---
description: Child-process shutdown stays bounded
condition: '(?m)^(?![ \t]*(?:/\*|\*))(?:(?!//)[^\n"]|"(?:[^"\\\n]|\\.)*")*?\.waitUntilExit\(\)'
scope:
  - 'tool:edit(**/Sources/**/*.swift)'
  - 'tool:write(**/Sources/**/*.swift)'
---
Process teardown uses bounded joins only; never follow a bounded shutdown with Darwin's unbounded `waitUntilExit()` (docs/asr.md › ASR sidecar protocol).
