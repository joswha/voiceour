"""Bounded phrase-boosting trie for inference-time shallow fusion.

This module builds an Aho-Corasick automaton over *token-id* sequences (the
model's BPE/SentencePiece ids, produced by the term -> token-id segmenter in
:mod:`voiceoour_asr.decoding.vocabulary`) and exposes a pure, deterministic
scoring interface for shallow-fusion biasing during decoding.

Design (all computed once at construction, read-only thereafter):

* **Goto trie.** Every phrase is inserted as a path of nodes. A node's
  *accumulated bias* ``A(node)`` is the sum of per-edge increments from the
  root, where the increment for the edge entering depth ``d`` is
  ``weight * depth_increment * d``. The marginal reward therefore *increases*
  with depth (deeper, longer partial matches earn more per token), and ``A`` is
  monotonically non-decreasing down any path. Edges shared by several phrases
  take the maximum increment, so a shared prefix earns credit toward the
  most-boosted phrase that runs through it.
* **Completion bonus.** Landing on a node that ends one or more phrases adds a
  ``weight * completion_bonus`` term on top of the accumulated-bias delta.
* **Failure links / backoff.** When a candidate token does not continue the
  current phrase, the automaton follows Aho-Corasick failure links to the
  longest matched *suffix* that is still a phrase prefix, instead of dropping
  straight back to the root. A broken partial match therefore degrades
  gracefully: credit for the still-matching suffix is retained rather than lost.
* **Output links.** Completions reachable through the failure chain (a shorter
  phrase that is a suffix of the current match) are credited too, matching
  standard Aho-Corasick multi-pattern output semantics.

The running bias of a token path telescopes: after any token sequence the total
equals ``A(current_state)`` plus every completion bonus banked along the way.
Divergence emits a *negative* delta that gives exactly that credit back down to
the retained suffix (or to zero at the root), so no spurious bias survives a
mismatch.

States are opaque non-negative integers (node ids); :attr:`PhraseTrie.root` is
the stable start state. :meth:`PhraseTrie.advance` is a pure function of
``(state, token_id)`` with no global mutation, so it is safe to fan out across
beam hypotheses. The RNN-T blank token is scored as a no-op that leaves the
state untouched.

The module deliberately imports no MLX / Metal and needs no checkpoint: it
operates purely on integer token ids and is unit-testable with synthetic
phrases.
"""

from __future__ import annotations

from collections import deque
from collections.abc import Iterable

__all__ = ["PhraseTrie"]

#: Opaque decoder state: an index into the automaton's node arrays.
State = int

_ROOT: State = 0


def _normalize_phrase(item: object, default_weight: float) -> tuple[list[int], float]:
    """Normalise one ``phrases`` entry into ``(token_ids, weight)``.

    Accepts the contract form ``(token_ids, weight)`` as well as a bare
    token-id sequence (weight defaults to ``default_weight``). The two are told
    apart by whether the first element is itself a sequence.
    """
    seq: object = item
    weight = default_weight
    if isinstance(item, (tuple, list)) and len(item) == 2 and isinstance(item[0], (tuple, list)):
        seq, weight = item[0], item[1]  # type: ignore[assignment]
    if not isinstance(seq, (tuple, list)):
        raise TypeError(f"phrase token sequence must be a list/tuple, got {type(seq)!r}")
    return [int(token) for token in seq], float(weight)


