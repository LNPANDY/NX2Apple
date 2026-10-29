"""Read-only half of issue triage: gather what the model gets and write it to a directory.

Runs in a job with `issues: read` and no secrets. Writes <out>/input.json (the data), <out>/prompt.txt (instructions plus that data as
JSON) and sets `skip` / `reason` in $GITHUB_OUTPUT. Everything that came from the issue is data inside input.json; the instructions come
from .github/triage/prompt.md in the checked-out default branch.
"""
import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import triage_logs as tl  # noqa: E402

ALLOWED_LABELS = ['game', 'build', 'launcher', 'ios', 'mac', 'idea', 'question', 'needs-info', 'duplicate']
SKIP_LABEL = 'no-triage'
BODY_CAP = 12000
MAX_PROMPT_BYTES = 90000   # one command-line argument holds 128 KiB on Linux; stay well below, whatever characters the issue uses
TITLE_CAP = 300

# Form fields that must have an answer, by the heading the issue form renders ("### <label>"); an empty field shows `_No response_`.
REQUIRED = {
    'NX2Apple version': 'NX2Apple version',
    'Computer and OS': 'computer and OS',
    'macOS or iOS / iPadOS version': 'macOS / iOS version',
    'Device, chip and RAM': 'device',
    'Copy diagnostics': 'Copy diagnostics',
    "The game's log": "the game's log",
    'Build log': 'build log',
    'The message': 'the error message',
    'Game, title ID and versions': 'game, title ID and versions',
}
KIND_HEADINGS = {'Which step failed': 'build', 'Where it runs': 'game', 'This is': 'launcher'}

STOP = set('the a an and or of to in on is are was were it its for with when after before not no this that my i me you at by from as be can cant cannot does doesnt dont do bug issue problem game'.split())


def gh(*args, check=True):
    r = subprocess.run(['gh', *args], capture_output=True, text=True, timeout=60)
    if check and r.returncode:
        raise SystemExit(f'gh {args[0]} {args[1]} failed: {r.stderr.strip()[:300]}')
    return r.stdout


def sections(body):
    """The `### heading` sections of an issue-form body: {heading: text}."""
    out, cur = {}, None
    for line in (body or '').splitlines():
        m = re.match(r'^### (.+?)\s*$', line)
        if m:
            cur = m[1]
            out[cur] = []
        elif cur is not None:
            out[cur].append(line)
    return {k: '\n'.join(v).strip() for k, v in out.items()}


LOG_FIELDS = ("The game's log", 'Build log')
NO_ANSWER = ('', '_No response_')
APP_VERSION = re.compile(r'\bv\d+\.\d+(?:\.\d+)?\b|\bNX2Apple\b[^\n]{0,40}?\bv?\d+\.\d+|\b(?:app|launcher) version\W{0,3}v?\d+\.\d+', re.I)
OS_VERSION = re.compile(r'\b(?:mac ?os(?: x)?|ios|ipados)\s+(?:[a-z]+\s+)?v?\d+(?:\.\d+)*', re.I)
FENCED_LOG = re.compile(r'```[^\n]*\n(?:[^\n]*\n){5,}?```')


def analyse_form(body, readable_attachments):
    """What the issue says about itself: whether it came from a form, which required answers are empty, a kind hint.

    The log counts as given when its own form field has text or a log attachment could be read; a `[RED]` line quoted in another field
    does not. `Copy diagnostics` is not asked of an idea (the form says it is not needed)."""
    sec = sections(body)
    from_form = any(h in sec for h in ('NX2Apple version', 'No keys, no game files', 'Game, title ID and versions'))
    missing, kind, target = [], None, None
    if from_form:
        for h, k in KIND_HEADINGS.items():
            if h in sec:
                kind = k
        if sec.get('This is', '').startswith('An idea'):
            kind = 'idea'
        for h, name in REQUIRED.items():
            if h not in sec or sec[h] not in NO_ANSWER:
                continue
            if h == 'Copy diagnostics' and kind == 'idea':
                continue
            if h in LOG_FIELDS and readable_attachments:
                continue
            missing.append(name)
        w = sec.get('Where it runs', '') + ' ' + sec.get('Built for', '')
        target = 'ios' if re.search(r'iPhone|iPad', w) else 'mac' if 'Mac' in w else None
    else:
        text = body or ''
        if not APP_VERSION.search(text):
            missing.append('NX2Apple version')
        if not OS_VERSION.search(text):
            missing.append('macOS or iOS / iPadOS version')
        if not (readable_attachments or FENCED_LOG.search(text)):
            missing.append('the log (or Copy diagnostics)')
    return {'from_form': from_form, 'missing': missing, 'kind_hint': kind, 'target_hint': target}


def search_words(title):
    words = []
    for w in re.findall(r"[A-Za-z0-9][A-Za-z0-9'_-]{2,}", title):
        if w.lower() not in STOP and w.lower() not in (x.lower() for x in words):
            words.append(w)
    return words[:6]


