# Contributing

Issues and pull requests are welcome. NX2Apple is the launcher (`frontend/`, `frontend-qt/`) and the glue around the [nxnative](https://github.com/seedds/nxnative) engine, which is vendored here as upstream plus a queue of patches, and bumped to upstream's latest every day. [AGENTS.md](AGENTS.md) describes the engine. Building by hand from a terminal (tools, `prod.keys`, the IPA) is on its own page: [BUILDING.md](BUILDING.md).

## Reporting a problem

Game problems, build problems and launcher problems each have an issue form (`.github/ISSUE_TEMPLATE/`). The form asks for what a report needs — versions, device, Copy diagnostics, the build log's game profile lines, the game's log and the crash report. Use it from the Issues page. A report without those is usually unactionable.

## Where an issue goes

- **Here:** the app, a build or install that fails, and a game that does not run well on your Mac or iPhone or iPad.
- **[Discussions](https://github.com/LNPANDY/NX2Apple/discussions):** questions (Q&A) and ideas (Ideas). Bugs stay issues.
- **[seedds/nxnative](https://github.com/seedds/nxnative/issues):** how the engine works, porting a new game, a rendering fault you have traced into the engine itself.

## What a report needs

Pick a form: **Game problem**, **Build problem** or **Launcher problem or idea**. Each asks for what the problem is traced with: the game, its title ID and versions, the target, the device and OS, the NX2Apple version, **Settings > Copy diagnostics**, and the log (a game's log, or the Build log on the Builds page). A report without them gets a request for them first. Where a game's log is: a Mac game in a library folder writes `log/<title ID>.log` beside its app, otherwise `~/Library/Logs/nxnative/<title ID>.log`. On an iPhone or iPad it is `log.txt` in the Files app.

**Never attach keys, game files or anything extracted from a game.** Logs, screenshots, title IDs and build IDs are fine.

## Helping with games

Each new game needs its own bring-up: a profile (build IDs, memory layout, texture slots), a shader
reader if it packs them in a form we do not read, and patch points. **Two ways to help, both
useful:**

- **Report a game that works** — if you got a title outside the verified list running, open an issue
  with the title ID, the update version, and what you did. It becomes a profile others can use.
- **Send the shaders that are missing** — if a game runs but stutters on first use of an effect, its
  shader variants are missing from the map. The host can dump what it cannot find
  (`DM_NVN_SHDUMP=<dir>`). Attach those and we add them to `shader_map.tsv` for everyone.

Issues with a full `Documents/log.txt` get looked at first — that log usually names the exact
missing piece.

## A pull request

- One change per PR, off `main`. Commit messages say what changed and why, in plain English, as `git log` does.
- Fill in the PR template: what and why, what was checked, screenshots for UI changes.
- A PR that changes anything visible in the launcher attaches before and after screenshots to the PR, under Screenshots. Show every view the PR changes, in each language it touches. A PR without them is not reviewed. A PR with no visible change writes "None, no visible change".
- **`frontend/` and `frontend-qt/` are the fork's own:** change them freely. Run `cd frontend && swift test`. For a UI change also capture the views for visual QA (`NX_LAUNCHER_CAPTURE_DIR`, see [frontend/README.md](frontend/README.md#verification)).
- **The engine is upstream plus the patch queue, built into `engine/`** (#214): `python3 tools/engine.py sync` makes it, engine work is a commit in `engine/`, and `python3 tools/engine.py export` turns it into a patch with its header. Until step 2 of #214 the repository still commits the same tree:
- **`dm/`, `scripts/`, `docs/`, `ref/` and `AGENTS.md` are upstream plus the patch queue.** They are generated: seedds/nxnative at the commit in `.upstream-ref` with the patches in `patches/` applied, so a direct edit fails `tools/patches.py check` (the `pr-scope` and `patch-queue` jobs) and would be lost on the next bump. The failure names the command: `python3 tools/patches.py absorb <files>` folds a direct edit into the patch that already touches the file (a new file may need `--into <patch>`). Commit `patches/` with it. For a change that needs a patch of its own, commit the change, turn it into a patch with `tools/patches.py export <commit>`, fill in its header (`Upstream-Status`, `Reason`, `Issue`), and send the same change to seedds/nxnative so the patch can go. Fixes to the engine and to game profiles go to seedds/nxnative first, as [patches/README.md](patches/README.md#upstream-first) states. That page walks through the steps and states the patch policy (what a patch may and may not change). Files under `.github/` and in the repository root that are not in that list (this file, `CLAUDE.md`, the README) are the fork's.

## For AI agents and other tools

Issue forms and the PR template apply in the browser only. `gh issue create`, the API and MCP tools skip the forms, so follow them yourself:

- **Problem reports.** Write the body as `###` headings with the same names as the form's fields (for example `### Game, title ID and versions`, `### Copy diagnostics`, `### The game's log`) and fill every required field from [.github/ISSUE_TEMPLATE](.github/ISSUE_TEMPLATE). Ask the user for what you cannot read yourself: the Copy diagnostics output, the log, the versions. If a required field is missing, do not open the issue.
- **Ideas and plans.** These have no form. Write plain sections that fit the content, for example `### Idea`, `### Plan` and `### Done when`. Leave out the problem fields (`This is`, `NX2Apple version`, `Computer and OS`, `Copy diagnostics`). Open it with the labels `idea` and `no-triage`.
- **Pull requests.** Use the sections of [.github/pull_request_template.md](.github/pull_request_template.md): `gh pr create --template .github/pull_request_template.md`, or the same headings in `--body`. Answer each section and remove the `<!-- -->` hints. Under Fix or feature, tick one box. A change to a vendored path follows the rule above.
- **Screenshots.** A PR that changes the launcher needs before and after images in its body (see "A pull request"). On a Mac, capture the changed views of `frontend/` with `NX_LAUNCHER_CAPTURE_DIR=<dir> swift test` and `NX_CAPTURE_LANG` for the language (`de`, `sv` or `zh`, English is the default). `frontend-qt/` has no capture, so take its screenshots by hand. Attach the images with `gh pr create --attach` or `gh pr edit --attach`, once per file. Write `![before](./before.png)` in the body and pass `--attach ./before.png`. `gh` uploads the file and rewrites the path to a `https://github.com/user-attachments/assets/...` URL. This needs `gh` 2.99.0 or newer, push access to the repository, and an OAuth or personal access token (a GitHub App token is rejected). Afterwards, read the body back and check that it holds the asset URLs and no local paths. If your `gh` or token cannot attach, say so under Screenshots, give the paths of the captures, and ask the user to attach them. An agent without a Mac (a Linux runner) says under Screenshots that it could not capture the views and asks for screenshots in the PR.
- Never attach or commit keys, game files or data extracted from a game, and do not paste key values into a log or a diagnostics report.
