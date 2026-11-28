#!/usr/bin/env python3
"""Build the bilingual searchable GitHub Pages profile compatibility index for NX2Apple.

Reads GAMES.md, GAMES.zh-CN.md, AppUpdateStore.swift and .upstream-ref using only
the Python 3.9+ standard library and emits a self-contained Dark Glass static site:
  - /index.html       (English index)
  - /zh/index.html    (Simplified Chinese index)
  - /games.json       (Structured compatibility feed)
  - /robots.txt       (Crawler disallow directives)
  - /.nojekyll        (Disable Jekyll processing on GitHub Pages)
"""
from __future__ import annotations

import argparse
import base64
from datetime import datetime, timezone
import html
import json
import os
from pathlib import Path
import re
import sys
from urllib.parse import urlparse

DEFAULT_BASE_URL = 'https://lnpandy.github.io/NX2Apple'
REPO_URL = 'https://github.com/LNPANDY/NX2Apple'
MAC_DOWNLOAD_URL = f'{REPO_URL}/releases/latest/download/NX2Apple-macOS-arm64.zip'
WIN_DOWNLOAD_URL = f'{REPO_URL}/releases/latest/download/NX2Apple-windows-x64.zip'
RELEASES_URL = f'{REPO_URL}/releases'

TITLE_ID_CELL_RE = re.compile(r'^`([0-9A-Fa-f]{16})`$')
PROFILE_NOTES_BLOCK_RE = re.compile(r'<!--\s*gallery:.*?-->.*?<!--\s*end of gallery\s*-->', re.S)
PROFILE_NOTE_LINK_RE = re.compile(
    r'<small>\s*<b>\s*<a\s+href="([^"]+)">(.*?)</a>\s*</b>(?:\s*<br>\s*(.*?))?\s*</small>',
    re.S | re.I,
)
README_ID_RE = re.compile(r'/([0-9A-Fa-f]{16})/README\.md(?:$|[?#])', re.I)
APP_VERSION_RE = re.compile(r'static\s+let\s+appVersion\s*=\s*"([^"]+)"')
FPS_RE = re.compile(r'(?:^|\b)(?:60|120)\s*fps\b', re.I)
IOS_NEG_RE = re.compile(
    r'not verified on a phone|未在手机上验证|no ipa built|没有构建过\s*ipa|mac only|目前仅\s*mac|not tried|没有试过|exceeds current ios limits|over ios(?:\x27s)? limit|超出.*ios.*限制',
    re.I,
)
IOS_POS_TARGET_RE = re.compile(r'(?:iphone|ipad|ios)', re.I)
IOS_POS_VERB_RE = re.compile(r'(?:playable|verified|builds,\s*installs|runs|played|可玩|已验证|运行|玩过)', re.I)
HTML_TAG_RE = re.compile(r'<[^>]+>')

SEMICOLON_ASCII = chr(59)
SEMICOLON_FULL = chr(0xFF1B)
SEMICOLON_SMALL = chr(0xFE54)
SEMICOLON_GREEK = chr(0x037E)
SEMICOLONS = (SEMICOLON_ASCII, SEMICOLON_FULL, SEMICOLON_SMALL, SEMICOLON_GREEK)


def clean_visible_text(text: str, *, chinese: bool = False) -> str:
    """Normalize text for display without any semicolon characters."""
    if not text:
        return ''
    out = text
    comma = '，' if chinese else ', '
    out = re.sub(r'\s*[' + ''.join(SEMICOLONS) + r']\s+', comma, out)
    for ch in SEMICOLONS:
        out = out.replace(ch, '·')
    out = re.sub(r'[ \t]{2,}', ' ', out)
    return out.strip()


def strip_markdown_inline(text: str) -> str:
    """Convert inline markdown links, bold and code spans to plain readable text."""
    out = re.sub(r'\[([^\]]+)\]\([^)]+\)', r'\1', text)
    out = re.sub(r'\*\*(.+?)\*\*', r'\1', out)
    out = re.sub(r'`([^`]+)`', r'\1', out)
    return out.strip()


def no_orphan_title(text: str) -> str:
    """Bind Switch 2 with a non-breaking space so titles never orphan a trailing digit."""
    return text.replace('Switch 2', 'Switch\u00a02')


def safe_http_url(url: str) -> str:
    """Allow only http or https URLs to prevent javascript or data URI injection."""
    candidate = (url or '').strip()
    if not candidate:
        return ''
    parsed = urlparse(candidate)
    if parsed.scheme.lower() in ('http', 'https') and parsed.netloc:
        return candidate
    return ''


def read_app_version(repo_root: Path) -> str:
    store_path = repo_root / 'frontend/Sources/NXModel/AppUpdateStore.swift'
    text = store_path.read_text(encoding='utf-8')
    match = APP_VERSION_RE.search(text)
    if not match:
        raise ValueError(f'Could not find appVersion in {store_path}')
    return clean_visible_text(match.group(1))


def read_upstream_ref(repo_root: Path) -> str:
    ref_path = repo_root / '.upstream-ref'
    pin = ref_path.read_text(encoding='utf-8').strip()
    if not re.fullmatch(r'[0-9a-fA-F]{40}', pin):
        raise ValueError(f'Expected 40-char git SHA in {ref_path}, got {pin!r}')
    return pin.lower()


def read_icon_data_uri(repo_root: Path) -> str:
    icon_path = repo_root / 'frontend-qt/nspb_qt/assets/app_icon.png'
    if icon_path.is_file():
        b64 = base64.b64encode(icon_path.read_bytes()).decode('ascii')
        return f'data:image/png,base64,{b64}'.replace(',base64,', chr(59) + 'base64,')
    return ''


def parse_upstream_notes(md_text: str) -> dict[str, dict[str, str]]:
    """Extract text-only upstream profile links and notes keyed by 16-char uppercase Title ID."""
    block_match = PROFILE_NOTES_BLOCK_RE.search(md_text)
    scope = block_match.group(0) if block_match else md_text
    notes: dict[str, dict[str, str]] = {}
    for href_raw, title_raw, note_raw in PROFILE_NOTE_LINK_RE.findall(scope):
        href = safe_http_url(html.unescape(href_raw))
        id_match = README_ID_RE.search(href)
        if not id_match:
            continue
        tid = id_match.group(1).upper()
        title_clean = clean_visible_text(HTML_TAG_RE.sub('', html.unescape(title_raw)))
        note_clean = clean_visible_text(HTML_TAG_RE.sub(' ', html.unescape(note_raw or '')))
        notes[tid] = {
            'upstream_readme_url': href,
            'profile_title': title_clean,
            'profile_note_en': note_clean,
        }
    return notes


def parse_markdown_tables(md_text: str) -> tuple[dict[str, dict[str, str]], dict[str, dict[str, str]]]:
    """Parse Switch 2 and full profile tables keyed by 16-char uppercase Title ID."""
    sections: list[tuple[str, list[list[str]]]] = []
    heading = ''
    rows: list[list[str]] = []
    for line in md_text.splitlines():
        if line.startswith('## '):
            if rows:
                sections.append((heading, rows))
                rows = []
            heading = line[3:].strip()
        elif line.startswith('|'):
            cells = [c.strip() for c in line.strip().strip('|').split('|')]
            if len(cells) == 4 and TITLE_ID_CELL_RE.fullmatch(cells[1]):
                rows.append(cells)
    if rows:
        sections.append((heading, rows))

    sw2_map: dict[str, dict[str, str]] = {}
    profile_map: dict[str, dict[str, str]] = {}
    for sec_heading, sec_rows in sections:
        is_sw2 = 'switch 2' in sec_heading.lower()
        target = sw2_map if is_sw2 else profile_map
        for cells in sec_rows:
            tid = cells[1].strip('`').upper()
            target[tid] = {
                'name': strip_markdown_inline(cells[0]),
                'title_id': tid,
                'col3': strip_markdown_inline(cells[2]),
                'col4': strip_markdown_inline(cells[3]),
            }
    if not profile_map and len(sections) == 1:
        profile_map = sw2_map
        sw2_map = {}
    return sw2_map, profile_map


def text_confirms_ios(text: str) -> bool:
    """Return True when at least one clause confirms iOS playability without negative qualifiers."""
    if not text:
        return False
    for clause in re.split(r'[.\n。]+', text):
        if not clause.strip():
            continue
        if IOS_NEG_RE.search(clause):
            continue
        if IOS_POS_TARGET_RE.search(clause) and IOS_POS_VERB_RE.search(clause):
            return True
    return False


