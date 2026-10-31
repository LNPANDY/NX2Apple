# Releasing NX2Apple

A release starts as a release candidate. Players get the exact files of the candidate that was tested: the same app and the same engine.

## Release candidates

### Cutting a candidate

1. The version bump goes to `main` first: `static let appVersion` in `frontend/Sources/NSPortBuilder/ContentView.swift`, and the changelog.
2. Tag a commit on `main` as `vX.Y.Z-rcN`, with N from 1: `git tag v0.7.6-rc1 <commit> && git push origin v0.7.6-rc1`.

`build-mac-app.yml` checks that the tag without `-rcN` is `appVersion`. The app inside says `0.7.6`, not `0.7.6-rc1`. The final release ships this bundle, and the app's own update installs only a bundle whose version is the release's.

### What CI publishes

The tag gets a GitHub pre-release titled "NX2Apple 0.7.6 release candidate 1". It is never "latest", and the app's update reads only the latest release, so no player is offered it. It carries:

- `NX2Apple-macOS-arm64.zip` and the same app under its older names (`nxnative-`, `NS-Port-Builder-macOS-arm64.zip`)
- `NX2Apple-engine.zip`, the engine tree that is also inside the app (`Contents/Resources/engine`)
- `latest.json` and `latest.json.sig`, the signed manifest of the stable channel for version 0.7.6. Its version, pin and `engine_id` are the ones the final `latest.json` of 0.7.6 has. Only its download URL differs.

The release notes name the engine build: version, pin, `engine_id`, and the SHA-256 of the engine zip and of the app zip.

The candidate never touches the pre-release `engine-experimental`, which serves `main`.

A candidate is built once. A second run of the same tag fails once the app is uploaded, because a rebuild would not be the same bytes. A broken build or a fix is the next candidate, `rc2`.

### Testing a candidate

The test runs against the engine the release will serve, not against whatever an engine channel serves that day.

- In a checkout, `tools/try-pr v0.7.6-rc1` downloads the app, checks its SHA-256 and its bundled `engine_id` against the candidate's `latest.json`, and prints the `engine_id`. It opens the app with launch arguments that make it build with its bundled engine: the stable channel, that `engine_id`, and no automatic engine or app update. The arguments last for that run.
- By hand: download `NX2Apple-macOS-arm64.zip` from the pre-release and unzip it. `NX2Apple.app/Contents/Resources/engine/.engine-id` is the `engine_id` of the notes. Then run `open -n NX2Apple.app --args -engineChannel stable -engineID <engine_id> -autoUpdateRepo '<false/>' -autoUpdateApp '<false/>'`.
- Settings shows the engine's version and the first 8 characters of its `engine_id`. The diagnostics report shows `Engine: stable 0.7.6 (<engine_id>)`. Both must match the notes.
- Without the arguments the app follows the channel and engine saved in its settings. The experimental channel serves the engine of `main`.
- Test the whole app on a Mac, and build and install games for iPhone or iPad with it.

The test app has the bundle id of an installed NX2Apple (`org.nxnative.NSPortBuilder`). It shares its settings and `~/Library/Application Support` (`NS Port Builder`, `NX2Apple` with the engine store, `nxnative`). A setting changed in the test app stays changed. The test app saves its engine choice. An installed release app goes back to its own engine at its next start. If it followed the experimental channel, pick that again in Settings.

If something is broken, a fix or a revert goes to `main`, and the next candidate is tagged on the new commit.

## The final release

When a candidate passes, the final tag `vX.Y.Z` goes on the same commit: `git tag v0.7.6 <commit of v0.7.6-rc2>`.

The build of the final tag looks for the newest `v0.7.6-rcN` on its commit. It downloads that candidate's files and checks the signature of its `latest.json`. It then checks that the manifest names exactly those zips, and that the engine zip this commit builds holds the same files as the candidate's (the zip is reproducible, so normally it is the same bytes). The release then gets the candidate's app zips and engine zip unchanged, with a `latest.json` of its own (same `engine_id`, its own download URL). Any difference stops the release before anything is uploaded.

A final tag on a commit without a candidate fails. In an emergency, a manual run on the tag publishes it anyway: `gh workflow run build-mac-app.yml --ref v0.7.6 -f release_without_rc=true`. Nobody tested that build as a whole, and the release notes say so.

## Who tags

- Release candidates: LNPANDY or v0lumehi.
- Final releases: LNPANDY. If LNPANDY cannot be reached for 48 hours, v0lumehi tags the final from the tested candidate and leaves a note in the release notes or in an issue.
- A final tag always points at the commit of a tested candidate.

### The tag ruleset

Two tag rulesets in Settings → Rules → Rulesets:

- Target `v*`, rules "Restrict updates" and "Restrict deletions", bypass for the repository admin. A tested tag never moves.
- Target `v*`, excluding `v*-rc*`, rule "Restrict creations", bypass for the repository admin and the write role.

In a repository owned by a personal account, bypass goes by role, not by person. LNPANDY is the admin, v0lumehi has the write role. The second ruleset does not block v0lumehi, so the 48-hour fallback works. It stops workflows and apps from making a final tag. Who tags a final release is the agreement above.
