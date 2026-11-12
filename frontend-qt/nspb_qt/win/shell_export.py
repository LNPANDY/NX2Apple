"""Shared-app (`NX2Apple.ipa`) library management and IPA export for the Qt front end.

Mirrors the Mac Swift launcher's `ShellInstall.swift`, `ShellExport.swift`, and
`ShellFrameworks.swift`. Each game is built as `DmGame<TitleID>.framework` with
`--shell-framework <work_dir>/shell-framework`, mirrored into `<shell_root>/frameworks/`,
recorded in `<shell_root>/shell.json`, and packed into `<shell_root>/export/NX2Apple.ipa`
inside a pre-built `DmShell.app` template (`frontend-ios` SwiftUI shell).

Each game's shader library is left out of the archive and written to
`<shell_root>/export/shader-libraries/<TitleID>/msl/` instead, to be copied to
`Documents/games/<TitleID>/msl/` on the device: install tools cannot carry the multi-gigabyte
`b-<chain>.img` of a big game (LNPANDY/NX2Apple#947), and the host reads the game's own folder
first (`EngineLaunchPlan.swift`, `nvn_mtl.m`). `external_shaders=False` packs them in again.
"""
from __future__ import annotations

import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import uuid
import zipfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

from .. import platform_util as pu
from . import fix_ipa_modes, macho_sign, toolchain as tc

IPA_NAME = 'NX2Apple.ipa'
APP_NAME = 'DmShell.app'
SCHEME = 'DmShell'
DEFAULT_BUNDLE_ID = 'org.nxnative.shell'
DISCARD_PREFIX = '.discarded-'
SHELL_ENTITLEMENTS = {'com.apple.developer.kernel.increased-memory-limit': True}
ZIP32_ENTRY_LIMIT = 0xFFFF - 2  # 65,533: reserves _CodeSignature/ and CodeResources for sideloaders
SHADER_FOLDER = 'shader-libraries'
SHADER_DIR = 'msl'


@dataclass
class ShellGame:
    title_id: str
    name: str
    framework: str

    def to_dict(self) -> dict[str, str]:
        return {
            'framework': self.framework,
            'name': self.name,
            'titleID': self.title_id,
        }

    @classmethod
    def from_dict(cls, d: dict) -> ShellGame | None:
        tid = str(d.get('titleID') or d.get('title_id') or '').strip().upper()
        fw = str(d.get('framework') or '').strip()
        if not tid or not fw:
            return None
        return cls(title_id=tid, name=str(d.get('name') or ''), framework=fw)


@dataclass
class ShellLibrary:
    bundle_id: str = DEFAULT_BUNDLE_ID
    team: str = ''
    games: list[ShellGame] = field(default_factory=list)

    @staticmethod
    def state_file(root: str | os.PathLike) -> Path:
        return Path(root) / 'shell.json'

    @classmethod
    def load(cls, root: str | os.PathLike) -> ShellLibrary:
        p = cls.state_file(root)
        if not p.is_file():
            library = cls()
            library.adopt_mirrors(root)
            return library
        try:
            data = json.loads(p.read_text(encoding='utf-8'))
            if not isinstance(data, dict):
                return cls()
            bundle_id = str(data.get('bundleID') or DEFAULT_BUNDLE_ID).strip() or DEFAULT_BUNDLE_ID
            team = str(data.get('team') or '').strip()
            games: list[ShellGame] = []
            for item in data.get('games') or []:
                if isinstance(item, dict):
                    g = ShellGame.from_dict(item)
                    if g is not None:
                        games.append(g)
            library = cls(bundle_id=bundle_id, team=team, games=games)
            library.adopt_mirrors(root)
            return library
        except Exception:
            return cls()

    def adopt_mirrors(self, root: str | os.PathLike) -> list[ShellGame]:
        """Register every whole `DmGame*.framework` under `<root>/frameworks/` that is not listed.

        A folder that was moved, restored from a backup, or whose `shell.json` was replaced
        still holds the games' frameworks. Each one carries its name and its title ID in its
        manifest, so the game can be taken back without building it again.
        """
        folder = frameworks_mirror(root)
        known = {g.title_id for g in self.games}
        added: list[ShellGame] = []
        try:
            # Sorted by name: `iterdir` order differs between NTFS and ext4, and this order is the
            # order the games are registered and reported in, so it has to be predictable.
            entries = sorted(folder.iterdir(), key=lambda p: p.name)
        except OSError:
            return added
        for entry in entries:
            if not entry.is_dir():
                continue
            tid = title_id_of_framework(entry)
            if not tid or tid in known:
                continue
            if missing_file_in_framework(entry, tid) is not None:
                continue
            name = tid
            try:
                data = json.loads((entry / 'game.manifest.json').read_text(encoding='utf-8'))
                if isinstance(data, dict):
                    name = str(data.get('name') or '').strip() or tid
            except Exception:
                pass
            game = ShellGame(title_id=tid, name=name, framework=str(entry))
            self.games.append(game)
            known.add(tid)
            added.append(game)
        return added

    def save(self, root: str | os.PathLike) -> None:
        root_p = Path(root)
        root_p.mkdir(parents=True, exist_ok=True)
        dropped = self._dropped_entries(root_p)
        payload = {
            'bundleID': self.bundle_id,
            'games': [g.to_dict() for g in self.games],
            'team': self.team,
        }
        tmp = root_p / f'.shell.json.{uuid.uuid4().hex[:8]}'
        tmp.write_text(json.dumps(payload, indent=2, sort_keys=True, ensure_ascii=False) + '\n',
                       encoding='utf-8')
        os.replace(tmp, self.state_file(root_p))
        if dropped:
            self._keep_dropped(root_p, dropped)

    def _dropped_entries(self, root: Path) -> list[dict]:
        """The entries on disk that this save would forget."""
        p = self.state_file(root)
        if not p.is_file():
            return []
        try:
            data = json.loads(p.read_text(encoding='utf-8'))
        except Exception:
            return []
        if not isinstance(data, dict):
            return []
        here = {g.title_id for g in self.games}
        out: list[dict] = []
        for item in data.get('games') or []:
            if not isinstance(item, dict):
                continue
            tid = str(item.get('titleID') or item.get('title_id') or '').strip().upper()
            if tid and tid not in here:
                out.append(item)
        return out

    def _keep_dropped(self, root: Path, entries: list[dict]) -> None:
        """Write the forgotten entries to `shell.json.bak`: the only record of them left."""
        payload = {'bundleID': self.bundle_id, 'games': entries, 'team': self.team}
        try:
            (root / 'shell.json.bak').write_text(
                json.dumps(payload, indent=2, sort_keys=True, ensure_ascii=False) + '\n',
                encoding='utf-8')
        except OSError:
            pass

    def add(self, game: ShellGame) -> None:
        for i, existing in enumerate(self.games):
            if existing.title_id == game.title_id:
                self.games[i] = game
                return
        self.games.append(game)

    def missing(self, exists: Callable[[str], bool] = os.path.isdir) -> list[ShellGame]:
        return [g for g in self.games if not exists(g.framework)]

    def drop_missing(self, exists: Callable[[str], bool] = os.path.isdir,
                     log: Callable[[str], None] = lambda _: None) -> list[ShellGame]:
        """Return the games whose framework is not on disk, and keep them registered.

        Forgetting one here is what made it disappear from the shared app for good: the build
        folder it came from is often gone too by then, so nothing is left to register it again.
        """
        gone = self.missing(exists)
        for g in gone:
            log(f'library: {g.title_id} ({g.name or g.title_id}) stays registered but its '
                f'framework is not on disk, so this export leaves it out: {g.framework}\n')
        return gone


