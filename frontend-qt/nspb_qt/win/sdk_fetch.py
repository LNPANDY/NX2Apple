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
import shutil
import struct
import subprocess
import time
import zlib
from pathlib import Path
from typing import Callable, Iterator

from . import toolchain as tc

XIP_WANT = '/Platforms/iPhoneOS.platform/Developer/SDKs/'


class SdkError(Exception):
    """A user-facing failure: the message says what to do next, not just what broke."""


def rmtree(path: Path) -> None:
    """Remove a tree, clearing the read-only bits git leaves on Windows.

    `shutil.rmtree` fails on a read-only file and `ignore_errors=True` then leaves the directory
    half-removed. Git marks its pack files read-only, so the stale clone survived every cleanup
    and the next `git clone` refused the non-empty destination. Retried once after chmodding the
    survivors, and only then given up on.
    """
    import stat
    if not path.exists():
        return

    def clear(func, p, _exc):                  # onerror: drop the read-only bit and retry
        try:
            os.chmod(p, stat.S_IWRITE | stat.S_IREAD)
            func(p)
        except OSError:
            pass

    shutil.rmtree(path, onerror=clear)
    if path.exists():                          # a file locked by another process (an indexer)
        shutil.rmtree(path, ignore_errors=True)


# ---------------------------------------------------------------- git route

def repair_tbd_stubs(sdk: Path, log: Callable[[str], None] | None = None) -> int:
    """The toolchain's repair, re-exported for the clone route: fix `.tbd` text stubs in place."""
    return tc.repair_tbd_stubs(sdk, log=log)




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
    try:
        r = subprocess.run(['git', '-C', str(repo), *args], capture_output=True, **tc.no_window())
    except OSError:
        return 0
    if r.returncode:
        return 0
    fixed = 0
    for entry in r.stdout.split(b'\x00'):
        if not entry:
            continue
        meta, _, rel = entry.partition(b'\t')
        if meta.split(b' ')[0] != b'120000':
            continue
        p = repo / os.fsdecode(rel)
        if not p.is_file() or p.is_symlink():
            continue
        target = p.read_text(encoding='utf-8', errors='replace').strip()
        real = (p.parent / target).resolve()
        if not real.is_file():
            log(f'    {rel.decode("utf-8", "replace")}: its target {target!r} is missing, left as it is')
            continue
        p.write_bytes(real.read_bytes())
        fixed += 1
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
    work = dest / f'.clone-{version}'
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
            last = None
            break
        except SdkError as e:
            last = e
    if last is not None:
        rmtree(work)
        raise last
    # narrow the working tree to the one SDK before checking anything out (same long-paths
    # config: -c applies to one command only, so this call carries it too)
    try:
        subprocess.run([git, '-c', 'core.longpaths=true', 'sparse-checkout', 'set', version],
                       cwd=str(work), check=True, capture_output=True, text=True,
                       encoding='utf-8', errors='replace', **tc.no_window())
    except subprocess.CalledProcessError as e:
        raise SdkError(f'git sparse-checkout failed: {(e.stderr or "").strip()[-400:]}') from e
    src = work / version
    if not tc.is_sdk_dir(src):
        raise SdkError(f'{tc.SDK_REPO} has no usable {version}: pick another version, or use a .xip')
    # The .git folder is deleted with `work` after the move, so this has to happen here, while
    # the index can still tell symlinks from the text files a Windows checkout left behind.
    materialize_symlinks(work, version, log=log)
    if target.exists():
        shutil.rmtree(target, ignore_errors=True)
    shutil.move(str(src), str(target))
    shutil.rmtree(work, ignore_errors=True)
    log(f'SDK ready: {target} ({tc.sdk_version(target)[0]})')
    return target


def available_versions(log: Callable[[str], None] | None = None) -> list[str]:
    """The SDK versions the repository currently offers (needs network; best effort)."""
    git = shutil.which('git')
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
    target = dest / cand.name
    if cand.resolve() == target.resolve():
        log(f'SDK is already in place: {target}')
        return target
    dest.mkdir(parents=True, exist_ok=True)
    log(f'copying {cand} → {target} (several GB, a few minutes)')
    shutil.rmtree(target, ignore_errors=True)
    shutil.copytree(cand, target, symlinks=False, dirs_exist_ok=True)
    if not tc.is_sdk_dir(target):
        raise SdkError(f'the copy at {target} is not a usable SDK (the source may be incomplete)')
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
        want = out / f'iPhoneOS{ver}.sdk' if ver else produced
        if produced != want:
            if want.exists():
                shutil.rmtree(want, ignore_errors=True)
            shutil.move(str(produced), str(want))
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


def _materialize(out: Path, links: list[tuple[str, str]], log: Callable[[str], None]) -> None:
    """Write each symlink as a copy of its target (Windows symlinks need extra privileges).

    Links are resolved through other links (`Headers → Versions/Current/Headers`, where
    `Versions/Current` is itself a link), so this loops until nothing new resolves.
    """
    todo = [(rel, t) for rel, t in links if '/' in rel.rstrip('/')]
    while True:
        left = []
        for rel, target in todo:
            dst = out / rel
            src = None if target.startswith('/') else (dst.parent / target)
            if src is None:
                log(f'  link {rel} → {target}: absolute, skipped')
                continue
            if dst.exists():
                continue
            if not src.exists():
                left.append((rel, target))
                continue
            if src.is_dir():
                shutil.copytree(src, dst)
            else:
                dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(src, dst)
        if len(left) == len(todo):
            for rel, target in left:
                log(f'  link {rel} → {target}: target not in the SDK, skipped')
            return
        todo = left


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
