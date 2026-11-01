# Releasing NX2Apple

A release starts as a release candidate. Players get the exact files of the candidate that was tested: the same app and the same engine.

## Release candidates

### Cutting a candidate

1. Before `-rc1`, bump the engine pin, so the candidate carries the current engine. The nightly sync job opens the pull request `sync/upstream-<sha>` when seedds/nxnative has news. If it has not, `python3 tools/engine.py bump --dry --to main` shows which patches would conflict, and `python3 tools/engine.py bump --to <sha>` moves the pin. Merge that pull request before the version bump.
2. The version bump goes to `main` next: `static let appVersion` in `frontend/Sources/NSPortBuilder/ContentView.swift`, and the changelog.
3. Tag a commit on `main` as `vX.Y.Z-rcN`, with N from 1: `git tag v0.7.6-rc1 <commit> && git push origin v0.7.6-rc1`.

`build-mac-app.yml` checks that the tag without `-rcN` is `appVersion`. The app inside says `0.7.6`, not `0.7.6-rc1`. The final release ships this bundle, and the app's own update installs only a bundle whose version is the release's.

### What CI publishes

The tag gets a GitHub pre-release titled "NX2Apple 0.7.6 release candidate 1". It is never "latest", and the app's update reads only the latest release, so no player is offered it. It carries:

- `NX2Apple-macOS-arm64.zip` and the same app under its older names (`nxnative-`, `NS-Port-Builder-macOS-arm64.zip`)
- `NX2Apple-engine.zip`, the engine tree that is also inside the app (`Contents/Resources/engine`)
- `latest.json` and `latest.json.sig`, the signed manifest of the stable channel for version 0.7.6. Its version, pin and `engine_id` are the ones the final `latest.json` of 0.7.6 has. Only its download URL differs.

The release notes name the engine build: version, pin, `engine_id`, and the SHA-256 of the engine zip and of the app zip.

The candidate never touches the pre-release `engine-experimental`, which serves `main`.

A candidate is built once. A second run of the same tag fails once the app is uploaded, because a rebuild would not be the same bytes. A broken build or a fix is the next candidate, `rc2`.

The pin stays between candidates. The final release ships the engine of its candidate, and its build stops when the engine zip differs. Bump the pin for `rc2` or later only for an engine fix that the release needs, and test that candidate as a whole again. A patch added to `patches/` also changes the `engine_id`, so a candidate with a new patch is tested as a whole too. Any other bump goes to `main` after the final tag, before the first candidate of the next version.

### Testing a candidate

The candidate's signed `latest.json` names the `engine_id` the release carries. The whole-app test checks that the app's first start, with its online engine check, lands on exactly that engine tree. The engine that `engine-experimental` serves that day does not count.

- In a checkout, `tools/try-pr v0.7.6-rc1` downloads the app, checks its SHA-256 and its bundled `engine_id` against the candidate's `latest.json`, and prints the `engine_id`. It opens the app with launch arguments that make it build with its bundled engine: the stable channel, that `engine_id`, and no automatic engine or app update. The arguments last for that run. To try a change that is not pushed yet, `tools/try-local` builds the app from the checkout the same way, without CI. It is never a release: no `latest.json`, no engine signature.
- By hand: download `NX2Apple-macOS-arm64.zip` from the pre-release and unzip it. `NX2Apple.app/Contents/Resources/engine/.engine-id` is the `engine_id` of the notes. Then run `open -n NX2Apple.app --args -engineChannel stable -engineID <engine_id> -autoUpdateRepo '<false/>' -autoUpdateApp '<false/>'`.
- After the first start, with the Mac online, check the engine the app uses. It must be the `engine_id` of the candidate's `latest.json` and of its notes. Any other `engine_id` makes the test void.
  - Settings, Build tools, row "Build engine": `0.7.6 · upstream <8 characters>`. The 8 characters are the start of the pin only, so they cannot tell two engines of one pin apart.
  - Settings, Build tools, row "Diagnostics", button "Copy diagnostics": the copied report has the line `- Engine: stable 0.7.6 (<engine_id>)` with the full `engine_id`.
- The launch arguments keep the launch check online, and it installs nothing. On a Mac whose settings are on the stable channel, opening the app without arguments runs the normal first start. It must land on the same `engine_id`.
- Without the arguments the app follows the channel and engine saved in its settings. The experimental channel serves the engine of `main`.
- Test the whole app on a Mac, and build and install games for iPhone or iPad with it.

The test app has the bundle id of an installed NX2Apple (`org.nxnative.NSPortBuilder`). It shares its settings and `~/Library/Application Support` (`NS Port Builder`, `NX2Apple` with the engine store, `nxnative`). A setting changed in the test app stays changed. The test app saves its engine choice. An installed release app goes back to its own engine at its next start. If it followed the experimental channel, pick that again in Settings.