def derive_ios_support(
    prof_en_status: str,
    prof_zh_status: str,
    sw2_fork_en: str,
    sw2_fork_zh: str,
    profile_note_en: str,
    sw2_up_en: str,
    sw2_up_zh: str,
) -> bool:
    """Determine iOS support by checking fork verification before upstream notes."""
    if any(text_confirms_ios(s) for s in (prof_en_status, prof_zh_status, sw2_fork_en, sw2_fork_zh)):
        return True
    if profile_note_en and IOS_POS_TARGET_RE.search(profile_note_en) and not IOS_NEG_RE.search(profile_note_en):
        return True
    if text_confirms_ios(sw2_up_en) or text_confirms_ios(sw2_up_zh):
        return True
    return False


def derive_tags(record: dict[str, object]) -> list[str]:
    """Compute filter tags solely from parsed metadata and real status text."""
    tid = str(record['id'])
    text_blob = ' '.join(
        str(record.get(k, ''))
        for k in (
            'name_en',
            'name_zh',
            'status_en',
            'status_zh',
            'profile_note_en',
            'sw2_upstream_en',
            'sw2_fork_en',
            'sw2_upstream_zh',
            'sw2_fork_zh',
        )
    )
    tags: list[str] = []
    if tid.startswith('0400') or record.get('in_sw2') or 'switch 2' in text_blob.lower():
        tags.append('switch2')
    if derive_ios_support(
        str(record.get('status_en', '')),
        str(record.get('status_zh', '')),
        str(record.get('sw2_fork_en', '')),
        str(record.get('sw2_fork_zh', '')),
        str(record.get('profile_note_en', '')),
        str(record.get('sw2_upstream_en', '')),
        str(record.get('sw2_upstream_zh', '')),
    ):
        tags.append('ios')
    if FPS_RE.search(text_blob):
        tags.append('fps60')
    return tags


def is_fork_verified(status_en: str, status_zh: str, sw2_fork_en: str) -> bool:
    blob = f'{status_en} {status_zh} {sw2_fork_en}'.lower()
    return (
        'verified here' in blob
        or 'verified \u2014' in blob
        or 'verified -' in blob
        or '本 fork 已验证' in blob
        or '已在 iphone 验证' in blob
        or blob.startswith('verified')
    )


def load_catalog(repo_root: Path) -> dict[str, object]:
    en_path = repo_root / 'GAMES.md'
    zh_path = repo_root / 'GAMES.zh-CN.md'
    en_text = en_path.read_text(encoding='utf-8')
    zh_text = zh_path.read_text(encoding='utf-8')

    notes_map = parse_upstream_notes(en_text)
    en_sw2, en_prof = parse_markdown_tables(en_text)
    zh_sw2, zh_prof = parse_markdown_tables(zh_text)

    ordered_ids: list[str] = list(en_prof.keys())
    seen_ids = set(ordered_ids)
    for extra_map in (zh_prof, en_sw2, zh_sw2):
        for tid in extra_map:
            if tid not in seen_ids:
                ordered_ids.append(tid)
                seen_ids.add(tid)

    games: list[dict[str, object]] = []
    for tid in ordered_ids:
        pe = en_prof.get(tid, {})
        pz = zh_prof.get(tid, {})
        se = en_sw2.get(tid, {})
        sz = zh_sw2.get(tid, {})
        note_info = notes_map.get(tid, {})

        raw_name_en = pe.get('name') or se.get('name') or note_info.get('profile_title') or pz.get('name') or tid
        raw_name_zh = pz.get('name') or sz.get('name') or raw_name_en

        name_en = clean_visible_text(raw_name_en, chinese=False)
        name_zh = clean_visible_text(raw_name_zh, chinese=True)
        update_en = clean_visible_text(pe.get('col3', ''), chinese=False)
        update_zh = clean_visible_text(pz.get('col3', '') or update_en, chinese=True)
        status_en = clean_visible_text(pe.get('col4', ''), chinese=False)
        status_zh = clean_visible_text(pz.get('col4', '') or status_en, chinese=True)
        sw2_upstream_en = clean_visible_text(se.get('col3', ''), chinese=False)
        sw2_fork_en = clean_visible_text(se.get('col4', ''), chinese=False)
        sw2_upstream_zh = clean_visible_text(sz.get('col3', '') or sw2_upstream_en, chinese=True)
        sw2_fork_zh = clean_visible_text(sz.get('col4', '') or sw2_fork_en, chinese=True)
        profile_note_en = clean_visible_text(note_info.get('profile_note_en', ''), chinese=False)

        record: dict[str, object] = {
            'id': tid,
            'name_en': name_en,
            'name_zh': name_zh,
            'raw_aliases': [raw_name_en, raw_name_zh] if raw_name_en != name_en else [],
            'update_en': update_en,
            'update_zh': update_zh,
            'status_en': status_en,
            'status_zh': status_zh,
            'sw2_upstream_en': sw2_upstream_en,
            'sw2_fork_en': sw2_fork_en,
            'sw2_upstream_zh': sw2_upstream_zh,
            'sw2_fork_zh': sw2_fork_zh,
            'upstream_readme_url': note_info.get('upstream_readme_url', ''),
            'profile_note_en': profile_note_en,
            'in_sw2': bool(se or sz),
            'verified_fork': is_fork_verified(status_en, status_zh, sw2_fork_en),
        }
        record['tags'] = derive_tags(record)
        games.append(record)

    counts = {
        'all': len(games),
        'switch2': sum(1 for g in games if 'switch2' in g['tags']),
        'ios': sum(1 for g in games if 'ios' in g['tags']),
        'fps60': sum(1 for g in games if 'fps60' in g['tags']),
    }

    return {
        'version': read_app_version(repo_root),
        'engine_pin': read_upstream_ref(repo_root),
        'generated_at': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
        'counts': counts,
        'games': games,
    }


def safe_json_for_script(obj: object) -> str:
    """Serialize JSON safely for inline script tag without HTML tag breakouts."""
    raw = json.dumps(obj, ensure_ascii=False, separators=(',', ':'))
    return (
        raw.replace('&', '\\u0026')
        .replace('<', '\\u003c')
        .replace('>', '\\u003e')
        .replace('\u2028', '\\u2028')
        .replace('\u2029', '\\u2029')
    )


