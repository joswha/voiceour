## What changes

<!-- The observable behavior that is different after this PR, and why. Not a file list. -->

## Verification

<!-- The smallest command or scenario that proves it works, and its result. -->

## Checklist

- [ ] `make check` passes
- [ ] If the UI changed, `make ui-snap` too, and I read the `.ax.diff` / `.flow.diff` before blessing any golden
- [ ] Intended UI goldens and flow journals are committed with the behavior change that requires them
- [ ] Every caller is migrated — no compatibility shim, alias, or deprecated path left behind
- [ ] The authoritative contract is updated (`README.md` for product behavior; `AGENTS.md` for engineering invariants), with specialist evidence/docs updated where relevant
- [ ] No build artifact or raw per-utterance benchmark output is in the diff

If this change touches the microphone, the model, the hotkey, insertion, entitlements, or signing, say which real-device check you ran — those paths cannot be proved by the fake backend.
