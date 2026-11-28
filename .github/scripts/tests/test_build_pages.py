"""Unit tests for .github/scripts/build_pages.py and .github/workflows/pages.yml."""
from __future__ import annotations

from html.parser import HTMLParser
import json
from pathlib import Path
import re
import sys
import tempfile
import tokenize
import unittest

SCRIPTS_DIR = Path(__file__).resolve().parents[1]
REPO_ROOT = Path(__file__).resolve().parents[3]
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

import build_pages as bp  # noqa: E402

FORBIDDEN_SEMICOLONS = (chr(59), chr(0xFF1B), chr(0xFE54), chr(0x037E))


class _VisibleTextExtractor(HTMLParser):
    """Extract rendered visible text and meta descriptions from generated HTML."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self._skip_depth = 0
        self.text_parts: list[str] = []
        self.meta_contents: list[str] = []
        self.links: list[str] = []
        self.images: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        tag_l = tag.lower()
        attr_map = dict(attrs)
        if tag_l in ('script', 'style'):
            self._skip_depth += 1
            return
        if tag_l == 'meta' and attr_map.get('content'):
            if attr_map.get('name') == 'description' or (attr_map.get('property') or '').startswith('og:'):
                self.meta_contents.append(attr_map['content'] or '')
        if tag_l == 'a' and attr_map.get('href'):
            self.links.append(attr_map['href'] or '')
        if tag_l == 'img' and attr_map.get('src'):
            self.images.append(attr_map['src'] or '')
        if tag_l == 'input' and attr_map.get('placeholder'):
            self.text_parts.append(attr_map['placeholder'] or '')

    def handle_endtag(self, tag: str) -> None:
        if tag.lower() in ('script', 'style') and self._skip_depth > 0:
            self._skip_depth -= 1

    def handle_data(self, data: str) -> None:
        if self._skip_depth == 0:
            self.text_parts.append(data)


def _extract_html_info(html_text: str) -> _VisibleTextExtractor:
    parser = _VisibleTextExtractor()
    parser.feed(html_text)
    parser.close()
    return parser


class BuildPagesRealRepoTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.tmp = tempfile.TemporaryDirectory(prefix='nx-pages-real-')
        cls.out = Path(cls.tmp.name) / 'site'
        cls.catalog = bp.build_site(REPO_ROOT, cls.out, 'https://lnpandy.github.io/NX2Apple')

    @classmethod
    def tearDownClass(cls) -> None:
        cls.tmp.cleanup()

    def test_real_repo_counts_and_files(self) -> None:
        counts = self.catalog['counts']
        self.assertEqual(counts['all'], 261)
        self.assertEqual(counts['switch2'], 22)
        self.assertEqual(counts['ios'], 50)
        self.assertEqual(counts['featured'], 146)
        self.assertEqual(counts['fps60'], 35)

        for rel in ('index.html', 'zh/index.html', 'games.json', 'sitemap.xml', 'robots.txt', '.nojekyll'):
            self.assertTrue((self.out / rel).is_file(), f'Missing {rel}')

        games_json = json.loads((self.out / 'games.json').read_text(encoding='utf-8'))
        self.assertEqual(games_json['counts']['all'], 261)
        self.assertEqual(len(games_json['games']), 261)
        self.assertEqual(games_json['version'], bp.read_app_version(REPO_ROOT))
        self.assertEqual(games_json['engine_pin'], bp.read_upstream_ref(REPO_ROOT))

        by_id = {g['id']: g for g in games_json['games']}
        self.assertEqual(len(by_id), 261)
        self.assertIn('ios', by_id['04007EF01F8AE000']['tags'])
        self.assertIn('fps60', by_id['04007EF01F8AE000']['tags'])
        self.assertIn('ios', by_id['040074A01BF12000']['tags'])
        self.assertNotIn('ios', by_id['0400380020056000']['tags'])
        self.assertNotIn('ios', by_id['0400486024DEC000']['tags'])
        self.assertNotIn('ios', by_id['010003F003A34000']['tags'])
        self.assertNotIn('fps60', by_id['0400486024DEC000']['tags'])

    def test_required_links_and_zero_semicolons_in_visible_text(self) -> None:
        for rel in ('index.html', 'zh/index.html'):
            with self.subTest(page=rel):
                raw = (self.out / rel).read_text(encoding='utf-8')
                info = _extract_html_info(raw)
                visible = ' '.join(info.text_parts)
                for bad in FORBIDDEN_SEMICOLONS:
                    self.assertNotIn(bad, visible, f'Found semicolon {bad!r} in visible text of {rel}')
                    for meta in info.meta_contents:
                        self.assertNotIn(bad, meta, f'Found semicolon {bad!r} in meta of {rel}')
                self.assertIn(bp.MAC_DOWNLOAD_URL, info.links)
                self.assertIn(bp.WIN_DOWNLOAD_URL, info.links)
                self.assertIn(bp.REPO_URL, info.links)
                self.assertIn('The Legend of Zelda: Breath of the Wild', visible)
                self.assertIn('01007EF00011E000', visible)

        zh_info = _extract_html_info((self.out / 'zh/index.html').read_text(encoding='utf-8'))
        self.assertIn('塞尔达传说 旷野之息', ' '.join(zh_info.text_parts))

        sitemap = (self.out / 'sitemap.xml').read_text(encoding='utf-8')
        self.assertIn('<loc>https://lnpandy.github.io/NX2Apple/</loc>', sitemap)
        self.assertIn('<loc>https://lnpandy.github.io/NX2Apple/zh/</loc>', sitemap)

        robots = (self.out / 'robots.txt').read_text(encoding='utf-8')
        self.assertIn('Sitemap: https://lnpandy.github.io/NX2Apple/sitemap.xml', robots)

    def test_python_comments_and_ui_strings_have_no_semicolons(self) -> None:
        for py_path in (SCRIPTS_DIR / 'build_pages.py', Path(__file__).resolve()):
            with py_path.open('rb') as fh:
                for tok in tokenize.tokenize(fh.readline):
                    if tok.type == tokenize.COMMENT:
                        for bad in FORBIDDEN_SEMICOLONS:
                            self.assertNotIn(bad, tok.string, f'{py_path.name}:{tok.start[0]} comment contains {bad!r}')
        for lang, mapping in bp.UI_STRINGS.items():
            for key, val in mapping.items():
                for bad in FORBIDDEN_SEMICOLONS:
                    self.assertNotIn(bad, val, f'UI_STRINGS[{lang}][{key}] contains {bad!r}')


class BuildPagesFixtureAndSecurityTests(unittest.TestCase):
    def _write_fixture_repo(self, root: Path, *, xss_payload: bool = False) -> None:
        (root / 'frontend/Sources/NXModel').mkdir(parents=True)
        (root / 'frontend/Sources/NXModel/AppUpdateStore.swift').write_text(
            'package static let appVersion = "9.9.9"\n',
            encoding='utf-8',
        )
        (root / '.upstream-ref').write_text('a' * 40 + '\n', encoding='utf-8')

        evil_name = '<script>alert(1)</script> " onmouseover="alert(2)"' if xss_payload else 'Sample Switch Game'
        evil_note = '<img src=x onerror=alert(3)> 60 fps' + chr(59) + ' Mac & iPhone' if xss_payload else '60 fps'
        evil_href = 'javascript:alert(4)' if xss_payload else 'https://github.com/seedds/nxnative/blob/' + ('a' * 40) + '/dm/games/0100111122220000/README.md'
        evil_img = 'javascript:alert(5)' if xss_payload else 'https://raw.githubusercontent.com/seedds/nxnative/' + ('a' * 40) + '/docs/images/sample.jpg'

        en_md = f"""# Games