UI_STRINGS = {
    'en': {
        'html_lang': 'en',
        'page_title': 'NX2Apple Profile Compatibility Index',
        'meta_desc': 'Technical compatibility matrix for static binary translation and Metal shader pipelines across {all} indexed profiles on Apple silicon.',
        'brand_sub': 'by nxnative',
        'nav_catalog': 'All Profiles',
        'lang_en': 'EN',
        'lang_zh': '中文',
        'star_cta': 'Star on GitHub',
        'hero_badge': 'v{version} · {all} Profiles · {switch2} 0400 Series',
        'hero_title_1': 'Profile Compatibility',
        'hero_title_2': 'and Build Index.',
        'hero_lead': 'Technical compatibility matrix for static binary translation and Metal shader pipelines across macOS, iPhone and iPad.',
        'dl_mac': 'Download for macOS (Apple Silicon)',
        'dl_win': 'Download for Windows (x64)',
        'all_releases': 'All releases',
        'repo_home': 'GitHub repository',
        'safety_note': 'Official binary builds from GitHub Releases. On macOS first launch, right-click and choose Open if Gatekeeper asks.',
        'stat_all': 'Indexed Profiles',
        'stat_all_sub': '0100 & 0400 title series',
        'stat_ios': 'iPhone & iPad',
        'stat_ios_sub': 'Verified & upstream reports',
        'stat_sw2': '0400 Series',
        'stat_sw2_sub': '64-bit 0400 title architecture',
        'stat_fps': '60+ FPS Tested',
        'stat_fps_sub': '60 to 120 fps configurations',
        'stat_hint': 'Filter →',
        'search_placeholder': 'Search English or Chinese title, Title ID, 0400, or notes...',
        'search_clear': 'Clear',
        'filter_all': 'All',
        'filter_switch2': '0400 Series',
        'filter_ios': 'iPhone & iPad',
        'filter_fps60': '60+ FPS',
        'showing_count': 'Showing {shown} of {total} profiles',
        'update_label': 'Update',
        'status_label': 'Status',
        'upstream_label': 'Upstream',
        'fork_label': 'This fork',
        'profile_link': 'Upstream notes',
        'copy_title': 'Click to copy Title ID',
        'copied_toast': 'Copied {tid}',
        'badge_sw2': '0400 Series',
        'badge_ios': 'iPhone & iPad',
        'badge_fps': '60+ FPS',
        'badge_verified': 'Verified',
        'empty_title': 'No matching profiles found',
        'empty_sub': 'Try a shorter English or Chinese title, a 16-digit Title ID, or clear active filters.',
        'empty_reset': 'Reset filters',
        'footer_source': 'Data synced from GAMES.md and GAMES.zh-CN.md · Engine pin',
        'footer_notice': 'Independent open-source build frontend. No game files, firmware or cryptographic keys are distributed or hosted.',
    },
    'zh': {
        'html_lang': 'zh-CN',
        'page_title': 'NX2Apple 构建配置兼容性索引',
        'meta_desc': '面向 Apple 芯片的静态指令转译与 Metal 着色器管线技术兼容性索引，收录 {all} 个实测配置条目。',
        'brand_sub': '基于 nxnative',
        'nav_catalog': '全部配置',
        'lang_en': 'EN',
        'lang_zh': '中文',
        'star_cta': 'Star 支持项目',
        'hero_badge': 'v{version} · {all} 个配置 · {switch2} 个 0400 架构',
        'hero_title_1': '构建配置与',
        'hero_title_2': '兼容性技术索引。',
        'hero_lead': '面向 Apple 芯片的静态指令转译与 Metal 着色器管线实测记录，支持按中英文名称与 Title ID 检索。',
        'dl_mac': '下载 macOS 版（Apple 芯片）',
        'dl_win': '下载 Windows 版（x64）',
        'all_releases': '查看全部发行版',
        'repo_home': 'GitHub 仓库主页',
        'safety_note': '安装包直连 GitHub 官方 Releases。macOS 首次打开如遇未付费签名提示，请右键选择「打开」即可。',
        'stat_all': '已收录配置',
        'stat_all_sub': '覆盖 0100 与 0400 系列配置',
        'stat_ios': 'iPhone / iPad 已测',
        'stat_ios_sub': '本 fork 验证与上游可玩报告',
        'stat_sw2': '0400 架构',
        'stat_sw2_sub': '0400 标题架构配置',
        'stat_fps': '60+ FPS 实测',
        'stat_fps_sub': '含 60 至 120 帧配置记录',
        'stat_hint': '筛选 →',
        'search_placeholder': '搜索中文名、英文原名、Title ID、0400 或实测关键词...',
        'search_clear': '清空',
        'filter_all': '全部',
        'filter_switch2': '0400 架构',
        'filter_ios': 'iPhone / iPad',
        'filter_fps60': '60+ FPS',
        'showing_count': '当前显示 {shown} / {total} 个条目',
        'update_label': '所需版本',
        'status_label': '状态',
        'upstream_label': '上游实测',
        'fork_label': '本 fork 实测',
        'profile_link': '上游技术文档',
        'copy_title': '点击复制 Title ID',
        'copied_toast': '已复制 {tid}',
        'badge_sw2': '0400 架构',
        'badge_ios': 'iPhone / iPad',
        'badge_fps': '60+ FPS',
        'badge_verified': '本 fork 已验证',
        'empty_title': '未找到匹配的配置条目',
        'empty_sub': '试试输入更短的中英文名、16 位十六进制 Title ID，或清除当前筛选条件。',
        'empty_reset': '重置全部筛选',
        'footer_source': '数据同步自 GAMES.md 与 GAMES.zh-CN.md · 引擎固定点',
        'footer_notice': '独立开源构建前端 · 不分发或托管任何游戏文件、固件与加密密钥',
    },
}