class PhraseTrie:
    """Aho-Corasick phrase-boosting automaton over token-id sequences.

    Parameters
    ----------
    phrases:
        Iterable of ``(token_ids, weight)`` pairs (weight optional; a bare
        token-id sequence uses ``default_weight``). Empty sequences are skipped.
        Duplicate phrases merge: their completion bonuses sum and shared edges
        keep the maximum increment.
    depth_increment:
        Base multiplier for the depth-increasing partial-match score. The
        marginal reward for the edge entering depth ``d`` of a phrase with the
        given ``weight`` is ``weight * depth_increment * d``.
    completion_bonus:
        Multiplier for the end-of-phrase bonus (``weight * completion_bonus``)
        granted when a completing node is entered.
    default_weight:
        Weight applied to phrases supplied without an explicit weight.
    blank_id:
        RNN-T blank token id, scored as a no-op (state unchanged, delta ``0``).

    Notes
    -----
    Ignored (blank) tokens take precedence over the goto trie, so phrases must
    not contain them.
    """

    def __init__(
        self,
        phrases: Iterable[object],
        *,
        depth_increment: float = 1.0,
        completion_bonus: float = 1.0,
        default_weight: float = 1.0,
        blank_id: int | None = None,
    ) -> None:
        self.depth_increment = float(depth_increment)
        self.completion_bonus = float(completion_bonus)

        ignore: set[int] = set()
        if blank_id is not None:
            ignore.add(int(blank_id))
        self._ignore: frozenset[int] = frozenset(ignore)

        # Node-indexed arrays. Node 0 is the root.
        children: list[dict[int, int]] = [{}]
        edge_inc: list[float] = [0.0]  # increment on the edge entering this node
        own_bonus: list[float] = [0.0]  # completion bonus for phrases ending here
        ends: list[bool] = [False]  # does a phrase end exactly at this node

        num_phrases = 0
        for item in phrases:
            tokens, weight = _normalize_phrase(item, default_weight)
            if not tokens:
                continue
            num_phrases += 1
            node = _ROOT
            for depth, token in enumerate(tokens, start=1):
                nxt = children[node].get(token)
                if nxt is None:
                    nxt = len(children)
                    children.append({})
                    edge_inc.append(0.0)
                    own_bonus.append(0.0)
                    ends.append(False)
                    children[node][token] = nxt
                inc = weight * self.depth_increment * depth
                if inc > edge_inc[nxt]:
                    edge_inc[nxt] = inc
                node = nxt
            own_bonus[node] += weight * self.completion_bonus
            ends[node] = True

        n = len(children)
        self._children: list[dict[int, int]] = children
        self.num_phrases = num_phrases

        # Accumulated bias A(node): telescoping sum of edge increments (a tree
        # walk, so each node is visited exactly once). Monotone non-decreasing.
        bias = [0.0] * n
        walk: deque[int] = deque([_ROOT])
        while walk:
            u = walk.popleft()
            for v in children[u].values():
                bias[v] = bias[u] + edge_inc[v]
                walk.append(v)
        self._bias: list[float] = bias

        # Failure links via BFS. fail[node] is the deepest node whose token
        # string is a proper suffix of node's; it is always strictly shallower,
        # so BFS visits it before node.
        fail = [_ROOT] * n
        order: list[int] = []
        queue: deque[int] = deque()
        for child in children[_ROOT].values():
            fail[child] = _ROOT
            order.append(child)
            queue.append(child)
        while queue:
            u = queue.popleft()
            for token, v in children[u].items():
                f = fail[u]
                while f != _ROOT and token not in children[f]:
                    f = fail[f]
                candidate = children[f].get(token)
                fail[v] = candidate if (candidate is not None and candidate != v) else _ROOT
                order.append(v)
                queue.append(v)
        self._fail: list[int] = fail

        # Output aggregation over the failure chain: a node completes its own
        # phrases plus every phrase completed by a shallower suffix.
        bonus = [0.0] * n
        terminal = [False] * n
        bonus[_ROOT] = own_bonus[_ROOT]
        terminal[_ROOT] = ends[_ROOT]
        for u in order:  # BFS order guarantees fail[u] is already finalised
            bonus[u] = own_bonus[u] + bonus[fail[u]]
            terminal[u] = ends[u] or terminal[fail[u]]
        self._bonus: list[float] = bonus
        self._terminal: list[bool] = terminal

    @property
    def root(self) -> State:
        """Stable start state for a fresh traversal."""
        return _ROOT

    def _transition(self, state: State, token_id: int) -> State:
        """Aho-Corasick goto*: the next state following failure links.

        Returns the deepest node reachable by consuming ``token_id`` from
        ``state`` or any of its failure-chain ancestors, or the root when no
        suffix matches. Pure: reads only immutable automaton arrays.
        """
        children = self._children
        fail = self._fail
        cur = state
        while True:
            nxt = children[cur].get(token_id)
            if nxt is not None:
                return nxt
            if cur == _ROOT:
                return _ROOT
            cur = fail[cur]

    def advance(self, state: State, token_id: int) -> tuple[State, float]:
        """Score ``token_id`` from ``state``; return ``(new_state, delta)``.

        ``delta`` is the change in accumulated bias plus any completion bonus
        earned by landing on the new state:

        * a forward match into a deeper node yields a positive, depth-increasing
          delta (plus the completion bonus if a phrase ends there);
        * a divergent token backs off via failure links, retaining credit for
          the longest still-matching suffix and emitting the (typically
          negative) delta that reconciles accumulated bias;
        * a blank token is a no-op: the state is unchanged and the delta is
          exactly ``0.0``.

        Pure function of ``(state, token_id)`` with no mutation of shared state.
        """
        if token_id in self._ignore:
            return state, 0.0
        nxt = self._transition(state, token_id)
        delta = self._bias[nxt] - self._bias[state] + self._bonus[nxt]
        return nxt, delta

    def is_terminal(self, state: State) -> bool:
        """Whether ``state`` completes at least one phrase (incl. via suffix)."""
        return self._terminal[state]

    def accumulated_bias(self, state: State) -> float:
        """Accumulated partial-match bias ``A(state)`` (read-only accessor)."""
        return self._bias[state]

    def __len__(self) -> int:
        return self.num_phrases
