"""Language choice: Chinese and Swedish devices use their matching catalog."""
from __future__ import annotations

import locale
import os
import sys
from enum import Enum


class Lang(Enum):
    ZH = 'zh'
    EN = 'en'
    SV = 'sv'

    @property
    def other(self) -> 'Lang':
        return {Lang.ZH: Lang.EN, Lang.EN: Lang.SV, Lang.SV: Lang.ZH}[self]

    @property
    def toggle_label(self) -> str:
        return {Lang.ZH: 'EN', Lang.EN: 'Svenska', Lang.SV: '中文'}[self]

    @staticmethod
    def initial() -> 'Lang':
        """Saved choice, else the device language: any Chinese variant is Chinese, everything
        else is English (the same rule the SwiftUI app uses)."""
        saved = os.environ.get('NSPB_LANG', '')
        if saved in ('zh', 'en', 'sv'):
            return Lang(saved)
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
                lang = ctypes.windll.kernel32.GetUserDefaultUILanguage() & 0xFF   # primary id
                buf = ctypes.create_unicode_buffer(85)
                if ctypes.windll.kernel32.GetLocaleInfoW(lang, 0x00000002, buf, 85):   # LOCALE_SISO639LANGNAME
                    low = buf.value.lower()
                    if low.startswith('zh'):
                        return Lang.ZH
                    return Lang.SV if low.startswith('sv') else Lang.EN
            except Exception:
                pass          # fall through to the environment
        try:
            tag = locale.getlocale()[0] or ''
        except (ValueError, TypeError):
            tag = ''
        tag = tag or os.environ.get('LANG', '') or os.environ.get('LC_ALL', '')
        # On Windows the locale name is spelled out ("Chinese (Simplified)_China"), so the prefix
        # test alone misses every Chinese install there; the name contains "Chinese".
        low = tag.lower()
        if low.startswith('zh') or 'chinese' in low:
            return Lang.ZH
        return Lang.SV if low.startswith('sv') or 'swedish' in low else Lang.EN
