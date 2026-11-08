"""Offline GLSL shader reconstruction for LÖVE games (such as Balatro) on Windows.

Upstream boots LÖVE games in the Mac host with `DM_GL_CAPTURE` (`dm/gfx/gl/hle_gl.m`) and saves
every GLSL source passed to `glShaderSource` as `<key>.vert` / `<key>.frag`, where
`key = sha256(GLSL)[:16]`.

LÖVE constructs those GLSL strings deterministically in Lua via `love.graphics._shaderCodeToGLSL`
 inside `wrap_GraphicsShader.lua`, which is embedded as a plain-text NUL-terminated C++ raw string
literal in the game's `main` NSO. This module locates `function love.graphics._shaderCodeToGLSL`
in `main`, parses its GLSL header/footer templates, and combines them with LÖVE's built-in default
shaders and the game's `resources/shaders/*.fs` files from the RomFS to produce the exact same
`.vert` and `.frag` files offline without a Mac host.
"""
from __future__ import annotations

import hashlib
import os
import re
import struct
import sys
from pathlib import Path
from typing import Callable

LONG_STRING_RE = re.compile(r'(\w+)\s*=\s*\[(=*)\[\n?(.*?)\]\2\]', re.S)


class LoveShaderError(ValueError):
    """Raised when a LÖVE binary's embedded shader Lua or NSO layout cannot be parsed."""


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
    end = max((mo + sz for _fo, mo, sz in segs), default=0)
    if end <= 0 or end > (512 << 20):
        raise LoveShaderError(f'{path}: invalid NSO segment layout (end={end:#x})')
    zbic_mod = None
    if flags & (1 << 7):
        try:
            import zbic as zbic_mod  # type: ignore[import-not-found]
        except ImportError as e:
            raise LoveShaderError(f'{path}: NSO uses ZBIC compression and the zbic package is missing: {e}') from e
    img = bytearray(end)
    for i, (fo, mo, sz) in enumerate(segs):
        if fo < 0 or csz[i] < 0 or fo > len(d) - csz[i] or mo < 0 or sz < 0 or mo > end - sz:
            raise LoveShaderError(f'{path}: truncated NSO segment {i}')
        raw = d[fo:fo + csz[i]]
        if (flags >> i) & 1:
            if zbic_mod is not None:
                try:
                    raw = zbic_mod.decompress(raw)
                except Exception as e:
                    raise LoveShaderError(f'{path}: failed to decompress ZBIC NSO segment {i}: {e}') from e
            else:
                import lz4.block
                try:
                    raw = lz4.block.decompress(raw, uncompressed_size=sz)
                except Exception as e:
                    raise LoveShaderError(f'{path}: failed to decompress LZ4 NSO segment {i}: {e}') from e
        if len(raw) != sz:
            raise LoveShaderError(f'{path}: NSO segment {i} uncompressed size mismatch ({len(raw)} != {sz})')
        img[mo:mo + sz] = raw
    return bytes(img)


def love_shader_lua(img: bytes) -> str | None:
    """Extract the plain-text `wrap_GraphicsShader.lua` C string containing `_shaderCodeToGLSL`."""
    marker = b'function love.graphics._shaderCodeToGLSL'
    i = img.find(marker)
    if i < 0:
        return None
    s = img.rfind(b'\0', 0, i) + 1
    e = img.find(b'\0', i)
    if e < 0:
        e = len(img)
    return img[s:e].decode('utf-8', errors='replace')


