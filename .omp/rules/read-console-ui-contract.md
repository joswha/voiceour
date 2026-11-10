---
description: Console, Journal and menu UI are governed by docs/console-ui.md
condition: '[\s\S]'
interruptMode: never
scope:
  - 'tool:edit(**/Sources/Voiceour/{Console*,Menu*,History*,Journal*,Home*,DesignToken*,GlassMarks,MeterBar,AppIdentity,ActivityHeatmap,SelectableTranscriptText,CaptionText,SessionFormatting,StatsFormatting,SettingsBindings,PrimaryActionButtonStyle,A11yEnvironment}.swift)'
  - 'tool:write(**/Sources/Voiceour/{Console*,Menu*,History*,Journal*,Home*,DesignToken*,GlassMarks,MeterBar,AppIdentity,ActivityHeatmap,SelectableTranscriptText,CaptionText,SessionFormatting,StatsFormatting,SettingsBindings,PrimaryActionButtonStyle,A11yEnvironment}.swift)'
  - 'tool:edit(**/Sources/VoiceMac/InstalledAppCatalog.swift)'
  - 'tool:write(**/Sources/VoiceMac/InstalledAppCatalog.swift)'
  - 'tool:edit(**/Sources/VoiceCore/{AppDisplayName,RecentSessionQuery,Journal}.swift)'
  - 'tool:write(**/Sources/VoiceCore/{AppDisplayName,RecentSessionQuery,Journal}.swift)'
---
This file is governed by `docs/console-ui.md`: native console controls, the Journal tab and its lenses, the menu and the visual vocabulary. If you have not read it this session, read it before your next edit, check this edit against it, and update it in the same commit when behavior changes.
