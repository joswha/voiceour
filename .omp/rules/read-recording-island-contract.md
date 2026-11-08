---
description: The recording island is governed by docs/recording-island.md
condition: '[\s\S]'
interruptMode: never
scope:
  - 'tool:edit(**/Sources/Voiceour/{RecordingOverlay*,Mercury*,IslandGarageEditor,ConsoleIslandSection}.swift)'
  - 'tool:write(**/Sources/Voiceour/{RecordingOverlay*,Mercury*,IslandGarageEditor,ConsoleIslandSection}.swift)'
  - 'tool:edit(**/Sources/VoiceCore/{IslandAppearance,MercuryWorld}.swift)'
  - 'tool:write(**/Sources/VoiceCore/{IslandAppearance,MercuryWorld}.swift)'
---
This file is governed by `docs/recording-island.md`; renderer changes also update `docs/mercury-renderer.md` and pass `make ui-mercury-bench`. If you have not read it this session, read it before your next edit, check this edit against it, and update it in the same commit when behavior changes.
