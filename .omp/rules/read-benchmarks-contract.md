---
description: Benchmark tooling is governed by docs/benchmarks.md
condition: '[\s\S]'
interruptMode: never
scope:
  - 'tool:edit(**/bench/**)'
  - 'tool:write(**/bench/**)'
  - 'tool:edit(**/Sources/VoiceourBench/**)'
  - 'tool:write(**/Sources/VoiceourBench/**)'
---
This file is governed by `docs/benchmarks.md`: tiers, `uv --no-config`, row identity, and the paired gate for comparing models. If you have not read it this session, read it before your next edit, check this edit against it, and update it in the same commit when behavior changes.
