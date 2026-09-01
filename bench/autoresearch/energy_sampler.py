#!/usr/bin/env python3
"""Wrap one subprocess with an unprivileged IOReport Energy Model delta.

Ported verbatim from the session's proven sampler
(.build/asr-research/three-bets/coreml/ioreport_energy.py). Values are
system-wide rail deltas over the command's lifetime: attributable only under
the harness's exclusive-hardware discipline. compute_j = cpu + gpu + ane.
"""
from __future__ import annotations

import ctypes
import json
import sys
import time
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import TypeVar

_T = TypeVar("_T")
_UTF8 = 0x08000100

_io = ctypes.CDLL("/usr/lib/libIOReport.dylib")
_cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")

_io.IOReportCopyAllChannels.argtypes = [ctypes.c_uint64, ctypes.c_uint64]
_io.IOReportCopyAllChannels.restype = ctypes.c_void_p
_io.IOReportCreateSubscription.argtypes = [
    ctypes.c_void_p,
    ctypes.c_void_p,
    ctypes.POINTER(ctypes.c_void_p),
    ctypes.c_uint64,
    ctypes.c_void_p,
]
_io.IOReportCreateSubscription.restype = ctypes.c_void_p
_io.IOReportCreateSamples.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
_io.IOReportCreateSamples.restype = ctypes.c_void_p
_io.IOReportCreateSamplesDelta.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
_io.IOReportCreateSamplesDelta.restype = ctypes.c_void_p
for _name in (
    "IOReportChannelGetGroup",
    "IOReportChannelGetSubGroup",
    "IOReportChannelGetChannelName",
    "IOReportChannelGetUnitLabel",
):
    _function = getattr(_io, _name)
    _function.argtypes = [ctypes.c_void_p]
    _function.restype = ctypes.c_void_p
_io.IOReportSimpleGetIntegerValue.argtypes = [ctypes.c_void_p, ctypes.c_int]
_io.IOReportSimpleGetIntegerValue.restype = ctypes.c_int64

_cf.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
_cf.CFStringCreateWithCString.restype = ctypes.c_void_p
_cf.CFStringGetCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32]
_cf.CFStringGetCString.restype = ctypes.c_bool
_cf.CFDictionaryGetValue.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
_cf.CFDictionaryGetValue.restype = ctypes.c_void_p
_cf.CFDictionaryGetCount.argtypes = [ctypes.c_void_p]
_cf.CFDictionaryGetCount.restype = ctypes.c_long
_cf.CFDictionaryCreateMutableCopy.argtypes = [ctypes.c_void_p, ctypes.c_long, ctypes.c_void_p]
_cf.CFDictionaryCreateMutableCopy.restype = ctypes.c_void_p
_cf.CFDictionarySetValue.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
_cf.CFDictionarySetValue.restype = None
_cf.CFArrayGetCount.argtypes = [ctypes.c_void_p]
_cf.CFArrayGetCount.restype = ctypes.c_long
_cf.CFArrayGetValueAtIndex.argtypes = [ctypes.c_void_p, ctypes.c_long]
_cf.CFArrayGetValueAtIndex.restype = ctypes.c_void_p
_cf.CFArrayCreateMutable.argtypes = [ctypes.c_void_p, ctypes.c_long, ctypes.c_void_p]
_cf.CFArrayCreateMutable.restype = ctypes.c_void_p
_cf.CFArrayAppendValue.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
_cf.CFArrayAppendValue.restype = None
_cf.CFRelease.argtypes = [ctypes.c_void_p]
_cf.CFRelease.restype = None


def _cf_string(value: str) -> ctypes.c_void_p:
    return ctypes.c_void_p(_cf.CFStringCreateWithCString(None, value.encode(), _UTF8))


def _python_string(value: int | None) -> str:
    if not value:
        return ""
    buffer = ctypes.create_string_buffer(512)
    if not _cf.CFStringGetCString(value, buffer, len(buffer), _UTF8):
        return ""
    return buffer.value.decode("utf-8", errors="replace").strip()


