"""Build-script notes that the Qt window shows as popups. No Qt in here, so the tests run anywhere.

The Mac app matches the same text (`NXCore/BuildNotes.swift`).
"""
from __future__ import annotations

# Printed by build_ipa_from_nsp.py before it rebuilds the shader libraries (with the `shaders_stale` event), then its reason
STALE_SHADERS = '[NOTE] cached shader libraries cannot be reused'
CHAIN_REASON = 'the translation chain changed'   # the reason the popup's text describes: a new shader translator


def chain_changed(text: str) -> bool:
    """Whether text holds the note for a changed shader translator."""
    return STALE_SHADERS in text and CHAIN_REASON in text