def export_folder(root: str | os.PathLike) -> Path:
    return Path(root) / 'export'


def ipa_path(root: str | os.PathLike) -> Path:
    return export_folder(root) / IPA_NAME


def export_stage(root: str | os.PathLike) -> Path:
    return export_folder(root) / 'stage'


def shader_libraries_folder(root: str | os.PathLike) -> Path:
    return export_folder(root) / SHADER_FOLDER


def external_shader_folder(root: str | os.PathLike, title_id: str) -> Path:
    return shader_libraries_folder(root) / title_id.upper()


def frameworks_mirror(root: str | os.PathLike) -> Path:
    return Path(root) / 'frameworks'


def mirrored_framework(root: str | os.PathLike, title_id: str) -> Path:
    return frameworks_mirror(root) / f'DmGame{title_id}.framework'


def title_id_of_framework(framework: str | os.PathLike) -> str:
    name = Path(framework).name
    if name.startswith('DmGame') and name.endswith('.framework') and len(name) > len('DmGame.framework'):
        raw = name[len('DmGame'):-len('.framework')]
        return raw.upper() if re.fullmatch(r'[0-9A-Fa-f]{16}', raw) else raw
    return ''


def built_framework(work_dir: str | os.PathLike) -> Path | None:
    """Return the newest `DmGame*.framework` inside `<work_dir>/shell-framework`."""
    folder = Path(work_dir) / 'shell-framework'
    if not folder.is_dir():
        return None
    cands = [
        p for p in folder.iterdir()
        if p.is_dir() and p.name.startswith('DmGame') and p.name.endswith('.framework')
        and len(p.name) > len('DmGame.framework')
    ]
    if not cands:
        return None

    def key(p: Path) -> tuple[float, str]:
        try:
            return (p.stat().st_mtime, p.name)
        except OSError:
            return (0.0, p.name)

    return max(cands, key=key)


def discard(path: str | os.PathLike) -> bool:
    """Rename `path` to a hidden `.discarded-<uuid>` sibling and remove it."""
    p = Path(path)
    if not p.exists():
        return True
    aside = p.parent / f'{DISCARD_PREFIX}{uuid.uuid4().hex}'
    try:
        p.rename(aside)
    except OSError:
        shutil.rmtree(p, ignore_errors=True)
        return not p.exists()
    shutil.rmtree(aside, ignore_errors=True)
    return True


def sweep_discarded(folder: str | os.PathLike) -> None:
    f = Path(folder)
    if not f.is_dir():
        return
    try:
        for child in f.iterdir():
            if child.name.startswith(DISCARD_PREFIX):
                shutil.rmtree(child, ignore_errors=True)
    except OSError:
        pass


