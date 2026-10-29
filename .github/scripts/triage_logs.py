"""Log first aid for issue triage: signal lines out of an issue body or attached log, matched against docs/agents/symptoms.md.

Deterministic and stdlib only. The model never sees raw logs, only what this module extracts (capped) and the entries it matches.
Used by triage_prepare.py; tests are in .github/scripts/tests.
"""
import re
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

REPO_URL = 'https://github.com/LNPANDY/NX2Apple'
BLOB = REPO_URL + '/blob/main/'

MAX_FETCH_BYTES = 8 * 1024 * 1024      # per attachment; read in chunks, only signal lines are kept
FETCH_TIMEOUT = 15                      # seconds, per request
MAX_ATTACHMENTS = 3
MAX_LINE = 300                          # characters kept per signal line
MAX_SIGNAL_LINES = 25                   # per kind

# Hosts an attachment may be fetched from, and hosts a redirect may land on (GitHub serves attachments from its own storage).
ATTACHMENT_URL = re.compile(
    r'https://(?:github\.com/user-attachments/(?:files|assets)/[^\s)>\]"\'<]+'
    r'|user-images\.githubusercontent\.com/[^\s)>\]"\'<]+'
    r'|github\.com/[\w.-]+/[\w.-]+/files/\d+/[^\s)>\]"\'<]+)')
REDIRECT_HOSTS = {'github.com', 'user-images.githubusercontent.com', 'objects.githubusercontent.com',
                  'release-assets.githubusercontent.com', 'private-user-images.githubusercontent.com'}

RED = re.compile(r'\[RED\] ')
CRASH = re.compile(r'CRASH sig=\d+|\bSIG(?:SEGV|ABRT|BUS|ILL|TRAP)\b|\bEXC_[A-Z_]+\b|Fatal error|[Aa]ssertion .{0,200}failed|\bTermination Reason\b')
FORK_PATCHES = re.compile(r'fork patches:', re.I)


def _clip(line):
    line = line.strip()
    return line if len(line) <= MAX_LINE else line[:MAX_LINE] + ' [...]'


def extract_signals(lines, signals=None):
    """Collect [RED] lines, crash lines and the `fork patches:` line from an iterable of text lines.

    Repeats are folded (a [RED] line logged a thousand times is one entry with a count). Returns
    {'red': [(line, count)], 'crash': [(line, count)], 'fork_patches': [line]}; pass `signals` to add to an earlier result.
    """
    sig = signals or {'red': {}, 'crash': {}, 'fork_patches': []}
    for raw in lines:
        if RED.search(raw):
            kind = 'red'
        elif CRASH.search(raw):
            kind = 'crash'
        elif FORK_PATCHES.search(raw):
            if len(sig['fork_patches']) < 3:
                sig['fork_patches'].append(_clip(raw))
            continue
        else:
            continue
        key = _clip(raw)
        # fold lines that differ only in numbers or addresses
        bucket = sig[kind]
        folded = norm(key)
        for k in bucket:
            if norm(k) == folded:
                bucket[k] += 1
                break
        else:
            if len(bucket) < MAX_SIGNAL_LINES:
                bucket[key] = 1
    return sig


def finish_signals(sig):
    return {'red': list(sig['red'].items()), 'crash': list(sig['crash'].items()), 'fork_patches': sig['fork_patches']}


def norm(s):
    """Normalise a line for matching. Only fields that vary between runs become `#`: pointers and addresses (0x with 8 or more hex digits)
    and long decimal numbers (4 or more digits: sizes, counts, timestamps). Result codes and constants (`0xd401`, `0xce01`, `-6`, `+0`) stay literal:
    they are what tells one entry from another."""
    s = re.sub(r'0x[0-9a-fA-F]{8,}', '0x#', s)
    s = re.sub(r'(?<![\w.])\d{4,}(?![\w.])', '#', s)
    return re.sub(r'\s+', ' ', s).strip()


# ---------------------------------------------------------------- symptom index

PLACEHOLDER = re.compile(r'…|\.\.\.|<[^<>`]{1,40}>')
SYMPTOM_LINE = re.compile(r'^- (?P<text>.*) → \[(?P<title>[^\]]+)\]\((?P<href>[^)\s]+)\)\s*$')
MIN_LITERAL = 15      # a fragment needs this many literal characters, or `[RED] x` would match everything


def slug(heading):
    """GitHub's anchor for a heading."""
    return re.sub(r'[^\w\- ]', '', heading.lower()).replace(' ', '-')


def parse_symptoms(text):
    """Entries of docs/agents/symptoms.md: [{'symptom', 'title', 'href', 'fragments': [[pieces]]}] with one fragment per `[RED] ...` span."""
    out = []
    for line in text.splitlines():
        m = SYMPTOM_LINE.match(line)
        if not m:
            continue
        frags = []
        for span in re.findall(r'`([^`]+)`', m['text']):
            if not span.startswith('[RED] '):
                continue
            pieces = [norm(p) for p in PLACEHOLDER.split(span)]
            pieces = [p for p in pieces if p]
            if sum(len(p) for p in pieces) >= MIN_LITERAL:
                frags.append(pieces)
        out.append({'symptom': m['text'], 'title': m['title'], 'href': m['href'], 'fragments': frags})
    return out


