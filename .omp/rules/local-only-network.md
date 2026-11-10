---
description: Network code lives only in the Granite model download and the opt-in TypeSafe label client
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
This target opens no connection. The app's network access is the pinned Granite download in `ModelCache` (`ASRSidecarCore`) and, only while Sort entries with Jev is on and a TypeSafe key is set, label requests from `TypeSafeOrganizer` (`VoiceOrganizer`) to the fixed endpoint `https://api.typesafe.ai/v1/systemone`; the app reaches that client only through `EntryOrganizing`. No model rewrites text, and there is no telemetry, crash reporting, account, update check, configurable base URL or arbitrary URL (docs/runtime.md › Local-first and network policy).
