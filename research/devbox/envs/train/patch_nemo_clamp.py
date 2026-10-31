#!/usr/bin/env python3
"""Make NeMo's RNNT/TDT gradient kernels compilable under numba 0.67.

numba 0.67 registers the `min`/`max` builtins through an overload whose impl has
a varargs signature `(*x)`. Under the CUDA target, numba's own FixupArgs pass
then compares that single vararg against the two argument types at the call site
and raises:

    TypeError: Signature mismatch: 2 argument types given, but function takes 1 arguments

The only place this bites is the gradient-clamp block of the RNNT/TDT kernels
(three identical sites), so *every* training step dies while the forward-only
inference path is unaffected. NeMo's shipped TDT config uses clamp=-1.0, so the
block is dead code at run time, but numba still has to type-infer it.

This rewrites `min`/`max` into the exact conditional expressions numba's own
builtins use (`a if a < b else b` / `a if a > b else b`), so behaviour is
identical for every input including NaN. Idempotent.
"""
import sys

TARGET = (
    "/srv/devbox/research/voiceour/envs/train/.venv/lib/python3.12/site-packages/"
    "nemo/collections/asr/parts/numba/rnnt_loss/utils/cuda_utils/gpu_rnnt_kernel.py"
)

OLD = """                g = min(g, clamp)
                g = max(g, -clamp)
"""
NEW = """                # numba 0.67: 2-arg min/max cannot compile under the CUDA target
                # (varargs overload vs FixupArgs); these are numba's own impls.
                g = g if g < clamp else clamp
                g = g if g > -clamp else -clamp
"""


def main():
    src = open(TARGET, encoding="utf-8").read()
    already = src.count("g = g if g < clamp else clamp")
    found = src.count(OLD)
    if already and not found:
        print(f"already patched ({already} sites); nothing to do")
        return 0
    if found != 3:
        print(f"ERROR: expected 3 clamp sites, found {found} (already patched: {already})")
        return 1
    open(TARGET, "w", encoding="utf-8").write(src.replace(OLD, NEW))
    print(f"patched {found} gradient-clamp sites in {TARGET}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
