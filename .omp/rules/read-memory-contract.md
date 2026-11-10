---
description: The memory store is governed by docs/memory.md
condition: '[\s\S]'
interruptMode: never
scope:
  - 'tool:edit(**/Sources/VoiceCore/{MemoryEntry,MemoryStore,MemoryPages,MemoryAgentInstructions}.swift)'
  - 'tool:write(**/Sources/VoiceCore/{MemoryEntry,MemoryStore,MemoryPages,MemoryAgentInstructions}.swift)'
  - 'tool:edit(**/Sources/Voiceour/MemoryJournal.swift)'
  - 'tool:write(**/Sources/Voiceour/MemoryJournal.swift)'
---
This file is governed by `docs/memory.md`: the memory folder and its files, the entry schema, the derived pages, the write planner, when dictations fold in, and what agents may read and write. If you have not read it this session, read it before your next edit, check this edit against it, and update it in the same commit when behavior changes.
