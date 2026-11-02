# tools/verify

Every feature has its expectations written down, and a check for each one, so a change that breaks a feature shows before a release candidate is tagged. A maintainer runs it on a Mac before `vX.Y.Z-rcN`. An agent can run it too.

```bash
python3 tools/verify list                      # every expectation: holds, gap or manual, and what checks it
python3 tools/verify auto                      # all test suites, then a report per expectation (about 5 minutes)
python3 tools/verify --target installed        # this Mac and its installed NX2Apple (seconds)
python3 tools/verify local --candidate DIR     # also the candidate that `tools/try-pr vX.Y.Z-rcN --dir DIR` downloaded
python3 tools/verify manual                    # asks the manual expectations, y, n or s
python3 tools/verify all                       # the three above, for a release candidate
python3 tools/verify auto --only cloud-saves   # one feature, only its tests
```

Each run prints one line per expectation and writes a Markdown report to `tools/verify/out/` (git-ignored) with the versions (checkout, app version, pin, engine_id, macOS, Xcode, the installed launcher's engine), the result of each expectation and the suite logs. The exit status is 1 when a check fails. Python 3.9+ and the standard library only.

## Expectations

One file per feature in [expectations/](expectations/). One line per expectation, with an ID that starts with the file's name and one plain sentence: Given / when / then, or something that is always true.

```markdown
- cloud-saves-04: Given the env.txt of #490 (DM_SAVE_SYNC set to a folder), when a game starts, then the launcher leaves the file byte for byte as it was.
- cloud-saves-02: The Mac launcher shows the cloud saves folder of a game and when it last synced. (gap: #499)
- cloud-saves-09: Given the same folder on both, a save made on the iPhone reaches the Mac. (manual)
```

A check binds to an ID with one comment line above it:

```swift
// expects: cloud-saves-04
func testAnExplicitSyncFolderFromAnOlderVersionIsLeftAsItIs() throws {
```

```python
# expects: engine-04
def test_a_changed_series_or_pin_makes_it_stale_and_sync_rebuilds(self):
```

Checks live in the suites that already exist: `frontend/Tests`, `frontend-ios/Tests`, `frontend-qt/tests`, `tools/tests`. A check of the real Mac is a `step_...` function in [verify.py](verify.py) with the same comment.

Each expectation is in one of three states:

- **holds**: a check passes today.
- **gap: #issue**: it is not true today. It may have no check yet. If it has one, the check expects its failure (`XCTExpectFailure` in Swift, `@unittest.expectedFailure` in Python), so the suite stays green while the gap is open and turns red the day the behavior changes.
- **manual**: only a person can check it (a real game, a real controller, a look at the screen). `verify manual` asks for it.

## The rule

`tools/tests/test_verify.py` (`ExpectationsMap.test_every_expectation_is_checked_or_marked`) runs with the tool tests in CI and in the pre-push hook. It fails when

1. an expectation has no check and is not marked `(gap: #issue)` or `(manual)`,
2. a marker names an ID that is not in `expectations/`,
3. a gap's check does not expect its failure, or a holding expectation's check does. When a gap is fixed, its expected failure stops happening and the suite turns red. The fix then drops the `(gap: ...)` mark and the `XCTExpectFailure`.

**Every fix adds or changes an expectation, and its check was red before the fix.** A fix PR either turns a `gap` into `holds` (rule 3 forces it) or adds a new expectation whose test fails without the fix.

## Adding an expectation (two minutes)

1. Add one line to the feature's file in `expectations/` (or a new `<feature>.md`). Take the next free number.
2. Put `// expects: <id>` (or `# expects: <id>`) above the test that checks it. A test can carry several IDs, comma-separated, and an ID can have several tests.
3. `python3 tools/verify lint` says whether the map is whole. No check yet? Write `(gap: #issue)` or `(manual)` at the end of the line.

## Targets

- **The checkout** (`auto`): the four suites (`swift test` in `frontend/` and `frontend-ios/`, the Qt and tool tests) and `tools/engine.py check`. `frontend-ios` needs macOS 26. CI runs it only when `frontend-ios/`, `tools/` or the engine change, so `auto` runs it on every candidate. Without `swift` (Windows, Linux) the Swift suites are skipped.
- **Files an older version left** (`auto`, in the suites): fixtures under `frontend/Tests/Fixtures/upgrade/` (an old env.txt, the keyword env.txt) run through today's code in `UpgradeFixturesTests`. More belong here: old `UserDefaults`, an old `library.json`.
- **The installed system** (`local`, `--target installed`): the real `~/Library/Application Support/nxnative/<title ID>/env.txt` files, the launcher's preferences (`defaults export org.nxnative.NSPortBuilder`) and each game's (`org.nxnative.<title ID>`), the engine store, iCloud Drive, Xcode, the iOS SDK, `devicectl list devices` (read-only, nothing is installed or copied). `--home DIR` reads another home folder, `--fixture NAME` unpacks `fixtures/NAME.json` into one. The checks of the machine itself are skipped then.

## The worked example: #490

A player upgraded to 1.0.0. The Mac game's `env.txt` still had `DM_SAVE_SYNC` and `DM_SAVE` on an old iCloud Drive folder, the iPhone synced through another one, and the Saves sheet copied into a third. Nothing said so. As expectations:

| ID | State | Checked by |
|---|---|---|
| cloud-saves-01 | holds | `step_cloud_sync_folders`: every sync folder exists and holds `<title ID>/save.dmsync` |
| cloud-saves-02 | gap: #499 | none yet: the Mac launcher does not show the folder |
| cloud-saves-03 | holds | `step_one_sync_folder_per_game`: no other iCloud Drive folder holds a newer save of the game. This is the one that names the #490 setup |
| cloud-saves-04 | holds | `UpgradeFixturesTests`: the 1.0.0 env.txt of #490 is left byte for byte |
| cloud-saves-05 | holds | `UpgradeFixturesTests`: the old `icloud` keyword keeps the folder the iPhone uses |
| saves-05 | gap: #490 | `UpgradeFixturesTests.testTheSavesSheetUsesTheDMSaveFolderOfEnvTxt`, expected to fail: the Saves sheet ignores `DM_SAVE` |
| saves-06 | holds | `step_env_dm_save`: no env.txt on this Mac sets `DM_SAVE` |
| settings-06 | holds | `step_env_hides_saved_choice`: no env.txt line hides a saved choice (the "saved choice ... not used" lines of the log) |

`python3 tools/verify local --fixture home-490` runs the Mac checks on that player's home folder, rebuilt from the issue: cloud-saves-03, saves-06 and settings-06 fail with the folders and variables named.

## What is checked how

75 expectations in 12 features. (a) a logic test with fakes, (b) an upgrade test with data from an older version, (c) a check of the real Mac, (d) a person.

| Feature | (a) | (b) | (c) | (d) | Gap |
|---|---|---|---|---|---|
| build | 8 | | | 1 | |
| install | 4 | | 1 | 1 | |
| saves | 4 | | 1 | 1 | 1 (#490) |
| cloud-saves | 2 | 2 | 3 | 1 | 1 (#499) |
| library | 5 | | | 1 | |
| controllers | 2 | 1 | | 1 | |
| settings | 2 | 3 | 2 | | |
| localization | 5 | | | 1 | |
| engine | 5 | | 2 | | |
| app-update | 4 | | | | |
| setup | 2 | 1 | 2 | | |
| release | 3 | | | 2 | |
| **All** | **46** | **7** | **11** | **9** | **2** |

engine-01 (`tools/engine.py check`) is counted under (a): it checks the checkout, not the Mac.

What cannot be automated here, and stays manual or out of reach:

- A real game: building it, playing it, its frame rate and its graphics. Game files cannot be in the repository or in CI.
- A real iPhone: installing, signing with a real team, the 7-day signature running out, the save copy over devicectl. `local` only lists the devices.
- iCloud itself: whether a file reaches the other device, and when. `local` reads what is on this Mac's iCloud Drive, not the iPhone's choice of folder (that sits in the shell's bookmark on the device).
- A real controller and the look of the views. The view captures (`NX_LAUNCHER_CAPTURE_DIR`) help a person, they do not judge.
- Windows: the Qt tests run anywhere, a build on Windows needs a Windows machine.

## Cost

`auto` is the four suites and the engine check, about 5 minutes on an M3 Max (4 min 50 s with a warm build cache), most of it `swift test` of `frontend/` (704 XCTest cases, about 3 minutes). A cold `swift build` adds a few minutes. `--only <prefix>` runs only the tests of those expectations. `local` takes seconds (devicectl can take up to a minute when a device is slow to answer). `manual` takes as long as the person needs: a release candidate has 9 manual expectations.