def mirror_framework(framework: str | os.PathLike, root: str | os.PathLike,
                     title_id: str | None = None) -> Path:
    """Copy `framework` into `<root>/frameworks/DmGame<titleID>.framework` atomically."""
    src = Path(framework)
    tid = title_id or title_id_of_framework(src)
    mirror = mirrored_framework(root, tid)
    if src.resolve() == mirror.resolve():
        return mirror
    mirror.parent.mkdir(parents=True, exist_ok=True)
    tmp = mirror.parent / f'{DISCARD_PREFIX}{uuid.uuid4().hex}'
    try:
        shutil.copytree(src, tmp, symlinks=True)
        if not discard(mirror):
            raise OSError(f'could not replace existing framework mirror at {mirror}')
        tmp.rename(mirror)
    except BaseException:
        shutil.rmtree(tmp, ignore_errors=True)
        raise
    return mirror


def mirror_frameworks(library: ShellLibrary, root: str | os.PathLike,
                      log: Callable[[str], None] = lambda _: None) -> None:
    for g in library.games:
        mirror = mirrored_framework(root, g.title_id)
        if Path(g.framework) == mirror:
            continue
        if Path(g.framework).is_dir():
            try:
                mirror_framework(g.framework, root, g.title_id)
                g.framework = str(mirror)
            except OSError as e:
                log(f"library: {g.title_id}'s framework could not be mirrored at {mirror}, "
                    f"it stays at {g.framework}: {e}\n")
        elif mirror.is_dir():
            log(f"library: {g.title_id}'s build folder is gone, its framework is the mirror at {mirror}\n")
            g.framework = str(mirror)


def missing_file_in_framework(framework: str | os.PathLike, title_id: str) -> str | None:
    """Return the first required file missing from `framework`, or None when whole."""
    fw = Path(framework)
    manifest_p = fw / 'game.manifest.json'
    if not manifest_p.is_file():
        return 'game.manifest.json'
    try:
        data = json.loads(manifest_p.read_text(encoding='utf-8'))
        if not isinstance(data, dict):
            return 'game.manifest.json'
    except Exception:
        return 'game.manifest.json'
    if data.get('loader') != 'FH':
        return 'game.manifest.json (loader != FH)'
    exe = str(data.get('framework_executable') or '').strip() or f'DmGame{title_id}'
    if not (fw / exe).is_file():
        return exe
    return None


def leave_out_incomplete(
    library: ShellLibrary,
    root: str | os.PathLike,
    title_id: str,
    name: str,
    t_func: Callable[..., str],
    log: Callable[[str], None] = lambda _: None,
) -> tuple[list[ShellGame], str | None]:
    """Return the incomplete earlier frameworks to leave out; fail on the current game's own.

    The incompletes stay registered and stay on disk: the folder they came from is usually gone
    by the time they are incomplete, so throwing the entries and the files away here is what made
    a game disappear from the shared app for good.
    """
    left_out: list[ShellGame] = []
    for g in library.games:
        missing = missing_file_in_framework(g.framework, g.title_id)
        if missing is None:
            continue
        if g.title_id == title_id:
            return [], t_func('shell.frameworkIncomplete', name, missing)
        note = t_func('shell.gameLeftOut', g.name or g.title_id, missing)
        log(f'library: {note} ({g.framework})\n')
        left_out.append(g)
    return left_out, None


def find_framework_copy(title_id: str, search_dirs: list[str | os.PathLike]) -> Path | None:
    """Return a whole `DmGame<title ID>.framework` for `title_id` from one of `search_dirs`."""
    name = f'DmGame{title_id}.framework'
    seen: set[str] = set()
    for raw in search_dirs:
        try:
            base = Path(raw)
        except (TypeError, ValueError):
            continue
        for place in (base, base / name, base / 'frameworks' / name, base / 'shell-framework' / name):
            try:
                key = str(place.resolve()).lower()
            except OSError:
                continue
            if key in seen:
                continue
            seen.add(key)
            if not place.is_dir():
                continue
            if missing_file_in_framework(place, title_id) is None:
                return place
    return None


def recover_frameworks(
    library: ShellLibrary,
    root: str | os.PathLike,
    search_dirs: list[str | os.PathLike],
    log: Callable[[str], None] = lambda _: None,
) -> tuple[list[str], list[ShellGame]]:
    """Mirror whole frameworks found in `search_dirs` back into `root` for the games that need them.

    This is what makes a moved or emptied cache recoverable without building the games again:
    the framework the old folder holds is the same file the game was built into.
    """
    recovered: list[str] = []
    still: list[ShellGame] = []
    for g in library.games:
        if missing_file_in_framework(g.framework, g.title_id) is None:
            continue
        found = find_framework_copy(g.title_id, [g.framework, *search_dirs])
        if found is None:
            still.append(g)
            continue
        mirror = mirrored_framework(root, g.title_id)
        try:
            if Path(found).resolve() != mirror.resolve():
                mirror_framework(found, root, g.title_id)
            g.framework = str(mirror)
        except OSError as e:
            log(f"library: {g.title_id}'s framework could not be put back from {found}: {e}\n")
            still.append(g)
            continue
        log(f'library: {g.title_id} was put back from {found} into {mirror}\n')
        recovered.append(f'{g.title_id} ({g.name or g.title_id})')
    return recovered, still


