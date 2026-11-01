"""Read-only half of the release notes: gather what the model gets and write it to a directory.

Runs in a job with `contents: read` and `pull-requests: read` and no secrets. Writes <out>/input.json (the data) and <out>/prompt.txt
(.github/release-notes/prompt.md with that data as JSON). The changelog rows, the pull request titles and the template are data for the
model, never instructions. The final tag and the newest final tag before it come from tools/release_notes.py.
"""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FINAL_TAG = re.compile(r'^v(\d+)\.(\d+)\.(\d+)$')
MAX_PROMPT_BYTES = 90000   # one command-line argument holds 128 KiB on Linux; stay well below, whatever characters the titles use
MAX_PRS = 150
TITLE_CAP = 200


def changelog_row(text, version):
    """The 'what changed' cell of the table row for `version` (v1.0.0 or 1.0.0), or ''."""
    want = version.lstrip('v')
    for line in text.splitlines():
        if not line.startswith('|'):
            continue
        cells = line.strip()[1:].split('|', 2)
        if len(cells) == 3 and cells[1].strip().lstrip('v') == want:
            rest = cells[2].rstrip()
            return (rest[:-1] if rest.endswith('|') else rest).strip()
    return ''


def select_prs(prs, shas):
    """Merged pull requests whose merge commit is one of `shas` (None keeps all), newest first, as plain data."""
    out = []
    for pr in prs:
        oid = (pr.get('mergeCommit') or {}).get('oid')
        if shas is not None and oid not in shas:
            continue
        out.append({
            'number': pr['number'],
            'title': str(pr.get('title', ''))[:TITLE_CAP],
            'author': (pr.get('author') or {}).get('login', ''),
            'labels': [l.get('name', '') for l in pr.get('labels') or []],
            'merged_at': pr.get('mergedAt', ''),
        })
    out.sort(key=lambda p: p['merged_at'], reverse=True)
    return out[:MAX_PRS]


def render_prompt(prompt, data):
    """The prompt with the data as JSON. Pull requests are dropped from the end until the result fits the argument limit."""
    data = dict(data)
    prs = list(data['pull_requests'])
    while True:
        data['pull_requests'] = prs
        text = prompt.replace('{{DATA}}', json.dumps(data, ensure_ascii=False, indent=1))
        if len(text.encode('utf-8')) <= MAX_PROMPT_BYTES or not prs:
            return text, len(data['pull_requests'])
        prs.pop()


def gh(*args):
    r = subprocess.run(['gh', *args], capture_output=True, text=True, timeout=120)
    if r.returncode:
        raise SystemExit('gh %s failed: %s' % (args[0], r.stderr.strip()[:300]))
    return r.stdout


def previous_tag(tag):
    r = subprocess.run([sys.executable, '-I', str(ROOT / 'tools/release_notes.py'), 'previous', tag], capture_output=True, text=True, timeout=60)
    if r.returncode:
        raise SystemExit('previous tag failed: %s' % r.stderr.strip()[:300])
    return r.stdout.strip()


def main(argv=None):
    p = argparse.ArgumentParser()
    p.add_argument('--repo', required=True)
    p.add_argument('--tag', required=True)
    p.add_argument('--out', required=True)
    args = p.parse_args(argv)
    if not FINAL_TAG.match(args.tag):
        raise SystemExit('%r is not a final tag (vX.Y.Z)' % args.tag)
    previous = previous_tag(args.tag)
    shas = None
    if previous:
        shas = set(gh('api', '--paginate', 'repos/%s/compare/%s...%s' % (args.repo, previous, args.tag), '--jq', '.commits[].sha').split())
    prs = json.loads(gh('pr', 'list', '--repo', args.repo, '--state', 'merged', '--base', 'main', '--limit', '500',
                        '--json', 'number,title,author,labels,mergedAt,mergeCommit') or '[]')
    data = {
        'tag': args.tag,
        'previous_tag': previous,
        'changelog_en': changelog_row((ROOT / 'CHANGELOG.md').read_text(encoding='utf-8'), args.tag),
        'changelog_zh': changelog_row((ROOT / 'CHANGELOG.zh-CN.md').read_text(encoding='utf-8'), args.tag),
        'pull_requests': select_prs(prs, shas),
        'template': (ROOT / '.github/release_notes_template.md').read_text(encoding='utf-8'),
    }
    if not data['changelog_en'] and not data['pull_requests']:
        raise SystemExit('nothing to write notes from: no changelog row and no merged pull request for %s' % args.tag)
    prompt = (ROOT / '.github/release-notes/prompt.md').read_text(encoding='utf-8')
    text, kept = render_prompt(prompt, data)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    (out / 'input.json').write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding='utf-8')
    (out / 'prompt.txt').write_text(text, encoding='utf-8')
    print('gathered %s: previous %s, %d pull request(s) (%d in the prompt), changelog en %s zh %s' % (
        args.tag, previous or 'none', len(data['pull_requests']), kept, 'yes' if data['changelog_en'] else 'no', 'yes' if data['changelog_zh'] else 'no'))
    return 0


if __name__ == '__main__':
    sys.exit(main())
