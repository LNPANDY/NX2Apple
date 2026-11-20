"""The Swift design tokens are generated from frontend/design-tokens/tokens.json and must not go stale (LNPANDY/NX2Apple#1458)."""
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import design_tokens  # noqa: E402


class DesignTokensTests(unittest.TestCase):
    def test_committed_swift_matches_the_json(self):
        self.assertEqual(design_tokens.main(['--check']), 0, 'run python3 tools/design_tokens.py and commit the result')

    def test_every_group_the_launcher_reads_is_there(self):
        tokens = json.loads(design_tokens.TOKENS.read_text(encoding='utf-8'))
        for group in ('color', 'typography', 'spacing', 'radius', 'control', 'motion'):
            self.assertIn(group, tokens)
        sizes = [float(t['$value']['fontSize'].rstrip('px')) for _, t in design_tokens.leaves(tokens['typography'])]
        self.assertGreaterEqual(min(sizes), 11, 'no text below 11 pt')
        spaces = {float(t['$value'].rstrip('px')) for _, t in design_tokens.leaves(tokens['spacing'])}
        self.assertEqual(spaces, {4, 8, 12, 16, 24, 32})

    def test_console_mode_has_its_own_ten_foot_scale(self):
        tokens = json.loads(design_tokens.TOKENS.read_text(encoding='utf-8'))
        console = tokens['console']
        sizes = [float(t['$value']['fontSize'].rstrip('px')) for _, t in design_tokens.leaves(console['typography'])]
        self.assertGreaterEqual(min(sizes), 15, 'nothing in console mode is smaller than 15 pt')
        swift = design_tokens.expected()
        self.assertIn('package enum Console {', swift)
        self.assertIn('package static let focus: CGFloat = 1.04', swift)

    def test_a_bad_value_is_refused(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'tokens.json'
            path.write_text(json.dumps({'color': {'x': {'$value': 'red'}}, 'typography': {}, 'spacing': {}, 'radius': {},
                                        'control': {}, 'motion': {}}), encoding='utf-8')
            with self.assertRaises(ValueError):
                design_tokens.expected(path)


if __name__ == '__main__':
    unittest.main()
