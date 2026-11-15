"""Issue #320 and shader progress formatting: stale-shaders popup notes and redundant `<N> not cached` stripping.

    python3 -m unittest frontend-qt/tests/test_build_notes.py -v
"""
from __future__ import annotations

import ast
import collections
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import threading
import time
import types
import unittest
from unittest import mock

os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')

ROOT = Path(__file__).resolve().parents[2]
QT_DIR = ROOT / 'frontend-qt'
if str(QT_DIR) not in sys.path:
    sys.path.insert(0, str(QT_DIR))

from nspb_qt import build_notes as bn  # noqa: E402

SCRIPT = ROOT / 'engine/scripts/build_ipa_from_nsp.py'


def _load_model_headless_without_pyside6():
    """Import `nspb_qt.model` with `PySide6` stubbed out so the test always exercises the headless CI path."""
    saved = {k: sys.modules.get(k) for k in ('PySide6', 'PySide6.QtCore', 'nspb_qt.model')}

    class _FakeSignalInstance:
        def __init__(self) -> None:
            self._slots: list = []

        def connect(self, fn) -> None:
            self._slots.append(fn)

        def disconnect(self, fn=None) -> None:
            if fn is None:
                self._slots.clear()
            elif fn in self._slots:
                self._slots.remove(fn)

        def emit(self, *args) -> None:
            for fn in list(self._slots):
                fn(*args)

    class _FakeSignal:
        def __init__(self, *_a) -> None:
            self._name = ''

        def __set_name__(self, _owner, name: str) -> None:
            self._name = f'_sig_{name}'

        def __get__(self, obj, _owner=None):
            if obj is None:
                return self
            inst = getattr(obj, self._name, None)
            if inst is None:
                inst = _FakeSignalInstance()
                setattr(obj, self._name, inst)
            return inst

    class _FakeQObject:
        def __init__(self, *_a, **_kw) -> None:
            pass

        def thread(self):
            return None

        @staticmethod
        def currentThread():
            return None

    class _FakeQSettings:
        def __init__(self, *_a, **_kw) -> None:
            self._d: dict[str, object] = {}

        def value(self, k: str, default: object = '', **kw) -> object:
            return self._d.get(k, kw.get('defaultValue', default))

        def setValue(self, k: str, v: object) -> None:
            self._d[k] = v

        def remove(self, k: str) -> None:
            self._d.pop(k, None)

    qt_pkg = types.ModuleType('PySide6')
    qt_core = types.ModuleType('PySide6.QtCore')
    qt_core.QSettings = _FakeQSettings
    qt_core.Q_ARG = lambda *_a: None
    qt_core.QMetaObject = types.SimpleNamespace(invokeMethod=lambda *_a, **_kw: None)
    qt_core.QObject = _FakeQObject
    qt_core.Qt = types.SimpleNamespace(QueuedConnection=0)
    qt_core.QThread = _FakeQObject
    qt_core.Signal = _FakeSignal
    qt_core.Slot = lambda *_a, **_kw: (lambda fn: fn)
    qt_pkg.QtCore = qt_core

    sys.modules['PySide6'] = qt_pkg
    sys.modules['PySide6.QtCore'] = qt_core
    sys.modules.pop('nspb_qt.model', None)

    def restore() -> None:
        for k, v in saved.items():
            if v is None:
                sys.modules.pop(k, None)
            else:
                sys.modules[k] = v

    from nspb_qt import model as model_mod
    return model_mod, restore


