"""The upstream sync's patchers against the files of a real upstream ref (issue #92).

scripts/sync_upstream.py re-applies the fork's changes to upstream's files with anchored patchers. Each
patcher is written against the text of upstream at one moment, so upstream moving on can break it in two
ways, and both went unnoticed until a person ran every patcher by hand against seedds/nxnative main:
  - an anchor no longer matches (ce99604a changed `clang -O1 ...` to `$(CLANG) -O1 ...`): the sync stops;
  - a marker is satisfied by upstream's own text (`list-runtimes`): the patcher says "already patched"
    on upstream's file and the fork's change silently disappears.
This test runs every patcher on the file of an upstream ref, in a temporary directory, and fails on
either, on a patcher that is not idempotent, and on a patched Python or shell file that does not parse.

The ref is $SYNC_PATCHERS_REF, else seedds/main (the remote the fork syncs from; CI adds it, see
.github/workflows/tests.yml). The tests are skipped when the ref is not in the repository. The base checks
read the fork's last sync base from .upstream-ref.
"""
import ast
import contextlib
import io
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / 'scripts'))
import sync_upstream as su   # noqa: E402


def rev_ok(ref):
    return subprocess.run(['git', 'rev-parse', '--verify', '--quiet', ref + '^{commit}'], cwd=REPO, capture_output=True).returncode == 0


def show(ref, path):
    r = subprocess.run(['git', 'show', f'{ref}:{path}'], cwd=REPO, capture_output=True)
    return r.stdout.decode('utf-8', errors='replace') if r.returncode == 0 else None


def last_base():
    f = REPO / '.upstream-ref'
    base = f.read_text().strip() if f.exists() else ''
    return base if base and rev_ok(base) else None


def quiet(fn, *a):
    """Run a patcher with its progress lines swallowed; a patcher that cannot fit raises SyncProblem."""
    buf = io.StringIO()
    n = len(su.problems)
    try:
        with contextlib.redirect_stdout(buf):
            return fn(*a)
    finally:
        del su.problems[n:]


class PatchersOnUpstream(unittest.TestCase):
    ref = os.environ.get('SYNC_PATCHERS_REF', 'seedds/main')

    @classmethod
    def setUpClass(cls):
        if not rev_ok(cls.ref):
            raise unittest.SkipTest(f'{cls.ref} is not in this repository (git fetch seedds, or set SYNC_PATCHERS_REF)')

    def test_every_patcher_applies_to_upstreams_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            for path, patcher in su.PATCHERS.items():
                with self.subTest(path=path):
                    text = show(self.ref, path)
                    self.assertIsNotNone(text, f'{path} is not in {self.ref}: upstream moved or deleted a carrier')
                    f = Path(tmp) / path
                    f.parent.mkdir(parents=True, exist_ok=True)
                    f.write_text(text, encoding='utf-8')
                    try:
                        out = quiet(patcher, f.read_text(encoding='utf-8'))
                    except su.SyncProblem as e:
                        self.fail(f'the patcher no longer fits {self.ref}: {e}')
                    if out is None: out = text
                    self.assertNotEqual(out, text, f"{path}: the patcher changed nothing on upstream's own file (a marker that "
                                                   f"upstream's text satisfies, or a patch upstream has made itself): the fork's change would be dropped silently")
                    marks = su.MARKERS[path] if isinstance(su.MARKERS[path], tuple) else (su.MARKERS[path],)
                    self.assertTrue(any(m in out for m in marks), f'{path}: the marker is missing from the patched file')
                    f.write_text(out, encoding='utf-8')
                    again = quiet(patcher, out)
                    self.assertEqual(again if again is not None else out, out, f'{path}: applying the patcher twice changes the file')
                    if path.endswith('.py'):
                        ast.parse(out)
                    if path.endswith('.sh'):
                        r = subprocess.run(['bash', '-n', str(f)], capture_output=True, text=True)
                        self.assertEqual(r.returncode, 0, r.stderr)

    def test_the_runtime_profile_leaves_no_compiled_constant_behind(self):
        for path in su.PROFILE_PATHS:
            with self.subTest(path=path):
                out = quiet(su.PATCHERS[path], show(self.ref, path))
                left = sorted({m.group(2) for m in su._PROFILE_TOKEN.finditer(out) if m.group(2)})   # outside strings and comments
                self.assertEqual(left, [], f'{path} still reads {left} at compile time')

    def test_the_patched_makefile_uses_one_compiler_spelling(self):
        original = show(self.ref, su.TESTS_MK)
        out = quiet(su.PATCHERS[su.TESTS_MK], original)
        spelling = '$(CLANG)' if '$(CLANG)' in original else 'clang'
        # a line the patcher only appended to keeps the spelling upstream gave it (upstream's own t_resolution rule says `clang`)
        orig = [l for l in original.splitlines() if l.startswith('\t')]
        added = [l for l in out.splitlines() if l not in original.splitlines() and l.startswith('\t') and 'clang' in l.lower()
                 and not any(l.startswith(o) for o in orig)]
        self.assertTrue(added)
        for l in added:
            self.assertTrue(l.startswith('\t' + spelling + ' '), l)


class PatchersOnTheLastBase(unittest.TestCase):
    """The patchers must also fit the base the fork was last synced from, so the same code runs before and after a sync."""

    def test_the_patchers_fit_the_last_sync_base(self):
        base = last_base()
        if not base: self.skipTest('the last sync base (.upstream-ref) is not in this repository')
        for path, patcher in su.PATCHERS.items():
            with self.subTest(path=path):
                text = show(base, path)
                self.assertIsNotNone(text)
                try:
                    out = quiet(patcher, text)
                except su.SyncProblem as e:
                    self.fail(f'the patcher does not fit the base {base[:7]}: {e}')
                marks = su.MARKERS[path] if isinstance(su.MARKERS[path], tuple) else (su.MARKERS[path],)
                self.assertTrue(any(m in (out if out is not None else text) for m in marks))

    def test_no_fork_edit_is_unprotected(self):
        """A vendored file that differs from the last sync base must be in OURS, PATCHED or DROPPED."""
        base = last_base()
        if not base: self.skipTest('the last sync base (.upstream-ref) is not in this repository')
        edited, _ = su.unprotected_edits(base)
        self.assertEqual(edited, [], "these vendored files differ from the last sync base, and a sync would replace them with upstream's: "
                                     'add a patcher (PATCHERS, MARKERS, PATCHED), or OURS / DROPPED with the reason, in scripts/sync_upstream.py')


class Tables(unittest.TestCase):
    def test_the_carrier_tables_are_consistent(self):
        self.assertEqual(set(su.PATCHED), set(su.PATCHERS))
        self.assertEqual(set(su.PATCHED), set(su.MARKERS))
        self.assertFalse(set(su.OURS) & set(su.PATCHED), 'a file is both fork-owned and re-patched')
        self.assertFalse((set(su.OURS) | set(su.PATCHED)) & set(su.DROPPED), 'a file is both protected and dropped')

    def test_ours_files_exist(self):
        missing = [p for p in su.OURS if not (REPO / p).exists()]
        self.assertEqual(missing, [], 'OURS lists files the fork does not have')

    def test_every_carrier_exists_in_the_fork(self):
        missing = [p for p in su.PATCHED if not (REPO / p).exists()]
        self.assertEqual(missing, [])


if __name__ == '__main__':
    unittest.main()
