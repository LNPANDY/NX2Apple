#!/usr/bin/env python3
"""The notes of a final release: a reviewed file per version plus the notes GitHub generates (RELEASING.md, "Release notes").

release-notes/vX.Y.Z.md is written by a person or an agent in a normal pull request before the final tag, in the form of
.github/release_notes_template.md (an English part, then a Chinese part, no generated block). When the final tag is built, CI runs `build`:
the file, a `---` line, then the generated notes (merged pull requests with their authors, first-time contributors, the Full Changelog link)
appended unchanged.

Subcommands (Python 3.9+, no packages):
  check FILE...                lint notes files: no emojis, pictograms or symbols, no semicolons (also the full-width one), no em-dashes or
                               en-dashes, a `## English` and then a `## 中文` section, no template comments or placeholders, no generated block.
                               Exit 1 when any file has a problem, and print every problem as file:line.
  previous TAG [--remote R]    print the newest final tag (no `-rc`) before TAG, read from `git ls-remote --tags R` (default origin).
                               Prints nothing when there is none.
  build TAG --out FILE [--previous TAG0] [--file NOTES] [--short-body FILE] [--repo OWNER/NAME]
                               write the release body to FILE. With an existing NOTES file (checked first, a bad file is an error) the body is
                               that file. Without one it is the short body from --short-body (the text CI wrote before this tool existed).
                               Either way `---` and the output of
                                 gh api -X POST repos/OWNER/NAME/releases/generate-notes -f tag_name=TAG -f previous_tag_name=TAG0 --jq .body
                               follow. Nothing is published: `gh release create --notes-file FILE` does that, in the workflow.
"""
import argparse
import os
import re
import subprocess
import sys
import unicodedata

DEFAULT_REPO = 'LNPANDY/NX2Apple'
FINAL_TAG = re.compile(r'^v(\d+)\.(\d+)\.(\d+)$')

HEADING_ZH = '## 中文'
HEADING_EN = '## English'

SEMICOLONS = {';': 'semicolon', '；': 'full-width semicolon', '﹔': 'small semicolon', ';': 'Greek question mark (looks like a semicolon)'}
DASHES = {'—': 'em-dash', '–': 'en-dash', '―': 'horizontal bar', '⸺': 'two-em dash', '⸻': 'three-em dash',
          '﹘': 'small em-dash', '﹣': 'small hyphen-minus', '－': 'full-width hyphen-minus'}

# Left behind when the template is copied and not finished.
PLACEHOLDERS = [
    (re.compile(r'<!--|-->'), 'a template comment'),
    (re.compile(r'\bv?X\.Y\.Z\b'), 'the placeholder vX.Y.Z'),
    (re.compile(r'(?<![\w&])#[NM]\b'), 'the placeholder #N or #M'),
    (re.compile(r'\b(?:TODO|TBD|FIXME)\b'), 'a TODO marker'),
    (re.compile(r'the one thing this release is about|Name of the feature|Lead of the (?:change|fix|issue)|One point\b', re.I), 'template text'),
    (re.compile(r'一个要点|功能的名称|改动的标题|修复的标题|问题的标题'), 'template text'),
]
# The generated block is added by `build`, never written into the file.
GENERATED = [
    (re.compile(r"^#+\s*What's Changed\b", re.I), 'the generated block (build adds it)'),
    (re.compile(r'\*\*Full Changelog\*\*|^Full Changelog\b', re.I), 'the Full Changelog link (build adds it)'),
    (re.compile(r'^#+\s*New Contributors\b', re.I), 'the generated block (build adds it)'),
]


def symbol_problem(ch):
    """Why a character is an emoji, a pictogram or a symbol, or None. ASCII and normal text (Latin, CJK, punctuation) pass."""
    if ord(ch) < 0x80:
        return None
    cat = unicodedata.category(ch)
    if cat in ('So', 'Sm', 'Sk', 'Sc'):
        return 'a symbol or pictogram'
    if cat in ('Cs', 'Co'):
        return 'a private or surrogate code point'
    if ch in '‍​‌⁠﻿':
        return 'an invisible character (emoji joiner or zero-width)'
    if '︀' <= ch <= '️' or cat == 'Me':
        return 'an emoji variation selector or keycap'
    if '\U0001f3fb' <= ch <= '\U0001f3ff':
        return 'an emoji skin tone'
    if '\U000e0000' <= ch <= '\U000e007f':
        return 'an emoji tag character'
    return None


def check_text(text):
    """Problems of one notes file as a list of (line number, message)."""
    problems = []
    zh = en = None
    in_comment = False
    for no, line in enumerate(text.splitlines(), 1):
        if line.rstrip() == HEADING_ZH:
            if zh is not None:
                problems.append((no, 'the section "%s" appears twice' % HEADING_ZH))
            zh = zh if zh is not None else no
        elif line.rstrip() == HEADING_EN:
            if en is not None:
                problems.append((no, 'the section "%s" appears twice' % HEADING_EN))
            en = en if en is not None else no
        for ch in line:
            if ch in SEMICOLONS:
                problems.append((no, 'no semicolons (found a %s)' % SEMICOLONS[ch]))
            elif ch in DASHES:
                problems.append((no, 'no em-dashes or en-dashes (found %s U+%04X)' % (DASHES[ch], ord(ch))))
            else:
                why = symbol_problem(ch)
                if why:
                    problems.append((no, 'no emojis, pictograms or symbols (found %s U+%04X, %s)' % (ch, ord(ch), why)))
        for pattern, what in PLACEHOLDERS + GENERATED:
            if pattern.search(line):
                problems.append((no, 'leftover from the template: %s' % what))
    if zh is None:
        problems.append((1, 'the section "%s" is missing' % HEADING_ZH))
    if en is None:
        problems.append((1, 'the section "%s" is missing' % HEADING_EN))
    if zh is not None and en is not None and en > zh:
        problems.append((en, 'the English part comes first: "%s" before "%s"' % (HEADING_EN, HEADING_ZH)))
    if zh is not None and en is not None:
        lines = text.splitlines()
        first, second = sorted((zh, en))
        for start, end, name in ((first, second, lines[first - 1].strip()), (second, len(lines) + 1, lines[second - 1].strip())):
            body = [l for l in lines[start:end - 1] if l.strip() and l.strip() != '---']
            if not body:
                problems.append((start, 'the section "%s" is empty' % name))
    # One report per line and message, not one per character.
    seen, unique = set(), []
    for item in problems:
        if item not in seen:
            seen.add(item)
            unique.append(item)
    return unique


