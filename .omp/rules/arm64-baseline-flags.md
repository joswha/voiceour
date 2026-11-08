---
description: Builds target the arm64 baseline, not the build machine
condition: '-m(?:cpu|arch|tune)=native'
scope:
  - 'tool:edit(**/Package.swift)'
  - 'tool:write(**/Package.swift)'
  - 'tool:edit(**/Makefile)'
  - 'tool:write(**/Makefile)'
  - 'tool:edit(**/scripts/**)'
  - 'tool:write(**/scripts/**)'
---
Builds target the arm64 baseline: never add `-mcpu=native` (or `-march`/`-mtune=native`) and never attempt a universal build (docs/asr.md › Model contract and vendor rules).
