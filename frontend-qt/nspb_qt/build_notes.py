"""Build-script notes that the Qt window shows as popups. No Qt in here, so the tests run anywhere.

The Mac app gets the same news as the `shaders_stale` event. The Qt window runs the build with `--progress lines`, which sends no
events, so it reads the note that build_ipa_from_nsp.py prints after the event, in every progress mode.
"""
from __future__ import annotations

# The note's start, then its reason
STALE_SHADERS = '[NOTE] cached shader libraries cannot be reused'
REASONS = {
    'the translation chain changed': 'chain',           # a new shader translator
    "the game profile's shader inputs changed": 'inputs',
}
# The popup's text for each reason, as the Mac app picks it
TEXT = {'chain': 'msg.shadersStale.chain', 'inputs': 'msg.shadersStale.inputs'}
TITLE = 'msg.shadersStale.title'


def stale_reason(text: str) -> str | None:
    """The reason of the stale-shaders note in text, as the event names it: 'chain' or 'inputs'. None when text holds no note."""
    if STALE_SHADERS not in text:
        return None
    return next((reason for words, reason in REASONS.items() if words in text), None)
