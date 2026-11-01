"""tools/release_notes.py: `check` accepts a notes file in the form of .github/release_notes_template.md and rejects each kind of bad file,
`previous` picks the newest final tag, and `build` writes the file, a `---` line and the generated notes unchanged, with a fake `gh` and no network."""
import importlib
import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

TOOLS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS))
N = importlib.import_module('release_notes')

GOOD = """**v1.2.3: the iPhone app.**

## 中文

**重点**

**iPhone 应用**
- 现在可以在 iPhone 上运行游戏
- 支持手柄

**修复**
- **修复崩溃**：启动时崩溃，现在不会了（#12）

## English

**Highlights**

**iPhone app**
- Games run on the iPhone now
- Controllers work

**Fixed**
- **Crash fixed**: it crashed at launch, now it does not (#12)

---

**Install:** download `NX2Apple-macOS-arm64.zip`, unzip, drag it to Applications. 中文：下载后解压，拖进「应用程序」。
"""

GENERATED = "## What's Changed\n* Fix a crash by @v0lumehi in #12\n\n**Full Changelog**: https://github.com/LNPANDY/NX2Apple/compare/v1.0.0...v1.2.3"

FAKE_GH = """#!/bin/sh
printf '%s\\n' "$@" > "$FAKE_GH_ARGS"
if [ -n "$FAKE_GH_FAIL" ]; then echo "HTTP 500" >&2; exit 1; fi
cat "$FAKE_GH_BODY"
"""


def problems(text):
    return [m for _, m in N.check_text(text)]


class Check(unittest.TestCase):
    def test_good_file(self):
        self.assertEqual(N.check_text(GOOD), [])

    def test_the_template_itself_fails(self):
        template = TOOLS.parent / '.github' / 'release_notes_template.md'
        if template.exists():
            self.assertTrue(N.check_text(template.read_text(encoding='utf-8')))

    def test_emojis_and_symbols(self):
        for bad in ('\U0001f680', '⚠️', '→', '✓', '©', '\U0001f1e9\U0001f1ea', '1️⃣', '\U0001f44d\U0001f3fd', '™'):
            with self.subTest(bad=bad):
                self.assertTrue(any('emojis' in m for m in problems(GOOD.replace('Controllers work', 'Controllers work ' + bad))))

    def test_chinese_and_normal_punctuation_pass(self):
        self.assertEqual(N.check_text(GOOD.replace('Controllers work', 'Controllers work, "quoted" and it’s fine…')), [])

    def test_semicolons(self):
        for bad in (';', '；'):
            with self.subTest(bad=bad):
                self.assertTrue(any('semicolon' in m for m in problems(GOOD.replace('Controllers work', 'Controllers work' + bad + ' yes'))))

    def test_dashes(self):
        for bad in ('—', '–', '——'):
            with self.subTest(bad=bad):
                self.assertTrue(any('dash' in m for m in problems(GOOD.replace('Controllers work', 'Controllers ' + bad + ' work'))))

    def test_sections(self):
        self.assertTrue(any('中文' in m and 'missing' in m for m in problems(GOOD.replace('## 中文', '## Chinese'))))
        self.assertTrue(any('English' in m and 'missing' in m for m in problems(GOOD.replace('## English', '## Englisch'))))
        zh, en = GOOD.split('## English')
        swapped = '## English' + en.split('---')[0] + '\n' + zh.replace('## 中文', '## 中文', 1)
        self.assertTrue(any('comes first' in m for m in problems(swapped)))
        self.assertTrue(any('empty' in m for m in problems(GOOD.split('**重点**')[0] + '## English\n\ntext\n')))

    def test_leftovers(self):
        for bad in ('<!-- a comment -->', 'vX.Y.Z', 'X.Y.Z', 'see #N', 'TODO', 'One point', '一个要点'):
            with self.subTest(bad=bad):
                self.assertTrue(any('template' in m for m in problems(GOOD.replace('Controllers work', bad))))

    def test_generated_block_does_not_belong_in_the_file(self):
        self.assertTrue(any('generated' in m or 'Full Changelog' in m for m in problems(GOOD + '\n' + GENERATED)))

    def test_check_file_cli(self):
        with tempfile.TemporaryDirectory() as d:
            good, bad = Path(d, 'v1.2.3.md'), Path(d, 'v1.2.4.md')
            good.write_text(GOOD, encoding='utf-8')
            bad.write_text(GOOD + '\n\U0001f680\n', encoding='utf-8')
            self.assertEqual(N.main(['check', str(good)]), 0)
            self.assertEqual(N.main(['check', str(good), str(bad)]), 1)
            self.assertEqual(N.main(['check', str(Path(d, 'missing.md'))]), 1)
            Path(d, 'binary.md').write_bytes(b'\xff\xfe\x00')
            self.assertEqual(N.main(['check', str(Path(d, 'binary.md'))]), 1)