def blocks(lua: str) -> dict:
    """Parse GLSL template tables (`GLSL.*` and `local defaultcode`) from `wrap_GraphicsShader.lua`."""
    lua = lua.replace('\r\n', '\n')
    out: dict = {}
    for m in re.finditer(r'^GLSL\.(\w+)\s*=\s*\[(=*)\[\n?(.*?)\]\2\]', lua, re.S | re.M):
        out[m.group(1)] = m.group(3)
    ws_re = re.compile(r'(?:\s|,|--[^\n]*)*')
    for m in re.finditer(r'^(?:GLSL\.(\w+)|local (defaultcode))\s*=\s*\{', lua, re.M):
        name = m.group(1) or m.group(2)
        pos = m.end()
        if name == 'VERSION':
            end_idx = lua.find('\n}', pos)
            if end_idx < 0:
                end_idx = lua.find('}', pos)
            body = lua[pos:end_idx if end_idx >= 0 else len(lua)]
            out['VERSION'] = {
                t: {False: n, True: es}
                for t, n, es in re.findall(
                    r'(\w+)\s*=\s*\{\s*\[false\]\s*=\s*"([^"]*)"\s*,\s*\[true\]\s*=\s*"([^"]*)"',
                    body,
                )
            }
            continue
        while True:
            ws = ws_re.match(lua, pos)
            pos = ws.end() if ws else pos
            if lua.startswith('}', pos):
                break
            e = LONG_STRING_RE.match(lua, pos)
            if not e:
                raise LoveShaderError(f'unexpected Lua in table {name} at {lua[pos:pos + 40]!r}')
            out[f'{name}.{e.group(1)}'] = e.group(3)
            pos = e.end()
    return out


class Love:
    """Offline replica of LÖVE's `createShaderStageCode` and `_shaderCodeToGLSL`."""

    REQUIRED_KEYS = (
        'VERSION', 'SYNTAX', 'UNIFORMS', 'FUNCTIONS',
        'VERTEX.HEADER', 'VERTEX.MAIN', 'PIXEL.HEADER', 'PIXEL.MAIN',
        'defaultcode.vertex', 'defaultcode.pixel',
        'defaultcode.videopixel', 'defaultcode.arraypixel',
    )

    def __init__(self, lua: str) -> None:
        self.b = blocks(lua)
        for need in self.REQUIRED_KEYS:
            if need not in self.b:
                raise LoveShaderError(f'LÖVE shader Lua without {need}: unsupported LÖVE version')

    def stage(
        self,
        stage: str,
        code: str,
        lang: str,
        gles: bool,
        glsl1on3: bool,
        gammacorrect: bool,
        custom: bool = False,
        multicanvas: bool = False,
    ) -> str:
        b = self.b
        if lang not in b['VERSION'] or gles not in b['VERSION'][lang]:
            raise LoveShaderError(f'LÖVE shader Lua has no VERSION entry for ({lang!r}, gles={gles})')
        lines = [
            b['VERSION'][lang][gles],
            f'#define {stage} {stage}',
            '#define LOVE_GLSL1_ON_GLSL3 1' if glsl1on3 else '',
            '#define LOVE_GAMMA_CORRECT 1' if gammacorrect else '',
            '#define LOVE_MULTI_CANVAS 1' if multicanvas else '',
            b['SYNTAX'],
            b[f'{stage}.HEADER'],
            b['UNIFORMS'],
            b['FUNCTIONS'],
            b.get(f'{stage}.FUNCTIONS'),
            b.get(f'{stage}.MAIN_CUSTOM') if custom else b[f'{stage}.MAIN'],
            '#line 0' if ((lang == 'glsl1' or glsl1on3) and not gles) else '#line 1',
            code,
        ]
        return '\n'.join('' if line is None else line for line in lines)

    @staticmethod
    def target(code: str) -> str:
        m = re.match(r'\s*#pragma language (\w+)', code)
        return m.group(1) if m else 'glsl1'

    def to_glsl(
        self,
        gles: bool,
        code: str,
        glsl3: bool = True,
        gammacorrect: bool = False,
    ) -> tuple[str | None, str | None]:
        vert = code if re.search(r'vec4\s+position\s*\(', code) else None
        pix, custom, multi = None, False, False
        if re.search(r'vec4\s+effect\s*\(', code):
            pix = code
        elif re.search(r'void\s+effect\s*\(', code):
            pix, custom, multi = code, True, 'love_Canvases' in code
        lang, on3 = self.target(code), False
        if lang == 'glsl1' and glsl3:
            lang, on3 = 'glsl3', True
        return (
            self.stage('VERTEX', vert, lang, gles, on3, gammacorrect) if vert else None,
            self.stage('PIXEL', pix, lang, gles, on3, gammacorrect, custom, multi) if pix else None,
        )

    def defaults(self, target: str, gles: bool, gammacorrect: bool) -> list[tuple[str, str]]:
        d = {k.split('.', 1)[1]: v for k, v in self.b.items() if k.startswith('defaultcode.')}
        return [
            ('vert', self.stage('VERTEX', d['vertex'], target, gles, False, gammacorrect)),
            ('frag', self.stage('PIXEL', d['pixel'], target, gles, False, gammacorrect)),
            ('frag', self.stage('PIXEL', d['videopixel'], target, gles, False, gammacorrect, True)),
            ('frag', self.stage('PIXEL', d['arraypixel'], target, gles, False, gammacorrect, True)),
        ]


