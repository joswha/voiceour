from __future__ import annotations

import pytest

from voiceour_asr.decoding.trie import PhraseTrie


def feed(trie: PhraseTrie, tokens):
    """Run ``tokens`` from the root; return (states, deltas)."""
    state = trie.root
    states: list[int] = []
    deltas: list[float] = []
    for token in tokens:
        state, delta = trie.advance(state, token)
        states.append(state)
        deltas.append(delta)
    return states, deltas


def test_root_is_stable_and_non_terminal():
    trie = PhraseTrie([([1, 2], 1.0)])
    assert trie.root == trie.root
    assert not trie.is_terminal(trie.root)
    assert trie.accumulated_bias(trie.root) == 0.0
    assert len(trie) == 1


def test_following_phrase_accrues_increasing_bias_then_completion_bonus():
    # completion_bonus=0 isolates the pure depth-increasing marginals.
    trie = PhraseTrie([([1, 2, 3], 1.0)], depth_increment=1.0, completion_bonus=0.0)
    states, deltas = feed(trie, [1, 2, 3])

    # Marginal reward strictly increases with depth.
    assert deltas[0] < deltas[1] < deltas[2]
    assert all(d > 0 for d in deltas)
    assert trie.is_terminal(states[-1])

    # Adding a completion bonus increases the total accrued bias by exactly the
    # bonus and nothing else (same monotone partial-match structure otherwise).
    boosted = PhraseTrie([([1, 2, 3], 1.0)], depth_increment=1.0, completion_bonus=5.0)
    _, boosted_deltas = feed(boosted, [1, 2, 3])
    assert sum(boosted_deltas) == pytest.approx(sum(deltas) + 5.0)
    # The bonus lands on the completing step, not the partial ones.
    assert boosted_deltas[:2] == deltas[:2]
    assert boosted_deltas[2] == pytest.approx(deltas[2] + 5.0)


def test_weight_scales_bias():
    light = PhraseTrie([([1, 2], 1.0)])
    heavy = PhraseTrie([([1, 2], 3.0)])
    assert heavy.accumulated_bias(feed(heavy, [1, 2])[0][-1]) == pytest.approx(
        3.0 * light.accumulated_bias(feed(light, [1, 2])[0][-1])
    )


def test_divergent_token_backs_off_via_failure_link_when_suffix_matches():
    # Phrases [1,2] and [2,3]: after completing [1,2], token 3 diverges but the
    # suffix "2" is a live prefix, so we back off to it and complete [2,3]
    # rather than resetting to the root with zero credit.
    trie = PhraseTrie([([1, 2], 1.0), ([2, 3], 1.0)])
    states, _ = feed(trie, [1, 2, 3])

    after_divergence = states[-1]
    assert after_divergence != trie.root
    assert trie.is_terminal(after_divergence)  # [2,3] completed via backoff
    assert trie.accumulated_bias(after_divergence) > 0.0  # credit retained


def test_full_reset_when_no_suffix_matches():
    trie = PhraseTrie([([1, 2], 1.0), ([2, 3], 1.0)])
    mid, _ = feed(trie, [1, 2])
    mid_state = mid[-1]
    assert trie.accumulated_bias(mid_state) > 0.0

    # An unrelated token from a mid-phrase state gives all credit back: land on
    # root with a negative delta equal to -A(mid_state).
    new_state, delta = trie.advance(mid_state, 99)
    assert new_state == trie.root
    assert delta == pytest.approx(-trie.accumulated_bias(mid_state))


def test_unrelated_tokens_yield_no_spurious_bias():
    trie = PhraseTrie([([1, 2, 3], 1.0)])
    states, deltas = feed(trie, [50, 51, 52])
    assert all(s == trie.root for s in states)
    assert all(d == 0.0 for d in deltas)
    assert not any(trie.is_terminal(s) for s in states)


def test_shared_prefix_phrases_both_remain_reachable():
    trie = PhraseTrie([([1, 2, 3], 1.0), ([1, 2, 4], 1.0)])
    shared, _ = feed(trie, [1, 2])
    shared_state = shared[-1]

    branch_a, delta_a = trie.advance(shared_state, 3)
    branch_b, delta_b = trie.advance(shared_state, 4)

    assert branch_a != branch_b
    assert trie.is_terminal(branch_a)  # [1,2,3]
    assert trie.is_terminal(branch_b)  # [1,2,4]
    assert delta_a > 0.0 and delta_b > 0.0


def test_aho_corasick_suffix_output_credits_contained_phrase():
    # [3] is a suffix of [1,2,3]; completing [1,2,3] must also credit [3].
    only_long = PhraseTrie([([1, 2, 3], 1.0)])
    with_suffix = PhraseTrie([([1, 2, 3], 1.0), ([3], 1.0)])

    long_state, _ = feed(only_long, [1, 2, 3])
    both_states, _ = feed(with_suffix, [1, 2, 3])

    # Landing on the [1,2,3] terminal also fires [3]'s output link.
    long_bonus = only_long.advance(feed(only_long, [1, 2])[0][-1], 3)[1]
    both_bonus = with_suffix.advance(feed(with_suffix, [1, 2])[0][-1], 3)[1]
    assert both_bonus > long_bonus
    assert with_suffix.is_terminal(both_states[-1])


def test_blank_tokens_are_no_ops():
    trie = PhraseTrie([([1, 2], 1.0)], blank_id=0)
    state = trie.root
    state, d1 = trie.advance(state, 1)
    after_1 = state

    # Blank leaves state and delta untouched.
    state, d_blank = trie.advance(state, 0)
    assert state == after_1
    assert d_blank == 0.0

    # The phrase still completes across interleaved no-ops.
    state, d2 = trie.advance(state, 2)
    assert trie.is_terminal(state)
    assert d2 > 0.0


def test_advance_is_pure_and_deterministic():
    trie = PhraseTrie([([1, 2], 1.0), ([2, 3], 2.0)])
    tokens = [1, 2, 3, 2, 3, 99, 1, 2]

    run_a = feed(trie, tokens)
    run_b = feed(trie, tokens)
    assert run_a == run_b

    # Calling advance twice on the same (state, token) is side-effect free.
    mid, _ = feed(trie, [1])
    s = mid[-1]
    first = trie.advance(s, 2)
    second = trie.advance(s, 2)
    assert first == second
    # And it did not perturb an independent fresh traversal.
    assert feed(trie, tokens) == run_a


def test_empty_and_bare_sequence_forms():
    # Empty phrases are skipped; bare sequences use the default weight.
    trie = PhraseTrie([[], [1, 2], ([3, 4], 2.0)], default_weight=1.0)
    assert len(trie) == 2

    bare_state, _ = feed(trie, [1, 2])
    weighted_state, _ = feed(trie, [3, 4])
    assert trie.is_terminal(bare_state[-1])
    assert trie.is_terminal(weighted_state[-1])
    # weight 2.0 phrase accrues twice the partial-match bias of the weight-1 one.
    assert trie.accumulated_bias(weighted_state[-1]) == pytest.approx(2.0 * trie.accumulated_bias(bare_state[-1]))


def test_no_mlx_import():
    # Verify in a fresh interpreter so sibling test modules that legitimately
    # import mlx cannot contaminate this process's sys.modules.
    import subprocess
    import sys

    code = (
        "import sys\n"
        "import voiceour_asr.decoding.trie as trie_mod\n"
        "assert 'mlx' not in trie_mod.__dict__\n"
        "leaked = [n for n in sys.modules if n == 'mlx' or n.startswith('mlx.')]\n"
        "assert not leaked, leaked\n"
    )
    result = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