def build_css() -> str:
    """Return Dark Glass CSS aligned with frontend/design-tokens/tokens.json."""
    return """
:root {
  --bg: #0e0e0f;
  --surface: rgba(26, 26, 28, 0.80);
  --surface-solid: #1a1a1c;
  --surface-raised: rgba(34, 34, 38, 0.88);
  --border: rgba(255, 255, 255, 0.10);
  --border-strong: rgba(255, 255, 255, 0.20);
  --text: rgba(255, 255, 255, 0.92);
  --text-secondary: rgba(255, 255, 255, 0.62);
  --text-tertiary: rgba(255, 255, 255, 0.42);
  --cream: #fff0d6;
  --cream-hi: #fff6e6;
  --cream-lo: #ffe2b8;
  --cream-on: #09090b;
  --emerald: #40d678;
  --amber: #ffc73d;
  --sky: #67d6ff;
  --coral: #ff6b66;
  --radius-chip: 8px;
  --radius-card: 16px;
  --radius-pill: 999px;
}
* { box-sizing: border-box; margin: 0; padding: 0; }
html { scroll-behavior: smooth; color-scheme: dark; max-width: 100%; overflow-x: clip; }
body {
  min-height: 100vh;
  max-width: 100%;
  overflow-x: clip;
  background-color: var(--bg);
  background-image:
    radial-gradient(900px 460px at 14% -4%, rgba(255, 226, 184, 0.11), transparent 66%),
    radial-gradient(760px 420px at 88% 6%, rgba(64, 214, 120, 0.08), transparent 64%);
  color: var(--text);
  font-family: 'Manrope', -apple-system, BlinkMacSystemFont, 'SF Pro Display', 'PingFang SC', 'Hiragino Sans GB', 'Microsoft YaHei', system-ui, sans-serif;
  line-height: 1.5;
  -webkit-font-smoothing: antialiased;
}
a { color: inherit; text-decoration: none; }
button { font: inherit; color: inherit; cursor: pointer; background: none; border: none; }
.wrap { width: 100%; max-width: 1220px; margin: 0 auto; padding: 0 22px; }

/* Sticky glass navigation */
.topbar {
  position: sticky; top: 0; z-index: 40;
  background: rgba(14, 14, 15, 0.78);
  backdrop-filter: blur(22px) saturate(145%);
  -webkit-backdrop-filter: blur(22px) saturate(145%);
  border-bottom: 1px solid rgba(255, 255, 255, 0.08);
}
.topbar-inner {
  display: flex; align-items: center; justify-content: space-between;
  gap: 14px; min-height: 64px;
}
.brand { display: flex; align-items: center; gap: 11px; flex-shrink: 0; }
.brand-icon {
  width: 34px; height: 34px; border-radius: 9px;
  box-shadow: 0 4px 14px rgba(0, 0, 0, 0.55);
  border: 1px solid rgba(255, 240, 214, 0.22);
  object-fit: cover;
}
.brand-fallback {
  width: 34px; height: 34px; border-radius: 9px;
  background: linear-gradient(155deg, #25221e, #121214);
  border: 1px solid rgba(255, 240, 214, 0.28);
  display: grid; place-items: center; font-weight: 800; font-size: 13px; color: var(--cream);
}
.brand-text b { display: block; font-size: 16px; font-weight: 800; letter-spacing: -0.02em; }
.brand-text span { display: block; font-size: 11px; color: var(--text-tertiary); margin-top: -2px; }

.top-actions { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; justify-content: flex-end; }
.nav-link {
  padding: 7px 12px; border-radius: var(--radius-pill);
  font-size: 13px; font-weight: 600; color: var(--text-secondary);
  transition: color 150ms ease, background 150ms ease;
}
.nav-link:hover { color: var(--text); background: rgba(255, 255, 255, 0.06); }

.lang-switch {
  display: inline-flex; align-items: center; padding: 3px;
  border-radius: var(--radius-pill);
  background: rgba(255, 255, 255, 0.06);
  border: 1px solid var(--border);
}
.lang-btn {
  padding: 5px 11px; border-radius: var(--radius-pill);
  font-size: 12px; font-weight: 700; color: var(--text-secondary);
  transition: all 150ms ease;
}
.lang-btn.active { background: var(--cream); color: var(--cream-on); }

.star-btn {
  display: inline-flex; align-items: center; gap: 7px;
  padding: 7px 14px; border-radius: var(--radius-pill);
  background: linear-gradient(180deg, rgba(255, 240, 214, 0.16), rgba(255, 240, 214, 0.08));
  border: 1px solid rgba(255, 240, 214, 0.34);
  font-size: 13px; font-weight: 700; color: var(--cream);
  transition: transform 150ms ease, border-color 150ms ease, background 150ms ease;
  white-space: nowrap;
}
.star-btn:hover { transform: translateY(-1px); border-color: var(--cream); background: rgba(255, 240, 214, 0.22); }
.star-btn svg { width: 15px; height: 15px; fill: var(--amber); flex-shrink: 0; }
.star-count {
  padding: 1px 7px; border-radius: var(--radius-pill);
  background: rgba(0, 0, 0, 0.35); color: var(--cream-hi);
  font-size: 11px; font-weight: 700; display: none;
}
.star-count.loaded { display: inline-block; }

/* Hero Bento */
.hero { padding: 24px 0 18px; }
.hero-grid {
  display: grid; grid-template-columns: minmax(0, 1.38fr) minmax(0, 1fr);
  gap: 16px; align-items: stretch;
}
.hero-main {
  min-width: 0;
  position: relative; padding: 24px 26px; border-radius: 22px;
  background: linear-gradient(160deg, rgba(30, 30, 34, 0.84), rgba(20, 20, 22, 0.90));
  border: 1px solid var(--border);
  box-shadow: 0 20px 60px rgba(0, 0, 0, 0.45), inset 0 1px 0 rgba(255, 255, 255, 0.08);
  display: flex; flex-direction: column; justify-content: space-between; gap: 14px;
}
.hero-pill {
  display: inline-flex; align-items: center; gap: 8px; align-self: flex-start;
  padding: 6px 13px; border-radius: var(--radius-pill);
  background: rgba(64, 214, 120, 0.11); border: 1px solid rgba(64, 214, 120, 0.32);
  color: #b9f5cf; font-size: 12px; font-weight: 700; letter-spacing: 0.01em;
}
.hero-dot { width: 7px; height: 7px; border-radius: 50%; background: var(--emerald); box-shadow: 0 0 10px var(--emerald); }
.hero h1 { font-size: clamp(28px, 3.6vw, 42px); font-weight: 800; line-height: 1.09; letter-spacing: -0.03em; }
.cream-grad {
  background: linear-gradient(180deg, var(--cream-hi) 0%, var(--cream-lo) 100%);
  -webkit-background-clip: text; background-clip: text; color: transparent;
}
.hero-lead { font-size: 15px; color: var(--text-secondary); max-width: 64ch; }

.cta-row { display: flex; flex-wrap: wrap; gap: 11px; margin-top: 2px; }
.btn-primary, .btn-secondary {
  display: inline-flex; align-items: center; gap: 9px;
  min-height: 44px; padding: 10px 18px; border-radius: 13px;
  font-size: 13.5px; font-weight: 700; transition: transform 150ms ease, filter 150ms ease, border-color 150ms ease;
}
.btn-primary {
  background: linear-gradient(180deg, var(--cream-hi), var(--cream));
  color: var(--cream-on);
  box-shadow: 0 10px 26px rgba(255, 240, 214, 0.16);
}
.btn-primary:hover { transform: translateY(-1px); filter: brightness(1.04); }
.btn-secondary {
  background: rgba(255, 255, 255, 0.07);
  border: 1px solid var(--border-strong); color: var(--text);
}
.btn-secondary:hover { transform: translateY(-1px); border-color: var(--cream); background: rgba(255, 255, 255, 0.11); }
.btn-primary svg, .btn-secondary svg { width: 17px; height: 17px; flex-shrink: 0; }

.sub-links { display: flex; flex-wrap: wrap; gap: 16px; font-size: 12.5px; font-weight: 600; color: var(--text-secondary); }
.sub-links a:hover { color: var(--cream); text-decoration: underline; }

.safety-note {
  display: flex; align-items: flex-start; gap: 10px;
  padding: 11px 14px; border-radius: 12px;
  background: rgba(255, 240, 214, 0.05); border: 1px solid rgba(255, 240, 214, 0.14);
  font-size: 12px; color: var(--text-secondary); line-height: 1.55;
}
.safety-note svg { width: 16px; height: 16px; color: var(--cream); flex-shrink: 0; margin-top: 2px; }

.stats-bento {
  min-width: 0;
  display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); grid-template-rows: 1fr 1fr; gap: 12px;
}
.stat-card {
  min-width: 0;
  position: relative; padding: 18px 20px; border-radius: 18px; text-align: left;
  background: var(--surface); border: 1px solid var(--border);
  box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.06);
  display: flex; flex-direction: column; justify-content: space-between; gap: 10px;
  transition: transform 150ms ease, border-color 150ms ease, background 150ms ease;
}
.stat-card:hover { transform: translateY(-2px); border-color: rgba(255, 240, 214, 0.36); background: rgba(34, 34, 38, 0.92); }
.stat-card.is-active { border-color: var(--cream); box-shadow: 0 0 0 1px rgba(255, 240, 214, 0.35); }
.stat-head { display: flex; align-items: baseline; justify-content: space-between; gap: 8px; }
.stat-num { font-size: clamp(28px, 3vw, 36px); font-weight: 800; letter-spacing: -0.03em; color: var(--cream-hi); line-height: 1.05; }
.stat-hint { font-size: 11px; font-weight: 700; color: var(--text-tertiary); opacity: 0.85; }
.stat-card:hover .stat-hint, .stat-card.is-active .stat-hint { color: var(--cream); opacity: 1; }
.stat-foot { display: flex; flex-direction: column; gap: 3px; }
.stat-label { display: flex; align-items: center; gap: 7px; font-size: 13px; font-weight: 700; color: var(--text); }
.stat-sub { font-size: 11.5px; color: var(--text-secondary); line-height: 1.35; }
.stat-dot { width: 8px; height: 8px; border-radius: 50%; flex-shrink: 0; }

/* Sticky search and filters */
.controls-dock {
  position: sticky; top: 64px; z-index: 30;
  padding: 14px 0 12px;
  background: rgba(14, 14, 15, 0.86);
  backdrop-filter: blur(20px);
  -webkit-backdrop-filter: blur(20px);
  border-bottom: 1px solid rgba(255, 255, 255, 0.06);
}
.controls-row { display: flex; flex-wrap: wrap; align-items: center; gap: 12px; }
.search-box {
  position: relative; flex: 1 1 320px;
  display: flex; align-items: center;
  background: var(--surface-raised); border: 1px solid var(--border-strong);
  border-radius: 13px; padding: 0 12px; min-height: 44px;
  transition: border-color 150ms ease, box-shadow 150ms ease;
}
.search-box:focus-within { border-color: var(--cream); box-shadow: 0 0 0 3px rgba(255, 240, 214, 0.14); }
.search-box svg { width: 17px; height: 17px; color: var(--text-tertiary); flex-shrink: 0; }
.search-box input {
  width: 100%; border: none; outline: none; background: transparent;
  color: var(--text); font: inherit; font-size: 14px; padding: 10px;
}
.search-box input::placeholder { color: var(--text-tertiary); }
.kbd-hint {
  padding: 2px 7px; border-radius: 6px; font-size: 11px; font-weight: 700;
  background: rgba(255, 255, 255, 0.08); color: var(--text-tertiary);
  border: 1px solid rgba(255, 255, 255, 0.10);
}
.clear-btn {
  display: none; padding: 4px 9px; border-radius: 8px;
  font-size: 12px; font-weight: 700; color: var(--text-secondary);
  background: rgba(255, 255, 255, 0.08);
}
.clear-btn.visible { display: inline-flex; }
.clear-btn:hover { color: var(--text); background: rgba(255, 255, 255, 0.14); }

.filter-bar { display: flex; align-items: center; justify-content: space-between; gap: 12px; margin-top: 11px; flex-wrap: wrap; }
.filter-pills { display: flex; flex-wrap: wrap; gap: 8px; }
.pill {
  display: inline-flex; align-items: center; gap: 7px;
  padding: 6px 13px; border-radius: var(--radius-pill);
  font-size: 12.5px; font-weight: 700;
  background: rgba(255, 255, 255, 0.05); border: 1px solid var(--border);
  color: var(--text-secondary); transition: all 140ms ease;
}
.pill:hover { color: var(--text); border-color: var(--border-strong); }
.pill.active { background: var(--cream); color: var(--cream-on); border-color: var(--cream); }
.pill-cnt {
  padding: 1px 6px; border-radius: var(--radius-pill);
  background: rgba(255, 255, 255, 0.10); font-size: 11px; font-weight: 800;
}
.pill.active .pill-cnt { background: rgba(0, 0, 0, 0.15); color: var(--cream-on); }
.result-meta { font-size: 12.5px; font-weight: 600; color: var(--text-secondary); }

/* Catalog section header */
.section-head {
  display: flex; align-items: center; justify-content: space-between; gap: 12px;
  flex-wrap: wrap; margin: 22px 0 14px;
}
.section-title { display: flex; align-items: baseline; gap: 10px; flex-wrap: wrap; }
.section-title h2 { font-size: 20px; font-weight: 800; letter-spacing: -0.02em; }
.section-title span { font-size: 13px; color: var(--text-secondary); }

/* Main catalog grid */
.catalog-section { padding-bottom: 44px; }
.catalog-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(350px, 1fr)); gap: 14px; }
.game-card {
  position: relative; padding: 16px 17px; border-radius: var(--radius-card);
  background: var(--surface); border: 1px solid var(--border);
  box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.05);
  display: flex; flex-direction: column; gap: 11px;
  transition: transform 150ms ease, border-color 150ms ease, background 150ms ease;
}
.game-card:hover { transform: translateY(-2px); border-color: rgba(255, 255, 255, 0.22); background: rgba(30, 30, 34, 0.90); }
.game-card.is-hidden { display: none; }

.card-top { display: flex; align-items: flex-start; gap: 12px; }
.card-thumb {
  width: 42px; height: 42px; border-radius: 11px; flex-shrink: 0;
  background: linear-gradient(155deg, rgba(255, 240, 214, 0.14), rgba(255, 255, 255, 0.03));
  border: 1px solid rgba(255, 240, 214, 0.18);
  box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.08);
  display: grid; place-items: center; font-weight: 800; font-size: 13.5px; letter-spacing: 0.03em; color: var(--cream);
}
.card-titles { min-width: 0; flex: 1; }
.card-titles h3 { font-size: 15.5px; font-weight: 700; line-height: 1.3; word-break: break-word; }
.card-sub { font-size: 12px; color: var(--text-tertiary); margin-top: 2px; word-break: break-word; }

.badges { display: flex; flex-wrap: wrap; gap: 5px; }
.badge {
  display: inline-flex; align-items: center; padding: 2px 8px; border-radius: var(--radius-pill);
  font-size: 11px; font-weight: 700; letter-spacing: 0.01em;
}
.badge-sw2 { background: rgba(255, 199, 61, 0.14); border: 1px solid rgba(255, 199, 61, 0.36); color: #ffd978; }
.badge-ios { background: rgba(64, 214, 120, 0.13); border: 1px solid rgba(64, 214, 120, 0.34); color: #9cf0bc; }
.badge-fps { background: rgba(103, 214, 255, 0.13); border: 1px solid rgba(103, 214, 255, 0.34); color: #a5e8ff; }
.badge-ver { background: rgba(64, 214, 120, 0.24); border: 1px solid rgba(64, 214, 120, 0.55); color: #d5ffe4; }

.meta-strip {
  display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 8px;
  padding: 8px 10px; border-radius: 10px;
  background: rgba(255, 255, 255, 0.04); border: 1px solid rgba(255, 255, 255, 0.07);
}
.tid-btn {
  display: inline-flex; align-items: center; gap: 6px;
  padding: 3px 8px; border-radius: 7px;
  background: rgba(255, 240, 214, 0.08); border: 1px solid rgba(255, 240, 214, 0.18);
  font-family: 'SF Mono', ui-monospace, Menlo, Consolas, monospace;
  font-size: 12px; font-weight: 600; color: var(--cream);
  transition: background 140ms ease, border-color 140ms ease;
}
.tid-btn:hover { background: rgba(255, 240, 214, 0.16); border-color: var(--cream); }
.tid-btn svg { width: 12px; height: 12px; opacity: 0.78; }
.update-text { font-size: 12px; color: var(--text-secondary); font-weight: 600; }

.notes-stack { display: flex; flex-direction: column; gap: 6px; font-size: 12.5px; color: var(--text-secondary); line-height: 1.5; }
.note-row { display: flex; flex-direction: column; gap: 2px; }
.note-row.sw2-box {
  padding: 8px 10px; border-radius: 10px;
  background: rgba(255, 255, 255, 0.03); border-left: 2px solid rgba(255, 199, 61, 0.55);
}
.note-label { font-size: 11px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.04em; color: var(--text-tertiary); }

.card-foot {
  margin-top: auto; padding-top: 6px;
  display: flex; align-items: center; justify-content: space-between; gap: 8px;
  border-top: 1px solid rgba(255, 255, 255, 0.06); font-size: 12px;
}
.ext-link { color: var(--cream); font-weight: 600; }
.ext-link:hover { text-decoration: underline; }

mark { background: rgba(255, 240, 214, 0.28); color: var(--cream-hi); padding: 0 2px; border-radius: 3px; }

.empty-state {
  display: none; text-align: center; padding: 54px 20px; border-radius: 18px;
  background: var(--surface); border: 1px dashed var(--border-strong);
}
.empty-state.visible { display: block; }
.empty-state h3 { font-size: 18px; font-weight: 700; margin-bottom: 6px; }
.empty-state p { font-size: 13.5px; color: var(--text-secondary); margin-bottom: 16px; }

.toast {
  position: fixed; left: 50%; bottom: 24px; transform: translate(-50%, 16px);
  padding: 10px 16px; border-radius: var(--radius-pill);
  background: var(--cream); color: var(--cream-on);
  font-size: 13px; font-weight: 800; box-shadow: 0 12px 30px rgba(0, 0, 0, 0.5);
  opacity: 0; pointer-events: none; transition: opacity 180ms ease, transform 180ms ease; z-index: 60;
}
.toast.show { opacity: 1; transform: translate(-50%, 0); }

footer {
  border-top: 1px solid rgba(255, 255, 255, 0.08);
  padding: 24px 0 36px; font-size: 12.5px; color: var(--text-tertiary);
}
.footer-inner { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 10px; }
.footer-inner a { color: var(--text-secondary); }
.footer-inner a:hover { color: var(--cream); }

@media (max-width: 960px) {
  .hero-grid { grid-template-columns: minmax(0, 1fr); }
  .stats-bento { grid-template-columns: repeat(4, minmax(0, 1fr)); grid-template-rows: auto; }
}
@media (max-width: 680px) {
  .wrap { padding: 0 14px; }
  .topbar-inner { padding: 8px 0; min-height: 56px; gap: 8px; }
  .brand { gap: 8px; }
  .brand-icon, .brand-fallback { width: 30px; height: 30px; border-radius: 8px; }
  .brand-text b { font-size: 14.5px; }
  .brand-text span { display: none; }
  .top-actions { gap: 6px; }
  .nav-link { display: none; }
  .lang-btn { padding: 4px 8px; font-size: 11.5px; }
  .star-btn { padding: 5px 10px; font-size: 11.5px; gap: 5px; }
  .star-btn svg { width: 13px; height: 13px; }
  .hero { padding: 16px 0 12px; }
  .hero-main { padding: 18px 16px; border-radius: 18px; }
  .btn-primary, .btn-secondary { width: 100%; justify-content: center; }
  .stats-bento { grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 9px; }
  .stat-card { padding: 14px; }
  .stat-hint { display: none; }
  .controls-dock { position: static; padding: 12px 0; }
  .search-box { flex: 1 1 100%; width: 100%; }
  .catalog-grid { grid-template-columns: minmax(0, 1fr); }
  .kbd-hint { display: none; }
}
"""


