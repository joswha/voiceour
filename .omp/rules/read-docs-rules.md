---
description: Editing docs and omp rules follows the documentation ownership rules
condition: '[\s\S]'
interruptMode: never
scope:
  - 'tool:edit(**/*.md)'
  - 'tool:write(**/*.md)'
---
Documentation rules for this repository:
- README.md owns the product contract: behavior, architecture, data, model/network, safety, development, verification. AGENTS.md is the map: boundaries, commands, git. `.omp/RULES.md` holds only invariants that bind every change. Each contract doc in the AGENTS.md Contracts list owns its subsystem's engineering rules.
- `.omp/rules/` holds omp trigger rules: bans that block an edit introducing a forbidden pattern, and read-first pointers that name the contract doc on the first edit to its files. Keep their scopes in step with the AGENTS.md Contracts list, and check a changed rule with `omp ttsr test` and `omp ttsr scan`.
- Evidence docs — `docs/mercury-renderer.md` (derivations), `docs/benchmarks.md`, `docs/performance-roadmap.md` and `research/` (measurements) — link back to the contract they serve; NEVER redefine product policy or promote dated evidence into shipping claims.
- `CONTRIBUTING.md`: PR gates. `SECURITY.md`: reporting. `CHANGELOG.md`: user-visible changes/release notes.
- One owner per topic; link elsewhere. Declarative current-state prose, not deletion history. Archive useful superseded records under `docs/archive/` with date/notice; `docs/superpowers/` contains historical plans. NEVER add new plan/redirect documents.
- Every documented command MUST exist. `make check-docs` checks model pins and make/script references in roots, CONTRIBUTING, top-level docs. Preserve linked headings.
