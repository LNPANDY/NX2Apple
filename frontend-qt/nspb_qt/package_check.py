"""Bounded, key-free mirror of the build script's package identification contract."""
from __future__ import annotations
from dataclasses import dataclass, field
from pathlib import Path
import os
import re
import struct

EXTENSIONS = {'.nsp', '.xci', '.nsz', '.xcz'}
MISSING_ID = 'No recognized ticket name and no filename [16 hex title ID]. This is not a keys check.'


@dataclass
class Package:
    path: str
    title: int | None = None
    method: str = 'none'
    reason: str = ''
    role: str = ''
    selected: bool = True
    consumed: bool = True

    @property
    def family(self):
        if self.title is None:
            return None
        low = self.title & 0xfff
        return self.title if low == 0 else (self.title & ~0xfff) - (0 if low == 0x800 else 0x1000)

    @property
    def actual_role(self):
        return 'base' if self.title & 0xfff == 0 else 'update' if self.title & 0xfff == 0x800 else 'dlc'

    @property
    def status(self):
        identity = f'{self.title:016X} via {self.method}' if self.title is not None else self.method
        return f'{self.role}: {identity}; {self.reason or "identified"}'


def inspect(path: str) -> Package:
    p = Package(path)
    try:
        with open(path, 'rb') as f:
            size = f.seek(0, 2)
            f.seek(0)
            head = f.read(0x104)
            if head[:4] == b'PFS0':
                if len(head) < 16:
                    raise ValueError()
                count, names = struct.unpack_from('<II', head, 4)
                length = count * 24 + names
                if count > 4096 or names > 1 << 20 or length > size - 16:
                    raise ValueError()
                f.seek(16)
                table = f.read(length)
                if len(table) != length:
                    raise ValueError()
                for i in range(count):
                    offset, length, name_at = struct.unpack_from('<QQI', table, i * 24)
                    if name_at >= names or offset > size - 16 - len(table) or length > size - 16 - len(table) - offset:
                        raise ValueError()
                    start = count * 24 + name_at
                    end = table.find(b'\0', start)
                    if end < 0:
                        raise ValueError()
                    name = table[start:end]
                    if p.title is None and re.fullmatch(rb'[0-9a-fA-F]{32}\.tik', name):
                        p.title, p.method = int(name[:16], 16), 'ticket name'
            elif head[0x100:0x104] != b'HEAD':
                raise ValueError()
        if p.title is None:
            match = re.search(r'\[([0-9a-fA-F]{16})\]', Path(path).name)
            if match:
                p.title, p.method = int(match[1], 16), 'filename tag'
            else:
                p.reason = MISSING_ID
    except OSError:
        p.title, p.method, p.reason = None, 'none', 'File missing or unreadable.'
    except ValueError:
        p.title, p.method, p.reason = None, 'none', 'Malformed or truncated package header/table.'
    return p


@dataclass
class Result:
    packages: list[Package] = field(default_factory=list)
    title: int | None = None
    ready: bool = False
    needs_staging: bool = True

    @property
    def paths(self):
        return [p.path for p in self.packages if p.consumed and not p.reason]

    @property
    def diagnostics(self):
        # Deliberately omit paths, filenames, ticket contents and key values.
        return 'Package identification (independent of keys)\n' + '\n'.join(p.status for p in self.packages)


def check(files: tuple[str, ...]) -> Result:
    result = Result()
    chosen = [(p, 'base' if i == 0 else 'update' if i == 1 else 'dlc')
              for i, p in enumerate(files) if p]
    if not files or not files[0]:
        return result
    try:
        siblings = sorted(p for p in Path(files[0]).parent.iterdir()
                          if p.suffix in EXTENSIONS and not p.name.startswith('._'))
    except OSError:
        siblings = []
    selected = {str(Path(p)) for p, _ in chosen}
    skipped = []
    for path, role in chosen:
        p = inspect(path)
        suffix = {'.nsz': '.nsp', '.xcz': '.xci'}.get(Path(path).suffix)
        counterpart = Path(path).with_suffix(suffix) if suffix else None
        if counterpart and counterpart.exists() and p.reason in ('', MISSING_ID):
            p.role, p.method, p.reason, p.consumed = role, 'skipped: decompressed counterpart is used', '', False
            p.title = None
            skipped.append(p)
            p = inspect(str(counterpart))
            selected.add(str(counterpart))
        p.role = role
        if Path(path).suffix not in EXTENSIONS:
            p.reason = 'Choose a lowercase .nsp, .xci, .nsz or .xcz package.'
        if Path(path).name.startswith('._'):
            p.reason = 'AppleDouble metadata is not a build input; choose the original package.'
        if not any(os.path.abspath(existing.path) == os.path.abspath(p.path) and existing.role == p.role
                   for existing in result.packages):
            result.packages.append(p)
    def compressed_copy(path):
        suffix = {'.nsz': '.nsp', '.xcz': '.xci'}.get(Path(path).suffix)
        return suffix and Path(path).with_suffix(suffix).exists()

    others = [inspect(str(p)) for p in siblings if str(p) not in selected and not compressed_copy(p)]
    base = result.packages[0]
    candidates = result.packages + others
    families = {p.family for p in candidates if p.title is not None and not p.reason}
    unknown = [p for p in candidates if p.reason == MISSING_ID]
    if base.reason == MISSING_ID and len(families) == 1 and len(unknown) == 1:
        family = next(iter(families))
        if not any(p.title == family for p in candidates):
            base.method, base.reason = 'ticketless base paired with one family; build IDs checked during build', ''
            result.title = family
    if base.title is not None:
        result.title = base.family
    for p in result.packages:
        if p.title is not None:
            if p.actual_role != p.role:
                p.reason = 'Package role does not match the selected slot.'
            elif p.family != result.title:
                p.reason = 'Package belongs to a different game.'
    for p in others:
        if p.title is not None and p.family == result.title and not p.reason and p.actual_role != 'base':
            if p.actual_role == 'update' and len(files) > 1 and files[1]:
                continue
            p.role, p.selected = p.actual_role, False
            # Deduplicate compressed siblings just as the backend does.
            suffix = {'.nsz': '.nsp', '.xcz': '.xci'}.get(Path(p.path).suffix)
            if not suffix or not Path(p.path).with_suffix(suffix).exists():
                result.packages.append(p)
    names = [Path(p.path).name for p in result.packages]
    if len(set(names)) != len(names):
        base.reason = 'Selected files have duplicate names; choose files with distinct names.'
    result.ready = result.title is not None and all(not p.reason for p in result.packages)
    result.needs_staging = set(result.paths) != {str(p) for p in siblings}
    result.packages += skipped
    return result
