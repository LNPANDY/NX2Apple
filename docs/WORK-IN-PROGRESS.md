# Work in progress

Everything below is either finished-but-unmerged, half-done, or researched-only. Ordered by
what blocks the most other work. Keep this file current: an item moves to "Done" only when it
is on main and verified.

Last updated: 2026-10-26.

## Done and on main (for reference)

| Item | Commit |
|---|---|
| SwiftUI app: v0.4.3, self-update, repo download/pull, 58→69 games | `v0.4.3` |
| Save-load deadlock (issue #4), ported upstream as PR #141 | `569a415`, upstream `b87a0cc` |
| NuGet / DOTNET_ROOT / xattr environment fixes | `1cd32ed`, `ed06721`, `9741197` |
| Sync guards: unit tests + patcher-consistency check in the sync | `f074175`-1 |
| Daily health-check workflow | `.github/workflows/daily-health.yml` |
| Qt front end (Windows + macOS), dark card UI, high-DPI, ~80 MB package | `9112dda`, `ba92be2`+ |
| Windows build capability (4,100 lines: toolchain, shims, cross-compile) | `f074175` |
| Touch-pad geometry + `DM_TOUCH_PREVIEW` (layer 1 of touch support) | `9112dda` |
| Roadmap + multiplayer protocol notes | `docs/ROADMAP.md`, `docs/MULTIPLAYER.md` |

## A. Needs your test on Windows (blocking my next step)

**The Windows build path has never run on Windows.** The Qt front end runs (you opened it) and
the build capability is written and unit-tested on macOS, but nobody has clicked Build on a
Windows machine.

- [ ] Download the latest `NS-Port-Builder-qt-windows-x64.zip`, run it, and report:
      does the dependency panel find a .NET SDK, and what does it say about LLVM/MinGW,
      iPhoneOS SDK and Metal tools (`python -m nspb_qt.win.doctor` gives a full report).
- Blocked by this: everything in section C.

## B. Half-done, finish without your input

- [x] **BC texture decode** — DONE (`7d2e044`, `840b58b`). `dm/third_party/bcdec/` (public
      domain), `dm/gfx/tex/nvn_bcdec.{c,h}`, `tex_bc_cpu` profile key, device check in
      `nvn_mtl.m`, CPU expansion in `pkg_upload_`. Unit test `t_bcdec.c` passes (BC1 matches an
      independent DXT1 decoder byte for byte). **Still needs an A15/A16 device to prove the
      rendered result** — neither of us has one.
- [ ] **Launcher architecture A**: `Documents/games/<titleID>/{romfs,msl,save,temp}` layout,
      `main.m romfs_locate` extended to look there, `DM_ROMFS`/`DM_MSL_DIR`/`DM_SAVE` set from the
      chosen game. This is what makes an external drive work. The runtime-profile part
      (`hle_profile.c`) was proven in a worktree but is **not merged**.
- [ ] Commit the runtime-profile work from the investigation
      (`/tmp/nx-mg`, branch `mg-profile-runtime`) if we adopt architecture A or B — currently the
      experimental patches live only in that worktree.
- [ ] v0.4.4 release once B has something user-visible (external drive support is the best
      candidate).

## C. Researched only, not started

Ordered by value per week. See `docs/ROADMAP.md` for the reasoning.

| # | Item | Effort | Why not started |
|---|---|---|---|
| C1 | **Relative touch look** (`hle_look.c` idea) | 1–2 wks | touch-the-wild's version depends on per-game observation hooks and float-exact provenance; author says unstable. Layer 1 (geometry) is already in |
| C2 | **Native aspect ratio** (`hle_aspect.c` idea) | 3–5 d per game | Needs per-game projection offsets; layer 1 came first |
| C3 | **Atmosphère cheats** | 0 if upstream merges PR #268 | Waiting on upstream; falls back to ~1 wk of our own if it stalls |
| C4 | **Settings capability gating** (`requires` + `defaultAtFps` from AnySwitch) | 1–2 wks | Polish; needs `settings.tsv` schema change |
| C5 | **Universal launcher architecture B** (4–8 games per IPA) | 3–4 wks | Blocked on: NRO-style module packing for non-NRO modules (`loader.c map_image`), and on deciding whether 4–8 games is worth it |
| C6 | **Multiplayer (LAN / lan-play / wireless)** | 2–3 wks for one game | Protocol documented in `docs/MULTIPLAYER.md`; needs BSD socket layer + virtual network + per-game `ldn` mapping. Untested: iOS multicast entitlement on a sideloaded IPA |
| C7 | **Launcher architecture C** (`dlopen` per-game framework) | large | Feasibility experiment **passed** on a device (iOS 27.0.1, sideloaded: `dlopen` of a nested framework + `dlsym` + call, docs/probe-dlopen.md); next is one real game as a framework in a shell app |
| C8 | **Pikmin 4 / Yoshi / other fork profiles** | days each | Cherriable from forks once their PRs land upstream |

## D. Blocked on upstream

- [ ] PR #268 Atmosphère cheats — watch for merge; our daily sync will bring it in.
- [ ] seedds/nxnative#205 (we filed): ARM64 branch range on a 185 MB text. Without it,
      EA Sports FC 27 and similar large titles cannot be rewritten.
- [ ] Upstream PRs from forks worth cherry-picking: #218/#216 (Yoshi sparse textures, texraw),
      #261 (CPU deswizzle, already merged), #269 (Pokémon Violet + BLE).

## E. Small things I noticed but have not done

- [ ] The Qt front end has no reproducible "check for app updates" (the SwiftUI one has it).
- [ ] Qt front end: per-stage percentage display (currently an indeterminate bar for the
      running stage; the SwiftUI app shows real percentages from the script's own output).
- [ ] `frontend-qt/README.md` says the Windows path is untested — update once section A passes.
- [ ] The games table in both READMEs is hand-inserted; `refresh_badges()` already counts the
      folders, so the table could be generated too.
- [ ] `docs/ROADMAP.md` predates the BC/multiplayer findings; fold them in.

## How to use this file

- Pick from A first if you are the one with the hardware; otherwise B.
- C is a menu, not a queue: each entry names its own blocker.
- Anything finished goes to the top table with its commit, so the list stays short.
