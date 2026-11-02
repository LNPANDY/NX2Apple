# The patch queue

The engine (`dm/`, `scripts/`, `docs/`, `ref/` and upstream's `AGENTS.md`) is not committed in this repository. It is
[seedds/nxnative](https://github.com/seedds/nxnative) at the commit in `../.upstream-ref`, plus the patches in this folder applied in
the order of `series` with `git am -3`. `python3 tools/engine.py sync` builds it into `engine/`, a real git repository that the outer
one ignores: upstream's commit at the pin (one commit deep), then one commit per patch. The same model carries Chromium's changes in
Electron and the upstream source's changes in a Debian package. The proposal and its reasons are
[#123](https://github.com/LNPANDY/NX2Apple/issues/123) and [#214](https://github.com/LNPANDY/NX2Apple/issues/214).

```sh
python3 tools/engine.py sync                 # engine/ = pin + series (a no-op when nothing changed)
python3 tools/engine.py status               # what we carry, and the state of engine/
python3 tools/engine.py export               # commits made in engine/ since the last sync become patches
python3 tools/engine.py check                # the headers are complete, and the series applies cleanly to the pin
python3 tools/engine.py bump --dry --to main # which patches a bump would drop or conflict on
```

`sync` never throws away work in `engine/`: with commits or changes there it stops and names `export` (or `--force`, which keeps
them on a backup branch). A sync that fails (a patch does not apply) puts `engine/` back as it was, so the next sync does not see commits nobody made. Offline, it says so and names the fix (`NX2APPLE_ENGINE_URL` takes a mirror or a local clone). The launchers
run it on the first start of a checkout, CI runs it before every job that reads the engine, and the release app carries the engine tree
instead (below). A PR that adds files under `dm/`, `scripts/`, `docs/` or `ref/` fails the `pr-scope` check.

Every patch is a `git format-patch` file. Its commit message carries a header:

```
Upstream-Status: forwarded seedds/nxnative#475 | pending | fork-only | backport <sha>
Reason: <one line: why the fork carries it>
Issue: LNPANDY/NX2Apple#<n>
```

| Upstream-Status | Meaning |
|---|---|
| `forwarded seedds/nxnative#N` | the same change is a pull request upstream, and the patch goes when it merges |
| `pending` | meant for upstream, no pull request yet |
| `fork-only` | stays here: a fork product choice, or upstream declined it (`fork-only (declined seedds/nxnative#N)`) |
| `backport <sha>` | upstream has it (that commit), and the patch goes on the next bump |

A status may carry a note in brackets. `tools/patches.py status` lists every patch with its status, reason and age, so the
list of what the fork carries and why is one command, and it should keep shrinking.

## Here first, upstream in parallel

A fix to the engine (`dm/`, `scripts/`, `ref/`), to a game profile (`dm/games/<id>/`) or to upstream's docs may land here first, as a
patch in `patches/`. The same change goes to [seedds/nxnative](https://github.com/seedds/nxnative) as a pull request in parallel.
Nobody has to wait for upstream. A patch here is a bridge until upstream has it, and the next bump drops it once the change is in.

The patch starts as `pending` while the upstream pull request is not open. It becomes `forwarded seedds/nxnative#<n>` once it is.
If you cannot open the upstream pull request, a maintainer sends it. A feature upstream declines stays here as
`fork-only (declined seedds/nxnative#N)`, with the reason in `Reason:`.

## Day to day

```sh
python3 tools/engine.py status              # what we carry, and why (tools/patches.py status prints the table alone)
python3 tools/engine.py sync                # make engine/ match the pin and the series
python3 tools/engine.py export              # commits made in engine/ become patches
python3 tools/engine.py check               # headers valid, no patch on the shader chain, the series applies to the pin
python3 tools/engine.py bump --to <sha>     # move the pin (the nightly job does this with main)
python3 tools/engine.py bump --dry --to <sha>   # which patches would conflict, changing nothing
python3 tools/engine.py candidates --to <sha>   # the upstream commits of a pin move that probably matter to the front ends (bump prints it last)
python3 tools/engine.py relink              # the links into seedds/nxnative in the READMEs follow the pin (bump does it)
```

`bump` needs the new upstream commit, which it fetches into `engine/` itself. Scratch worktrees go to `$PATCHES_TMP` (or `--tmp`), else
the system's temporary folder. After a bump (also `--dry`) it prints two tables of the upstream commits between the old and the new pin (`tools/bump_candidates.py`, #464). The first, "Likely matters to the front ends", has the commits that touch the shader chain (consecutive chain moves are one row with the first and the last value), an env row that was removed or rewritten, the NSP script's interface or an error text a failure row matches, the launcher interface, or a binary layout. The second, collapsed, lists the commits whose only match is a file one of our patches changes: `bump` and `sync` already apply the patches and fail on a conflict, so read those only when a patch applied but its behavior might have shifted. It reads the commits' files with `gh api`, so it needs `gh`, and it never fails the bump. It is a list of candidates, not a verdict: whoever reviews the sync pull request reads the first table and fills its `Handled` column. The nightly job puts the first table in the body of the `sync/upstream-<sha>` pull request and the second in a `<details>` block. `dm/fork_patches.txt` is generated by `sync` inside `engine/` (one patch name per line). Do not edit it.

## Carrying a quick fix, and sending it upstream

1. `python3 tools/engine.py sync`, then change the engine in `engine/` and commit there, with a message that says what and why.
   Do not edit `dm/`, `scripts/`, `docs/` or `ref/` at the root of this repository: they do not exist there, and a PR that adds them
   fails `pr-scope`.
2. `python3 tools/engine.py export` writes `patches/NNNN-<subject>.patch` for each commit made since the last sync, adds it to
   `series`, and puts the header template into the message (`Upstream-Status: pending`, `Reason: TODO`, `Issue: TODO`, which
   `--status`, `--reason` and `--issue` set). Fill the three lines in. `export HEAD~2..HEAD` or `export <commit>` names the commits.
   Rename the file if you want a shorter name, because the name is what `fork_patches.txt` and `status` show. The number is a placeholder:
   whoever merges the pull request renumbers the patch to the next free number in `series` on `main` and says so in the PR.
3. `python3 tools/engine.py check` must pass. Commit `patches/` (and nothing from `engine/`) in a pull request here. The next `sync`
   rebuilds `engine/` from the series, and keeps your commits on a backup branch.
4. Send the same change to seedds/nxnative as a pull request from a branch off *their* main (`git -C engine fetch seedds`,
   `git -C engine switch -c fix-x seedds/main`, `git cherry-pick <commit>`), and set the patch to `forwarded seedds/nxnative#<N>`.
5. When upstream merges it, the next bump finds the patch empty and drops it (`landed upstream` in the sync PR). If upstream took it
   in a different form (as `Co-authored-by`, reworked), the patch conflicts instead. Delete it then, and set nothing else.

## Bumping, and what a conflict is

`bump` applies the series onto the new upstream commit with a three-way merge. A patch that comes out empty is dropped and
listed as landed upstream. A patch that conflicts stops the bump: it names the patch, its Reason and its Upstream-Status, and
leaves the conflict in a worktree.

1. In that worktree, resolve the conflict, `git add`, `git am --continue`. If upstream has taken the patch's change in another
   form, `git am --skip` instead.
2. Apply the patches after it: `git am -3 <the remaining patch files>`.
3. `python3 tools/engine.py refresh <worktree> --to <sha>` writes the commits back as the series (patches with no commit are
   deleted) and moves `.upstream-ref`.
4. Run the checks (`check`, `sync`, the tests, the host build), commit, open the pull request.

The nightly workflow does the first step only: it opens a pull request on `sync/upstream` when every patch applies, and an issue
naming the blocking patch when one does not. Whoever owns the patch refreshes it.

## The engine tree and how it is published (#227)

Players get no git: a release carries the engine as a plain tree. `python3 tools/engine.py tree --out DIR [--zip FILE]` writes it from
a synced `engine/` (`dm/`, `scripts/`, `docs/`, `ref/`, `AGENTS.md`, `LICENSE`, the patches applied, `dm/fork_patches.txt`, no history) plus
`.upstream-ref` and `.engine-id`, the tree's identity `<pin>-<first 12 hex of the series digest>` (the series changes without the pin moving, so
the pin alone does not name a tree). The zip is deterministic (sorted, fixed timestamps), so its SHA-256 is reproducible.

`python3 tools/release_manifest.py publish ...` writes `latest.json` (version, pin, `engine_id`, channel, built, the engine and app assets with
SHA-256 and size, sources) and, when a key is set, `latest.json.sig` (a detached Ed25519 signature over its exact bytes, base64). With `--upload` it puts
`NX2Apple-engine.zip`, `latest.json` and `latest.json.sig` on a GitHub release. Without `--upload` it is a dry run.
`build-mac-app.yml` does this for a release candidate tag `vX.Y.Z-rcN` and a release tag `vX.Y.Z` (stable channel, the tree also goes into `Contents/Resources/engine`).
A release tag ships the files of the release candidate on its commit, and `release_manifest.py check-rc` checks they are that build ([RELEASING.md](../RELEASING.md)).
`sync-upstream.yml` does it for the pre-release tag `engine-experimental`.

### Signing is optional for now

The key is the repository secret `ENGINE_SIGNING_KEY` (base64 of the 32 raw private bytes). `python3 tools/release_manifest.py keygen` makes a pair.
Its public half is `frontend/engine-signing.pub`, which the launcher compiles in.
- With the secret set, `publish` signs and verifies the result. A key that does not belong to `frontend/engine-signing.pub` stops the release.
- Without the secret, `publish` writes and uploads `latest.json` without a signature and prints a warning, a workflow annotation in CI. A `latest.json.sig` left on the release by an earlier signed run is removed, because it would not match the new manifest.
- `python3 tools/release_manifest.py verify --manifest latest.json` checks a signature the way the launcher does. A missing `latest.json.sig` passes with a warning while the secret is not set, and fails when the secret is set or `--require-signature` is given.
- Signing becomes mandatory before any download source other than GitHub is added (#268, Cloudflare R2). `publish --source` already refuses to run without a key.

### The experimental channel

The pre-release `engine-experimental` is built and published from `main` only, by the `publish-experimental` job of `sync-upstream.yml`.
The job starts only on the ref `refs/heads/main` and only when the sync job of the nightly run succeeded with a green bump.
It builds the engine of `main` and uploads it when its `engine_id` is not the one already published. A bump reaches the channel once its pull request is merged.
A run on a pull request branch or any other ref never starts the job. The `force_experimental` input of a manual run on `main` uploads again even when the `engine_id` is the same.

Locally: `python3 tools/engine.py sync`, then `tree --out /tmp/t --zip /tmp/e/NX2Apple-engine.zip`, then `publish --engine-zip /tmp/e/NX2Apple-engine.zip
--version 0.0.0 --channel experimental --tag engine-experimental --out /tmp/p --ephemeral-key` runs every step except the upload.

## Patch policy

Upstream's compatibility is the baseline. A patch does not change it silently.

1. **The default is upstream's support matrix:** macOS 26.6 and later, Xcode 27.1, Apple silicon, the iPhones upstream supports. A
   normal build stays inside it.
2. **Going beyond it takes a marked patch,** `Upstream-Status: fork-only (declined seedds/nxnative#N)` or `fork-only`, with the
   reason. Example: BC textures decoded on the CPU for older iPhones (`bc-cpu-decode`, declined in seedds/nxnative#488). Such a
   patch acts only where it is needed (no change on supported hardware), has its own tests, and is ours to maintain: if it
   conflicts on a bump, we refresh it or drop it.
3. **Off limits:** the shader chain (`DMSH_CHAIN`, `dm/gfx/nvn/dmsh_chain.h`, the chain tools `dm/gfx/tools/dmsh_*`, `Program.cs`,
   `ios_metal.py`, `dmsh_chain.lock`, the translator `dmsh_xlate_bin`, with the exact list in the engine's AGENTS.md, which
   `tools/engine.py` reads from there), upstream's tool pins, and lowering a minimum version. Shader caches and game profiles depend on them, and diverging there
   makes our builds incompatible with upstream's caches and bug reports. `tools/engine.py check` and `export` reject a patch that touches
   these paths.
4. **Bug reports go where they belong.** Every build records the patches it carries: `DMForkPatches` in the app's `Info.plist` and
   the first line of the log (`fork patches: a, b, c`, `Documents/log.txt` on iOS, the Mac app's log). The issue forms ask for that
   line, so a report from a configuration upstream does not support comes to NX2Apple, not to seedds. The list is every patch in the
   series, whatever its status, because any of them makes the build differ from upstream's.

## What is not a patch

`.github/`, `frontend/`, `frontend-qt/`, `tools/`, the README, CONTRIBUTING.md, AGENTS.md, CLAUDE.md and everything else in the repository
belong to the fork and are edited directly. The engine is only what `sync` builds into `engine/`.

## Generated files inside the engine

`docs/agents/game-patches.md` and `docs/agents/symptoms.md` are written by upstream's own tools (`dm/tools/docs_patches.py`,
`dm/tools/docs_symptoms.py`) from the tree, and upstream's `test_docs.py` requires them to equal that output. With the series in,
the tree differs from upstream's (a profile key, a patched host table), so upstream's copy would fail the test, and a patch that
carried the file would conflict on every bump. `sync` therefore runs both tools on the patched tree and commits the result in
`engine/`, and a patch that touches either file is rejected by `check` (`export` leaves them out). Nothing to do by hand: `sync` writes
them. The badge data of the README is `.github/badges/*.json` in this repository (it was a patch of `fork-docs` before step 2 of #214).
The games gallery of `GAMES.md` is written by `engine/dm/tools/docs_gallery.py`, with links to nxnative at the pinned commit.
