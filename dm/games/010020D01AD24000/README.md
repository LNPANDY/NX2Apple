# ANIMAL WELL (`010020D01AD24000`)

Update 1.0.10 (v655360), SDK 20.5.7, on NVN (46 BNSH shaders). Modules `main` and `sdk`. All its assets, the shaders among them, are embedded in `main`: the program has no RomFS. The standard host and rewriter run this build with no game-specific fix: no shader overrides, rewriter cuts or host changes. Only this update is registered in the profile. The unsigned IPA is confirmed playable on the iPhone.

On the Mac: the opening rooms at 60 fps with movement, jumping and audio; item pickup and pause menus work. One repeat run recovered from an AudioUnit startup timeout through the existing audio restart path.

**Regression recording checked (2026-10-28):** a full `regress.py check --record` against `337186cf3ce7` passed on an Apple M4 Pro, macOS 27.2 / Xcode 27.1, and wrote the [last green record](validated.tsv). Both 100-second runs reached the opening room at 60 fps, all 46 shaders and their MSL stayed unchanged, screenshots matched within tolerance, and neither run logged a `[RED]` line. Both used `DM_PRESENT_LINK=0` to control the window-occlusion effect described below. One game covers the harness's recording path; this change does not alter the host or shader chain.

## What it needs

| Setting | Where | Why |
|---|---|---|
| `romfs_marker` empty | [`game.tsv`](game.tsv) | the Program NCAs have no data section: `nx_extract --romfs-image` creates an empty RomFS image, which the empty marker checks; see [Files](#files) |
| 3.5 GB layout: `mem_reserve 0xe0000000`, `mem_alias 0x10000000`, `mem_stack 0x10000000`, `app_pool 0xCD500000` | `game.tsv` | the provisional layout, which holds: a 256 MB alias region, a 256 MB stack region and a 2816 MB heap region. `main` sets a heap of at most the pool − 64 MB − 536 MB of bss (counted as used memory) |
| `sys_resource 0x0` | `game.tsv` | the NPDM declares 0 MB of system resource: `IsVirtualAddressMemoryEnabled` is false, as on Horizon |
| `pad_layout simple` | `game.tsv` | the 2D virtual pad; B jumps |
| `shader_groups /=romfs` | `game.tsv` | the shaders are in `main` |

## Files

- Both the base and the update Program NCAs have no data section. The assets live in `main`, whose read-only segment is about 32 MB.
- **Current:** `nx_extract --romfs-image` directly writes a 56-byte `DMROMFS1` image (one root entry), with no RomFS directory; survey mode still writes a header-only manifest. It passes the same index validator as a populated image. Since the game keeps its assets in `main` and does not mount RomFS on the tested opening route, its gameplay check cannot establish populated-image read performance; synthetic filesystem tests cover reads and overlays. See [RomFS images](../../../docs/reference/packing.md#romfs-folder-transfers-fail-or-leave-stale-game-files).
- **Direct extraction checked on 2026-10-27:** the NSP pipeline produced `AnimalWell-DirectRomFS.ipa` (54.6 MiB), with all 46 iOS shaders and exactly one `Payload/DmIOS.app/romfs.img` entry. Both the extraction and IPA contain no RomFS directory. The archive's CRC check passed. This unsigned IPA has not been tested on an iPhone here.
- **Direct extraction regression: PASS.** The full 100-second `regress.py` route against `08b8a3c1ef1c` kept all 46 shaders and their MSL unchanged, with no new `[RED]` lines: 59.5 → 59.7 fps, p99 16.76 → 16.77 ms, peak 980 → 981 MiB. Screenshot differences were 1–3 dHash bits. Both hosts used `DM_PRESENT_LINK=0` for the window-occlusion control described below; the report is `<NSP folder>/010020D01AD24000-work/regress-direct-extraction/report.md`.
- **Rechecked after integration with main `4f24ce6489a2`: PASS.** A fresh 100-second baseline and candidate both ran at 60.0 fps; p99 16.77 → 16.76 ms, peak 997 → 996 MiB, all 46 shaders/MSL unchanged, screenshots within tolerance (2–3 dHash bits), no new `[RED]` lines. Both used the same diagnostic control and were marked busy by the harness. The report is `<NSP folder>/010020D01AD24000-work/regress-romfs-main/report.md`. The combined host suite, 347 tool tests, 31 iOS tests, 71 graphics Python tests and the Metal graphics suite passed; the rebuilt unsigned IPA's CRC check passed too.
- **Checked on 2026-10-27:** Mac runs with the folder and image selected both reached the opening room and passed 2,400 presented frames, with no `[RED]` lines in the completed comparison runs. Five control-triggered screenshots per input cover the room, pause and resume; all pairs are within the harness's image tolerances (2–6 dHash bits and 0.44–2.71 mean RGB difference out of 255). The folder captures use the windowless path after a busy windowed run missed captures; this establishes picture/boot behavior, not a performance comparison. An initial audio-enabled folder run recovered through the existing AudioUnit restart path. A separate unsigned `AnimalWell-RomFS.ipa` was built (54.6 MiB), with all 46 iOS shaders; it has not been installed or tested on an iPhone here. The `smoke.tsv` route uses a fresh save and leaves the character still in the opening room.
- **Measurement constraint:** a default windowed baseline/candidate comparison reported 59.7 → 27.5 fps and p99 16.75 → 134.53 ms. The candidate logged focus state 2 and display-link callbacks about once per second; the baseline remained active and used the existing silent-link rescue. A reverse-order probe reproduced the slowdown in the unchanged host too. With the existing `DM_PRESENT_LINK=0` applied to both hosts as a diagnostic control, both gave 60.0 fps and p99 16.76 ms in the 15-second measured windows. This is the documented [occluded Mac display-link behavior](../../../docs/reference/frame-rate.md#present-thread-rescues-a-silent-display-link); no presentation setting or default was changed by the image implementation. Keep the window visible and foreground for normal timing comparisons. The full multi-game regression remains pending; the attempted run reached Balatro's unsupported OpenGL chain check and began a separate game's 73,330-shader rebuild before this pass was limited to this game.
- **Controlled full-route regression: PASS.** `regress.py check --baseline 08b8a3c1ef1c --games 010020D01AD24000 --no-hud --env DM_PRESENT_LINK=0` compared the baseline with the image implementation for 100 seconds each on an M4 Pro, macOS 27.0.1 / Xcode 27.1. Both built all 46 shaders, with unchanged MSL and no interface failures or new `[RED]` lines. Baseline → candidate: 59.5 → 59.3 fps, frame p99 16.76 → 17.01 ms, peak footprint 980 → 981 MiB; all three screenshot pairs differ by one dHash bit and mean RGB 0.70–1.13 out of 255. The direct-drawable switch was applied equally to control the window-occlusion effect above; both samples were marked busy by the harness. The report is in `<NSP folder>/010020D01AD24000-work/regress-animal-well-direct/`.

## Shaders

- **Current:** 46 BNSH shaders embedded in `main` (1 vertex, 45 pixel), all translated for Mac and iOS by the existing splitter and translator. The prewarm list covers the opening rooms.

## Memory

- `main` has about 537 MB of bss, counted by the existing big-module memory rule.
- During a four-minute Mac run, resident memory stayed near 855 MB and Metal allocations at 159 MB.

## Found on this game

- **An empty RomFS for a program without a data section** (`nx_extract`; an empty `romfs_marker` checks the directory itself): [dm/games/README.md](../README.md).
- **An empty RomFS image:** [RomFS images](../../../docs/reference/packing.md#romfs-folder-transfers-fail-or-leave-stale-game-files).
- **Resolved:** `--platform mac-app` stopped at the pipeline archive (`pso_offline: no base to build`) because the profile's `shader_pairs.tsv` holds no pair; a pair list with no pair is now nothing to build and the app is packed without an archive: [Offline pipeline archive reuse and fallback](../../../docs/reference/shaders.md#offline-pipeline-archive-reuse-and-fallback) ([GitHub issue #338](https://github.com/seedds/nxnative/issues/338)).

## Open

- Save and reload are unverified: the test did not reach a save checkpoint.
- The bss is 536 MB in `game.tsv`'s comment and about 537 MB in the bring-up notes ([Memory](#memory)).
- The player-facing [README](../../../README.md) lists the games that start in the 2D layout and says the others start in 3D; ANIMAL WELL is not in that list, but its profile has `pad_layout simple` (2D).
