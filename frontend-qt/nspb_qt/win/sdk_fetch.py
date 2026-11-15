"""Get an iPhoneOS SDK onto a Windows PC.

Two routes, both ending in a folder that `toolchain.is_sdk_dir` accepts:

* **clone** (default): `xybp888/iOS-SDKs` is a plain git repository holding complete SDK trees
  as loose files, so a shallow, `--filter=blob:none` sparse checkout of one version is a few
  hundred MB instead of the 40 GB of an Xcode.xip. No Apple ID needed.
* **xip**: Apple's own `Xcode_<ver>.xip`, which is the only licensed source for redistribution
  purposes. A xip is a xar archive whose `Content` member is a pbzx stream of a cpio archive; we
  stream it and write only `Platforms/iPhoneOS.platform/Developer/SDKs/`, which is about 2 GB of
  the 40 GB app. The logic follows the reference implementation, including Xcode 27's
  sorted-cpio hard-link canaries.

Both routes verify what they wrote (`toolchain.is_sdk_dir` plus a metadata digest) before the
folder becomes visible to `toolchain.ios_sdk()`.
"""
from __future__ import annotations

import concurrent.futures as cf
import lzma
import os
import re
import shutil
import struct
import subprocess
import tempfile
import time
import zlib
from pathlib import Path
from typing import Callable, Iterator

from . import archive_guard as ag
from . import toolchain as tc

XIP_WANT = '/Platforms/iPhoneOS.platform/Developer/SDKs/'
MAX_ZIP_MEMBERS = 65_536
MAX_ZIP_BYTES = 2 * 1024 * 1024 * 1024  # 2 GiB ceiling for unpacked SDK archives
_VALID_SDK_VER_RE = re.compile(r'^\d+(?:\.\d+)*$')
_VALID_SDK_DIR_RE = re.compile(r'^iPhoneOS\d+(?:\.\d+)*\.sdk$')


class SdkError(Exception):
    """A user-facing failure: the message says what to do next, not just what broke."""


def _clean_archive_relpath(raw: str) -> str | None:
    return ag.clean_archive_relpath(raw)


def _is_within(child: Path, root: Path) -> bool:
    return ag.is_within(child, root)


def _is_same_or_within(child: Path, root: Path) -> bool:
    return ag.is_same_or_within(child, root)


def _win_path(p: Path | str) -> str:
    return ag.win_path(p)


def rmtree(path: Path) -> None:
    ag.rmtree_force(path)


# ---------------------------------------------------------------- git route

def repair_tbd_stubs(sdk: Path, log: Callable[[str], None] | None = None, **kwargs) -> int:
    """The toolchain's repair, re-exported for the clone route: fix `.tbd` text stubs in place."""
    return tc.repair_tbd_stubs(sdk, log=log, **kwargs)