def frameworks_in_ipa(ipa: str | os.PathLike) -> list[str]:
    """The `DmGame*.framework` names an IPA actually holds under `Payload/<shell>/Frameworks/`."""
    prefix = f'Payload/{APP_NAME}/Frameworks/'
    names: set[str] = set()
    with zipfile.ZipFile(ipa) as zf:
        for info in zf.infolist():
            if not info.filename.startswith(prefix):
                continue
            rest = info.filename[len(prefix):]
            first = rest.split('/', 1)[0]
            if first.endswith('.framework'):
                names.add(first)
    return sorted(names)


def check_ipa_has_games(ipa: str | os.PathLike, title_ids: list[str]) -> None:
    """Raise when the packed IPA lacks a framework it was asked to hold."""
    present = set(frameworks_in_ipa(ipa))
    missing = [f'DmGame{tid}.framework' for tid in title_ids
               if f'DmGame{tid}.framework' not in present]
    if missing:
        raise RuntimeError(f'the archive is missing {", ".join(missing)}; the old IPA was kept')


def place_banner(
    title_id: str,
    framework: str | os.PathLike,
    banners_dir: str | os.PathLike | None = None,
    picked: str | None = None,
) -> str | None:
    """Copy the game's 16:9 banner into `<framework>/banner.<ext>`, or remove stale banners."""
    fw = Path(framework)
    exts = ('png', 'jpg', 'jpeg', 'heic', 'webp')
    for ext in exts:
        try:
            (fw / f'banner.{ext}').unlink(missing_ok=True)
        except OSError:
            pass
    cands: list[Path] = []
    if picked:
        cands.append(Path(picked))
    if banners_dir:
        bdir = Path(banners_dir)
        tid_up = title_id.upper()
        for ext in exts:
            cands.append(bdir / f'{tid_up}.{ext}')
    source = next((p for p in cands if p.is_file()), None)
    if source is None:
        return None
    ext = source.suffix.lstrip('.').lower()
    if ext not in exts:
        ext = 'jpg'
    dest = fw / f'banner.{ext}'
    try:
        shutil.copy2(source, dest)
        return str(source)
    except OSError:
        return None


def framework_shaders(framework: str | os.PathLike) -> Path | None:
    """Return the `msl` folder of `framework`, or None when it carries no shader library."""
    folder = Path(framework) / SHADER_DIR
    return folder if folder.is_dir() else None


def shader_library_skip(framework_name: str) -> str:
    """The archive path `pack_ipa.py --skip` leaves out: a framework's whole shader folder."""
    return f'Payload/{APP_NAME}/Frameworks/{framework_name}/{SHADER_DIR}'


def place_shader_library(framework: str | os.PathLike, root: str | os.PathLike,
                         title_id: str, log: Callable[[str], None] = lambda _: None) -> Path | None:
    """Copy `framework`'s shader library to `<root>/export/shader-libraries/<title id>/msl`.

    The copy is a hard link where the volume allows it, so the gigabytes of a big game are not
    stored twice. Returns the folder holding it, or None when the framework carries none.
    """
    source = framework_shaders(framework)
    if source is None:
        return None
    dest = external_shader_folder(root, title_id) / SHADER_DIR
    try:
        dest.mkdir(parents=True, exist_ok=True)
        # A library of 10 GB is moved once, not once per export: a file already there with the
        # same name and size is left alone, and only what the framework no longer carries goes.
        _copy_shaders(source, dest, log)
        return dest
    except OSError as e:
        log(f'shader library: {source} was not copied to {dest}: {e}\n')
        return None


def _copy_shaders(source: Path, dest: Path, log: Callable[[str], None]) -> None:
    """Make `dest` hold `source`, copying only what is missing or a different size."""
    try:
        wanted = {member.name for member in source.iterdir()}
    except OSError:
        wanted = set()
    try:
        stale = sorted(dest.iterdir(), key=lambda p: p.name)
    except OSError:
        stale = []
    for old in stale:
        if old.name in wanted:
            continue
        try:
            if old.is_dir() and not old.is_symlink():
                shutil.rmtree(old, ignore_errors=True)
            else:
                old.unlink()
        except OSError as e:
            log(f'shader library: {old} was not removed: {e}\n')
    for member in sorted(source.iterdir(), key=lambda p: p.name):
        target = dest / member.name
        try:
            if member.is_dir():
                if target.exists() and not target.is_dir():
                    target.unlink()
                target.mkdir(parents=True, exist_ok=True)
                _copy_shaders(member, target, log)
                continue
            if target.is_dir():
                shutil.rmtree(target, ignore_errors=True)
            if target.is_file() and target.stat().st_size == member.stat().st_size:
                continue
            if target.exists():
                target.unlink()
            try:
                os.link(member, target)
            except OSError:
                if target.exists():
                    target.unlink()
                shutil.copy2(member, target)
        except OSError as e:
            log(f'shader library: {member} was not copied to {target}: {e}\n')


