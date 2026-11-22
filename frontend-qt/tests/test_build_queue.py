"""Tests for the general batch build queue (nspb_qt.build_queue, Model & MainWindow integration).

Covers:
1. Multi-game discovery and Title ID grouping (NSP/XCI/NSZ/XCZ + dump folders + NUPs + prod.keys).
2. Enqueueing while a build is active without disrupting the running build.
3. Single-game failure advancing automatically to subsequent games + batch summary.
4. Stop-queue `stopping` window race protection and stale-generation filtering.
5. Restart persistence recovery (`building` -> `queued`, `awaiting_resume=True`, never faking `done`).
6. Reorder (up/down), remove, retry, clear finished, and cancel queued operations.
7. Headless (PySide6-blocked via wrapping all `sys.meta_path` finders) subprocess verification.
8. Real PySide6 MainWindow / BuildQueueCard / QueueSelectGamesDialog / dropEvent integration.
"""
from __future__ import annotations

import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'frontend-qt'))

from nspb_qt import build_queue as bq


def _make_fake_npdm(program_id: int) -> bytes:
    """Create a minimal valid NPDM header matching `inputs.program_id` (META + ACI0)."""
    buf = bytearray(0xA0)
    buf[0:4] = b'META'
    aci0_off = 0x80
    aci0_size = 0x20
    struct.pack_into('<II', buf, 0x70, aci0_off, aci0_size)
    buf[aci0_off:aci0_off + 4] = b'ACI0'
    struct.pack_into('<Q', buf, aci0_off + 0x10, program_id)
    return bytes(buf)


def _make_fake_nup(path: Path, title_id: int, *, version: int = 0) -> None:
    """Create a minimal valid NUP v1 file matching `inputs.read_nup`."""
    toc_off = 0x80
    count = 1
    table_len = 0x30 + count * 0x40
    total_size = toc_off + table_len
    head = bytearray(0x80)
    head[0:3] = b'NUP'
    head[3] = 1
    struct.pack_into('<Q', head, 0x08, toc_off)
    struct.pack_into('<Q', head, 0x10, table_len)
    # Zero TOC SHA means checksum optional (supported by read_nup)
    struct.pack_into('<Q', head, 0x40, total_size)
    struct.pack_into('<I', head, 0x48, count)
    table = bytearray(table_len)
    table[0:4] = b'TOC\x01'
    o = 0x30
    struct.pack_into('<Q', table, o, title_id)
    struct.pack_into('<I', table, o + 20, version)
    table[o + 24] = 0  # base
    path.write_bytes(bytes(head) + bytes(table))


class BuildQueueDiscoveryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix='bq-discover-'))
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def test_discover_groups_multiple_games_updates_dlcs_folders_and_nups(self) -> None:
        root = self.tmp / 'roms'
        root.mkdir()
        # Shared prod.keys
        keys = root / 'prod.keys'
        keys.write_text('header_key = ' + '0' * 64 + '\n', encoding='utf-8')

        # Game A: two base files (largest wins), two updates (newest version wins), two DLCs
        ga_dir = root / 'GameA'
        ga_dir.mkdir()
        (ga_dir / 'Zelda Small [01007EF00011E000][v0].nsp').write_bytes(b'A' * 64)
        ga_base = ga_dir / 'Zelda BOTW [01007EF00011E000][v0].nsp'
        ga_base.write_bytes(b'A' * 256)
        (ga_dir / 'Zelda BOTW [01007EF00011E800][v65536].nsp').write_bytes(b'U' * 32)
        ga_upd = ga_dir / 'Zelda BOTW [01007EF00011E800][v131072].nsp'
        ga_upd.write_bytes(b'U' * 32)
        ga_dlc1 = ga_dir / 'Zelda DLC1 [01007EF00011F001][v0].nsp'
        ga_dlc2 = ga_dir / 'Zelda DLC2 [01007EF00011F002][v0].nsp'
        ga_dlc1.write_bytes(b'D' * 16)
        ga_dlc2.write_bytes(b'D' * 16)

        # Game B: XCI base + update + empty/hidden junk that must be ignored
        gb_base = root / 'Mario Kart 8 [0100152000022000][v0].xci'
        gb_base.write_bytes(b'B' * 128)
        gb_upd = root / 'Mario Kart 8 [0100152000022800][v196608].nsp'
        gb_upd.write_bytes(b'V' * 32)
        (root / '._Mario Kart 8 [0100152000022000].xci').write_bytes(b'junk')
        (root / 'Empty [0100F2C0115B6000].nsp').write_bytes(b'')

        # Game C: unpacked dump folder
        gc_dir = root / 'DumpGame'
        (gc_dir / 'base' / 'exefs').mkdir(parents=True)
        (gc_dir / 'base' / 'romfs').mkdir(parents=True)
        (gc_dir / 'base' / 'exefs' / 'main.npdm').write_bytes(_make_fake_npdm(0x0100000000010000))

        # Game D: Switch 2 NUP
        gd_nup = root / 'Switch2Title.nup'
        _make_fake_nup(gd_nup, 0x040032B023CA4000)

        # Build output dir that must be skipped
        skip_dir = root / '01007EF00011E000_build'
        skip_dir.mkdir()
        (skip_dir / 'Fake [0100999999999000].nsp').write_bytes(b'X' * 64)

        res = bq.discover_game_groups([str(root)])
        self.assertEqual(res.keys_path, str(keys))
        by_tid = {g.title_id: g for g in res.games}
        self.assertEqual(
            set(by_tid.keys()),
            {'01007EF00011E000', '0100152000022000', '0100000000010000', '040032B023CA4000'},
        )

        ga = by_tid['01007EF00011E000']
        self.assertEqual(ga.base_path, str(ga_base))
        self.assertEqual(ga.update_path, str(ga_upd))
        self.assertEqual(ga.dlc_paths, sorted([str(ga_dlc1), str(ga_dlc2)]))
        self.assertFalse(ga.is_game_folder)
        self.assertEqual(ga.keys_path, str(keys))

        gb = by_tid['0100152000022000']
        self.assertEqual(gb.base_path, str(gb_base))
        self.assertEqual(gb.update_path, str(gb_upd))
        self.assertEqual(gb.dlc_paths, [])

        gc = by_tid['0100000000010000']
        self.assertTrue(gc.is_game_folder)
        self.assertEqual(gc.game_dir, str(gc_dir))

        gd = by_tid['040032B023CA4000']
        self.assertTrue(gd.is_game_folder)
        self.assertEqual(gd.game_dir, str(gd_nup))

    def test_discover_ignores_symlinks(self) -> None:
        real_nsp = self.tmp / 'Real [01007EF00011E000].nsp'
        real_nsp.write_bytes(b'A' * 64)
        scan_dir = self.tmp / 'scan'
        scan_dir.mkdir()
        link_nsp = scan_dir / 'Link [0100152000022000].nsp'
        try:
            os.symlink(real_nsp, link_nsp)
        except OSError:
            self.skipTest('symlinks not permitted on this platform')
        res = bq.discover_game_groups([str(scan_dir)])
        self.assertEqual(res.games, [])


class BuildQueueStoreTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix='bq-store-'))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.qfile = self.tmp / 'build-queue.json'

    def _entry(self, tid: str, name: str, **kw) -> bq.QueueEntry:
        return bq.QueueEntry(
            title_id=tid,
            name=name,
            base_path=f'/games/{name}.nsp',
            keys_path='/games/prod.keys',
            **kw,
        )

    def test_enqueue_while_running_does_not_interrupt_and_advances_sequentially(self) -> None:
        started: list[tuple[str, bool]] = []
        batches: list[tuple[int, int, int]] = []
        running_flag = [False]

        def start_entry(entry: bq.QueueEntry, defer_shell: bool) -> str | None:
            started.append((entry.title_id, defer_shell))
            running_flag[0] = True
            return None

        store = bq.BuildQueueStore(
            file_path=self.qfile,
            busy=lambda: running_flag[0],
            start_entry=start_entry,
            on_batch_completed=lambda d, f, s: batches.append((d, f, s)),
        )
        e1 = self._entry('0100000000001000', 'Game 1')
        self.assertEqual(store.enqueue([e1]), 1)
        self.assertTrue(store.start())
        self.assertEqual(started, [('0100000000001000', False)])
        self.assertEqual(store.running_entry.title_id, '0100000000001000')

        # Enqueue new games (plus a duplicate of the running game) mid-build
        e1_dup = self._entry('0100000000001000', 'Game 1 Dup')
        e2 = self._entry('0100000000002000', 'Game 2')
        e3 = self._entry('0100000000003000', 'Game 3')
        self.assertEqual(store.enqueue([e1_dup, e2, e3]), 2)
        self.assertEqual(store.running_entry.title_id, '0100000000001000')
        self.assertEqual(store.progress_counts(), (1, 3))

        # Finish Game 1 -> Game 2 starts with defer_shell=True (Game 3 still waiting)
        running_flag[0] = False
        self.assertTrue(store.on_build_finished(True, 'ok'))
        self.assertEqual(started[-1], ('0100000000002000', True))
        self.assertEqual(store.progress_counts(), (2, 3))

        # Finish Game 2 -> Game 3 starts with defer_shell=False (last iOS shared item)
        running_flag[0] = False
        self.assertTrue(store.on_build_finished(True, 'ok'))
        self.assertEqual(started[-1], ('0100000000003000', False))

        # Finish Game 3 -> batch completes
        running_flag[0] = False
        self.assertTrue(store.on_build_finished(True, 'ok'))
        self.assertFalse(store.active)
        self.assertEqual(batches, [(3, 0, 0)])
        self.assertEqual([e.status for e in store.entries], [bq.STATUS_DONE] * 3)

    def test_single_failure_does_not_block_following_games(self) -> None:
        started: list[str] = []
        batches: list[tuple[int, int, int]] = []
        running_flag = [False]

        def start_entry(entry: bq.QueueEntry, _defer: bool) -> str | None:
            started.append(entry.title_id)
            if entry.title_id == '0100000000001000':
                return 'missing prod.keys'  # synchronous failure
            running_flag[0] = True
            return None

        store = bq.BuildQueueStore(
            file_path=self.qfile,
            busy=lambda: running_flag[0],
            start_entry=start_entry,
            on_batch_completed=lambda d, f, s: batches.append((d, f, s)),
        )
        store.enqueue([
            self._entry('0100000000001000', 'Sync Fail'),
            self._entry('0100000000002000', 'Async Fail'),
            self._entry('0100000000003000', 'Success Game'),
        ])
        store.start()
        # Sync Fail failed immediately and automatically advanced to Async Fail
        self.assertEqual(started, ['0100000000001000', '0100000000002000'])
        self.assertEqual(store.entries[0].status, bq.STATUS_FAILED)
        self.assertEqual(store.entries[0].reason, 'missing prod.keys')
        self.assertEqual(store.entries[1].status, bq.STATUS_BUILDING)

        # Async Fail fails -> automatically advances to Success Game
        running_flag[0] = False
        store.on_build_finished(False, 'shader compiler crashed')
        self.assertEqual(started, ['0100000000001000', '0100000000002000', '0100000000003000'])
        self.assertEqual(store.entries[1].status, bq.STATUS_FAILED)
        self.assertEqual(store.entries[1].reason, 'shader compiler crashed')

        # Success Game succeeds -> batch completes (1 done, 2 failed)
        running_flag[0] = False
        store.on_build_finished(True, 'done')
        self.assertEqual(store.entries[2].status, bq.STATUS_DONE)
        self.assertEqual(batches, [(1, 2, 0)])

    def test_stop_queue_stopping_window_blocks_racy_restarts_and_requeues_interrupted(self) -> None:
        started: list[str] = []
        cancelled = [0]
        running_flag = [False]

        def start_entry(entry: bq.QueueEntry, _defer: bool) -> str | None:
            started.append(entry.title_id)
            running_flag[0] = True
            return None

        store = bq.BuildQueueStore(
            file_path=self.qfile,
            busy=lambda: running_flag[0],
            start_entry=start_entry,
            cancel_running=lambda: cancelled.__setitem__(0, cancelled[0] + 1),
        )
        store.enqueue([
            self._entry('0100000000001000', 'Game 1'),
            self._entry('0100000000002000', 'Game 2'),
        ])
        store.start()
        gen1 = store.current_generation
        self.assertEqual(started, ['0100000000001000'])

        # User clicks Stop while Game 1 subprocess is still tearing down
        store.stop_queue()
        self.assertEqual(cancelled[0], 1)
        self.assertTrue(store.stopping)
        self.assertFalse(store.active)
        self.assertTrue(store.paused)

        # During `stopping` window, neither start() nor process_next() nor enqueue(auto_start=True) may launch Game 2
        self.assertFalse(store.start())
        self.assertFalse(store.process_next())
        store.enqueue([self._entry('0100000000003000', 'Game 3')], auto_start=True)
        self.assertEqual(started, ['0100000000001000'])

        # Stale generation callback is ignored
        self.assertFalse(store.on_build_finished(True, 'stale', generation=gen1 - 1))
        self.assertTrue(store.stopping)

        # Now Game 1 exits due to cancellation -> returns to queued, stopping clears, Game 2 stays queued
        running_flag[0] = False
        self.assertTrue(store.on_build_finished(False, 'Stopped', stopped=True, generation=gen1))
        self.assertFalse(store.stopping)
        self.assertFalse(store.active)
        self.assertTrue(store.paused)
        self.assertEqual(store.entries[0].status, bq.STATUS_QUEUED)
        self.assertEqual(store.entries[0].reason, '')
        self.assertEqual(started, ['0100000000001000'])

        # Resuming starts Game 1 again from the front
        self.assertTrue(store.resume())
        self.assertEqual(started, ['0100000000001000', '0100000000001000'])
        self.assertEqual(store.entries[0].status, bq.STATUS_BUILDING)

    def test_restart_persistence_recovers_building_to_queued_never_done(self) -> None:
        started: list[str] = []
        running_flag = [False]

        def start_entry(entry: bq.QueueEntry, _defer: bool) -> str | None:
            started.append(entry.title_id)
            running_flag[0] = True
            return None

        store1 = bq.BuildQueueStore(
            file_path=self.qfile,
            busy=lambda: running_flag[0],
            start_entry=start_entry,
        )
        store1.enqueue([
            self._entry('0100000000001000', 'Finished Game'),
            self._entry('0100000000002000', 'Crash Mid Build'),
            self._entry('0100000000003000', 'Still Waiting'),
        ])
        store1.start()
        running_flag[0] = False
        store1.on_build_finished(True, 'done')
        # Now Game 2 is actively building and persisted as `building`
        self.assertEqual(store1.entries[0].status, bq.STATUS_DONE)
        self.assertEqual(store1.entries[1].status, bq.STATUS_BUILDING)
        self.assertEqual(store1.entries[2].status, bq.STATUS_QUEUED)
        self.assertTrue(self.qfile.is_file())

        # Simulate process crash & restart with a fresh BuildQueueStore reading the same file
        started2: list[str] = []
        store2 = bq.BuildQueueStore(
            file_path=self.qfile,
            busy=lambda: False,
            start_entry=lambda e, _d: (started2.append(e.title_id), None)[1],
        )
        self.assertTrue(store2.awaiting_resume)
        self.assertFalse(store2.active)
        self.assertEqual(started2, [])  # must not auto-start after crash
        self.assertEqual(store2.entries[0].status, bq.STATUS_DONE)
        # Critical receipt check: interrupted `building` entry MUST become `queued`, NEVER `done`
        self.assertEqual(store2.entries[1].status, bq.STATUS_QUEUED)
        self.assertEqual(store2.entries[2].status, bq.STATUS_QUEUED)

        # Corrupt file recovers safely to empty queue
        corrupt = self.tmp / 'corrupt-queue.json'
        corrupt.write_text('{not valid json', encoding='utf-8')
        store3 = bq.BuildQueueStore(file_path=corrupt)
        self.assertTrue(store3.is_empty)
        self.assertFalse(store3.awaiting_resume)

    def test_reorder_remove_retry_clear_and_cancel_queued(self) -> None:
        repacked = [0]
        running_flag = [False]
        store = bq.BuildQueueStore(
            file_path=self.qfile,
            busy=lambda: running_flag[0],
            start_entry=lambda _e, _d: (running_flag.__setitem__(0, True), None)[1],
            repack_shared_shell=lambda: (repacked.__setitem__(0, repacked[0] + 1), True)[1],
        )
        e1 = self._entry('0100000000001000', 'G1')
        e2 = self._entry('0100000000002000', 'G2')
        e3 = self._entry('0100000000003000', 'G3')
        store.enqueue([e1, e2, e3])

        self.assertFalse(store.can_move_up(e1.id))
        self.assertTrue(store.can_move_down(e1.id))
        self.assertTrue(store.move_down(e1.id))
        self.assertEqual([e.title_id for e in store.entries], ['0100000000002000', '0100000000001000', '0100000000003000'])
        self.assertTrue(store.move_up(e3.id))
        self.assertEqual([e.title_id for e in store.entries], ['0100000000002000', '0100000000003000', '0100000000001000'])

        # Start G2 -> cannot remove running G2, can remove queued G1
        store.start()
        self.assertFalse(store.remove(e2.id))
        self.assertTrue(store.remove(e1.id))
        self.assertEqual([e.title_id for e in store.entries], ['0100000000002000', '0100000000003000'])

        # Fail G2, succeed G3 -> retry G2
        running_flag[0] = False
        store.on_build_finished(False, 'oom')
        self.assertEqual(store.entries[0].status, bq.STATUS_FAILED)
        self.assertEqual(store.entries[1].status, bq.STATUS_BUILDING)
        running_flag[0] = False
        store.on_build_finished(True, 'done')
        self.assertEqual(store.entries[1].status, bq.STATUS_DONE)

        self.assertTrue(store.retry(e2.id))
        self.assertEqual(store.entries[0].status, bq.STATUS_QUEUED)
        self.assertEqual(store.entries[0].reason, '')

        # Clear finished removes G3 (done) and keeps G2 (queued)
        self.assertEqual(store.clear_finished(), 1)
        self.assertEqual([e.title_id for e in store.entries], ['0100000000002000'])

        # Cancel queued clears waiting items
        self.assertEqual(store.cancel_queued(), 1)
        self.assertTrue(store.is_empty)

    def test_deferred_shared_shell_still_repacks_when_later_entries_removed(self) -> None:
        started: list[tuple[str, bool]] = []
        repacks: list[int] = []
        batches: list[tuple[int, int, int]] = []
        running_flag = [False]

        def start_entry(ent: bq.QueueEntry, defer: bool) -> str | None:
            started.append((ent.id, defer))
            running_flag[0] = True
            return None

        def repack() -> bool:
            repacks.append(1)
            running_flag[0] = True
            return True

        store = bq.BuildQueueStore(
            file_path=self.qfile,
            busy=lambda: running_flag[0],
            start_entry=start_entry,
            repack_shared_shell=repack,
            on_batch_completed=lambda d, f, s: batches.append((d, f, s)),
        )
        e1 = bq.QueueEntry(id='s1', title_id='0100000000001000', name='S1', base_path='/a.nsp', target='ios', ipa_kind='shared')
        e2 = bq.QueueEntry(id='s2', title_id='0100000000002000', name='S2', base_path='/b.nsp', target='ios', ipa_kind='shared')
        store.enqueue([e1, e2])
        self.assertTrue(store.start())
        self.assertEqual(started, [('s1', True)])

        # User deletes the remaining waiting item while s1 (deferred) is still building
        self.assertTrue(store.remove('s2'))
        running_flag[0] = False
        self.assertTrue(store.on_build_finished(True, 'done'))

        # Must still trigger final shared-shell repack even though no queued items remain
        self.assertEqual(len(repacks), 1)
        self.assertTrue(store.finalizing_shell)
        self.assertEqual(batches, [])

        running_flag[0] = False
        self.assertTrue(store.on_build_finished(True, 'repacked'))
        self.assertFalse(store.finalizing_shell)
        self.assertFalse(store.active)
        self.assertEqual(batches, [(1, 0, 0)])

        # Single non-deferred shared iOS build exports shell directly and does not trigger extra repack
        e3 = bq.QueueEntry(id='s3', title_id='0100000000003000', name='S3', base_path='/c.nsp', target='ios', ipa_kind='shared')
        store.enqueue([e3])
        self.assertTrue(store.start())
        self.assertEqual(started[-1], ('s3', False))
        running_flag[0] = False
        self.assertTrue(store.on_build_finished(True, 'done'))
        self.assertEqual(len(repacks), 1)
        self.assertFalse(store.active)

    def test_queue_file_load_rejects_symlink(self) -> None:
        real = self.tmp / 'real-queue.json'
        link = self.tmp / 'link-queue.json'
        bq.BuildQueueFile.save(
            [bq.QueueEntry(id='e1', title_id='0100000000001000', name='Real', base_path='/a.nsp')],
            paused=True,
            path=real,
        )
        try:
            os.symlink(real, link)
        except OSError:
            self.skipTest('symlink creation unsupported on this platform')
        entries, paused = bq.BuildQueueFile.load(link)
        self.assertEqual(entries, [])
        self.assertFalse(paused)