def materialize_symlinks(repo: Path, sub: str, log: Callable[[str], None]) -> int:
    """Copy the targets of the SDK's git symlinks over their checked-out text stubs.

    The repository stores the SDK's internal aliases as git symlinks (`usr/lib/libSystem.tbd` →
    `libSystem.B.tbd`; about 300 `.tbd` files). macOS and Linux check those out as symlinks;
    Windows checks each one out as a small text file holding the target's path (real symlinks
    need Developer Mode). `ld64.lld` then opens `libSystem.tbd`, finds no `--- !tapi-tbd` in it,
    and refuses: "libSystem.tbd: unhandled file type", which fails the link probe four ways and
    no build starts. Copying each target over its stub makes the SDK link; the files are small.

    `repo` is the clone (its `.git` still exists at this point), `sub` the SDK folder inside it
    ("" = the whole repo). Returns how many stubs were replaced. Real symlinks are left alone.
    """
    args = ['ls-files', '-s', '-z']
    if sub:
        args += ['--', sub]
    git = str(tc.git_exe() or shutil.which('git') or 'git')
    try:
        r = subprocess.run([git, '-C', str(repo), *args], capture_output=True, **tc.no_window())
    except OSError:
        return 0
    if r.returncode:
        return 0
    symlinks: list[Path] = []
    for entry in r.stdout.split(b'\x00'):
        if not entry:
            continue
        meta, _, rel = entry.partition(b'\t')
        if meta.split(b' ')[0] != b'120000':
            continue
        symlinks.append(repo / os.fsdecode(rel))
    pending = set(symlinks)
    fixed = 0
    for _pass in range(4):
        round_fixed = 0
        for p in list(symlinks):
            if p not in pending:
                continue
            wp = Path(_win_path(p))
            if not wp.is_file() or wp.is_symlink():
                pending.discard(p)
                continue
            try:
                target = wp.read_text(encoding='utf-8', errors='replace').strip()
            except OSError:
                pending.discard(p)
                continue
            if not target or ':' in target or target.startswith(('/', '\\')):
                pending.discard(p)
                continue
            cand = p.parent / target.replace('\\', '/')
            if not _is_within(cand, repo):
                pending.discard(p)
                continue
            if cand in pending:
                continue  # target is itself a symlink stub; resolve it first
            wreal = Path(_win_path(cand.resolve()))
            try:
                if wreal.is_dir():
                    p_real = p.resolve()
                    cand_real = cand.resolve()
                    if (
                        p_real == cand_real
                        or p_real.is_relative_to(cand_real)
                        or cand_real.is_relative_to(p_real)
                    ):
                        pending.discard(p)
                        continue
                    wp.unlink()
                    shutil.copytree(str(wreal), str(wp), dirs_exist_ok=True)
                    pending.discard(p)
                    round_fixed += 1
                    fixed += 1
                elif wreal.is_file():
                    wp.write_bytes(wreal.read_bytes())
                    pending.discard(p)
                    round_fixed += 1
                    fixed += 1
            except (OSError, shutil.Error) as e:
                log(f'    {p.relative_to(repo).as_posix()}: copy warning ({e}), skipped')
                pending.discard(p)
        if not round_fixed:
            break
    for p in sorted(pending):
        wp = Path(_win_path(p))
        if wp.is_file() and not wp.is_symlink():
            try:
                target = wp.read_text(encoding='utf-8', errors='replace').strip()
            except OSError:
                target = ''
            log(f'    {p.relative_to(repo).as_posix()}: its target {target!r} is missing, left as it is')
    if fixed:
        log(f'    materialized {fixed} symlink stubs into real files (Windows checkout of git symlinks)')
    return fixed



