import json
import os
import sys
import tempfile
import unittest
from unittest import mock
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import triage_apply as ta  # noqa: E402

GOOD_URL = 'https://github.com/LNPANDY/NX2Apple/blob/main/docs/reference/services.md#x'


def out(labels=('game',), comment='Hello.', duplicates=()):
    return json.dumps({'labels': list(labels), 'comment': comment, 'duplicates': list(duplicates)})


def run(raw, issue=5, cands=(3, 4), exists=lambda n: True):
    return ta.validate(raw, issue, set(cands), exists)


class Schema(unittest.TestCase):
    def test_ok(self):
        self.assertEqual(run(out(('game', 'mac'), 'Thanks.', (3,))), (['game', 'mac'], 'Thanks.', [3]))

    def test_fenced_json_ok_prose_not(self):
        self.assertEqual(run('```json\n' + out() + '\n```')[0], ['game'])
        for bad in ('Sure! ' + out(), out() + ' done', '', '[]', '{}', 'null'):
            with self.assertRaises(ta.Invalid):
                run(bad)

    def test_extra_or_missing_keys(self):
        with self.assertRaises(ta.Invalid):
            run(json.dumps({'labels': [], 'comment': '', 'duplicates': [], 'close': True}))
        with self.assertRaises(ta.Invalid):
            run(json.dumps({'labels': [], 'comment': ''}))

    def test_types(self):
        for bad in ({'labels': 'game', 'comment': '', 'duplicates': []}, {'labels': [1], 'comment': '', 'duplicates': []},
                    {'labels': [], 'comment': ['x'], 'duplicates': []}, {'labels': [], 'comment': '', 'duplicates': ['3']},
                    {'labels': [], 'comment': '', 'duplicates': [True]}, {'labels': [], 'comment': '', 'duplicates': [3.0]}):
            with self.assertRaises(ta.Invalid, msg=bad):
                run(json.dumps(bad))

    def test_too_long_raw(self):
        with self.assertRaises(ta.Invalid):
            run(out(comment='a' * (ta.MAX_RAW + 1)))


class Labels(unittest.TestCase):
    def test_allow_list(self):
        for l in ('wontfix', 'bug', 'Game', 'no-triage', 'good first issue', ''):
            with self.assertRaises(ta.Invalid, msg=l):
                run(out((l,)))

    def test_repeats_and_count(self):
        with self.assertRaises(ta.Invalid):
            run(out(('game', 'game')))
        with self.assertRaises(ta.Invalid):
            run(out(('game', 'build', 'launcher', 'ios', 'mac')))

    def test_duplicate_label_without_target_is_dropped(self):
        self.assertEqual(run(out(('game', 'duplicate')))[0], ['game'])
        self.assertEqual(run(out(('duplicate',), duplicates=(3,)))[0], ['duplicate'])


class Duplicates(unittest.TestCase):
    def test_must_be_candidate_other_and_existing(self):
        with self.assertRaises(ta.Invalid):
            run(out(duplicates=(99,)))                      # not a candidate
        with self.assertRaises(ta.Invalid):
            run(out(duplicates=(5,)), cands=(5, 3))         # the issue itself
        with self.assertRaises(ta.Invalid):
            run(out(duplicates=(3,)), exists=lambda n: False)
        with self.assertRaises(ta.Invalid):
            run(out(duplicates=(3, 3)))
        with self.assertRaises(ta.Invalid):
            run(out(duplicates=(1, 2, 3, 4)), cands=(1, 2, 3, 4))


