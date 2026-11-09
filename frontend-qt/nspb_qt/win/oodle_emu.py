#!/usr/bin/env python3
"""Windows replacement for the Mac host's Oodle / LZ5 decoder tool mode (`dm/host/hle_oodle.c`).

Supports the exact wire protocols expected by `shader_split.py`, `uepak.py`, and
`scripts/build_ipa_from_nsp.py`:
- `DM_OODLE_SERVE=1`:
  Reads `(comp_len: u64, raw_len: u64, comp_bytes)` requests from `stdin` and writes
  `(decoded_len: u64, raw_bytes)` responses to `stdout` (`0` on failure).
- `DM_OODLE_JOB=<job_file>`:
  Reads `"DMOJ"` (`0x4A4F4D44`), `count: u32`, and `count` records of
  `(comp_len: u32, raw_len: u32, comp_bytes)`, then writes `<job_file>.out` with `"DMOR"`
  (`0x524F4D44`), `count: u32`, and `count` records of `(decoded_len: u32, raw_bytes)`.

Performance optimizations over naive ARM64 emulation:
1. Native Windows x64 DLL Passthrough (`oo2core_*_win64.dll`):
   When a native Windows 64-bit Oodle DLL is configured in an explicit location (`NSPB_OODLE_DLL`,
   `toolchain.json`, or `%LOCALAPPDATA%\\NS Port Builder\\tools\\oodle`), `OodleLZ_Decompress` calls
   execute natively on the host CPU via `ctypes` without starting Unicorn, falling back to the
   game's ARM64 decoder only if a block fails.
2. Single-Module Loading & Work-Folder Pre-Relocated Image Cache:
   Only the module holding the decoder (`main`, or a `subsdk` if absent from `main`) is loaded,
   skipping the multi-megabyte Nintendo `sdk` NSO. Once relocated, the module snapshot and decoder
   offsets are stored under the build work folder as plain JSON metadata plus raw binary bytes
   keyed by the hashes of `arm64_emu.py`, `oodle_emu.py`, and the module's `(path, size, mtime_ns)`.
3. In-VM ARM64 Fast Stubs (`arm64_emu.FAST_BASE`):
   `memcpy`, `memmove`, `memset`, `memcmp`, `strlen`, `malloc`, `calloc`, and `free` run as native
   ARM64 machine code inside the VM with zero Python `UC_HOOK_CODE` traps.
4. Pre-Allocated Fixed I/O Buffers & Pre-Packed Stack Frames:
   Input/output buffers and stack arguments are allocated once per `Decoder` instance and reused
   across all requests.
5. Multi-Core Parallel `DM_OODLE_JOB` Sharding:
   Large Unreal shader jobs (such as OCTOPATH TRAVELER 0's 10,596 shaders) are sharded across
   parallel worker processes that warm-start from the work-folder relocation cache.
"""
from __future__ import annotations

import ctypes
import hashlib
import json
import os
import struct
import subprocess
import sys
import zlib
from pathlib import Path

if __package__:
    from . import arm64_emu as E
else:
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import arm64_emu as E  # type: ignore[no-redef]

_CACHE_VERSION = b'nspb-oodle-cache-v3-json-bin'
_REDIRECT_SIGNATURES = (b'LZ5_decompress_safe', b'OodleLZ_Decompress', b'oodlelzcompressors.cpp')


def log(msg: str) -> None:
    print(f'[dm] {msg}', file=sys.stderr, flush=True)


def die(msg: str) -> None:
    log(msg)
    raise SystemExit(1)


def exefs_for(patched: str | Path) -> Path:
    """Locate the original (unpatched) ExeFS directory corresponding to `patched`."""
    for env_key in ('NSPB_EXEFS', 'NXW_EXEFS'):
        if os.environ.get(env_key):
            p = Path(os.environ[env_key])
            if p.is_file() and p.name == 'main':
                return p.parent
            if (p / 'main').is_file():
                return p
    p = Path(patched).resolve()
    if p.is_file() and p.name == 'main':
        return p.parent
    ver = p.name.removeprefix('patched_')
    for cand in (
        p.parent / 'extract' / ver / 'ExeFS',
        p.parent.parent / 'extract' / ver / 'ExeFS',
        p,
    ):
        if (cand / 'main').is_file():
            return cand
    die(f'oodle_emu: no extracted ExeFS for {p} (set NSPB_EXEFS)')
    raise AssertionError('unreachable')


