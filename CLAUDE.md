# Notes for Claude

- Read [AGENTS.md](AGENTS.md) first.
- For an issue or a pull request, follow [CONTRIBUTING.md](CONTRIBUTING.md), section "For AI agents and other tools", and the templates in `.github/`.
- `dm/`, `scripts/`, `docs/`, `ref/` and `AGENTS.md` are upstream plus the patch queue in `patches/`: a change there is a patch (`scripts/patches.py export`, see [patches/README.md](patches/README.md)), not a direct edit, and `scripts/patches.py check` fails otherwise.
- **Commit with your own git identity.** Use the one configured for your clone, or your own name and email. AGENTS.md ends with `git -c user.name=seedds -c user.email=…`: that is seedds' own identity, written for his repository. Do not copy it unless you are seedds: it attributes your commits, and the `From:` line of patches made with `scripts/patches.py export`, to him (six commits on 2026-10-30 did, including `v0.7.2`, and patch 0033 in #230).
