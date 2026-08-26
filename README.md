<div align="center">

<img src="docs/media/app-icon.png" width="128" alt="">

# Voiceour

<p><strong>Tap <code>fn</code> to dictate where your cursor is.</strong></p>

<img src="docs/media/dictation-island-still.png" width="720" alt="Voiceour’s recording island while listening, with Cancel on the left, a live waveform in the center, and Finish on the right.">

<sub>macOS 14+ · Apple Silicon only · English only · initial 1.26 GB model download</sub>

</div>

## How it works

Tap Fn once and speak. Tap again and the text lands in the app you were already using — recorded, recognized, and cleaned up entirely on your Mac. Ordinary text fields get the paste; a terminal, a code editor, a password field, or a target Voiceour could not read gets the transcript on the clipboard instead, and no setting widens that. [Permissions and delivery safety](docs/permissions.md) has the matrix.

No account, no telemetry, no cloud transcription. The only network request fetches the recognition model, pinned to `ggml-org/parakeet-GGUF` revision `35156454d1a39de06863303dd209fd2bed6ee079`. Settings offers a Compact version of that same model — 0.67 GB on disk instead of 1.26 GB, a little slower to transcribe, applied the next time Voiceour starts.

## Contributing

Voiceour is MIT licensed, so you're free to read it, fork it, and build your own version.

It's maintained by one person, so I keep the scope tight and won't merge every pull request. Please open an issue before starting anything large, so we can agree on the approach first. Bug reports and ideas are always welcome.

Two things that are especially welcome:

- **Documentation fixes.** Wrong commands, dead links, anything out of date.
- **Fixes under `Vendor/parakeet/`.** That directory is a copy of [ggml-org/whisper.cpp](https://github.com/ggml-org/whisper.cpp). Send those upstream instead — they'll reach every project using it, and they'll survive the next time Voiceour updates its copy.

[CONTRIBUTING.md](CONTRIBUTING.md) has the checks to run before opening a PR.

## Build it

There is no signed release yet, so build from source. You need macOS 14 or newer on Apple Silicon and a Swift 6 toolchain — Xcode 16 or newer, or just its Command Line Tools.

```sh
git clone https://github.com/joswha/voiceour.git
cd voiceour
make build
```

Start on the fake backend. It needs no model download and no permission grant: synthetic audio through the real pipeline, real UI.

```sh
scripts/run_dev.sh
```

Then run the real app. This assembles `.build/Voiceour.app`, downloads the pinned model on first launch — 1.26 GB, with progress in the menu bar — and asks for Microphone at the first recording, plus Accessibility if you want the paste rather than a clipboard copy. The first launch opens the console on Home, where a first-run card states the tap gesture, the download's progress, and which of those two permissions is required — it retires itself once you have dictated once.

```sh
scripts/run_real.sh
```

That bundle is ad-hoc signed, not notarized, so its code identity can change when you rebuild and macOS may ask for both grants again. Run `scripts/setup_local_signing.sh` once for a stable local identity; [developer setup](docs/developer-setup.md) covers signing, notarization, and the rest of the commands.

## FAQ

### Why Apple Silicon only?

The vendored parakeet.cpp/ggml code is arm64-only, and `Vendor/parakeet/ggml/embed/ggml-metal-embed.c` enforces that at compile time. Supporting Intel would mean vendoring upstream's x86 sources and splitting `Package.swift` into per-architecture targets, since SwiftPM has no architecture build condition. It's a deliberate choice, not something on the roadmap — see [non-goals](docs/non-goals.md).

### What network requests does Voiceour make?

Exactly one: downloading the recognition model. Transcription itself is entirely local. No telemetry, no account, no analytics, no update checks.

That request goes to `huggingface.co`, for the repository `ggml-org/parakeet-GGUF` at revision `35156454d1a39de06863303dd209fd2bed6ee079`, and fetches one of two files:

| file | size | when |
| --- | --- | --- |
| `ggml-parakeet-tdt-0.6b-v3-f16.bin` | 1.26 GB | Balanced (default) |
| `ggml-parakeet-tdt-0.6b-v3-q8_0.bin` | 0.67 GB | Compact |

The revision is pinned so you can fetch and hash those exact bytes yourself, and Voiceour verifies the download against a SHA-256 built into the app before loading it.

Worth being clear about one thing: like any download, that HTTPS request tells Hugging Face and its CDN your IP address and User-Agent. Local transcription doesn't change that.

You can block Voiceour in a firewall such as Little Snitch if you'd rather it didn't happen. Without the model there's no transcription, but the fake backend still works, since it downloads nothing.

### Known issues and troubleshooting

- **Build fails on an older toolchain.** Swift 6 is required: Xcode 16 or newer, or just its Command Line Tools.
- **macOS keeps asking for Microphone or Accessibility after a rebuild.** macOS ties a permission to the app's code signature, and an ad-hoc development build gets a new one each time. Run `scripts/setup_local_signing.sh` once for a stable local certificate; `scripts/bundle.sh` picks it up automatically.
- **A permission is stuck.** Quit Voiceour, reset it, and it'll ask again on the next recording.

  ```sh
  tccutil reset Microphone com.voiceour.app
  tccutil reset Accessibility com.voiceour.app
  ```

## Documentation

[Architecture](docs/architecture.md) · [Permissions and delivery safety](docs/permissions.md) · [Benchmarks](docs/benchmarks.md) · [Non-goals](docs/non-goals.md) · [UI design](docs/design-bible.md) · [Developer setup](docs/developer-setup.md) · [Contributing](CONTRIBUTING.md) · [Changelog](CHANGELOG.md)

[![CI](../../actions/workflows/ci.yml/badge.svg)](../../actions/workflows/ci.yml)

MIT licensed. That covers Voiceour's own code; third-party components keep their own terms. [NOTICE](NOTICE) credits the vendored sources and the speech model, and [benchmarks/DATA-LICENSE.md](benchmarks/DATA-LICENSE.md) covers the CC BY 4.0 corpus transcripts quoted in the committed benchmark reports.

Voiceour is an independent macOS dictation app, not affiliated with, sponsored by, or endorsed by Apple Inc.
