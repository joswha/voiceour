---
description: Harness capture and settling rules
condition:
  - '(?m)^(?![ \t]*(?:/\*|\*))(?:(?!//)[^\n"]|"(?:[^"\\\n]|\\.)*")*?\b(?:ImageRenderer|bitmapImageRepForCachingDisplay)\b'
  - '(?m)^(?![ \t]*(?:/\*|\*))(?:(?!//)[^\n"]|"(?:[^"\\\n]|\\.)*")*?\b(?:Thread\.sleep|usleep)\('
scope:
  - 'tool:edit(**/Sources/Voiceour/UIHarness/**)'
  - 'tool:write(**/Sources/Voiceour/UIHarness/**)'
---
Harness capture is `cacheDisplay(in:to:)` into an owned RGBA8 `.deviceRGB` bitmap with alpha: `ImageRenderer` stubs AppKit-backed views, and the system caching bitmap drifts with the monitor profile. Settling is the fixed run-loop pump, never a sleep (docs/ui-harness.md › Invariants).