class HeadlessNoPySide6Tests(unittest.TestCase):
    def test_build_queue_logic_runs_cleanly_with_pyside6_completely_blocked(self) -> None:
        """Wrap every sys.meta_path finder to block PySide6, assert find_spec is None, and run pure queue tests."""
        with tempfile.TemporaryDirectory(prefix='bq-headless-') as td:
            script = Path(td) / 'run_headless_bq.py'
            script.write_text(
                f"""import importlib.abc
import importlib.util
import sys
import tempfile
from pathlib import Path


class _BlockPySide6Finder(importlib.abc.MetaPathFinder):
    def __init__(self, wrapped):
        self._wrapped = wrapped

    def find_spec(self, fullname, path=None, target=None):
        if fullname == 'PySide6' or fullname.startswith('PySide6.'):
            return None
        return self._wrapped.find_spec(fullname, path, target)


sys.meta_path = [_BlockPySide6Finder(f) for f in sys.meta_path]
for name in list(sys.modules):
    if name == 'PySide6' or name.startswith('PySide6.'):
        del sys.modules[name]

assert importlib.util.find_spec('PySide6') is None, 'PySide6 must be completely blocked'

sys.path.insert(0, {str(ROOT / 'frontend-qt')!r})
from nspb_qt import build_queue as bq

assert bq.HAS_QT is False, 'build_queue.HAS_QT must be False when PySide6 is absent'

with tempfile.TemporaryDirectory() as qdir:
    qfile = Path(qdir) / 'build-queue.json'
    f1 = Path(qdir) / 'Alpha [0100111111110000][v0].nsp'
    f2 = Path(qdir) / 'Beta [0100222222220000][v0].nsp'
    f1.write_bytes(b'1' * 64)
    f2.write_bytes(b'2' * 64)
    disc = bq.discover_game_groups([str(qdir)])
    assert len(disc.games) == 2, f'expected 2 games, got {{len(disc.games)}}'

    started = []
    store = bq.BuildQueueStore(
        file_path=qfile,
        busy=lambda: False,
        start_entry=lambda e, _d: (started.append(e.title_id), None)[1],
    )
    entries = [g.to_queue_entry() for g in disc.games]
    assert store.enqueue(entries) == 2
    assert store.start() is True
    assert store.entries[0].status == bq.STATUS_BUILDING

    # Restart recovery without PySide6
    reloaded = bq.BuildQueueStore(file_path=qfile)
    assert reloaded.awaiting_resume is True
    assert reloaded.entries[0].status == bq.STATUS_QUEUED
    assert reloaded.entries[1].status == bq.STATUS_QUEUED

print('HEADLESS_BUILD_QUEUE_OK')
""",
                encoding='utf-8',
            )
            proc = subprocess.run(
                [sys.executable, str(script)],
                capture_output=True,
                text=True,
                timeout=30,
            )
            self.assertEqual(
                proc.returncode,
                0,
                f'Headless test failed:\nSTDOUT:\n{proc.stdout}\nSTDERR:\n{proc.stderr}',
            )
            self.assertIn('HEADLESS_BUILD_QUEUE_OK', proc.stdout)