def key(src: str) -> str:
    return hashlib.sha256(src.encode('utf-8', 'surrogateescape')).hexdigest()[:16]


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
    """Reconstruct GL shaders for a LÖVE game into `out`.

    Returns `(made_dict, wanted_set)` when `main` is a LÖVE binary and all required capture-table
    entries are reconstructed, or `None` when `main` does not embed `love.graphics._shaderCodeToGLSL`
    or when the reconstructed set does not cover `table` (so callers fall back cleanly instead of
    swapping in a partial capture).
    """
    main_path = Path(main)
    if not main_path.is_file():
        return None
    lua = love_shader_lua(nso_image(main_path))
    if not lua:
        return None
    love = Love(lua)
    want: set[str] | None = None
    if table and Path(table).is_file():
        want = {
            line.strip()
            for line in Path(table).read_text(encoding='utf-8', errors='replace').splitlines()
            if line.strip() and not line.startswith('#')
        }
    if require_table and not want:
        log('love_shaders: no capture table to verify completeness against, skipping offline reconstruction')
        return None

    rfs = _load_romfs_module(repo)
    rpath_cls = getattr(rfs, 'Path', Path)
    rom_root = rpath_cls(romfs)

    conf = rom_root / 'conf.lua'
    gc = bool(
        conf.exists()
        and re.search(r'\bgammacorrect\s*=\s*true', conf.read_text(encoding='utf-8', errors='replace'))
    )
    if want:
        for g in (False, True):
            if all(f'{key(s)}.{e}' in want for e, s in love.defaults('glsl3', False, g)):
                gc = g

    cands: list[tuple[str, str, str]] = [
        (ext, s, 'LÖVE default') for ext, s in love.defaults('glsl3', False, gc)
    ]
    sh_dir = rom_root / 'resources/shaders'
    fs_files = sorted(sh_dir.glob('*.fs')) if sh_dir.exists() else []
    for fs in fs_files:
        # Preserve raw line endings (CRLF vs LF): LÖVE passes the file bytes as-is to glShaderSource.
        code = fs.read_bytes().decode('utf-8', 'surrogateescape')
        v, p = love.to_glsl(False, code, True, gc)
        if v:
            cands.append(('vert', v, fs.name))
        if p:
            cands.append(('frag', p, fs.name))

    made: dict[str, str] = {}
    encoded: dict[str, bytes] = {}
    for ext, src, what in cands:
        name = f'{key(src)}.{ext}'
        made[name] = what
        encoded[name] = src.encode('utf-8', 'surrogateescape')

    log(f'love_shaders: {len(made)} sources (gamma correction {"on" if gc else "off"})')
    if want is not None:
        hit = want & set(made)
        if not (want <= set(made)):
            log(
                f'love_shaders: {len(hit)} of the {len(want)} sources the capture table lists are '
                f'among them ({len(want - hit)} missing from the offline reconstruction)'
            )
            return None
        log(
            f'love_shaders: {len(hit)} of the {len(want)} sources the capture table lists are '
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
        raise SystemExit('usage: love_shaders.py <ExeFS main> <RomFS> <out> [gl_capture.tsv]')
    res = generate(*sys.argv[1:5])
    if res is None:
        raise SystemExit(1)
    made_map, want_set = res
    raise SystemExit(0 if want_set is None or want_set <= set(made_map) else 1)
