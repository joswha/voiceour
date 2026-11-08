---
description: Island controls stage and commit through IslandGarageEditor
condition: '(?m)^(?![ \t]*(?:/\*|\*))(?:(?!//)[^\n"]|"(?:[^"\\\n]|\\.)*")*?\bsettingBinding\('
scope:
  - 'tool:edit(**/Sources/Voiceour/ConsoleIslandSection.swift)'
  - 'tool:write(**/Sources/Voiceour/ConsoleIslandSection.swift)'
  - 'tool:edit(**/Sources/Voiceour/IslandGarageEditor.swift)'
  - 'tool:write(**/Sources/Voiceour/IslandGarageEditor.swift)'
---
Island controls stage a draft with `stageIsland`; `IslandGarageEditor` alone commits it with `commitIsland`, one save and one undo step per commit. Never `settingBinding` for island controls (docs/recording-island.md, garage writes).
