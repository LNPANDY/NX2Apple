"""tools/verify: the expectations stay bound to their checks, and the checks of a Mac read a Mac the way the engine does."""
import re
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools/verify'))
import verify  # noqa: E402

MARK = 'expects: '   # written apart, so this file's fixtures are not read as markers


class ExpectationsMap(unittest.TestCase):
    def test_every_expectation_is_checked_or_marked(self):
        """The one rule (tools/verify/README.md): every expectation has a test or a gap or manual mark, every marker names an
        expectation, a gap's test expects its failure and a holding expectation's test does not."""
        problems = verify.lint()
        self.assertEqual(problems, [], '\n' + '\n'.join(problems))

    def test_the_number_of_expectations_is_what_list_prints(self):
        exps, problems = verify.load_expectations()
        self.assertEqual(problems, [])
        self.assertGreater(len(exps), 40)
        self.assertTrue(all(e['id'].startswith(e['feature'] + '-') for e in exps.values()))


class Rules(unittest.TestCase):
    """Each rule on a small repository of its own."""

    def tree(self, expectations, swift='', python=''):
        root = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: __import__('shutil').rmtree(root))
        (root / 'tools/verify/expectations').mkdir(parents=True)
        (root / 'tools/verify/expectations/demo.md').write_text('# Demo\n\n' + expectations)
        (root / 'frontend/Tests/T').mkdir(parents=True)
        (root / 'frontend/Tests/T/DemoTests.swift').write_text('final class DemoTests: XCTestCase {\n' + swift + '}\n')
        (root / 'tools/tests').mkdir(parents=True)
        (root / 'tools/tests/test_demo.py').write_text('class Demo(unittest.TestCase):\n' + python)
        (root / 'tools/verify/verify.py').write_text('')
        return root

    def test_an_expectation_without_a_test_is_a_problem(self):
        root = self.tree('- demo-01: Always true.\n')
        self.assertTrue(any('demo-01 has no test' in p for p in verify.lint(root)))

    def test_a_marked_expectation_needs_no_test(self):
        root = self.tree('- demo-01: Not yet. (gap: #1)\n- demo-02: By hand. (manual)\n')
        self.assertEqual(verify.lint(root), [])

    def test_a_marker_binds_the_test_under_it(self):
        root = self.tree('- demo-01: Always true.\n', swift=f'    // {MARK}demo-01\n    @MainActor func testIt() {{}}\n',
                         python=f'    # {MARK}demo-01\n    def test_it(self):\n        pass\n')
        self.assertEqual(verify.lint(root), [])
        tests = sorted((m['cls'], m['test']) for m in verify.scan_markers(root))
        self.assertEqual(tests, [('Demo', 'test_it'), ('DemoTests', 'testIt')])

    def test_a_marker_naming_no_expectation_is_a_problem(self):
        root = self.tree('- demo-01: By hand. (manual)\n', swift=f'    // {MARK}demo-07\n    func testIt() {{}}\n')
        self.assertTrue(any('demo-07 is not an expectation' in p for p in verify.lint(root)))

    def test_a_gap_test_must_expect_its_failure(self):
        plain = f'    // {MARK}demo-01\n    func testIt() {{ XCTAssertTrue(false) }}\n'
        root = self.tree('- demo-01: Not yet. (gap: #1)\n', swift=plain)
        self.assertTrue(any('must expect the failure' in p for p in verify.lint(root)))
        expecting = f'    // {MARK}demo-01\n    func testIt() {{\n        XCTExpectFailure("#1") {{ XCTAssertTrue(false) }}\n    }}\n'
        self.assertEqual(verify.lint(self.tree('- demo-01: Not yet. (gap: #1)\n', swift=expecting)), [])

    def test_a_holding_expectation_must_not_expect_a_failure(self):
        py = f'    # {MARK}demo-01\n    @unittest.expectedFailure\n    def test_it(self):\n        pass\n'
        root = self.tree('- demo-01: Always true.\n', python=py)
        self.assertTrue(any('holds, but its test expects a failure' in p for p in verify.lint(root)))

    def test_a_line_that_is_not_an_expectation_is_a_problem(self):
        root = self.tree('- demo-1: no two digits\n- other-01: wrong file\n')
        problems = verify.lint(root)
        self.assertTrue(any('not "- <feature>-NN' in p for p in problems))
        self.assertTrue(any('does not start with the file name' in p for p in problems))