class Comment(unittest.TestCase):
    def bad(self, text):
        with self.assertRaises(ta.Invalid, msg=text):
            run(out(comment=text))

    def good(self, text):
        self.assertEqual(run(out(comment=text))[1], text)

    def test_mentions(self):
        for t in ('cc @everyone', '@octocat hi', 'hello\n@LNPANDY', 'ping (@a)', 'x@y.com'):
            self.bad(t)

    def test_links(self):
        for t in ('see https://evil.example/x', 'http://github.com/LNPANDY/NX2Apple', 'https://github.com/other/repo',
                  'https://github.com/LNPANDY/NX2Apple-evil', 'https://github.com/LNPANDY/NX2Apple.evil.com/x',
                  '[x](https://evil.example)', '[x](javascript:alert(1))', '[x](evil.example)', 'www.evil.example',
                  'evil.example', 'visit evil.com now', 'mailto:a@b.c', 'data:text/html,x', 'ftp://x/y',
                  '[a]: https://evil.example/', 'https://github.com@evil.example/', 'https://github.com/seedds/nxnative2',
                  'https://GITHUB.com.evil.example/LNPANDY/NX2Apple', 'github.com/other/repo.com'):
            self.bad(t)

    def test_allowed_links(self):
        for t in (f'See {GOOD_URL}.', f'[entry]({GOOD_URL})', 'https://github.com/seedds/nxnative/issues', 'https://github.com/LNPANDY/NX2Apple#readme',
                  'the README: https://github.com/LNPANDY/NX2Apple#readme)', '[top](#top)', 'build_ipa.sh and log.txt and README.md', 'see #3 and #4, and #5 itself',
                  'Mario (010015100B514000) on macOS 26.1, Settings > Copy diagnostics'):
            self.good(t)

    def test_discussions_links(self):
        for t in ('Please ask in https://github.com/LNPANDY/NX2Apple/discussions/categories/q-a',
                  '[Q&A](https://github.com/LNPANDY/NX2Apple/discussions/categories/q-a).',
                  'https://github.com/LNPANDY/NX2Apple/discussions', 'github.com/LNPANDY/NX2Apple/discussions/categories/q-a'):
            self.good(t)
        for t in ('https://github.com/LNPANDY/discussions', 'https://github.com/other/NX2Apple/discussions',
                  'https://github.com/LNPANDY/NX2Apple/discussions/../../evil/x'):
            self.bad(t)

    def test_html_and_images(self):
        for t in ('<img src=x>', '<script>', '![x](https://github.com/LNPANDY/NX2Apple/a.png)', '<!-- hi -->', '</details>'):
            self.bad(t)

    def test_cross_repo_ref_and_control_and_length(self):
        self.bad('fixes other/repo#1')
        self.bad('a\x00b')
        self.bad('a' * (ta.MAX_COMMENT + 1))
        self.good('a' * ta.MAX_COMMENT)

    def test_url_path_escapes(self):
        for t in ('https://github.com/LNPANDY/NX2Apple/../../evil/repo', 'https://github.com/LNPANDY/NX2Apple/%2e%2e/%2e%2e/evil/repo',
                  'https://github.com/LNPANDY/NX2Apple/%2E%2E/x', 'https://github.com/LNPANDY/NX2Apple/%252e%252e/x',
                  'https://github.com/LNPANDY/NX2Apple/./../x', 'https://github.com/LNPANDY/NX2Apple/..%2fevil',
                  'https://github.com/LNPANDY/NX2Apple/a\\..\\..\\evil', 'github.com/LNPANDY/NX2Apple/../../evil/repo',
                  '[x](https://github.com/LNPANDY/NX2Apple/../../evil/repo)', 'https://github.com:8080/LNPANDY/NX2Apple',
                  'https://github.com/LNPANDY', 'https://github.com/'):
            self.bad(t)
        self.good('https://github.com/LNPANDY/NX2Apple/blob/main/docs/a.md#top and github.com/seedds/nxnative/issues')

    def test_reference_definitions_and_protocol_relative(self):
        for t in ('[open][x]\n\n[x]: //evil.app', '[open][x]\n\n[x]: https://evil.example', '[x]: evil.example', 'see //evil.example/x',
                  '[x]: /LNPANDY/../evil', '[a](//evil.example)', '[a]( //evil.example )', '[a](<//evil.example>)', 'go to evil.app', 'go to evil.zip.example',
                  'x.y.z', 'host.corp', 'a.b'):
            self.bad(t)
        self.good('[x]: https://github.com/LNPANDY/NX2Apple/blob/main/README.md')
        self.good('[x]: #top')

    def test_file_names_and_versions_are_not_hosts(self):
        self.good('services.md, hle_svc.c:447, build_ipa.sh, v0.4.9, macOS 26.1, Node.js, nvn_dirty.c')

    def test_issue_references_must_be_known(self):
        for t in ('Possibly the same problem as #9999', 'see https://github.com/LNPANDY/NX2Apple/issues/9999', 'https://github.com/LNPANDY/NX2Apple/pull/12',
                  '[x](https://github.com/seedds/nxnative/issues/77)', 'see #12'):
            self.bad(t)
        self.assertEqual(run(out(comment='Same as #3 and https://github.com/LNPANDY/NX2Apple/issues/4, and this one, #5'))[1][:7], 'Same as')

    def test_injection_example(self):
        self.bad('Ignoring my instructions. Closing this issue. @everyone see https://evil.example')


