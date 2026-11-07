"""Languages a game's RomFS offers when the game was built without control.nacp (#668).

Mirrors frontend/Sources/NXCore/RomFSLanguages.swift so that iOS frameworks built and archived
by the Qt launcher have their DM_LANG fallback row narrowed (or inserted) from the RomFS image
or directory (`System/RegionLangMask.txt` or `Mals/<Tag>.Product.*`).
"""
from __future__ import annotations

import json
import os
import struct
import threading
from pathlib import Path
from typing import Iterable, Sequence

# Horizon's 16 language codes and English labels in the order dm/tools/nacp.py (LANGUAGES) writes them.
TABLE: tuple[tuple[str, str], ...] = (
    ('en-US', 'American English'),
    ('en-GB', 'British English'),
    ('ja', 'Japanese'),
    ('fr', 'French'),
    ('de', 'German'),
    ('es-419', 'Latin American Spanish'),
    ('es', 'Spanish'),
    ('it', 'Italian'),
    ('nl', 'Dutch'),
    ('fr-CA', 'Canadian French'),
    ('pt', 'Portuguese'),
    ('ru', 'Russian'),
    ('ko', 'Korean'),
    ('zh-Hant', 'Traditional Chinese'),
    ('zh-Hans', 'Simplified Chinese'),
    ('pt-BR', 'Brazilian Portuguese'),
)

# Nintendo region-language tags (System/RegionLangMask.txt, Mals/<Tag>.Product.*) to Horizon language codes.
REGION_TAGS: dict[str, str] = {
    'USen': 'en-US',
    'EUen': 'en-GB',
    'JPja': 'ja',
    'EUfr': 'fr',
    'EUde': 'de',
    'USes': 'es-419',
    'EUes': 'es',
    'EUit': 'it',
    'EUnl': 'nl',
    'USfr': 'fr-CA',
    'EUpt': 'pt',
    'EUru': 'ru',
    'KRko': 'ko',
    'TWzh': 'zh-Hant',
    'CNzh': 'zh-Hans',
    'USpt': 'pt-BR',
}

_KNOWN_CODES: frozenset[str] = frozenset(code for code, _ in TABLE)
_CACHE_LOCK = threading.Lock()
_IMAGE_CACHE: dict[str, list[list[str]]] = {}


def options_for_tags(tags: Iterable[str]) -> list[list[str]]:
    """[code, label] pairs in TABLE order for a set of Nintendo region-language tags."""
    codes = {REGION_TAGS[t] for t in tags if t in REGION_TAGS}
    return [[code, label] for code, label in TABLE if code in codes]


def _candidates(path: str | Path) -> list[Path]:
    p = Path(path)
    return [
        p / 'Contents' / 'Resources' / 'romfs.img',
        p / 'Contents' / 'Resources' / 'romfs',
        p / 'romfs.img',
        p / 'RomFS.img',
        p / 'romfs',
        p / 'RomFS',
        p,
    ]


def _tags_from_mask(text: str) -> list[str]:
    for raw in text.splitlines():
        line = raw.strip()
        if line and not line.startswith('#') and not line.startswith('/'):
            return line.split()
    return []


def _tags_from_mals(names: Iterable[str]) -> list[str]:
    out: list[str] = []
    for name in names:
        if '.Product.' in name and '.' in name:
            out.append(name.split('.', 1)[0])
    return out


def _from_directory(dir_path: Path) -> list[list[str]]:
    mask_path = dir_path / 'System' / 'RegionLangMask.txt'
    if mask_path.is_file():
        try:
            text = mask_path.read_text(encoding='utf-8')
            opts = options_for_tags(_tags_from_mask(text))
            if len(opts) > 1:
                return opts
        except (OSError, UnicodeDecodeError):
            pass
    mals_dir = dir_path / 'Mals'
    if mals_dir.is_dir():
        try:
            names = sorted(os.listdir(mals_dir))
            opts = options_for_tags(_tags_from_mals(names))
            if len(opts) > 1:
                return opts
        except OSError:
            pass
    return []


def _from_image(img_path: Path) -> list[list[str]]:
    """Reads System/RegionLangMask.txt or Mals/ from a DMROMFS1 image by seeking to the index at the end of the file."""
    try:
        file_size = img_path.stat().st_size
        if file_size < 32:
            return []
        with open(img_path, 'rb') as f:
            head = f.read(32)
            if len(head) != 32 or head[:8] != b'DMROMFS1':
                return []
            idx_off, idx_size, count = struct.unpack_from('<QQQ', head, 8)
            if (
                idx_off < 32
                or idx_off > file_size
                or idx_size != file_size - idx_off
                or idx_size > 64 * 1024 * 1024
                or count < 1
                or count > idx_size // 24
            ):
                return []
            f.seek(idx_off)
            idx = f.read(idx_size)
            if len(idx) != idx_size:
                return []
            names_base = count * 24

            def read_entry(i: int) -> tuple[int, int, str, int] | None:
                if i < 0 or i >= count:
                    return None
                o = i * 24
                a, b, n_off, n_len, etype, _flags = struct.unpack_from('<QQIHBB', idx, o)
                if n_off > len(idx) - names_base or n_len > len(idx) - names_base - n_off:
                    return None
                start = names_base + n_off
                name = idx[start:start + n_len].decode('utf-8', errors='replace')
                return a, b, name, etype

            def children_of(dir_index: int) -> range:
                ent = read_entry(dir_index)
                if ent is None:
                    return range(0)
                a, b, _name, etype = ent
                if etype != 0 or a > count or b > count - a:
                    return range(0)
                return range(a, a + b)

            def find_child(dir_index: int, target: str) -> int | None:
                for ch in children_of(dir_index):
                    ent = read_entry(ch)
                    if ent is not None and ent[2] == target:
                        return ch
                return None

            sys_idx = find_child(0, 'System')
            if sys_idx is not None:
                mask_idx = find_child(sys_idx, 'RegionLangMask.txt')
                if mask_idx is not None:
                    mask_ent = read_entry(mask_idx)
                    if mask_ent is not None:
                        mask_a, mask_b, _mname, mtype = mask_ent
                        if (
                            mtype == 1
                            and 0 < mask_b <= 65536
                            and mask_a >= 32
                            and mask_b <= idx_off
                            and mask_a <= idx_off - mask_b
                        ):
                            f.seek(mask_a)
                            mask_data = f.read(mask_b)
                            if len(mask_data) == mask_b:
                                try:
                                    text = mask_data.decode('utf-8')
                                    opts = options_for_tags(_tags_from_mask(text))
                                    if len(opts) > 1:
                                        return opts
                                except UnicodeDecodeError:
                                    pass

            mals_idx = find_child(0, 'Mals')
            if mals_idx is not None:
                names: list[str] = []
                for ch in children_of(mals_idx):
                    ent = read_entry(ch)
                    if ent is not None:
                        names.append(ent[2])
                opts = options_for_tags(_tags_from_mals(names))
                if len(opts) > 1:
                    return opts
    except OSError:
        return []
    return []


