---
description: Sliders never use minimum/maximum value labels
condition: '(?m)^(?![ \t]*(?:/\*|\*))(?:(?!//)[^\n"]|"(?:[^"\\\n]|\\.)*")*?\b(?:minimumValueLabel|maximumValueLabel)\b'
scope:
  - 'tool:edit(**/Sources/Voiceour/**/*.swift)'
  - 'tool:write(**/Sources/Voiceour/**/*.swift)'
---
Sliders use integer UI units with an explicit `step`, `.labelsHidden()` plus `.accessibilityLabel`/`.accessibilityValue`, and a trailing monospaced readout hidden from accessibility. `minimumValueLabel`/`maximumValueLabel` publish tiny step buttons that fail the `tiny-hit-target` lint (docs/console-ui.md › Console).