_CHANNELS_KEY = _cf_string("IOReportChannels")
class _CFArrayCallBacks(ctypes.Structure):
    _fields_ = [
        ("version", ctypes.c_long),
        ("retain", ctypes.c_void_p),
        ("release", ctypes.c_void_p),
        ("copy_description", ctypes.c_void_p),
        ("equal", ctypes.c_void_p),
    ]


_TYPE_ARRAY_CALLBACKS = _CFArrayCallBacks.in_dll(_cf, "kCFTypeArrayCallBacks")


@dataclass
class RawSample:
    pointer: int
    monotonic_ns: int


class EnergySampler:
    """Unprivileged system-wide IOReport Energy Model sampler.

    Values are rail energy deltas. They include every process active between the two
    samples, so a short-window result is a system-energy observation, not a per-process
    attribution. Interleaving variants and repeating reduces slow background drift.
    """

    def __init__(self) -> None:
        self._source_channels = int(_io.IOReportCopyAllChannels(0, 0) or 0)
        if not self._source_channels:
            raise RuntimeError("IOReportCopyAllChannels returned null")
        source_array = int(_cf.CFDictionaryGetValue(self._source_channels, _CHANNELS_KEY) or 0)
        if not source_array:
            _cf.CFRelease(self._source_channels)
            raise RuntimeError("IOReport channel dictionary has no IOReportChannels")
        count = int(_cf.CFArrayGetCount(source_array))
        self._selected = int(
            _cf.CFArrayCreateMutable(None, count, ctypes.byref(_TYPE_ARRAY_CALLBACKS)) or 0
        )
        if not self._selected:
            _cf.CFRelease(self._source_channels)
            raise RuntimeError("CFArrayCreateMutable returned null")
        for index in range(count):
            item = int(_cf.CFArrayGetValueAtIndex(source_array, index) or 0)
            if not item or _python_string(_io.IOReportChannelGetGroup(item)) != "Energy Model":
                continue
            channel = _python_string(_io.IOReportChannelGetChannelName(item))
            if (
                channel.endswith("CPU Energy")
                or channel == "GPU Energy"
                or channel.startswith("ANE")
                or channel.startswith("DRAM")
                or channel.startswith("GPU SRAM")
            ):
                _cf.CFArrayAppendValue(self._selected, item)
        selected_count = int(_cf.CFArrayGetCount(self._selected))
        if selected_count == 0:
            _cf.CFRelease(self._selected)
            _cf.CFRelease(self._source_channels)
            raise RuntimeError("no Energy Model channels are available")
        self._channels = int(
            _cf.CFDictionaryCreateMutableCopy(
                None,
                int(_cf.CFDictionaryGetCount(self._source_channels)),
                self._source_channels,
            )
            or 0
        )
        if not self._channels:
            _cf.CFRelease(self._selected)
            _cf.CFRelease(self._source_channels)
            raise RuntimeError("CFDictionaryCreateMutableCopy returned null")
        _cf.CFDictionarySetValue(self._channels, _CHANNELS_KEY, self._selected)
        subscribed_channels = ctypes.c_void_p()
        self._subscription = int(
            _io.IOReportCreateSubscription(
                None,
                self._channels,
                ctypes.byref(subscribed_channels),
                0,
                None,
            )
            or 0
        )
        if not self._subscription:
            self.close()
            raise RuntimeError("IOReportCreateSubscription returned null")

    def close(self) -> None:
        if getattr(self, "_subscription", 0):
            _cf.CFRelease(self._subscription)
            self._subscription = 0
        if getattr(self, "_channels", 0):
            _cf.CFRelease(self._channels)
            self._channels = 0
        if getattr(self, "_selected", 0):
            _cf.CFRelease(self._selected)
            self._selected = 0
        if getattr(self, "_source_channels", 0):
            _cf.CFRelease(self._source_channels)
            self._source_channels = 0

    def __enter__(self) -> EnergySampler:
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def sample(self) -> RawSample:
        pointer = int(_io.IOReportCreateSamples(self._subscription, self._channels, None) or 0)
        sampled_ns = time.monotonic_ns()
        if not pointer:
            raise RuntimeError("IOReportCreateSamples returned null")
        return RawSample(pointer=pointer, monotonic_ns=sampled_ns)

    def delta(self, before: RawSample, after: RawSample) -> dict[str, object]:
        delta_pointer = int(_io.IOReportCreateSamplesDelta(before.pointer, after.pointer, None) or 0)
        _cf.CFRelease(before.pointer)
        _cf.CFRelease(after.pointer)
        if not delta_pointer:
            raise RuntimeError("IOReportCreateSamplesDelta returned null")
        try:
            channel_array = int(_cf.CFDictionaryGetValue(delta_pointer, _CHANNELS_KEY) or 0)
            if not channel_array:
                raise RuntimeError("IOReport delta has no IOReportChannels")
            channels: list[dict[str, object]] = []
            count = int(_cf.CFArrayGetCount(channel_array))
            for index in range(count):
                item = int(_cf.CFArrayGetValueAtIndex(channel_array, index) or 0)
                if not item:
                    continue
                group = _python_string(_io.IOReportChannelGetGroup(item))
                if group != "Energy Model":
                    continue
                channel = _python_string(_io.IOReportChannelGetChannelName(item))
                unit = _python_string(_io.IOReportChannelGetUnitLabel(item))
                raw = int(_io.IOReportSimpleGetIntegerValue(item, 0))
                factor = {"mJ": 1e-3, "uJ": 1e-6, "nJ": 1e-9}.get(unit)
                joules = raw * factor if factor is not None else None
                channels.append({"channel": channel, "unit": unit, "raw": raw, "joules": joules})
            rails = {"cpu_j": 0.0, "gpu_j": 0.0, "ane_j": 0.0, "dram_j": 0.0, "gpu_sram_j": 0.0}
            for item in channels:
                value = item["joules"]
                if value is None:
                    continue
                channel = str(item["channel"])
                if channel.endswith("CPU Energy"):
                    rails["cpu_j"] += float(value)
                elif channel == "GPU Energy":
                    rails["gpu_j"] += float(value)
                elif channel.startswith("ANE"):
                    rails["ane_j"] += float(value)
                elif channel.startswith("DRAM"):
                    rails["dram_j"] += float(value)
                elif channel.startswith("GPU SRAM"):
                    rails["gpu_sram_j"] += float(value)
            rails["compute_j"] = rails["cpu_j"] + rails["gpu_j"] + rails["ane_j"]
            return {
                "elapsed_ms": (after.monotonic_ns - before.monotonic_ns) / 1e6,
                "rails": rails,
                "channels": channels,
            }
        finally:
            _cf.CFRelease(delta_pointer)

    def measure(self, operation: Callable[[], _T]) -> tuple[_T, dict[str, object]]:
        before = self.sample()
        result = operation()
        after = self.sample()
        return result, self.delta(before, after)


def main() -> int:
    import argparse
    import subprocess

    parser = argparse.ArgumentParser(
        description="Wrap a command with an IOReport Energy Model delta."
    )
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        raise SystemExit("energy_sampler.py: no command given")

    with EnergySampler() as sampler:
        before = sampler.sample()
        started = time.monotonic_ns()
        completed = subprocess.run(command)
        elapsed_ns = time.monotonic_ns() - started
        after = sampler.sample()
        delta = sampler.delta(before, after)

    payload = {
        "command_exit": completed.returncode,
        "command_elapsed_ms": elapsed_ns / 1e6,
        "window_elapsed_ms": delta["elapsed_ms"],
        "rails": delta["rails"],
        "channels": delta["channels"],
    }
    args.output.write_text(json.dumps(payload, indent=1, sort_keys=True) + "\n")
    return completed.returncode


if __name__ == "__main__":
    sys.exit(main())