def find_shell_template(repo: str | os.PathLike, root: str | os.PathLike | None = None,
                        log: Callable[[str], None] = lambda _: None) -> Path | None:
    """Locate the pre-built `DmShell.app` template bundle."""
    cands: list[Path] = []
    env_tpl = os.environ.get('NSPB_SHELL_TEMPLATE')
    if env_tpl:
        cands.append(Path(env_tpl))
    meipass = getattr(sys, '_MEIPASS', None)
    if meipass:
        cands.append(Path(meipass) / 'shell_template' / APP_NAME)
        cands.append(Path(meipass).parent / 'shell_template' / APP_NAME)
    cands.append(Path(sys.executable).parent / 'shell_template' / APP_NAME)
    cands.append(Path(__file__).resolve().parent / 'shell_template' / APP_NAME)
    if root:
        cands.append(Path(root) / 'template' / APP_NAME)

    for c in cands:
        if (c / SCHEME).is_file() and (c / 'Info.plist').is_file():
            return c

    # On a macOS source checkout without a pre-built template, build one once into <root>/template/DmShell.app
    if not pu.IS_WIN and root:
        repo_p = Path(repo)
        builder = repo_p.parent / 'tools' / 'build_shell_template.py'
        if not builder.is_file():
            builder = repo_p / 'tools' / 'build_shell_template.py'
        if builder.is_file():
            out_tpl = Path(root) / 'template' / APP_NAME
            log(f'Building {APP_NAME} template at {out_tpl}...\n')
            r = subprocess.run(
                [sys.executable, str(builder), '--engine', str(repo_p), '--out', str(out_tpl)],
                capture_output=True, text=True, encoding='utf-8', errors='replace',
            )
            if r.returncode == 0 and (out_tpl / SCHEME).is_file():
                return out_tpl
            log(f'build_shell_template.py failed: {r.stdout}\n{r.stderr}\n')
    return None


def _dm_chain(repo: Path) -> str:
    hdr = repo / 'dm' / 'gfx' / 'nvn' / 'dmsh_chain.h'
    if hdr.is_file():
        m = re.search(r'^#define\s+DMSH_CHAIN\s+"([^"]+)"', hdr.read_text(encoding='utf-8', errors='replace'), re.M)
        if m:
            return m.group(1)
    return ''


def _dm_commit(repo: Path) -> str:
    try:
        r = subprocess.run(['git', '-C', str(repo), 'rev-parse', '--short=12', 'HEAD'],
                           capture_output=True, text=True, timeout=5, **pu.no_window_kwargs())
        if r.returncode == 0 and r.stdout.strip():
            commit = r.stdout.strip()
            s = subprocess.run(['git', '-C', str(repo), 'status', '--porcelain', '--untracked-files=no'],
                               capture_output=True, text=True, timeout=5, **pu.no_window_kwargs())
            if s.returncode == 0 and s.stdout.strip():
                commit += '+dirty'
            return commit
    except Exception:
        pass
    return ''


def _dm_fork_patches(repo: Path) -> str:
    fp = repo / 'dm' / 'fork_patches.txt'
    if fp.is_file():
        lines = [ln.strip() for ln in fp.read_text(encoding='utf-8', errors='replace').splitlines() if ln.strip()]
        return ','.join(lines)
    return ''


def _prepare_fonts(staged_app: Path, repo: Path, python_exe: str) -> None:
    font_dir = staged_app / 'dm' / 'font'
    font_dir.mkdir(parents=True, exist_ok=True)
    std_dst = font_dir / 'standard.ttf'
    if not std_dst.is_file():
        std_src = tc.std_font()
        if std_src is None and os.environ.get('STD_FONT'):
            std_src = Path(os.environ['STD_FONT'])
        if std_src is None and not pu.IS_WIN:
            mac_font = Path('/System/Library/Fonts/Supplemental/Arial Unicode.ttf')
            if mac_font.is_file():
                std_src = mac_font
        if std_src is None or not std_src.is_file():
            raise RuntimeError('no standard.ttf font available (set STD_FONT or check Windows Fonts)')
        shutil.copyfile(std_src, std_dst)

    ext_dst = font_dir / 'nintendo_ext.ttf'
    if not ext_dst.is_file():
        letter = tc.letter_font()
        if letter is None and os.environ.get('LETTER_FONT'):
            letter = Path(os.environ['LETTER_FONT'])
        if letter is None and not pu.IS_WIN:
            mac_letter = Path('/System/Library/Fonts/Supplemental/Arial Rounded Bold.ttf')
            if mac_letter.is_file():
                letter = mac_letter
        if letter is None or not letter.is_file():
            raise RuntimeError('no bold TTF for the button icons (set LETTER_FONT or check Windows Fonts)')
        make_ext = repo / 'dm' / 'tools' / 'make_ext_font.py'
        r = subprocess.run(
            [python_exe, str(make_ext), str(ext_dst), str(letter)],
            capture_output=True, text=True, encoding='utf-8', errors='replace',
            env=pu.child_env(), **pu.no_window_kwargs(),
        )
        if r.returncode != 0 or not ext_dst.is_file():
            raise RuntimeError(f'make_ext_font.py failed: {r.stderr or r.stdout}')


def _update_shell_plist(staged_app: Path, bundle_id: str, repo: Path) -> None:
    plist_p = staged_app / 'Info.plist'
    with open(plist_p, 'rb') as f:
        info = plistlib.load(f)
    info['CFBundleIdentifier'] = bundle_id
    info.setdefault('CFBundleDisplayName', 'NX2Apple')
    chain = _dm_chain(repo)
    if chain:
        info['DMChain'] = chain
    commit = _dm_commit(repo)
    if commit:
        info['DMCommit'] = commit
    info['DMForkPatches'] = _dm_fork_patches(repo)
    with open(plist_p, 'wb') as f:
        plistlib.dump(info, f, fmt=plistlib.FMT_XML, sort_keys=True)