If something is broken, a fix or a revert goes to `main`, and the next candidate is tagged on the new commit.

## The final release

When a candidate passes, the final tag `vX.Y.Z` goes on the same commit: `git tag v0.7.6 <commit of v0.7.6-rc2>`.

The build of the final tag looks for the newest `v0.7.6-rcN` on its commit. It downloads that candidate's files and checks the signature of its `latest.json`. It then checks that the manifest names exactly those zips, and that the engine zip this commit builds holds the same files as the candidate's (the zip is reproducible, so normally it is the same bytes). The release then gets the candidate's app zips and engine zip unchanged, with a `latest.json` of its own (same `engine_id`, its own download URL). Any difference stops the release before anything is uploaded.

A final tag on a commit without a candidate fails. In an emergency, a manual run on the tag publishes it anyway: `gh workflow run build-mac-app.yml --ref v0.7.6 -f release_without_rc=true`. Nobody tested that build as a whole, and the release notes say so.

## Release notes

CI writes a short body: the version and the tested candidate. The readable notes are written by a person or an agent from [.github/release_notes_template.md](.github/release_notes_template.md).

The notes of a final release are a file in the repository, `release-notes/vX.Y.Z.md`, in the form of the template (the English part, then the Chinese part, no generated block). Merge it in a normal pull request before the final tag is pushed. When the final tag is built, CI creates the release with that file, a `---` line and GitHub's generated notes appended (`python3 tools/release_notes.py build`, the previous tag is the newest final tag before this one). `python3 tools/release_notes.py check release-notes/vX.Y.Z.md` runs the rules below and also runs in the pull request CI. Without the file CI writes the short body (the version and the tested candidate) and appends the generated notes. If the tool fails, the release gets the short body and CI prints a warning: a notes problem never stops a release. CI creates the release only when it does not exist, so notes edited by hand are never overwritten, and `gh release edit <tag> --notes-file <file>` stays the way to fix them later.

The notes can also be written by the Copilot CLI: for a final tag the workflow [release-notes.yml](.github/workflows/release-notes.yml) gathers the changelog row and the merged pull requests, lets the model write the text from them only, and runs `check` on it. A text that passes is used when there is no reviewed `release-notes/vX.Y.Z.md` (that file always wins) and sets the release title from its first line. Without the secret `COPILOT_TOKEN`, with a failed model job or a failed check the release gets the short body and a warning. To try it on an existing release, run the workflow by hand with `publish` false and read the job summary. Setup, the model variable `RELEASE_NOTES_MODEL` and the prompt: [.github/release-notes/README.md](.github/release-notes/README.md).

- English first, Chinese second, under `## English` and `## 中文`, with the same content in both. Each part has one bullet per change, grouped in bold: a notice, Highlights, New, Fixed, Known issues, Requires.
- No emojis, no pictograms and no symbols in the text. No semicolons (also not the full-width one) and no em-dashes. Plain English and plain Chinese.
- People are written as `@login`, the owner as `@LNPANDY`.
- Every claim comes from the changelog row, the merged pull requests or the issues. Nothing is invented.
- Write the notes before the final tag is pushed or right after it. Put them in a file and publish with `gh release edit <tag> --notes-file <file>`. Never paste them from a chat, that brings emojis along.
- After the two parts, append the generated notes: `gh api repos/LNPANDY/NX2Apple/releases/generate-notes -f tag_name=<tag> -f previous_tag_name=<previous final tag> --jq .body`, written into the notes file before `gh release edit`. They are English only and not edited by hand. They list the merged pull requests with their authors and name first-time contributors, so they replace a hand-written Credits section. [.github/release.yml](.github/release.yml) sets their categories. Keep the generated block unedited and last: its `@login` mentions and the Full Changelog link (the compare view, so the commit history since the last release) are what list the contributors and the history. Titles of pull requests show up as written, so write them without em-dashes.

## Who tags

- Release candidates: LNPANDY or v0lumehi.
- Final releases: LNPANDY. If LNPANDY cannot be reached for 48 hours, v0lumehi tags the final from the tested candidate and leaves a note in the release notes or in an issue.
- A final tag always points at the commit of a tested candidate.

### The tag ruleset

Two tag rulesets in Settings → Rules → Rulesets:

- Target `v*`, rules "Restrict updates" and "Restrict deletions", bypass for the repository admin. A tested tag never moves.
- Target `v*`, excluding `v*-rc*`, rule "Restrict creations", bypass for the repository admin and the write role.

In a repository owned by a personal account, bypass goes by role, not by person. LNPANDY is the admin, v0lumehi has the write role. The second ruleset does not block v0lumehi, so the 48-hour fallback works. It stops workflows and apps from making a final tag. Who tags a final release is the agreement above.