class Results(unittest.TestCase):
    def test_the_three_output_formats_are_read(self):
        text = '\n'.join([
            "Test Case '-[NX2AppleTests.SaveTransferTests testA]' passed (0.010 seconds).",
            "Test Case '-[NX2AppleTests.SaveTransferTests testB]' failed (0.020 seconds).",
            '✔ Test envFileParsing() passed after 0.001 seconds.',
            '✘ Test settingsAndCloudFolderAreSet() failed after 0.002 seconds with 1 issue.',
            'test_ok (test_demo.Demo.test_ok) ... ok',
            'test_doc (test_demo.Demo.test_doc)',
            'A docstring line ... FAIL',
            'test_gap (test_demo.Demo.test_gap) ... expected failure',
            '✔ Test everyKeyHasEveryLanguage(folder:) with 2 test cases passed after 0.002 seconds.',
            'test_loud (test_demo.Demo.test_loud) ... what the test printed',
            'ok',
            'test_skip (test_demo.Demo.test_skip) ... skipped \'no swift\'',
        ])
        self.assertEqual(verify.parse_results(text), {
            'SaveTransferTests.testA': 'pass', 'SaveTransferTests.testB': 'fail', '*.envFileParsing': 'pass',
            '*.settingsAndCloudFolderAreSet': 'fail', 'Demo.test_ok': 'pass', 'Demo.test_doc': 'fail', 'Demo.test_gap': 'pass',
            '*.everyKeyHasEveryLanguage': 'pass', 'Demo.test_loud': 'pass', 'Demo.test_skip': 'skip'})

    def test_a_gap_whose_test_fails_is_reported_as_possibly_closed(self):
        e = dict(id='x-01', manual=False, gap='#1')
        self.assertEqual(verify.evaluate(e, {'x-01': [('pass', '')]})[0], 'gap')
        state, note = verify.evaluate(e, {'x-01': [('fail', 'T.t fail')]})
        self.assertEqual(state, 'FAIL')
        self.assertIn('may be closed', note)


class TheMacOfIssue490(unittest.TestCase):
    """The checks of a Mac, on the home folder of #490 (tools/verify/fixtures/home-490.json)."""

    def setUp(self):
        self.home = tempfile.mkdtemp()
        self.addCleanup(lambda: __import__('shutil').rmtree(self.home))
        verify.unpack_fixture('home-490', self.home)
        self.mac = verify.Machine(home=self.home)

    def test_the_sync_folder_exists_and_holds_the_save(self):
        self.assertEqual(verify.run_step('step_cloud_sync_folders', self.mac)[0], 'pass')
        self.assertEqual(verify.run_step('step_icloud_drive', self.mac)[0], 'pass')

    def test_the_iphones_newer_save_in_another_folder_is_found(self):
        result, note = verify.run_step('step_one_sync_folder_per_game', self.mac)
        self.assertEqual(result, 'fail')
        self.assertIn('nxnative Saves holds a newer save', note)

    def test_dm_save_in_env_txt_is_named(self):
        result, note = verify.run_step('step_env_dm_save', self.mac)
        self.assertEqual(result, 'fail')
        self.assertIn('01006BB00C6F0000: DM_SAVE=', note)

    def test_env_txt_lines_that_hide_saved_choices_are_named(self):
        result, note = verify.run_step('step_env_hides_saved_choice', self.mac)
        self.assertEqual(result, 'fail')
        self.assertIn('DM_METAL_HUD, DM_PRESENT_UPSCALE', note)
        self.assertNotIn('DM_LANG', note)

    def test_the_checks_of_the_machine_itself_are_skipped_for_another_home(self):
        for step in verify.MACHINE_WIDE:
            self.assertEqual(verify.run_step(step, self.mac)[0], 'skip')

    def test_env_txt_is_read_as_the_engine_reads_it(self):
        env = verify.read_env('# DM_SAVE_SYNC=icloud\n  DM_SAVE_SYNC = /a  \nDM_SAVE_SYNC=/b\n=x\nnoequals\nDM_X=1\r\n')
        self.assertEqual(env, {'DM_SAVE_SYNC': '/a', 'DM_X': '1'})

    def test_the_keyword_and_the_games_own_folder_resolve_as_the_engine_does(self):
        drive = Path(self.home) / 'Library/Mobile Documents/com~apple~CloudDocs'
        self.assertEqual(self.mac.sync_folder('0100', {'DM_SAVE_SYNC': 'icloud'})[0], drive / 'nxnative Saves')
        self.assertEqual(self.mac.sync_folder('0100', {'DM_SAVE_SYNC': '0'})[0], None)
        own = drive / 'nxnative_launcher/01006BB00C6F0000'
        self.assertIsNotNone(verify.save_file(own, '01006BB00C6F0000'), 'a folder named after the game is the game\'s folder')


class ReleaseRules(unittest.TestCase):
    # expects: release-03
    def test_the_app_version_has_its_changelog_row(self):
        version = re.search(r'appVersion = "([^"]+)"', (ROOT / 'frontend/Sources/NX2Apple/ContentView.swift').read_text()).group(1)
        self.assertIn(f'| v{version} |', (ROOT / 'CHANGELOG.md').read_text())


if __name__ == '__main__':
    unittest.main()
