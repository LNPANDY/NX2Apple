# Notes for Claude

- Read [AGENTS.md](AGENTS.md) first.
- For an issue or a pull request, follow [CONTRIBUTING.md](CONTRIBUTING.md), section "For AI agents and other tools", and the templates in `.github/`.
- `dm/`, `scripts/`, `docs/`, `ref/` and `AGENTS.md` are upstream plus the patch queue in `patches/`: a change there is a patch (`scripts/patches.py export`, see [patches/README.md](patches/README.md)), not a direct edit, and `scripts/patches.py check` fails otherwise.
- **Commit as this repository's owner, not upstream's.** AGENTS.md ends with `git -c user.name=seedds -c user.email=…` because it is written for seedds/nxnative, where seedds is the maintainer; here the commits are LNPANDY's, and the repository's own `user.name`/`user.email` already say so. Do not pass `-c user.name=`/`-c user.email=` by hand: it makes fork commits show upstream's author (six of 2026-10-30's commits did, including `v0.7.2`).
