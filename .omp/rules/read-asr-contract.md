---
description: The sidecar, model and vendored sources are governed by docs/asr.md
condition: '[\s\S]'
interruptMode: never
scope:
  - 'tool:edit(**/Sources/{ASRSidecarCore,VoiceourASR,ASRSidecarStub}/**)'
  - 'tool:write(**/Sources/{ASRSidecarCore,VoiceourASR,ASRSidecarStub}/**)'
  - 'tool:edit(**/Sources/VoiceCore/ASRProtocol.swift)'
  - 'tool:write(**/Sources/VoiceCore/ASRProtocol.swift)'
  - 'tool:edit(**/Sources/VoiceMac/{SidecarASRClient,ASRBackendRegistry,ProcessLineIO,RetiredModelCacheSweep}.swift)'
  - 'tool:write(**/Sources/VoiceMac/{SidecarASRClient,ASRBackendRegistry,ProcessLineIO,RetiredModelCacheSweep}.swift)'
  - 'tool:edit(**/Vendor/**)'
  - 'tool:write(**/Vendor/**)'
  - 'tool:edit(**/fixtures/protocol/**)'
  - 'tool:write(**/fixtures/protocol/**)'
---
This file is governed by `docs/asr.md`: the NDJSON protocol, the Granite model contract and the vendor patch rules; protocol models, client/server encoding and `fixtures/protocol/` change together. If you have not read it this session, read it before your next edit, check this edit against it, and update it in the same commit when behavior changes.