<!-- gallery: kept by hand -->
<table>
<tr>
<td align="center" valign="top" width="33%"><img src="{evil_img}" width="256" alt="Test"><br><small><b><a href="{evil_href}">{evil_name}</a></b><br>{evil_note}</small></td>
</tr>
</table>
<!-- end of gallery -->

## Switch 2 games

| Game | Title ID | Upstream says | On this fork |
|---|---|---|---|
| Switch 2 Mac Only | `0400111122220000` | Plays on Mac. No IPA built | Not tried |
| Switch 2 iPhone OK | `0400333344440000` | Plays on Mac (60 fps). No IPA built | Verified on iPhone at 60 fps |

## Profiles

| Game | Title ID | Update required | Status |
|---|---|---|---|
| {evil_name} | `0100111122220000` | 1.0.0 (v65536) | {evil_note} |
| Switch 2 Mac Only | `0400111122220000` | v65536 | Profile present, not verified on a phone |
| Switch 2 iPhone OK | `0400333344440000` | v131072 | **Verified** — plays on an iPhone at 60 fps |
"""

        zh_md = f"""# 游戏

## Switch 2 游戏

| 游戏 | 标题 ID | 上游的说法 | 本 fork |
|---|---|---|---|
| Switch 2 仅 Mac | `0400111122220000` | 在 Mac 上可玩。没有构建过 IPA | 没有试过 |
| Switch 2 iPhone 可玩 | `0400333344440000` | 在 Mac 上可玩 60 fps。没有构建过 IPA | 已在 iPhone 验证 60 fps |