def build_js(lang: str, copied_template: str, showing_template: str) -> str:
    """Return progressive enhancement script with zero semicolons and DOM-safe text rendering."""
    # Keep every statement newline-separated so JavaScript works cleanly without semicolons
    return f"""
(function () {{
  const LANG = {json.dumps(lang)}
  const COPIED_TPL = {json.dumps(copied_template)}
  const SHOWING_TPL = {json.dumps(showing_template)}
  const dataEl = document.getElementById('nx-games-data')
  const GAMES = dataEl ? JSON.parse(dataEl.textContent || '[]') : []
  const byId = Object.create(null)
  for (const g of GAMES) byId[g.id] = g

  const searchInput = document.getElementById('search-input')
  const clearBtn = document.getElementById('search-clear')
  const filterPills = Array.from(document.querySelectorAll('.pill[data-filter]'))
  const statCards = Array.from(document.querySelectorAll('.stat-card[data-filter]'))
  const catalogCards = Array.from(document.querySelectorAll('.game-card[data-id]'))
  const resultMeta = document.getElementById('result-meta')
  const emptyState = document.getElementById('empty-state')
  const emptyReset = document.getElementById('empty-reset')
  const langEn = document.getElementById('lang-switch-en')
  const langZh = document.getElementById('lang-switch-zh')
  const toastEl = document.getElementById('toast')
  const starCountEl = document.getElementById('gh-stars')

  let activeFilter = 'all'
  let toastTimer = 0

  function norm(s) {{
    return String(s || '').toLowerCase().replace(/[^0-9a-z\\u4e00-\\u9fff]+/g, ' ').trim()
  }}

  function showToast(msg) {{
    if (!toastEl) return
    toastEl.textContent = msg
    toastEl.classList.add('show')
    if (toastTimer) clearTimeout(toastTimer)
    toastTimer = setTimeout(() => toastEl.classList.remove('show'), 1800)
  }}

  function noOrphan(s) {{
    return String(s || '').replace(/Switch 2/g, 'Switch\\u00a02')
  }}

  function setHighlight(el, rawText, query) {{
    if (!el) return
    const text = noOrphan(rawText)
    el.textContent = ''
    const q = query.trim()
    if (!q) {{
      el.textContent = text
      return
    }}
    const lower = text.toLowerCase()
    const ql = q.toLowerCase()
    let pos = 0
    let idx = lower.indexOf(ql, pos)
    if (idx === -1) {{
      el.textContent = text
      return
    }}
    while (idx !== -1) {{
      if (idx > pos) el.appendChild(document.createTextNode(text.slice(pos, idx)))
      const mark = document.createElement('mark')
      mark.textContent = text.slice(idx, idx + ql.length)
      el.appendChild(mark)
      pos = idx + ql.length
      idx = lower.indexOf(ql, pos)
    }}
    if (pos < text.length) el.appendChild(document.createTextNode(text.slice(pos)))
  }}

  function updateLangLinks(q, filter) {{
    const params = new URLSearchParams()
    if (q) params.set('q', q)
    if (filter && filter !== 'all') params.set('filter', filter)
    const qs = params.toString()
    const suffix = qs ? '?' + qs : ''
    if (langEn) langEn.href = (LANG === 'zh' ? '../' : './') + suffix
    if (langZh) langZh.href = (LANG === 'zh' ? './' : 'zh/') + suffix
  }}

  function syncUrl(q, filter) {{
    const params = new URLSearchParams(window.location.search)
    if (q) params.set('q', q)
    else params.delete('q')
    if (filter && filter !== 'all') params.set('filter', filter)
    else params.delete('filter')
    const qs = params.toString()
    const nextUrl = window.location.pathname + (qs ? '?' + qs : '') + window.location.hash
    window.history.replaceState(null, '', nextUrl)
    updateLangLinks(q, filter)
  }}

  function matchesQuery(g, rawQ, normQ) {{
    if (!rawQ) return true
    const seriesHint = g.tags && g.tags.includes('switch2') ? '0400 series 0400 架构 switch 2' : ''
    const hayRaw = [
      g.id, g.name_en, g.name_zh, g.update_en, g.update_zh,
      g.status_en, g.status_zh, g.profile_note_en,
      g.sw2_upstream_en, g.sw2_fork_en, g.sw2_upstream_zh, g.sw2_fork_zh,
      seriesHint,
      ...(g.raw_aliases || [])
    ].join(' ')
    if (hayRaw.toLowerCase().includes(rawQ.toLowerCase())) return true
    if (normQ && norm(hayRaw).includes(normQ)) return true
    return false
  }}

  function applyState() {{
    const rawQ = (searchInput ? searchInput.value : '').trim()
    const normQ = norm(rawQ)
    if (clearBtn) clearBtn.classList.toggle('visible', rawQ.length > 0)

    for (const pill of filterPills) {{
      pill.classList.toggle('active', pill.dataset.filter === activeFilter)
    }}
    for (const st of statCards) {{
      st.classList.toggle('is-active', st.dataset.filter === activeFilter)
    }}

    let shown = 0
    for (const card of catalogCards) {{
      const g = byId[card.dataset.id]
      if (!g) continue
      const tagOk = activeFilter === 'all' || (g.tags && g.tags.includes(activeFilter))
      const qOk = matchesQuery(g, rawQ, normQ)
      const visible = tagOk && qOk
      card.classList.toggle('is-hidden', !visible)
      if (visible) {{
        shown += 1
        const primaryEl = card.querySelector('.title-primary')
        const subEl = card.querySelector('.title-sub')
        const tidEl = card.querySelector('.tid-code')
        if (primaryEl) setHighlight(primaryEl, LANG === 'zh' ? g.name_zh : g.name_en, rawQ)
        if (subEl) setHighlight(subEl, LANG === 'zh' ? g.name_en : g.name_zh, rawQ)
        if (tidEl) setHighlight(tidEl, g.id, rawQ)
      }}
    }}

    if (resultMeta) {{
      resultMeta.textContent = SHOWING_TPL.replace('{{shown}}', String(shown)).replace('{{total}}', String(GAMES.length))
    }}
    if (emptyState) emptyState.classList.toggle('visible', shown === 0)
    syncUrl(rawQ, activeFilter)
  }}

  if (searchInput) {{
    searchInput.addEventListener('input', applyState)
  }}
  if (clearBtn) {{
    clearBtn.addEventListener('click', () => {{
      searchInput.value = ''
      applyState()
      searchInput.focus()
    }})
  }}
  if (emptyReset) {{
    emptyReset.addEventListener('click', () => {{
      if (searchInput) searchInput.value = ''
      activeFilter = 'all'
      applyState()
    }})
  }}
  for (const el of [...filterPills, ...statCards]) {{
    el.addEventListener('click', () => {{
      activeFilter = el.dataset.filter || 'all'
      applyState()
    }})
  }}

  document.addEventListener('click', (ev) => {{
    const copyBtn = ev.target.closest('.tid-btn[data-copy]')
    if (copyBtn) {{
      const tid = copyBtn.dataset.copy
      if (navigator.clipboard && navigator.clipboard.writeText) {{
        navigator.clipboard.writeText(tid).catch(() => {{}})
      }}
      showToast(COPIED_TPL.replace('{{tid}}', tid))
    }}
  }})

  document.addEventListener('keydown', (ev) => {{
    if (ev.key === '/' && document.activeElement !== searchInput && !ev.metaKey && !ev.ctrlKey && !ev.altKey) {{
      const tag = (document.activeElement && document.activeElement.tagName) || ''
      if (tag !== 'INPUT' && tag !== 'TEXTAREA') {{
        ev.preventDefault()
        if (searchInput) searchInput.focus()
      }}
    }}
  }})

  const initParams = new URLSearchParams(window.location.search)
  const initQ = initParams.get('q') || ''
  const initFilter = initParams.get('filter') || 'all'
  const validFilters = new Set(['all', 'switch2', 'ios', 'fps60'])
  if (searchInput && initQ) searchInput.value = initQ
  if (validFilters.has(initFilter)) activeFilter = initFilter
  applyState()

  if (starCountEl && typeof fetch === 'function') {{
    fetch('https://api.github.com/repos/LNPANDY/NX2Apple', {{ headers: {{ Accept: 'application/vnd.github+json' }} }})
      .then((res) => (res.ok ? res.json() : null))
      .then((data) => {{
        if (!data || typeof data.stargazers_count !== 'number') return
        const n = data.stargazers_count
        starCountEl.textContent = n >= 1000 ? (n / 1000).toFixed(1) + 'k' : String(n)
        starCountEl.classList.add('loaded')
      }})
      .catch(() => {{}})
  }}
}})()
"""