def clone_sdk(version: str = tc.SDK_PINNED, dest: Path | None = None,
              log: Callable[[str], None] | None = None) -> Path:
    """Sparse-clone one SDK out of `xybp888/iOS-SDKs` and return the folder.

    A full clone of that repository is ~600 MB of git objects plus tens of GB of checked-out
    trees; `--filter=blob:none --sparse` fetches no file contents up front, then a `sparse-checkout
    set` pulls only the requested SDK. That is what makes this practical on a normal connection.
    """
    log = log or (lambda s: None)
    # toolchain.git_exe() first: the app may have downloaded its own PortableGit, which is not on
    # PATH. `shutil.which` alone missed it, so the SDK step failed right after a successful git
    # install (the same "installed but invisible" bug as llvm_dir had).
    found = tc.git_exe() or shutil.which('git')
    git = str(found) if found else None
    if not git:
        raise SdkError('git is not installed: get it from https://git-scm.com/download/win, or '
                       'download an Xcode .xip and use the xip route instead')
    dest = Path(dest or tc.sdk_cache_dir())
    dest.mkdir(parents=True, exist_ok=True)
    target = dest / version
    if tc.is_sdk_dir(target):
        # The cached SDK may predate the symlink materialization: repair it in place, then the
        # probe links on the next run instead of failing on a 15-byte text file forever.
        repair_tbd_stubs(target, log=log)
        log(f'SDK already present: {target}')
        return target
    # Clean up any legacy `.clone-<version>` folder from an earlier interrupted run, then use a
    # short `.tmp` directory name to keep deep SDK paths well under MAX_PATH.
    rmtree(dest / f'.clone-{version}')
    work = dest / '.tmp'
    rmtree(work)

    def run(args: list[str], what: str, repo: str = tc.SDK_REPO) -> None:
        log(f'$ git {" ".join(args)}')
        try:
            # encoding='utf-8': git always writes UTF-8, while a Chinese Windows console decodes
            # with GBK, which turned `C:\Users\QC-北\…` into `C:\Users\QC-鍖梊…` in the log — and
            # a bug report full of mojibake is a bug report nobody can act on.
            p = subprocess.Popen([git] + args, cwd=str(dest), stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, text=True, errors='replace',
                                 encoding='utf-8', bufsize=1, **tc.no_window())
        except OSError as e:
            raise SdkError(f'cannot start git: {e}') from e
        assert p.stdout is not None
        for line in p.stdout:
            s = line.rstrip()
            if s:
                log(s)
        p.wait()
        if p.returncode:
            raise SdkError(f'git {what} failed (exit {p.returncode}); check the network and retry')

    # The clone goes through the same mirror list as the file downloads: the repository is on
    # GitHub, and a mainland connection that took 974 s for a 182 MB release asset is not going to
    # enjoy a shallow clone either. The mirrors are git-protocol proxies, so the SHA of the
    # checkout is unchanged — and the SDK is verified by its own layout afterwards.
    # -c core.longpaths=true: the SDK trees carry paths past Windows' 260-character MAX_PATH
    # (a swiftinterface inside System/Cryptexes/… tops it), and without this the sparse checkout
    # dies with "Filename too long" — the report's third attempt at the SDK. The config is
    # clone-scoped, so the user's own git is untouched.
    clone_args = ['-c', 'core.longpaths=true', 'clone', '--filter=blob:none', '--sparse',
                  '--depth', '1']
    last: Exception | None = None
    for i, repo in enumerate(tc.mirror_urls(tc.SDK_REPO)):
        if i:
            log(f'retrying through a mirror: {repo}')
        # Every attempt starts from nothing. This has to be a real removal: git marks its pack
        # files read-only, and `shutil.rmtree(ignore_errors=True)` silently leaves those behind on
        # Windows. The next clone then dies with "destination path already exists and is not an
        # empty directory" on all three sources, which is what the report showed — the retries
        # were never given a chance.
        rmtree(work)
        try:
            run(clone_args + [repo, str(work)], 'clone', repo)
            # narrow the working tree to the one SDK inside the mirror loop: `--filter=blob:none`
            # defers all blob downloads to `sparse-checkout set`, so a connection that passes the
            # tiny initial clone and drops during the multi-hundred-MB blob fetch must retry on
            # the next mirror rather than aborting the whole install.
            try:
                subprocess.run([git, '-c', 'core.longpaths=true', 'sparse-checkout', 'set', version],
                               cwd=str(work), check=True, capture_output=True, text=True,
                               encoding='utf-8', errors='replace', **tc.no_window())
            except subprocess.CalledProcessError as e:
                raise SdkError(f'git sparse-checkout failed: {(e.stderr or "").strip()[-400:]}') from e
            last = None
            break
        except SdkError as e:
            last = e
    if last is not None:
        rmtree(work)
        raise last
    src = work / version
    try:
        if not tc.is_sdk_dir(src):
            raise SdkError(f'{tc.SDK_REPO} has no usable {version}: pick another version, or use a .xip')
        # The .git folder is deleted with `work` after the move, so this has to happen here, while
        # the index can still tell symlinks from the text files a Windows checkout left behind.
        materialize_symlinks(work, version, log=log)
        repair_tbd_stubs(src, log=log, error_cls=SdkError)
        ag.install_staged_tree(src, target, validator=tc.is_sdk_dir, error_cls=SdkError)
    finally:
        rmtree(work)
    log(f'SDK ready: {target} ({tc.sdk_version(target)[0]})')
    return target


