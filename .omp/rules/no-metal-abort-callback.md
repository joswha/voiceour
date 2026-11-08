---
description: Granite never installs a Metal abort callback
condition: '\bggml_backend_metal_set_abort_callback\b'
scope:
  - 'tool:edit(**/Vendor/granite/**)'
  - 'tool:write(**/Vendor/granite/**)'
  - 'tool:edit(**/Sources/ASRSidecarCore/**)'
  - 'tool:write(**/Sources/ASRSidecarCore/**)'
---
Never install a Metal abort callback: the vendored Metal backend runs `n_cb=3`. Cancellation polls only at `granite.h` stage boundaries, so a cancel can wait one full graph compute (docs/asr.md › Model contract and vendor rules).