def has_decoder(paths: list[str | Path] | str | Path) -> bool:
    """Fast static check: True if any module in `paths` embeds an Oodle or LZ5 decoder."""
    if isinstance(paths, (str, Path)):
        paths = [paths]
    checked: set[Path] = set()
    for item in paths:
        p = Path(item)
        cands: list[Path] = []
        if p.is_file():
            cands.append(p)
            for sub in sorted(p.parent.glob('subsdk*')):
                if sub.is_file():
                    cands.append(sub)
        elif p.is_dir():
            if (p / 'main').is_file():
                cands.append(p / 'main')
            for sub in sorted(p.glob('subsdk*')):
                if sub.is_file():
                    cands.append(sub)
        for mod_path in cands:
            try:
                rp = mod_path.resolve()
            except OSError:
                rp = mod_path
            if rp in checked:
                continue
            checked.add(rp)
            try:
                img, *_ = E.nso_load(mod_path)
            except Exception:
                try:
                    img = bytearray(mod_path.read_bytes())
                except OSError:
                    continue
            if any(sig in img for sig in _REDIRECT_SIGNATURES):
                return True
    return False


# ---- Native Windows x86_64 Oodle DLL Passthrough ----
def _load_toolchain_module():
    if __package__:
        from . import toolchain as tc
        return tc
    import toolchain as tc  # type: ignore[no-redef]
    return tc


def find_native_oodle_dll() -> Path | None:
    """Locate a native 64-bit Oodle DLL (`oo2core_*_win64.dll`) from explicit locations only.

    Checks `NSPB_OODLE_DLL`, `oodle_dll` in `toolchain.json`, and
    `%LOCALAPPDATA%\\NS Port Builder\\tools\\oodle` (`toolchain.tools_dir() / 'oodle'`). Never
    probes `PATH` or the current working directory.
    """
    cands: list[Path] = []
    if env_dll := os.environ.get('NSPB_OODLE_DLL'):
        ep = Path(env_dll)
        if ep.is_file():
            cands.append(ep)
        elif ep.is_dir():
            cands.extend(sorted(ep.glob('oo2core_*_win64.dll'), reverse=True))
            cands.extend(sorted(ep.glob('oo2core_*.dll'), reverse=True))
    try:
        tc = _load_toolchain_module()
        cfg = tc.load_config()
        if cfg_dll := cfg.get('oodle_dll'):
            cp = Path(cfg_dll)
            if cp.is_file():
                cands.append(cp)
            elif cp.is_dir():
                cands.extend(sorted(cp.glob('oo2core_*_win64.dll'), reverse=True))
                cands.extend(sorted(cp.glob('oo2core_*.dll'), reverse=True))
        tools_oodle = tc.tools_dir() / 'oodle'
        if tools_oodle.is_dir():
            cands.extend(sorted(tools_oodle.glob('oo2core_*_win64.dll'), reverse=True))
            cands.extend(sorted(tools_oodle.glob('oo2core_*.dll'), reverse=True))
    except Exception:
        pass
    for c in cands:
        if c.is_file():
            return c
    return None


class NativeOodleDll:
    """Wrapper around a native host `oo2core_*_win64.dll` exporting `OodleLZ_Decompress`."""

    def __init__(self, dll_path: Path) -> None:
        self.path = dll_path
        lib = ctypes.CDLL(str(dll_path))
        fn = getattr(lib, 'OodleLZ_Decompress', None)
        if fn is None:
            raise RuntimeError(f'{dll_path} does not export OodleLZ_Decompress')
        fn.restype = ctypes.c_int64
        fn.argtypes = [
            ctypes.c_char_p, ctypes.c_int64,
            ctypes.c_void_p, ctypes.c_int64,
            ctypes.c_int, ctypes.c_int, ctypes.c_int,
            ctypes.c_void_p, ctypes.c_int64,
            ctypes.c_void_p, ctypes.c_void_p,
            ctypes.c_void_p, ctypes.c_int64,
            ctypes.c_int,
        ]
        self._fn = fn
        self._scratch_n = 16 << 20
        self._scratch = ctypes.create_string_buffer(self._scratch_n)
        self._out_cap = 16 << 20
        self._out_buf = ctypes.create_string_buffer(self._out_cap)

    def decompress(self, comp: bytes, rl: int) -> bytes | None:
        if rl < 0:
            return None
        if rl == 0:
            return b''
        need_out = rl + 0x10000
        out_buf = self._out_buf if need_out <= self._out_cap else ctypes.create_string_buffer(need_out)
        got = self._fn(
            comp, len(comp),
            out_buf, rl,
            1, 0, 0,
            None, 0,
            None, None,
            self._scratch, self._scratch_n,
            3,
        )
        if got == rl:
            return ctypes.string_at(out_buf, rl)
        return None