def _resolve_python_exe(python_exe: str = '') -> str:
    """Return a real Python interpreter even when called from a frozen PyInstaller GUI."""
    if python_exe:
        exe_name = Path(python_exe).stem.lower()
        if not (getattr(sys, 'frozen', False) and exe_name.startswith('nx2apple')):
            return python_exe
    if not getattr(sys, 'frozen', False):
        return sys.executable
    py, _, _ = pu.find_python()
    return py or ('python' if pu.IS_WIN else '/usr/bin/python3')


def _cleanup_tmp_sidecars(tmp_ipa: Path) -> None:
    """Remove temporary IPA and any sidecar files written by `pack_ipa.py` (`.idx`, `.partial`, `.clone`)."""
    base = str(tmp_ipa)
    for p in (
        tmp_ipa,
        Path(base + '.idx'),
        Path(base + '.partial'),
        Path(base + '.clone'),
        Path(base + '.idx.partial'),
    ):
        try:
            p.unlink(missing_ok=True)
        except OSError:
            pass


def _count_tree_entries(root: Path, cap: int) -> int:
    """Count `root` plus its descendants, stopping once `cap` is exceeded."""
    if not root.exists():
        return 0
    total = 1
    if not root.is_dir():
        return total
    for _dirpath, dirnames, filenames in os.walk(root):
        total += len(dirnames) + len(filenames)
        if total > cap:
            return total
    return total


def _estimate_ipa_entries(staged_app: Path, fw_paths: list[Path], limit: int,
                          skip_shader_dirs: bool = False) -> int:
    """Estimate total ZIP entries for `Payload/`, `DmShell.app`, and mapped frameworks.

    `skip_shader_dirs` leaves each framework's `msl` folder out of the count, which is what an
    export with `external_shaders` writes: those entries never reach the archive.
    """
    cap = limit + 1
    # 1 for Payload/, plus DmShell.app tree, plus Frameworks/ container when frameworks exist.
    total = 1 + _count_tree_entries(staged_app, cap)
    if fw_paths and not (staged_app / 'Frameworks').exists():
        total += 1
    for fw in fw_paths:
        if total > cap:
            return total
        entries = _count_tree_entries(fw, cap - total + 1)
        if skip_shader_dirs:
            shaders = fw / SHADER_DIR
            if shaders.is_dir():
                entries -= _count_tree_entries(shaders, entries)
        total += entries
    return total


def _pack_loose_shader_dirs(
    fw_paths: list[Path],
    *,
    stage_dir: Path,
    repo_p: Path,
    py_exe: str,
    entry_limit: int,
    staged_app: Path,
    log: Callable[[str], None],
) -> list[Path]:
    """Pack loose `msl/**/b-*` shader folders into single `.img` files when entry count exceeds `entry_limit`."""
    shader_lib_py = repo_p / 'dm' / 'tools' / 'shader_lib.py'
    staged_fw_root = stage_dir / 'packed_frameworks'
    out_fws: list[Path] = []
    aa_bin = Path('/usr/bin/aa')

    for fw_path in fw_paths:
        msl_dir = fw_path / 'msl'
        if not msl_dir.is_dir():
            out_fws.append(fw_path)
            continue

        b_dirs: list[Path] = []
        for cand in sorted(msl_dir.iterdir()):
            if cand.is_dir() and cand.name.startswith('b-'):
                b_dirs.append(cand)
            elif cand.is_dir() and re.fullmatch(r'p\d+', cand.name):
                for sub in sorted(cand.iterdir()):
                    if sub.is_dir() and sub.name.startswith('b-'):
                        b_dirs.append(sub)

        if not b_dirs and not aa_bin.is_file():
            out_fws.append(fw_path)
            continue

        staged_fw = staged_fw_root / fw_path.name
        shutil.rmtree(staged_fw, ignore_errors=True)
        staged_fw.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(fw_path, staged_fw, symlinks=True)

        if shader_lib_py.is_file():
            for rel_b in [d.relative_to(fw_path) for d in b_dirs]:
                target_b = staged_fw / rel_b
                if not target_b.is_dir():
                    continue
                r = subprocess.run(
                    [py_exe, str(shader_lib_py), 'pack', str(target_b)],
                    capture_output=True,
                    text=True,
                    encoding='utf-8',
                    errors='replace',
                    env=pu.child_env(),
                    **pu.no_window_kwargs(),
                )
                if r.returncode != 0 or not Path(f'{target_b}.img').is_file():
                    why = (r.stderr or r.stdout or f'exit {r.returncode}').strip()
                    raise RuntimeError(f'shader_lib pack failed for {fw_path.name}: {why}')
                log(f'packed loose shader folder into {rel_b}.img for {fw_path.name}\n')

        staged_msl = staged_fw / 'msl'
        if (
            staged_msl.is_dir()
            and aa_bin.is_file()
            and _count_tree_entries(staged_msl, entry_limit) > 256
        ):
            for old_aar in list(staged_fw.glob('msl-*.aar')):
                old_aar.unlink(missing_ok=True)
            aar_out = staged_fw / f'msl-{uuid.uuid4()}.aar'
            r_aa = subprocess.run(
                [str(aa_bin), 'archive', '-d', str(staged_msl), '-o', str(aar_out), '-a', 'lzfse'],
                capture_output=True,
                text=True,
                encoding='utf-8',
                errors='replace',
            )
            if r_aa.returncode == 0 and aar_out.is_file():
                shutil.rmtree(staged_msl, ignore_errors=True)

        out_fws.append(staged_fw)

    return out_fws


