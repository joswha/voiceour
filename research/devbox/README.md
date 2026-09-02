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
| `envs/nemo` | NeMo inference, fine-tuning, VAD, mining | `envs/nemo/pyproject.toml` + `uv.lock` in this directory (torch 2.11.0+cu128, nemo_toolkit 3.0.0, transformers 5.16.1, silero-vad, static-ffmpeg, yt-dlp) |

Rebuild: copy the two files to `/srv/devbox/research/voiceour/envs/nemo/` and run `uv sync`
there. Verified 2026-09-03: `nvidia/parakeet-tdt-0.6b-v3` loads on CUDA (34.5 s, 4.8 GiB peak)
and transcribes `fixtures/audio/hello_16k_mono.wav` to the same text as the Mac sidecar
(`Hello world testing Nvidia Parakeet NN spaceport.`; only the `Nvidia`/`NVIDIA` casing
differs).

## Rules of use

- One GPU job at a time; agents coordinate before a GPU step. Timing-bearing product
  measurements never come from this host — it is for training, candidate decodes, and mining.
  Product latency/RTFx/energy stay on Apple Silicon under `bash autoresearch.sh`.
- Every run writes `command.txt`, `manifest.json` (env lock digest, model revisions, GPU,
  driver, seeds), `metrics.jsonl`, and a verdict, and is mirrored to the Mac artifact tree.
- No Hugging Face token is installed on either machine; gated repositories are recorded as
  blocked, never worked around.
