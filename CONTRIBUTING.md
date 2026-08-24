# Contributing

Development is fake-first: you can build, test, and run the app without downloading the model or granting system permissions.

Setup instructions are in [docs/developer-setup.md](docs/developer-setup.md). The full engineering rules are in [AGENTS.md](AGENTS.md).

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

Everyone runs that block; the extra real-model and real-microphone test runs need a downloaded model or a physical input device, so run them only when your change touches those paths.

If you changed the UI, also run `make ui-snap`. Read the generated `.ax.diff` or `.flow.diff` before you bless a golden with `make ui-update` or `make ui-flow-update`. A scene with an error-severity lint finding cannot be blessed.

## What a good PR looks like

- Keep the change narrow. Say which observable behavior changes and why.
- Name the smallest verification that proves the change works.
- Do not add compatibility shims for internal APIs. Update every caller instead.
- Update the one document that owns the topic rather than describing it twice.
- Commit intended UI goldens and flow journals together with the behavior change that requires them.
- Keep build artifacts and raw per-utterance benchmark output out of the commit.