# ---- Finding the decoder in an NSO module (`dm/host/hle_oodle.c`) ----
def eh_table(m: E.Module) -> list[int]:
    b = m.img
    m0 = m.mod0
    if m0 < 0 or m0 > len(b) - 20:
        die(f'oodle_emu: MOD0 header out of bounds in {m.name} (mod0={m0:#x}, size={len(b):#x})')
    eh = struct.unpack_from('<i', b, m0 + 16)[0]
    ehs = m0 + eh
    if ehs < 0 or ehs > len(b) - 4:
        die(f'oodle_emu: .eh_frame_hdr out of bounds in {m.name} (ehs={ehs:#x}, size={len(b):#x})')
    penc, cenc, tenc = b[ehs + 1], b[ehs + 2], b[ehs + 3]
    o = [ehs + 4]

    def rd(enc: int) -> int:
        fmt, app, at = enc & 0xF, enc & 0x70, o[0]
        if fmt == 0x3:
            if at < 0 or at > len(b) - 4:
                die(f'oodle_emu: .eh_frame_hdr read out of bounds in {m.name} (at={at:#x})')
            v = struct.unpack_from('<I', b, at)[0]
            o[0] += 4
        elif fmt == 0xB:
            if at < 0 or at > len(b) - 4:
                die(f'oodle_emu: .eh_frame_hdr read out of bounds in {m.name} (at={at:#x})')
            v = struct.unpack_from('<i', b, at)[0]
            o[0] += 4
        elif fmt == 0x4:
            if at < 0 or at > len(b) - 8:
                die(f'oodle_emu: .eh_frame_hdr read out of bounds in {m.name} (at={at:#x})')
            v = struct.unpack_from('<Q', b, at)[0]
            o[0] += 8
        else:
            die(f'oodle_emu: .eh_frame_hdr encoding {enc:#x} not handled')
            raise AssertionError('unreachable')
        return (v + at) if app == 0x10 else (v + ehs) if app == 0x30 else v

    rd(penc)
    n = rd(cenc)
    if n < 0 or n > (len(b) - o[0]) // 8:
        die(f'oodle_emu: .eh_frame_hdr entry count {n} out of bounds in {m.name}')
    starts: list[int] = []
    for _ in range(n):
        starts.append(rd(tenc) & 0xFFFFFFFFFFFFFFFF)
        rd(tenc)
    return sorted(starts)


def func_start(starts: list[int], off: int) -> int:
    import bisect
    idx = bisect.bisect_right(starts, off)
    return starts[idx - 1] if idx > 0 else 0


def func_next(starts: list[int], off: int, text_end: int) -> int:
    import bisect
    idx = bisect.bisect_right(starts, off)
    return starts[idx] if idx < len(starts) else text_end


def str_fns(m: E.Module, starts: list[int], needle: str, whole: bool) -> list[int]:
    b = m.img
    ro, re_ = m.ro_off, m.data_off
    nb = needle.encode()
    strs: list[int] = []
    p = ro
    while len(strs) < 16:
        p = b.find(nb, p, re_)
        if p < 0:
            break
        s = p
        while s > ro and b[s - 1]:
            s -= 1
        if not whole or (s == p and p + len(nb) < len(b) and b[p + len(nb)] == 0):
            strs.append(s)
        p += len(nb)
    if not strs:
        return []
    want = set(strs)
    want_pages = {addr & ~0xFFF for addr in want}
    fns: list[int] = []
    te = m.text_end
    words = memoryview(b)[:te - te % 4].cast('I')
    n_words = len(words)
    for i in range(n_words):
        w = words[i]
        if (w & 0x9F000000) != 0x90000000:
            continue
        imm = ((w >> 29) & 3) | (((w >> 5) & 0x7FFFF) << 2)
        if imm & (1 << 20):
            imm -= 1 << 21
        page = ((i * 4) & ~0xFFF) + (imm << 12)
        if page not in want_pages:
            continue
        rd_reg = w & 31
        limit = min(n_words, i + 8)
        for k in range(i + 1, limit):
            w2 = words[k]
            if (w2 & 0xFF800000) != 0x91000000 or ((w2 >> 5) & 31) != rd_reg:
                continue
            if page + ((w2 >> 10) & 0xFFF) in want:
                f = func_start(starts, k * 4)
                if f not in fns:
                    fns.append(f)
            break
    return sorted(fns)


def _locate_decoder_in_module(mod: E.Module) -> tuple[str, int, tuple[int, int, int, int] | None] | None:
    if 'LZ5_decompress_safe' in mod.exports:
        return 'LZ5_decompress_safe', mod.exports['LZ5_decompress_safe'], None
    if b'OodleLZ_Decompress' not in mod.img and b'oodlelzcompressors.cpp' not in mod.img:
        return None
    starts = eh_table(mod)
    fns = str_fns(mod, starts, 'OodleLZ_Decompress', True)
    if len(fns) > 1:
        die(f'oodle_emu: {len(fns)} functions reference "OodleLZ_Decompress" in {mod.name} (expected 1)')
    if fns:
        return 'OodleLZ_Decompress', fns[0], None
    src = str_fns(mod, starts, 'oodlelzcompressors.cpp', False)
    leg = str_fns(
        mod,
        starts,
        'OODLE ERROR : OodleLZ_Decompress: asked to decode Legacy compressor',
        False,
    )
    if len(src) != 2 or len(leg) != 1 or leg[0] != src[0]:
        return None
    create = func_next(starts, src[0], mod.text_end)
    destroy = func_next(starts, create, mod.text_end)
    if func_next(starts, destroy, mod.text_end) != src[1]:
        return None
    base = mod.base
    lzd = (base + src[0], base + create, base + destroy, base + src[1])
    return 'OodleLZDecoder_DecodeSome', src[1], lzd


