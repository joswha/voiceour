from __future__ import annotations

import argparse
from pathlib import Path

import pytest

from voiceour_bench import run


class _BuildReached(Exception):
    """Raised in place of the release build once argument parsing has succeeded."""


@pytest.mark.parametrize("backend", ["fake", "granite"])
def test_every_registered_backend_is_accepted(monkeypatch: pytest.MonkeyPatch, backend: str) -> None:
    def refuse_build(root: Path) -> Path:
        raise _BuildReached

    monkeypatch.setattr(run, "_build_swift_runner", refuse_build)
    with pytest.raises(_BuildReached):
        run.main(["--tier", "smoke", "--mode", "stt", "--backend", backend])


def test_an_unregistered_backend_is_refused_before_building(monkeypatch: pytest.MonkeyPatch) -> None:
    def refuse_build(root: Path) -> Path:
        raise AssertionError("an invalid backend must fail before the release build")

    monkeypatch.setattr(run, "_build_swift_runner", refuse_build)
    with pytest.raises(SystemExit) as raised:
        run.main(["--tier", "smoke", "--mode", "stt", "--backend", "granite-ctc"])
    assert raised.value.code == 2


def test_the_default_backend_is_granite(monkeypatch: pytest.MonkeyPatch) -> None:
    seen: list[argparse.Namespace] = []

    def capture(runner: Path, args: argparse.Namespace, manifest: Path, output: Path, root: Path) -> None:
        seen.append(args)
        raise _BuildReached

    monkeypatch.setattr(run, "_build_swift_runner", lambda root: root / "voiceour-bench")
    monkeypatch.setattr(run, "prepare_tier", lambda tier, n, root: Path(__file__))
    monkeypatch.setattr(run, "_results_jsonl_path", lambda root, tier, mode, backend: root / "unused.jsonl")
    monkeypatch.setattr(run, "_invoke_runner", capture)
    with pytest.raises(_BuildReached):
        run.main(["--tier", "smoke", "--mode", "stt"])
    assert seen[0].backend == "granite"