def candidates(repo, number, title):
    """Likely duplicates: a read-only `gh issue list --search` on words of the title (no qualifiers can pass through)."""
    words = search_words(title)
    if not words:
        return []
    out = gh('issue', 'list', '-R', repo, '--state', 'all', '--limit', '8', '--search', ' '.join(words) + ' in:title,body',
             '--json', 'number,title,state,labels', check=False)
    try:
        rows = json.loads(out or '[]')
    except ValueError:
        return []
    return [{'number': r['number'], 'title': r['title'][:200], 'state': r['state'], 'labels': [l['name'] for l in r.get('labels', [])]}
            for r in rows if r['number'] != number][:6]


def build_prompt(template, data, cap=MAX_PROMPT_BYTES):
    """The template with the data as JSON, at most `cap` bytes of UTF-8: the issue body is cut (halved until it fits), then the log lines."""
    def render():
        return template.replace('{{DATA}}', json.dumps(data, ensure_ascii=False))

    def size(text):
        return len(text.encode('utf-8', 'replace'))
    body = data['issue']['body']
    while size(render()) > cap and body:
        body = body[:len(body) // 2]
        data['issue']['body'] = body
        data['issue']['body_truncated'] = True
    for key in ('red', 'crash'):
        while size(render()) > cap and data['log_signals'][key]:
            data['log_signals'][key].pop()
    while size(render()) > cap and data['symptom_matches']:
        data['symptom_matches'].pop()
    while size(render()) > cap and data['issue']['title']:
        data['issue']['title'] = data['issue']['title'][:len(data['issue']['title']) // 2]
    return render()


def set_output(**kv):
    path = os.environ.get('GITHUB_OUTPUT')
    for k, v in kv.items():
        line = f'{k}={v}'
        print(line)
        if path:
            with open(path, 'a', encoding='utf-8') as f:
                f.write(line + '\n')


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--repo', required=True)
    ap.add_argument('--issue', type=int, required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--docs', default='docs')
    ap.add_argument('--prompt', default='.github/triage/prompt.md')
    ap.add_argument('--issue-json', help='read the issue from this file instead of the API (tests)')
    a = ap.parse_args(argv)
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)

    issue = json.loads(Path(a.issue_json).read_text()) if a.issue_json else json.loads(gh('api', f'repos/{a.repo}/issues/{a.issue}'))
    labels = [l['name'] for l in issue.get('labels', [])]
    reason = None
    if 'pull_request' in issue:
        reason = 'a pull request'
    elif issue.get('state') != 'open':
        reason = 'the issue is not open'
    elif SKIP_LABEL in labels:
        reason = f'label {SKIP_LABEL}'
    elif (issue.get('user') or {}).get('type') == 'Bot':
        reason = 'opened by a bot'
    if reason:
        set_output(skip='true', reason=reason)
        return 0

    title = (issue.get('title') or '')[:TITLE_CAP]
    body = (issue.get('body') or '')
    sig = tl.extract_signals(body.splitlines())
    urls = tl.attachment_urls(body)
    readable = 0   # attachments that gave at least one line of text (a screenshot or a failed download gives none)
    for u in urls:
        count = [0]

        def counted(lines):
            for line in lines:
                count[0] += 1
                yield line
        try:
            sig = tl.extract_signals(counted(tl.fetch_lines(u)), sig)
        except Exception as e:  # a dead or refused link must not stop triage
            print(f'attachment not read ({type(e).__name__}): {u}')
        readable += count[0] > 0
    signals = tl.finish_signals(sig)

    symptoms = tl.parse_symptoms((Path(a.docs) / 'agents' / 'symptoms.md').read_text(encoding='utf-8'))
    matches = tl.match_symptoms([l for l, _ in signals['red']], symptoms, a.docs)

    data = {
        'issue': {'number': issue['number'], 'title': title, 'body': body[:BODY_CAP], 'body_truncated': len(body) > BODY_CAP,
                  'author_association': issue.get('author_association')},
        'form': analyse_form(body, readable),
        'log_signals': {'red': [{'line': l, 'count': c} for l, c in signals['red']],
                        'crash': [{'line': l, 'count': c} for l, c in signals['crash']],
                        'fork_patches': signals['fork_patches'], 'attachments_found': len(urls), 'attachments_read': readable},
        'symptom_matches': matches,
        'duplicate_candidates': candidates(a.repo, issue['number'], title),
        'allowed_labels': ALLOWED_LABELS,
    }
    prompt = build_prompt(Path(a.prompt).read_text(encoding='utf-8'), data)
    (out / 'input.json').write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding='utf-8', errors='replace')
    (out / 'prompt.txt').write_text(prompt, encoding='utf-8', errors='replace')
    set_output(skip='false', reason='')
    return 0


if __name__ == '__main__':
    sys.exit(main())
