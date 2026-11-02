"""NS Port Builder — Qt front end (Windows and macOS from one code base).

The SwiftUI app in ../frontend/ is the macOS-native one. This is the cross-platform
counterpart: same job (drive scripts/build_ipa_from_nsp.py and pack the RomFS archive),
same localisation strings, built with PySide6 so Windows users get a native window too.

Layout mirrors the SwiftUI app so the two stay recognisable:
    model.py        state, dependency detection, build runner (Qt signals, no UI)
    ui.py           the window
    l10n.py         the texts, read from ../frontend/l10n (the SwiftUI app reads the same files)
    platform_*.py   per-OS paths and tool discovery
"""