class BuildNotesTest(unittest.TestCase):
    def test_each_reason_is_read(self):
        self.assertEqual(bn.stale_reason('[NOTE] cached shader libraries cannot be reused (b-4e0dd2535996 -> b-b7cd656abd7c): '
                                         'the translation chain changed; 65 base libraries scheduled'), 'chain')
        self.assertEqual(bn.stale_reason("[NOTE] cached shader libraries cannot be reused (3f1c -> 9a20): "
                                         "the game profile's shader inputs changed"), 'inputs')

    def test_other_lines_are_not_a_note(self):
        for line in ('[NOTE] chain-changed: b-4e0dd2535996 -> b-b7cd656abd7c: the upstream update changed the shader translator',
                     '[5/9] shaders'):
            with self.subTest(line=line):
                self.assertIsNone(bn.stale_reason(line))

    def test_every_reason_has_a_text(self):
        self.assertEqual(set(bn.REASONS.values()), set(bn.TEXT))

    @unittest.skipUnless(SCRIPT.is_file(), 'engine/ is not synced (python3 tools/engine.py sync)')
    def test_the_engines_script_still_prints_the_note(self):
        """An engine update that rewords the note fails here, instead of losing the popup."""
        text = SCRIPT.read_text(encoding='utf-8').replace("\\'", "'")   # the script writes profile\'s
        for words in (bn.STALE_SHADERS, *bn.REASONS):
            with self.subTest(words=words):
                self.assertIn(words, text)

    def test_strip_not_cached_variants(self):
        cases = [
            ('11,201 not cached', ''),
            ('4 not cached', ''),
            ('1,234,567 not cached', ''),
            ('11\u00a0201 not cached', ''),
            ('11\u202f201 not cached', ''),
            ('11.201 not cached', ''),
            ('compiling · 679 / 11,201 shaders · 11,201 not cached', 'compiling · 679 / 11,201 shaders'),
            (
                'compiling · 679 / 11,201 shaders · 11,201 not cached · 0:50 · ETA 12:54',
                'compiling · 679 / 11,201 shaders · 0:50 · ETA 12:54',
            ),
            (
                '679/11,201 shaders, 11,201 not cached, 0:50 · ETA 12:54',
                '679/11,201 shaders, 0:50 · ETA 12:54',
            ),
            ('679 / 11,201 shaders (11,201 not cached)', '679 / 11,201 shaders'),
            ('(11,201 not cached)', ''),
            ('6,000 cached, 5,201 not cached', '6,000 cached'),
            ('6,000 cached · 5,201 not cached', '6,000 cached'),
            ('(6,000 cached, 5,201 not cached)', '(6,000 cached)'),
            ('(5,201 not cached, 6,000 cached)', '(6,000 cached)'),
            ('2 cached', '2 cached'),
            ('11,201 of 11,201 shaders ready (0 from the cache)', '11,201 of 11,201 shaders ready (0 from the cache)'),
            ('a failed key was not cached as zero', 'a failed key was not cached as zero'),
        ]
        for raw, expected in cases:
            with self.subTest(raw=raw):
                self.assertEqual(bn.strip_not_cached(raw), expected)

    def test_model_on_line_strips_not_cached_without_breaking_percent_or_eta_headless(self):
        model_mod, restore = _load_model_headless_without_pyside6()
        self.addCleanup(restore)
        with mock.patch.object(model_mod.Model, 'check_deps', lambda self: None):
            m = model_mod.Model()

        # Generated by `build_ipa_from_nsp.py` `Progress('lines')` + `ShaderWatch` on `dmsh_build.py` DMSH_PROGRESS
        m._on_line('[12:01:01] [6/8] Mac shaders · cache check …')
        m._on_line('[12:01:03] [6/8] Mac shaders · cache check: 30%, 3,360/11,201 shaders, 0 cached, 0:02')
        self.assertEqual(m.stages[-1].percent, 30.0)
        self.assertEqual(m.stages[-1].detail, '3,360/11,201 shaders, 0 cached, 0:02')

        m._on_line('[12:01:04] [6/8] Mac shaders · compiling …')
        m._on_line('[12:01:54] [6/8] Mac shaders · compiling: 6%, 679/11,201 shaders, 11,201 not cached, 0:50 · ETA 12:54')
        self.assertEqual(m.stages[-1].name, 'Mac shaders · compiling')
        self.assertEqual(m.stages[-1].percent, 6.0)
        self.assertEqual(m.stages[-1].detail, '679/11,201 shaders, 0:50 · ETA 12:54')

        # Partial cache hit (4 not cached, no thousands comma)
        m._on_line('[12:02:10] [7/8] iOS shaders · compiling: 70%, 7/10 shaders, 4 not cached, 0:35 · ETA 0:15')
        self.assertEqual(m.stages[-1].percent, 70.0)
        self.assertEqual(m.stages[-1].detail, '7/10 shaders, 0:35 · ETA 0:15')

        # If `engine/` is synced locally, also verify directly against the real `ShaderWatch` + `Progress` emitter
        if SCRIPT.is_file():
            src = SCRIPT.read_text(encoding='utf-8')
            mod_ast = ast.parse(src, filename=str(SCRIPT))
            wanted = {'BEAT', 'clock', 'hms', 'size_unit', 'amount', 'Progress', 'ShaderWatch'}
            nodes = [
                n for n in mod_ast.body
                if (isinstance(n, (ast.FunctionDef, ast.ClassDef)) and n.name in wanted)
                or (isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id in wanted for t in n.targets))
            ]
            ns: dict[str, object] = {
                'collections': collections,
                'json': json,
                'shutil': shutil,
                'sys': sys,
                'threading': threading,
                'time': time,
                'types': types,
                'in_ipython': lambda: False,
            }
            exec(compile(ast.Module(body=nodes, type_ignores=[]), str(SCRIPT), 'exec'), ns)
            ProgressCls = ns['Progress']
            ShaderWatchCls = ns['ShaderWatch']
            clock_fn = ns['clock']
            with tempfile.TemporaryDirectory() as tmp:
                prog_json = Path(tmp) / 'progress.json'
                prog_json.write_text(
                    json.dumps({'step': 'compiling', 'done': 679, 'total': 11201, 'cached': 0, 'misses': 11201}),
                    encoding='utf-8',
                )
                watch = ShaderWatchCls(prog_json)
                polled = watch()
                self.assertEqual(polled['note'], '11,201 not cached')

                m2 = None
                with mock.patch.object(model_mod.Model, 'check_deps', lambda self: None):
                    m2 = model_mod.Model()
                prog = ProgressCls('lines')
                prog._out = m2._on_line
                try:
                    prog.plan(8)
                    prog.k = 5
                    prog.stage('Mac shaders', step='compiling')
                    if prog.tstop:
                        prog.tstop.set()
                    prog.set(**polled)
                    with prog.lock:
                        st = prog.cur
                        st.t0 -= 50.0
                        st.hist.clear()
                        now = time.time()
                        st.hist.append((now - 50.0, 0))
                        st.hist.append((now, 679))
                        head, frac, count, note, times = prog._fields(st)
                        prog._out(
                            f'[{clock_fn()}] {head}: '
                            + ', '.join(x for x in (f'{frac * 100:.0f}%' if frac is not None else '', count, note, times) if x)
                        )
                finally:
                    prog.close()
                self.assertNotIn('not cached', m2.stages[0].detail)
                self.assertIn('679/11,201 shaders', m2.stages[0].detail)
                self.assertIn('ETA ', m2.stages[0].detail)

    def test_elided_label_preserves_trailing_eta_when_narrow(self):
        try:
            from PySide6.QtCore import Qt
            from PySide6.QtWidgets import QApplication
            from nspb_qt.widgets import ElidedLabel
        except ImportError:
            return
        _app = QApplication.instance() or QApplication([])
        full = 'compiling · 10,842 / 28,669 shaders · 0:50 · ETA 12:54'
        lbl = ElidedLabel(full, elide_mode=Qt.ElideMiddle, alignment=Qt.AlignRight | Qt.AlignVCenter)
        self.assertEqual(lbl.text(), full)
        self.assertEqual(lbl.minimumSizeHint().width(), 0)
        narrow = lbl.displayed_text(180)
        self.assertNotEqual(narrow, full)
        self.assertTrue(narrow.endswith('ETA 12:54'), narrow)


if __name__ == '__main__':
    unittest.main()
