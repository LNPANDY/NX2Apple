#!/usr/bin/env python3
"""Verify that every DM_* switch named in draft Markdown or text files exists in docs/env_switches.tsv.

Usage:
  python3 tools/verify_env_switches.py [--table PATH] <file>...
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
DEFAULT_TABLE = REPO / 'engine' / 'docs' / 'env_switches.tsv'
NAME = r'DM_[A-Z0-9_]*[A-Z0-9]'


def verify_texts(paths: list[str | Path], table: Path = DEFAULT_TABLE) -> tuple[list[tuple[str, str]], int]:
    """Return ([(path, unknown_name), ...], known_count).

    Every DM_* name mentioned in `paths` must either be a row in `table` or belong to a documented
    prefix/family (such as `DM_PROF_<key>` or a prefix literal ending in `_` like `DM_NVN_*`).
    """
    if not table.is_file():
        raise FileNotFoundError(f'{table} is missing: run `python3 tools/engine.py sync` first')
    known: set[str] = set()
    family: set[str] = set()
    for line in table.read_text(encoding='utf-8').splitlines():
        fields = line.split('\t')
        if not fields or not fields[0].startswith('DM_'):
            continue
        known.add(fields[0])
        for m in re.finditer(r'(' + NAME + r')_[<*]', '\t'.join(fields[1:])):
            family.add(m.group(1))
    bad: list[tuple[str, str]] = []
    for p in paths:
        text = Path(p).read_text(encoding='utf-8', errors='replace')
        for n in sorted(set(re.findall(NAME, text))):
            if n.endswith('_'):
                continue
            if n not in known and not any(k.startswith(n + '_') for k in known) and n not in family:
                bad.append((str(p), n))
    return bad, len(known)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--table', type=Path, default=DEFAULT_TABLE, help='path to env_switches.tsv (default: engine/docs/env_switches.tsv)')
    ap.add_argument('files', nargs='+', help='draft files to inspect')
    args = ap.parse_args(argv)
    try:
        problems, known = verify_texts(args.files, args.table)
    except FileNotFoundError as e:
        print(f'verify_env_switches.py: {e}', file=sys.stderr)
        return 2
    for p, n in problems:
        print(f'{p}: {n} is not a switch the sources read')
    print(f'{len(problems)} unknown name(s) against {known} known switches')
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main())