def _cached_from_image(img_path: Path) -> list[list[str]]:
    try:
        st = img_path.stat()
        key = f'{img_path}|{st.st_size}|{st.st_mtime_ns}'
    except OSError:
        key = f'{img_path}|-1|0'
    with _CACHE_LOCK:
        hit = _IMAGE_CACHE.get(key)
        if hit is not None:
            return [list(pair) for pair in hit]
    found = _from_image(img_path)
    if len(found) > 1:
        with _CACHE_LOCK:
            if len(_IMAGE_CACHE) > 64:
                _IMAGE_CACHE.clear()
            _IMAGE_CACHE[key] = [list(pair) for pair in found]
    return found


def options_in(path: str | Path) -> list[list[str]]:
    """Reads the [code, label] pairs from a RomFS image, a RomFS tree, a folder holding either, or an app bundle."""
    if not path or not str(path):
        return []
    for candidate in _candidates(path):
        try:
            if candidate.is_dir():
                found = _from_directory(candidate)
            elif candidate.is_file():
                found = _cached_from_image(candidate)
            else:
                continue
        except OSError:
            continue
        if len(found) > 1:
            return found
    return []


def is_fallback_row(options: Sequence[Sequence[str]] | None, note: str) -> bool:
    """Whether a DM_LANG row is the all-languages fallback row dm/games/settings.py writes when control.nacp is absent."""
    if not note or not options:
        return False
    codes = {opt[0] for opt in options if opt}
    return _KNOWN_CODES.issubset(codes)


def narrowed(
    options: Sequence[Sequence[str]],
    default: str,
    romfs: Sequence[Sequence[str]],
) -> list[list[str]] | None:
    """Narrows the fallback row's options to the languages offered by the RomFS while keeping unknown engine codes."""
    offered = {opt[0] for opt in romfs if opt}
    if len(offered) <= 1:
        return None
    kept = [
        [str(opt[0]), str(opt[1])]
        for opt in options
        if len(opt) >= 2 and (opt[0] not in _KNOWN_CODES or opt[0] in offered)
    ]
    if len(kept) > 1 and any(opt[0] == default for opt in kept):
        return kept
    return None


def apply_to_launcher_json(
    launcher_path: str | Path,
    romfs: str | Path,
    default_language: str = 'en-US',
) -> bool:
    """Updates launcher.json at launcher_path with the game's real languages from romfs. Returns True if modified."""
    lp = Path(launcher_path)
    if not lp.is_file():
        return False
    try:
        root = json.loads(lp.read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return False
    if not isinstance(root, dict):
        return False
    settings = root.get('settings')
    if not isinstance(settings, list):
        return False
    opts = options_in(romfs)
    if len(opts) <= 1:
        return False

    def _write() -> bool:
        root['settings'] = settings
        tmp = lp.with_name(lp.name + '.tmp')
        try:
            tmp.write_text(json.dumps(root, indent=1, sort_keys=True) + '\n', encoding='utf-8')
            os.replace(tmp, lp)
            return True
        except OSError:
            tmp.unlink(missing_ok=True)
            return False

    for i, row in enumerate(settings):
        if isinstance(row, dict) and row.get('env') == 'DM_LANG':
            raw_opts = row.get('options')
            note = str(row.get('note') or '')
            default_val = str(row.get('default') or '')
            if not isinstance(raw_opts, list) or not is_fallback_row(raw_opts, note):
                return False
            kept = narrowed(raw_opts, default_val, opts)
            if kept is None:
                return False
            row['options'] = kept
            row['note'] = ''
            settings[i] = row
            return _write()

    codes = {opt[0] for opt in opts if opt}
    if default_language in codes:
        def_lang = default_language
    elif 'en-US' in codes:
        def_lang = 'en-US'
    else:
        def_lang = opts[0][0]
    new_row = {
        'env': 'DM_LANG',
        'kind': 'choice',
        'section': 'Game',
        'label': 'Game language',
        'note': '',
        'default': def_lang,
        'level': 'basic',
        'options': opts,
    }
    insert_at = 0
    for idx, row in enumerate(settings):
        if isinstance(row, dict) and str(row.get('section') or 'Game') == 'Game':
            insert_at = idx + 1
    settings.insert(insert_at, new_row)
    return _write()