# ---- Safe JSON + raw binary relocation cache inside the build work folder ----
_SOURCE_DIGEST: bytes | None = None


def _source_digest() -> bytes:
    global _SOURCE_DIGEST
    if _SOURCE_DIGEST is None:
        h = hashlib.sha256(_CACHE_VERSION)
        for src_file in (Path(E.__file__).resolve(), Path(__file__).resolve()):
            try:
                h.update(src_file.read_bytes())
            except OSError:
                pass
        h.update(E.FAST_STUB_BYTES)
        _SOURCE_DIGEST = h.digest()
    return _SOURCE_DIGEST


def _cache_dir_for(exefs: Path, patched: str | Path | None = None) -> Path:
    if dm_root := os.environ.get('DM_ROOT'):
        return Path(dm_root) / 'tools' / 'oodle_cache'
    if patched is not None:
        p = Path(patched).resolve()
        if p.name.startswith('patched_'):
            return p.parent / 'tools' / 'oodle_cache'
    if exefs.parent.parent.name == 'extract':
        return exefs.parent.parent.parent / 'tools' / 'oodle_cache'
    return exefs.parent / 'oodle_cache'


def _cache_file_for(
    mod_paths: list[tuple[str, str]],
    *,
    exefs: Path | None = None,
    patched: str | Path | None = None,
) -> Path | None:
    if os.environ.get('NSPB_OODLE_NO_CACHE') or not mod_paths:
        return None
    h = hashlib.sha256(_source_digest())
    for name, p in mod_paths:
        try:
            st = os.stat(p)
        except OSError:
            return None
        h.update(f'{name}\0{os.path.realpath(p)}\0{st.st_size}\0{st.st_mtime_ns}\0'.encode())
    base_exefs = exefs if exefs is not None else Path(mod_paths[0][1]).resolve().parent
    cdir = _cache_dir_for(base_exefs, patched)
    return cdir / f'nspb_oodle_{h.hexdigest()[:24]}.json'


def _write_reloc_cache(meta_path: Path, snap: dict) -> None:
    meta_path.parent.mkdir(parents=True, exist_ok=True)
    bin_path = meta_path.with_suffix('.bin')
    vm = snap['vm']
    img_blobs = bytearray()
    mods_meta: list[dict] = []
    for m_info in vm['mods']:
        raw_img = bytes(m_info['img'])
        mods_meta.append({
            'name': m_info['name'],
            'base': int(m_info['base']),
            'text_end': int(m_info['text_end']),
            'ro_off': int(m_info['ro_off']),
            'data_off': int(m_info['data_off']),
            'mod0': int(m_info['mod0']),
            'exports': {str(k): int(v) for k, v in m_info['exports'].items()},
            'img_offset': len(img_blobs),
            'img_size': len(raw_img),
        })
        img_blobs.extend(raw_img)

    doc = {
        'format': 1,
        'kind': snap['kind'],
        'off': int(snap['off']),
        'mod_name': snap['mod_name'],
        'lzd': list(snap['lzd']) if snap['lzd'] is not None else None,
        'traps': {str(k): int(v) for k, v in vm['traps'].items()},
        'trap_names': list(vm['trap_names']),
        'total_img_bytes': len(img_blobs),
        'mods': mods_meta,
    }
    comp_bin = zlib.compress(bytes(img_blobs), level=1)
    pid = os.getpid()
    tmp_bin = bin_path.with_name(f'{bin_path.name}.tmp.{pid}')
    tmp_meta = meta_path.with_name(f'{meta_path.name}.tmp.{pid}')
    try:
        tmp_bin.write_bytes(comp_bin)
        os.replace(tmp_bin, bin_path)
        tmp_meta.write_text(json.dumps(doc), encoding='utf-8')
        os.replace(tmp_meta, meta_path)
    finally:
        tmp_bin.unlink(missing_ok=True)
        tmp_meta.unlink(missing_ok=True)


