## What changes

<!-- The observable behavior that is different after this PR, and why. Not a file list. -->

## Verification

<!-- The smallest command or scenario that proves it works, and its result. -->

## Checklist

- [ ] `make build` `make format-check` `make check-docs` `make lint-python` `make test` pass
- [ ] `make ui-flow` passes; if the UI changed, `make ui-snap` too, and I read the `.ax.diff` / `.flow.diff` before blessing any golden
- [ ] Intended UI goldens and flow journals are committed with the behavior change that requires them
- [ ] Every caller is migrated — no compatibility shim, alias, or deprecated path left behind
- [ ] The one document that owns this topic is updated (`README.md`, `docs/architecture.md`, `docs/permissions.md`, `docs/benchmarks.md`, `docs/ui-harness.md`, or `docs/developer-setup.md`)
- [ ] No build artifact or raw per-utterance benchmark output is in the diff

If this change touches the microphone, the model, the hotkey, insertion, entitlements, or signing, say which real-device check you ran — those paths cannot be proved by the fake backend.
