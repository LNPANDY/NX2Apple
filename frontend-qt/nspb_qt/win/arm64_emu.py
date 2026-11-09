"""Lightweight ARM64 user-mode emulator (Unicorn) for running Switch NSO decoder/compiler routines on Windows.

Upstream runs the game's own ARM64 Oodle / LZ5 decoders and GLSLC compiler in the Mac host
(`dm/host/hle_oodle.c`, `dm/host/hle_glslc.c`). On Windows (x86_64), this module loads the
required NSO module(s), applies ELF dynamic relocations (`R_AARCH64_RELATIVE`, `ABS64`,
`GLOB_DAT`, `JUMP_SLOT`, and `DT_RELR`), and executes pure computation routines inside Unicorn.

Performance architecture:
1. In-VM Native ARM64 Fast Stubs (`FAST_BASE`):
   Standard C memory, string, sorting, and bump-allocator routines (`memcpy`, `memmove`, `memset`,
   `memcmp`, `strlen`, `strcmp`, `strncmp`, `qsort`, `malloc`, `calloc`, `free`, `__errno`, and C++
   `operator new`/`delete`) are compiled as native ARM64 machine code inside `FAST_BASE` (outside
   the `UC_HOOK_CODE` trap range). QEMU's TCG JIT translates them inline with the guest code,
   eliminating thousands of Python hook context switches and `mem_read`/`mem_write` round-trips.
2. Shared VM/Host Bump-Pointer Heap (`HEAP_CTL_ADDR` at `TLS_BASE + 0xF000`):
   The in-VM `malloc` and `calloc` stubs allocate 16-byte-aligned blocks directly from
   `[heap_top, heap_limit]` in `TLS_BASE + 0xF000` (with 64-bit overflow guards and a 16-byte size
   header at `[ptr - 16]` so `realloc` can inspect blocks allocated by either the VM or Python).
   Resetting the heap between calls is a single 8-byte write.
3. Pre-Relocated Module Snapshot Support:
   `Module` and `Machine` can export and restore pre-relocated module images so worker processes
   skip LZ4 decompression, symbol parsing, and relocation loops.
"""
from __future__ import annotations

import os
import struct
import sys
from pathlib import Path

PAGE = 0x1000


def up(n: int, a: int = PAGE) -> int:
    return (n + a - 1) & ~(a - 1)


STOP = 0xFFFF_0000          # return address of every call: emulation ends here
TRAP_BASE = 0xFFFE_0000     # one 4-byte slot (a ret) per Python-trapped import
FAST_BASE = 0xFFFD_0000     # unhooked native ARM64 machine-code stubs for hot libc / allocator calls
STACK_TOP, STACK_SIZE = 0x7F00_0000_0000, 32 << 20
HEAP_BASE = 0x6000_0000_0000
TLS_BASE = 0x5F00_0000_0000
HEAP_CTL_ADDR = TLS_BASE + 0xF000   # [heap_top: u64, heap_limit: u64, slow_malloc: u64, slow_calloc: u64]
ERRNO_ADDR = TLS_BASE + 0xF020      # int32 errno storage
DEFAULT_CALL_TIMEOUT_US = 30_000_000

_REDIRECTED_ALLOCATORS = frozenset({
    'malloc',
    'free',
    'calloc',
    'realloc',
    'aligned_alloc',
    'memalign',
    'posix_memalign',
    'glslc_Alloc',
    'glslc_Free',
    'glslc_Realloc',
    '_Znwm',
    '_Znam',
    '_ZnwmRKSt9nothrow_t',
    '_ZnamRKSt9nothrow_t',
    '_ZdlPv',
    '_ZdaPv',
    '_ZdlPvm',
    '_ZdaPvm',
    '_ZdlPvRKSt9nothrow_t',
    '_ZdaPvRKSt9nothrow_t',
})


class EmuError(RuntimeError):
    pass


# Optional top-level import so importing `arm64_emu` for static inspection or unit tests on
# machines without `unicorn` does not fail until a `Machine` is actually instantiated.
try:
    from unicorn import (
        Uc,
        UcError,
        UC_ARCH_ARM64,
        UC_HOOK_CODE,
        UC_HOOK_INTR,
        UC_HOOK_MEM_INVALID,
        UC_MODE_ARM,
        UC_PROT_ALL,
    )
    from unicorn.arm64_const import (
        UC_ARM64_REG_CPACR_EL1,
        UC_ARM64_REG_LR,
        UC_ARM64_REG_PC,
        UC_ARM64_REG_SP,
        UC_ARM64_REG_TPIDR_EL0,
        UC_ARM64_REG_TPIDRRO_EL0,
        UC_ARM64_REG_X0,
        UC_ARM64_REG_X29,
    )
    _HAS_UNICORN = True
except ImportError:
    _HAS_UNICORN = False
    Uc = None  # type: ignore[assignment,misc]
    UcError = RuntimeError  # type: ignore[assignment,misc]
    UC_ARCH_ARM64 = 1
    UC_MODE_ARM = 0
    UC_HOOK_CODE = 4
    UC_HOOK_INTR = 1
    UC_HOOK_MEM_INVALID = 0x7F0
    UC_PROT_ALL = 7
    UC_ARM64_REG_CPACR_EL1 = 1
    UC_ARM64_REG_LR = 2
    UC_ARM64_REG_PC = 3
    UC_ARM64_REG_SP = 4
    UC_ARM64_REG_TPIDR_EL0 = 5
    UC_ARM64_REG_TPIDRRO_EL0 = 6
    UC_ARM64_REG_X0 = 199
    UC_ARM64_REG_X29 = 228


