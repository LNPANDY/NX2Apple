import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import notes_finish as nf  # noqa: E402

ROOT = Path(__file__).resolve().parents[3]
GOOD = """**v1.0.0: The iPhone and iPad app / iPhone 和 iPad 版发布**

## English

**New**
- **A shell app**: one app holds all your games (#226)

## 中文

**新增**
- **外壳应用**：一个应用装下所有游戏（#226）
"""


class Clean(unittest.TestCase):
    def test_plain_text_is_kept(self):
        self.assertEqual(nf.clean(GOOD), GOOD)

    def test_fence_around_everything_is_removed(self):
        self.assertEqual(nf.clean('```markdown\n' + GOOD + '```\n'), GOOD)
        self.assertEqual(nf.clean('```\n' + GOOD + '\n```'), GOOD)

    def test_inner_fence_stays(self):
        text = 'a\n```\ncode\n```\nb\n'
        self.assertEqual(nf.clean(text), text)

    def test_crlf_bom_and_blank_edges(self):
        self.assertEqual(nf.clean('﻿\n\na\r\nb\n\n\n'), 'a\nb\n')

    def test_empty(self):
        self.assertEqual(nf.clean(' \n\n'), '')


class Title(unittest.TestCase):
    def title(self, text, tag='v1.0.0'):
        return nf.title_from(text, tag)

    def test_title_of_the_template_line(self):
        self.assertEqual(self.title(GOOD), 'v1.0.0: The iPhone and iPad app / iPhone 和 iPad 版发布')

    def test_trailing_full_stops_go(self):
        self.assertEqual(self.title('**v1.0.0: The app. / 应用。**\n'), 'v1.0.0: The app / 应用')

    def test_other_version_is_refused(self):
        self.assertEqual(self.title(GOOD, 'v1.0.1'), '')

    def test_line_must_be_first_and_bold(self):
        self.assertEqual(self.title('Here are the notes\n' + GOOD), '')
        self.assertEqual(self.title('v1.0.0: The app / 应用\n'), '')

    def test_both_languages_needed(self):
        self.assertEqual(self.title('**v1.0.0: The app**\n'), '')
        self.assertEqual(self.title('**v1.0.0:  / 应用**\n'), '')

    def test_unsafe_titles_are_refused(self):
        for line in ('**v1.0.0: The `app` / 应用**', '**v1.0.0: Thanks @LNPANDY / 应用**', '**v1.0.0: Fix #5 / 应用**', '**v1.0.0: <b>x</b> / y**'):
            self.assertEqual(self.title(line + '\n'), '', line)

    def test_too_long(self):
        self.assertEqual(self.title('**v1.0.0: %s / 应用**\n' % ('x' * 200)), '')

    def test_template_placeholder_is_not_a_title(self):
        self.assertEqual(self.title('**vX.Y.Z: the one thing / x**\n'), '')


class Cli(unittest.TestCase):
    def run_cli(self, *args):
        return subprocess.run([sys.executable, '-I', str(ROOT / '.github/scripts/notes_finish.py'), *args], capture_output=True, text=True)

    def test_clean_and_title(self):
        with tempfile.TemporaryDirectory() as d:
            raw, out = os.path.join(d, 'raw'), os.path.join(d, 'out')
            Path(raw).write_text('```\n' + GOOD + '```\n', encoding='utf-8')
            self.assertEqual(self.run_cli('clean', raw, out).returncode, 0)
            self.assertEqual(Path(out).read_text(encoding='utf-8'), GOOD)
            r = self.run_cli('title', out, 'v1.0.0')
            self.assertEqual(r.stdout.strip(), 'v1.0.0: The iPhone and iPad app / iPhone 和 iPad 版发布')

    def test_empty_answer_fails(self):
        with tempfile.TemporaryDirectory() as d:
            raw = os.path.join(d, 'raw')
            Path(raw).write_text('\n', encoding='utf-8')
            self.assertEqual(self.run_cli('clean', raw, os.path.join(d, 'out')).returncode, 1)

    def test_missing_file_gives_no_title(self):
        r = self.run_cli('title', '/nonexistent/x.md', 'v1.0.0')
        self.assertEqual((r.returncode, r.stdout.strip()), (0, ''))

    def test_good_text_passes_the_release_notes_check(self):
        sys.path.insert(0, str(ROOT / 'tools'))
        import release_notes  # noqa: E402
        self.assertEqual(release_notes.check_text(GOOD), [])


if __name__ == '__main__':
    unittest.main()