def export_shell(
    *,
    root: str | os.PathLike,
    repo: str | os.PathLike,
    framework: str | os.PathLike,
    title_id: str,
    name: str,
    python_exe: str = '',
    banners_dir: str | os.PathLike | None = None,
    picked_artwork: str | None = None,
    t_func: Callable[..., str] | None = None,
    log: Callable[[str], None] = lambda _: None,
    stage_cb: Callable[[str, str], None] | None = None,
    entry_limit: int = ZIP32_ENTRY_LIMIT,
    extra_dirs: list[str | os.PathLike] | None = None,
    external_shaders: bool = True,
) -> tuple[bool, str, str, list[str]]:
    """Mirror `framework` into `root`, update `shell.json`, and pack `<root>/export/NX2Apple.ipa`.

    `extra_dirs` are folders to look in for a registered game whose framework is not in `root`
    any more, such as the cache folder the user moved away from or a backup copy.

    `entry_limit` is the sideloader ZIP32 entry cap: past it the framework shader folders are packed
    into images first, and the export fails rather than write an archive no sideloader can read.

    `external_shaders` leaves every game's shader library out of the archive and writes it to
    `<root>/export/shader-libraries/<title id>/msl/` for the player to copy to
    `Documents/games/<title id>/msl/` on the device. Pass False to pack them in again, which is
    what an older shell expects.

    Returns `(ok, ipa_path, message, notes)`.
    """
    def _t(key: str, *args: object) -> str:
        if t_func is not None:
            return t_func(key, *args)
        return f'{key}: ' + ', '.join(str(a) for a in args) if args else key

    root_p = Path(root)
    repo_p = Path(repo)
    fw_p = Path(framework)
    tid_norm = title_id.strip().upper() if re.fullmatch(r'[0-9A-Fa-f]{16}', title_id.strip()) else title_id.strip()
    py_exe = _resolve_python_exe(python_exe)

    if not fw_p.is_dir():
        folder = fw_p.parent.name or 'shell-framework'
        return False, '', _t('shell.noFramework', name, folder), []

    # 1. Update shell.json and mirror frameworks into <root>/frameworks/
    notes: list[str] = []
    sweep_discarded(frameworks_mirror(root_p))
    library = ShellLibrary.load(root_p)
    library.add(ShellGame(title_id=tid_norm, name=name, framework=str(fw_p)))
    mirror_frameworks(library, root_p, log=log)
    recovered, _still = recover_frameworks(
        library, root_p, [d for d in (extra_dirs or []) if d], log=log)
    library.drop_missing(log=log)
    left_out, err = leave_out_incomplete(library, root_p, tid_norm, name, _t, log=log)
    if err is not None:
        return False, '', _t('shell.projectFailed', err), []
    if left_out:
        # The archive on disk holds games this export cannot hold: keeping it is the only way
        # not to lose them from the phone, so say which files are missing and stop.
        try:
            library.save(root_p)
        except OSError as e:
            return False, '', _t('shell.projectFailed', str(e)), []
        blocked = [f'{g.title_id} ({g.name or g.title_id}): '
                   f'{missing_file_in_framework(g.framework, g.title_id)}'
                   for g in left_out]
        return False, '', _t('shell.gamesMissing', str(ipa_path(root_p)), '\n'.join(blocked)), []
    pack_ids = [g.title_id for g in library.games]

    for g in library.games:
        picked = picked_artwork if g.title_id == tid_norm else None
        banner = place_banner(g.title_id, g.framework, banners_dir=banners_dir, picked=picked)
        if banner:
            log(f'banner: {g.title_id} {banner}\n')

    try:
        library.save(root_p)
    except OSError as e:
        return False, '', _t('shell.projectFailed', str(e)), []

    if recovered:
        notes.append(_t('shell.gamesRecovered', ', '.join(recovered)))

    # The shader library of a big game is several gigabytes in one file, which the install tools
    # cannot copy on to the phone (LNPANDY/NX2Apple#947). Write it beside the IPA for the player
    # to send to Documents/games/<title id>/msl/, where the host reads it first, and leave it out
    # of the archive.
    skips: list[str] = []
    shader_dirs: list[str] = []
    if external_shaders:
        for g in library.games:
            fw_name = Path(g.framework).name
            placed = place_shader_library(g.framework, root_p, g.title_id, log=log)
            if placed is None:
                continue
            skips.append(shader_library_skip(fw_name))
            shader_dirs.append(f'{g.title_id}: {placed}')
        if shader_dirs:
            notes.append(_t('shell.shadersExported', str(shader_libraries_folder(root_p)),
                            '\n'.join(shader_dirs)))

    # 2. Stage DmShell.app from the pre-built template
    pack_stage_name = _t('shell.exportPackStage')
    if stage_cb:
        stage_cb(pack_stage_name, 'running')

    tpl = find_shell_template(repo_p, root=root_p, log=log)
    if tpl is None or not (tpl / SCHEME).is_file():
        if stage_cb:
            stage_cb(pack_stage_name, 'failed')
        return False, '', _t('shell.exportFailed', f'missing {APP_NAME} template'), notes

    stage_dir = export_stage(root_p)
    out_ipa = ipa_path(root_p)
    out_ipa.parent.mkdir(parents=True, exist_ok=True)
    tmp_ipa = out_ipa.parent / f'.{IPA_NAME}.{uuid.uuid4().hex[:8]}.tmp'
    staged_app = stage_dir / 'Payload' / APP_NAME
    try:
        shutil.rmtree(stage_dir, ignore_errors=True)
        _cleanup_tmp_sidecars(tmp_ipa)
        staged_app.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(tpl, staged_app, symlinks=True)
        # Ensure template carries no stale embedded frameworks; pack_ipa maps the live ones
        shutil.rmtree(staged_app / 'Frameworks', ignore_errors=True)

        _prepare_fonts(staged_app, repo_p, py_exe)
        _update_shell_plist(staged_app, library.bundle_id, repo_p)

        # Ad-hoc sign DmShell with the Increased Memory Limit entitlement
        macho_sign.sign(staged_app / SCHEME, library.bundle_id, SHELL_ENTITLEMENTS)

        # 3. Pack Payload/DmShell.app and every game's framework into a temporary archive first,
        # then atomically replace export/NX2Apple.ipa so an existing IPA is preserved on failure.
        raw_fw_paths = [Path(g.framework) for g in library.games]
        # With the libraries beside the IPA their folders are skipped, so they cost no entries and
        # packing them into images first would only write files nobody sends.
        if _estimate_ipa_entries(staged_app, raw_fw_paths, entry_limit,
                                 skip_shader_dirs=external_shaders) > entry_limit:
            effective_fw_paths = _pack_loose_shader_dirs(
                raw_fw_paths,
                stage_dir=stage_dir,
                repo_p=repo_p,
                py_exe=py_exe,
                entry_limit=entry_limit,
                staged_app=staged_app,
                log=log,
            )
        else:
            effective_fw_paths = raw_fw_paths

        est_entries = _estimate_ipa_entries(staged_app, effective_fw_paths, entry_limit,
                                            skip_shader_dirs=external_shaders)
        if est_entries > entry_limit:
            raise RuntimeError(
                f'IPA entry count exceeds the {entry_limit:,}-entry ZIP32 sideloader limit '
                '(remove unused games from the shared app or rebuild them with packed shader images)'
            )

        pack_py = repo_p / 'dm' / 'ios' / 'tools' / 'pack_ipa.py'
        maps: list[str] = []
        executables = [f'Payload/{APP_NAME}/{SCHEME}']
        for fw_path in effective_fw_paths:
            fw_name = fw_path.name
            fw_exe = fw_path.stem
            maps.append(f'Payload/{APP_NAME}/Frameworks/{fw_name}={fw_path}')
            executables.append(f'Payload/{APP_NAME}/Frameworks/{fw_name}/{fw_exe}')
        maps.append(f'Payload/{APP_NAME}={staged_app}')

        cmd = [py_exe, str(pack_py), str(tmp_ipa), '--no-reuse']
        for skip in skips:
            cmd += ['--skip', skip]
        cmd += maps
        log(f'[{pack_stage_name}] {" ".join(cmd)}\n')
        r = subprocess.run(
            cmd, capture_output=True, text=True, encoding='utf-8', errors='replace',
            env=pu.child_env(), **pu.no_window_kwargs(),
        )
        if r.stdout:
            log(r.stdout)
        if r.stderr:
            log(r.stderr)
        if r.returncode != 0 or not tmp_ipa.is_file():
            why = (r.stderr or r.stdout or f'exit {r.returncode}').strip().splitlines()[-1]
            raise RuntimeError(why)

        with zipfile.ZipFile(tmp_ipa, 'r') as zf_check:
            actual_entries = len(zf_check.infolist())
        if actual_entries > entry_limit:
            raise RuntimeError(
                f'packed IPA holds {actual_entries:,} entries, exceeding the {entry_limit:,}-entry ZIP32 limit'
            )
        # The archive must hold every game it was asked to hold before it may replace the one
        # on disk, which the phone's library and the user's saves are tied to.
        check_ipa_has_games(tmp_ipa, pack_ids)

        mode_summary = fix_ipa_modes.fix(tmp_ipa, executables)
        log(f'{mode_summary}\n')
        os.replace(tmp_ipa, out_ipa)
    except Exception as e:
        if stage_cb:
            stage_cb(pack_stage_name, 'failed')
        return False, '', _t('shell.exportFailed', str(e)), notes
    finally:
        shutil.rmtree(stage_dir, ignore_errors=True)
        _cleanup_tmp_sidecars(tmp_ipa)

    if stage_cb:
        stage_cb(pack_stage_name, 'done')
    msg = '\n'.join([_t('shell.exportDone', str(out_ipa))] + notes)
    return True, str(out_ipa), msg, notes