def install_sdk_from_zip(zip_path: Path, dest: Path | None = None,
                         log: Callable[[str], None] | None = None,
                         unpack_progress: Callable[[int, int], None] | None = None) -> Path:
    """Unpack an `iPhoneOS*.sdk.zip` archive (from `xybp888/iOS-SDKs` releases or user-supplied),
    materialize Unix symlinks and `.tbd` text stubs, and return the SDK directory in `dest`.
    """
    import zipfile
    log = log or (lambda s: None)
    src_zip = Path(zip_path)
    if not src_zip.is_file():
        raise SdkError(f'no such file: {src_zip}')
    dest = Path(dest or tc.sdk_cache_dir())
    dest.mkdir(parents=True, exist_ok=True)
    rmtree(dest / '.u')
    for stale in dest.glob('.s-*'):
        rmtree(stale)
    staging = Path(tempfile.mkdtemp(prefix='.s-', dir=str(dest)))
    log(f'unpacking {src_zip.name} → {dest}')
    try:
        quota = ag.ArchiveQuota(max_entries=MAX_ZIP_MEMBERS, max_bytes=MAX_ZIP_BYTES)
        try:
            ag.extract_zip_safely(
                src_zip,
                staging,
                quota=quota,
                unpack_progress=unpack_progress,
                log=log,
                error_cls=SdkError,
            )
        except zipfile.BadZipFile as e:
            raise SdkError(f'{src_zip.name} is not a valid zip archive ({e})') from e
        except OSError as e:
            raise SdkError(f'failed to unpack {src_zip.name}: {e}') from e

        sdk_src = tc.resolve_sdk_dir(staging)
        if sdk_src is None or not _is_same_or_within(sdk_src, staging):
            raise SdkError(
                f'{src_zip.name} does not contain a valid iPhoneOS SDK '
                '(needs SDKSettings.json and System/Library/Frameworks/UIKit.framework)'
            )
        repair_tbd_stubs(
            sdk_src,
            log=log,
            quota=quota,
            error_cls=SdkError,
        )
        ver, _ = tc.sdk_version(sdk_src)
        if ver and not _VALID_SDK_VER_RE.match(ver):
            raise SdkError(f'invalid SDK version in SDKSettings.json: {ver!r}')
        if _VALID_SDK_DIR_RE.match(sdk_src.name) and (not ver or sdk_src.name == f'iPhoneOS{ver}.sdk'):
            folder_name = sdk_src.name
        elif ver:
            folder_name = f'iPhoneOS{ver}.sdk'
        else:
            folder_name = tc.SDK_PINNED
        if not _VALID_SDK_DIR_RE.match(folder_name):
            raise SdkError(f'invalid SDK directory name: {folder_name!r}')
        dest_real = Path(os.path.abspath(os.fspath(dest))).resolve()
        target = dest / folder_name
        target_real = Path(os.path.abspath(os.fspath(target))).resolve()
        if target_real.parent != dest_real:
            raise SdkError(f'target SDK path escapes destination directory: {target}')

        ag.install_staged_tree(
            sdk_src,
            target,
            validator=tc.is_sdk_dir,
            error_cls=SdkError,
        )
        log(f'SDK ready: {target} ({tc.sdk_version(target)[0]})')
        return target
    finally:
        rmtree(staging)


def install_sdk(version: str = tc.SDK_PINNED, dest: Path | None = None,
                log: Callable[[str], None] | None = None,
                progress: Callable[[int, int], None] | None = None,
                unpack_progress: Callable[[int, int], None] | None = None,
                fallback_git: bool = True) -> Path:
    """Download and install the pinned iPhoneOS SDK via the release `.zip` (using GitHub mirrors
    and speed ranking, no git required), falling back to `clone_sdk` if needed."""
    log = log or (lambda s: None)
    dest = Path(dest or tc.sdk_cache_dir())
    dest.mkdir(parents=True, exist_ok=True)
    target = dest / version
    if tc.is_sdk_dir(target):
        repair_tbd_stubs(target, log=log)
        log(f'SDK already present: {target}')
        return target
    if version == tc.SDK_PINNED and tc.SDK_ASSET.get('url'):
        from . import fetch as wf
        asset = tc.SDK_ASSET
        cache = tc.tools_dir() / 'downloads'
        try:
            zpath = wf.download(
                asset['url'],
                cache / asset['name'],
                asset['sha256'],
                asset.get('size'),
                log=log,
                progress=progress,
            )
            return install_sdk_from_zip(zpath, dest=dest, log=log, unpack_progress=unpack_progress)
        except (wf.DownloadError, SdkError) as e:
            if not fallback_git:
                raise
            log(f'release archive download did not succeed ({e}); trying git sparse-checkout fallback…')
            if not (tc.git_exe() or shutil.which('git')):
                try:
                    wf.install_git(log=log, progress=progress)
                except wf.DownloadError:
                    raise SdkError(str(e)) from e
    return clone_sdk(version=version, dest=dest, log=log)


