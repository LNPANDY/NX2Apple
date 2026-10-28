"""Write half of issue triage: validate the model's JSON strictly, then add labels and post (or update) one comment.

Runs in a job with `issues: write` and no model token. The model's output is untrusted (the issue it read may have steered it), so
nothing in it is applied unless every check passes; a failed check applies nothing and fails the job. This script never closes an
issue, edits one, removes a label or touches code.

  schema      exactly {"labels": [str], "comment": str, "duplicates": [int]}
  labels      each from ALLOWED_LABELS, no repeats, at most 4; labels the repository does not have are skipped (never created)
  duplicates  at most 3 issue numbers, each a candidate that triage_prepare.py found, not the issue itself, and existing in this repository
  mode        TRIAGE_MODE: `post` posts the comment; `report` (default, also for any other value) only adds labels and writes the comment
              to the job summary and triage-<issue>.md
  comment     at most 1500 characters; no @-mention, no HTML, no images; links only into github.com/LNPANDY/NX2Apple and
              github.com/seedds/nxnative (the README is the first), judged on the normalised path; Markdown reference definitions, `//host`
              and dotted words that are not file names are rejected; an issue number may only be the issue itself or a gathered candidate
"""
import argparse
import json
import os
import re
import urllib.parse
import subprocess
import sys
from pathlib import Path

ALLOWED_LABELS = ['game', 'build', 'launcher', 'ios', 'mac', 'idea', 'question', 'needs-info', 'duplicate']
MAX_LABELS = 4
MAX_DUPLICATES = 3
MAX_COMMENT = 1500
MAX_RAW = 20000
MODES = ('report', 'post')
MARKER = '<!-- nx2apple-triage -->'
FOOTER = '_Automated first look (AI-assisted, from the issue form and the log). A maintainer will follow up._'

ALLOWED_REPOS = {('lnpandy', 'nx2apple'), ('seedds', 'nxnative')}   # any path inside them is allowed, e.g. /discussions and /discussions/categories/q-a
# Anything that can become a link: a scheme, `www.`, a protocol-relative `//host`. Bare domains are found separately.
ANY_URL = re.compile(r'(?:[a-z][a-z0-9+.-]*://|www\.|mailto:|javascript:|data:)\S*', re.I)
BARE_GITHUB = re.compile(r'(?<![\w./-])github\.com/\S*', re.I)
REF_DEF = re.compile(r'^[ ]{0,3}\[[^\]\n]+\]:[ \t]*(\S*)', re.M)
INLINE_TARGET = re.compile(r'\]\(\s*<?([^)\s>]*)')
DOMAIN_LIKE = re.compile(r'(?<![\w@/-])[a-z0-9][a-z0-9_-]*(?:\.[a-z0-9][a-z0-9_-]*)+(?![\w-])', re.I)
# A dotted word is a file name, not a host, when its last part is one of these (or a number: 0.4.9, 26.1). Anything else is rejected.
FILE_EXT = set('txt log md py sh swift c h m mm cpp hpp tsv json yml yaml toml plist zip pdf png jpg jpeg gif ipa nsp nsz xci nso nro js ts rs cs csv ini lock metal msl'.split())
TRAIL = ')]>.,;:!*_\'"`'
ISSUE_REF = re.compile(r'(?<![\w&/])#(\d+)\b')
ISSUE_URL_NUM = re.compile(r'/(?:issues|pull|discussions)/(\d+)', re.I)


def allowed_url(url):
    """https://github.com/LNPANDY/NX2Apple... or .../seedds/nxnative..., judged on the normalised path: no userinfo, no port, no dot segments
    (encoded or not), no backslashes, so `.../NX2Apple/../../evil/repo` is not inside the repository."""
    try:
        u = urllib.parse.urlsplit(url)
        port = u.port
    except ValueError:
        return False
    if u.scheme.lower() != 'https' or (u.hostname or '') != 'github.com' or u.username is not None or u.password is not None or port is not None:
        return False
    if u.netloc.lower() != 'github.com':
        return False
    path = u.path
    for _ in range(4):                       # decode to a fixed point: %2e%2e, %252e%252e
        nxt = urllib.parse.unquote(path)
        if nxt == path:
            break
        path = nxt
    else:
        return False
    if '\\' in path or any(ord(c) < 32 for c in path):
        return False
    segs = path.split('/')
    if any(sg in ('.', '..') for sg in segs):
        return False
    parts = [sg for sg in segs if sg]
    return len(parts) >= 2 and (parts[0].lower(), parts[1].lower()) in ALLOWED_REPOS


