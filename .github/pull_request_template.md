<!-- One change per PR. CONTRIBUTING.md says where a change may go. Read it before touching dm/, scripts/, docs/, ref/ or AGENTS.md. -->

## What and why

<!-- The symptom or the need, the cause, and the change. Link the issue (Fixes #...). -->

## Checked

<!-- Delete what does not apply. Say what was not checked too. -->
- Tests: <!-- `cd frontend && swift test`, frontend-qt tests if you changed it, `python3 scripts/patches.py check` when `patches/` or a vendored path changed -->
- Visual QA: <!-- `NX_LAUNCHER_CAPTURE_DIR=<dir> swift test` captures the views, for a UI change -->
- Run on a device or Mac: <!-- what was built, played or installed, with title ID and version, chip and OS -->

## Screenshots

<!-- For a UI change: before and after, in the languages it touches. -->

## Scope

- [ ] No vendored file (`dm/`, `scripts/`, `docs/`, `ref/`, `AGENTS.md`) is edited directly: a change there is a patch in `patches/` (`scripts/patches.py export`, and `patches.py check` passes), with its `Upstream-Status`
- [ ] A fix to the engine or a game profile is also (or first) a PR at seedds/nxnative: this PR's patch says `forwarded seedds/nxnative#...`
- [ ] No keys, game files or data extracted from a game in the change or the attachments
