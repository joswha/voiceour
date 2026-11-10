---
description: Console, Journal, kit, themes and menu UI are governed by docs/console-ui.md
condition: '[\s\S]'
interruptMode: never
scope:
  - 'tool:edit(**/Sources/Voiceour/{Console*,Menu*,Journal*,Kit*,Home*,Settings*,Theme*,DesignToken*,AppIdentity,ActivityHeatmap,SelectableTranscriptText,SessionFormatting,StatsFormatting,PrimaryActionButtonStyle,A11yEnvironment}.swift)'
  - 'tool:write(**/Sources/Voiceour/{Console*,Menu*,Journal*,Kit*,Home*,Settings*,Theme*,DesignToken*,AppIdentity,ActivityHeatmap,SelectableTranscriptText,SessionFormatting,StatsFormatting,PrimaryActionButtonStyle,A11yEnvironment}.swift)'
  - 'tool:edit(**/Sources/VoiceMac/InstalledAppCatalog.swift)'
  - 'tool:write(**/Sources/VoiceMac/InstalledAppCatalog.swift)'
  - 'tool:edit(**/Sources/VoiceCore/{AppDisplayName,RecentSessionQuery,Journal,ConsoleAppearance}.swift)'
  - 'tool:write(**/Sources/VoiceCore/{AppDisplayName,RecentSessionQuery,Journal,ConsoleAppearance}.swift)'
---
This file is governed by `docs/console-ui.md`: the console window and its tabs, the component kit, the theme (appearance and accent), the Journal and its lenses, the menu and the visual vocabulary. If you have not read it this session, read it before your next edit, check this edit against it, and update it in the same commit when behavior changes.