def monogram_for(name: str) -> str:
    letters = [ch for ch in name if ch.isalnum()]
    return (''.join(letters[:2]) or 'NX').upper()


def same_title(a: str, b: str) -> bool:
    norm_a = re.sub(r'[\s()（）]+', '', a).lower()
    norm_b = re.sub(r'[\s()（）]+', '', b).lower()
    return norm_a == norm_b


def render_game_cards(games: list[dict[str, object]], lang: str, strings: dict[str, str]) -> str:
    parts: list[str] = []
    copy_svg = '<svg viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M0 6.75C0 5.784.784 5 1.75 5h1.5a.75.75 0 0 1 0 1.5h-1.5a.25.25 0 0 0-.25.25v7.5c0 .138.112.25.25.25h7.5a.25.25 0 0 0 .25-.25v-1.5a.75.75 0 0 1 1.5 0v1.5A1.75 1.75 0 0 1 9.25 16h-7.5A1.75 1.75 0 0 1 0 14.25Z"></path><path d="M5 1.75C5 .784 5.784 0 6.75 0h7.5C15.216 0 16 .784 16 1.75v7.5A1.75 1.75 0 0 1 14.25 11h-7.5A1.75 1.75 0 0 1 5 9.25Zm1.75-.25a.25.25 0 0 0-.25.25v7.5c0 .138.112.25.25.25h7.5a.25.25 0 0 0 .25-.25v-7.5a.25.25 0 0 0-.25-.25Z"></path></svg>'
    for g in games:
        tid = str(g['id'])
        primary = no_orphan_title(str(g['name_zh'] if lang == 'zh' else g['name_en']))
        secondary = no_orphan_title(str(g['name_en'] if lang == 'zh' else g['name_zh']))
        update_val = str(g['update_zh'] if lang == 'zh' else g['update_en'])
        status_val = str(g['status_zh'] if lang == 'zh' else g['status_en'])
        sw2_up = str(g['sw2_upstream_zh'] if lang == 'zh' else g['sw2_upstream_en'])
        sw2_fork = str(g['sw2_fork_zh'] if lang == 'zh' else g['sw2_fork_en'])
        profile_note = str(g.get('profile_note_en', ''))
        tags: list[str] = list(g['tags'])
        readme_url = safe_http_url(str(g.get('upstream_readme_url', '')))

        mono = html.escape(monogram_for(primary), quote=True)
        sub_html = f'<div class="card-sub title-sub">{html.escape(secondary)}</div>' if secondary and not same_title(primary, secondary) else ''

        badge_parts: list[str] = []
        if g.get('verified_fork'):
            badge_parts.append(f'<span class="badge badge-ver">{html.escape(strings["badge_verified"])}</span>')
        if 'switch2' in tags:
            badge_parts.append(f'<span class="badge badge-sw2">{html.escape(strings["badge_sw2"])}</span>')
        if 'ios' in tags:
            badge_parts.append(f'<span class="badge badge-ios">{html.escape(strings["badge_ios"])}</span>')
        if 'fps60' in tags:
            badge_parts.append(f'<span class="badge badge-fps">{html.escape(strings["badge_fps"])}</span>')
        badges_html = f'<div class="badges">{"".join(badge_parts)}</div>' if badge_parts else ''

        notes: list[str] = []
        if status_val:
            notes.append(
                f'<div class="note-row"><span class="note-label">{html.escape(strings["status_label"])}</span>'
                f'<span>{html.escape(status_val)}</span></div>'
            )
        if sw2_up:
            notes.append(
                f'<div class="note-row sw2-box"><span class="note-label">{html.escape(strings["upstream_label"])}</span>'
                f'<span>{html.escape(sw2_up)}</span></div>'
            )
        if sw2_fork and sw2_fork not in ('Not tried', '没有试过'):
            notes.append(
                f'<div class="note-row sw2-box"><span class="note-label">{html.escape(strings["fork_label"])}</span>'
                f'<span>{html.escape(sw2_fork)}</span></div>'
            )
        if profile_note and not sw2_up:
            notes.append(f'<div class="note-row"><span>{html.escape(profile_note)}</span></div>')

        foot_left = (
            f'<a class="ext-link" href="{html.escape(readme_url, quote=True)}" target="_blank" rel="noopener noreferrer">{html.escape(strings["profile_link"])} ↗</a>'
            if readme_url
            else '<span></span>'
        )
        foot_html = f'<div class="card-foot">{foot_left}</div>' if readme_url else ''

        parts.append(
            f'<article class="game-card" data-id="{html.escape(tid, quote=True)}">'
            f'<div class="card-top">'
            f'<div class="card-thumb" aria-hidden="true">{mono}</div>'
            f'<div class="card-titles"><h3 class="title-primary">{html.escape(primary)}</h3>{sub_html}</div>'
            f'</div>'
            f'{badges_html}'
            f'<div class="meta-strip">'
            f'<button type="button" class="tid-btn" data-copy="{html.escape(tid, quote=True)}" title="{html.escape(strings["copy_title"], quote=True)}">'
            f'<span class="tid-code">{html.escape(tid)}</span>{copy_svg}</button>'
            f'<span class="update-text">{html.escape(strings["update_label"])}: {html.escape(update_val)}</span>'
            f'</div>'
            f'<div class="notes-stack">{"".join(notes)}</div>'
            f'{foot_html}'
            f'</article>'
        )
    return '\n'.join(parts)


