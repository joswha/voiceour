# GPU research host — `ubuntu-devbox`

Provisioned 2026-09-03 for the next ASR program (`research/next-program.md`). The host runbook
with access, storage, and hazards is `~/.omp/agent/docs/ubuntu-devbox.md`; this file records
only what the research program adds and how to reproduce it.

## Hardware (measured 2026-09-03)

| component | value |
|---|---|
| GPU | NVIDIA GeForce RTX 2070 SUPER, 8,192 MiB, compute capability 7.5 (Turing: fp16 tensor cores, no bf16, no FlashAttention-2), driver 595.84, CUDA 13.2 |
| CPU | AMD Ryzen 9 7950X, 16 cores / 32 threads, AVX-512 |
| RAM | 30 GiB (27 available beside the v12x dev stacks), 4 GiB swap |
| Disk | `/srv/devbox` 916 GiB NVMe (547 GiB free), `/` 449 GiB (165 GiB free) |
| Network | ~26 MB/s from Hugging Face |

Consequence for training: full-parameter fine-tuning of the 0.6B model with a standard
optimizer does not fit in 8 GiB; partial unfreezing, adapters, or a rented GPU do. The
measured envelope is recorded by the `train-feasibility` run under the student track.

## Layout on the host

```
/srv/devbox/research/voiceour/
    envs/<name>/          uv projects (pyproject.toml + uv.lock); pythons/ holds uv-managed CPython
    data/                 shipped frozen corpora, screen inputs, mined audio
    runs/                 per-run artifacts, mirrored to the Mac's .build/asr-research/next/…
    logs/
    mining/               corpus mining pipeline
/srv/devbox/models/voiceour/   model weights outside the HF cache
/srv/devbox/cache/{uv,hf}      UV_CACHE_DIR and HF_HOME
```

Nothing under `/srv/devbox/code`, the Docker stacks, or system packages is touched; `uv` is a
user-space binary at `~/.local/bin/uv` and every Python comes from `uv python install`.

## Environments

Every remote script exports:

```sh
export PATH="$HOME/.local/bin:$PATH" UV_CACHE_DIR=/srv/devbox/cache/uv \
       UV_PYTHON_INSTALL_DIR=/srv/devbox/research/voiceour/envs/pythons HF_HOME=/srv/devbox/cache/hf
```

| env | purpose | pins |
|---|---|---|
| `envs/nemo` | NeMo inference, VAD, mining | `envs/nemo/` here (torch 2.11.0+cu128, nemo_toolkit 3.0.0, transformers 5.16.1, silero-vad, static-ffmpeg, yt-dlp) |
| `envs/train` | NeMo fine-tuning | `envs/train/` here: same base plus `nvidia-cuda-nvcc-cu12==12.8.*` (libNVVM for the numba TDT-loss kernel), `numba==0.67.0`, and `patch_nemo_clamp.py`, applied once after `uv sync` because numba 0.67 cannot compile the two-argument `min`/`max` in NeMo's RNNT gradient-clamp block under the CUDA target. Export `CUDA_HOME=/srv/devbox/research/voiceour/envs/train/cuda_shim` (symlinks to the wheel's `nvvm/` and `lib64/`). Inference in `envs/nemo` is unaffected. |
| `envs/screen-qwen` | Qwen3-ASR candidate | `qwen-asr 0.0.6`, transformers 4.57.6, torch 2.11.0+cu128 |
| `envs/screen-kyutai` | Kyutai STT candidate | `moshi 0.2.12`, torch 2.9.1+cu128, sphn, sentencepiece 0.2.2 |
| `envs/screen-score` | scorer matching the bench pins | jiwer 4.0.0, whisper-normalizer 0.1.12, rapidfuzz 3.14.5 |

Rebuild any env: copy its `pyproject.toml` + `uv.lock` to `/srv/devbox/research/voiceour/envs/<name>/`
and run `uv sync` there. Verified 2026-09-03: `nvidia/parakeet-tdt-0.6b-v3` loads on CUDA
(34.5 s, 4.8 GiB peak) and transcribes `fixtures/audio/hello_16k_mono.wav` to the same text
as the Mac sidecar (`Hello world testing Nvidia Parakeet NN spaceport.`; only the
`Nvidia`/`NVIDIA` casing differs).

## GPU health (measured 2026-09-03)

The card's PCIe link is faulty. Under load the kernel logs uncorrectable non-fatal AER
errors (`CmpltTO`, completion timeouts) and `Xid 13` graphics exceptions — 219 events in one
day — and `lspci` shows `LnkSta: 2.5GT/s (downgraded)` on a Gen3 x16 card in a Gen5-capable
slot, i.e. the link never trains above Gen1. A 2-minute host↔device copy soak
(`runs/gpu-health/stress.py`) corrupted 14 of 362 256 MB round trips with the default ASPM
policy and 2 of 371 with `pcie_aspm` policy `performance` (set at runtime, not persisted;
`power/control=on` on the GPU function likewise). Matmul results were bit-exact both times:
compute is fine, transfers are not. Two independent runs saw silently wrong results — NaN
from a device-to-host weight copy, a reloaded model emitting `⁇` from bitwise-identical
weights. `CUDA_LAUNCH_BLOCKING=1` reduces but does not eliminate the fault.

Consequences: (1) every result from this GPU must be replicated or checked against a
CPU/Mac reference before it is trusted; the replacement-screen kills were validated by exact
reproduction of the frozen v3 baseline (19/799) and by double-decode hash identity; (2) no
training run is credible here until the link is fixed — reseat the card/riser or force the
slot to Gen3 in firmware, then rerun `stress.py` and expect 0 mismatches; (3) the fine-tuning
envelope below stands regardless.

## Fine-tuning envelope (`runs/train-feasibility`, `.build/…/technical-student-distillation/wave1/train-feasibility/` on the Mac)

`parakeet-tdt-0.6b-v3`, fp16 AMP, AdamW 1e-5, 30 steps, ≤15 s audio, official Lightning loop,
7.60 GiB usable: full fine-tune (627M) **OOMs at batch 2**; decoder+joint (18.1M, encoder
frozen) fits at batch 4 (7.10 GiB, 35.8 audio-s/s) or batch 2 (3.83 GiB, 20.0 audio-s/s ≈ 3 min
per audio hour); encoder top-4 / top-8 + decoder+joint and NeMo linear adapters (dim 64, after
`model.replace_adapter_compatible_modules()`) fit only at batch 2. NeMo exposes no gradient
checkpointing for FastConformer. `.nemo` save/load is lossless (725/725 tensors bitwise
identical, 5/5 transcripts identical on CPU). The real distillation fine-tune needs a
bf16-capable GPU with ≥ 24 GB (L4/A10G/A100).

## Rules of use

- One GPU job at a time; agents coordinate before a GPU step. Timing-bearing product
  measurements never come from this host — it is for training, candidate decodes, and mining.
  Product latency/RTFx/energy stay on Apple Silicon under `bash autoresearch.sh`.
- Every run writes `command.txt`, `manifest.json` (env lock digest, model revisions, GPU,
  driver, seeds), `metrics.jsonl`, and a verdict, and is mirrored to the Mac artifact tree.
- No Hugging Face token is installed on either machine; gated repositories are recorded as
  blocked, never worked around.
