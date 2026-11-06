"""Multi-process worker functions for `patch_nso.py` on Windows.

`patch_nso.py` calls `in_parallel(x18_words, pieces)` and
`in_parallel(spin_heads_with_region, jobs)` at module top level using
`multiprocessing.get_context('fork').Pool`.

On Windows there is no `fork()`, and a thread pool is serialized by the Python GIL because
`x18_words` and `spin_heads_with_region` spend most of their time in Python loops, regexes
and graph walks. Spawning worker processes against this standalone module avoids re-importing
`patch_nso.py` at top level while giving each worker its own GIL and Capstone instance, reading
`IMG` zero-copy from a read-only `mmap` mapping.
"""
from __future__ import annotations

import marshal
import mmap
import pickle
import re
import struct
import types

from capstone import CS_ARCH_ARM64, CS_MODE_ARM, Cs
from capstone.arm64 import ARM64_OP_IMM, ARM64_OP_MEM, ARM64_OP_REG

_FILE = None
_MM: mmap.mmap | bytes = b''
_MD_LITE: Cs | None = None
_R18 = re.compile(r'\b[xw]18\b')
_SPIN_FN = None


def _close_mmap() -> None:
    global _FILE, _MM
    if _FILE is not None:
        try:
            _MM.close()  # type: ignore[union-attr]
        except Exception:
            pass
        try:
            _FILE.close()
        except Exception:
            pass
        _FILE = None
        _MM = b''


def _attach_mmap(img_path: str) -> None:
    global _FILE, _MM
    _close_mmap()
    _FILE = open(img_path, 'rb')
    _MM = mmap.mmap(_FILE.fileno(), 0, access=mmap.ACCESS_READ)


def init_x18(img_path: str) -> None:
    """Initializer for `x18_words` worker processes."""
    global _MD_LITE
    _attach_mmap(img_path)
    if _MD_LITE is None:
        _MD_LITE = Cs(CS_ARCH_ARM64, CS_MODE_ARM)


def run_x18_job(job: tuple[int, int]) -> set[int]:
    """Execute `x18_words(lo, hi)` in a separate process with its own GIL."""
    lo, hi = job
    md = _MD_LITE or Cs(CS_ARCH_ARM64, CS_MODE_ARM)
    img = _MM
    r18 = _R18
    out: set[int] = set()
    a = lo
    while a < hi:
        end = min(hi, a + 0x4000)
        last = a - 4
        for addr, _sz, _mn, op in md.disasm_lite(img[a:end], a):
            last = addr
            if r18.search(op):
                out.add(addr)
        a = last + 4 if last + 4 >= end else last + 8
    return out


def init_spin(img_path: str, state_path: str) -> None:
    """Initializer for `spin_heads_with_region` worker processes."""
    global _SPIN_FN
    _attach_mmap(img_path)
    with open(state_path, 'rb') as sf:
        codes_blob, state = pickle.load(sf)

    img = _MM
    md_detail = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
    md_detail.detail = True
    dec: dict[int, object] = {}

    def spin_ins(a: int, _dec=dec, _md=md_detail, _img=img):
        if a not in _dec:
            _dec[a] = next(_md.disasm(_img[a:a + 4], a), None)
        return _dec[a]

    class SpinNo(Exception):
        pass

    wg: dict[str, object] = {
        '__builtins__': __builtins__,
        're': re,
        'struct': struct,
        'ARM64_OP_REG': ARM64_OP_REG,
        'ARM64_OP_IMM': ARM64_OP_IMM,
        'ARM64_OP_MEM': ARM64_OP_MEM,
        'IMG': img,
        'md': md_detail,
        'spin_dec': dec,
        'spin_ins': spin_ins,
        'SpinNo': SpinNo,
    }
    wg.update(state)
    codes = marshal.loads(codes_blob)
    for fname, (code_obj, defaults) in codes.items():
        wg[fname] = types.FunctionType(code_obj, wg, fname, defaults)
    _SPIN_FN = wg['spin_heads_with_region']


def run_spin_job(job: tuple[int, int]) -> list[int]:
    """Execute `spin_heads_with_region(first, step)` in a separate process."""
    return _SPIN_FN(*job)  # type: ignore[misc]