def render_page(catalog: dict[str, object], lang: str, base_url: str, icon_uri: str) -> str:
    strings = UI_STRINGS[lang]
    counts: dict[str, int] = catalog['counts']  # type: ignore[assignment]
    games: list[dict[str, object]] = catalog['games']  # type: ignore[assignment]
    version = str(catalog['version'])
    pin = str(catalog['engine_pin'])
    base = base_url.rstrip('/')

    canonical = f'{base}/zh/' if lang == 'zh' else f'{base}/'
    en_alt = f'{base}/'
    zh_alt = f'{base}/zh/'
    en_href = '../' if lang == 'zh' else './'
    zh_href = './' if lang == 'zh' else 'zh/'

    meta_desc = strings['meta_desc'].format(all=counts['all'])
    hero_badge = strings['hero_badge'].format(version=version, all=counts['all'], switch2=counts['switch2'])
    showing_tpl = strings['showing_count']
    showing_init = showing_tpl.format(shown=counts['all'], total=counts['all'])

    favicon_tag = f'<link rel="icon" type="image/png" href="{html.escape(icon_uri, quote=True)}">' if icon_uri else ''
    brand_img = (
        f'<img class="brand-icon" src="{html.escape(icon_uri, quote=True)}" alt="NX2Apple icon">'
        if icon_uri
        else '<div class="brand-fallback" aria-hidden="true">nx</div>'
    )

    star_svg = '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M8 .25a.75.75 0 0 1 .673.418l1.882 3.815 4.21.612a.75.75 0 0 1 .416 1.279l-3.046 2.97.719 4.192a.751.751 0 0 1-1.088.791L8 12.347l-3.766 1.98a.75.75 0 0 1-1.088-.79l.72-4.194L.818 6.374a.75.75 0 0 1 .416-1.28l4.21-.611L7.327.668A.75.75 0 0 1 8 .25Z"></path></svg>'
    dl_svg = '<svg viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M2.75 14A1.75 1.75 0 0 1 1 12.25v-2.5a.75.75 0 0 1 1.5 0v2.5c0 .138.112.25.25.25h10.5a.25.25 0 0 0 .25-.25v-2.5a.75.75 0 0 1 1.5 0v2.5A1.75 1.75 0 0 1 13.25 14Z"></path><path d="M7.25 7.689V2a.75.75 0 0 1 1.5 0v5.689l1.97-1.969a.749.749 0 1 1 1.06 1.06l-3.25 3.25a.749.749 0 0 1-1.06 0L4.22 6.78a.749.749 0 1 1 1.06-1.06l1.97 1.969Z"></path></svg>'
    info_svg = '<svg viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M0 8a8 8 0 1 1 16 0A8 8 0 0 1 0 8Zm8-6.5a6.5 6.5 0 1 0 0 13 6.5 6.5 0 0 0 0-13ZM6.5 7.75A.75.75 0 0 1 7.25 7h1a.75.75 0 0 1 .75.75v2.75h.25a.75.75 0 0 1 0 1.5h-2a.75.75 0 0 1 0-1.5h.25v-2h-.25a.75.75 0 0 1-.75-.75ZM8 6a1 1 0 1 1 0-2 1 1 0 0 1 0 2Z"></path></svg>'
    search_svg = '<svg viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M10.68 11.74a6 6 0 0 1-7.922-8.982 6 6 0 0 1 8.982 7.922l3.04 3.04a.749.749 0 0 1-.326 1.275.749.749 0 0 1-.734-.215ZM11.5 7a4.499 4.499 0 1 0-8.997 0A4.499 4.499 0 0 0 11.5 7Z"></path></svg>'

    catalog_html = render_game_cards(games, lang, strings)
    data_json = safe_json_for_script(games)
    css = build_css()
    js = build_js(lang, strings['copied_toast'], showing_tpl)

    pin_short = pin[:8]
    pin_url = f'https://github.com/seedds/nxnative/tree/{pin}'

    return f"""<!doctype html>
<html lang="{html.escape(strings['html_lang'], quote=True)}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow, noarchive, nosnippet">
<meta name="googlebot" content="noindex, nofollow, noarchive, nosnippet">
<title>{html.escape(strings['page_title'])}</title>
<meta name="description" content="{html.escape(meta_desc, quote=True)}">
<meta property="og:title" content="{html.escape(strings['page_title'], quote=True)}">
<meta property="og:description" content="{html.escape(meta_desc, quote=True)}">
<meta property="og:type" content="website">
<meta property="og:url" content="{html.escape(canonical, quote=True)}">
<link rel="canonical" href="{html.escape(canonical, quote=True)}">
<link rel="alternate" hreflang="en" href="{html.escape(en_alt, quote=True)}">
<link rel="alternate" hreflang="zh-Hans" href="{html.escape(zh_alt, quote=True)}">
<link rel="alternate" hreflang="x-default" href="{html.escape(en_alt, quote=True)}">
{favicon_tag}
<style>{css}</style>
</head>
<body>
<header class="topbar">
  <div class="wrap topbar-inner">
    <a class="brand" href="./">
      {brand_img}
      <span class="brand-text"><b>NX2Apple</b><span>{html.escape(strings['brand_sub'])}</span></span>
    </a>
    <nav class="top-actions" aria-label="Primary">
      <a class="nav-link" href="#catalog">{html.escape(strings['nav_catalog'])}</a>
      <div class="lang-switch">
        <a id="lang-switch-en" class="lang-btn{' active' if lang == 'en' else ''}" href="{html.escape(en_href, quote=True)}">{html.escape(strings['lang_en'])}</a>
        <a id="lang-switch-zh" class="lang-btn{' active' if lang == 'zh' else ''}" href="{html.escape(zh_href, quote=True)}">{html.escape(strings['lang_zh'])}</a>
      </div>
      <a class="star-btn" href="{html.escape(REPO_URL, quote=True)}" target="_blank" rel="noopener noreferrer">
        {star_svg}
        <span>{html.escape(strings['star_cta'])}</span>
        <span id="gh-stars" class="star-count"></span>
      </a>
    </nav>
  </div>
</header>

<main>
  <section class="hero wrap">
    <div class="hero-grid">
      <div class="hero-main">
        <div class="hero-pill"><span class="hero-dot" aria-hidden="true"></span><span>{html.escape(hero_badge)}</span></div>
        <div>
          <h1>{html.escape(strings['hero_title_1'])}<br><span class="cream-grad">{html.escape(strings['hero_title_2'])}</span></h1>
        </div>
        <p class="hero-lead">{html.escape(strings['hero_lead'])}</p>
        <div class="cta-row">
          <a class="btn-primary" href="{html.escape(MAC_DOWNLOAD_URL, quote=True)}">{dl_svg}<span>{html.escape(strings['dl_mac'])}</span></a>
          <a class="btn-secondary" href="{html.escape(WIN_DOWNLOAD_URL, quote=True)}">{dl_svg}<span>{html.escape(strings['dl_win'])}</span></a>
        </div>
        <div class="sub-links">
          <a href="{html.escape(RELEASES_URL, quote=True)}" target="_blank" rel="noopener noreferrer">{html.escape(strings['all_releases'])} ↗</a>
          <a href="{html.escape(REPO_URL, quote=True)}" target="_blank" rel="noopener noreferrer">{html.escape(strings['repo_home'])} ↗</a>
        </div>
        <div class="safety-note">{info_svg}<span>{html.escape(strings['safety_note'])}</span></div>
      </div>

      <div class="stats-bento">
        <button type="button" class="stat-card is-active" data-filter="all">
          <div class="stat-head"><span class="stat-num">{counts['all']}</span><span class="stat-hint">{html.escape(strings['stat_hint'])}</span></div>
          <div class="stat-foot">
            <span class="stat-label"><span class="stat-dot" style="background: var(--cream)"></span>{html.escape(strings['stat_all'])}</span>
            <span class="stat-sub">{html.escape(strings['stat_all_sub'])}</span>
          </div>
        </button>
        <button type="button" class="stat-card" data-filter="ios">
          <div class="stat-head"><span class="stat-num">{counts['ios']}</span><span class="stat-hint">{html.escape(strings['stat_hint'])}</span></div>
          <div class="stat-foot">
            <span class="stat-label"><span class="stat-dot" style="background: var(--emerald)"></span>{html.escape(strings['stat_ios'])}</span>
            <span class="stat-sub">{html.escape(strings['stat_ios_sub'])}</span>
          </div>
        </button>
        <button type="button" class="stat-card" data-filter="switch2">
          <div class="stat-head"><span class="stat-num">{counts['switch2']}</span><span class="stat-hint">{html.escape(strings['stat_hint'])}</span></div>
          <div class="stat-foot">
            <span class="stat-label"><span class="stat-dot" style="background: var(--amber)"></span>{html.escape(strings['stat_sw2'])}</span>
            <span class="stat-sub">{html.escape(strings['stat_sw2_sub'])}</span>
          </div>
        </button>
        <button type="button" class="stat-card" data-filter="fps60">
          <div class="stat-head"><span class="stat-num">{counts['fps60']}</span><span class="stat-hint">{html.escape(strings['stat_hint'])}</span></div>
          <div class="stat-foot">
            <span class="stat-label"><span class="stat-dot" style="background: var(--sky)"></span>{html.escape(strings['stat_fps'])}</span>
            <span class="stat-sub">{html.escape(strings['stat_fps_sub'])}</span>
          </div>
        </button>
      </div>
    </div>
  </section>

  <section class="controls-dock">
    <div class="wrap">
      <div class="controls-row">
        <label class="search-box">
          {search_svg}
          <input id="search-input" type="search" autocomplete="off" spellcheck="false" placeholder="{html.escape(strings['search_placeholder'], quote=True)}">
          <button id="search-clear" type="button" class="clear-btn">{html.escape(strings['search_clear'])}</button>
          <span class="kbd-hint" aria-hidden="true">/</span>
        </label>
      </div>
      <div class="filter-bar">
        <div class="filter-pills">
          <button type="button" class="pill active" data-filter="all">{html.escape(strings['filter_all'])} <span class="pill-cnt">{counts['all']}</span></button>
          <button type="button" class="pill" data-filter="ios">{html.escape(strings['filter_ios'])} <span class="pill-cnt">{counts['ios']}</span></button>
          <button type="button" class="pill" data-filter="fps60">{html.escape(strings['filter_fps60'])} <span class="pill-cnt">{counts['fps60']}</span></button>
          <button type="button" class="pill" data-filter="switch2">{html.escape(strings['filter_switch2'])} <span class="pill-cnt">{counts['switch2']}</span></button>
        </div>
        <div id="result-meta" class="result-meta">{html.escape(showing_init)}</div>
      </div>
    </div>
  </section>

  <section id="catalog" class="wrap catalog-section">
    <div class="section-head">
      <div class="section-title">
        <h2>{html.escape(strings['nav_catalog'])}</h2>
        <span>{counts['all']}</span>
      </div>
    </div>
    <div id="catalog-grid" class="catalog-grid">
      {catalog_html}
    </div>
    <div id="empty-state" class="empty-state">
      <h3>{html.escape(strings['empty_title'])}</h3>
      <p>{html.escape(strings['empty_sub'])}</p>
      <button id="empty-reset" type="button" class="btn-secondary">{html.escape(strings['empty_reset'])}</button>
    </div>
  </section>
</main>

<footer>
  <div class="wrap footer-inner">
    <div>{html.escape(strings['footer_source'])} <a href="{html.escape(pin_url, quote=True)}" target="_blank" rel="noopener noreferrer"><code>{html.escape(pin_short)}</code></a></div>
    <div>{html.escape(strings['footer_notice'])}</div>
  </div>
</footer>

<div id="toast" class="toast" role="status" aria-live="polite"></div>
<script id="nx-games-data" type="application/json">{data_json}</script>
<script>{js}</script>
</body>
</html>
"""


