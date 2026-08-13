from __future__ import annotations

__all__ = ["ArkASR", "TranscriptionResult"]


def __getattr__(name: str):
    if name == "ArkASR":
        from .api import ArkASR

        return ArkASR
    if name == "TranscriptionResult":
        from .generation import TranscriptionResult

        return TranscriptionResult
    raise AttributeError(name)