def available_versions(log: Callable[[str], None] | None = None) -> list[str]:
    """The SDK versions the repository currently offers (needs network; best effort)."""
    found = tc.git_exe() or shutil.which('git')
    git = str(found) if found else None
    if not git:
        return []
    try:
        r = subprocess.run([git, 'ls-remote', '--heads', tc.SDK_REPO], capture_output=True,
                           text=True, timeout=120, **tc.no_window())
    except (OSError, subprocess.SubprocessError):
        return []
    return [] if r.returncode else list(tc.SDK_ACCEPTED)


def import_local(src: Path, dest: Path | None = None,
                 log: Callable[[str], None] | None = None) -> Path:
    """Take an SDK folder the user already has (copied from a Mac, or unpacked elsewhere).

    `src` may be the `.sdk` itself or a folder containing one; nothing is copied when `src` is
    already inside the cache, so a user who keeps the SDK on a big drive can leave it there.
    """
    log = log or (lambda s: None)
    src = Path(src)
    cand = src
    if not tc.is_sdk_dir(cand):
        inner = sorted((p for p in src.glob('iPhoneOS*.sdk') if p.is_dir()), reverse=True) if src.is_dir() else []
        if not inner:
            raise SdkError(f'{src} is not an iPhoneOS SDK (needs SDKSettings.json and '
                           'System/Library/Frameworks/UIKit.framework)')
        cand = inner[0]
    dest = Path(dest or tc.sdk_cache_dir())
    dest.mkdir(parents=True, exist_ok=True)
    ver, _ = tc.sdk_version(cand)
    if ver and not _VALID_SDK_VER_RE.match(ver):
        raise SdkError(f'invalid SDK version in SDKSettings.json: {ver!r}')
    folder_name = cand.name if _VALID_SDK_DIR_RE.match(cand.name) else (f'iPhoneOS{ver}.sdk' if ver else tc.SDK_PINNED)
    if not _VALID_SDK_DIR_RE.match(folder_name):
        raise SdkError(f'invalid SDK directory name: {folder_name!r}')
    target = dest / folder_name
    if cand.resolve() == target.resolve():
        log(f'SDK is already in place: {target}')
        return target
    log(f'copying {cand} → {target} (several GB, a few minutes)')
    for stale in dest.glob('.imp-*'):
        rmtree(stale)
    staging = Path(tempfile.mkdtemp(prefix='.imp-', dir=str(dest)))
    staged_sdk = staging / folder_name
    try:
        try:
            shutil.copytree(_win_path(cand), _win_path(staged_sdk), symlinks=False, dirs_exist_ok=True)
        except (OSError, shutil.Error) as e:
            raise SdkError(f'failed to copy SDK from {cand}: {e}') from e
        repair_tbd_stubs(staged_sdk, log=log, error_cls=SdkError)
        ag.install_staged_tree(
            staged_sdk,
            target,
            validator=tc.is_sdk_dir,
            error_cls=SdkError,
        )
    finally:
        rmtree(staging)
    log(f'SDK ready: {target} ({tc.sdk_version(target)[0]})')
    return target


# ---------------------------------------------------------------- xip route

