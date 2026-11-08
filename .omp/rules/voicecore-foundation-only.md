---
description: VoiceCore imports Foundation only
condition: '(?m)^[ \t]*(?:@\w+[ \t]+)*import[ \t]+(?:(?:struct|class|enum|protocol|func|var|let|typealias)[ \t]+)?(?:AppKit|SwiftUI|AVFoundation|AVFAudio|AVKit|ApplicationServices|Carbon|CoreAudio|CoreGraphics|IOKit|Security|Network)\b'
scope:
  - 'tool:edit(**/Sources/VoiceCore/**/*.swift)'
  - 'tool:write(**/Sources/VoiceCore/**/*.swift)'
---
`VoiceCore` imports Foundation only. AppKit, SwiftUI, AVFoundation, Accessibility, event posting, pasteboard, process launch and Keychain belong in `VoiceMac`, behind a small protocol that `VoiceCore` declares and the app injects (AGENTS.md › Architecture boundaries).
