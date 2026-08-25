<div align="center">

<img src="docs/media/app-icon.png" width="128" alt="">

# Voiceour

<p><strong>Tap <code>fn</code> to dictate where your cursor is.</strong></p>

<img src="docs/media/dictation-island-still.png" width="720" alt="Voiceour’s recording island while listening, with Cancel on the left, a live waveform in the center, and Finish on the right.">

<sub>macOS 14+ · English only · initial 1.26 GB model download</sub>

</div>

## How it works

Tap Fn once and speak. Tap again and the text lands in the app you were already using — recorded, recognized, and cleaned up entirely on your Mac. Ordinary text fields get the paste; a terminal, a code editor, a password field, or a target Voiceour could not read gets the transcript on the clipboard instead, and no setting widens that. [Permissions and delivery safety](docs/permissions.md) has the matrix.

No account, no telemetry, no cloud transcription. The only network request fetches the recognition model, pinned to `ggml-org/parakeet-GGUF` revision `35156454d1a39de06863303dd209fd2bed6ee079`. Settings offers a Compact version of that same model — 0.67 GB on disk instead of 1.26 GB, a little slower to transcribe, applied the next time Voiceour starts.

## Build it

There is no signed release yet, so build from source. You need macOS 14 or newer and a Swift 6 toolchain — Xcode 16 or newer, or just its Command Line Tools.

```sh
git clone https://github.com/joswha/voiceour.git
cd voiceour
make build
```

Start on the fake backend. It needs no model download and no permission grant: synthetic audio through the real pipeline, real UI.

```sh
scripts/run_dev.sh
```

Then run the real app. This assembles `.build/Voiceour.app`, downloads the pinned model on first launch — 1.26 GB, with progress in the menu bar — and asks for Microphone at the first recording, plus Accessibility if you want the paste rather than a clipboard copy.

```sh
scripts/run_real.sh
```

That bundle is ad-hoc signed, not notarized, so its code identity can change when you rebuild and macOS may ask for both grants again. Run `scripts/setup_local_signing.sh` once for a stable local identity; [developer setup](docs/developer-setup.md) covers signing, notarization, and the rest of the commands.

## Documentation

[Architecture](docs/architecture.md) · [Permissions and delivery safety](docs/permissions.md) · [Benchmarks](docs/benchmarks.md) · [Non-goals](docs/non-goals.md) · [UI design](docs/design-bible.md) · [Developer setup](docs/developer-setup.md) · [Contributing](CONTRIBUTING.md) · [Changelog](CHANGELOG.md)

[![CI](../../actions/workflows/ci.yml/badge.svg)](../../actions/workflows/ci.yml)

MIT licensed. [NOTICE](NOTICE) credits third-party source and model artifacts.