def _read_reloc_cache(meta_path: Path) -> dict | None:
    bin_path = meta_path.with_suffix('.bin')
    if not meta_path.is_file() or not bin_path.is_file():
        return None
    try:
        doc = json.loads(meta_path.read_text(encoding='utf-8'))
        if not isinstance(doc, dict) or doc.get('format') != 1:
            return None
        raw_all = zlib.decompress(bin_path.read_bytes())
        total_expected = int(doc.get('total_img_bytes', -1))
        if len(raw_all) != total_expected:
            return None
        mv = memoryview(raw_all)
        mods_out: list[dict] = []
        for m_meta in doc['mods']:
            off = int(m_meta['img_offset'])
            sz = int(m_meta['img_size'])
            if off < 0 or sz <= 0 or off > len(raw_all) - sz:
                return None
            mods_out.append({
                'name': str(m_meta['name']),
                'base': int(m_meta['base']),
                'img': bytes(mv[off:off + sz]),
                'text_end': int(m_meta['text_end']),
                'ro_off': int(m_meta['ro_off']),
                'data_off': int(m_meta['data_off']),
                'mod0': int(m_meta['mod0']),
                'exports': {str(k): int(v) for k, v in m_meta['exports'].items()},
            })
        lzd_raw = doc.get('lzd')
        lzd = (
            (int(lzd_raw[0]), int(lzd_raw[1]), int(lzd_raw[2]), int(lzd_raw[3]))
            if isinstance(lzd_raw, list) and len(lzd_raw) == 4
            else None
        )
        return {
            'kind': str(doc['kind']),
            'off': int(doc['off']),
            'mod_name': str(doc['mod_name']),
            'lzd': lzd,
            'vm': {
                'traps': {str(k): int(v) for k, v in doc['traps'].items()},
                'trap_names': [str(x) for x in doc['trap_names']],
                'mods': mods_out,
            },
        }
    except (OSError, zlib.error, ValueError, KeyError, IndexError, TypeError):
        return None


