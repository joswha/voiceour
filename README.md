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

## Open source, not open contribution

The whole app is here under the MIT license. Read it, learn from it, fork it, ship your own version — that is what the license is for, and you need nobody's permission.

It is not an open-contribution project. One person maintains it, and keeping the design coherent counts for more here than merging every improvement: reviewing someone else's code and then owning it for good usually costs more than writing it. So most pull requests are declined, and that is a decision about maintenance rather than a verdict on the code in them.

Two carve-outs, both genuinely welcome:

- **Documentation fixes.** A wrong command, a dead link, a paragraph the app has outgrown — send it.
- **Anything under `Vendor/parakeet/`.** That tree is a vendored drop of [ggml-org/whisper.cpp](https://github.com/ggml-org/whisper.cpp), so fixes belong upstream there, where every downstream project gets them and where they survive the next re-vendor instead of being reapplied by hand.

Bugs and ideas are welcome as issues. Open one before writing anything large — it costs nothing to hear no first.

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

## Questions

### Why Apple Silicon only?

A stated non-goal, not an omission. The vendored parakeet.cpp/ggml drop is arm64-only by design, and `Vendor/parakeet/ggml/embed/ggml-metal-embed.c` enforces that at compile time. A universal build would mean re-vendoring upstream's x86 quantization and repack sources and splitting `Package.swift` into per-architecture targets, because SwiftPM has no architecture build condition. [Non-goals](docs/non-goals.md) lists the other decisions of this kind.

### What network requests does Voiceour make?

Exactly one, and only to fetch the recognition model. Recognition itself is entirely local: no telemetry, no account, no analytics, no update check.

That one request goes to `huggingface.co`, to the repository `ggml-org/parakeet-GGUF` at the pinned revision `35156454d1a39de06863303dd209fd2bed6ee079`, for one of its two files — `ggml-parakeet-tdt-0.6b-v3-f16.bin`, 1.26 GB, the Balanced default, or `ggml-parakeet-tdt-0.6b-v3-q8_0.bin`, 0.67 GB, if you chose Compact. Publishing the revision is the point of stating it: those coordinates name exact bytes you can fetch and hash yourself, and Voiceour checks the finished download against a SHA-256 compiled into the app before it will load it.

One honest caveat. That HTTPS request discloses your IP address and HTTP User-Agent to Hugging Face and its CDN, the same as any download does. Local inference cannot undo that, and nothing on this side pretends otherwise.

If you would rather it never happened, block Voiceour in a firewall such as Little Snitch. What breaks is exactly one thing, and it is the main one: with no model there is no transcription. The fake backend above still runs, because it needs no download at all.

### Known issues and troubleshooting

- **The build fails on an older toolchain.** Swift 6 is required: Xcode 16 or newer, or just its Command Line Tools.
- **macOS asks for Microphone or Accessibility again after a rebuild.** Expected: TCC keys a grant to a code identity, and an ad-hoc development identity can change. Run `scripts/setup_local_signing.sh` once for a stable self-signed certificate, which `scripts/bundle.sh` then picks up on its own.
- **A grant is stuck in a bad state.** Quit Voiceour, reset the two it holds, and it will ask again at the next recording.

  ```sh
  tccutil reset Microphone com.voiceour.app
  tccutil reset Accessibility com.voiceour.app
  ```

## Documentation

[Architecture](docs/architecture.md) · [Permissions and delivery safety](docs/permissions.md) · [Benchmarks](docs/benchmarks.md) · [Non-goals](docs/non-goals.md) · [UI design](docs/design-bible.md) · [Developer setup](docs/developer-setup.md) · [Contributing](CONTRIBUTING.md) · [Changelog](CHANGELOG.md)

[![CI](../../actions/workflows/ci.yml/badge.svg)](../../actions/workflows/ci.yml)

MIT licensed, which covers Voiceour's own code; third-party material keeps its own terms. [NOTICE](NOTICE) credits the vendored sources and the recognition model, and [benchmarks/DATA-LICENSE.md](benchmarks/DATA-LICENSE.md) the CC BY 4.0 corpus transcripts quoted in the committed benchmark reports.

Voiceour is an independent macOS dictation app, not affiliated with, sponsored by, or endorsed by Apple Inc.
