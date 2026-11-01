# Contributing

Issues and pull requests are welcome. NX2Apple is the launcher (`frontend/`, `frontend-qt/`) and the glue around the [nxnative](https://github.com/seedds/nxnative) engine, which is fetched here as upstream at a pinned commit plus a queue of patches (`python3 tools/engine.py sync` builds it into `engine/`), and bumped to upstream's latest every day. [AGENTS.md](AGENTS.md) describes this repository, and `engine/AGENTS.md` the engine. Building by hand from a terminal (tools, `prod.keys`, the IPA) is on its own page: [BUILDING.md](BUILDING.md).

## Reporting a problem

Game problems, build problems and launcher problems each have an issue form (`.github/ISSUE_TEMPLATE/`). The form asks for what a report needs — versions, device, Copy diagnostics, the build log's game profile lines, the game's log and the crash report. Use it from the Issues page. A report without those is usually unactionable.

## Where an issue goes

- **Here:** the app, a build or install that fails, and a game that does not run well on your Mac or iPhone or iPad.
- **[Discussions](https://github.com/LNPANDY/NX2Apple/discussions):** questions (Q&A) and ideas (Ideas). Bugs stay issues.
- **[seedds/nxnative](https://github.com/seedds/nxnative/issues):** how the engine works, porting a new game (its profile goes there as a pull request, see "Helping with games"), a rendering fault you have traced into the engine itself.

## What a report needs

Pick a form: **Game problem**, **Build problem** or **Launcher problem or idea**. Each asks for what the problem is traced with: the game, its title ID and versions, the target, the device and OS, the NX2Apple version, **Settings > Copy diagnostics**, and the log (a game's log, or the Build log on the Builds page). A report without them gets a request for them first. Where a game's log is: a Mac game in a library folder writes `log/<title ID>.log` beside its app, otherwise `~/Library/Logs/nxnative/<title ID>.log`. On an iPhone or iPad it is `log.txt` in the Files app.

**Never attach keys, game files or anything extracted from a game.** Logs, screenshots, title IDs and build IDs are fine.

## Helping with games

Each new game needs its own bring-up: a profile (build IDs, memory layout, texture slots), a shader
reader if it packs them in a form we do not read, and patch points. A game profile is engine code
(`dm/games/<id>/`), and the engine lives in [seedds/nxnative](https://github.com/seedds/nxnative). **Ways to help, all
useful:**

- **Report a game that works** — if you got a title outside the verified list running, open an issue
  with the title ID, the update version, and what you did. It becomes an entry in [GAMES.md](GAMES.md)
  that others can use.
- **Send a new game profile, or a fix to the engine, to seedds/nxnative first.** Open the pull request
  there and follow their [CONTRIBUTING.md](https://github.com/seedds/nxnative/blob/main/CONTRIBUTING.md)
  (a new game takes its profile, its note and its row in the games table). If the game also matters for
  Apple devices here, link your pull request in a Game problem issue here, or in a comment on the issue
  that already exists. Please do not send it here as a patch. If upstream is slow and the game is
  verified here, a maintainer may carry it in `patches/` as a bridge (`Upstream-Status: forwarded`)
  and credit you. If you cannot open the upstream pull request, a maintainer sends it.
- **Send the shaders that are missing** — if a game runs but stutters on first use of an effect, its
  shader variants are missing from the map. The host can dump what it cannot find
  (`DM_NVN_SHDUMP=<dir>`). Attach those and we add them to `shader_map.tsv` for everyone.

Issues with a full `Documents/log.txt` get looked at first — that log usually names the exact
missing piece.

## A pull request

- Before any work in a clone or worktree, run `git config core.hooksPath .githooks`. The hooks run the checks for what you commit and push (`python3 tools/engine.py check` for `patches/`, the tests for the code you changed, see `tools/githooks.py`). `tools/engine.py sync`, `check` and `export` install the hooks when they are not. Keep them installed and never use `--no-verify`. Never push to `main` directly. The pre-push hook rejects it for every tool, and the "Main rule" ruleset on GitHub rejects it for everyone, with no bypass.
- One change per PR, off `main`. Commit messages say what changed and why, in plain English, as `git log` does.
- Fill in the PR template: what and why, what was checked, screenshots for UI changes.
- A PR that changes anything visible in the launcher attaches before and after screenshots to the PR, under Screenshots. Show every view the PR changes, in each language it touches. A PR without them is not reviewed. A PR with no visible change writes "None, no visible change".
- **`frontend/` and `frontend-qt/` are the fork's own:** change them freely. Run `cd frontend && swift test`. For a UI change also capture the views for visual QA (`NX_LAUNCHER_CAPTURE_DIR`, see [frontend/README.md](frontend/README.md#verification)).
- **The engine is not in this repository.** `dm/`, `scripts/`, `docs/` and `ref/` are seedds/nxnative at the commit in `.upstream-ref` with the patches in `patches/` applied, built into `engine/` by `python3 tools/engine.py sync` (a git repository that git ignores here, #214). A PR that adds files under those paths fails the `pr-scope` check, because the next sync would not carry them. A fix to the engine or to a game profile lands here first, as a patch, and goes to seedds/nxnative as a pull request in parallel, as [patches/README.md](patches/README.md#here-first-upstream-in-parallel) states. If you cannot open the upstream pull request, a maintainer sends it. To make the patch, commit the change in `engine/`, run `python3 tools/engine.py export`, fill in the header of the new patch (`Upstream-Status`, `Reason`, `Issue`), run `python3 tools/engine.py check`, and commit `patches/` with it. That page walks through the steps and states the patch policy (what a patch may and may not change). Everything else in the repository root and under `.github/` (this file, `CLAUDE.md`, `AGENTS.md`, the README) is the fork's.

### Fixes, features and ideas

This section is for contributions from outside. The maintainers (v0lumehi and LNPANDY) keep their own rules, see "When a PR merges".

We want to help you build what fits and to spare you work that cannot go in. The launcher code is being reorganized, so many open PRs will need a rebase, and a change is easier to land when we agree on the design before the code is written. So features and proposals are always talked about first. Fixes stay welcome without asking.

- **A fix is welcome as a PR without asking.** Tests that cover a fix, typos and corrections in docs count as fixes. A report that a game works stays a report (an issue, or the entry in [GAMES.md](GAMES.md)), not a feature.
- **Anything that is not a fix is a feature or a proposal, and is discussed first.** That means a new feature, a change to how the launcher works or looks, a new setting, a new dependency, a new way to build or install, a refactor, a new doc page. Open an issue with the form "Launcher problem or idea" (`This is: An idea`), or an idea in [Discussions](https://github.com/LNPANDY/NX2Apple/discussions) (Ideas). A maintainer says "go" by adding the label `help wanted` to the issue. Then build it, and link that issue in your PR. A feature PR without a linked issue that has the go is not reviewed. It is closed with a friendly note after 14 days, and you can reopen it once the go is there. A draft PR as a sketch is fine, but it waits for the go like any other. For a change that touches several front ends or the architecture, the issue also holds a short design note: what you want to change, why, and the alternatives you looked at.

If it is unclear whether something is a fix, ask in an issue. The maintainers decide.

A new game profile or an engine fix goes to seedds/nxnative first, see "Helping with games".

PRs opened before this rule keep the old path: an issue within 48 hours of the first reply from a maintainer, and one maintainer agrees to the idea before the PR merges.

### Where we would love help

The [milestones](https://github.com/LNPANDY/NX2Apple/milestones) are the plan, and you are welcome to take an issue from one. Some issues are for the maintainers.

- Issues with the label [`help wanted`](https://github.com/LNPANDY/NX2Apple/labels/help%20wanted) carry a maintainer's go already. Build one straight away and link the issue in your PR.
- For any other issue in a milestone, comment that you would like to take it. A maintainer answers with a go or with a pointer, so two people do not build the same thing.
- [`good first issue`](https://github.com/LNPANDY/NX2Apple/labels/good%20first%20issue) marks the easy starts.
- Start from the problem, not the solution. Say what you want to do and what is in the way, which is what the form asks. The maintainers may point to a planned way to do it.
- If a maintainer cannot take an idea, they say so early and explain why, see [What happens to your PR](#what-happens-to-your-pr).

### What happens to your PR

A pull request from outside never merges automatically. One maintainer tries the app that CI built for the PR, which is the `NX2Apple-macOS-arm64` artifact of the Build Mac app run. The same maintainer reviews the code. Whoever looks first decides.

If the maintainers do not want a change, they say so early, explain why, and close the PR. They may keep parts of it and credit you as co-author.

A PR that waits on its author for 30 days is closed with a note that it can be reopened.

### When a PR merges

This holds for every PR. A PR from outside also gets the maintainer check above, and never merges before it.

Every fix goes through a PR. A fix merges when CI is green. No approval is needed.

An unanswered review with changes requested from a maintainer blocks the merge. A plain review comment does not block. The maintainer who requested the changes reviews again once the fix is pushed, and approves or withdraws the request. Each maintainer clears their own objections. If the two maintainers disagree about an objection, Andy ([@LNPANDY](https://github.com/LNPANDY)) decides.

A feature from the maintainers (v0lumehi and LNPANDY) merges after 48 hours. A feature from outside never merges by waiting. It merges after a maintainer agreed to the idea, tried the app and reviewed the code.

A patch in `patches/` takes the next free number from `patches/series` on `main` at merge time. Whoever merges renumbers the patch and notes it in the PR. You do not need to rebase to chase free numbers.

## For AI agents and other tools

Issue forms and the PR template apply in the browser only. `gh issue create`, the API and MCP tools skip the forms, so follow them yourself:

- **Problem reports.** Write the body as `###` headings with the same names as the form's fields (for example `### Game and title ID`, `### Copy diagnostics`, `### The game's log`) and fill every required field from [.github/ISSUE_TEMPLATE](.github/ISSUE_TEMPLATE). Ask the user for what you cannot read yourself: the Copy diagnostics output, the log, the versions. If a required field is missing, do not open the issue.
- **Ideas and plans.** These have no form. Write plain sections that fit the content, for example `### Idea`, `### Plan` and `### Done when`. Leave out the problem fields (`This is`, `NX2Apple version`, `Computer and OS`, `Copy diagnostics`). Open it with the labels `idea` and `no-triage`.
- **Before you build.** If you work for an outside contributor, a feature or a proposal needs an issue or a discussion with a maintainer's go (see "Fixes, features and ideas"). Check that it exists or ask the user. A new game profile or an engine fix goes to seedds/nxnative first (see "Helping with games").
- **Pull requests.** Use the sections of [.github/pull_request_template.md](.github/pull_request_template.md): `gh pr create --template .github/pull_request_template.md`, or the same headings in `--body`. Answer each section and remove the `<!-- -->` hints. Under Fix or feature, tick one box. A feature from outside links the issue with the go. A change to the engine follows the rule above.
- **Screenshots.** A PR that changes the launcher needs before and after images in its body (see "A pull request"). On a Mac, capture the changed views of `frontend/` with `NX_LAUNCHER_CAPTURE_DIR=<dir> swift test` and `NX_CAPTURE_LANG` for the language (`de`, `sv` or `zh`, English is the default). `frontend-qt/` has no capture, so take its screenshots by hand. Attach the images with `gh pr create --attach` or `gh pr edit --attach`, once per file. Write `![before](./before.png)` in the body and pass `--attach ./before.png`. `gh` uploads the file and rewrites the path to a `https://github.com/user-attachments/assets/...` URL. This needs `gh` 2.99.0 or newer, push access to the repository, and an OAuth or personal access token (a GitHub App token is rejected). Afterwards, read the body back and check that it holds the asset URLs and no local paths. If your `gh` or token cannot attach, say so under Screenshots, give the paths of the captures, and ask the user to attach them. An agent without a Mac (a Linux runner) says under Screenshots that it could not capture the views and asks for screenshots in the PR.
- **Release notes.** They follow `.github/release_notes_template.md`, English first, then Chinese, no emojis.
- Never attach or commit keys, game files or data extracted from a game, and do not paste key values into a log or a diagnostics report.
