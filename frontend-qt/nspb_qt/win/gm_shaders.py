"""Offline GLSL ES shader reconstruction for GameMaker Studio 2 games (such as Well Dweller) on Windows.

Upstream boots GameMaker games in the Mac host with `DM_GL_CAPTURE` (`dm/gfx/gl/hle_gl.m`) and
saves every GLSL source passed to `glShaderSource` as `<key>.vert` / `<key>.frag`, where
`key = sha256(GLSL)[:16]`.

A GameMaker Studio 2 Switch runner (`ExeFS/main`) compiles two deterministic sets of GLSL ES 1.00
shaders at startup:
1. 24 built-in default pipeline shader pairs (48 shaders: `Default_Shader`, `Default_Light_Shader`
   across 1/2/4/8 vertex lights, and `Colour_Shader`, each permuted across `USE_FOG` and
   `USE_ALPHATEST`), assembled from NUL-terminated C strings in `ExeFS/main` immediately around the
   `#define MATRIX_VIEW                    0` lighting library header.
2. Every custom shader entry stored in the `FORM` -> `SHDR` chunk of `RomFS/game.win` (or
   `data.win`), whose GLSL ES vertex and fragment strings are stored verbatim in the `STRG` table.

This module extracts both sets directly from `ExeFS/main` and `RomFS/game.win` (streaming only the
IFF chunk headers and the `SHDR` strings without reading the multi-hundred-megabyte texture and
audio chunks into memory) to produce the exact same `.vert` and `.frag` files offline without a Mac
host.
"""
from __future__ import annotations

import hashlib
import os
import struct
import sys
from pathlib import Path
from typing import Callable

_VS_PREC_SIG = b'#define LOWPREC lowp\n'
_VS_COMMON_SIG = b'#define MATRIX_VIEW                    0'
_FS_PREC_SIG = b'precision mediump float;'
_FS_COMMON_SIG = b'uniform sampler2D gm_BaseTexture;'
_MAX_NSO_IMAGE = 512 << 20
_MAX_SHDR_ENTRIES = 65536
_MAX_SHADER_LEN = 16 << 20


class GMShaderError(ValueError):
    """Raised when a GameMaker binary or data file (`game.win`) has a damaged or truncated layout."""


def _load_romfs_module(repo: Path | None = None):
    if 'romfs' in sys.modules:
        return sys.modules['romfs']
    candidates: list[Path] = []
    if repo is not None:
        candidates.append(Path(repo) / 'dm' / 'tools')
    try:
        if __package__:
            from . import driver
        else:
            import driver  # type: ignore[no-redef]
        candidates.append(driver.repo_dir() / 'dm' / 'tools')
    except Exception:
        pass
    here = Path(__file__).resolve()
    for p in here.parents:
        if (p / 'dm' / 'tools' / 'romfs.py').is_file():
            candidates.append(p / 'dm' / 'tools')
        if (p / 'engine' / 'dm' / 'tools' / 'romfs.py').is_file():
            candidates.append(p / 'engine' / 'dm' / 'tools')
    for cand in candidates:
        if cand.is_dir():
            s = str(cand)
            if s not in sys.path:
                sys.path.insert(0, s)
            try:
                import romfs as rfs
                return rfs
            except ImportError:
                continue
    return None