class Decoder:
    def __init__(self, patched: str | Path, *, use_fast_stubs: bool = True) -> None:
        self.patched = patched
        self.exefs = exefs_for(patched)
        self.use_fast_stubs = use_fast_stubs
        self.m: E.Machine | None = None
        self.kind: str = ''
        self.off: int = 0
        self.mod_name: str = 'main'
        self.fn: int = 0
        self.lzd: tuple[int, int, int, int] | None = None

        # Check for native Windows x64 Oodle DLL first
        self.native_dll: NativeOodleDll | None = None
        dll_path = find_native_oodle_dll()
        if dll_path is not None:
            try:
                self.native_dll = NativeOodleDll(dll_path)
            except Exception as e:
                log(f'oodle_emu: could not load native Oodle DLL {dll_path}: {e}')
                self.native_dll = None

        # If a native Oodle DLL is loaded and `main` contains Oodle (not LZ5), we can defer
        # initializing Unicorn until a block actually needs the emulated fallback.
        main_file = self.exefs / 'main'
        if self.native_dll is not None and main_file.is_file():
            try:
                img, *_ = E.nso_load(main_file)
                if b'LZ5_decompress_safe' not in img and (
                    b'OodleLZ_Decompress' in img or b'oodlelzcompressors.cpp' in img
                ):
                    self.kind = 'OodleLZ_Decompress'
                    self.off = 0
                    return
            except Exception:
                pass

        self._init_emu()

    @property
    def using_native_dll(self) -> bool:
        return self.native_dll is not None and self.kind != 'LZ5_decompress_safe'

    def _init_emu(self) -> None:
        if self.m is not None:
            return
        exefs = self.exefs
        main_pair = [('main', str(exefs / 'main'))] if (exefs / 'main').is_file() else []
        if not main_pair:
            die(f'oodle_emu: no main NSO in {exefs}')

        cache_path = (
            _cache_file_for(main_pair, exefs=exefs, patched=self.patched)
            if self.use_fast_stubs
            else None
        )
        if cache_path is not None and cache_path.is_file():
            try:
                snap = _read_reloc_cache(cache_path)
                if snap is not None:
                    self.kind = snap['kind']
                    self.off = snap['off']
                    self.mod_name = snap['mod_name']
                    self.lzd = snap['lzd']
                    self.m = E.Machine([], use_fast_stubs=self.use_fast_stubs, pre_relocated=snap['vm'])
                    target_mod = self.m.module(self.mod_name)
                    self.fn = target_mod.base + self.off
                    self._alloc_buffers()
                    return
            except Exception:
                pass

        # Single-module load first: `main` holds the decoder in >99% of games.
        m = E.Machine(main_pair, use_fast_stubs=self.use_fast_stubs)
        main_mod = m.module('main')
        found = _locate_decoder_in_module(main_mod)
        target_mod = main_mod

        if found is None:
            # Check `subsdk*` only if `main` did not contain the decoder, never loading `sdk`.
            sub_pairs = main_pair + [
                (p.name, str(p))
                for p in sorted(exefs.iterdir())
                if p.name.startswith('subsdk') and p.is_file()
            ]
            if len(sub_pairs) > len(main_pair):
                m = E.Machine(sub_pairs, use_fast_stubs=self.use_fast_stubs)
                for mod in m.mods:
                    if mod.name == 'main':
                        continue
                    found = _locate_decoder_in_module(mod)
                    if found is not None:
                        target_mod = mod
                        break

        if found is None:
            die(
                'oodle_emu: main has no "LZ5_decompress_safe", "OodleLZ_Decompress", or '
                'streaming Oodle decoder to find'
            )
            raise AssertionError('unreachable')

        self.m = m
        self.kind, self.off, self.lzd = found
        self.mod_name = target_mod.name
        self.fn = target_mod.base + self.off

        if cache_path is not None and len(self.m.mods) == 1:
            try:
                _write_reloc_cache(
                    cache_path,
                    {
                        'kind': self.kind,
                        'off': self.off,
                        'mod_name': self.mod_name,
                        'lzd': self.lzd,
                        'vm': self.m.export_snapshot(),
                    },
                )
            except Exception:
                pass

        self._alloc_buffers()

    def _alloc_buffers(self) -> None:
        assert self.m is not None
        m = self.m
        self.scratch_n = 16 << 20
        self.scratch = m.malloc(self.scratch_n)
        self.in_cap = 8 << 20
        self.in_buf = m.malloc(self.in_cap)
        self.out_cap = 16 << 20
        self.out_buf = m.malloc(self.out_cap)
        self.lzd_out = m.malloc(16)
        self.mark = m.heap_mark()
        self._oodle_stack = struct.pack('<6Q', 0, 0, 0, self.scratch, self.scratch_n, 3)

    def redirect(self, addr: int, name: str) -> None:
        """Overwrite the function at `addr` with an indirect jump to the emulator's handler."""
        assert self.m is not None
        target = self.m.resolve_import(name)
        patch = struct.pack('<IIQ', 0x58000050, 0xD61F0200, target)
        self.m.write(addr, patch)
        for mod in self.m.mods:
            if mod.base <= addr < mod.base + len(mod.img):
                off = addr - mod.base
                mod.img[off:off + len(patch)] = patch

    def run(self, comp: bytes, rl: int) -> bytes | None:
        if rl < 0:
            return None
        if rl == 0:
            return b''
        if self.native_dll is not None and self.kind != 'LZ5_decompress_safe':
            res = self.native_dll.decompress(comp, rl)
            if res is not None:
                return res
            if self.m is None:
                self._init_emu()

        assert self.m is not None
        m = self.m
        m.heap_reset(self.mark)
        cl = len(comp)
        c = self.in_buf if cl <= self.in_cap else m.malloc(cl or 1)
        r = self.out_buf if (rl + 0x10000) <= self.out_cap else m.malloc(rl + 0x10000)
        if comp:
            m.write(c, comp)

        if self.kind == 'LZ5_decompress_safe':
            got = m.call_fast(self.fn, c, r, cl, rl) if cl < 2 ** 31 and rl < 2 ** 31 else -1
            got = got - (1 << 64) if got >= 1 << 63 else got
        elif self.kind == 'OodleLZ_Decompress':
            got = m.call_fast(self.fn, c, cl, r, rl, 1, 0, 0, 0, self._oodle_stack)
            got = got - (1 << 64) if got >= 1 << 63 else got
        else:
            got = self.lzd_run(c, comp, cl, r, rl)
        return m.read(r, rl) if got == rl else None

    def lzd_run(self, c: int, comp: bytes, cl: int, r: int, rl: int) -> int:
        assert self.m is not None and self.lzd is not None
        size, create, destroy, some = self.lzd
        if cl < 2 or (comp[0] & 0x0F) != 0x0C:
            return -1
        compressor = {6: 8, 10: 9, 12: 13}.get(comp[1] & 0x7F)
        if compressor is None:
            return -1
        m = self.m
        need = m.call_fast(size, compressor, rl) & 0xFFFFFFFF
        if need <= 0 or need >= 1 << 31:
            return -1
        mem = self.scratch if need + 64 <= self.scratch_n else m.malloc(need + 64)
        dec = m.call_fast(create, compressor, rl, mem, need + 64)
        if not dec:
            return -1
        out = self.lzd_out
        pos = cpos = 0
        stack_some = struct.pack('<4Q', 1, 0, 0, 3)
        while pos < rl:
            m.write(out, b'\0' * 16)
            ok = (
                m.call_fast(
                    some,
                    dec,
                    out,
                    r,
                    pos,
                    rl,
                    rl - pos,
                    c + cpos,
                    cl - cpos,
                    stack_bytes=stack_some,
                )
                & 0xFFFFFFFF
            )
            done, used = struct.unpack('<ii', m.read(out, 8))
            if not ok or (done <= 0 and used <= 0):
                break
            pos += done
            cpos += used
        m.call_fast(destroy, dec)
        return pos


def read_all(f, n: int) -> bytes | None:
    b = bytearray()
    while len(b) < n:
        k = f.read(n - len(b))
        if not k:
            return None
        b += k
    return bytes(b)


