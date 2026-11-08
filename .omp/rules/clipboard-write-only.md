---
description: The clipboard is write-only
condition: '(?m)^(?![ \t]*(?:/\*|\*))(?:(?!//)[^\n"]|"(?:[^"\\\n]|\\.)*")*?(?:\.(?:string|data|propertyList)\(forType:|\.readObjects\(|\.pasteboardItems\b|\.canReadObject\(|\.availableType\(from:)'
scope:
  - 'tool:edit(**/Sources/**/*.swift)'
  - 'tool:write(**/Sources/**/*.swift)'
---
Voiceour writes the transcript to the clipboard through `GeneralPasteboard` and never reads, saves or restores what was there before (docs/runtime.md › Privacy and insertion safety).