def nso_image(path: str | Path) -> bytes:
    """Decompress an NSO0 file into its flat module image (or return raw bytes if uncompressed)."""
    d = Path(path).read_bytes()
    if len(d) < 0x6C or d[:4] != b'NSO0':
        return d

    flags = struct.unpack_from('<I', d, 0x0C)[0]
    segs = [struct.unpack_from('<III', d, 0x10 + i * 0x10) for i in range(3)]
    csz = struct.unpack_from('<III', d, 0x60)
    end = 0
    for i, (fo, mo, sz) in enumerate(segs):
        if fo < 0 or csz[i] < 0 or fo > len(d) - csz[i]:
            raise GMShaderError(f'{path}: truncated NSO segment {i}')
        if mo < 0 or sz < 0 or mo > _MAX_NSO_IMAGE or sz > _MAX_NSO_IMAGE - mo:
            raise GMShaderError(f'{path}: invalid NSO segment {i} bounds')
        if mo + sz > end:
            end = mo + sz
    if end <= 0:
        raise GMShaderError(f'{path}: empty NSO segment layout')
    img = bytearray(end)
    for i, (fo, mo, sz) in enumerate(segs):
        raw = d[fo:fo + csz[i]]
        if (flags >> i) & 1:
            if flags & (1 << 7):
                try:
                    import zbic  # pyright: ignore[reportMissingImports]
                except ImportError as e:
                    raise GMShaderError(f'{path}: ZBIC segment needs zbic package') from e
                raw = zbic.decompress(raw)
            else:
                import lz4.block
                try:
                    raw = lz4.block.decompress(raw, uncompressed_size=sz)
                except lz4.block.LZ4BlockError as e:
                    raise GMShaderError(f'{path}: corrupted LZ4 NSO segment {i}') from e
        if len(raw) != sz:
            raise GMShaderError(f'{path}: NSO segment {i} decompressed to {len(raw):#x}, expected {sz:#x}')
        img[mo:mo + sz] = raw
    return bytes(img)


def key_bytes(raw: bytes) -> str:
    """Return the 16-hex-character SHA-256 prefix used by `hle_gl.m` (`sh_capture`)."""
    return hashlib.sha256(raw).hexdigest()[:16]


def _read_cstr(buf: bytes, pos: int) -> tuple[bytes, int]:
    nul = buf.find(b'\x00', pos)
    if nul < 0:
        raise GMShaderError('unterminated C string in GameMaker runner shader table')
    return buf[pos:nul], nul + 1


def _skip_padding(buf: bytes, pos: int, limit: int = 64) -> int:
    end = min(len(buf), pos + limit)
    while pos < end and buf[pos] == 0:
        pos += 1
    return pos


def runner_builtins(main_img: bytes) -> list[tuple[str, bytes, str]] | None:
    """Extract the 48 built-in GLSL ES shaders from a GameMaker Runner NSO image.

    Returns `None` if `main_img` does not contain the GameMaker runner shader table.
    Raises `GMShaderError` if the signature is present but the surrounding string table is truncated.
    """
    idx = main_img.find(_VS_COMMON_SIG)
    if idx < 0:
        return None
    prec_idx = main_img.rfind(_VS_PREC_SIG, max(0, idx - 64), idx)
    if prec_idx < 0:
        raise GMShaderError('GameMaker vertex precision header not found before MATRIX_VIEW')
    vs_prec, _ = _read_cstr(main_img, prec_idx)
    vs_common, pos = _read_cstr(main_img, idx)

    vs_templates: list[bytes] = []
    for _ in range(8):
        pos = _skip_padding(main_img, pos)
        if pos >= len(main_img) or not main_img[pos:pos + 10].startswith(b'attribute '):
            break
        s, pos = _read_cstr(main_img, pos)
        vs_templates.append(s)
    if len(vs_templates) < 3:
        raise GMShaderError(
            f'GameMaker vertex shader templates incomplete ({len(vs_templates)}/3) in ExeFS/main'
        )

    pos = _skip_padding(main_img, pos)
    if not main_img[pos:pos + len(_FS_PREC_SIG)].startswith(_FS_PREC_SIG):
        raise GMShaderError('GameMaker fragment precision header not found in ExeFS/main')
    fs_prec, pos = _read_cstr(main_img, pos)

    pos = _skip_padding(main_img, pos)
    if not main_img[pos:pos + len(_FS_COMMON_SIG)].startswith(_FS_COMMON_SIG):
        raise GMShaderError('GameMaker fragment common header not found in ExeFS/main')
    fs_common, pos = _read_cstr(main_img, pos)

    fs_templates: list[bytes] = []
    for _ in range(8):
        pos = _skip_padding(main_img, pos)
        if pos >= len(main_img) or not main_img[pos:pos + 8].startswith(b'varying '):
            break
        s, pos = _read_cstr(main_img, pos)
        fs_templates.append(s)
    if len(fs_templates) < 2:
        raise GMShaderError(
            f'GameMaker fragment shader templates incomplete ({len(fs_templates)}/2) in ExeFS/main'
        )

    out: list[tuple[str, bytes, str]] = []
    light_defs = (
        b'#define MAX_VS_LIGHTS 1\n',
        b'#define MAX_VS_LIGHTS 2\n',
        b'#define MAX_VS_LIGHTS 4\n',
        b'#define MAX_VS_LIGHTS 8\n',
    )
    for fog in (b'', b'#define USE_FOG\n'):
        for alpha in (b'', b'#define USE_ALPHATEST\n'):
            base_macros = fog + alpha
            for vt in vs_templates:
                if b'in_Normal' in vt:
                    for ld in light_defs:
                        out.append(('vert', vs_prec + base_macros + ld + vs_common + vt, 'GM runner lit vertex'))
                else:
                    out.append(('vert', vs_prec + base_macros + vs_common + vt, 'GM runner vertex'))
            for ft in fs_templates:
                out.append(('frag', fs_prec + base_macros + fs_common + ft, 'GM runner fragment'))
                if b'v_vTexcoord' in ft:
                    for ld in light_defs:
                        out.append(('frag', fs_prec + base_macros + ld + fs_common + ft, 'GM runner lit fragment'))
    return out