class Previous(unittest.TestCase):
    TAGS = ['v0.7.5', 'v0.8.0-rc1', 'v0.8.0-rc8', 'v1.0.0-rc1', 'v1.0.0', 'v1.0.0-rc2', 'v0.7.10', 'v0.7.9', 'nightly', 'v1.1.0-rc1']

    def test_newest_final_before(self):
        self.assertEqual(N.previous_final('v1.0.0', self.TAGS), 'v0.7.10')
        self.assertEqual(N.previous_final('v1.1.0', self.TAGS), 'v1.0.0')
        self.assertEqual(N.previous_final('v0.7.10', self.TAGS), 'v0.7.9')

    def test_none(self):
        self.assertEqual(N.previous_final('v0.7.5', ['v0.7.5', 'v0.8.0-rc1']), '')

    def test_not_a_final_tag(self):
        for tag in ('v1.0.0-rc1', '1.0.0', 'main'):
            with self.assertRaises(ValueError):
                N.previous_final(tag, self.TAGS)

    def test_remote_tags_skip_peeled_lines(self):
        out = 'abc\trefs/tags/v1.0.0\ndef\trefs/tags/v1.0.0^{}\n123\trefs/heads/main\n'
        with mock.patch('subprocess.run', return_value=mock.Mock(stdout=out)):
            self.assertEqual(N.remote_tags('origin'), ['v1.0.0'])


class Build(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        d = Path(self.tmp.name)
        self.bin = d / 'bin'
        self.bin.mkdir()
        gh = self.bin / 'gh'
        gh.write_text(FAKE_GH)
        gh.chmod(gh.stat().st_mode | stat.S_IXUSR)
        (d / 'generated.txt').write_text(GENERATED + '\n')
        self.args_file = d / 'gh-args.txt'
        self.notes = d / 'v1.2.3.md'
        self.short = d / 'short.md'
        self.short.write_text('NX2Apple v1.2.3\n\nThe files of the release candidate v1.2.3-rc1.\n')
        self.out = d / 'out.md'
        env = {'PATH': str(self.bin) + os.pathsep + os.environ['PATH'], 'FAKE_GH_ARGS': str(self.args_file), 'FAKE_GH_BODY': str(d / 'generated.txt')}
        patcher = mock.patch.dict(os.environ, env)
        patcher.start()
        self.addCleanup(patcher.stop)
        os.environ.pop('FAKE_GH_FAIL', None)

    def run_build(self, *extra):
        return N.main(['build', 'v1.2.3', '--out', str(self.out), '--previous', 'v1.0.0', '--repo', 'LNPANDY/NX2Apple', *extra])

    def test_notes_file_then_generated_block(self):
        self.notes.write_text(GOOD, encoding='utf-8')
        self.assertEqual(self.run_build('--file', str(self.notes), '--short-body', str(self.short)), 0)
        self.assertEqual(self.out.read_text(encoding='utf-8'), GOOD.strip() + '\n\n---\n\n' + GENERATED + '\n')
        self.assertEqual(self.args_file.read_text().split(), [
            'api', '-X', 'POST', 'repos/LNPANDY/NX2Apple/releases/generate-notes', '-f', 'tag_name=v1.2.3', '-f', 'previous_tag_name=v1.0.0', '--jq', '.body'])

    def test_missing_file_uses_the_short_body(self):
        self.assertEqual(self.run_build('--file', str(self.notes), '--short-body', str(self.short)), 0)
        self.assertEqual(self.out.read_text(), self.short.read_text().strip() + '\n\n---\n\n' + GENERATED + '\n')

    def test_no_previous_tag_leaves_the_argument_out(self):
        self.assertEqual(N.main(['build', 'v1.2.3', '--out', str(self.out), '--short-body', str(self.short)]), 0)
        self.assertNotIn('previous_tag_name', self.args_file.read_text())

    def test_bad_notes_file_fails_and_writes_nothing(self):
        self.notes.write_text(GOOD + '\n\U0001f680\n', encoding='utf-8')
        self.assertEqual(self.run_build('--file', str(self.notes), '--short-body', str(self.short)), 1)
        self.assertFalse(self.out.exists())

    def test_gh_failure_fails_and_writes_nothing(self):
        self.notes.write_text(GOOD, encoding='utf-8')
        with mock.patch.dict(os.environ, {'FAKE_GH_FAIL': '1'}):
            self.assertEqual(self.run_build('--file', str(self.notes)), 1)
        self.assertFalse(self.out.exists())

    def test_not_a_final_tag(self):
        self.assertEqual(N.main(['build', 'v1.2.3-rc1', '--out', str(self.out), '--short-body', str(self.short)]), 1)

    def test_nothing_to_build_from(self):
        self.assertEqual(self.run_build('--file', str(self.notes)), 1)


if __name__ == '__main__':
    unittest.main()
