# -*- coding: utf-8 -*-
"""README art in the launcher's own look: the feature banner (English and Chinese) and the logo.

    python3 frontend/screenshots/gen_hero.py

Drawn as HTML with the app's font (frontend/fonts/Manrope.ttf), palette (LauncherPalette in
LauncherView.swift) and icon, and rendered by headless Google Chrome at 2x. Chinese falls back to
PingFang SC, which macOS ships. The numbers are read from the tree on every run, so the banner and
the README cannot disagree.
"""
import html
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"


def repo_numbers() -> tuple[int, int]:
    """(game profiles, verified on an iPhone): the dm/games/0100… folders, and GAMES.md's games
    table rows that say they were verified."""
    games = sum(1 for d in (REPO / 'dm/games').iterdir() if d.is_dir() and d.name.startswith('0100'))
    readme = (REPO / 'GAMES.md').read_text(encoding='utf-8')
    verified = sum(1 for ln in readme.splitlines()
                   if ln.startswith('| ') and ln.count('`') >= 2
                   and ('**Verified here**' in ln or 'Verified —' in ln))
    return games, verified


TEXT = {
    'en': {
        'out': 'hero-features-en.png',
        'title': ('Switch games,', 'on iPhone and Mac.'),
        'lead': 'Not an emulator. No terminal.<br>A Mac app does the whole build in a few clicks.',
        'stats': ['game profiles', 'verified on iPhone', 'files → 127 shards'],
        'cards': [
            ('One-click build', 'Pick your files, press Build. No terminal.'),
            ('RomFS archive', '300k files in 127 shards: a 16 GB game installs.'),
            ('Resumable builds', 'A stopped build continues where it left off.'),
            ('Self-installing', 'Fetches the build tools and updates itself.'),
        ],
    },
    'zh': {
        'out': 'hero-features.png',
        'title': ('Switch 游戏，', '装进 iPhone 和 Mac。'),
        'lead': '不是模拟器 · 不用命令行<br>一个 macOS App 点几下就完成构建',
        'stats': ['款游戏 profile', '款 iPhone 实测', '文件 → 127 分片'],
        'cards': [
            ('一键构建', '选好文件按构建，全程无命令行'),
            ('RomFS 归档', '30 万文件压成 127 片，16 GB 也能装'),
            ('断点续传', '中断接着跑，没变的部分直接复用'),
            ('自助安装', '自动下载仓库，App 自己也能更新'),
        ],
    },
}

STYLE = """
@font-face { font-family: Manrope; src: url('%(font)s'); font-weight: 200 800; }
* { margin: 0; box-sizing: border-box; }
html, body { width: %(w)dpx; height: %(h)dpx; overflow: hidden; background: transparent; }
body { font-family: Manrope, 'PingFang SC', sans-serif; color: #fff; -webkit-font-smoothing: antialiased; }
.cream { background: linear-gradient(180deg, #fff6e6 0%%, #ffe2b8 100%%); -webkit-background-clip: text; color: transparent; }
.mark { display: flex; align-items: center; gap: 11px; }
.mark img { width: 34px; height: 34px; }
.mark b { font-size: 21px; font-weight: 700; letter-spacing: -0.6px; }
.mark i { font-style: normal; font-size: 9px; font-weight: 500; color: rgba(255,255,255,.5); display: block; margin-top: -3px; }
"""