def _ensure_unicorn() -> None:
    global _HAS_UNICORN, Uc, UcError
    global UC_ARCH_ARM64, UC_MODE_ARM, UC_HOOK_CODE, UC_HOOK_INTR, UC_HOOK_MEM_INVALID, UC_PROT_ALL
    global UC_ARM64_REG_CPACR_EL1, UC_ARM64_REG_LR, UC_ARM64_REG_PC, UC_ARM64_REG_SP
    global UC_ARM64_REG_TPIDR_EL0, UC_ARM64_REG_TPIDRRO_EL0, UC_ARM64_REG_X0, UC_ARM64_REG_X29
    if _HAS_UNICORN and Uc is not None:
        return
    try:
        from unicorn import (
            Uc as _Uc,
            UcError as _UcError,
            UC_ARCH_ARM64 as _ARCH,
            UC_HOOK_CODE as _HC,
            UC_HOOK_INTR as _HI,
            UC_HOOK_MEM_INVALID as _HM,
            UC_MODE_ARM as _MODE,
            UC_PROT_ALL as _PROT,
        )
        from unicorn.arm64_const import (
            UC_ARM64_REG_CPACR_EL1 as _CPACR,
            UC_ARM64_REG_LR as _LR,
            UC_ARM64_REG_PC as _PC,
            UC_ARM64_REG_SP as _SP,
            UC_ARM64_REG_TPIDR_EL0 as _TPIDR,
            UC_ARM64_REG_TPIDRRO_EL0 as _TPIDRRO,
            UC_ARM64_REG_X0 as _X0,
            UC_ARM64_REG_X29 as _X29,
        )
        Uc, UcError = _Uc, _UcError
        UC_ARCH_ARM64, UC_MODE_ARM = _ARCH, _MODE
        UC_HOOK_CODE, UC_HOOK_INTR, UC_HOOK_MEM_INVALID, UC_PROT_ALL = _HC, _HI, _HM, _PROT
        UC_ARM64_REG_CPACR_EL1, UC_ARM64_REG_LR, UC_ARM64_REG_PC, UC_ARM64_REG_SP = _CPACR, _LR, _PC, _SP
        UC_ARM64_REG_TPIDR_EL0, UC_ARM64_REG_TPIDRRO_EL0 = _TPIDR, _TPIDRRO
        UC_ARM64_REG_X0, UC_ARM64_REG_X29 = _X0, _X29
        _HAS_UNICORN = True
    except ImportError as exc:
        raise EmuError(
            'unicorn is required to emulate Switch ARM64 modules on Windows '
            f'(run `{sys.executable} -m pip install unicorn`)'
        ) from exc


# ---- ARM64 branch encoding helpers for the in-VM fast stubs ----
_EQ, _NE, _HS, _LO, _HI, _LE = 0, 1, 2, 3, 8, 13


def _b_cond(off_insns: int, cond: int) -> int:
    return 0x54000000 | ((off_insns & 0x7FFFF) << 5) | cond


def _b_uncond(off_insns: int) -> int:
    return 0x14000000 | (off_insns & 0x3FFFFFF)


def _cbz_x(reg: int, off_insns: int) -> int:
    return 0xB4000000 | ((off_insns & 0x7FFFF) << 5) | reg


def _cbnz_x(reg: int, off_insns: int) -> int:
    return 0xB5000000 | ((off_insns & 0x7FFFF) << 5) | reg


def _cbz_w(reg: int, off_insns: int) -> int:
    return 0x34000000 | ((off_insns & 0x7FFFF) << 5) | reg


def _cbnz_w(reg: int, off_insns: int) -> int:
    return 0x35000000 | ((off_insns & 0x7FFFF) << 5) | reg


