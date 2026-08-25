<div align="center">

<img src="docs/media/app-icon.png" width="128" alt="">

# Voiceour

<p><strong>Tap <code>fn</code> to dictate where your cursor is.</strong></p>

<img src="docs/media/dictation-island-still.png" width="720" alt="Voiceour’s recording island while listening, with Cancel on the left, a live waveform in the center, and Finish on the right.">

[**Download Voiceour**](https://github.com/joswha/voiceour/releases/latest)

<sub>macOS 14+ · English only · initial 1.26 GB model download</sub>

</div>

## How it works

Tap Fn once and speak. Tap again and the text lands in the app you were already using — recorded, recognized, and cleaned up entirely on your Mac.

No account, no telemetry, no cloud transcription. The only network request fetches the recognition model, pinned to `ggml-org/parakeet-GGUF` revision `35156454d1a39de06863303dd209fd2bed6ee079`. Settings offers a Compact version of that same model — 0.67 GB on disk instead of 1.26 GB, a little slower to transcribe, applied the next time Voiceour starts.

## Documentation

[Architecture](docs/architecture.md) · [Permissions and delivery safety](docs/permissions.md) · [Benchmarks](docs/benchmarks.md) · [Non-goals](docs/v0-non-goals.md) · [UI design](docs/design-bible.md) · [Developer setup](docs/developer-setup.md) · [Contributing](CONTRIBUTING.md)

[![CI](../../actions/workflows/ci.yml/badge.svg)](../../actions/workflows/ci.yml)

MIT licensed. [NOTICE](NOTICE) credits third-party source and model artifacts.