def serve(dec: Decoder) -> int:
    i, o = sys.stdin.buffer, sys.stdout.buffer
    n = bad = 0
    mode_desc = (
        f'native {dec.native_dll.path.name}'
        if dec.using_native_dll
        else f'emulated ARM64 at {dec.mod_name}+{dec.off:#x}'
    )
    log(f'DM_OODLE_SERVE: {dec.kind} ({mode_desc}, win/oodle_emu.py), requests on stdin')
    while True:
        h = read_all(i, 16)
        if h is None:
            break
        cl, rl = struct.unpack('<QQ', h)
        if cl > 1 << 32 or rl > 1 << 32:
            die(f'DM_OODLE_SERVE: request too large ({cl:#x} -> {rl:#x})')
        comp = read_all(i, cl)
        if comp is None:
            die('DM_OODLE_SERVE: request cut short')
        try:
            out = dec.run(comp, rl)
        except E.EmuError as e:
            out = None
            log(f'[RED] DM_OODLE_SERVE: request {n}: {e}')
        if out is None and rl:
            bad += 1
            if bad <= 8:
                log(f'[RED] DM_OODLE_SERVE: request {n} ({cl} -> {rl} bytes) failed')
        o.write(struct.pack('<Q', len(out) if out else 0))
        if out:
            o.write(out)
        o.flush()
        n += 1
    log(f'DM_OODLE_SERVE: {n} requests, {bad} failed')
    return 1 if bad else 0


def _read_job_records(path: str | Path) -> list[tuple[int, int, bytes]]:
    with open(path, 'rb') as f:
        hdr = f.read(8)
        if len(hdr) != 8:
            die(f'DM_OODLE_JOB: {path} is truncated')
        magic, n = struct.unpack('<II', hdr)
        if magic != 0x4A4F4D44:
            die(f'DM_OODLE_JOB: {path} is not a job file')
        records: list[tuple[int, int, bytes]] = []
        for k in range(n):
            rh = f.read(8)
            if len(rh) != 8:
                die(f'DM_OODLE_JOB: record {k} header ends early')
            cl, rl = struct.unpack('<II', rh)
            comp = f.read(cl)
            if len(comp) != cl:
                die(f'DM_OODLE_JOB: record {k} ends early')
            records.append((cl, rl, comp))
    return records


def _write_job_shard(path: Path, records: list[tuple[int, int, bytes]]) -> None:
    with open(path, 'wb') as f:
        f.write(struct.pack('<II', 0x4A4F4D44, len(records)))
        for cl, rl, comp in records:
            f.write(struct.pack('<II', cl, rl))
            f.write(comp)


def _read_shard_output(out_sp: Path, expected_count: int) -> list[bytes | None] | None:
    """Read a worker shard's `.out` file, returning `None` only if the file is missing or truncated."""
    if not out_sp.is_file():
        return None
    try:
        data = out_sp.read_bytes()
    except OSError:
        return None
    if len(data) < 8:
        return None
    smagic, sn = struct.unpack_from('<II', data, 0)
    if smagic != 0x524F4D44 or sn != expected_count:
        return None
    pos = 8
    items: list[bytes | None] = []
    for _ in range(sn):
        if pos + 4 > len(data):
            return None
        got_len = struct.unpack_from('<I', data, pos)[0]
        pos += 4
        if pos + got_len > len(data):
            return None
        items.append(data[pos:pos + got_len] if got_len else None)
        pos += got_len
    if pos != len(data):
        return None
    return items


