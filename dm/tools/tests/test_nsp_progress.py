"""NSP script progress (scripts/build_ipa_from_nsp.py --progress): the json mode's events, a count held back and sent by the ticker, a failed step's log tail,
and the human modes' lines; no game files, keys or Xcode needed (temporary files only in a temporary folder)."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[3] / 'scripts/build_ipa_from_nsp.py'
spec = importlib.util.spec_from_file_location('build_ipa_from_nsp', SCRIPT)
nsp = importlib.util.module_from_spec(spec); spec.loader.exec_module(nsp)

class OneTick:
    """A ticker stop event that lets one tick through"""
    def __init__(self): self.n = 0
    def wait(self, timeout): self.n += 1; return self.n > 1
    def is_set(self): return False

class Json(unittest.TestCase):
    def setUp(self):
        self.now, self.out = 100.0, io.StringIO()
        self.prog = nsp.Progress('json')
        for cm in (contextlib.redirect_stdout(self.out), mock.patch.object(nsp.time, 'monotonic', side_effect=lambda: self.now),
                   mock.patch.object(nsp.threading, 'Thread'), mock.patch.object(nsp, 'PROG', self.prog)):   # no real ticker: the tests tick it themselves
            cm.__enter__(); self.addCleanup(cm.__exit__, None, None, None)

    def events(self, ev=None):
        return [e for e in map(json.loads, self.out.getvalue().splitlines()) if ev in (None, e['ev'])]

    def test_events(self):
        self.prog.plan(2)
        self.prog.stage('extract Pokémon', step='reading', done=0, total=10, unit='files', est=True)
        self.prog.set(step='writing', done=2, total=4)
        self.prog.say('[RED] two\nlines')
        self.prog.end('4 files')
        self.prog.stage('rewrite')
        self.prog.close(ok=False); self.prog.close(ok=False)
        es = self.events()
        self.assertEqual([e['ev'] for e in es], ['stage', 'progress', 'step', 'progress', 'say', 'stage_end', 'stage', 'progress', 'stage_end'])
        self.assertEqual([es[0][k] for k in ('k', 'n', 'name', 'step')], [1, 2, 'extract Pokémon', 'reading'])
        self.assertEqual([es[1][k] for k in ('frac', 'est', 'eta')], [0, True, None])
        self.assertEqual([es[3][k] for k in ('step', 'frac', 'unit', 'est')], ['writing', 0.5, '', False])   # a new step starts with no count
        self.assertEqual(es[4]['msg'], '[RED] two\nlines')
        self.assertEqual([es[5][k] for k in ('ok', 'summary')], [True, '4 files'])
        self.assertEqual([es[7][k] for k in ('done', 'total', 'frac')], [None, None, None])
        self.assertFalse(es[8]['ok'])
        self.assertIn('Pokémon', self.out.getvalue())   # not escaped

    def test_count_held_back(self):
        self.prog.stage('rewrite', done=0, total=3, unit='modules')
        self.now += 1; self.prog.set(done=1)
        self.now += 0.1; self.prog.set(done=2)   # within JSON_INTERVAL of the last event
        self.prog._tick(OneTick())
        self.assertEqual([e['done'] for e in self.events('progress')], [0, 1])
        self.now += 0.5; self.prog._tick(OneTick())   # the ticker sends it
        self.assertEqual([e['done'] for e in self.events('progress')], [0, 1, 2])
        self.prog.set(done=3); self.prog.end()   # held back again, then sent before stage_end
        es = self.events()
        self.assertEqual([es[-2][k] for k in ('done', 'frac')], [3, 0.99])
        self.assertEqual(es[-1]['ev'], 'stage_end')

    def test_no_prompt(self):
        with mock.patch.object(nsp, 'in_ipython', return_value=True), mock.patch('builtins.input') as inp:
            with self.assertRaisesRegex(nsp.BuildError, 'does not prompt'): nsp.ask('NSP folder: ', 'the NSP folder')
        inp.assert_not_called()

    def test_failed_step(self):
        self.prog.stage('child')
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / 'child.log'
            with self.assertRaisesRegex(nsp.BuildError, 'exit code 7'):
                nsp.run([sys.executable, '-c', 'import sys; print("out"); print("err", file=sys.stderr); sys.exit(7)'], log)
            self.assertEqual(sorted(log.read_text().split()), ['err', 'out'])
        es = self.events()
        self.assertEqual([e['ev'] for e in es], ['stage', 'progress', 'stage_end', 'say'])
        self.assertFalse(es[2]['ok'])
        self.assertTrue('out' in es[3]['msg'] and 'err' in es[3]['msg'])

class Cli(unittest.TestCase):
    def test_argument_error_precedes_json_mode(self):
        r = subprocess.run([sys.executable, '-B', str(SCRIPT), '--progress', 'json', '--invalid-option'],
                           capture_output=True, text=True, timeout=30)
        self.assertEqual((r.returncode, r.stdout), (2, ''))
        self.assertIn('usage:', r.stderr)
        self.assertIn('unrecognized arguments: --invalid-option', r.stderr)

    def test_json_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            r = subprocess.run([sys.executable, '-B', str(SCRIPT), '--progress', 'json', str(Path(tmp) / 'missing'), '-k', str(Path(tmp) / 'keys')],
                               capture_output=True, text=True, timeout=30)
        self.assertEqual((r.returncode, r.stderr), (1, ''))
        es = [json.loads(l) for l in r.stdout.splitlines()]
        self.assertTrue(es and all(e['ev'] == 'say' for e in es))
        self.assertIn('[RED] not a folder:', es[-1]['msg'])

class HumanModes(unittest.TestCase):
    def test_lines(self):
        for mode in ('bar', 'lines', 'off'):
            with self.subTest(mode=mode), contextlib.redirect_stdout(io.StringIO()) as out:
                prog = nsp.Progress(mode); prog.plan(1)
                prog.stage('compile', done=0, total=10); ticker = prog.ticker
                prog.set(step='writing', done=1); prog.say('message'); prog.close()
                if ticker: ticker.join(2); self.assertFalse(ticker.is_alive())
            text = out.getvalue()
            self.assertIn('message', text)
            self.assertIn('✓ [1/1] compile', text)
            self.assertEqual('\r' in text, mode == 'bar')
            self.assertEqual(ticker is None, mode == 'off')

if __name__ == '__main__':
    unittest.main()
