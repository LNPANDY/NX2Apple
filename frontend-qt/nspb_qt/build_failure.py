"""The NSP script's early stops, turned into hints (the SwiftUI app's BuildFailure.swift).

The script prints a `[RED]` line and exits 1 for each stop (a BuildError), and the window used to show the
last line of the log. The classifier reads the whole log tail: for a damaged NSP the last line is only
"nx_extract exit code 3" and the message is above it. No Qt in here, so the tests run anywhere.

TABLE is the same table as BuildFailure.swift's (a test compares the two). frontend/Tests/Fixtures/
build_failures.json holds the script's real message for every row, and a test checks that each fragment is
still in the vendored script, so a sync that rewords a message fails there.
"""
from __future__ import annotations

import re
from dataclasses import dataclass

ROSETTA = 'rosetta'
TRANSLATOR = 'translator'
IOS_SDK = 'iosSDK'
CLT_SELECTED = 'cltSelected'
OTHER_METAL = 'otherMetal'
SHADER_REGRESSION = 'shaderRegression'
DAMAGED_NSP = 'damagedNSP'
A32_PROGRAM = 'a32Program'
KEYS = 'keys'
SEVERAL_GAMES = 'severalGames'
NO_TITLE_ID = 'noTitleID'
DISK_FULL = 'diskFull'
UNKNOWN = 'unknown'

# (id, kind, regular expression searched in the log)
TABLE: list[tuple[str, str, str]] = [
    ('rosetta.intel', ROSETTA, r'is an Intel one running under Rosetta'),
    ('translator.run', TRANSLATOR, r'the shader translator does not run'),
    ('translator.start', TRANSLATOR, r'the shader translator does not start'),
    ('ios.sdk', IOS_SDK, r'the iOS SDK is not installed'),
    ('clt.selected', CLT_SELECTED, r'the selected developer folder is the Command Line Tools'),
    ('metal.other', OTHER_METAL, r'Metal compiler is not the one the shaders were tested with'),
    ('shaders.regression', SHADER_REGRESSION, r'a change to the translation chain broke them'),
    ('nsp.damaged', DAMAGED_NSP, r"files fail the NCA's hash check"),
    ('arm32.program', A32_PROGRAM, r'is a 32-bit ARM program'),
    ('keys.missing', KEYS, r'(?m)^\[RED\] no such file: '),
    ('games.several', SEVERAL_GAMES, r'more than one game in the folder, keep one game per folder'),
    ('games.noTitleID', NO_TITLE_ID, r'no NSP with a readable title ID in '),
    ('disk.low', DISK_FULL, r'less than [0-9]+ GB free on the volume of '),
    ('disk.full', DISK_FULL, r'No space left on device'),
]

# The script's override for a stop, offered as "Build anyway". The others cannot be built around.
OVERRIDE_FLAGS = {
    OTHER_METAL: '--allow-other-metal',
    SHADER_REGRESSION: '--allow-shader-regressions',
    DAMAGED_NSP: '--allow-damaged',
}

KINDS = [ROSETTA, TRANSLATOR, IOS_SDK, CLT_SELECTED, OTHER_METAL, SHADER_REGRESSION, DAMAGED_NSP, A32_PROGRAM,
         KEYS, SEVERAL_GAMES, NO_TITLE_ID, DISK_FULL]
# The Swift app has four more rows that no log line sets (a drive that is gone, a signing team, a device transfer):
# they belong to the Mac launcher's install on a device and to /Volumes, which this front end does not have.

_A32_NAME = re.compile(r'^(?:\[RED\] )?(.+?) \([0-9A-Fa-f]{16}\) is a 32-bit ARM program', re.M)


@dataclass(frozen=True)
class Failure:
    kind: str
    game: str | None = None   # a32Program: the game, when the message names it
    detail: str | None = None   # diskFull: the GB the script says it needs. noTitleID: the folder it names

    @property
    def what_key(self) -> str:
        return f'fail.{self.kind}.what'

    @property
    def next_key(self) -> str:
        return f'fail.{self.kind}.next'

    @property
    def flag(self) -> str | None:
        return OVERRIDE_FLAGS.get(self.kind)


def _detail(kind: str, log: str) -> str | None:
    if kind == DISK_FULL:   # "less than 40 GB free on the volume of /Volumes/X/..."
        m = re.search(r'less than ([0-9]+) GB free', log)
        return m.group(1) if m else None
    if kind == NO_TITLE_ID:   # "no NSP with a readable title ID in /path"
        m = re.search(r'(?m)no NSP with a readable title ID in (.+)$', log)
        return m.group(1).strip() if m else None
    return None


def classify(log: str, keys_readable: bool | None = None) -> Failure:
    """UNKNOWN when no row matches: the caller then keeps showing the last line of the log.

    keys_readable: what the window knows of the keys file (False = gone or unreadable). The script's own line for a missing
    file is a row of the table, and nx_extract says nothing of its own about a file it cannot read."""
    for _id, kind, pattern in TABLE:
        if re.search(pattern, log):
            m = _A32_NAME.search(log) if kind == A32_PROGRAM else None
            name = m.group(1).strip() if m else None
            return Failure(kind, None if name in (None, '', '?') else name, _detail(kind, log))
    if keys_readable is False:
        return Failure(KEYS)
    return Failure(UNKNOWN)


def arguments(args: list[str], flag: str | None) -> list[str]:
    """The build arguments with the one-off override added: exactly one `--allow-*`, or none."""
    rest = [a for a in args if not a.startswith('--allow-')]
    return rest + [flag] if flag and flag.startswith('--allow-') else rest


class OverrideState:
    """"Build anyway": nothing is armed until the confirmation, and the arm serves one build only."""

    def __init__(self) -> None:
        self.confirming: Failure | None = None
        self._armed: str | None = None

    def request(self, failure: Failure | None) -> bool:
        """Ask for confirmation (the window shows the dialog). False for a stop that has no override."""
        if failure is None or failure.flag is None:
            return False
        self.confirming = failure
        return True

    def cancel(self) -> None:
        self.confirming = None

    def confirm(self) -> bool:
        if self.confirming is None:
            return False
        self._armed = self.confirming.flag
        self.confirming = None
        return True

    def take(self) -> str | None:
        """The flag the next build runs with, once."""
        flag, self._armed = self._armed, None
        return flag