def extract_xip(xip: Path, out: Path | None = None,
                log: Callable[[str], None] | None = None) -> Path:
    """Write the iPhoneOS SDK out of an `Xcode_<ver>.xip` and return its folder.

    Called from a thread by the app, so progress goes through `log` rather than print().
    """
    log = log or (lambda s: None)
    xip = Path(xip)
    if not xip.is_file():
        raise SdkError(f'no such file: {xip}')
    out = Path(out or tc.sdk_cache_dir())
    out.mkdir(parents=True, exist_ok=True)
    produced: Path | None = None
    t0 = time.time()
    try:
        with open(xip, 'rb') as f:
            start, length, enc = _xar_content(f)
            log(f'xip: Content {length / 2**30:.1f} GiB ({enc or "raw"}); writing to {out}')
            need, have = _scan(f, start, length)
            lost = sum(len(v) for k, v in need.items() if k not in have)
            links = sum(len(v) for v in need.values())
            log(f'  pass 1: {links} SDK files are hard links whose bytes another entry carries'
                + (f' ({lost} with no carrier)' if lost else ''))
            produced = _extract(f, start, length, out, need, log)
        bad = _remaining_canaries(out)
        if bad:
            raise SdkError(f'{len(bad)} SDK files still hold a canary placeholder, e.g. {bad[0]}: '
                           'the .xip may be a different format version; try the git route')
    except (struct.error, lzma.LZMAError, EOFError) as e:
        raise SdkError(f'{xip.name} could not be unpacked ({e}); is it a complete download?') from e
    finally:
        pass
    # the folder name decides which version toolchain.ios_sdk picks
    final = _settle_sdk_dir(out, produced, log)
    log(f'done in {time.time() - t0:.0f} s: {final} ({tc.sdk_version(final)[0]})')
    return final


def _settle_sdk_dir(out: Path, produced: Path | None, log: Callable[[str], None]) -> Path:
    """Make sure a `iPhoneOS*.sdk` sits directly in the cache with the right name."""
    if produced and produced.is_dir():
        ver, _ = tc.sdk_version(produced)
        if ver and not _VALID_SDK_VER_RE.match(ver):
            raise SdkError(f'invalid SDK version in SDKSettings.json: {ver!r}')
        want = out / f'iPhoneOS{ver}.sdk' if ver else produced
        if produced != want:
            ag.install_staged_tree(
                produced,
                want,
                validator=tc.is_sdk_dir,
                error_cls=SdkError,
            )
        return want
    for p in sorted((x for x in out.glob('iPhoneOS*.sdk') if x.is_dir()), reverse=True):
        if tc.is_sdk_dir(p):
            return p
    raise SdkError(f'the .xip held no iPhoneOS SDK under {out}')


def _xar_content(f) -> tuple[int, int, str]:
    hdr = f.read(28)
    if hdr[:4] != b'xar!':
        raise SdkError('not a xar / .xip archive (the file may be an HTML error page)')
    hsize, _ver, toc_c, _toc_u = struct.unpack('>HHQQ', hdr[4:24])
    f.seek(hsize)
    toc = zlib.decompress(f.read(toc_c))
    heap = hsize + toc_c
    import xml.etree.ElementTree as ET
    for fe in ET.fromstring(toc).iter('file'):
        if (fe.findtext('name') or '') == 'Content':
            d = fe.find('data')
            if d is None:
                continue
            enc_node = d.find('encoding')
            enc = enc_node.get('style') if enc_node is not None else ''
            return heap + int(d.findtext('offset')), int(d.findtext('length')), enc
    raise SdkError('the .xip has no Content member')


def _pbzx_chunks(f, start: int, length: int) -> Iterator[bytes]:
    f.seek(start)
    end = start + length
    if f.read(4) != b'pbzx':
        raise SdkError('the .xip Content member is not a pbzx stream')
    f.read(8)
    while f.tell() < end:
        h = f.read(16)
        if len(h) < 16:
            break
        _flags, size = struct.unpack('>QQ', h)
        yield f.read(size)


