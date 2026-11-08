---
description: Text stages and glossary are governed by docs/text-pipeline.md
condition: '[\s\S]'
interruptMode: never
scope:
  - 'tool:edit(**/Sources/VoiceCore/{CandidateRetrieval,CleanupEngine,DictationLanguage,DictationTextStage,Glossary,GlossaryQuery,LiteralComposition,Models,Phonetics,TermSpotting,TermSuggestion,Vocabulary,VocabularyRepair}.swift)'
  - 'tool:write(**/Sources/VoiceCore/{CandidateRetrieval,CleanupEngine,DictationLanguage,DictationTextStage,Glossary,GlossaryQuery,LiteralComposition,Models,Phonetics,TermSpotting,TermSuggestion,Vocabulary,VocabularyRepair}.swift)'
  - 'tool:edit(**/Sources/VoiceCore/Resources/**)'
  - 'tool:write(**/Sources/VoiceCore/Resources/**)'
  - 'tool:edit(**/Sources/VoiceMac/WordListImporter.swift)'
  - 'tool:write(**/Sources/VoiceMac/WordListImporter.swift)'
  - 'tool:edit(**/Sources/Voiceour/{ConsoleGlossaryTab,ConsoleTermEditor,GlossaryAliasParsing}.swift)'
  - 'tool:write(**/Sources/Voiceour/{ConsoleGlossaryTab,ConsoleTermEditor,GlossaryAliasParsing}.swift)'
---
This file is governed by `docs/text-pipeline.md`: term spotting, literal commands, cleanup, repair, language gating and glossary rules. If you have not read it this session, read it before your next edit, check this edit against it, and update it in the same commit when behavior changes.
