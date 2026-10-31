# DRAGON QUEST III HD-2D Remake (`01003E601E324000`)

Update 1.1.2 (v262144) over the base game, SDK 16.2.6. Square Enix, Unreal Engine 4.27.2 (`SDK MW+EpicGames+UnrealEngine-4_27_2` in `main`): everything in one pak whose index is encrypted, NVN, CRIWARE sound (a 6-channel AudioOut beside the audio renderer) and Sofdec movies (`.usm`, decoded on CRI Mana's own threads). Modules `main`, `subsdk0` (`NintendoSDK_movie`, which `main` imports from) and `sdk`. 60 fps (30 on the Switch) by the host's write of Unreal's present interval.

Status: brought up on the Mac on 2026-10-31: the logos and the opening movie, the title, a new adventure log (name entry, appearance, voice language, objective marker, difficulty), the autosave tutorial, the opening (the voice in the dark, the forest path and the cliff by the waterfalls, walked by the player, the personality questions) into the prologue (the monster in the cave and by the well), the autosave written and continued from the title after a restart, at 60 fps with sound. No red line at run time; about 2.6 GB resident. Not built for the iPhone yet.

## What it needs

| Setting | Where | Why |
|---|---|---|
| `fps_target 60` | [`game.tsv`](game.tsv), `hle_fpslock.c` | the host writes 1 into `rhi.SyncInterval`; see [Frame rate](#frame-rate) |
| FMallocBinned3 constructor call cut, with gate `OBS_UE_MALLOC` | the rewriter's engine-wide rule (`dm/tools/ue_malloc.py`), no build ID | its pools take 37 GB of the engine region; the host's allocator runs Unreal's heap (`hle_uemalloc.c`); see [Memory](#memory) |
| Engine region given what the alias region has room for, 2.81 GB: gate `OBS_UE_REGION` on the store of its size | the rewriter's engine-wide rule (`dm/tools/ue_region.py`), no build ID; the host's room (`hle_svc.c`) | Unreal's `nninitStartup` reserves 62 GB by default |
| Node area cut 1 GB → 62 MB, regions aligned to 2 MB | `dm/tools/sdk_patches.py` function-matched cuts (`MATCH_CUTS`), `sdk` build `a5cb2175…` | the same AddressRegionManager as the other Unreal games' SDKs; matched by the code, no fixed address |
| 3.75 GB guest block: `mem_reserve 0xF0000000`, `mem_alias 0xC8000000`, `mem_stack 0x10000000`, `app_pool 0xCD500000` | `game.tsv` | DRAGON QUEST VII Reimagined's layout: alias region = node area + the engine region + 256 MB for regions made later; 256 MB stacks, 384 MB heap region |
| `sys_resource 0x5000000` | `game.tsv` | the NPDM declares 80 MB of system resource |
| `pad_layout full` | `game.tsv` | the 3D layout (a D-pad and a right stick), as Octopath Traveler II and DRAGON QUEST VII Reimagined. It plays with the controller, so it stays docked (1920x1080) |

## Frame rate

- **Current:** 60 fps (30 on the Switch). The game's Switch device profile (`Nicola/Config/Switch/SwitchDeviceProfiles.ini`) sets `rhi.syncinterval=2`, the present interval 2 it asks for while `r.VSync=1` (`BaseSwitchEngine.ini`) locks presents to vsync; no config sets `FrameRateLimit` or `t.MaxFPS`. The host writes 1 into `rhi.SyncInterval` (`hle_fpslock.c`, found by its name as in every Unreal game) whenever the game sets it back, and the game then asks for present interval 1 itself.
- Unreal steps the game by the time that really passed: from the same autosave, the same 0.6 s stick press scrolled the prologue's cave by 245 px at 60 fps and 240 px at 30 fps (`run/ab.sh`, phase correlation of the shots before and after).
- `DM_FPS_TARGET=30` (`Documents/env.txt` on the iPhone) keeps the game's own 30 and saves power.
- The texture streaming pool is the game's own concern here: its Switch profile sets `r.Streaming.PoolSize=850`, so `ue_texture_pool` is not set.

## Memory

- As DRAGON QUEST VII Reimagined ([0100A9D01C446000](../0100A9D01C446000/README.md#memory)): `nninitStartup` needs virtual address memory and reserves 62 GB for the engine; the rewriter's engine-wide rules cut the allocator's constructor and gate the region's size. The log's `[mem] Unreal's engine region: 62.00 GB asked, 2.81 GB of address space, what the alias region has room for` shows it.
- On the Mac through the opening and the prologue: up to +0.75 GB of the alias region with 0.5 GB mapped, an Unreal heap (host malloc zone) of 1 GB, about 2.6 GB resident.

## Files and shaders

- One pak, `Nicola/Content/Paks/Nicola-Switch_0_P.pak` (7.4 GB, 172,665 files, version 11 with the magic 0xcc from the end, Oodle and Zlib blocks; the profile's `romfs_marker`): the cooked packages, CRIWARE `.awb` banks (BGM, English and Japanese voices) and `.usm` movies, and the two shader code archives. The index is AES-256 encrypted, and so are 41 config files.
- **Resolved: no window of `main` holds the pak key.** The callback that hands the key to the engine loads two 16-byte literals from separate places and stores them as one; `uepak.py` now reads such keys from the code: [An Unreal pak key split into two 16-byte literals](../../../docs/reference/shaders.md#an-unreal-pak-key-split-into-two-16-byte-literals).
- Shaders: `ShaderArchive-Global-SF_GLSL_SWITCH.ushaderbytecode` (1,554 shaders) and `ShaderArchive-Nicola-SF_GLSL_SWITCH.ushaderbytecode` (46,743), stored in the pak, every shader an LZ4 block (`uepak.py` `lz4_shaders`, no host run). 47,298 unique shaders (3,823 vertex, 40,605 pixel, 2,831 compute, 39 geometry); the Mac libraries took 2 h 12 min to compile on the first build.
- One geometry shader seen in play writes only the layer, and its vertex shader draws with its layer entry points instead (the host's general rule).

## Add-on content

- The NSP folder holds 5 DLC NSPs with a licence only (103 KB each, no content); the host reports the indices as owned. Nothing in the opening asks for them.

## Mac routes

- The work folder's `run/ctl.sh` drives a run started with `DM_CTL` (`wait S` / `snap NAME`), and `run/ab.sh <tag> [VAR=value…]` boots, continues from the autosave in the first slot, presses the stick left for 0.6 s and takes shots before and after (the frame-rate check above): [05, Scripted input](../../../docs/agents/05-debugging.md#scripted-input-and-thread-scheduling).

## Found on this game

General changes first needed here; each applies to every game:

- **An Unreal pak key split into two 16-byte literals in `main`'s code** (`uepak.py` `code_keys`): [An Unreal pak key split into two 16-byte literals](../../../docs/reference/shaders.md#an-unreal-pak-key-split-into-two-16-byte-literals), [01, Compressed RomFS content](../../../docs/agents/01-extract.md#compressed-romfs-content).

## Open

- The iPhone: no IPA built or tested yet.
- Only the opening and the prologue were played; the first town, a battle and a church save are not tested yet. 38 of the 39 geometry shaders have not been seen in play.
