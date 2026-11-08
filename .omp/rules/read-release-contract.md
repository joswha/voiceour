---
description: Versioning, signing and release scripts are governed by docs/release.md
condition: '[\s\S]'
interruptMode: never
scope:
  - 'tool:edit(**/scripts/{release,sign_notarize,bundle,verify_bundle}.sh)'
  - 'tool:write(**/scripts/{release,sign_notarize,bundle,verify_bundle}.sh)'
  - 'tool:edit(**/Resources/Info.plist)'
  - 'tool:write(**/Resources/Info.plist)'
  - 'tool:edit(**/.github/workflows/**)'
  - 'tool:write(**/.github/workflows/**)'
---
This file is governed by `docs/release.md`: version ownership, preflight, binary packaging and the maintainer sequence; tags and publication need the user's authorization in the current conversation. If you have not read it this session, read it before your next edit, check this edit against it, and update it in the same commit when behavior changes.