class Invalid(ValueError):
    pass


def parse_output(raw):
    """The model's text as the JSON object it must be: raw JSON, or one fenced block that holds it."""
    if len(raw) > MAX_RAW:
        raise Invalid('output too long')
    text = raw.strip()
    m = re.fullmatch(r'```(?:json)?\s*\n(.*)\n```', text, re.S)
    if m:
        text = m[1].strip()
    try:
        obj = json.loads(text)
    except ValueError as e:
        raise Invalid(f'not JSON: {e}')
    if not isinstance(obj, dict) or set(obj) != {'labels', 'comment', 'duplicates'}:
        raise Invalid('keys must be exactly labels, comment, duplicates')
    return obj


def check_comment(text, issue_refs=frozenset()):
    """Reject a comment that could carry anything but plain text and links into the two allowed repositories.
    `issue_refs`: the issue numbers the comment may name (the issue itself and the gathered duplicate candidates)."""
    if not isinstance(text, str):
        raise Invalid('comment is not a string')
    if len(text) > MAX_COMMENT:
        raise Invalid('comment too long')
    if re.search(r'[\x00-\x08\x0b-\x1f\x7f]', text):
        raise Invalid('control characters in comment')
    if re.search(r'@\w', text):
        raise Invalid('@-mention in comment')
    if re.search(r'<[A-Za-z/!?]', text) or '![' in text:
        raise Invalid('HTML or image in comment')
    nums = set()
    for m in ANY_URL.finditer(text):
        url = m.group(0).rstrip(TRAIL)
        if not allowed_url(url):
            raise Invalid(f'link not allowed: {url[:60]}')
        nums.update(int(n) for n in ISSUE_URL_NUM.findall(urllib.parse.unquote(url)))
    for m in BARE_GITHUB.finditer(text):
        url = 'https://' + m.group(0).rstrip(TRAIL)
        if not allowed_url(url):
            raise Invalid(f'link not allowed: {m.group(0)[:60]}')
        nums.update(int(n) for n in ISSUE_URL_NUM.findall(urllib.parse.unquote(url)))
    targets = [t for t in REF_DEF.findall(text)] + INLINE_TARGET.findall(text)
    for t in targets:
        if not (t.startswith('#') or allowed_url(t.rstrip(TRAIL))):
            raise Invalid(f'link target not allowed: {t[:60]}')
    # what is left once the allowed links are removed must hold no host, no `//host`, no dotted word that is not a file name or a number
    rest = ANY_URL.sub(' ', text)
    rest = BARE_GITHUB.sub(' ', rest)
    if re.search(r'(?<!:)//\S', rest) or re.search(r'(?<![\w])\\\\\S', rest):
        raise Invalid('protocol-relative link in comment')
    for m in DOMAIN_LIKE.finditer(rest):
        last = m.group(0).rsplit('.', 1)[1].lower()
        if last.isdigit() or last in FILE_EXT:
            continue
        raise Invalid(f'domain in comment: {m.group(0)[:60]}')
    if re.search(r'[\w.-]+/[\w.-]+#\d+', rest):
        raise Invalid('cross-repository reference in comment')
    nums.update(int(n) for n in ISSUE_REF.findall(rest))
    nums.update(int(n) for n in ISSUE_REF.findall(' '.join(targets)))
    bad = sorted(n for n in nums if n not in issue_refs)
    if bad:
        raise Invalid(f'issue reference not known: #{bad[0]}')


def validate(raw, issue, candidates, exists):
    """Return (labels, comment, duplicates) or raise Invalid. `candidates`: the numbers triage_prepare found; `exists(n)`: the issue is in this repository."""
    obj = parse_output(raw)
    labels, comment, dups = obj['labels'], obj['comment'], obj['duplicates']
    if not isinstance(labels, list) or not all(isinstance(l, str) for l in labels):
        raise Invalid('labels must be a list of strings')
    if len(set(labels)) != len(labels) or len(labels) > MAX_LABELS:
        raise Invalid('labels repeat or exceed the limit')
    bad = [l for l in labels if l not in ALLOWED_LABELS]
    if bad:
        raise Invalid(f'labels not on the allow-list: {bad[:3]}')
    if not isinstance(dups, list) or any(type(n) is not int for n in dups):
        raise Invalid('duplicates must be a list of integers')
    if len(set(dups)) != len(dups) or len(dups) > MAX_DUPLICATES:
        raise Invalid('duplicates repeat or exceed the limit')
    for n in dups:
        if n == issue or n not in candidates or not exists(n):
            raise Invalid(f'duplicate #{n} is not a known other issue of this repository')
    check_comment(comment, set(candidates) | {issue})
    if not dups and 'duplicate' in labels:
        labels = [l for l in labels if l != 'duplicate']   # a label without a target is dropped, not applied
    return labels, comment, dups