def _build_fast_stubs() -> tuple[bytes, dict[str, int]]:
    """Assemble native ARM64 machine code for hot libc & allocator functions at `FAST_BASE`."""
    stubs: dict[str, list[int]] = {
        'free': [
            0xD65F03C0,             # ret
        ],
        'memcpy': [
            0xAA0003E3,             # mov x3, x0
            0xF100205F,             # cmp x2, #8
            _b_cond(6, _LO),        # b.lo 2f
            0xF8408424,             # 1: ldr x4, [x1], #8
            0xF8008464,             # str x4, [x3], #8
            0xD1002042,             # sub x2, x2, #8
            0xF100205F,             # cmp x2, #8
            _b_cond(-4, _HS),       # b.hs 1b
            _cbz_x(2, 5),           # 2: cbz x2, 4f
            0x38401424,             # 3: ldrb w4, [x1], #1
            0x38001464,             # strb w4, [x3], #1
            0xF1000442,             # subs x2, x2, #1
            _b_cond(-3, _NE),       # b.ne 3b
            0xD65F03C0,             # 4: ret
        ],
        'memmove': [
            _cbz_x(2, 16),          # cbz x2, ret_fwd
            0xAA0003E3,             # mov x3, x0
            0xEB01001F,             # cmp x0, x1
            _b_cond(14, _HI),       # b.hi bwd_copy
            0xF100205F,             # cmp x2, #8
            _b_cond(6, _LO),        # b.lo fwd_tail
            0xF8408424,             # fwd_8: ldr x4, [x1], #8
            0xF8008464,             # str x4, [x3], #8
            0xD1002042,             # sub x2, x2, #8
            0xF100205F,             # cmp x2, #8
            _b_cond(-4, _HS),       # b.hs fwd_8
            _cbz_x(2, 5),           # fwd_tail: cbz x2, ret_fwd
            0x38401424,             # fwd_1: ldrb w4, [x1], #1
            0x38001464,             # strb w4, [x3], #1
            0xF1000442,             # subs x2, x2, #1
            _b_cond(-3, _NE),       # b.ne fwd_1
            0xD65F03C0,             # ret_fwd: ret
            0x8B020021,             # bwd_copy: add x1, x1, x2
            0x8B020063,             # add x3, x3, x2
            0x385FFC24,             # bwd_1: ldrb w4, [x1, #-1]!
            0x381FFC64,             # strb w4, [x3, #-1]!
            0xF1000442,             # subs x2, x2, #1
            _b_cond(-3, _NE),       # b.ne bwd_1
            0xD65F03C0,             # ret
        ],
        'memset': [
            0xAA0003E3,             # mov x3, x0
            0x92401C24,             # and x4, x1, #0xff
            0xF100205F,             # cmp x2, #8
            _b_cond(8, _LO),        # b.lo tail
            0xAA042084,             # orr x4, x4, x4, lsl #8
            0xAA044084,             # orr x4, x4, x4, lsl #16
            0xAA048084,             # orr x4, x4, x4, lsl #32
            0xF8008464,             # loop8: str x4, [x3], #8
            0xD1002042,             # sub x2, x2, #8
            0xF100205F,             # cmp x2, #8
            _b_cond(-3, _HS),       # b.hs loop8
            _cbz_x(2, 4),           # tail: cbz x2, done
            0x38001464,             # loop1: strb w4, [x3], #1
            0xF1000442,             # subs x2, x2, #1
            _b_cond(-2, _NE),       # b.ne loop1
            0xD65F03C0,             # done: ret
        ],
        'memcmp': [
            _cbz_x(2, 7),           # cbz x2, ret0
            0x38401403,             # loop: ldrb w3, [x0], #1
            0x38401424,             # ldrb w4, [x1], #1
            0x6B040063,             # subs w3, w3, w4
            _b_cond(5, _NE),        # b.ne diff
            0xF1000442,             # subs x2, x2, #1
            _b_cond(-5, _NE),       # b.ne loop
            0xD2800000,             # ret0: mov x0, #0
            0xD65F03C0,             # ret
            0x93407C60,             # diff: sxtw x0, w3
            0xD65F03C0,             # ret
        ],
        'strlen': [
            0xAA0003E1,             # mov x1, x0
            0x38401422,             # loop: ldrb w2, [x1], #1
            _cbnz_w(2, -1),         # cbnz w2, loop
            0xCB000020,             # sub x0, x1, x0
            0xD1000400,             # sub x0, x0, #1
            0xD65F03C0,             # ret
        ],
        'strcmp': [
            0x38401402,             # loop: ldrb w2, [x0], #1
            0x38401423,             # ldrb w3, [x1], #1
            0x6B030044,             # subs w4, w2, w3
            _b_cond(4, _NE),        # b.ne diff
            _cbnz_w(2, -4),         # cbnz w2, loop
            0xD2800000,             # mov x0, #0
            0xD65F03C0,             # ret
            0x93407C80,             # diff: sxtw x0, w4
            0xD65F03C0,             # ret
        ],
        'strncmp': [
            _cbz_x(2, 8),           # cbz x2, ret0
            0x38401403,             # loop: ldrb w3, [x0], #1
            0x38401424,             # ldrb w4, [x1], #1
            0x6B040065,             # subs w5, w3, w4
            _b_cond(6, _NE),        # b.ne diff
            _cbz_w(3, 3),           # cbz w3, ret0
            0xF1000442,             # subs x2, x2, #1
            _b_cond(-6, _NE),       # b.ne loop
            0xD2800000,             # ret0: mov x0, #0
            0xD65F03C0,             # ret
            0x93407CA0,             # diff: sxtw x0, w5
            0xD65F03C0,             # ret
        ],
        'errno': [
            0xD53BD060,             # mrs x0, tpidrro_el0
            0x91403C00,             # add x0, x0, #0xf, lsl #12
            0x91008000,             # add x0, x0, #0x20
            0xD65F03C0,             # ret
        ],
        'malloc': [
            0xD53BD061,             # mrs x1, tpidrro_el0
            0x91403C21,             # add x1, x1, #0xf, lsl #12
            0xD35FFC06,             # lsr x6, x0, #31 (overflow guard: >= 2 GB goes to slow trap)
            _cbnz_x(6, 15),         # cbnz x6, slow
            _cbz_x(0, 2),           # cbz x0, zero_sz
            _b_uncond(2),           # b align
            0xD2800020,             # zero_sz: mov x0, #1
            0x91003C00,             # align: add x0, x0, #15
            0x927CEC00,             # and x0, x0, #0xfffffffffffffff0
            0xA9400C22,             # ldp x2, x3, [x1]
            0x91004044,             # add x4, x2, #16
            0x8B000085,             # add x5, x4, x0
            0xEB0300BF,             # cmp x5, x3
            _b_cond(5, _HI),        # b.hi slow
            0xF9000025,             # str x5, [x1]
            0xF9000040,             # str x0, [x2]
            0xAA0403E0,             # mov x0, x4
            0xD65F03C0,             # ret
            0xF9400830,             # slow: ldr x16, [x1, #16]
            0xD61F0200,             # br x16
        ],
        'calloc': [
            0xD53BD062,             # mrs x2, tpidrro_el0
            0x91403C42,             # add x2, x2, #0xf, lsl #12
            0x9BC17C06,             # umulh x6, x0, x1 (128-bit multiply overflow check)
            _cbnz_x(6, 22),         # cbnz x6, slow (x0 and x1 remain untouched for _calloc)
            0x9B017C07,             # mul x7, x0, x1 (keep product in x7 so x0/x1 stay intact)
            0xD350FCE6,             # lsr x6, x7, #16 (>= 64 KB goes to slow trap for bulk zeroing)
            _cbnz_x(6, 19),         # cbnz x6, slow
            _cbz_x(7, 2),           # cbz x7, zero_sz
            _b_uncond(2),           # b align
            0xD2800027,             # zero_sz: mov x7, #1
            0x91003CE7,             # align: add x7, x7, #15
            0x927CECE7,             # and x7, x7, #0xfffffffffffffff0
            0xA9401043,             # ldp x3, x4, [x2]
            0x91004065,             # add x5, x3, #16
            0x8B0700A6,             # add x6, x5, x7
            0xEB0400DF,             # cmp x6, x4
            _b_cond(9, _HI),        # b.hi slow
            0xF9000046,             # str x6, [x2]
            0xF9000067,             # str x7, [x3]
            0xAA0503E3,             # mov x3, x5
            0xA8817C7F,             # zero_loop: stp xzr, xzr, [x3], #16
            0xF10040E7,             # subs x7, x7, #16
            _b_cond(-2, _NE),       # b.ne zero_loop
            0xAA0503E0,             # mov x0, x5
            0xD65F03C0,             # ret
            0xF9400C50,             # slow: ldr x16, [x2, #24]
            0xD61F0200,             # br x16
        ],
        'qsort': [
            0xA9BA7BFD,             # stp x29, x30, [sp, #-96]!
            0x910003FD,             # mov x29, sp
            0xA90153F3,             # stp x19, x20, [sp, #16]
            0xA9025BF5,             # stp x21, x22, [sp, #32]
            0xA90363F7,             # stp x23, x24, [sp, #48]
            0xA9046BF9,             # stp x25, x26, [sp, #64]
            0xF100083F,             # cmp x1, #2
            _b_cond(31, _LO),       # b.lo done
            0xAA0003F3,             # mov x19, x0 (base)
            0xAA0103F4,             # mov x20, x1 (nmemb)
            0xAA0203F5,             # mov x21, x2 (size)
            0xAA0303F6,             # mov x22, x3 (compar)
            0xD2800037,             # mov x23, #1 (i = 1)
            0xEB1402FF,             # outer_loop: cmp x23, x20
            _b_cond(24, _HS),       # b.hs done
            0xAA1703F8,             # mov x24, x23 (j = i)
            _cbz_x(24, 20),         # inner_loop: cbz x24, next_i
            0xD1000719,             # sub x25, x24, #1
            0x9B157F39,             # mul x25, x25, x21
            0x8B130339,             # add x25, x25, x19 (ptr_a)
            0x8B15033A,             # add x26, x25, x21 (ptr_b)
            0xAA1903E0,             # mov x0, x25
            0xAA1A03E1,             # mov x1, x26
            0xD63F02C0,             # blr x22 (compar(ptr_a, ptr_b))
            0x7100001F,             # cmp w0, #0
            _b_cond(11, _LE),       # b.le next_i
            0xD2800009,             # mov x9, #0
            0x38696B2A,             # byte_loop: ldrb w10, [x25, x9]
            0x38696B4B,             # ldrb w11, [x26, x9]
            0x38296B4A,             # strb w10, [x26, x9]
            0x38296B2B,             # strb w11, [x25, x9]
            0x91000529,             # add x9, x9, #1
            0xEB15013F,             # cmp x9, x21
            _b_cond(-6, _LO),       # b.lo byte_loop
            0xD1000718,             # sub x24, x24, #1
            _b_uncond(-19),         # b inner_loop
            0x910006F7,             # next_i: add x23, x23, #1
            _b_uncond(-24),         # b outer_loop
            0xA94153F3,             # done: ldp x19, x20, [sp, #16]
            0xA9425BF5,             # ldp x21, x22, [sp, #32]
            0xA94363F7,             # ldp x23, x24, [sp, #48]
            0xA9446BF9,             # ldp x25, x26, [sp, #64]
            0xA8C67BFD,             # ldp x29, x30, [sp], #96
            0xD65F03C0,             # ret
        ],
    }

    aliases: dict[str, str] = {
        'memcpy': 'memcpy',
        '__memcpy_chk': 'memcpy',
        '__aeabi_memcpy': 'memcpy',
        '__aeabi_memcpy4': 'memcpy',
        '__aeabi_memcpy8': 'memcpy',
        'memmove': 'memmove',
        '__memmove_chk': 'memmove',
        '__aeabi_memmove': 'memmove',
        '__aeabi_memmove4': 'memmove',
        '__aeabi_memmove8': 'memmove',
        'memset': 'memset',
        '__memset_chk': 'memset',
        'memcmp': 'memcmp',
        'bcmp': 'memcmp',
        'strlen': 'strlen',
        'strcmp': 'strcmp',
        'strncmp': 'strncmp',
        '__errno': 'errno',
        '__errno_location': 'errno',
        '___errno': 'errno',
        'free': 'free',
        'glslc_Free': 'free',
        '_ZdlPv': 'free',
        '_ZdaPv': 'free',
        '_ZdlPvm': 'free',
        '_ZdaPvm': 'free',
        '_ZdlPvRKSt9nothrow_t': 'free',
        '_ZdaPvRKSt9nothrow_t': 'free',
        'malloc': 'malloc',
        'glslc_Alloc': 'malloc',
        '_Znwm': 'malloc',
        '_Znam': 'malloc',
        '_ZnwmRKSt9nothrow_t': 'malloc',
        '_ZnamRKSt9nothrow_t': 'malloc',
        'calloc': 'calloc',
        'qsort': 'qsort',
    }

    buf = bytearray()
    entry_offsets: dict[str, int] = {}
    for canonical, words in stubs.items():
        while len(buf) % 16:
            buf.extend(b'\xC0\x03\x5F\xD6')  # pad with `ret`
        entry_offsets[canonical] = FAST_BASE + len(buf)
        buf.extend(struct.pack(f'<{len(words)}I', *words))

    addr_map = {sym: entry_offsets[target] for sym, target in aliases.items()}
    return bytes(buf), addr_map


