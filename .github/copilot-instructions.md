# Instructions for the Copilot coding agent

Read [AGENTS.md](../AGENTS.md) (the fork's, at the root) and [CONTRIBUTING.md](../CONTRIBUTING.md) first, and they win over this file.

- `frontend/` and `frontend-qt/` are this fork's own: change them directly. `cd frontend && swift test` is the check.
- The engine (`dm/`, `scripts/`, `docs/`, `ref/`) is not in this repository: it is seedds/nxnative at `.upstream-ref` plus `patches/`, built into `engine/` by `python3 tools/engine.py sync`. Do not add files under those paths in a PR (the `pr-scope` check fails it). A change to the engine is a pull request to seedds/nxnative first, and a patch in `patches/` (a commit in `engine/`, then `python3 tools/engine.py export`) only while the fork has to carry it.
- Never touch the shader translation chain (`dm/gfx/tools/dmsh_*`, `dm/gfx/nvn/dmsh_chain.h`, `dmsh_chain.lock`, the translator).
- A feature PR waits 48 hours for the owner before it merges. Releases (version bumps, tags, update-history rows) are the owner's.
- No AI attribution anywhere: no "Generated with", no `Co-Authored-By` for a tool, in commits, PRs or issues.
- Never attach or commit keys, game files or anything extracted from a game.
- You work on a Linux runner and cannot build or run the macOS app. The macOS jobs of `tests.yml` are the check: do not claim a Swift or Metal change works until they are green.
- A PR that changes the launcher needs before and after screenshots. You cannot capture them on a Linux runner: say so under Screenshots and ask for them in the PR (CONTRIBUTING.md, "For AI agents and other tools").
- Issues and PRs follow the forms and the PR template (CONTRIBUTING.md, "For AI agents and other tools").