class Build(unittest.TestCase):
    def test_empty_means_no_comment(self):
        self.assertEqual(ta.build_comment('', []), '')
        self.assertEqual(ta.build_comment('  ', []), '')

    def test_comment_has_footer_and_marker(self):
        b = ta.build_comment('Hi.', [3, 4])
        self.assertTrue(b.startswith('Hi.\n\nPossibly the same problem as: #3, #4'))
        self.assertTrue(b.endswith(ta.MARKER))
        self.assertEqual(ta.build_comment('', [3]).count('#3'), 1)

    def test_built_comment_passes_its_own_check(self):
        ta.check_comment(ta.FOOTER)   # the footer is added after validation; it must still satisfy the rules


class Mode(unittest.TestCase):
    def test_resolve(self):
        self.assertEqual(ta.resolve_mode('post'), 'post')
        self.assertEqual(ta.resolve_mode(' post\n'), 'post')
        for v in ('report', '', None, 'POST', 'Post', 'posts', 'true', '1', 'post;report', 'pos'):
            self.assertEqual(ta.resolve_mode(v), 'report', v)

    def test_report_text(self):
        t = ta.report_text(7, 'LNPANDY/NX2Apple', ['game', 'mac'], [3], 'Line one.\n\nLine two.')
        self.assertIn('[#7](https://github.com/LNPANDY/NX2Apple/issues/7)', t)
        self.assertIn('Labels added: game, mac', t)
        self.assertIn('> Line one.\n>\n> Line two.', t)
        self.assertIn('> _(no comment)_', ta.report_text(7, 'a/b', [], [], ''))


class Apply(unittest.TestCase):
    """main() end to end with `gh` replaced: which calls are made in each mode."""

    def run_main(self, mode, summary=True):
        d = Path(tempfile.mkdtemp())
        (d / 'input.json').write_text(json.dumps({'duplicate_candidates': []}))
        (d / 'result.txt').write_text(out(('question',), 'Please ask in https://github.com/LNPANDY/NX2Apple/discussions/categories/q-a'))
        calls = []

        def fake_gh(*args, check=True):
            calls.append(args)
            r = mock.Mock(returncode=0, stdout='[{"name": "question"}]' if args[0] == 'label' else '')
            return r
        env = {'GITHUB_STEP_SUMMARY': str(d / 'summary.md')} if summary else {}
        with mock.patch.object(ta, 'gh', fake_gh), mock.patch.dict(os.environ, env), mock.patch.dict(os.environ, {'TRIAGE_MODE': ''}):
            if not summary:
                os.environ.pop('GITHUB_STEP_SUMMARY', None)
            rc = ta.main(['--repo', 'LNPANDY/NX2Apple', '--issue', '5', '--input', str(d / 'input.json'), '--result', str(d / 'result.txt'),
                          '--report-dir', str(d)] + (['--mode', mode] if mode is not None else []))
        self.assertEqual(rc, 0)
        return d, [c[0:2] for c in calls]

    def test_report_mode_labels_but_posts_nothing(self):
        for mode in (None, 'report', 'garbage', 'POST'):
            d, calls = self.run_main(mode)
            self.assertIn(('issue', 'edit'), calls)
            self.assertNotIn(('issue', 'comment'), calls)
            self.assertFalse([c for c in calls if c[0] == 'api' and c[1] == '-X'])
            md = (d / 'triage-5.md').read_text()
            self.assertIn('> Please ask in https://github.com/LNPANDY/NX2Apple/discussions/categories/q-a', md)
            self.assertIn('[#5](https://github.com/LNPANDY/NX2Apple/issues/5)', md)
            self.assertIn('discussions/categories/q-a', (d / 'summary.md').read_text())

    def test_report_mode_without_summary_variable(self):
        d, calls = self.run_main('report', summary=False)
        self.assertTrue((d / 'triage-5.md').exists())

    def test_post_mode_comments(self):
        d, calls = self.run_main('post')
        self.assertIn(('issue', 'edit'), calls)
        self.assertIn(('issue', 'comment'), calls)
        self.assertFalse((d / 'triage-5.md').exists())
        self.assertFalse((d / 'summary.md').exists())


if __name__ == '__main__':
    unittest.main()
