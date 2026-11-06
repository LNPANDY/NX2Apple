"""Shared-app (`NX2Apple.ipa`) library management and IPA export for the Qt front end.

Mirrors the Mac Swift launcher's `ShellInstall.swift`, `ShellExport.swift`, and
`ShellFrameworks.swift`. Each game is built as `DmGame<TitleID>.framework` with
`--shell-framework <work_dir>/shell-framework`, mirrored into `<shell_root>/frameworks/`,
recorded in `<shell_root>/shell.json`, and packed into `<shell_root>/export/NX2Apple.ipa`
inside a pre-built `DmShell.app` template (`frontend-ios` SwiftUI shell).
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
            return cls()
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
            return cls(bundle_id=bundle_id, team=team, games=games)
        except Exception:
            return cls()

    def save(self, root: str | os.PathLike) -> None:
        root_p = Path(root)
        root_p.mkdir(parents=True, exist_ok=True)
        payload = {
            'bundleID': self.bundle_id,
            'games': [g.to_dict() for g in self.games],
            'team': self.team,
        }
        tmp = root_p / f'.shell.json.{uuid.uuid4().hex[:8]}'
        tmp.write_text(json.dumps(payload, indent=2, sort_keys=True, ensure_ascii=False) + '\n',
                       encoding='utf-8')
        os.replace(tmp, self.state_file(root_p))

    def add(self, game: ShellGame) -> None:
        for i, existing in enumerate(self.games):
            if existing.title_id == game.title_id:
                self.games[i] = game
                return
        self.games.append(game)

    def drop_missing(self, exists: Callable[[str], bool] = os.path.isdir) -> None:
        self.games = [g for g in self.games if exists(g.framework)]


def export_folder(root: str | os.PathLike) -> Path:
    return Path(root) / 'export'


def ipa_path(root: str | os.PathLike) -> Path:
    return export_folder(root) / IPA_NAME


def export_stage(root: str | os.PathLike) -> Path:
    return export_folder(root) / 'stage'


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
) -> tuple[list[str], str | None]:
    """Filter out incomplete earlier frameworks; fail if the current game's framework is incomplete."""
    notes: list[str] = []
    gone: set[str] = set()
    for g in library.games:
        missing = missing_file_in_framework(g.framework, g.title_id)
        if missing is None:
            continue
        if g.title_id == title_id:
            return [], t_func('shell.frameworkIncomplete', name, missing)
        label = g.name or g.title_id
        note = t_func('shell.gameLeftOut', label, missing)
        log(f'library: {note} ({g.framework})\n')
        notes.append(note)
        gone.add(g.title_id)
        if Path(g.framework) == mirrored_framework(root, g.title_id):
            discard(g.framework)
    if gone:
        library.games = [g for g in library.games if g.title_id not in gone]
    return notes, None


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
) -> tuple[bool, str, str, list[str]]:
    """Mirror `framework` into `root`, update `shell.json`, and pack `<root>/export/NX2Apple.ipa`.

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
    sweep_discarded(frameworks_mirror(root_p))
    library = ShellLibrary.load(root_p)
    library.add(ShellGame(title_id=tid_norm, name=name, framework=str(fw_p)))
    mirror_frameworks(library, root_p, log=log)
    library.drop_missing()
    notes, err = leave_out_incomplete(library, root_p, tid_norm, name, _t, log=log)
    if err is not None:
        return False, '', _t('shell.projectFailed', err), []

    for g in library.games:
        picked = picked_artwork if g.title_id == tid_norm else None
        banner = place_banner(g.title_id, g.framework, banners_dir=banners_dir, picked=picked)
        if banner:
            log(f'banner: {g.title_id} {banner}\n')

    try:
        library.save(root_p)
    except OSError as e:
        return False, '', _t('shell.projectFailed', str(e)), []

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
        pack_py = repo_p / 'dm' / 'ios' / 'tools' / 'pack_ipa.py'
        maps: list[str] = []
        executables = [f'Payload/{APP_NAME}/{SCHEME}']
        for g in library.games:
            fw_path = Path(g.framework)
            fw_name = fw_path.name
            fw_exe = fw_path.stem
            maps.append(f'Payload/{APP_NAME}/Frameworks/{fw_name}={fw_path}')
            executables.append(f'Payload/{APP_NAME}/Frameworks/{fw_name}/{fw_exe}')
        maps.append(f'Payload/{APP_NAME}={staged_app}')

        cmd = [py_exe, str(pack_py), str(tmp_ipa), '--no-reuse'] + maps
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