def _read_exact(f, size: int) -> bytes:
    b = f.read(size)
    if len(b) != size:
        raise GMShaderError('unexpected EOF in GameMaker data file')
    return b


def _read_gm_string(f, file_size: int, str_ptr: int) -> bytes:
    if str_ptr < 4 or str_ptr > file_size:
        raise GMShaderError(f'invalid string pointer {str_ptr:#x} in SHDR chunk')
    f.seek(str_ptr - 4)
    slen = struct.unpack('<I', _read_exact(f, 4))[0]
    if slen > _MAX_SHADER_LEN or slen > file_size - str_ptr:
        raise GMShaderError(f'string at {str_ptr:#x} length {slen:#x} exceeds bounds')
    return _read_exact(f, slen)


def shdr_chunk_shaders(win_path) -> list[tuple[str, bytes, str]]:
    """Extract custom GLSL ES shaders from the `FORM` -> `SHDR` chunk of `game.win`."""
    with win_path.open('rb') as f:
        f.seek(0, os.SEEK_END)
        file_size = f.tell()
        if file_size < 8:
            raise GMShaderError('game.win is too small to be a FORM container')
        f.seek(0)
        hdr = _read_exact(f, 8)
        if hdr[:4] != b'FORM':
            raise GMShaderError('game.win does not start with FORM magic')
        form_size = struct.unpack_from('<I', hdr, 4)[0]
        if form_size > file_size - 8:
            raise GMShaderError('FORM size exceeds game.win length')
        end = 8 + form_size
        pos = 8
        shdr_off = shdr_size = None
        while pos <= end - 8:
            f.seek(pos)
            chdr = _read_exact(f, 8)
            tag = chdr[:4]
            csz = struct.unpack_from('<I', chdr, 4)[0]
            if csz > end - 8 - pos:
                raise GMShaderError(f'chunk {tag!r} size {csz:#x} exceeds FORM boundary')
            if tag == b'SHDR':
                shdr_off = pos + 8
                shdr_size = csz
                break
            pos += 8 + csz
        if shdr_off is None or shdr_size is None:
            return []
        if shdr_size < 4:
            raise GMShaderError('SHDR chunk is too small')
        f.seek(shdr_off)
        shdr_buf = _read_exact(f, shdr_size)
        count = struct.unpack_from('<I', shdr_buf, 0)[0]
        if count > _MAX_SHDR_ENTRIES or count > (shdr_size - 4) // 4:
            raise GMShaderError(f'SHDR entry count {count} exceeds chunk size {shdr_size}')
        ptrs = struct.unpack_from(f'<{count}I', shdr_buf, 4)
        out: list[tuple[str, bytes, str]] = []
        for p in ptrs:
            if p < 8 or p > file_size - 16:
                raise GMShaderError(f'SHDR entry pointer {p:#x} out of bounds')
            f.seek(p)
            name_p, _stype, es_v_p, es_f_p = struct.unpack('<4I', _read_exact(f, 16))
            name = _read_gm_string(f, file_size, name_p).decode('utf-8', 'replace')
            vs = _read_gm_string(f, file_size, es_v_p)
            fs = _read_gm_string(f, file_size, es_f_p)
            if vs:
                out.append(('vert', vs, name))
            if fs:
                out.append(('frag', fs, name))
        return out


