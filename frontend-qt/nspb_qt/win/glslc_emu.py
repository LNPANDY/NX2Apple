"""Offline GLSLC shader compiler host (`glslcCompile` in Unicorn) for Windows builds.

Upstream captures runtime-compiled NVN shaders (`DM_GLSLC_CAPTURE`, `dm/host/hle_glslc.c`) by
booting the game in the Mac host until every `<fnv1a>.glslc` file named in `shader_map.tsv` has
been written. Six supported titles use runtime `glslcCompile`:
- *Portal* (`01007BB017812000`, 10 `.glslc` outputs from `materialsystem.nro` and `video_nx.nro`)
- *Portal 2* (`0100ABD01785C000`, 9 `.glslc` outputs from `materialsystem.nro`)
- *Fire Emblem: Three Houses* (`010055D009F78000`, 9 single-stage boot shaders in `ExeFS/main`)
- *DRAGON QUEST BUILDERS 2* (`010042000A986000`, 6 single-stage boot shaders in `ExeFS/main`)
- *Hyrule Warriors: Definitive Edition* (`0100AE00096EA000`, 7 single-stage boot shaders in `ExeFS/main`)
- *Catherine: Full Body* (`0100BF00112C0000`, 2 single-stage boot shaders in `ExeFS/main`)

On Windows (where `dmhost` cannot run), this module extracts the embedded GLSL sources from the
game's NROs / `ExeFS/main` (and any plain-text `.vert` / `.frag` files in the RomFS) and loads the
game's own `GLSLC` NSO module (`ExeFS/subsdk0`) into `arm64_emu.Machine` to run `glslcCompile`
directly, producing byte-for-byte identical `<fnv1a>.glslc` outputs.
"""
from __future__ import annotations

import hashlib
import math
import os
import re
import struct
from pathlib import Path
from typing import Callable, Iterable

from . import arm64_emu as E

try:
    from unicorn.arm64_const import (
        UC_ARM64_REG_D0,
        UC_ARM64_REG_D8,
        UC_ARM64_REG_LR,
        UC_ARM64_REG_S0,
        UC_ARM64_REG_SP,
        UC_ARM64_REG_X19,
        UC_ARM64_REG_X29,
    )
except ImportError:
    UC_ARM64_REG_SP = 4
    UC_ARM64_REG_LR = 2
    UC_ARM64_REG_X19 = 218
    UC_ARM64_REG_X29 = 228
    UC_ARM64_REG_D0 = 67
    UC_ARM64_REG_D8 = 75
    UC_ARM64_REG_S0 = 131

GLSLC_MAGIC = 0x19866891
# `GLSLCoptionFlags`: `outputShaderReflection` (1 << 4) | `separateDebugData` (1 << 17)
SOURCE_MATSYS_FLAG_BITS = 0x00020010

_GLSL_CAND_RE = re.compile(rb'(?://GLSL[vf]p\r?\n)?#version\s+[0-9]+[^\x00]*')
_MAIN_ENTRY_RE = re.compile(rb'\bvoid\s+main\s*\(')
_FMT_RE = re.compile(r'%([-+ #0]*)(\*|\d+)?(?:\.(\*|\d+))?(hh|h|ll|l|z|t|L)?([diuoxXfFeEgGaAcspn%])')
_SCANF_RE = re.compile(r'%(\*)?(\d+)?(hh|h|ll|l|z|t|L)?([diuoxXfFeEgGaAcspn%\[]+)')