## Profile 列表

| 游戏 | Title ID | 需要的更新包 | 状态 |
|---|---|---|---|
| 中文测试游戏 | `0100111122220000` | 1.0.0 (v65536) | 有 profile，未在手机上验证 |
| Switch 2 仅 Mac | `0400111122220000` | v65536 | 有 profile，未在手机上验证 |
| Switch 2 iPhone 可玩 | `0400333344440000` | v131072 | **已在 iPhone 验证** —— 60 fps 可玩 |
"""
        (root / 'GAMES.md').write_text(en_md, encoding='utf-8')
        (root / 'GAMES.zh-CN.md').write_text(zh_md, encoding='utf-8')

    def test_xss_escaping_and_dangerous_url_rejection(self) -> None:
        with tempfile.TemporaryDirectory(prefix='nx-pages-xss-') as tmp:
            root = Path(tmp) / 'repo'
            out = Path(tmp) / 'out'
            root.mkdir()
            self._write_fixture_repo(root, xss_payload=True)

            catalog = bp.build_site(root, out, 'https://example.github.io/NX2Apple')
            by_id = {g['id']: g for g in catalog['games']}
            self.assertIn('switch2', by_id['0400111122220000']['tags'])
            self.assertNotIn('ios', by_id['0400111122220000']['tags'])
            self.assertIn('switch2', by_id['0400333344440000']['tags'])
            self.assertIn('ios', by_id['0400333344440000']['tags'])
            self.assertIn('fps60', by_id['0400333344440000']['tags'])

            for rel in ('index.html', 'zh/index.html'):
                raw = (out / rel).read_text(encoding='utf-8')
                self.assertNotIn('<script>alert(1)</script>', raw)
                self.assertNotIn('<img src=x onerror=alert(3)>', raw)
                self.assertNotIn('javascript:alert', raw)
                info = _extract_html_info(raw)
                visible = ' '.join(info.text_parts)
                for bad in FORBIDDEN_SEMICOLONS:
                    self.assertNotIn(bad, visible)
                self.assertIn('&lt;script&gt;alert(1)&lt;/script&gt;', raw)

    def test_workflow_hardening_and_sha_pinning(self) -> None:
        wf_path = REPO_ROOT / '.github/workflows/pages.yml'
        text = wf_path.read_text(encoding='utf-8')
        uses_lines = re.findall(r'uses:\s*([^\n]+)', text)
        self.assertGreaterEqual(len(uses_lines), 5)
        for ref in uses_lines:
            self.assertRegex(
                ref.strip(),
                r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[0-9a-f]{40}\s+#\s+v\d+',
                f'Action must be pinned to 40-char commit SHA with version comment: {ref}',
            )
        build_block = text.split('  build:')[1].split('  deploy:')[0]
        self.assertNotIn('actions/configure-pages', build_block)
        self.assertIn('pages: write', text)
        self.assertIn('id-token: write', text)
        self.assertIn("github.event_name != 'pull_request'", text)


if __name__ == '__main__':
    unittest.main()
