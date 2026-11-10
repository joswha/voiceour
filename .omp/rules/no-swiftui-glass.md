---
description: No view uses SwiftUI glass
condition: '(?m)^(?![ \t]*(?:/\*|\*))(?:(?!//)[^\n"]|"(?:[^"\\\n]|\\.)*")*?(?:\.glassEffect\(|\bGlassEffectContainer\b|\.glassBackgroundEffect\()'
scope:
  - 'tool:edit(**/Sources/Voiceour/**/*.swift)'
  - 'tool:write(**/Sources/Voiceour/**/*.swift)'
---
No view calls `.glassEffect`, `GlassEffectContainer` or `.glassBackgroundEffect`, the component kit (`Sources/Voiceour/Kit*.swift`) included: the console and the menu paint opaque theme surfaces (`@Environment(\.theme)`), because glass samples whatever lies under it, so no contrast can be promised on it, and the offscreen harness cannot capture it. The console window's chrome stays `ConsoleGlassGround` (`NSGlassEffectView(style: .regular)`, AppKit), and the island stays an opaque rasterized body (docs/console-ui.md › Console).
