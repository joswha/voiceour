---
description: The memory store, topics and sorting are governed by docs/memory.md
condition: '[\s\S]'
interruptMode: never
scope:
  - 'tool:edit(**/Sources/VoiceCore/{MemoryEntry,MemoryStore,MemoryPages,MemoryAgentInstructions,AgentNotes,TopicCatalog,EntryOrganizing,TypeSafeJudgment,TypeSafeKeySource}.swift)'
  - 'tool:write(**/Sources/VoiceCore/{MemoryEntry,MemoryStore,MemoryPages,MemoryAgentInstructions,AgentNotes,TopicCatalog,EntryOrganizing,TypeSafeJudgment,TypeSafeKeySource}.swift)'
  - 'tool:edit(**/Sources/Voiceour/{MemoryJournal,MemoryOrganizing}.swift)'
  - 'tool:write(**/Sources/Voiceour/{MemoryJournal,MemoryOrganizing}.swift)'
  - 'tool:edit(**/Sources/VoiceOrganizer/**/*.swift)'
  - 'tool:write(**/Sources/VoiceOrganizer/**/*.swift)'
---
This file is governed by `docs/memory.md`: the memory folder and its files, the entry schema, the derived pages, the write planner, when dictations fold in, topics, the sorting model and its requests, and what agents may read and write. If you have not read it this session, read it before your next edit, check this edit against it, and update it in the same commit when behavior changes.
