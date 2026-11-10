---
description: Only the component kit uses SwiftUI glass
condition: '(?m)^(?![ \t]*(?:/\*|\*))(?:(?!//)[^\n"]|"(?:[^"\\\n]|\\.)*")*?(?:\.glassEffect\(|\bGlassEffectContainer\b|\.glassBackgroundEffect\()'
scope:
  - 'tool:edit(**/Sources/Voiceour/{[!K]*,K[!i]*,Ki[!t]*}.swift)'
  - 'tool:write(**/Sources/Voiceour/{[!K]*,K[!i]*,Ki[!t]*}.swift)'
  - 'tool:edit(**/Sources/Voiceour/*/**/*.swift)'
  - 'tool:write(**/Sources/Voiceour/*/**/*.swift)'
---
SwiftUI glass lives only in the component kit, `Sources/Voiceour/Kit*.swift`, and only over the Journal's opaque ground: glass never samples `ConsoleGlassGround`. Every other view composes kit components and never calls `.glassEffect`, `GlassEffectContainer` or `.glassBackgroundEffect` itself; the console ground stays `NSGlassEffectView(style: .regular)`, and the island stays an opaque rasterized body (docs/console-ui.md › Kit).