def generate(
    main: str | Path,
    romfs: str | Path,
    out: str | Path,
    table: str | Path | None = None,
    log: Callable[[str], None] = print,
    repo: Path | None = None,
    *,
    require_table: bool = False,
) -> tuple[dict[str, str], set[str] | None] | None:
    """Reconstruct GL shaders for a GameMaker Studio 2 game into `out`.

    Returns `(made_dict, wanted_set)` when `main` is a GameMaker runner and all required
    capture-table entries are reconstructed, or `None` when `main` is not a GameMaker binary,
    when `game.win`/`data.win` is absent, or when the reconstructed set does not cover `table`.
    """
    main_path = Path(main)
    if not main_path.is_file():
        return None
    builtins = runner_builtins(nso_image(main_path))
    if builtins is None:
        return None

    want: set[str] | None = None
    if table and Path(table).is_file():
        want = {
            line.strip()
            for line in Path(table).read_text(encoding='utf-8', errors='replace').splitlines()
            if line.strip() and not line.startswith('#')
        }
    if require_table and not want:
        log('gm_shaders: no capture table to verify completeness against, skipping offline reconstruction')
        return None

    rfs = _load_romfs_module(repo)
    rpath_cls = getattr(rfs, 'Path', Path)
    rom_root = rpath_cls(romfs)

    win_path = None
    for candidate in ('game.win', 'data.win'):
        p = rom_root / candidate
        if p.exists():
            win_path = p
            break
    if win_path is None:
        return None

    custom = shdr_chunk_shaders(win_path)
    made: dict[str, str] = {}
    encoded: dict[str, bytes] = {}
    for ext, raw, what in builtins + custom:
        name = f'{key_bytes(raw)}.{ext}'
        made[name] = what
        encoded[name] = raw

    log(f'gm_shaders: {len(made)} sources ({len(builtins)} runner built-in, {len(custom)} SHDR entries)')
    if want is not None:
        hit = want & set(made)
        if not (want <= set(made)):
            log(
                f'gm_shaders: {len(hit)} of the {len(want)} sources the capture table lists are '
                f'among them ({len(want - hit)} missing from the offline reconstruction)'
            )
            return None
        log(
            f'gm_shaders: {len(hit)} of the {len(want)} sources the capture table lists are '
            'among them (every one, byte for byte)'
        )

    out_dir = Path(out)
    out_dir.mkdir(parents=True, exist_ok=True)
    pid = os.getpid()
    for name, raw in encoded.items():
        dst = out_dir / name
        tmp = out_dir / f'{name}.tmp.{pid}'
        try:
            tmp.write_bytes(raw)
            os.replace(tmp, dst)
        finally:
            tmp.unlink(missing_ok=True)
    return made, want


if __name__ == '__main__':
    if len(sys.argv) < 4:
        raise SystemExit('usage: gm_shaders.py <ExeFS main> <RomFS> <out> [gl_capture.tsv]')
    res = generate(*sys.argv[1:5])
    if res is None:
        raise SystemExit(1)
    made_map, want_set = res
    raise SystemExit(0 if want_set is None or want_set <= set(made_map) else 1)