def _unpack(chunk: bytes) -> bytes:
    return lzma.decompress(chunk, format=lzma.FORMAT_XZ) if chunk[:6] == b'\xfd7zXZ\x00' else chunk


def _stream(f, start: int, length: int, workers: int) -> Iterator[bytes]:
    with cf.ThreadPoolExecutor(workers) as ex:
        pend = []
        for ch in _pbzx_chunks(f, start, length):
            pend.append(ex.submit(_unpack, ch))
            if len(pend) >= workers * 2:
                yield pend.pop(0).result()
        for p in pend:
            yield p.result()


class _Reader:
    """Sequential reader over the decoded chunks (cpio is read front to back twice)."""

    def __init__(self, it):
        self.it, self.buf, self.pos, self.total = it, bytearray(), 0, 0

    def read(self, n: int) -> bytes:
        while len(self.buf) - self.pos < n:
            try:
                c = next(self.it)
            except StopIteration:
                break
            if self.pos:
                del self.buf[:self.pos]
                self.pos = 0
            self.buf += c
        out = bytes(self.buf[self.pos:self.pos + n])
        self.pos += len(out)
        self.total += len(out)
        return out

    def skip(self, n: int) -> None:
        while n > 0:
            k = len(self.buf) - self.pos
            if k == 0:
                try:
                    c = next(self.it)
                except StopIteration:
                    return
                self.buf = bytearray(c)
                self.pos = 0
                continue
            s = min(k, n)
            self.pos += s
            self.total += s
            n -= s


def _entries(r: _Reader) -> Iterator[tuple[str, int, int, int, int]]:
    """(name, mode, inode, size, padding) per cpio entry; the caller consumes the data."""
    while True:
        magic = r.read(6)
        if not magic:
            return
        if magic == b'070707':          # odc
            h = r.read(70)
            if len(h) < 70:
                return
            ino, mode = int(h[6:12], 8), int(h[12:18], 8)
            namesize, size = int(h[53:59], 8), int(h[59:70], 8)
            name = r.read(namesize)[:-1].decode('utf-8', 'surrogateescape')
            pad = 0
        elif magic in (b'070701', b'070702'):   # newc
            h = r.read(104)
            if len(h) < 104:
                return
            fld = [int(h[i:i + 8], 16) for i in range(0, 104, 8)]
            ino, mode, size, namesize = fld[0], fld[1], fld[6], fld[11]
            name = r.read(namesize)[:-1].decode('utf-8', 'surrogateescape')
            r.skip((-(110 + namesize)) % 4)
            pad = (-size) % 4
        else:
            raise SdkError(f'unknown cpio header {magic!r} at byte {r.total}')
        if name == 'TRAILER!!!':
            return
        yield name, mode, ino, size, pad


CANARY = b'NULLcanary'


def _is_canary(head: bytes, size: int) -> bool:
    return size >= len(CANARY) and head.startswith(CANARY) and not head[len(CANARY):].strip(b'\0')


def _scan(f, start: int, length: int) -> tuple[dict, set]:
    """Pass 1: which inodes carry real bytes, and which SDK paths are hard links to them.

    Xcode 27 stores a sorted, deduplicated cpio: for one hard-linked inode exactly one entry
    holds the data and the others hold a same-sized `NULLcanary` placeholder. Without this pass
    the placeholder would end up on disk as if it were a header.
    """
    need: dict[tuple[int, int], list[str]] = {}
    have: set[tuple[int, int]] = set()
    r = _Reader(_stream(f, start, length, os.cpu_count() or 4))
    for name, mode, ino, size, pad in _entries(r):
        if mode & 0o170000 == 0o100000 and size:
            head = r.read(min(size, 64))
            r.skip(size - len(head))
            i = name.find(XIP_WANT)
            if _is_canary(head, size):
                if i >= 0:
                    need.setdefault((ino, size), []).append(name[i + len(XIP_WANT):])
            else:
                have.add((ino, size))
        else:
            r.skip(size)
        r.skip(pad)
    return need, have