def job(dec: Decoder, path: str) -> int:
    records = _read_job_records(path)
    n = len(records)
    mode_desc = (
        f'native {dec.native_dll.path.name}'
        if dec.using_native_dll
        else f'emulated ARM64 at {dec.mod_name}+{dec.off:#x}'
    )
    log(f'DM_OODLE_JOB: {dec.kind} ({mode_desc}, win/oodle_emu.py), {n} records')

    # Multi-core parallel sharding for large emulated jobs (spawning Python + Unicorn costs ~150 ms
    # on Windows, so auto-sharding kicks in only when the job is large enough to amortize spawn cost,
    # or when NSPB_OODLE_WORKERS is explicitly set).
    max_w_env = os.environ.get('NSPB_OODLE_WORKERS')
    explicit_w = int(max_w_env) if (max_w_env and max_w_env.isdigit()) else 0
    total_raw_bytes = sum(rl for _cl, rl, _comp in records)
    should_shard = (
        not dec.using_native_dll
        and (
            (explicit_w >= 2 and n >= 4)
            or (explicit_w == 0 and n >= 512 and total_raw_bytes >= (4 << 20))
        )
    )
    max_w = explicit_w if explicit_w >= 2 else min(os.cpu_count() or 4, 8)
    if should_shard and max_w >= 2:
        workers = min(max_w, max(2, n // 2))
        shard_paths: list[Path] = []
        log_files: list[tuple[int, Path, object]] = []
        procs: list[tuple[int, Path, subprocess.Popen]] = []
        try:
            # Partition records evenly by raw output bytes so each worker does similar work
            buckets: list[list[tuple[int, int, int, bytes]]] = [[] for _ in range(workers)]
            loads = [0] * workers
            for idx, (cl, rl, comp) in enumerate(records):
                target = min(range(workers), key=loads.__getitem__)
                buckets[target].append((idx, cl, rl, comp))
                loads[target] += max(rl, 256)

            buckets = [b for b in buckets if b]
            if len(buckets) >= 2:
                env = dict(os.environ, NSPB_OODLE_WORKERS='1')
                for s_idx, b in enumerate(buckets):
                    sp = Path(f'{path}.shard.{os.getpid()}.{s_idx}')
                    lp = Path(f'{path}.shard.{os.getpid()}.{s_idx}.log')
                    shard_paths.extend((sp, lp))
                    _write_job_shard(sp, [(cl, rl, comp) for _i, cl, rl, comp in b])
                    s_env = dict(env, DM_OODLE_JOB=str(sp))
                    lf = open(lp, 'w', encoding='utf-8', errors='replace')
                    log_files.append((s_idx, lp, lf))
                    p = subprocess.Popen(
                        [sys.executable, str(Path(__file__).resolve()), str(dec.patched)],
                        env=s_env,
                        stdout=lf,
                        stderr=subprocess.STDOUT,
                    )
                    procs.append((s_idx, sp, p))

                all_ok = True
                results: dict[int, bytes | None] = {}
                red_logged = 0
                for (s_idx, sp, p), (_li, lp, lf) in zip(procs, log_files):
                    rc = p.wait()
                    lf.close()
                    out_sp = Path(str(sp) + '.out')
                    shard_paths.append(out_sp)
                    try:
                        shard_log = lp.read_text(encoding='utf-8', errors='replace').splitlines()
                    except OSError:
                        shard_log = []
                    for ln in shard_log:
                        if '[RED]' in ln and red_logged < 8:
                            red_logged += 1
                            print(f'{ln} (shard {s_idx})', file=sys.stderr, flush=True)

                    # Accept a valid `.out` when `rc` is 0 (all records decoded) or 1 (some records
                    # failed and were written with length 0, matching serial mode).
                    shard_items = (
                        _read_shard_output(out_sp, len(buckets[s_idx]))
                        if rc in (0, 1)
                        else None
                    )
                    if shard_items is None:
                        tail = ' | '.join(shard_log[-4:]) if shard_log else 'no log output'
                        log(f'[RED] DM_OODLE_JOB: shard {s_idx} failed (exit {rc}): {tail}')
                        all_ok = False
                        break
                    for (orig_idx, _cl, _rl, _comp), item in zip(buckets[s_idx], shard_items):
                        results[orig_idx] = item

                if all_ok and len(results) == n:
                    bad = total = 0
                    with open(path + '.out', 'wb') as out:
                        out.write(struct.pack('<II', 0x524F4D44, n))
                        for k in range(n):
                            r = results[k]
                            if r is None:
                                bad += 1
                                out.write(struct.pack('<I', 0))
                            else:
                                out.write(struct.pack('<I', len(r)))
                                out.write(r)
                                total += len(r)
                    log(
                        f'DM_OODLE_JOB: {n - bad} records decoded across {len(buckets)} workers '
                        f'({bad} failed, {total / 1048576:.1f} MB out) -> {path}.out'
                    )
                    return 1 if bad else 0
        except Exception as e:
            log(f'[RED] DM_OODLE_JOB: parallel sharding error ({e}), falling back to serial')
        finally:
            for _, _, p in procs:
                if p.poll() is None:
                    try:
                        p.kill()
                        p.wait()
                    except Exception:
                        pass
            for _li, _lp, lf in log_files:
                try:
                    lf.close()
                except Exception:
                    pass
            for sp in shard_paths:
                try:
                    sp.unlink(missing_ok=True)
                except OSError:
                    pass

    with open(path + '.out', 'wb') as out:
        out.write(struct.pack('<II', 0x524F4D44, n))
        bad = total = 0
        for k, (cl, rl, comp) in enumerate(records):
            try:
                r = dec.run(comp, rl)
            except E.EmuError as e:
                r = None
                log(f'[RED] DM_OODLE_JOB: record {k}: {e}')
            if r is None:
                bad += 1
                if bad <= 8:
                    log(f'[RED] DM_OODLE_JOB: record {k} ({cl} -> {rl} bytes) failed')
                out.write(struct.pack('<I', 0))
            else:
                out.write(struct.pack('<I', rl))
                out.write(r)
                total += rl
            if k and k % 2000 == 0:
                log(f'DM_OODLE_JOB: {k} / {n} records')
    log(
        f'DM_OODLE_JOB: {n - bad} records decoded with the game\'s {dec.kind} '
        f'({bad} failed, {total / 1048576:.1f} MB out) -> {path}.out'
    )
    return 1 if bad else 0


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if not args:
        die('usage: oodle_emu.py <rewritten modules folder>   (DM_OODLE_SERVE=1 or DM_OODLE_JOB=<file>)')
    if os.environ.get('DM_OODLE_JOB'):
        return job(Decoder(args[0]), os.environ['DM_OODLE_JOB'])
    if os.environ.get('DM_OODLE_SERVE'):
        return serve(Decoder(args[0]))
    die(
        'oodle_emu: neither DM_OODLE_SERVE nor DM_OODLE_JOB is set: the emulator runs only the '
        'decoder tool mode (booting a game needs a Mac with Apple silicon)'
    )
    return 1


if __name__ == '__main__':
    raise SystemExit(main())
