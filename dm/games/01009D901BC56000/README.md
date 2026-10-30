# Donkey Kong Country Returns HD (`01009D901BC56000`)

Update 1.1.0 (v65536) over the base game, SDK 18.3.5. Unity 6000.0.28f1 IL2CPP with FMOD on NVN. Modules `main`, `subsdk0` (NintendoSDK_movie) and `sdk`; the SDK and movie module are the builds used by [Monster Train 2](../010051701FB46000/README.md) and [Super Mario Galaxy](../010099C022B96000/README.md). The base game is not registered or tested.

Plays on the Mac at 60 fps: the title, a new save, the opening movie, the island and Jungle maps, and the opening of 1-1 Jungle Hijinxs (running, jumping, damage, losing a life and restarting). An unsigned IPA is built; iOS is untested.

## What it needs

| Setting | Where | Why |
|---|---|---|
| `sys_resource 0x1000000` | [`game.tsv`](game.tsv) | the NPDM declares 16 MB of system resource: virtual address memory |
| 5 GB guest block: `mem_reserve 0x140000000`, `mem_alias 0x118000000`, `mem_stack 0x10000000`, `app_pool 0xCD500000` | `game.tsv` | Unity 6 reserves and commits its regions itself, without setting a heap, as [BALL x PIT](../010086A022444000/README.md) |
| `depth_mode zero` | `game.tsv` | the offline pipeline prebuild uses the near=0 convention the game sets at boot |
| SDK node area 1 GB → 62 MB, and regions of 4 MB and more aligned to 2 MB as SDK 20 | `dm/tools/sdk_patches.py`, the SDK-wide rules (`MATCH_CUTS`) on SDK build `60751516…` | leaves room for the game's address regions; the build's row (the node area cut alone) was removed on 2026-10-30 after a run on Monster Train 2, the same build |
| Unity 6 Shader layout | `dm/gfx/tools/unityfs.py` | no bundle supplies the stripped files' type tree; see [Shaders](#shaders) |

No game-code patch.

## Shaders

- **Resolved:** the split stopped with `no bundle has a Shader type tree of the same hash to borrow`. The 214 Shader objects have hash `2ec7223dce3af4232b14ae1441bd7999`, the same as BALL x PIT's bundles. The shared reader now supplies that layout: [Unity Shader layouts written out for players without bundles](../../../docs/reference/shaders.md#unity-shader-layouts-written-out-for-players-without-bundles).
- The layout matches the bundle tree in types, field order and alignment flags. Every Shader object and all 16 ComputeShader objects read to their exact ends; compute uses the existing 2022.3 layout (`bfdf63ab…`).
- All 19,314 shaders build for Mac and iOS, with no unresolved binding or driver-bank read the host cannot fill. The prewarm seed has 280 entries (160 shaders, 110 render pipelines, 10 compute pipelines), covering the tested opening route. A clean Mac startup prepared every entry in 0.04 seconds with no missing key or red line.
- 19,314 stage shaders: 9,596 vertex, 9,600 pixel, 117 compute and one geometry; 9,602 vertex/pixel pairs. Of these, 19,303 come from the loose serialized files under `Data/`, and 11 are the player's GLSLC outputs in `main`. RomFS has 362 files (12.50 GB), including 14 MP4 movies and 74 FMOD resource files.

## Mac routes

The work folder is `<NSP folder>/01009D901BC56000-work`. `run/boot.py <log name> <seconds> KEY=VALUE…` uses the rewritten v65536 modules and `build/returnshost`, with save and temporary storage in `run/`. `run/ctl.py --shot <name> <buttons…>` drives `DM_CTL` and takes a screenshot.

- Fresh save: L+R at the title, A at the update notice, A for slot 1, A for Modern Mode, then A for one player. Give each menu transition about two seconds. The opening movie is `GI.mp4`, 119 seconds of 1920×1080 H.264 with stereo 48 kHz AAC.
- Existing slot: L+R, A, then A for one player; the new-game mode choice is skipped. The save made after the intro starts at the island map. A enters Jungle; A selects 1-1 Jungle Hijinxs, and A starts the level. At the treehouse, press X rapidly (30 presses about 0.23 seconds apart) to finish the opening prompt; widely spaced presses do not finish it. The left stick moves, B jumps and X/Y pounds or rolls.

## Testing

- 2026-10-26, Mac: initialization, title, new-game menus, the opening MP4, save creation and reloading, island and Jungle maps, and the opening of 1-1 Jungle Hijinxs. Running, jumping over the first block, enemy damage, losing a life (four balloons to three), restarting and the pause menu work. No red line in the complete-library run, about ten minutes including the maps and first-level testing. No game-code cut or rendering switch is needed.
- Frame time p50 about 16.67 ms (60 fps); median p95 over the last twenty 300-frame windows 19.53 ms while the IPA build ran on the same Mac.
- The address-region high-water mark reaches +3.51 GB of 4.375 GB in the first level. Resident memory settles at 2.67 GB and Metal allocations at 0.96 GB: 2,674 → 2,676 MB resident and 962 → 963 MB GPU over frames 24,000–33,000, about 150 seconds.
- FMOD opens one stereo 48 kHz AudioOut. The first ten seconds of PCM contain 592,464 nonzero samples of 960,000, peak 12,940 and RMS 1,239; real Core Audio output opens without an underrun or watchdog warning. Sound was not assessed by listening.
- The unsigned IPA is about 11.6 GB (12,486,937,808 bytes), with 19,314 iOS libraries, the prewarm list and the fps counter. Archive inspection confirmed version 1.1.0, the correct bundle ID, an unsigned arm64 executable and no diagnostic environment file.

## Open

- iOS has not been tested on a device.
- Only the opening portion of the first level was played; finishing it, later levels, bosses and multiplayer remain untested.
- The other thirteen MP4 movies and non-English languages are untested.

## Found on this game

- The stripped Unity 6 Shader layout, hash `2ec7223d…`: [shaders.md](../../../docs/reference/shaders.md#unity-shader-layouts-written-out-for-players-without-bundles).