BANNER = """<!doctype html><meta charset="utf-8"><style>%(style)s
body { background: #0e0e0f; }
.glow { position: absolute; inset: 0;
  background: radial-gradient(520px 300px at 18%% 30%%, rgba(255,226,184,.10), transparent 70%%),
              radial-gradient(420px 260px at 92%% 110%%, rgba(64,214,120,.06), transparent 70%%); }
.left { position: absolute; left: 46px; top: 30px; width: 440px; }
h1 { margin-top: 22px; font-size: 42px; line-height: 1.04; font-weight: 800; letter-spacing: -1.6px; }
.lead { margin-top: 10px; font-size: 14px; line-height: 1.5; font-weight: 500; color: rgba(255,255,255,.62); }
.stats { position: absolute; left: 46px; bottom: 30px; display: flex; gap: 34px; }
.stat b { display: block; font-size: 26px; font-weight: 800; letter-spacing: -1px; }
.stat span { display: flex; align-items: center; gap: 6px; margin-top: 2px; font-size: 10px; font-weight: 700;
  letter-spacing: 1.1px; text-transform: var(--case, uppercase); color: rgba(255,255,255,.55); }
.stat span::before { content: ''; width: 6px; height: 6px; border-radius: 3px; background: var(--dot); }
.cards { position: absolute; right: 40px; top: 38px; bottom: 38px; width: 480px;
  display: grid; grid-template-columns: 1fr 1fr; grid-template-rows: 1fr 1fr; gap: 12px; }
.card { position: relative; padding: 20px 20px 18px; border-radius: 16px; background: #1a1a1c;
  border: 1px solid rgba(255,255,255,.08); overflow: hidden; display: flex; flex-direction: column; }
.card::after { content: ''; position: absolute; inset: 0; border-radius: 16px; pointer-events: none;
  background: linear-gradient(160deg, rgba(255,255,255,.05), transparent 45%%); }
.num { align-self: flex-start; padding: 3px 9px; border-radius: 99px; font-size: 10px; font-weight: 800;
  letter-spacing: 1px; color: #0e0e0f; background: #fff0d6; }
.card h2 { margin-top: 14px; font-size: 18px; font-weight: 700; letter-spacing: -0.4px; }
.card p { margin-top: 5px; font-size: 12.5px; text-wrap: pretty; line-height: 1.45; font-weight: 500; color: rgba(255,255,255,.55); }
</style>
<div class="glow"></div>
<div class="left">
  <div class="mark"><img src="%(icon)s"><div><b>NX2Apple</b><i>— by nxnative</i></div></div>
  <h1>%(t1)s<br><span class="cream">%(t2)s</span></h1>
  <p class="lead">%(lead)s</p>
</div>
<div class="stats" style="--case: %(case)s">%(stats)s</div>
<div class="cards">%(cards)s</div>
"""

LOGO = """<!doctype html><meta charset="utf-8"><style>%(style)s
body { display: flex; align-items: center; justify-content: center; }
.mark { gap: 18px; }
.mark img { width: 72px; height: 72px; }
.mark b { font-size: 48px; letter-spacing: -1.6px; color: %(ink)s; }
.mark i { font-size: 15px; margin-top: -4px; color: %(sub)s; }
</style>
<div class="mark"><img src="%(icon)s"><div><b>NX2Apple</b><i>— by nxnative</i></div></div>
"""


def render(page: str, out: Path, w: int, h: int) -> None:
    with tempfile.NamedTemporaryFile('w', suffix='.html', delete=False, encoding='utf-8') as f:
        f.write(page)
    subprocess.run([CHROME, '--headless=new', '--hide-scrollbars', '--force-device-scale-factor=2',
                    '--default-background-color=00000000', f'--window-size={w},{h}',
                    f'--screenshot={out}', f'file://{f.name}'],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    Path(f.name).unlink()
    print('saved', out.relative_to(REPO))


def main() -> int:
    if not Path(CHROME).exists():
        sys.exit('needs Google Chrome in /Applications (it renders the HTML)')
    common = {'font': (REPO / 'frontend/fonts/Manrope.ttf').as_uri(),
              'icon': (REPO / 'frontend/icon.iconset/icon_256x256@2x.png').as_uri()}
    games, verified = repo_numbers()
    w, h = 1050, 350   # 2100x700 at 2x, the banner's old size
    for lang in TEXT.values():
        style = STYLE % {**common, 'w': w, 'h': h}
        nums = [(str(games), '#40d678'), (str(verified), '#ffc73d'), ('300k', '#fff0d6')]
        stats = ''.join(f'<div class="stat" style="--dot:{c}"><b>{n}</b><span>{html.escape(l)}</span></div>'
                        for (n, c), l in zip(nums, lang['stats']))
        cards = ''.join(f'<div class="card"><span class="num">0{i + 1}</span><h2>{html.escape(t)}</h2><p>{html.escape(d)}</p></div>'
                        for i, (t, d) in enumerate(lang['cards']))
        page = BANNER % {**common, 'style': style, 't1': lang['title'][0], 't2': lang['title'][1],
                         'lead': lang['lead'], 'stats': stats, 'cards': cards,
                         'case': 'uppercase' if lang is TEXT['en'] else 'none'}
        render(page, HERE / lang['out'], w, h)
    for name, ink, sub in [('logo-dark.png', '#ffffff', 'rgba(255,255,255,.5)'), ('logo-light.png', '#0e0e0f', 'rgba(14,14,15,.55)')]:
        style = STYLE % {**common, 'w': 420, 'h': 110}
        render(LOGO % {**common, 'style': style, 'ink': ink, 'sub': sub}, HERE / name, 420, 110)
    return 0


if __name__ == '__main__':
    sys.exit(main())