def fragment_matches(pieces, line):
    """The literal pieces of a symptom fragment appear in the normalised log line, in order."""
    n = norm(line)
    pos = 0
    for p in pieces:
        i = n.find(p, pos)
        if i < 0:
            return False
        pos = i + len(p)
    return True


def found_on(docs_dir, href):
    """The games of an entry's `Found on` bullet: [{'name', 'title_id', 'url'}]. `href` is the symptom index's relative link."""
    path, _, anchor = href.partition('#')
    f = (Path(docs_dir) / 'agents' / path).resolve()
    ref_root = Path(docs_dir).resolve()
    if not f.is_file() or ref_root not in f.parents:
        return []
    lines = f.read_text(encoding='utf-8').splitlines()
    start = level = None
    for i, line in enumerate(lines):
        m = re.match(r'^(#{2,4}) (.+?)\s*$', line)
        if m and slug(m[2]) == anchor:
            start, level = i + 1, len(m[1])
            break
    if start is None:
        return []
    games, seen, in_found = [], set(), False
    for line in lines[start:]:
        m = re.match(r'^(#{1,6}) ', line)
        if m and len(m[1]) <= level:
            break
        if line.startswith('- **Found on:**'):
            in_found = True
        elif in_found and (line.startswith('- ') or (line.strip() and not line[0].isspace())):
            in_found = False   # the next top-level bullet or paragraph ends the block; indented lines and blanks belong to it
        if in_found:
            for name, tid in re.findall(r'\[([^\]]+)\]\((?:\.\./)*dm/games/([0-9A-Fa-f]{16})/README\.md(?:#[^)\s]*)?\)', line):
                if tid.upper() not in seen:
                    seen.add(tid.upper())
                    games.append({'name': name, 'title_id': tid.upper(), 'url': f'{BLOB}dm/games/{tid.upper()}/README.md'})
    return games[:6]


def entry_url(href):
    """The GitHub URL of an entry linked from the symptom index (docs/agents/symptoms.md links ../reference/x.md#anchor)."""
    path, _, anchor = href.partition('#')
    parts = [p for p in ('docs', 'agents', *path.split('/')) if p]
    stack = []
    for p in parts:
        if p == '..':
            if stack:
                stack.pop()
        else:
            stack.append(p)
    return BLOB + '/'.join(stack) + ('#' + anchor if anchor else '')


def match_symptoms(red_lines, symptoms, docs_dir, limit=5):
    """Each [RED] line against the index. Returns the best hits first: the entry, its link, the matched fragment's text and the games."""
    hits = {}
    for line in red_lines:
        for e in symptoms:
            for pieces in e['fragments']:
                if fragment_matches(pieces, line):
                    score = sum(len(p) for p in pieces)
                    key = e['href']
                    if key not in hits or hits[key]['score'] < score:
                        hits[key] = {'score': score, 'entry': e['title'], 'url': entry_url(e['href']), 'log_line': line,
                                     'symptom': e['symptom'][:400], 'href': e['href']}
    ranked = sorted(hits.values(), key=lambda h: -h['score'])[:limit]
    for h in ranked:
        h['found_on'] = found_on(docs_dir, h.pop('href'))
    return ranked


# ---------------------------------------------------------------- attachments

class _Redirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        u = urllib.parse.urlsplit(newurl)
        if u.scheme != 'https' or u.hostname not in REDIRECT_HOSTS:
            raise urllib.error.URLError(f'redirect to {u.hostname} refused')
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def attachment_urls(text):
    seen = []
    for m in ATTACHMENT_URL.finditer(text or ''):
        u = m.group(0).rstrip('.,;')
        if u not in seen:
            seen.append(u)
    return seen[:MAX_ATTACHMENTS]


def fetch_lines(url, opener=None, max_bytes=MAX_FETCH_BYTES, timeout=FETCH_TIMEOUT):
    """Download an attachment (size cap, timeout, no credentials) and yield its lines. Images and binary files yield nothing."""
    if not ATTACHMENT_URL.fullmatch(url):
        return
    opener = opener or urllib.request.build_opener(_Redirect)
    req = urllib.request.Request(url, headers={'User-Agent': 'nx2apple-triage'})
    with opener.open(req, timeout=timeout) as r:
        ctype = (r.headers.get('Content-Type') or '').lower()
        if ctype.startswith(('image/', 'video/')):
            return
        got, tail = 0, b''
        while got < max_bytes:
            chunk = r.read(min(65536, max_bytes - got))
            if not chunk:
                break
            if b'\0' in chunk:
                return
            got += len(chunk)
            data = tail + chunk
            *whole, tail = data.split(b'\n')
            for b in whole:
                yield b.decode('utf-8', 'replace')
        if tail:
            yield tail.decode('utf-8', 'replace')
