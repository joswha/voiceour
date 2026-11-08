---
description: Shipping views use NSGlassEffectView, never SwiftUI glass
condition: '(?m)^(?![ \t]*(?:/\*|\*))(?:(?!//)[^\n"]|"(?:[^"\\\n]|\\.)*")*?(?:\.glassEffect\(|\bGlassEffectContainer\b|\.glassBackgroundEffect\()'
scope:
  - 'tool:edit(**/Sources/Voiceour/**/*.swift)'
  - 'tool:write(**/Sources/Voiceour/**/*.swift)'
---
Shipping views never use SwiftUI `.glassEffect`: the console ground is `NSGlassEffectView(style: .regular)` behind native section plates, and the island is an opaque rasterized body (docs/console-ui.md › Console).
