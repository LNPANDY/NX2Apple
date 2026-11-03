# Project Charter

A standalone project: a cloud-built, NX2Apple-based line for two games,
maintained as our own numbered patches on top of the upstream NX2Apple
patch queue. This repository was forked from LNPANDY/NX2Apple on
2026-11-03.

## Isolation from the existing project

This repository is fully independent of Tiaoge-tou/nxnative (the current
fork-based build line). Neither repository reads, writes, or depends on
the other:

- The existing project keeps running exactly as before; nothing in this
  repository affects its hourly upstream sync, its build workflow, or
  its delivered packages.
- Work here can be paused or abandoned at any time and the existing
  project remains the fallback. Returning to it requires no migration.

## Scope

Only two games are in scope:

- Hollow Knight: Silksong — 010013C00E930000
- Hades II — 0100A00019DE0000

Dark Souls Remastered is not followed in this project for now; it stays
with the existing project only.

## Settled decisions (2026-11-03)

1. **BC route: upstream NX2Apple's own patch 0008** (full CPU decode of
   BC1–BC7). The old fork's two BC groups are NOT ported:
   - H (per-format gate: refuse only BC6H/BC7 at texture creation), and
   - I (BC1–BC5 transcode on upload via a device-aware format map).
   Consequence: no-BC GPU behaviour in this project is whatever 0008
   provides. **Verification on an iPhone 13 Pro (A15, no BC support) is
   a mandatory acceptance item for the first build batch** — the old
   fork's route was proven on that device, this one is not yet.
2. **Our patches start at 0061**, appended after the upstream series
   (which currently ends at 0060). Grouping follows the patch inventory
   of the old fork's 227 own commits (193 to port, 17 groups), minus
   groups H and I above. Group Q (green-screen bisect switches) is
   optional and undecided. Group A (the GitHub Actions cloud workflow)
   is a repository-level file and does not enter the engine patch
   series.
3. **fpslock accounting (display-rate / 120 Hz):** the O group
   (display-rate-120hz) records only our own delta when ported — the
   Silksong `k_locks` row, the conditional continuation of the tick when
   no fixed target exists, the display-rate servo (write the measured
   display rate over the FPS_I32 field, restore −1 on release), and its
   two guards (`target && nier`, `fb.n && target`). Upstream's
   `target_row()` dynamic scan is upstream-originated and is not
   counted as one of our patches. One rule is binding for the port:
   dynamically scanned rows must be excluded from the display-rate
   servo, and the Silksong row must carry an explicit display-rate
   eligibility flag, so a 60/target step field is never written 120.

## Phases

- **Phase 1 — Skeleton & secrets list.** This charter; the list of
  repository secrets the cloud workflow will need (names and purposes
  only; values are entered by the owner in repository Settings).
- **Phase 2 — Patch port, 0061+.** Rebase the grouped changes from the
  inventory onto this tree's patch queue, one group at a time, keeping
  each patch self-contained and re-appliable by the tree's sync machinery (`tools/engine.py`, driven by `.github/workflows/sync-upstream.yml`).
- **Phase 3 — Cloud workflow for the two games.** Repository-level
  GitHub Actions workflow (group A) building Silksong and Hades II only,
  slim IPA delivery, game sources fetched the same way as the existing
  project.
- **Phase 4 — First builds & acceptance.** First packages for both
  games, including the mandatory iPhone 13 Pro BC verification from
  decision 1, before this line is considered usable.
