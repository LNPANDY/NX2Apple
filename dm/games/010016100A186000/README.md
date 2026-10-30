# SteamWorld Heist: Ultimate Edition (`010016100A186000`)

Update 2.2.1 (v65536), SDK 4.5.0, on NVN (25 shaders, BNSH files). Modules `main` and `sdk`. Image & Form's own engine (the SteamWorld series' engine, an older version of the one [SteamWorld Heist II](../010089C01E9CA000/README.md) runs on), with its shaders in a zip `.impak` archive in RomFS. The standard host and rewriter run this build with no game-specific fix: no shader overrides, rewriter cuts or host changes. The profile is the NSP script's provisional one, unchanged apart from its names ([What it needs](#what-it-needs)). Only this update is registered in the profile.

On the Mac (2026-10-29, a short gameplay check, as for Heist II): the intro's story slides, the title menu with its three save slots, a new game (Experienced), then the first mission: Piper's dialogue, the tutorial's look-up (right stick) and the move cursor (left stick), at 60 fps (frame time p50 16.67 ms, GPU p50 about 1 ms at 1080p) with audio rendered and no `[RED]` line. In a second run the game loaded the save back into the mission, so the save and its reload work. The unsigned IPA is built with the frame rate counter but not tested on an iPhone.

## What it needs

| Setting | Where | Why |
|---|---|---|
| 3.25 GB layout: `mem_reserve 0x100000000`, `mem_alias 0x10000000`, `mem_stack 0x10000000`, `app_pool 0xCD500000` | [`game.tsv`](game.tsv) | the provisional layout, which holds: `main` sets a heap of at most the pool − 64 MB |
| `sys_resource 0x0` | `game.tsv` | the NPDM declares 0 MB of system resource: `IsVirtualAddressMemoryEnabled` is false, as on Horizon |
| `modules main sdk` | `game.tsv` | `main` imports only from `sdk`; the game has no movie decoder (its cutscenes are textures, `.bntx.z`) |
| `shader_groups /Bundle/=bundle /DLC/=dlc` | `game.tsv` | every shader is in `Bundle/data01.impak` (`Shaders/*.bnsh`); `DLC/` holds none |
| `pad_layout` (default, `simple`) | | the 2D virtual pad; the left stick moves the cursor, the right stick looks around, A confirms |

## Files

- RomFS: 694 files, 0.21 GB: `Bundle/` (`Textures/`, `Audio/` with 154 WAV and 58 Ogg files, `Fonts/`, `Characters/`, `Atlases/`, `Cutscenes/` as `.bntx.z`, `Language/`), the four zip archives (`.impak`), and `DLC/dlc01`–`dlc03`: the Ultimate Edition's add-on content, in the base game's RomFS.
- The save holds `savegame_000.dat`, `progress.dat` and `settings.xml` at its root.

## Shaders

- **Current:** 25 distinct shaders from the `.bnsh` files in `Bundle/data01.impak` (basic colour and texture effects, the light overlays), all translated for the Mac.
- **Open:** the prewarm list (`pso_manifest.tsv`) is empty. On the first Mac boot the 300 frames around the first mission's start spent 321 ms on the submit thread making pipelines (311 ms of it loading shader libraries). A list recorded through the title and the first mission would spare the iPhone's first start those waits.

## Memory

- The process footprint stayed under 1 GB (963 MiB in the first mission).

## On the Mac

- After the NSP script's `--platform mac` build, its printed command runs the game; with the window covered add `DM_PRESENT_LINK=0` so `DM_CTL` screenshots still come.
- With a fresh save: the story slides start about 15 s after start; A advances them (about ten presses) to the title, then A (New Game, slot 1), A (Experienced), A (OK) and A through the next slides reaches the mission. With a save, X skips the slides and A on the title continues it.
- Single frames of 60–190 ms come at scene changes (the slides, the title, the mission load); in play the frames stay at 16.7 ms.

## Found on this game

Nothing new: it runs on mechanisms found on other games, SDK 4.5.0's NVN and services included.

## Open

- iPhone: the IPA is built but not tested.
- The empty prewarm list ([Shaders](#shaders)).
- Only the start of the first mission was played; combat, the ship, the map, the DLC missions and the other languages are untested.
