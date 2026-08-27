# Contributing

Development is fake-first: you can build, test, and run the app without downloading the model or granting system permissions. `make dev` runs the fake backend in this terminal; `make self-test` is the launch-path check on that same path.

Setup instructions are in [docs/developer-setup.md](docs/developer-setup.md). [AGENTS.md](AGENTS.md) holds the full engineering rules, including the [complete command matrix](AGENTS.md#developer-commands).

## Before you open a PR

Run `make check`. It is the portable gate, in this order: build, format-check, check-docs, lint-python, test, ui-flow, test-python, self-test, bench-smoke. Any of those can be run alone.

```sh
make check
```

Everyone runs `make check`. The real-model and real-microphone suites need a downloaded model or a physical input device, so run them only when your change touches those paths; [docs/developer-setup.md](docs/developer-setup.md) names their flags.

If you changed the UI, also run `make ui-snap`. Read the generated `.ax.diff` or `.flow.diff` before you bless a golden with `make ui-update` or `make ui-flow-update`. A scene with an error-severity lint finding cannot be blessed; [docs/ui-harness.md](docs/ui-harness.md) explains the artifacts.

## What a good PR looks like

- Keep the change narrow. Say which observable behavior changes and why.
- Name the smallest verification that proves the change works.
- Do not add compatibility shims for internal APIs. Update every caller instead.
- Update the one document that owns the topic rather than describing it twice.
- Add a bullet to [CHANGELOG.md](CHANGELOG.md) under `Unreleased` when the change is user-visible.
- Do not bump the version or add a release heading to the changelog in a PR. Releasing is a local maintainer operation; [AGENTS.md](AGENTS.md#release-procedure) has the procedure.
- Commit intended UI goldens and flow journals together with the behavior change that requires them.
- Keep build artifacts and raw per-utterance benchmark output out of the commit.
