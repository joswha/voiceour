---
description: The app's only network path is the Granite model download
condition: '(?m)^(?![ \t]*(?:/\*|\*))(?:(?!//)[^\n"]|"(?:[^"\\\n]|\\.)*")*?\b(?:URLSession|URLRequest|NWConnection|NWListener|NWPathMonitor|NSURLConnection|WKWebView|import[ \t]+Network)\b'
scope:
  - 'tool:edit(**/Sources/VoiceCore/**/*.swift)'
  - 'tool:write(**/Sources/VoiceCore/**/*.swift)'
  - 'tool:edit(**/Sources/VoiceMac/**/*.swift)'
  - 'tool:write(**/Sources/VoiceMac/**/*.swift)'
  - 'tool:edit(**/Sources/Voiceour/**/*.swift)'
  - 'tool:write(**/Sources/Voiceour/**/*.swift)'
  - 'tool:edit(**/Sources/VoiceourASR/**)'
  - 'tool:write(**/Sources/VoiceourASR/**)'
---
The app's only network access is the pinned Granite download in `ModelCache` (`ASRSidecarCore`). No network text processing, telemetry, crash reporting, accounts, update checks or arbitrary URLs (docs/runtime.md › Local-first and network policy).