FAST_STUB_BYTES, FAST_STUB_ADDRS = _build_fast_stubs()


_NSO_CACHE: dict[tuple[str, int, int], tuple[bytes, int, int, int]] = {}


def nso_load(path: str | Path) -> tuple[bytearray, int, int, int]:
    """Decompress an NSO0 file into `(image_with_bss, text_end, ro_off, data_off)`."""
    p = Path(path)
    try:
        st = p.stat()
        cache_key: tuple[str, int, int] | None = (os.path.realpath(p), st.st_size, st.st_mtime_ns)
    except OSError:
        cache_key = None
    if cache_key is not None and cache_key in _NSO_CACHE:
        raw_img, t_end, r_off, d_off = _NSO_CACHE[cache_key]
        return bytearray(raw_img), t_end, r_off, d_off

    d = p.read_bytes()
    if len(d) < 0x6C or d[:4] != b'NSO0':
        raise EmuError(f'{path}: not an NSO')
    flags = struct.unpack_from('<I', d, 0x0C)[0]
    segs = [struct.unpack_from('<III', d, 0x10 + i * 0x10) for i in range(3)]
    raw_csz = struct.unpack_from('<III', d, 0x60)
    csz = [raw_csz[i] if (flags >> i) & 1 else segs[i][2] for i in range(3)]
    bss = struct.unpack_from('<I', d, 0x3C)[0]
    total = max(
        segs[0][1] + segs[0][2],
        segs[1][1] + segs[1][2],
        segs[2][1] + segs[2][2] + bss,
    )
    if bss < 0 or total <= 0 or total > (512 << 20):
        raise EmuError(f'{path}: invalid NSO image size ({total:#x})')
    img = bytearray(total)
    for i, (fo, mo, sz) in enumerate(segs):
        c = csz[i]
        if fo < 0 or mo < 0 or sz < 0 or c < 0 or fo + c > len(d) or mo + sz > total:
            raise EmuError(f'{path}: truncated NSO segment {i}')
        raw = d[fo:fo + c]
        if (flags >> i) & 1:
            if flags & (1 << 7):
                try:
                    import zbic  # type: ignore[import-not-found]
                except ImportError as exc:
                    raise EmuError(f'{path}: ZBIC (zstd) segment {i} requires zbic') from exc
                try:
                    raw = zbic.decompress(bytes(raw))
                except Exception as exc:
                    raise EmuError(f'{path}: ZBIC segment {i} failed to decompress ({exc})') from exc
            else:
                import lz4.block
                try:
                    raw = lz4.block.decompress(raw, uncompressed_size=sz)
                except Exception as exc:
                    raise EmuError(f'{path}: LZ4 segment {i} failed to decompress ({exc})') from exc
        if len(raw) != sz:
            raise EmuError(f'{path}: segment {i} decompressed to {len(raw):#x} bytes, expected {sz:#x}')
        img[mo:mo + sz] = raw
    t_end, r_off, d_off = segs[0][1] + segs[0][2], segs[1][1], segs[2][1]
    if cache_key is not None:
        if len(_NSO_CACHE) >= 4:
            _NSO_CACHE.clear()
        _NSO_CACHE[cache_key] = (bytes(img), t_end, r_off, d_off)
    return img, t_end, r_off, d_off