def check_file(path):
    try:
        with open(path, encoding='utf-8') as f:
            text = f.read()
    except FileNotFoundError:
        return [(0, 'the file does not exist')]
    except UnicodeDecodeError:
        return [(0, 'the file is not UTF-8')]
    return check_text(text)


def cmd_check(args):
    bad = 0
    for path in args.files:
        problems = check_file(path)
        for no, message in problems:
            print('%s:%d: %s' % (path, no, message))
            if os.environ.get('GITHUB_ACTIONS'):
                print('::error file=%s,line=%d,title=Release notes::%s' % (path, max(no, 1), message))
        if problems:
            bad += 1
        else:
            print('%s: ok' % path)
    if bad:
        print('%d of %d file(s) have problems. The rules are in RELEASING.md, "Release notes".' % (bad, len(args.files)), file=sys.stderr)
    return 1 if bad else 0


def final_key(tag):
    m = FINAL_TAG.match(tag)
    return tuple(int(x) for x in m.groups()) if m else None


def previous_final(tag, tags):
    """The newest final tag (vX.Y.Z, no -rc) that is older than `tag`, or ''."""
    me = final_key(tag)
    if me is None:
        raise ValueError('%r is not a final tag (vX.Y.Z)' % tag)
    older = [(final_key(t), t) for t in set(tags) if final_key(t) is not None and final_key(t) < me]
    return max(older)[1] if older else ''


def remote_tags(remote):
    out = subprocess.run(['git', 'ls-remote', '--tags', remote], capture_output=True, text=True, check=True).stdout
    tags = []
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[1].startswith('refs/tags/') and not parts[1].endswith('^{}'):
            tags.append(parts[1][len('refs/tags/'):])
    return tags


def cmd_previous(args):
    try:
        print(previous_final(args.tag, remote_tags(args.remote)))
    except (ValueError, subprocess.CalledProcessError) as e:
        print('previous: %s' % e, file=sys.stderr)
        return 1
    return 0


def generated_notes(repo, tag, previous):
    cmd = ['gh', 'api', '-X', 'POST', 'repos/%s/releases/generate-notes' % repo, '-f', 'tag_name=%s' % tag]
    if previous:
        cmd += ['-f', 'previous_tag_name=%s' % previous]
    cmd += ['--jq', '.body']
    body = subprocess.run(cmd, capture_output=True, text=True, check=True).stdout.rstrip('\n')
    if not body.strip():
        raise RuntimeError('GitHub returned empty generated notes')
    return body


def cmd_build(args):
    if final_key(args.tag) is None:
        print('build: %r is not a final tag (vX.Y.Z)' % args.tag, file=sys.stderr)
        return 1
    if args.file and os.path.exists(args.file):
        problems = check_file(args.file)
        if problems:
            for no, message in problems:
                print('%s:%d: %s' % (args.file, no, message), file=sys.stderr)
            print('build: %s fails the check' % args.file, file=sys.stderr)
            return 1
        with open(args.file, encoding='utf-8') as f:
            head = f.read().strip()
    elif args.short_body:
        with open(args.short_body, encoding='utf-8') as f:
            head = f.read().strip()
        print('build: %s, the body is the short one' % ('%s does not exist' % args.file if args.file else 'no notes file'), file=sys.stderr)
    else:
        print('build: no notes file and no --short-body', file=sys.stderr)
        return 1
    try:
        generated = generated_notes(args.repo, args.tag, args.previous)
    except (subprocess.CalledProcessError, OSError, RuntimeError) as e:
        detail = getattr(e, 'stderr', '') or e
        print('build: the generated notes failed: %s' % str(detail).strip(), file=sys.stderr)
        return 1
    with open(args.out, 'w', encoding='utf-8') as f:
        f.write('%s\n\n---\n\n%s\n' % (head, generated))
    print('build: wrote %s (previous tag %s)' % (args.out, args.previous or 'none'))
    return 0


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    sub = p.add_subparsers(dest='cmd', required=True)
    c = sub.add_parser('check')
    c.add_argument('files', nargs='+')
    c.set_defaults(fn=cmd_check)
    pr = sub.add_parser('previous')
    pr.add_argument('tag')
    pr.add_argument('--remote', default='origin')
    pr.set_defaults(fn=cmd_previous)
    b = sub.add_parser('build')
    b.add_argument('tag')
    b.add_argument('--out', required=True)
    b.add_argument('--previous', default='')
    b.add_argument('--file', default='')
    b.add_argument('--short-body', default='')
    b.add_argument('--repo', default=os.environ.get('GITHUB_REPOSITORY') or DEFAULT_REPO)
    b.set_defaults(fn=cmd_build)
    args = p.parse_args(argv)
    return args.fn(args)


if __name__ == '__main__':
    sys.exit(main())
