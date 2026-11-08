---
description: The offscreen UI harness is governed by docs/ui-harness.md
condition: '[\s\S]'
interruptMode: never
scope:
  - 'tool:edit(**/Sources/Voiceour/UIHarness/**)'
  - 'tool:write(**/Sources/Voiceour/UIHarness/**)'
  - 'tool:edit(**/Sources/Voiceour/RenderOverrides.swift)'
  - 'tool:write(**/Sources/Voiceour/RenderOverrides.swift)'
  - 'tool:edit(**/fixtures/ui/**)'
  - 'tool:write(**/fixtures/ui/**)'
  - 'tool:edit(**/scripts/{ui_harness,console_shot}.sh)'
  - 'tool:write(**/scripts/{ui_harness,console_shot}.sh)'
---
This file is governed by `docs/ui-harness.md` and its Invariants: offscreen-only capture, the fixed pump, behavior-neutral `RenderOverrides`, and blessing rules. If you have not read it this session, read it before your next edit, check this edit against it, and update it in the same commit when behavior changes.
