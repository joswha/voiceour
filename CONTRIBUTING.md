# Contributing

Development is fake-first: you can build, test, and run the app without downloading the model or granting system permissions.

Setup instructions are in [docs/developer-setup.md](docs/developer-setup.md). [AGENTS.md](AGENTS.md) holds the full engineering rules, including the [complete command matrix](AGENTS.md#developer-commands).

## Before you open a PR

Run these portable checks, in this order:

```sh
make build
make format-check
make check-docs
make lint-python
make test
make ui-flow
(cd bench && uv --no-config run pytest)
scripts/run_dev.sh --self-test
make bench-smoke
```

Everyone runs that block. The real-model and real-microphone suites need a downloaded model or a physical input device, so run them only when your change touches those paths; [docs/developer-setup.md](docs/developer-setup.md) names their flags.

If you changed the UI, also run `make ui-snap`. Read the generated `.ax.diff` or `.flow.diff` before you bless a golden with `make ui-update` or `make ui-flow-update`. A scene with an error-severity lint finding cannot be blessed; [docs/ui-harness.md](docs/ui-harness.md) explains the artifacts.

## What a good PR looks like

- Keep the change narrow. Say which observable behavior changes and why.
- Name the smallest verification that proves the change works.
- Do not add compatibility shims for internal APIs. Update every caller instead.
- Update the one document that owns the topic rather than describing it twice.
- Add a bullet to [CHANGELOG.md](CHANGELOG.md) under `Unreleased` when the change is user-visible.
- Commit intended UI goldens and flow journals together with the behavior change that requires them.
- Keep build artifacts and raw per-utterance benchmark output out of the commit.
