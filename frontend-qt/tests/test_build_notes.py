"""Issue #320: the Qt popup reads upstream's stale-shaders note, for both of its reasons.

    python3 -m unittest frontend-qt/tests/test_build_notes.py -v
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'frontend-qt'))

from nspb_qt import build_notes as bn  # noqa: E402

SCRIPT = ROOT / 'engine/scripts/build_ipa_from_nsp.py'


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


if __name__ == '__main__':
    unittest.main()
