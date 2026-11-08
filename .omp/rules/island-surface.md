---
description: Recording island clock, drag and pointer rules
condition:
  - '(?m)^(?![ \t]*(?:/\*|\*))(?:(?!//)[^\n"]|"(?:[^"\\\n]|\\.)*")*?\bTimelineView\b'
  - '(?m)^(?![ \t]*(?:/\*|\*))(?:(?!//)[^\n"]|"(?:[^"\\\n]|\\.)*")*?\b(?:performDrag|nextEvent)\('
  - '(?m)^(?![ \t]*(?:/\*|\*))(?:(?!//)[^\n"]|"(?:[^"\\\n]|\\.)*")*?\bignoresMouseEvents[ \t]*=[ \t]*false\b'
scope:
  - 'tool:edit(**/Sources/Voiceour/RecordingOverlay*.swift)'
  - 'tool:write(**/Sources/Voiceour/RecordingOverlay*.swift)'
  - 'tool:edit(**/Sources/Voiceour/Mercury*.swift)'
  - 'tool:write(**/Sources/Voiceour/Mercury*.swift)'
---
Recording island (docs/recording-island.md): `MercurySurfaceView` frames come from `NSView.displayLink(target:selector:)`, never `TimelineView`, a timer or a published SwiftUI clock. Drags are direct manipulation from `mouseDown`/`mouseDragged`/`mouseUp`, never `performDrag` or a nested tracking loop. Only `RecordingOverlayPointerGate` decides `ignoresMouseEvents`; an unconditional `false` turns the whole panel into a click sink.
