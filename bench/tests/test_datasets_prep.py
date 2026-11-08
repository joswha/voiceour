from __future__ import annotations

from pathlib import Path

import datasets.config
from datasets import load_dataset
from huggingface_hub import hf_hub_download

from voiceour_bench import datasets_prep


def test_dataset_caches_written_inside_the_benchmark_cache(tmp_path: Path) -> None:
    """Both libraries read their cache paths when imported, so setting the environment alone
    left every download of the process in ~/.cache/huggingface (52 GB by 2026-11-06)."""
    rows = tmp_path / "rows.csv"
    rows.write_text("text\nhello\n", encoding="utf-8")
    user_cache = datasets.config.HF_DATASETS_CACHE

    with datasets_prep._hf_cache_env(tmp_path):
        load_dataset("csv", data_files=str(rows), split="train")

    cache = datasets_prep.benchmarks_data_dir(tmp_path) / "hf-cache" / "datasets"
    assert any(cache.rglob("*.arrow"))
    assert datasets.config.HF_DATASETS_CACHE == user_cache


def test_hub_downloads_resolve_inside_the_benchmark_cache(tmp_path: Path) -> None:
    """`datasets` fetches Hub-hosted files with `hf_hub_download` and no cache directory, so the
    Hub's default cache is where they land. A seeded local entry proves which cache that is."""
    commit = "0" * 40
    repo = datasets_prep.benchmarks_data_dir(tmp_path) / "hf-cache" / "hub" / "datasets--voiceour--probe"
    (repo / "snapshots" / commit).mkdir(parents=True)
    (repo / "snapshots" / commit / "rows.txt").write_text("hello\n", encoding="utf-8")
    (repo / "refs").mkdir()
    (repo / "refs" / "main").write_text(commit, encoding="utf-8")

    with datasets_prep._hf_cache_env(tmp_path):
        path = hf_hub_download("voiceour/probe", "rows.txt", repo_type="dataset", local_files_only=True)

    assert Path(path).resolve() == (repo / "snapshots" / commit / "rows.txt").resolve()
