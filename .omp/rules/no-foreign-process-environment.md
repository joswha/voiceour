---
description: Voiceour never reads another process's argv or environment
condition: '(?m)^(?![ \t]*(?:/\*|\*))(?:(?!//)[^\n"]|"(?:[^"\\\n]|\\.)*")*?\b(?:KERN_PROCARGS2?|KERN_PROCENV)\b'
scope:
  - 'tool:edit(**/Sources/**/*.swift)'
  - 'tool:write(**/Sources/**/*.swift)'
---
Agent session binding reads another process only through its process-table entry, executable path and open file paths, and never reads its argv or environment (docs/runtime.md › Agent session binding).