def render_robots() -> str:
    return 'User-agent: *\nDisallow: /\n'


def build_site(repo_root: Path, out_dir: Path, base_url: str = DEFAULT_BASE_URL) -> dict[str, object]:
    catalog = load_catalog(repo_root)
    icon_uri = read_icon_data_uri(repo_root)

    out_dir.mkdir(parents=True, exist_ok=True)
    zh_dir = out_dir / 'zh'
    zh_dir.mkdir(parents=True, exist_ok=True)

    (out_dir / 'index.html').write_text(render_page(catalog, 'en', base_url, icon_uri), encoding='utf-8')
    (zh_dir / 'index.html').write_text(render_page(catalog, 'zh', base_url, icon_uri), encoding='utf-8')
    (out_dir / 'games.json').write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    sitemap_path = out_dir / 'sitemap.xml'
    if sitemap_path.exists():
        sitemap_path.unlink()
    (out_dir / 'robots.txt').write_text(render_robots(), encoding='utf-8')
    (out_dir / '.nojekyll').write_text('', encoding='utf-8')
    return catalog


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description='Build bilingual NX2Apple GitHub Pages site.')
    parser.add_argument(
        '--repo-root',
        type=Path,
        default=Path(__file__).resolve().parents[2],
        help='Path to the repository root.',
    )
    parser.add_argument(
        '--out',
        type=Path,
        default=Path(os.environ.get('RUNNER_TEMP', '.')) / 'pages-site',
        help='Output directory for static site artifacts.',
    )
    parser.add_argument(
        '--base-url',
        default=DEFAULT_BASE_URL,
        help='Canonical base URL for meta links.',
    )
    args = parser.parse_args(argv)
    catalog = build_site(args.repo_root.resolve(), args.out.resolve(), args.base_url)
    counts = catalog['counts']
    print(
        f"Built pages site in {args.out}: v{catalog['version']}, "
        f"{counts['all']} profiles ({counts['switch2']} 0400 series, {counts['ios']} iOS, {counts['fps60']} 60+ FPS)"
    )
    return 0


if __name__ == '__main__':
    sys.exit(main())
