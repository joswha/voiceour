# Contributing

Development is fake-first: you can build, test, and run the app without downloading the model or granting system permissions. `make dev` runs the fake backend in this terminal; `make self-test` is the launch-path check on that same path.

[README.md](README.md#development) owns setup and the product's technical contract. [AGENTS.md](AGENTS.md) owns engineering invariants, verification and release workflows, including the [complete command matrix](AGENTS.md#developer-commands).

## Before you open a PR

Run `make check` on macOS 27 with Xcode 27 and Swift 6.4. It is the local gate, in this order: build, format-check, check-docs, lint-python, test, ui-flow, ui-mercury-bench, test-python, self-test, bench-smoke. Any of those can be run alone.

```sh
make check
```

Everyone runs `make check`. The real-model and real-microphone suites need a downloaded model or a physical input device; [verification](README.md#verification) names their opt-in flags and what they prove.

If you changed the UI, also run `make ui-snap`. Read the generated `.ax.diff` or `.flow.diff` before you bless a golden with `make ui-update` or `make ui-flow-update`. A scene with an error-severity lint finding cannot be blessed; [docs/ui-harness.md](docs/ui-harness.md) explains the artifacts.

CI uses the `xcode-27` preview runner and asserts macOS 27, Xcode 27, SDK 27, Swift 6.4, and arm64 before building. Semantic flows are required; hosted scene snapshots remain advisory, so do not bless CI raster drift.

## What a good PR looks like

- Keep the change narrow. Say which observable behavior changes and why.
- Name the smallest verification that proves the change works.
- Do not add compatibility shims for internal APIs. Update every caller instead.
- Update `README.md` for the product contract and `AGENTS.md` for engineering invariants. Specialist docs hold supporting derivations, measurement records and harness details, not competing specifications.
- Add a bullet to [CHANGELOG.md](CHANGELOG.md) under `Unreleased` when the change is user-visible.
- Do not bump the version or add a release heading to the changelog in a PR. Releasing is a local maintainer operation; [AGENTS.md](AGENTS.md#release-procedure) has the procedure.
- Commit intended UI goldens and flow journals together with the behavior change that requires them.
- Keep build artifacts and raw per-utterance benchmark output out of the commit.
