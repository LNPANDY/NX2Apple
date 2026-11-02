"""Language choice: a device whose language has a file in `frontend/l10n` uses that catalog, any other uses English.

The languages, their own names and the locale prefixes that select them are read from the files (`l10n.py`),
so a new language is a new file and no change here.
"""
from __future__ import annotations

import locale
import os
import re
import sys
from dataclasses import dataclass

from . import l10n

FALLBACK = 'en'   # a device language that has no file gets English


def selects(low: str, locale_name: str) -> bool:
    """Does the lowercased locale `low` belong to the language that lists `locale_name`?

    A language tag matches by prefix, "fr" alone or followed by a separator (fr_FR, fr-CA, fr_BE.UTF-8) and
    not a longer code such as "fry" (Frisian). A locale name (Windows spells it out: "French_France",
    "Chinese (Simplified)_China") is longer than a code and matches anywhere in the text.
    """
    if len(locale_name) > 3 and locale_name in low:
        return True
    return re.match(re.escape(locale_name) + r'(?![a-z])', low) is not None


def match(low: str, languages: list[l10n.Language]) -> str | None:
    """The code of the first language one of whose locales selects `low`, None when none does."""
    for language in languages:
        if any(selects(low, name) for name in language.locales):
            return language.code
    return None


@dataclass(frozen=True)
class Lang:
    """A language of the launcher, identified by its code: the name of its file in `frontend/l10n`."""
    code: str

    @staticmethod
    def all() -> list[Lang]:
        """Every language that has a file, in picker order."""
        return [Lang(language.code) for language in l10n.LANGUAGES]

    @staticmethod
    def find(code: str) -> Lang | None:
        return next((lang for lang in Lang.all() if lang.code == code), None)

    @property
    def _language(self) -> l10n.Language | None:
        return next((language for language in l10n.LANGUAGES if language.code == self.code), None)

    @property
    def name(self) -> str:
        """The language's own name (Svenska, Deutsch), or its code when no file has it."""
        language = self._language
        return language.name if language else self.code

    @property
    def locales(self) -> tuple[str, ...]:
        language = self._language
        return language.locales if language else (self.code,)

    @property
    def other(self) -> Lang:
        """The next language in the picker's order, after the last the first (the language button cycles)."""
        everyone = Lang.all()
        if self not in everyone:
            return everyone[0] if everyone else self
        return everyone[(everyone.index(self) + 1) % len(everyone)]

    @property
    def toggle_label(self) -> str:
        """What the language button says: the next language's own name, "EN" for English."""
        nxt = self.other
        return 'EN' if nxt.code == FALLBACK else nxt.name

    @staticmethod
    def detect(tag: str, languages: list[l10n.Language] | None = None) -> Lang:
        """The language a lowercased locale or language tag selects, else English."""
        code = match(tag, l10n.LANGUAGES if languages is None else languages)
        return Lang(code or FALLBACK)

    @staticmethod
    def initial() -> Lang:
        """Saved choice, else the device language: one that has a file (by language code or Windows locale
        name) uses its own catalog, everything else is English (the same rule the SwiftUI app uses)."""
        saved = Lang.find(os.environ.get('NSPB_LANG', ''))
        if saved:
            return saved
        if sys.platform.startswith('win'):
            # Ask Windows first, and always — not only when locale.getlocale() came back empty.
            # The **user's** UI language, not the system's: a Chinese Windows install on
            # English-labelled hardware (most handhelds ship en-US as the OS locale) has
            # LOCALE_SYSTEM_DEFAULT = en. GetUserDefaultUILanguage is what the Settings app's
            # display language reflects.
            #
            # This used to run only `if not tag`, and locale.getlocale() on Windows almost never
            # returns empty: it returns the *locale name* ("Chinese (Simplified)_China"), which is
            # not a BCP-47 tag, so `startswith('zh')` was False and the branch that knew better
            # never ran. A Chinese user therefore got an English interface whatever the API said
            # (the Windows report of "the exe is still not Chinese").
            import ctypes
            try:
                lang = ctypes.windll.kernel32.GetUserDefaultUILanguage() & 0x3FF   # LANGID: the primary language
                buf = ctypes.create_unicode_buffer(85)
                # LOCALE_SISO639LANGNAME (0x59) is the ISO 639 code ("zh", "sv", "de"). 0x02 (LOCALE_SLANGUAGE)
                # is the *localized display name* — "中文(简体，中国)" — so a Chinese Windows never matched
                # the prefix test here and the early return handed that user an English interface.
                if ctypes.windll.kernel32.GetLocaleInfoW(lang, 0x00000059, buf, 85):
                    low = buf.value.strip().lower()
                    if low:                    # a real code: its language, or English when we have no file for it
                        return Lang.detect(low)
            except Exception:
                pass          # fall through to the environment
        try:
            tag = locale.getlocale()[0] or ''
        except (ValueError, TypeError):
            tag = ''
        tag = tag or os.environ.get('LANG', '') or os.environ.get('LC_ALL', '')
        # On Windows the locale name is spelled out ("Chinese (Simplified)_China"), so the prefix
        # test alone misses every Chinese install there; the name is in the file's `locales`.
        return Lang.detect(tag.lower())
