<!-- One change per PR. CONTRIBUTING.md says where a change may go. The engine (`dm/`, `scripts/`, `docs/`, `ref/`) is not in this repository: it is seedds/nxnative plus `patches/`. -->

## Fix or feature

<!-- Tick one. A fix merges once CI is green, a feature after 48 hours. Maintainers label it `bug` or `enhancement`. -->
- [ ] Fix
- [ ] Feature

## What and why

<!-- The symptom or the need, the cause, and the change. Link the issue (Fixes #...). -->

## Checked

<!-- Delete what does not apply. Say what was not checked too. -->
- Tests: <!-- `cd frontend && swift test`, frontend-qt tests if you changed it, `python3 tools/engine.py check` when `patches/` changed -->
- Visual QA: <!-- `NX_LAUNCHER_CAPTURE_DIR=<dir> swift test` captures the views, for a UI change -->
- Run on a device or Mac: <!-- what was built, played or installed, with title ID and version, chip and OS -->

## Screenshots

<!-- A change to anything visible in the launcher (`frontend/` or `frontend-qt/`) needs before and after images of every view it changes, in the languages it touches. Attach them here (`gh pr edit --attach <file>` uploads an image). Captures from `NX_LAUNCHER_CAPTURE_DIR` are fine (`NX_CAPTURE_LANG=de` picks the language). A PR without them is not reviewed. -->

<!-- With no visible change, write: None, no visible change. -->

## Scope

- [ ] No engine file (`dm/`, `scripts/`, `docs/`, `ref/`) is added to the repository: a change there is a patch in `patches/` (a commit in `engine/`, then `tools/engine.py export`, and `tools/engine.py check` passes), with its `Upstream-Status`
- [ ] A fix to the engine or a game profile is also (or first) a PR at seedds/nxnative: this PR's patch says `forwarded seedds/nxnative#...`
- [ ] A change to a launcher view has before and after screenshots above
- [ ] No keys, game files or data extracted from a game in the change or the attachments