def fnv1a_64(data: bytes) -> int:
    """Compute the 64-bit FNV-1a digest used by `dm/host/hle_glslc.c` to name `<hash>.glslc`."""
    h = 0xCBF29CE484222325
    for b in data:
        h = ((h ^ b) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return h


def stage_of(src: bytes) -> int:
    """Infer the `NVNshaderStage` (0=VERTEX, 1=FRAGMENT, 5=COMPUTE) from GLSL source text."""
    if b'local_size_x' in src:
        return 5
    if b'//GLSLvp' in src or re.search(rb'\bgl_Position\b', src):
        return 0
    return 1


def extract_glsl_sources(img: bytes | bytearray) -> list[bytes]:
    """Return complete null-terminated GLSL shader source strings embedded in `img`."""
    out: list[bytes] = []
    for m in _GLSL_CAND_RE.finditer(img):
        s = m.group(0)
        if _MAIN_ENTRY_RE.search(s):
            out.append(s + b'\x00')
    return out


def _load_order(name: str) -> tuple[bool, bool, int, str]:
    return (
        name != 'main',
        name == 'sdk',
        int(name[6:]) if name.startswith('subsdk') and name[6:].isdigit() else 0,
        name,
    )


def find_glslc_nso(exefs_dir: str | Path) -> Path | None:
    """Find the NSO module in `exefs_dir` that exports `glslcCompile` and `glslcInitialize`."""
    exefs = Path(exefs_dir)
    if not exefs.is_dir():
        return None
    cands = sorted(
        (p for p in exefs.iterdir() if p.is_file() and p.name not in ('main', 'rtld', 'sdk')),
        key=lambda p: _load_order(p.name),
    )
    for p in cands:
        try:
            with open(p, 'rb') as f:
                if f.read(4) != b'NSO0':
                    continue
            mod = E.Module(p.name, p, 0x0800_0000)
        except Exception:
            continue
        if 'glslcCompile' in mod.exports and 'glslcInitialize' in mod.exports:
            return p
    return None


def collect_nro_programs(
    nro_bytes: bytes,
) -> list[tuple[tuple[bytes, ...], tuple[int, ...], bool]]:
    """Extract `(sources, stages, uses_matsys_flags)` compile jobs from a Switch NRO image."""
    if len(nro_bytes) < 0x40 or nro_bytes[0x10:0x14] != b'NRO0':
        return []
    decl_size = struct.unpack_from('<I', nro_bytes, 0x18)[0]
    if decl_size < 0x40 or decl_size > len(nro_bytes) or decl_size > (512 << 20):
        return []
    if b'glslcCompile\x00' not in nro_bytes:
        return []
    spans = [
        (m.start(), m.end(), m.group(0) + b'\x00')
        for m in _GLSL_CAND_RE.finditer(nro_bytes)
        if _MAIN_ENTRY_RE.search(m.group(0))
    ]
    if not spans:
        return []
    refl_dbg = (
        b'CShaderDeviceMgr' in nro_bytes
        or b'materialsystem' in nro_bytes
        or b'//GLSLvp' in nro_bytes
    )
    jobs: list[tuple[tuple[bytes, ...], tuple[int, ...], bool]] = []
    cur_vs: bytes | None = None
    paired_vs = False
    prev_end = 0
    for start, end, s in spans:
        st = stage_of(s)
        if st == 0:
            if cur_vs is not None and not paired_vs:
                jobs.append(((cur_vs,), (0,), refl_dbg))
            cur_vs = s
            paired_vs = False
            prev_end = end
        elif st == 1 and cur_vs is not None:
            if (start - prev_end) <= 0x400:
                jobs.append(((cur_vs, s), (0, 1), refl_dbg))
                paired_vs = True
                prev_end = end
            else:
                if not paired_vs:
                    jobs.append(((cur_vs,), (0,), refl_dbg))
                cur_vs = None
                paired_vs = False
                jobs.append(((s,), (1,), refl_dbg))
        else:
            if cur_vs is not None and not paired_vs:
                jobs.append(((cur_vs,), (0,), refl_dbg))
            cur_vs = None
            paired_vs = False
            jobs.append(((s,), (st,), refl_dbg))
    if cur_vs is not None and not paired_vs:
        jobs.append(((cur_vs,), (0,), refl_dbg))
    return jobs


def collect_main_programs(
    main_path: str | Path,
) -> list[tuple[tuple[bytes, ...], tuple[int, ...], bool]]:
    """Extract single-stage compile jobs from `ExeFS/main` when it imports `glslcCompile`."""
    p = Path(main_path)
    if not p.is_file():
        return []
    try:
        with open(p, 'rb') as f:
            magic = f.read(4)
        img = bytes(E.nso_load(p)[0]) if magic == b'NSO0' else p.read_bytes()
    except Exception:
        return []
    if b'glslcCompile\x00' not in img:
        return []
    srcs = extract_glsl_sources(img)
    jobs: list[tuple[tuple[bytes, ...], tuple[int, ...], bool]] = []
    seen: set[bytes] = set()
    for s in srcs:
        if s in seen:
            continue
        seen.add(s)
        jobs.append(((s,), (stage_of(s),), False))
    return jobs


def collect_romfs_glsl_programs(
    romfs_dir: str | Path | None,
) -> list[tuple[tuple[bytes, ...], tuple[int, ...], bool]]:
    """Extract compile jobs from plain-text `.vert` / `.frag` files in an extracted RomFS folder."""
    if not romfs_dir:
        return []
    root = Path(romfs_dir)
    if not root.is_dir():
        return []
    jobs: list[tuple[tuple[bytes, ...], tuple[int, ...], bool]] = []
    for dp, _, names in os.walk(root):
        for name in sorted(names):
            low = name.lower()
            if not low.endswith(('.vert', '.frag')):
                continue
            fp = Path(dp) / name
            try:
                raw = fp.read_bytes()
            except OSError:
                continue
            if not raw or len(raw) > (4 << 20):
                continue
            if re.search(rb'[\x00-\x08\x0b\x0e-\x1f\x7f]', raw[:4096]):
                continue
            if not _MAIN_ENTRY_RE.search(raw):
                continue
            src = raw + b'\x00'
            st = 0 if low.endswith('.vert') else 1
            jobs.append(((src,), (st,), False))
    return jobs


# ---- C runtime / math / varargs helpers for GLSLC inside Unicorn ----
class _VaList:
    """AAPCS64 `va_list` reader (`struct __va_list { stack, gr_top, vr_top, gr_offs, vr_offs }`)."""

    def __init__(self, m: E.Machine, va_ptr: int) -> None:
        st, gr_top, vr_top, gr_offs, vr_offs = struct.unpack('<QQQii', m.uc.mem_read(va_ptr, 32))
        self.m = m
        self.stack = st
        self.gr_top = gr_top
        self.vr_top = vr_top
        self.gr_offs = gr_offs
        self.vr_offs = vr_offs

    def next_int(self) -> int:
        if self.gr_offs < 0:
            addr = self.gr_top + self.gr_offs
            self.gr_offs += 8
            if addr >= self.gr_top - 64:
                return struct.unpack('<Q', self.m.uc.mem_read(addr, 8))[0]
        val = struct.unpack('<Q', self.m.uc.mem_read(self.stack, 8))[0]
        self.stack += 8
        return val

    def next_double(self) -> float:
        if self.vr_offs < 0:
            addr = self.vr_top + self.vr_offs
            self.vr_offs += 16
            if addr >= self.vr_top - 128:
                return struct.unpack('<d', self.m.uc.mem_read(addr, 8))[0]
        val = struct.unpack('<d', self.m.uc.mem_read(self.stack, 8))[0]
        self.stack += 8
        return val


class _RegArgs:
    """AAPCS64 variadic argument reader starting at general register `start_gr`."""

    def __init__(self, m: E.Machine, start_gr: int, start_vr: int = 0) -> None:
        self.m = m
        self.gr = start_gr
        self.vr = start_vr
        self.sp = m.uc.reg_read(UC_ARM64_REG_SP)

    def next_int(self) -> int:
        if self.gr < 8:
            v = self.m.x(self.gr)
            self.gr += 1
            return v
        v = struct.unpack('<Q', self.m.uc.mem_read(self.sp, 8))[0]
        self.sp += 8
        return v

    def next_double(self) -> float:
        if self.vr < 8:
            bits = self.m.uc.reg_read(UC_ARM64_REG_D0 + self.vr)
            self.vr += 1
            return struct.unpack('<d', struct.pack('<Q', bits))[0]
        v = struct.unpack('<d', self.m.uc.mem_read(self.sp, 8))[0]
        self.sp += 8
        return v


def _format_c(m: E.Machine, fmt_bytes: bytes, args: _VaList | _RegArgs) -> bytes:
    fmt = fmt_bytes.decode('latin1')
    out: list[str] = []
    pos = 0
    for match in _FMT_RE.finditer(fmt):
        out.append(fmt[pos:match.start()])
        pos = match.end()
        flags, width_s, prec_s, length, spec = match.groups()
        if spec == '%':
            out.append('%')
            continue
        width = args.next_int() if width_s == '*' else (int(width_s) if width_s else None)
        if width is not None:
            width &= 0xFFFFFFFF
            if width > 0x7FFFFFFF:
                width -= 0x100000000
        prec = args.next_int() if prec_s == '*' else (int(prec_s) if prec_s is not None else None)
        if prec is not None:
            prec &= 0xFFFFFFFF
            if prec > 0x7FFFFFFF:
                prec -= 0x100000000
            # C99 7.19.6.1p5: a negative precision argument is taken as if the precision were omitted.
            if prec < 0:
                prec = None

        if spec in 'di':
            v = args.next_int()
            if length in ('ll', 'l', 'z', 't'):
                if v >= (1 << 63):
                    v -= 1 << 64
            else:
                v &= 0xFFFFFFFF
                if v >= (1 << 31):
                    v -= 1 << 32
            s = str(abs(v))
            if prec is not None:
                s = '' if (prec == 0 and v == 0) else s.zfill(prec)
            sign = '-' if v < 0 else ('+' if '+' in flags else (' ' if ' ' in flags else ''))
            if width and '0' in flags and '-' not in flags and prec is None:
                s = sign + s.zfill(max(0, width - len(sign)))
            else:
                s = sign + s
        elif spec in 'uoxXp':
            v = args.next_int()
            if spec == 'p':
                v &= 0xFFFFFFFFFFFFFFFF
                s = f'0x{v:x}'
            else:
                if length not in ('ll', 'l', 'z', 't'):
                    v &= 0xFFFFFFFF
                if spec == 'u':
                    s = str(v)
                elif spec == 'o':
                    s = oct(v)[2:]
                elif spec == 'x':
                    s = hex(v)[2:]
                else:
                    s = hex(v)[2:].upper()
                if prec is not None:
                    s = '' if (prec == 0 and v == 0) else s.zfill(prec)
                prefix = (
                    ('0x' if spec == 'x' else ('0X' if spec == 'X' else ('0' if spec == 'o' else '')))
                    if ('#' in flags and v != 0)
                    else ''
                )
                if width and '0' in flags and '-' not in flags and prec is None:
                    s = prefix + s.zfill(max(0, width - len(prefix)))
                else:
                    s = prefix + s
        elif spec in 'fFeEgGaA':
            fv = args.next_double()
            p_str = f'.{prec}' if prec is not None else ''
            py_fmt = f'%{flags}{width or ""}{p_str}{spec}'
            try:
                s = py_fmt % fv
            except Exception:
                s = str(fv)
        elif spec == 'c':
            s = chr(args.next_int() & 0xFF)
        elif spec == 's':
            p = args.next_int()
            raw = (
                E._cstr(m, p, prec if prec is not None else (1 << 20)).decode('latin1')
                if p
                else '(null)'
            )
            if prec is not None:
                raw = raw[:prec]
            s = raw
        else:
            s = ''
        if width is not None:
            if width < 0 or '-' in flags:
                s = s.ljust(abs(width))
            else:
                s = s.rjust(width)
        out.append(s)
    out.append(fmt[pos:])
    return ''.join(out).encode('latin1')


def _strcpy(m: E.Machine) -> int:
    d, s = m.x(0), E._cstr(m, m.x(1)) + b'\0'
    m.uc.mem_write(d, s)
    return d


def _strncpy(m: E.Machine) -> int:
    d, n = m.x(0), m.x(2)
    if n:
        s = E._cstr(m, m.x(1), n)
        m.uc.mem_write(d, s[:n].ljust(n, b'\0'))
    return d


def _strcat(m: E.Machine) -> int:
    d = m.x(0)
    a = E._cstr(m, d)
    b = E._cstr(m, m.x(1)) + b'\0'
    m.uc.mem_write(d + len(a), b)
    return d


def _strncat(m: E.Machine) -> int:
    d, n = m.x(0), m.x(2)
    a = E._cstr(m, d)
    b = E._cstr(m, m.x(1), n)[:n] + b'\0'
    m.uc.mem_write(d + len(a), b)
    return d


def _strchr(m: E.Machine) -> int:
    s_addr, c = m.x(0), m.x(1) & 0xFF
    s = E._cstr(m, s_addr)
    if c == 0:
        return s_addr + len(s)
    idx = s.find(c)
    return (s_addr + idx) if idx >= 0 else 0


def _strrchr(m: E.Machine) -> int:
    s_addr, c = m.x(0), m.x(1) & 0xFF
    s = E._cstr(m, s_addr)
    if c == 0:
        return s_addr + len(s)
    idx = s.rfind(c)
    return (s_addr + idx) if idx >= 0 else 0


def _strstr(m: E.Machine) -> int:
    h_addr = m.x(0)
    h, n = E._cstr(m, h_addr), E._cstr(m, m.x(1))
    if not n:
        return h_addr
    idx = h.find(n)
    return (h_addr + idx) if idx >= 0 else 0


def _strcasecmp(m: E.Machine) -> int:
    a, b = E._cstr(m, m.x(0)).lower(), E._cstr(m, m.x(1)).lower()
    return 0 if a == b else (1 if a > b else (-1 & 0xFFFFFFFFFFFFFFFF))


def _tolower(m: E.Machine) -> int:
    c = m.x(0) & 0xFF
    return c + 32 if 65 <= c <= 90 else c


def _toupper(m: E.Machine) -> int:
    c = m.x(0) & 0xFF
    return c - 32 if 97 <= c <= 122 else c


def _isspace(m: E.Machine) -> int:
    return 1 if (m.x(0) & 0xFF) in b' \t\n\r\x0b\x0c' else 0


def _isalpha(m: E.Machine) -> int:
    c = m.x(0) & 0xFF
    return 1 if (65 <= c <= 90 or 97 <= c <= 122) else 0


def _isalnum(m: E.Machine) -> int:
    c = m.x(0) & 0xFF
    return 1 if (48 <= c <= 57 or 65 <= c <= 90 or 97 <= c <= 122) else 0


def _atoi(m: E.Machine) -> int:
    s = E._cstr(m, m.x(0)).decode('latin1').lstrip()
    rm = re.match(r'^[+-]?\d+', s)
    v = int(rm.group(0)) if rm else 0
    return v & 0xFFFFFFFFFFFFFFFF


def _strtol(m: E.Machine) -> int:
    s_addr, endptr, base = m.x(0), m.x(1), m.x(2) & 0xFFFFFFFF
    if base > 0x7FFFFFFF:
        base -= 0x100000000
    raw = E._cstr(m, s_addr).decode('latin1')
    stripped = raw.lstrip()
    lead = len(raw) - len(stripped)
    if base == 0:
        if stripped.startswith(('0x', '0X', '+0x', '+0X', '-0x', '-0X')):
            rm = re.match(r'^[+-]?0[xX][0-9a-fA-F]+', stripped)
            b_val = 16
        elif stripped.startswith(('0', '+0', '-0')):
            rm = re.match(r'^[+-]?[0-7]+', stripped)
            b_val = 8
        else:
            rm = re.match(r'^[+-]?\d+', stripped)
            b_val = 10
    elif base == 16:
        rm = re.match(r'^[+-]?(?:0[xX])?[0-9a-fA-F]+', stripped)
        b_val = 16
    elif base == 8:
        rm = re.match(r'^[+-]?[0-7]+', stripped)
        b_val = 8
    else:
        rm = re.match(r'^[+-]?[0-9a-zA-Z]+', stripped)
        b_val = base if 2 <= base <= 36 else 10
    if rm:
        tok = rm.group(0)
        try:
            v = int(tok, b_val)
            end = s_addr + lead + len(tok)
        except ValueError:
            v, end = 0, s_addr
    else:
        v, end = 0, s_addr
    if endptr:
        m.uc.mem_write(endptr, struct.pack('<Q', end))
    return v & 0xFFFFFFFFFFFFFFFF


def _setjmp(m: E.Machine) -> int:
    buf = m.x(0)
    uc = m.uc
    regs = [uc.reg_read(UC_ARM64_REG_X19 + i) for i in range(10)]
    regs.append(uc.reg_read(UC_ARM64_REG_X29))
    regs.append(uc.reg_read(UC_ARM64_REG_LR))
    regs.append(uc.reg_read(UC_ARM64_REG_SP))
    dregs = [uc.reg_read(UC_ARM64_REG_D8 + i) for i in range(8)]
    uc.mem_write(buf, struct.pack('<13Q8Q', *regs, *dregs))
    return 0


def _longjmp(m: E.Machine) -> int:
    buf, val = m.x(0), m.x(1) & 0xFFFFFFFF
    if val == 0:
        val = 1
    uc = m.uc
    data = struct.unpack('<13Q8Q', uc.mem_read(buf, 21 * 8))
    for i in range(10):
        uc.reg_write(UC_ARM64_REG_X19 + i, data[i])
    uc.reg_write(UC_ARM64_REG_X29, data[10])
    uc.reg_write(UC_ARM64_REG_LR, data[11])
    uc.reg_write(UC_ARM64_REG_SP, data[12])
    for i in range(8):
        uc.reg_write(UC_ARM64_REG_D8 + i, data[13 + i])
    return val


def _sprintf(m: E.Machine) -> int:
    dst, fmt = m.x(0), E._cstr(m, m.x(1))
    res = _format_c(m, fmt, _RegArgs(m, 2))
    m.uc.mem_write(dst, res + b'\0')
    return len(res)


def _snprintf(m: E.Machine) -> int:
    dst, sz, fmt = m.x(0), m.x(1), E._cstr(m, m.x(2))
    res = _format_c(m, fmt, _RegArgs(m, 3))
    if dst and sz > 0:
        m.uc.mem_write(dst, res[:sz - 1] + b'\0')
    return len(res)


def _vsprintf(m: E.Machine) -> int:
    dst, fmt, va = m.x(0), E._cstr(m, m.x(1)), m.x(2)
    res = _format_c(m, fmt, _VaList(m, va))
    m.uc.mem_write(dst, res + b'\0')
    return len(res)


def _vsnprintf(m: E.Machine) -> int:
    dst, sz, fmt, va = m.x(0), m.x(1), E._cstr(m, m.x(2)), m.x(3)
    res = _format_c(m, fmt, _VaList(m, va))
    if dst and sz > 0:
        m.uc.mem_write(dst, res[:sz - 1] + b'\0')
    return len(res)


def _sscanf(m: E.Machine) -> int:
    s = E._cstr(m, m.x(0)).decode('latin1')
    fmt = E._cstr(m, m.x(1)).decode('latin1')
    args = _RegArgs(m, 2)
    pos = 0
    s_pos = 0
    count = 0
    for match in _SCANF_RE.finditer(fmt):
        lit = fmt[pos:match.start()]
        for ch in lit:
            if ch.isspace():
                while s_pos < len(s) and s[s_pos].isspace():
                    s_pos += 1
            else:
                if s_pos >= len(s) or s[s_pos] != ch:
                    return count
                s_pos += 1
        pos = match.end()
        suppress, width_s, length, spec = match.groups()
        if spec == '%':
            if s_pos < len(s) and s[s_pos] == '%':
                s_pos += 1
            else:
                break
            continue
        if spec not in ('c', 'n') and not spec.startswith('['):
            while s_pos < len(s) and s[s_pos].isspace():
                s_pos += 1
        if spec != 'n' and s_pos >= len(s):
            return (-1 & 0xFFFFFFFFFFFFFFFF) if count == 0 else count
        sub = s[s_pos:s_pos + int(width_s)] if width_s else s[s_pos:]
        if spec in ('d', 'i', 'u', 'x', 'X', 'o'):
            base = 10 if spec in ('d', 'u') else (16 if spec in ('x', 'X') else (8 if spec == 'o' else 0))
            pat = (
                r'^[+-]?(?:0[xX])?[0-9a-fA-F]+'
                if base in (0, 16)
                else (r'^[+-]?[0-7]+' if base == 8 else r'^[+-]?\d+')
            )
            rm = re.match(pat, sub)
            if not rm:
                break
            tok = rm.group(0)
            val = int(tok, base)
            s_pos += len(tok)
            if not suppress:
                ptr = args.next_int()
                if length in ('ll', 'l', 'z', 't'):
                    m.uc.mem_write(ptr, struct.pack('<Q', val & 0xFFFFFFFFFFFFFFFF))
                elif length == 'h':
                    m.uc.mem_write(ptr, struct.pack('<H', val & 0xFFFF))
                elif length == 'hh':
                    m.uc.mem_write(ptr, struct.pack('<B', val & 0xFF))
                else:
                    m.uc.mem_write(ptr, struct.pack('<I', val & 0xFFFFFFFF))
                count += 1
        elif spec in ('f', 'F', 'e', 'E', 'g', 'G', 'a', 'A'):
            rm = re.match(r'^[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?', sub)
            if not rm:
                break
            tok = rm.group(0)
            fval = float(tok)
            s_pos += len(tok)
            if not suppress:
                ptr = args.next_int()
                if length == 'l':
                    m.uc.mem_write(ptr, struct.pack('<d', fval))
                else:
                    m.uc.mem_write(ptr, struct.pack('<f', fval))
                count += 1
        elif spec == 's':
            rm = re.match(r'^\S+', sub)
            if not rm:
                break
            tok = rm.group(0)
            s_pos += len(tok)
            if not suppress:
                ptr = args.next_int()
                m.uc.mem_write(ptr, tok.encode('latin1') + b'\0')
                count += 1
        elif spec == 'c':
            n_ch = int(width_s) if width_s else 1
            if len(sub) < n_ch:
                break
            tok = sub[:n_ch]
            s_pos += n_ch
            if not suppress:
                ptr = args.next_int()
                m.uc.mem_write(ptr, tok.encode('latin1'))
                count += 1
        elif spec == 'n':
            if not suppress:
                ptr = args.next_int()
                m.uc.mem_write(ptr, struct.pack('<i', s_pos))
    return count


def _d_get(m: E.Machine, i: int = 0) -> float:
    return struct.unpack('<d', struct.pack('<Q', m.uc.reg_read(UC_ARM64_REG_D0 + i)))[0]


def _d_set(m: E.Machine, v: float) -> None:
    m.uc.reg_write(UC_ARM64_REG_D0, struct.unpack('<Q', struct.pack('<d', float(v)))[0])
    return None


def _f_get(m: E.Machine, i: int = 0) -> float:
    return struct.unpack('<f', struct.pack('<I', m.uc.reg_read(UC_ARM64_REG_S0 + i) & 0xFFFFFFFF))[0]


def _f_set(m: E.Machine, v: float) -> None:
    m.uc.reg_write(UC_ARM64_REG_S0, struct.unpack('<I', struct.pack('<f', float(v)))[0])
    return None


def _atof(m: E.Machine) -> None:
    s = E._cstr(m, m.x(0)).decode('latin1').lstrip()
    rm = re.match(r'^[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?', s)
    v = float(rm.group(0)) if rm else 0.0
    return _d_set(m, v)


def _math1(fn: Callable[[float], float]) -> Callable[[E.Machine], None]:
    def h(m: E.Machine) -> None:
        try:
            r = fn(_d_get(m, 0))
        except ValueError:
            r = float('nan')
        except OverflowError:
            r = float('inf')
        return _d_set(m, r)
    return h


def _math1f(fn: Callable[[float], float]) -> Callable[[E.Machine], None]:
    def h(m: E.Machine) -> None:
        try:
            r = fn(_f_get(m, 0))
        except ValueError:
            r = float('nan')
        except OverflowError:
            r = float('inf')
        return _f_set(m, r)
    return h


def _math2(fn: Callable[[float, float], float]) -> Callable[[E.Machine], None]:
    def h(m: E.Machine) -> None:
        try:
            r = fn(_d_get(m, 0), _d_get(m, 1))
        except ValueError:
            r = float('nan')
        except OverflowError:
            r = float('inf')
        return _d_set(m, r)
    return h


def _ldexp(m: E.Machine) -> None:
    exp = m.x(0) & 0xFFFFFFFF
    if exp >= (1 << 31):
        exp -= 1 << 32
    try:
        r = math.ldexp(_d_get(m, 0), exp)
    except OverflowError:
        r = float('inf')
    return _d_set(m, r)


def _frexp(m: E.Machine) -> None:
    mant, exp = math.frexp(_d_get(m, 0))
    if m.x(0):
        m.uc.mem_write(m.x(0), struct.pack('<i', exp))
    return _d_set(m, mant)


def _zero(_m: E.Machine) -> int:
    return 0


_EXP2 = math.exp2 if hasattr(math, 'exp2') else lambda x: 2.0 ** x

_GLSLC_EXTRA_TRAPS: dict[str, object] = {
    'NvOsMutexDestroy': _zero,
    'NvOsMutexLock': _zero,
    'NvOsMutexUnlock': _zero,
    'NvOsFopen': _zero,
    'NvOsFclose': _zero,
    'NvOsFread': _zero,
    'NvOsFwrite': _zero,
    'NvOsFseek': _zero,
    'NvOsFtell': _zero,
    'getenv': _zero,
    'feof': _zero,
    'fflush': _zero,
    'fprintf': _zero,
    'fputc': _zero,
    'fputs': _zero,
    'fseek': _zero,
    'ftell': _zero,
    'fwrite': _zero,
    'printf': _zero,
    'putc': _zero,
    'puts': _zero,
    'vfprintf': _zero,
    'strcpy': _strcpy,
    'strncpy': _strncpy,
    'strcat': _strcat,
    'strncat': _strncat,
    'strchr': _strchr,
    'strrchr': _strrchr,
    'strstr': _strstr,
    'strcasecmp': _strcasecmp,
    'tolower': _tolower,
    'toupper': _toupper,
    'isspace': _isspace,
    'isalpha': _isalpha,
    'isalnum': _isalnum,
    'atoi': _atoi,
    'atof': _atof,
    'strtol': _strtol,
    'sscanf': _sscanf,
    'sprintf': _sprintf,
    'snprintf': _snprintf,
    'vsprintf': _vsprintf,
    'vsnprintf': _vsnprintf,
    'setjmp': _setjmp,
    'longjmp': _longjmp,
    'ldexp': _ldexp,
    'frexp': _frexp,
    'exp2': _math1(_EXP2),
    'exp2f': _math1f(_EXP2),
    'log': _math1(math.log),
    'logf': _math1f(math.log),
    'pow': _math2(math.pow),
    'cos': _math1(math.cos),
    'sin': _math1(math.sin),
    'tan': _math1(math.tan),
    'tanh': _math1(math.tanh),
    'acos': _math1(math.acos),
    'asin': _math1(math.asin),
    'atan': _math1(math.atan),
    'atan2': _math2(math.atan2),
    'sqrt': _math1(math.sqrt),
    'exp': _math1(math.exp),
    'fmod': _math2(math.fmod),
}


class GlslcCompiler:
    """Host a Switch `GLSLC` NSO module inside `arm64_emu.Machine` and run `glslcCompile`."""

    def __init__(self, nso_path: str | Path, *, heap_size: int = 96 << 20) -> None:
        self.path = Path(nso_path)
        self.m = m = E.Machine([(self.path.name, self.path)], heap_size=heap_size)
        self.mod = mod = m.mods[0]
        if 'glslcCompile' not in mod.exports or 'glslcInitialize' not in mod.exports:
            raise E.EmuError(f'{self.path}: missing glslcInitialize / glslcCompile exports')

        alloc_struct = m.malloc(64)
        dummy_mutex = m.malloc(64)
        strtok_state = [0]

        def _get_alloc(_m: E.Machine) -> int:
            return alloc_struct

        def _mutex_create(m_: E.Machine) -> int:
            if m_.x(0):
                m_.uc.mem_write(m_.x(0), struct.pack('<Q', dummy_mutex))
            return 0

        def _strtok(m_: E.Machine) -> int:
            s_addr, delim_addr = m_.x(0), m_.x(1)
            if s_addr:
                strtok_state[0] = s_addr
            cur = strtok_state[0]
            if not cur:
                return 0
            s = E._cstr(m_, cur)
            delim = set(E._cstr(m_, delim_addr))
            i = 0
            while i < len(s) and s[i] in delim:
                i += 1
            if i == len(s):
                strtok_state[0] = 0
                return 0
            tok_start = cur + i
            j = i
            while j < len(s) and s[j] not in delim:
                j += 1
            if j < len(s):
                m_.uc.mem_write(cur + j, b'\0')
                strtok_state[0] = cur + j + 1
            else:
                strtok_state[0] = 0
            return tok_start

        m.TRAPS = dict(E.Machine.TRAPS)
        m.TRAPS.update(_GLSLC_EXTRA_TRAPS)
        m.TRAPS['glslc_GetAllocator'] = _get_alloc
        m.TRAPS['NvOsMutexCreate'] = _mutex_create
        m.TRAPS['strtok'] = _strtok

        if 'glslcSetAllocator' in mod.exports:
            m.call(mod.base + mod.exports['glslcSetAllocator'], 0x1000, 0x2000, 0x3000, 0)

        self.init_addr = mod.base + mod.exports['glslcInitialize']
        self.comp_addr = mod.base + mod.exports['glslcCompile']
        self.fin_addr = (mod.base + mod.exports['glslcFinalize']) if 'glslcFinalize' in mod.exports else None

        # Allocate a persistent compile object to read default `optionFlags` and hold GLSLC's
        # ~18 MB standard-library symbol table warm across subsequent `compile_program` calls.
        self.warm_obj = m.malloc(0x400)
        rc = m.call(self.init_addr, self.warm_obj)
        if not (rc & 0xFF):
            raise E.EmuError(f'{self.path}: glslcInitialize failed')
        self.default_flags = struct.unpack('<I', m.read(self.warm_obj + 0x20, 4))[0]
        self.init_mark = m.heap_mark()
        self.warm_mark: int | None = None

    def compile_program(
        self,
        sources: Iterable[bytes],
        stages: Iterable[int],
        *,
        option_flags: int | None = None,
    ) -> bytes | None:
        """Compile `sources` with `stages` and return the raw `.glslc` output bytes, or `None`."""
        src_list = [s if s.endswith(b'\0') else (s + b'\0') for s in sources]
        stg_list = [int(st) for st in stages]
        if not src_list or len(src_list) != len(stg_list):
            return None

        m = self.m
        flags = self.default_flags if option_flags is None else int(option_flags)

        if self.warm_mark is None:
            obj = self.warm_obj
            is_first = True
        else:
            obj = m.malloc(0x400)
            rc = m.call(self.init_addr, obj)
            if not (rc & 0xFF):
                m.heap_reset(self.warm_mark)
                return None
            is_first = False

        try:
            m.write(obj + 0x20, struct.pack('<I', flags & 0xFFFFFFFF))
            src_ptrs = []
            for s in src_list:
                sp = m.malloc(len(s))
                m.write(sp, s)
                src_ptrs.append(sp)
            srcs_arr = m.malloc(8 * len(src_ptrs))
            m.write(srcs_arr, struct.pack(f'<{len(src_ptrs)}Q', *src_ptrs))
            stgs_arr = m.malloc(4 * len(stg_list))
            m.write(stgs_arr, struct.pack(f'<{len(stg_list)}I', *stg_list))
            m.write(obj + 0xA8, struct.pack('<QQB', srcs_arr, stgs_arr, len(src_list)))

            rc = m.call(self.comp_addr, obj, timeout_us=60_000_000)
            if not (rc & 0xFF):
                return None

            res_ptr = struct.unpack('<Q', m.read(obj, 8))[0]
            if not res_ptr:
                return None
            stat_ptr, out_ptr = struct.unpack('<QQ', m.read(res_ptr, 16))
            if not stat_ptr or not out_ptr:
                return None
            ok_flag, alloc_err = struct.unpack('<BB', m.read(stat_ptr + 0x0C, 2))
            if not ok_flag or alloc_err:
                return None
            magic = struct.unpack('<I', m.read(out_ptr, 4))[0]
            size = struct.unpack('<I', m.read(out_ptr + 0x44, 4))[0]
            if magic != GLSLC_MAGIC or size < 0x48 or size > (64 << 20):
                return None
            out = m.read(out_ptr, size)
            if is_first:
                self.warm_mark = m.heap_mark()
            return out
        finally:
            if not is_first and self.fin_addr is not None:
                try:
                    m.call(self.fin_addr, obj)
                except Exception:
                    pass
            m.heap_reset(self.warm_mark if self.warm_mark is not None else self.init_mark)


def _iter_nro_files(ver_dir: Path, nro_dirs: Iterable[str | Path]) -> list[Path]:
    """Locate distinct `.nro` files associated with `ver_dir` and `nro_dirs`."""
    roots: list[Path] = []
    for d in nro_dirs:
        if d:
            p = Path(d)
            if p.is_dir():
                roots.append(p)
    for sub in ('romfs_nro', 'RomFS/nro', 'RomFS'):
        cand = ver_dir / sub
        if cand.is_dir():
            roots.append(cand)

    out: list[Path] = []
    seen_hashes: set[bytes] = set()
    for r in roots:
        for dp, _, names in os.walk(r):
            for name in sorted(names):
                if not name.lower().endswith('.nro'):
                    continue
                fp = Path(dp) / name
                try:
                    with open(fp, 'rb') as f:
                        head = f.read(0x40)
                    if len(head) < 0x40 or head[0x10:0x14] != b'NRO0':
                        continue
                    data = fp.read_bytes()
                except OSError:
                    continue
                digest = hashlib.sha256(data).digest()
                if digest in seen_hashes:
                    continue
                seen_hashes.add(digest)
                out.append(fp)
    return out


def compile_for_version(
    ver_dir: str | Path,
    out_dir: str | Path,
    *,
    nro_dirs: Iterable[str | Path] = (),
    wanted: set[str] | None = None,
    say: Callable[[str], None] | None = None,
    progress: Callable[[int], None] | None = None,
) -> set[str]:
    """Compile runtime GLSLC shaders for `ver_dir` into `out_dir` and return written filenames."""
    vpath = Path(ver_dir)
    opath = Path(out_dir)
    exefs = vpath / 'ExeFS'
    glslc_nso = find_glslc_nso(exefs)
    if glslc_nso is None:
        return set()

    jobs: list[tuple[tuple[bytes, ...], tuple[int, ...], bool]] = []
    for nro_fp in _iter_nro_files(vpath, nro_dirs):
        try:
            jobs.extend(collect_nro_programs(nro_fp.read_bytes()))
        except OSError:
            continue
    jobs.extend(collect_main_programs(exefs / 'main'))
    if not jobs:
        jobs.extend(collect_romfs_glsl_programs(vpath / 'RomFS'))
    if not jobs:
        return set()

    compiler = GlslcCompiler(glslc_nso)
    opath.mkdir(parents=True, exist_ok=True)
    written: set[str] = set()

    for srcs, stgs, refl_dbg in jobs:
        if wanted and written >= wanted:
            break
        pref_flags = (
            (compiler.default_flags | SOURCE_MATSYS_FLAG_BITS)
            if refl_dbg
            else compiler.default_flags
        )
        alt_flags = pref_flags ^ SOURCE_MATSYS_FLAG_BITS
        flag_cands = [pref_flags, alt_flags] if wanted else [pref_flags]

        for flg in flag_cands:
            out_bytes = compiler.compile_program(srcs, stgs, option_flags=flg)
            if not out_bytes:
                continue
            fname = f'{fnv1a_64(out_bytes):016x}.glslc'
            if wanted and fname not in wanted:
                continue
            (opath / fname).write_bytes(out_bytes)
            written.add(fname)
            if progress is not None:
                progress(len(written & wanted if wanted else written))
            if say is not None:
                say(f'glslc: compiled run-time shader {fname} ({len(out_bytes)} bytes)')
            break

    return written
