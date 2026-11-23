"""Tests for game-tuned upstream variants in `upstream_store` (no PySide6 required)."""
from __future__ import annotations

import tempfile
import unittest
import zipfile
from pathlib import Path

from nspb_qt import upstream_store as us


class UpstreamVariantTests(unittest.TestCase):
    def test_archive_and_info_refs_urls_and_branches(self) -> None:
        self.assertEqual(
            us.ARCHIVE_URLS['kidwithsword'],
            'https://codeload.github.com/cheemu21/kid-with-sword-remake/zip/refs/heads/L',
        )
        self.assertEqual(
            us.ARCHIVE_URLS['nolagkart'],
            'https://codeload.github.com/kingbumi31/no-lag-kart/zip/refs/heads/main',
        )
        self.assertEqual(us.BRANCH_NAMES['kidwithsword'], 'L')
        self.assertEqual(us.BRANCH_NAMES['nolagkart'], 'main')
        self.assertEqual(us.upstream_display_name('kidwithsword'), 'Kid with Sword')
        self.assertEqual(us.upstream_display_name('nolagkart'), 'No Lag Kart')

    def test_parse_info_refs_uses_branch_l_for_kidwithsword(self) -> None:
        l_sha = 'a' * 40
        main_sha = 'b' * 40
        payload = (
            '001e# service=git-upload-pack\n'
            f'0000003f{main_sha} HEAD\x00multi_ack\n'
            f'003f{main_sha} refs/heads/main\n'
            f'003b{l_sha} refs/heads/L\n'
            '0000\n'
        )
        kws = us.parse_info_refs('kidwithsword', payload)
        self.assertIsNotNone(kws)
        assert kws is not None
        self.assertEqual(kws.commit, l_sha)
        self.assertEqual(kws.version, l_sha[:7])

        nlk = us.parse_info_refs('nolagkart', payload)
        self.assertIsNotNone(nlk)
        assert nlk is not None
        self.assertEqual(nlk.commit, main_sha)
        self.assertEqual(nlk.version, main_sha[:7])

    def test_tuned_engines_for_title_id(self) -> None:
        self.assertEqual(us.tuned_engines_for_title_id('0400486024dec000'), ('kidwithsword', 'macnativegames'))
        self.assertEqual(us.tuned_engines_for_title_id('0400C3F00006E000'), ('nolagkart',))
        self.assertEqual(us.tuned_engines_for_title_id('01007EF00011E000'), ('macnativegames',))
        self.assertEqual(us.tuned_engines_for_title_id('0100152000022000'), ())
        self.assertEqual(us.tuned_engines_for_title_id('bad'), ())

    def test_install_upstream_zip_for_variant(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'upstreams'
            zip_path = Path(tmp) / 'kws.zip'
            commit = 'c' * 40
            with zipfile.ZipFile(zip_path, 'w') as zf:
                zf.writestr('kid-with-sword-remake-L/dm/tools/nx_extract/Program.cs', '// cs\n')
                zf.writestr('kid-with-sword-remake-L/scripts/build_ipa_from_nsp.py', '# build\n')
                zf.comment = commit.encode('utf-8')

            dest = us.install_upstream_zip(zip_path, 'kidwithsword', root=root)
            self.assertEqual(dest, root / 'kidwithsword')
            self.assertTrue(us.is_usable_upstream(str(dest), 'kidwithsword'))
            receipt = us.read_local_receipt('kidwithsword', str(dest))
            self.assertIsNotNone(receipt)
            assert receipt is not None
            self.assertEqual(receipt.commit, commit)
            self.assertEqual(receipt.version, commit[:7])


if __name__ == '__main__':
    unittest.main()
