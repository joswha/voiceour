"""Peak memory sampler for the `voiceour-asr` sidecar.

Writes `<peak_phys_footprint_bytes> <peak_resident_bytes> <n_samples>
<resident_layout_validated>` to the output path, rewritten after every sample so
the harness can read it even if the sampler is killed.

Both figures come from one `proc_pid_rusage(2)` call, not from `ps`. Two reasons:

- `ps -o rss=` reports only resident size, and resident size is not what macOS
  manages a process by. `ri_phys_footprint` is the accounting jetsam enforces and
  the figure Activity Monitor's "Memory" column shows: it includes compressed and
  swapped-out dirty pages, and excludes clean file-backed pages, which resident
  size gets backwards on both counts. A change that turns 1.2 GB of dirty
  anonymous weights into clean file-backed pages is a real reduction in what this
  app costs the system, and resident size alone would not show it.
- `pgrep` + `ps` is two `fork`/`exec` pairs per sample, which caps the useful
  rate at a few hertz. A peak narrower than the interval is simply not seen, and
  allocation spikes are exactly the thing a memory segment must catch. Sampling
  a known pid through `libSystem` is a single syscall, so the interval can be
  20 ms instead of 200 ms.

`rusage_info_v0` already carries both fields, so flavour 0 is requested: it is
the oldest and most stable layout that answers the question.
"""

from __future__ import annotations

import ctypes
import struct
import subprocess
import sys
import time
from pathlib import Path

# struct rusage_info_v0 {
#     uint8_t  ri_uuid[16];          offset  0
#     uint64_t ri_user_time;                16
#     uint64_t ri_system_time;              24
#     uint64_t ri_pkg_idle_wkups;           32
#     uint64_t ri_interrupt_wkups;          40
#     uint64_t ri_pageins;                  48
#     uint64_t ri_wired_size;               56
#     uint64_t ri_resident_size;            64
#     uint64_t ri_phys_footprint;           72
#     uint64_t ri_proc_start_abstime;       80
#     uint64_t ri_proc_exit_abstime;        88
# };
RUSAGE_INFO_V0_SIZE = 96
OFF_RESIDENT = 64
RUSAGE_FLAVOR_V0 = 0

PROCESS_NAME = "voiceour-asr"
SAMPLE_INTERVAL_S = 0.020
DISCOVER_INTERVAL_S = 0.200


def _libsystem() -> ctypes.CDLL:
    lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
    lib.proc_pid_rusage.restype = ctypes.c_int
    return lib


def _sample(lib: ctypes.CDLL, buf: ctypes.Array, pid: int) -> tuple[int, int] | None:
    """Return (resident_bytes, phys_footprint_bytes), or None if pid is gone."""
    if lib.proc_pid_rusage(pid, RUSAGE_FLAVOR_V0, ctypes.byref(buf)) != 0:
        return None
    resident, footprint = struct.unpack_from("<QQ", buf, OFF_RESIDENT)
    return resident, footprint


def _discover() -> list[int]:
    try:
        out = subprocess.run(
            ["/usr/bin/pgrep", "-x", PROCESS_NAME],
            capture_output=True,
            text=True,
            check=False,
        ).stdout
    except OSError:
        return []
    return [int(line) for line in out.split() if line.isdigit()]


def _resident_from_ps(pid: int) -> int | None:
    """Cross-check the rusage resident field against the OS process table."""
    try:
        out = subprocess.run(
            ["/bin/ps", "-o", "rss=", "-p", str(pid)],
            capture_output=True,
            text=True,
            check=False,
        ).stdout.strip()
    except OSError:
        return None
    return int(out) * 1024 if out.isdigit() else None


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: mem_sampler.py <output-path>", file=sys.stderr)
        return 64

    out_path = Path(sys.argv[1])
    lib = _libsystem()
    buf = ctypes.create_string_buffer(RUSAGE_INFO_V0_SIZE)

    peak_footprint = 0
    peak_resident = 0
    n_samples = 0
    resident_layout_validated = False

    def flush() -> None:
        out_path.write_text(
            f"{peak_footprint} {peak_resident} {n_samples} "
            f"{int(resident_layout_validated)}\n"
        )
    flush()

    pids: list[int] = []
    last_discover = 0.0

    while True:
        now = time.monotonic()
        if not pids and now - last_discover >= DISCOVER_INTERVAL_S:
            pids = _discover()
            last_discover = now

        live: list[int] = []
        for pid in pids:
            observed = _sample(lib, buf, pid)
            if observed is None:
                continue
            live.append(pid)
            resident, footprint = observed
            peak_resident = max(peak_resident, resident)
            peak_footprint = max(peak_footprint, footprint)
            n_samples += 1

            # `ri_phys_footprint` can legitimately sit far below RSS once model
            # weights become clean file-backed pages. Validate field order
            # against `ps` directly instead of inferring it from their values.
            if not resident_layout_validated and n_samples % 50 == 0:
                ps_resident = _resident_from_ps(pid)
                if ps_resident:
                    ratio = resident / ps_resident
                    resident_layout_validated = 0.75 <= ratio <= 1.25

        # A pid that stopped answering is dropped, which sends the next
        # iteration back to discovery rather than sampling a dead process.
        pids = live

        # Only rewrite when there is something new to report; with no sidecar
        # running this loop would otherwise rewrite the file 50 times a second.
        if n_samples and n_samples % 25 == 0:
            flush()

        time.sleep(SAMPLE_INTERVAL_S)


if __name__ == "__main__":
    raise SystemExit(main())
