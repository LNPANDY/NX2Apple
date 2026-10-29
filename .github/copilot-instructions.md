# Instructions for the Copilot coding agent

Read [AGENTS.md](../AGENTS.md) and [CONTRIBUTING.md](../CONTRIBUTING.md) first; they win over this file.

- `frontend/` and `frontend-qt/` are this fork's own: change them directly. `cd frontend && swift test` is the check.
- The vendored engine (`dm/`, `scripts/`, `docs/`, `ref/`, `AGENTS.md`) comes from upstream every day: do not edit it in a PR (the `pr-scope` check fails it). Until the `patches/` mechanism (#124) lands, `scripts/sync_upstream.py` (its `OURS` and `PATCHED` lists) is what protects a fork change there; ask a maintainer to add a patcher. Once it lands, a change to an engine path goes only through `patches/`.
- Never touch the shader translation chain (`dm/gfx/tools/dmsh_*`, `dm/gfx/nvn/dmsh_chain.h`, `dmsh_chain.lock`, the translator).
- A feature PR waits 48 hours for the owner before it merges. Releases (version bumps, tags, update-history rows) are the owner's.
- No AI attribution anywhere: no "Generated with", no `Co-Authored-By` for a tool, in commits, PRs or issues.
- Never attach or commit keys, game files or anything extracted from a game.
- You work on a Linux runner and cannot build or run the macOS app. The macOS jobs of `tests.yml` are the check: do not claim a Swift or Metal change works until they are green.
- Issues and PRs follow the forms and the PR template (CONTRIBUTING.md, "For AI agents and other tools").
