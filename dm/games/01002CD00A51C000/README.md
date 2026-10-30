# Baba Is You (`01002CD00A51C000`)

Update 1.0.12 (v786432), SDK 19.3.3, on NVN (131 shaders, GLSLC programs). Modules `main` and `sdk`. A Multimedia Fusion 2 game (its splash: "made using Multimedia Fusion 2 by Clickteam") on MP2 Games' Switch runtime, with its level and editor logic in Lua files in RomFS. The standard host and rewriter run this build with no game-specific fix: no shader overrides, rewriter cuts or host changes. The profile is the NSP script's provisional one with only the shader group corrected ([What it needs](#what-it-needs)). Only this update is registered in the profile.

On the Mac (2026-10-29, a short gameplay check): splash, title menu, the opening sequence and level 00 played through to its win (input moves Baba and pushes the rocks), then the world map, all at 60 fps (frame time p50 16.67 / p95 16.70 ms) with audio and no `[RED]` line. Continue Playing in a second run brought back the map with level 00 solved, so the save and its reload work. The unsigned IPA has not been built from this profile or tested on an iPhone.

## What it needs

| Setting | Where | Why |
|---|---|---|
| 3.25 GB layout: `mem_reserve 0x100000000`, `mem_alias 0x10000000`, `mem_stack 0x10000000`, `app_pool 0xCD500000` | [`game.tsv`](game.tsv) | the provisional layout, which holds: `main` sets a heap of at most the pool − 64 MB |
| `sys_resource 0x0` | `game.tsv` | the NPDM declares 0 MB of system resource: `IsVirtualAddressMemoryEnabled` is false, as on Horizon |
| `mem_used 0x6000000` | `game.tsv` | the rewritten modules are over the default 64 MB (`main` has 71 MB of bss); written by the NSP script after the rewrite |
| `shader_groups /Assets.dat=assets` | `game.tsv` | every shader is in the root `Assets.dat`; the provisional guess (`/Data/`, the largest RomFS folder) matched none and left them in the `other` package. Same shader keys either way |
| `pad_layout` (default, `simple`) | | the 2D virtual pad; the left stick moves, A waits |

## Files

- RomFS: 6,374 files, 0.10 GB. `Assets.dat` (0.02 GB, the RomFS marker) holds the shaders; `Data/` holds the sprites (PNG), worlds (`.l` / `.ld`), Lua scripts, languages and the Ogg music.
- The save holds `Settings.txt`, `ba.ba`, `0ba.ba` and `levels/world_data.txt`, written through the transactional save mount.

## Shaders

- **Current:** 120 GLSLC outputs in `Assets.dat`, each a whole program (a vertex and a pixel shader, then a reflection section), give 131 distinct shaders (15 vertex, 116 pixel), all translated for the Mac. Read by the multi-stage GLSLC reader: [GLSLC outputs holding several stages](../../../docs/reference/shaders.md#glslc-outputs-holding-several-stages).
- The prewarm list (`pso_manifest.tsv`) is empty: with about 200 draws a frame and a handful of pipelines, the first frames built theirs in the background without a draw waiting.

## Memory

- Over the runs, resident memory was 670–710 MB and Metal allocations about 1.18 GB.

## On the Mac

- After the NSP script's `--platform mac` build, its printed command runs the game. A run with the window behind other windows loses focus (`oe focus state → 2`) and the display link stops presenting, so `DM_CTL` screenshots never come; `DM_PRESENT_LINK=0` keeps it presenting ([Present thread rescues a silent display link](../../../docs/reference/frame-rate.md#present-thread-rescues-a-silent-display-link)).
- With a fresh save: A at about 22 s skips the splash, A again on the title menu's Continue Playing (or Start the Game) runs the opening; level 00 starts about 30 s later and is won by eight presses of Right.

## Found on this game

- **GLSLC outputs holding several stages** (`glslc_program`): [shaders](../../../docs/reference/shaders.md#glslc-outputs-holding-several-stages).

## Open

- iPhone: an IPA from this profile is not built or tested.
- One boot's first audio callback came 216 ms late, and the host retried the AudioUnit (`[RED] audio #0: the device has not called back`); sound played after it. The later runs did not log it.
- Only level 00 and the world map were played; later worlds, the level editor and the other languages are untested.
