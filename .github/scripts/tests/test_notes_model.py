import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import notes_model as nm  # noqa: E402

ROOT = Path(__file__).resolve().parents[3]
LIST = ['claude-sonnet-5.5', 'claude-sonnet-5', 'claude-sonnet-4.6', 'claude-sonnet-4.5']


def refused(model):
    return 1, '', 'Error: Model "%s" from --model flag is not available.\n' % model


class Fake:
    """A runner that accepts only some ids and records the calls."""
    def __init__(self, accepted=(), other_failure=()):
        self.accepted, self.other, self.calls = set(accepted), set(other_failure), []

    def __call__(self, model):
        self.calls.append(model)
        if model in self.accepted:
            return 0, 'the notes\n', ''
        if model in self.other:
            return 2, '', 'Error: authentication failed'
        return refused(model)


class Chain(unittest.TestCase):
    def run_chain(self, fake, ids=LIST):
        logs = []
        return nm.run_chain(ids, fake, logs.append), logs

    def test_first_id_works(self):
        fake = Fake(LIST)
        (model, out), _ = self.run_chain(fake)
        self.assertEqual((model, out, fake.calls), ('claude-sonnet-5.5', 'the notes\n', ['claude-sonnet-5.5']))

    def test_goes_on_after_not_available(self):
        fake = Fake(['claude-sonnet-4.6'])
        (model, _), logs = self.run_chain(fake)
        self.assertEqual((model, fake.calls), ('claude-sonnet-4.6', LIST[:3]))
        self.assertTrue(any('copilot said: Error: Model "claude-sonnet-5.5" from --model flag is not available.' in l for l in logs))

    def test_none_available(self):
        fake = Fake()
        with self.assertRaises(nm.ChainError) as c:
            self.run_chain(fake)
        self.assertEqual(fake.calls, LIST)
        self.assertIn('none of the models', str(c.exception))

    def test_other_failure_stops_the_chain(self):
        fake = Fake(['claude-sonnet-4.5'], other_failure=['claude-sonnet-5'])
        with self.assertRaises(nm.ChainError):
            self.run_chain(fake)
        self.assertEqual(fake.calls, ['claude-sonnet-5.5', 'claude-sonnet-5'])

    def test_message_is_matched_on_stdout_too(self):
        run = lambda m: (1, 'Error: Model "%s" from --model flag is not available.' % m, '') if m == 'a' else (0, 'ok', '')
        self.assertEqual(nm.run_chain(['a', 'b'], run, lambda s: None), ('b', 'ok'))

    def test_a_similar_message_is_not_a_model_error(self):
        self.assertFalse(nm.is_not_available('Error: rate limit, the service is not available'))
        self.assertFalse(nm.is_not_available('Model rejected'))
        self.assertTrue(nm.is_not_available('Error: Model "x-1.0" from --model flag is not available.'))


class Candidates(unittest.TestCase):
    def test_list_is_fine(self):
        self.assertEqual(nm.check_candidates(LIST), LIST)

    def test_no_haiku_no_auto_in_the_list(self):
        for bad in ('claude-haiku-4.5', 'Claude-HAIKU-5.5', 'auto', 'AUTO'):
            with self.assertRaises(nm.ChainError, msg=bad):
                nm.check_candidates(['claude-sonnet-5.5', bad])

    def test_not_an_id(self):
        for bad in ('', '-x', 'a b'.split()[0] + ';rm', 'x' * 65, '$(id)'):
            with self.assertRaises(nm.ChainError, msg=bad):
                nm.check_candidates([bad])

    def test_empty_list(self):
        with self.assertRaises(nm.ChainError):
            nm.check_candidates([])

    def test_override_is_validated_like_triage_model(self):
        self.assertEqual(nm.check_candidates(['gpt-5.4'], override=True), ['gpt-5.4'])
        with self.assertRaises(nm.ChainError):
            nm.check_candidates(['bad id;'], override=True)

    def test_workflow_list_is_clean_and_newest_first(self):
        text = (ROOT / '.github/workflows/release-notes.yml').read_text(encoding='utf-8')
        line = next(l for l in text.splitlines() if l.strip().startswith('NOTES_MODEL_CANDIDATES:'))
        ids = line.split(':', 1)[1].split('#')[0].strip().strip("'\"").split()
        self.assertEqual(nm.check_candidates(ids), ids)
        self.assertEqual(ids[0], 'claude-sonnet-5.5')
        self.assertTrue(all('sonnet' in i for i in ids))


class Main(unittest.TestCase):
    def go(self, runner, *extra):
        with tempfile.TemporaryDirectory() as d:
            prompt, out, gh = (os.path.join(d, n) for n in ('prompt.txt', 'answer.txt', 'gh_out'))
            Path(prompt).write_text('p', encoding='utf-8')
            with mock.patch.object(nm, 'copilot_runner', return_value=runner), mock.patch.dict(os.environ, {'GITHUB_OUTPUT': gh}):
                code = nm.main(['--prompt', prompt, '--out', out, *extra])
            read = lambda p: Path(p).read_text(encoding='utf-8') if os.path.exists(p) else None
            return code, read(out), read(os.path.join(d, 'model.txt')), read(gh)

    def test_success_writes_answer_model_and_outputs(self):
        code, answer, model, gh = self.go(Fake(['claude-sonnet-5']), '--candidates', ' '.join(LIST))
        self.assertEqual((code, answer, model, gh), (0, 'the notes\n', 'claude-sonnet-5\n', 'ran=true\nmodel=claude-sonnet-5\n'))

    def test_override_has_no_fallback(self):
        fake = Fake(['claude-sonnet-5.5'])
        code, answer, _, gh = self.go(fake, '--candidates', ' '.join(LIST), '--override', 'gpt-5.4')
        self.assertEqual((code, answer, gh), (1, None, None))
        self.assertEqual(fake.calls, ['gpt-5.4'])

    def test_failure_writes_nothing(self):
        code, answer, model, gh = self.go(Fake(), '--candidates', ' '.join(LIST))
        self.assertEqual((code, answer, model, gh), (1, None, None, None))


if __name__ == '__main__':
    unittest.main()