def _extract(f, start: int, length: int, out: Path, need: dict,
             log: Callable[[str], None]) -> Path | None:
    """Pass 2: write the SDK, following hard links and collecting symlinks for later."""
    r = _Reader(_stream(f, start, length, os.cpu_count() or 4))
    links: list[tuple[str, str]] = []
    seen_inodes: set[tuple[int, int]] = set()
    n = 0
    last = time.time()
    sdk_roots: set[str] = set()
    for name, mode, ino, size, pad in _entries(r):
        i = name.find(XIP_WANT)
        rel = name[i + len(XIP_WANT):] if i >= 0 else None
        kind, key = mode & 0o170000, (ino, size)
        if rel and kind == 0o120000:                 # symlink: the target is the data
            links.append((rel, r.read(size).decode('utf-8', 'surrogateescape')))
        elif kind == 0o100000:
            head = r.read(min(size, 64))
            canary = _is_canary(head, size)
            dsts = [out / rel] if rel and not canary else []
            if not canary and key in need and key not in seen_inodes:
                dsts += [out / p for p in need[key]]
                seen_inodes.add(key)
            if dsts:
                for d in dsts:
                    d.parent.mkdir(parents=True, exist_ok=True)
                    if rel:
                        sdk_roots.add(rel.split('/')[0])
                for d in dsts:
                    d.write_bytes(head)
                if size > len(head):
                    fs = [open(d, 'ab') for d in dsts]
                    try:
                        left = size - len(head)
                        while left:
                            b = r.read(min(left, 1 << 22))
                            if not b:
                                raise SdkError('the cpio stream ended inside a file')
                            for o in fs:
                                o.write(b)
                            left -= len(b)
                    finally:
                        for o in fs:
                            o.close()
                n += len(dsts)
            else:
                r.skip(size - len(head))
        else:
            if rel and kind == 0o040000:
                (out / rel).mkdir(parents=True, exist_ok=True)
                sdk_roots.add(rel.split('/')[0])
            r.skip(size)
        r.skip(pad)
        if time.time() - last > 10:
            last = time.time()
            log(f'  {r.total / 2**30:.1f} GiB read, {n} SDK files')
    _materialize(out, links, log)
    if not sdk_roots:
        return None
    # the SDK folder is written under its own directory (iPhoneOS.sdk or iPhoneOS<ver>.sdk)
    for root in sorted(sdk_roots):
        p = out / root
        if p.is_dir() and root.endswith('.sdk') and tc.is_sdk_dir(p):
            return p
    for p in sorted((x for x in out.glob('iPhoneOS*.sdk') if x.is_dir()), reverse=True):
        if tc.is_sdk_dir(p):
            return p
    return None


def _materialize(
    out: Path,
    links: list[tuple[str, str]],
    log: Callable[[str], None],
    *,
    strict: bool = False,
    max_bytes: int | None = None,
    bytes_used: int = 0,
    max_entries: int | None = None,
    entries_used: int = 0,
) -> tuple[int, int]:
    quota = ag.ArchiveQuota(
        max_entries=max_entries if max_entries is not None else 10**12,
        max_bytes=max_bytes if max_bytes is not None else 10**18,
        entries_used=entries_used,
        bytes_used=bytes_used,
    )
    ag.materialize_unix_symlinks(
        out,
        links,
        quota=quota,
        log=log,
        strict=strict,
        error_cls=SdkError,
    )
    return quota.entries_used, quota.bytes_used


def _remaining_canaries(out: Path) -> list[Path]:
    """Files that are still a placeholder: a sign the cpio layout was not understood."""
    bad = []
    for p in out.rglob('*'):
        try:
            if not p.is_file() or p.stat().st_size < len(CANARY):
                continue
            with open(p, 'rb') as f:
                head = f.read(64)
        except OSError:
            continue
        if _is_canary(head, p.stat().st_size):
            bad.append(p)
            if len(bad) > 8:
                break
    return bad


def describe_sdk(sdk: Path) -> str:
    ver, build = tc.sdk_version(sdk)
    return f'{sdk.name} {ver} {build}'.strip()
