"""Small helpers between the model's answer and the release (standard library only).

  clean RAW OUT        write the answer to OUT without a code fence around the whole text and without blank edges. Exit 1 when it is empty.
                       The rules of the text itself are checked by `tools/release_notes.py check`, not here.
  title FILE TAG       print the release title from the first line of FILE, which must be the bold line `**vX.Y.Z: English / Chinese**` with
                       the version of TAG. Prints nothing (exit 0) when the line cannot be read, so the title stays as it is.
"""
import re
import sys

TITLE_LINE = re.compile(r'^\*\*(v\d+\.\d+\.\d+): (.+?) / (.+?)\*\*$')
BAD_TITLE_CHARS = re.compile(r'[`@#<>\\"\x00-\x1f\x7f]')
MAX_TITLE = 150


def clean(raw):
    text = raw.replace('\r\n', '\n').lstrip('﻿').strip()
    lines = text.split('\n')
    if len(lines) >= 2 and re.match(r'^```[A-Za-z]*$', lines[0].strip()) and lines[-1].strip() == '```':
        text = '\n'.join(lines[1:-1]).strip()
    return text + '\n' if text else ''


def title_from(text, tag):
    """`vX.Y.Z: English / Chinese` from the first line, or ''."""
    first = text.lstrip().split('\n', 1)[0].strip()
    m = TITLE_LINE.match(first)
    if not m or m.group(1) != tag:
        return ''
    english, chinese = (part.strip().rstrip('.。').strip() for part in (m.group(2), m.group(3)))
    title = '%s: %s / %s' % (tag, english, chinese)
    if not english or not chinese or len(title) > MAX_TITLE or BAD_TITLE_CHARS.search(title) or '/' in english or '/' in chinese:
        return ''
    return title


def main(argv):
    if len(argv) == 4 and argv[1] == 'clean':
        with open(argv[2], encoding='utf-8', errors='replace') as f:
            text = clean(f.read())
        if not text:
            print('the answer is empty', file=sys.stderr)
            return 1
        with open(argv[3], 'w', encoding='utf-8') as f:
            f.write(text)
        return 0
    if len(argv) == 4 and argv[1] == 'title':
        try:
            with open(argv[2], encoding='utf-8') as f:
                print(title_from(f.read(), argv[3]))
        except (OSError, UnicodeDecodeError):
            print('')
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv))