def build_comment(comment, dups):
    parts = [comment.strip()] if comment.strip() else []
    if dups:
        parts.append('Possibly the same problem as: ' + ', '.join(f'#{n}' for n in dups))
    if not parts:
        return ''
    return '\n\n'.join(parts + [FOOTER, MARKER])


def resolve_mode(value):
    """`post` only for exactly "post" (a trailing newline or spaces are tolerated); anything else, unset or misspelled, is `report`."""
    return 'post' if isinstance(value, str) and value.strip() == 'post' else 'report'


def report_text(issue, repo, labels, dups, body):
    """The Markdown of a report-mode run: what was labelled and the comment that would have been posted, as a quoted block."""
    quoted = '\n'.join('> ' + ln if ln else '>' for ln in body.splitlines()) if body else '> _(no comment)_'
    return (f'## Triage of [#{issue}](https://github.com/{repo}/issues/{issue}) (report mode: nothing posted)\n\n'
            f'Labels added: {", ".join(labels) if labels else "none"}\n\n'
            f'Duplicates: {", ".join(f"#{n}" for n in dups) if dups else "none"}\n\n'
            f'Comment it would post:\n\n{quoted}\n')


def gh(*args, check=True):
    r = subprocess.run(['gh', *args], capture_output=True, text=True, timeout=60)
    if check and r.returncode:
        raise SystemExit(f'gh {args[0]} failed: {r.stderr.strip()[:300]}')
    return r


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--repo', required=True)
    ap.add_argument('--issue', type=int, required=True)
    ap.add_argument('--input', required=True, help='input.json of triage_prepare.py')
    ap.add_argument('--result', required=True, help="the model's output")
    ap.add_argument('--dry-run', action='store_true')
    ap.add_argument('--mode', default=os.environ.get('TRIAGE_MODE', ''), help='report (default) or post; anything else is report')
    ap.add_argument('--report-dir', default='.', help='report mode: where triage-<issue>.md is written')
    a = ap.parse_args(argv)

    data = json.loads(Path(a.input).read_text(encoding='utf-8'))
    cands = {c['number'] for c in data['duplicate_candidates']}
    exists = lambda n: gh('api', f'repos/{a.repo}/issues/{n}', check=False).returncode == 0
    try:
        labels, comment, dups = validate(Path(a.result).read_text(encoding='utf-8', errors='replace'), a.issue, cands, exists)
    except Invalid as e:
        print(f'::error::triage output rejected, nothing applied: {e}')
        return 1
    body = build_comment(comment, dups)

    have = {l['name'] for l in json.loads(gh('label', 'list', '-R', a.repo, '--limit', '200', '--json', 'name').stdout)}
    use = [l for l in labels if l in have]
    for l in labels:
        if l not in have:
            print(f'::notice::label {l!r} does not exist in {a.repo}, skipped')
    print(f'labels: {use}\nduplicates: {dups}\ncomment:\n{body}')
    mode = resolve_mode(a.mode)
    print(f'mode: {mode}')
    if a.dry_run:
        return 0
    if use:
        gh('issue', 'edit', str(a.issue), '-R', a.repo, '--add-label', ','.join(use))
    if mode == 'report':   # labels are internal; the comment goes to the job summary and an artifact, never to the issue
        text = report_text(a.issue, a.repo, use, dups, body)
        Path(a.report_dir, f'triage-{a.issue}.md').write_text(text, encoding='utf-8')
        summary = os.environ.get('GITHUB_STEP_SUMMARY')
        if summary:
            with open(summary, 'a', encoding='utf-8') as f:
                f.write(text + '\n')
        return 0
    if body:
        old = gh('api', f'repos/{a.repo}/issues/{a.issue}/comments', '--paginate', '--jq',
                 '.[] | select(.user.type == "Bot" and (.body | contains("%s"))) | .id' % MARKER).stdout.split()
        if old:   # a re-run updates the earlier comment: one comment per issue
            gh('api', '-X', 'PATCH', f'repos/{a.repo}/issues/comments/{old[0]}', '-f', f'body={body}')
        else:
            gh('issue', 'comment', str(a.issue), '-R', a.repo, '--body', body)
    return 0


if __name__ == '__main__':
    sys.exit(main())
