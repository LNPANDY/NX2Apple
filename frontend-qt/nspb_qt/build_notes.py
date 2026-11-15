"""Build-script notes that the Qt window shows as popups. No Qt in here, so the tests run anywhere.

The Mac app gets the same news as the `shaders_stale` event. The Qt window runs the build with `--progress lines`, which sends no
events, so it reads the note that build_ipa_from_nsp.py prints after the event, in every progress mode.
"""
from __future__ import annotations

import re

# The note's start, then its reason
STALE_SHADERS = '[NOTE] cached shader libraries cannot be reused'
REASONS = {
    'the translation chain changed': 'chain',           # a new shader translator
    "the game profile's shader inputs changed": 'inputs',
}
# The popup's text for each reason, as the Mac app picks it
TEXT = {'chain': 'msg.shadersStale.chain', 'inputs': 'msg.shadersStale.inputs'}
TITLE = 'msg.shadersStale.title'

_NOT_CACHED_NUM = r'(?:\d{1,3}(?:[,.\u00a0\u202f ]\d{3})+|\d+)'
_PAREN_NOT_CACHED_RE = re.compile(rf'\s*\(\s*{_NOT_CACHED_NUM}\s+not\s+cached\s*\)', re.IGNORECASE)
_LEADING_SEP_NOT_CACHED_RE = re.compile(
    rf'(?:\s*·\s*|(?<!\d)\s*[,;]\s*|\s*[,;]\s+){_NOT_CACHED_NUM}\s+not\s+cached\b',
    re.IGNORECASE,
)
_STANDALONE_NOT_CACHED_RE = re.compile(
    rf'(?<![\d,.\u00a0\u202f]){_NOT_CACHED_NUM}\s+not\s+cached\b(?:\s*·\s*|\s*[,;]\s+|\s{{2,}})?',
    re.IGNORECASE,
)


def strip_not_cached(text: str) -> str:
    """Remove redundant `<N> not cached` counts from a stage's detail while keeping counts, cached hit notes, and error text."""
    if not text or 'not' not in text.lower():
        return text
    out = _PAREN_NOT_CACHED_RE.sub('', text)
    out = _LEADING_SEP_NOT_CACHED_RE.sub('', out)
    out = _STANDALONE_NOT_CACHED_RE.sub('', out)
    return out.strip()


def stale_reason(text: str) -> str | None:
    """The reason of the stale-shaders note in text, as the event names it: 'chain' or 'inputs'. None when text holds no note."""
    if STALE_SHADERS not in text:
        return None
    return next((reason for words, reason in REASONS.items() if words in text), None)
