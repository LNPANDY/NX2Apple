# Instructions for the Copilot coding agent

Read [AGENTS.md](../AGENTS.md) (the fork's, at the root) and [CONTRIBUTING.md](../CONTRIBUTING.md) first, and they win over this file.

- First, in your checkout, run `git config core.hooksPath .githooks`. The hooks run the checks before a commit and a push. Keep them installed, never use `--no-verify`, and never push to `main`: every change goes through a PR. The pre-push hook rejects a push to `main` for every tool, and the "Main rule" ruleset on GitHub rejects it for everyone, with no bypass.
- `frontend/` and `frontend-qt/` are this fork's own: change them directly. `cd frontend && swift test` is the check.
- The engine (`dm/`, `scripts/`, `docs/`, `ref/`) is not in this repository: it is seedds/nxnative at `.upstream-ref` plus `patches/`, built into `engine/` by `python3 tools/engine.py sync`. Do not add files under those paths in a PR (the `pr-scope` check fails it). A change to the engine is a pull request to seedds/nxnative first, and a patch in `patches/` (a commit in `engine/`, then `python3 tools/engine.py export`) only while the fork has to carry it.
- A feature or a proposal from outside needs an issue in a milestone (a maintainer puts an idea there when it gets a yes) before you build it. Check that it exists or ask the user. A new game profile goes to seedds/nxnative first (CONTRIBUTING.md, "Fixes, features and ideas" and "Helping with games").
- Never touch the shader translation chain (`dm/gfx/tools/dmsh_*`, `dm/gfx/nvn/dmsh_chain.h`, `dmsh_chain.lock`, the translator).
- A fix merges when CI is green, unless a maintainer's "changes requested" review is unanswered. A plain review comment does not block. The maintainer who requested the changes reviews again after your push. The owner decides only when the maintainers disagree. A feature PR from a maintainer waits 48 hours before it merges. A feature from outside never merges by waiting: a maintainer has to agree to the idea, try the app and review the code. A fix from outside gets the same maintainer check before it merges. Whoever merges a patch renumbers it from `patches/series` on `main`, so do not rebase to chase free numbers. Releases (version bumps, tags, update-history rows) are the owner's.
- Never attach or commit keys, game files or anything extracted from a game.
- You work on a Linux runner and cannot build or run the macOS app. The macOS jobs of `tests.yml` are the check: do not claim a Swift or Metal change works until they are green.
- A PR that changes the launcher needs before and after screenshots. You cannot capture them on a Linux runner: say so under Screenshots and ask for them in the PR (CONTRIBUTING.md, "For AI agents and other tools").
- Issues and PRs follow the forms and the PR template (CONTRIBUTING.md, "For AI agents and other tools").
- Release notes follow `.github/release_notes_template.md`, English first, then Chinese, no emojis.