class Module:
    def __init__(
        self,
        name: str,
        path: str | Path | None,
        base: int,
        *,
        preloaded: tuple[bytearray, int, int, int, int, dict[str, int]] | None = None,
    ) -> None:
        self.name, self.base = name, base
        if preloaded is not None:
            self.img, self.text_end, self.ro_off, self.data_off, self.mod0, self.exports = preloaded
            self.tags: dict[int, int] = {}
            self.syms: list[tuple[str, int, int]] = []
            return

        assert path is not None
        self.img, self.text_end, self.ro_off, self.data_off = nso_load(path)
        if len(self.img) < 8:
            raise EmuError(f'{name}: image too small')
        mod0 = struct.unpack_from('<I', self.img, 4)[0]
        if mod0 + 28 > len(self.img) or self.img[mod0:mod0 + 4] != b'MOD0':
            raise EmuError(f'{name}: no MOD0')
        self.mod0 = mod0
        dyn = mod0 + struct.unpack_from('<i', self.img, mod0 + 4)[0]
        self.tags = {}
        img = self.img
        max_dyn = min(4096, (len(img) - dyn) // 16) if 0 <= dyn < len(img) else 0
        for i in range(max_dyn):
            t, v = struct.unpack_from('<qQ', img, dyn + i * 16)
            if t == 0:
                break
            self.tags.setdefault(t, v)
        symtab, strtab = self.tags.get(6, 0), self.tags.get(5, 0)
        nsyms = max(0, (strtab - symtab) // 24) if 0 <= symtab <= strtab <= len(img) else 0
        self.syms = []
        exports: dict[str, int] = {}
        if nsyms:
            sym_slice = memoryview(img)[symtab:symtab + nsyms * 24]
            for nm, _info, _other, shndx, value, _size in struct.iter_unpack('<IBBHQQ', sym_slice):
                s_off = strtab + nm
                if s_off < 0 or s_off >= len(img):
                    sname = ''
                else:
                    z_off = img.find(b'\0', s_off)
                    sname = img[s_off:z_off if z_off >= 0 else s_off].decode('latin1')
                self.syms.append((sname, value, shndx))
                if shndx and sname:
                    exports[sname] = value
        self.exports = exports

    def relocs(self) -> list[tuple[int, int, int, int]]:
        out: list[tuple[int, int, int, int]] = []
        img = self.img
        for tab, size in ((7, 8), (23, 2)):  # DT_RELA / DT_RELASZ, DT_JMPREL / DT_PLTRELSZ
            if tab not in self.tags or size not in self.tags:
                continue
            off, nbytes = self.tags[tab], self.tags[size]
            n = nbytes // 24
            if off < 0 or off + n * 24 > len(img):
                continue
            rel_slice = memoryview(img)[off:off + n * 24]
            for r_off, info, add in struct.iter_unpack('<QQq', rel_slice):
                out.append((r_off, info & 0xFFFFFFFF, info >> 32, add))
        return out


def _cstr(m: Machine, a: int, limit: int = 1 << 20) -> bytes:
    if not a or limit <= 0:
        return b''
    out = bytearray()
    while len(out) < limit:
        chunk = bytes(m.uc.mem_read(a + len(out), min(256, limit - len(out))))
        z = chunk.find(b'\0')
        if z >= 0:
            return bytes(out + chunk[:z])
        out += chunk
    return bytes(out)


class Machine:
    TRAPS: dict[str, object] = {}  # import name -> handler(machine) returning x0 (filled below)

    def __init__(
        self,
        modules: list[tuple[str, str | Path]],
        heap_size: int = 96 << 20,
        *,
        use_fast_stubs: bool = True,
        pre_relocated: dict | None = None,
    ) -> None:
        """Load `modules` (`[(name, NSO path), ...]`) into an emulated ARM64 address space."""
        _ensure_unicorn()
        self.uc = uc = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
        uc.reg_write(UC_ARM64_REG_CPACR_EL1, 0x300000)  # FP / SIMD on
        self.use_fast_stubs = use_fast_stubs
        self.traps: dict[str, int] = {}
        self.trap_names: list[str] = []

        uc.mem_map(TRAP_BASE, 0x10000, UC_PROT_ALL)
        if (STOP & ~0xFFFF) != TRAP_BASE:
            uc.mem_map(STOP & ~0xFFFF, 0x10000, UC_PROT_ALL)
        uc.mem_write(TRAP_BASE, b'\xC0\x03\x5F\xD6' * (0x10000 // 4))  # ret

        uc.mem_map(FAST_BASE, 0x10000, UC_PROT_ALL)
        uc.mem_write(FAST_BASE, FAST_STUB_BYTES)

        self.mods: list[Module] = []
        base = 0x0800_0000

        if pre_relocated is not None:
            self.traps = dict(pre_relocated['traps'])
            self.trap_names = list(pre_relocated['trap_names'])
            for m_info in pre_relocated['mods']:
                m = Module(
                    m_info['name'],
                    None,
                    m_info['base'],
                    preloaded=(
                        bytearray(m_info['img']),
                        m_info['text_end'],
                        m_info['ro_off'],
                        m_info['data_off'],
                        m_info['mod0'],
                        dict(m_info['exports']),
                    ),
                )
                self.mods.append(m)
                uc.mem_map(m.base, up(len(m.img), 0x10000), UC_PROT_ALL)
                uc.mem_write(m.base, bytes(m.img))
        else:
            for name, path in modules:
                m = Module(name, path, base)
                self.mods.append(m)
                uc.mem_map(base, up(len(m.img), 0x10000), UC_PROT_ALL)
                base = up(base + len(m.img) + 0x100000, 0x200000)

            exports: dict[str, int] = {}
            for m in self.mods:
                for n, v in m.exports.items():
                    exports.setdefault(n, m.base + v)

            for m in self.mods:
                for off, typ, si, add in m.relocs():
                    if typ == 0:
                        continue
                    if off < 0 or off > len(m.img) - 8:
                        raise EmuError(f'{m.name}: relocation offset {off:#x} out of bounds')
                    if typ == 1027:  # R_AARCH64_RELATIVE
                        val = m.base + add
                    elif typ in (257, 1025, 1026):  # ABS64, GLOB_DAT, JUMP_SLOT
                        if si < 0 or si >= len(m.syms):
                            raise EmuError(f'{m.name}: relocation symbol index {si} out of bounds')
                        n, v, sh = m.syms[si]
                        if n in _REDIRECTED_ALLOCATORS:
                            val = self.resolve_import(n)
                        elif sh:
                            val = m.base + v + (add if typ == 257 else 0)
                        elif n in self.TRAPS:
                            val = self.resolve_import(n)
                        elif n in exports:
                            val = exports[n] + (add if typ == 257 else 0)
                        else:
                            val = self.resolve_import(n)
                    else:
                        raise EmuError(f'{m.name}: relocation type {typ} not handled')
                    struct.pack_into('<Q', m.img, off, val & 0xFFFFFFFFFFFFFFFF)

                if 36 in m.tags and 35 in m.tags:  # DT_RELR / DT_RELRSZ
                    relr_off, relr_sz = m.tags[36], m.tags[35]
                    if 0 <= relr_off <= len(m.img) - relr_sz:
                        where = 0
                        for k in range(relr_sz // 8):
                            e = struct.unpack_from('<Q', m.img, relr_off + 8 * k)[0]
                            if not (e & 1):
                                if e < 0 or e > len(m.img) - 8:
                                    raise EmuError(f'{m.name}: DT_RELR offset {e:#x} out of bounds')
                                cur = struct.unpack_from('<Q', m.img, e)[0]
                                struct.pack_into('<Q', m.img, e, (cur + m.base) & 0xFFFFFFFFFFFFFFFF)
                                where = e + 8
                            else:
                                for bit in range(1, 64):
                                    if (e >> bit) & 1:
                                        a = where + (bit - 1) * 8
                                        if a < 0 or a > len(m.img) - 8:
                                            raise EmuError(f'{m.name}: DT_RELR bitmap offset {a:#x} out of bounds')
                                        cur = struct.unpack_from('<Q', m.img, a)[0]
                                        struct.pack_into('<Q', m.img, a, (cur + m.base) & 0xFFFFFFFFFFFFFFFF)
                                where += 63 * 8

                # Redirect any module-defined allocator exports (`malloc`, `free`, `calloc`,
                # `realloc`, `operator new`, etc.) so direct `BL` calls inside the module also
                # use the emulator's heap instead of an uninitialized SDK heap.
                for alloc_sym in _REDIRECTED_ALLOCATORS:
                    fn_off = m.exports.get(alloc_sym)
                    if fn_off is not None and 0 <= fn_off <= m.text_end - 16:
                        target = self.resolve_import(alloc_sym)
                        m.img[fn_off:fn_off + 16] = struct.pack('<IIQ', 0x58000050, 0xD61F0200, target)

                # Normalize ARMv8.3 Pointer Authentication returns (`retaa` / `retab`) to plain
                # `ret` so Switch 2 (`Ounce`) modules execute cleanly on Unicorn's ARMv8.0 core
                # (where `paciasp` / `pacibsp` are HINT no-ops).
                for pat in (b'\xFF\x0F\x5F\xD6', b'\xBF\x0F\x5F\xD6'):
                    pos = m.img.find(pat, 0, m.text_end)
                    while pos != -1:
                        if (pos & 3) == 0:
                            m.img[pos:pos + 4] = b'\xC0\x03\x5F\xD6'
                        pos = m.img.find(pat, pos + (4 if (pos & 3) == 0 else 1), m.text_end)

                uc.mem_write(m.base, bytes(m.img))

        uc.mem_map(STACK_TOP - STACK_SIZE, STACK_SIZE, UC_PROT_ALL)
        uc.mem_map(TLS_BASE, 0x10000, UC_PROT_ALL)
        uc.reg_write(UC_ARM64_REG_TPIDRRO_EL0, TLS_BASE)
        uc.reg_write(UC_ARM64_REG_TPIDR_EL0, TLS_BASE + 0x8000)

        self.heap_size = heap_size
        self.heap_limit = HEAP_BASE + heap_size
        uc.mem_map(HEAP_BASE, heap_size, UC_PROT_ALL)
        self.heap_top = HEAP_BASE
        self.blocks: dict[int, int] = {}

        # Register slow-path allocator traps for the in-VM bump allocator's overflow fallback
        slow_malloc = self.trap('malloc')
        slow_calloc = self.trap('calloc')
        uc.mem_write(
            HEAP_CTL_ADDR,
            struct.pack('<QQQQ', self.heap_top, self.heap_limit, slow_malloc, slow_calloc),
        )

        uc.hook_add(UC_HOOK_CODE, self._on_trap, begin=TRAP_BASE, end=TRAP_BASE + 0xFFFF)
        uc.hook_add(UC_HOOK_INTR, self._on_intr)
        self.fault: str | None = None

    def export_snapshot(self) -> dict:
        """Export pre-relocated module images and trap bindings for caching across worker processes."""
        return {
            'traps': dict(self.traps),
            'trap_names': list(self.trap_names),
            'mods': [
                {
                    'name': m.name,
                    'base': m.base,
                    'img': bytes(m.img),
                    'text_end': m.text_end,
                    'ro_off': m.ro_off,
                    'data_off': m.data_off,
                    'mod0': m.mod0,
                    'exports': dict(m.exports),
                }
                for m in self.mods
            ],
        }

    # ---- memory & shared bump allocator ----
    def _vm_heap_top(self) -> int:
        return struct.unpack('<Q', self.uc.mem_read(HEAP_CTL_ADDR, 8))[0]

    def _set_vm_heap_top(self, val: int) -> None:
        self.heap_top = val
        self.uc.mem_write(HEAP_CTL_ADDR, struct.pack('<Q', val))

    def malloc(self, n: int, align: int = 16) -> int:
        cur = max(self.heap_top, self._vm_heap_top())
        sz = up(max(n, 1), 16)
        a = up(cur + 16, max(align, 16))
        new_top = a + sz
        if new_top > self.heap_limit:
            raise EmuError(f'emulated heap full ({self.heap_size >> 20} MB)')
        self.uc.mem_write(a - 16, struct.pack('<Q', sz))
        self._set_vm_heap_top(new_top)
        self.blocks[a] = n
        return a

    def heap_mark(self) -> int:
        self.heap_top = max(self.heap_top, self._vm_heap_top())
        return self.heap_top

    def heap_reset(self, mark: int) -> None:
        self._set_vm_heap_top(mark)
        if self.blocks:
            # Fast check: only rebuild `self.blocks` if something was recorded at or above `mark`
            if any(a >= mark for a in self.blocks):
                self.blocks = {a: n for a, n in self.blocks.items() if a < mark}

    def write(self, a: int, b: bytes | bytearray | memoryview) -> None:
        self.uc.mem_write(a, bytes(b))

    def read(self, a: int, n: int) -> bytes:
        return bytes(self.uc.mem_read(a, n))

    def resolve_import(self, name: str) -> int:
        """Return the in-VM fast stub address when available, or a Python trap slot otherwise."""
        if (
            self.use_fast_stubs
            and name in FAST_STUB_ADDRS
            and self.TRAPS.get(name) is _DEFAULT_TRAPS.get(name)
        ):
            return FAST_STUB_ADDRS[name]
        return self.trap(name)

    def trap(self, name: str) -> int:
        if name not in self.traps:
            if len(self.trap_names) * 4 >= 0x10000 - 4:
                raise EmuError('too many trapped imports')
            self.traps[name] = TRAP_BASE + 4 * len(self.trap_names)
            self.trap_names.append(name)
        return self.traps[name]

    def module(self, name: str) -> Module:
        return next(m for m in self.mods if m.name == name)

    # ---- calls ----
    def call(
        self,
        addr: int,
        *args: int,
        max_insns: int = 0,
        timeout_us: int = DEFAULT_CALL_TIMEOUT_US,
    ) -> int:
        """Call `addr` with AAPCS64 integer/pointer arguments (`x0..x7`, rest on stack)."""
        uc = self.uc
        sp = STACK_TOP - 0x1000
        if len(args) > 8:
            extra = args[8:]
            sp -= up(8 * len(extra), 16)
            uc.mem_write(
                sp,
                struct.pack(f'<{len(extra)}Q', *(v & 0xFFFFFFFFFFFFFFFF for v in extra)),
            )
        for i, v in enumerate(args[:8]):
            uc.reg_write(UC_ARM64_REG_X0 + i, v & 0xFFFFFFFFFFFFFFFF)
        uc.reg_write(UC_ARM64_REG_SP, sp)
        uc.reg_write(UC_ARM64_REG_LR, STOP)
        uc.reg_write(UC_ARM64_REG_X29, 0)
        self.fault = None
        try:
            uc.emu_start(addr, STOP, timeout=timeout_us, count=max_insns)
        except UcError as e:
            pc = uc.reg_read(UC_ARM64_REG_PC)
            raise EmuError(
                f'{e} at {self.where(pc)}' + (f' ({self.fault})' if self.fault else '')
            ) from None
        if self.fault:
            raise EmuError(self.fault)
        pc = uc.reg_read(UC_ARM64_REG_PC)
        if timeout_us and pc != STOP:
            raise EmuError(f'emulation timed out at {self.where(pc)} (limit {timeout_us // 1000} ms)')
        return uc.reg_read(UC_ARM64_REG_X0)

    def call_fast(
        self,
        addr: int,
        r0: int = 0,
        r1: int = 0,
        r2: int = 0,
        r3: int = 0,
        r4: int = 0,
        r5: int = 0,
        r6: int = 0,
        r7: int = 0,
        stack_bytes: bytes = b'',
        *,
        timeout_us: int = DEFAULT_CALL_TIMEOUT_US,
    ) -> int:
        """Low-overhead call path for hot inner loops (`Decoder.run`) with pre-packed stack args."""
        uc = self.uc
        sp = STACK_TOP - 0x1000
        if stack_bytes:
            sp -= up(len(stack_bytes), 16)
            uc.mem_write(sp, stack_bytes)
        uc.reg_write(UC_ARM64_REG_X0, r0 & 0xFFFFFFFFFFFFFFFF)
        uc.reg_write(UC_ARM64_REG_X0 + 1, r1 & 0xFFFFFFFFFFFFFFFF)
        uc.reg_write(UC_ARM64_REG_X0 + 2, r2 & 0xFFFFFFFFFFFFFFFF)
        uc.reg_write(UC_ARM64_REG_X0 + 3, r3 & 0xFFFFFFFFFFFFFFFF)
        uc.reg_write(UC_ARM64_REG_X0 + 4, r4 & 0xFFFFFFFFFFFFFFFF)
        uc.reg_write(UC_ARM64_REG_X0 + 5, r5 & 0xFFFFFFFFFFFFFFFF)
        uc.reg_write(UC_ARM64_REG_X0 + 6, r6 & 0xFFFFFFFFFFFFFFFF)
        uc.reg_write(UC_ARM64_REG_X0 + 7, r7 & 0xFFFFFFFFFFFFFFFF)
        uc.reg_write(UC_ARM64_REG_SP, sp)
        uc.reg_write(UC_ARM64_REG_LR, STOP)
        uc.reg_write(UC_ARM64_REG_X29, 0)
        self.fault = None
        try:
            uc.emu_start(addr, STOP, timeout=timeout_us)
        except UcError as e:
            pc = uc.reg_read(UC_ARM64_REG_PC)
            raise EmuError(
                f'{e} at {self.where(pc)}' + (f' ({self.fault})' if self.fault else '')
            ) from None
        if self.fault:
            raise EmuError(self.fault)
        pc = uc.reg_read(UC_ARM64_REG_PC)
        if timeout_us and pc != STOP:
            raise EmuError(f'emulation timed out at {self.where(pc)} (limit {timeout_us // 1000} ms)')
        return uc.reg_read(UC_ARM64_REG_X0)

    def where(self, pc: int) -> str:
        for m in self.mods:
            if m.base <= pc < m.base + len(m.img):
                return f'{m.name}+{pc - m.base:#x}'
        if TRAP_BASE <= pc < TRAP_BASE + 0x10000:
            idx = (pc - TRAP_BASE) // 4
            if idx < len(self.trap_names):
                return f'import {self.trap_names[idx]}'
        if FAST_BASE <= pc < FAST_BASE + 0x10000:
            return f'fast_stub+{pc - FAST_BASE:#x}'
        return f'{pc:#x}'

    def _on_intr(self, uc, intno: int, _user) -> None:
        pc = uc.reg_read(UC_ARM64_REG_PC)
        self.fault = f'supervisor call / exception {intno} at {self.where(pc - 4)}: the emulator has no kernel'
        uc.emu_stop()

    def _on_trap(self, uc, addr: int, _size: int, _user) -> None:
        idx = (addr - TRAP_BASE) // 4
        name = self.trap_names[idx] if 0 <= idx < len(self.trap_names) else None
        h = self.TRAPS.get(name) if name is not None else None
        if not callable(h):
            lr = uc.reg_read(UC_ARM64_REG_LR)
            self.fault = (
                f'the code called import {name}, which the emulator does not provide '
                f'(from {self.where(lr - 4)})'
            )
            uc.emu_stop()
            return
        r = h(self)
        if r is not None:
            uc.reg_write(UC_ARM64_REG_X0, r & 0xFFFFFFFFFFFFFFFF)

    def x(self, i: int) -> int:
        return self.uc.reg_read(UC_ARM64_REG_X0 + i)


# ---- Fallback Python trap handlers (also used for realloc / aligned_alloc / abort) ----
def _memcpy(m: Machine) -> int:
    d, s, n = m.x(0), m.x(1), m.x(2)
    if n:
        m.uc.mem_write(d, bytes(m.uc.mem_read(s, n)))
    return d


def _memset(m: Machine) -> int:
    d, c, n = m.x(0), m.x(1) & 0xFF, m.x(2)
    if n:
        m.uc.mem_write(d, bytes([c]) * n)
    return d


def _memcmp(m: Machine) -> int:
    a, b = m.read(m.x(0), m.x(2)), m.read(m.x(1), m.x(2))
    for x, y in zip(a, b):
        if x != y:
            return (x - y) & 0xFFFFFFFFFFFFFFFF
    return 0


def _strlen(m: Machine) -> int:
    return len(_cstr(m, m.x(0)))


def _strcmp(m: Machine) -> int:
    a, b = _cstr(m, m.x(0)), _cstr(m, m.x(1))
    return 0 if a == b else (1 if a > b else (-1 & 0xFFFFFFFFFFFFFFFF))


def _strncmp(m: Machine) -> int:
    n = m.x(2)
    a, b = _cstr(m, m.x(0), n)[:n], _cstr(m, m.x(1), n)[:n]
    return 0 if a == b else (1 if a > b else (-1 & 0xFFFFFFFFFFFFFFFF))


def _malloc(m: Machine) -> int:
    return m.malloc(m.x(0))


def _calloc(m: Machine) -> int:
    n = m.x(0) * m.x(1)
    a = m.malloc(n)
    if n:
        m.uc.mem_write(a, b'\0' * n)
    return a


def _aligned(m: Machine) -> int:
    return m.malloc(m.x(1), m.x(0))


def _posix_memalign(m: Machine) -> int:
    a = m.malloc(m.x(2), m.x(1))
    m.uc.mem_write(m.x(0), struct.pack('<Q', a))
    return 0


def _realloc(m: Machine) -> int:
    p, n = m.x(0), m.x(1)
    old_n = m.blocks.get(p)
    if old_n is None and HEAP_BASE + 16 <= p <= m._vm_heap_top():
        old_n = struct.unpack('<Q', m.uc.mem_read(p - 16, 8))[0]
    a = m.malloc(n)
    if p and old_n:
        m.uc.mem_write(a, bytes(m.uc.mem_read(p, min(n, old_n))))
    return a


def _free(_m: Machine) -> None:
    return None


def _errno(m: Machine) -> int:
    return ERRNO_ADDR


def _abort(m: Machine) -> None:
    m.fault = 'the code called abort'
    m.uc.emu_stop()


_DEFAULT_TRAPS: dict[str, object] = {
    'memcpy': _memcpy,
    'memmove': _memcpy,
    '__memcpy_chk': _memcpy,
    '__memmove_chk': _memcpy,
    '__aeabi_memcpy': _memcpy,
    '__aeabi_memcpy4': _memcpy,
    '__aeabi_memcpy8': _memcpy,
    '__aeabi_memmove': _memcpy,
    '__aeabi_memmove4': _memcpy,
    '__aeabi_memmove8': _memcpy,
    'memset': _memset,
    '__memset_chk': _memset,
    'memcmp': _memcmp,
    'bcmp': _memcmp,
    'strlen': _strlen,
    'strcmp': _strcmp,
    'strncmp': _strncmp,
    '__errno': _errno,
    '__errno_location': _errno,
    '___errno': _errno,
    'malloc': _malloc,
    'glslc_Alloc': _malloc,
    '_Znwm': _malloc,
    '_Znam': _malloc,
    '_ZnwmRKSt9nothrow_t': _malloc,
    '_ZnamRKSt9nothrow_t': _malloc,
    'calloc': _calloc,
    'realloc': _realloc,
    'glslc_Realloc': _realloc,
    'free': _free,
    'glslc_Free': _free,
    '_ZdlPv': _free,
    '_ZdaPv': _free,
    '_ZdlPvm': _free,
    '_ZdaPvm': _free,
    '_ZdlPvRKSt9nothrow_t': _free,
    '_ZdaPvRKSt9nothrow_t': _free,
    'aligned_alloc': _aligned,
    'memalign': _aligned,
    'posix_memalign': _posix_memalign,
    'abort': _abort,
}

Machine.TRAPS.update(_DEFAULT_TRAPS)