try:
    from PySide6.QtCore import QEvent, QMimeData, QPointF, Qt, QUrl
    from PySide6.QtGui import QDropEvent
    from PySide6.QtWidgets import QApplication
    HAS_PYSIDE6 = True
except ImportError:
    HAS_PYSIDE6 = False


@unittest.skipUnless(HAS_PYSIDE6, 'PySide6 required for MainWindow BuildQueueCard UI tests')
class MainWindowBuildQueueUITests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')
        cls.app = QApplication.instance() or QApplication([])

    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix='bq-ui-'))
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def _cleanup_window(self, m, w) -> None:
        w.close()
        w.deleteLater()
        m.deleteLater()
        self.app.sendPostedEvents(None, QEvent.DeferredDelete)
        self.app.processEvents()

    def _make_window(self, lang_code: str = 'en', queue_file: Path | None = None):
        from nspb_qt.i18n import Lang
        from nspb_qt.model import Model
        from nspb_qt.ui import MainWindow

        m = Model(queue_file=queue_file or (self.tmp / 'build-queue.json'))
        m.repo_path = ''
        m.deps_checked = True
        m.deps = []
        m.set_lang(Lang(lang_code))
        w = MainWindow(m, perform_startup_checks=False)
        self.addCleanup(self._cleanup_window, m, w)
        w.resize(1080, 860)
        w.show()
        for _ in range(3):
            self.app.processEvents()
        return m, w

    def test_add_current_game_reorder_retry_and_l10n_rendering(self) -> None:
        m, w = self._make_window('en')
        g1 = self.tmp / 'Hollow Knight [0100633007D48000][v0].nsp'
        g2 = self.tmp / 'Celeste [0100F7B00BB5C000][v0].nsp'
        keys = self.tmp / 'prod.keys'
        g1.write_bytes(b'1' * 64)
        g2.write_bytes(b'2' * 64)
        keys.write_text('header_key = ' + '0' * 64 + '\n', encoding='utf-8')

        m.base_path = str(g1)
        m.keys_path = str(keys)
        w._refresh_all()
        self.assertTrue(w.add_queue_btn.isEnabled())

        # Click Add to queue for Game 1
        w.add_queue_btn.click()
        self.app.processEvents()
        self.assertEqual(len(m.build_queue.entries), 1)
        self.assertFalse(w.add_queue_btn.isEnabled(), 'duplicate queued entry disables add button')
        self.assertEqual(len(w.queue_card._row_widgets), 1)
        self.assertTrue(w.queue_card.start_btn.isVisible())

        # Select Game 2 and enqueue
        m.base_path = str(g2)
        w._refresh_all()
        self.assertTrue(w.add_queue_btn.isEnabled())
        w.add_queue_btn.click()
        self.app.processEvents()
        self.assertEqual(len(m.build_queue.entries), 2)
        self.assertEqual(len(w.queue_card._row_widgets), 2)
        self.assertIn('2', w.queue_card.progress_pill.text())

        # Switch language to zh and verify BuildQueueCard updates cleanly
        from nspb_qt.i18n import Lang
        m.set_lang(Lang('zh'))
        self.app.processEvents()
        self.assertEqual(w.queue_card.title_label.text(), m.t('queue.title'))
        self.assertEqual(w.add_queue_btn.text(), m.t('queue.add'))

    def test_drop_multi_games_opens_confirm_dialog_and_running_drop_appends(self) -> None:
        m, w = self._make_window('en')
        g1 = self.tmp / 'Game One [0100111111110000][v0].nsp'
        g2 = self.tmp / 'Game Two [0100222222220000][v0].nsp'
        g3 = self.tmp / 'Game Three [0100333333330000][v0].nsp'
        for f in (g1, g2, g3):
            f.write_bytes(b'X' * 64)

        # Multi-game drop triggers QueueSelectGamesDialog with both discovered games pre-checked
        mime = QMimeData()
        mime.setUrls([QUrl.fromLocalFile(str(g1)), QUrl.fromLocalFile(str(g2))])
        ev = QDropEvent(QPointF(20, 20), Qt.DropAction.CopyAction, mime, Qt.MouseButton.LeftButton, Qt.KeyboardModifier.NoModifier)

        opened_discovered: list[list[bq.DiscoveredGame]] = []

        def fake_open(discovered=None):
            opened_discovered.append(list(discovered or []))
            m.enqueue_discovered_games(list(discovered or []))

        with mock.patch.object(w, '_open_queue_select_dialog', side_effect=fake_open):
            w.dropEvent(ev)
        self.assertEqual(len(opened_discovered), 1)
        self.assertEqual(len(opened_discovered[0]), 2)
        self.assertEqual(len(m.build_queue.entries), 2)

        # Single-game drop while running appends to queue without overwriting current build form
        m.base_path = str(g1)
        m.running = True
        mime2 = QMimeData()
        mime2.setUrls([QUrl.fromLocalFile(str(g3))])
        ev2 = QDropEvent(QPointF(20, 20), Qt.DropAction.CopyAction, mime2, Qt.MouseButton.LeftButton, Qt.KeyboardModifier.NoModifier)
        w.dropEvent(ev2)
        self.assertEqual(m.base_path, str(g1), 'running build inputs must remain untouched')
        self.assertEqual(len(m.build_queue.entries), 3)
        self.assertEqual(m.build_queue.entries[-1].title_id, '0100333333330000')

    def test_select_games_dialog_prechecks_and_returns_entries(self) -> None:
        m, w = self._make_window('en')
        g1 = bq.DiscoveredGame(
            title_id='01007EF00011E000',
            name='Breath of the Wild',
            base_path='/games/botw.nsp',
            update_path='/games/botw_upd.nsp',
            dlc_paths=['/games/botw_dlc1.nsp'],
        )
        g2 = bq.DiscoveredGame(
            title_id='0100152000022000',
            name='Mario Kart 8 Deluxe',
            base_path='/games/mk8d.xci',
        )
        dlg = bq.QueueSelectGamesDialog(m, m.build_queue, discovered=[g1, g2], parent=w)
        self.assertEqual(len(dlg._checkboxes), 2)
        self.assertTrue(all(cb.isChecked() for cb, _ in dlg._checkboxes))
        dlg._accept_selected()
        chosen = dlg.chosen_entries()
        self.assertEqual(len(chosen), 2)
        self.assertEqual(chosen[0].title_id, '01007EF00011E000')
        self.assertEqual(chosen[1].title_id, '0100152000022000')
        self.assertEqual(chosen[0].batch_id, chosen[1].batch_id)

    def test_model_end_to_end_queue_signal_advancement_and_batch_completed(self) -> None:
        from nspb_qt.model import Dep, DepState, Model

        g1 = self.tmp / 'Game A [01007EF00011E000][v0].nsp'
        g2 = self.tmp / 'Game B [0100152000022000][v0].nsp'
        keys = self.tmp / 'prod.keys'
        g1.write_bytes(b'1' * 64)
        g2.write_bytes(b'2' * 64)
        keys.write_text('header_key = ' + '0' * 64 + '\n', encoding='utf-8')

        m = Model(queue_file=self.tmp / 'e2e-queue.json')
        self.addCleanup(m.deleteLater)
        m.deps_checked = True
        m.deps = [Dep('python', 'dep.python', 'dep.python.hint', DepState.OK)]

        batches: list[tuple[int, int, int]] = []
        m.queueBatchCompleted.connect(lambda d, f, s: batches.append((d, f, s)))

        built_bases: list[str] = []

        def fake_start_build(*, title_id=None):
            built_bases.append(m.base_path)
            if m.base_path == str(g1):
                m.finished.emit(False, 'shader fail')
            else:
                m.finished.emit(True, 'done')

        with (
            mock.patch.object(type(m), 'repo_ok', new_callable=mock.PropertyMock, return_value=True),
            mock.patch.object(m, 'start_build', side_effect=fake_start_build),
        ):
            m.build_queue.enqueue([
                bq.QueueEntry(title_id='01007EF00011E000', name='Game A', base_path=str(g1), keys_path=str(keys)),
                bq.QueueEntry(title_id='0100152000022000', name='Game B', base_path=str(g2), keys_path=str(keys)),
            ])
            self.assertTrue(m.build_queue.start())
            for _ in range(10):
                self.app.processEvents()

        self.assertEqual(built_bases, [str(g1), str(g2)])
        self.assertEqual(m.build_queue.entries[0].status, bq.STATUS_FAILED)
        self.assertEqual(m.build_queue.entries[0].reason, 'shader fail')
        self.assertEqual(m.build_queue.entries[1].status, bq.STATUS_DONE)
        self.assertEqual(batches, [(1, 1, 0)])

    def test_restart_recovery_banner_and_row_action_buttons_in_mainwindow(self) -> None:
        qfile = self.tmp / 'crash-queue.json'
        bq.BuildQueueFile.save(
            [
                bq.QueueEntry(
                    id='e-done',
                    title_id='0100111111110000',
                    name='Done Game',
                    base_path='/games/done.nsp',
                    status=bq.STATUS_DONE,
                ),
                bq.QueueEntry(
                    id='e-crash',
                    title_id='0100222222220000',
                    name='Crashed Game',
                    base_path='/games/crash.nsp',
                    status=bq.STATUS_BUILDING,
                ),
                bq.QueueEntry(
                    id='e-fail',
                    title_id='0100333333330000',
                    name='Failed Game',
                    base_path='/games/fail.nsp',
                    status=bq.STATUS_FAILED,
                    reason='link failed',
                ),
            ],
            paused=False,
            path=qfile,
        )
        m, w = self._make_window('en', queue_file=qfile)
        self.assertTrue(m.build_queue.awaiting_resume)
        self.assertEqual(m.build_queue.entries[1].status, bq.STATUS_QUEUED)
        self.assertEqual(w.queue_card.start_btn.text(), m.t('queue.resume'))
        self.assertTrue(w.queue_card.clear_btn.isVisible())

        # Retry the failed item directly via store/UI and verify card refreshes
        self.assertTrue(m.build_queue.retry('e-fail'))
        self.app.processEvents()
        self.assertEqual(m.build_queue.entries[2].status, bq.STATUS_QUEUED)
        self.assertTrue(m.build_queue.move_up('e-fail'))
        self.app.processEvents()
        self.assertEqual([e.id for e in m.build_queue.entries], ['e-done', 'e-fail', 'e-crash'])

    def test_model_repack_resets_cancel_flag_defer_shell_cleanup_and_rejects_symlinks(self) -> None:
        from nspb_qt.model import Dep, DepState, Model

        real_base = self.tmp / 'real.nsp'
        real_keys = self.tmp / 'prod.keys'
        real_upd = self.tmp / 'upd.nsp'
        real_dlc = self.tmp / 'dlc.nsp'
        real_dir = self.tmp / 'game_folder'
        real_dir.mkdir()
        real_base.write_bytes(b'1' * 64)
        real_keys.write_text('header_key = ' + '0' * 64 + '\n', encoding='utf-8')
        real_upd.write_bytes(b'2' * 64)
        real_dlc.write_bytes(b'3' * 64)

        m = Model(queue_file=self.tmp / 'guard-queue.json')
        self.addCleanup(m.deleteLater)
        m.deps_checked = True
        m.deps = [Dep('python', 'dep.python', 'dep.python.hint', DepState.OK)]

        # 1) start_repack_shell_ipa resets stale _build_cancelled flag
        m._build_cancelled = True
        done_ev = threading.Event()

        def fake_repack() -> tuple[bool, str]:
            done_ev.set()
            return True, 'ok'

        with (
            mock.patch.object(m, 'can_export_built_games', return_value=True),
            mock.patch.object(m, 'repack_built_shell_ipa', side_effect=fake_repack),
        ):
            self.assertTrue(m.start_repack_shell_ipa())
            self.assertFalse(m._build_cancelled)
            self.assertTrue(done_ev.wait(timeout=3.0))
            for _ in range(10):
                self.app.processEvents()

        # 2) start_build_from_queue_entry clears _defer_shell_export if start_build fails to launch async
        ent_ok = bq.QueueEntry(
            title_id='01007EF00011E000',
            name='BotW',
            base_path=str(real_base),
            keys_path=str(real_keys),
            target='ios',
            ipa_kind='shared',
        )
        with (
            mock.patch.object(type(m), 'repo_ok', new_callable=mock.PropertyMock, return_value=True),
            mock.patch.object(m, 'start_build', return_value=None),
        ):
            m.start_build_from_queue_entry(ent_ok, defer_shell_export=True)
            self.assertFalse(m._defer_shell_export)

        # 3) start_build_from_queue_entry rejects symlinks for game_dir, base, keys, update, and dlc
        try:
            link_base = self.tmp / 'link_base.nsp'
            link_keys = self.tmp / 'link_keys.keys'
            link_upd = self.tmp / 'link_upd.nsp'
            link_dlc = self.tmp / 'link_dlc.nsp'
            link_dir = self.tmp / 'link_dir'
            os.symlink(real_base, link_base)
            os.symlink(real_keys, link_keys)
            os.symlink(real_upd, link_upd)
            os.symlink(real_dlc, link_dlc)
            os.symlink(real_dir, link_dir)
        except OSError:
            self.skipTest('symlink creation unsupported on this platform')

        with mock.patch.object(type(m), 'repo_ok', new_callable=mock.PropertyMock, return_value=True):
            self.assertIsNotNone(m.start_build_from_queue_entry(
                bq.QueueEntry(name='DirLink', game_dir=str(link_dir), is_game_folder=True)
            ))
            self.assertIsNotNone(m.start_build_from_queue_entry(
                bq.QueueEntry(name='BaseLink', base_path=str(link_base), keys_path=str(real_keys))
            ))
            self.assertIsNotNone(m.start_build_from_queue_entry(
                bq.QueueEntry(name='KeysLink', base_path=str(real_base), keys_path=str(link_keys))
            ))
            self.assertIsNotNone(m.start_build_from_queue_entry(
                bq.QueueEntry(name='UpdLink', base_path=str(real_base), keys_path=str(real_keys), update_path=str(link_upd))
            ))
            self.assertIsNotNone(m.start_build_from_queue_entry(
                bq.QueueEntry(name='DlcLink', base_path=str(real_base), keys_path=str(real_keys), dlc_paths=[str(link_dlc)])
            ))


if __name__ == '__main__':
    unittest.main()
