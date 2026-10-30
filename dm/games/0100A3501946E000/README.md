# OCTOPATH TRAVELER II (`0100A3501946E000`)

Update 1.1.1 (v131072) over the base game, SDK 12.3.2 (its own `sdk` build). Square Enix / Acquire, Unreal Engine 4.27 (`++UE4+Release-4.27`): everything in one pak with the shaders inline in the cooked packages, NVN, PhysX, CRIWARE (ADX2 sound through a 6-channel AudioOut, USM movies). Modules `main`, `subsdk0` (the movie module) and `sdk`. 60 fps (30 on the Switch) by the host's writes of Unreal's frame limits.

Status: brought up on the Mac: the boot, the initial settings, the title, a new game, the traveler selection (the stick's quill cursor and L / R), Hikari's opening into his first battle (the battle tutorials, a won battle and the scene after it) and Castti's opening (the flashback, the ship, free play on the deck: talking, the Path Action tutorial), at 60 fps (frame time p50 16.7 ms, p95 about 17 ms) with CRIWARE sound; about 2.8 GB resident with 1.4–1.9 GB of Metal allocations in the battle. Plays on the iPhone (IPA 5.9 GB, user, 2026-10-25), also with the geometry split and the Unreal-heap thread stacks below (16f4889).

## What it needs

| Setting | Where | Why |
|---|---|---|
| `fps_target 60` | [`game.tsv`](game.tsv), `hle_fpslock.c` | the host writes 60 into `t.MaxFPS` (`main+0x76fef58`) and 1 into `rhi.SyncInterval` (`main+0x75ad0d0`); see [Frame rate](#frame-rate) |
| FMallocBinned3 constructor cut: `main+0xbecc08` `bl 0xc4d778` → `nop` | [`patches.py`](patches.py), `main` `0d964901…` | its pools are cut out of the engine region; see [Memory](#memory) |
| Observation gate `OBS_UE_MALLOC` at `main+0xbecc0c` (orig `mov x0, x19`) | `patches.py` | puts the host allocator's vtable into the new object in x19 (`hle_uemalloc.c` layout `UE4_27`) |
| `game_args -SwitchVirtualAddressSpaceSize=2048` | `game.tsv` | a 2 GB engine region instead of 62 GB |
| Node area cut 1 GB → 62 MB (`sdk+0x346190` / `+0x34622c`) and regions of 4 MB and more aligned to 2 MB, as SDK 20 (`sdk+0x346384` / `+0x34638c` / `+0x346390`) | `dm/tools/sdk_patches.py`, the SDK-wide rules (`MATCH_CUTS`) on `sdk` build `5bcf525f…` | the AddressRegionManager constructor at `sdk+0x346180`; the 2 GB engine region then starts 62 MB into the alias region. Until 2026-10-30 a row for this build gave the node area cut only, and the region came at alias +0.75 GB (a run to the smoke route's end on each) |
| 3.75 GB guest block: `mem_reserve 0xF0000000`, `mem_alias 0xC8000000`, `mem_stack 0x10000000`, `app_pool 0xCD500000` | `game.tsv` | as DRAGON QUEST VII Reimagined: alias region = node area + the 2 GB region, with room left over from when the region was aligned to 1 GB |
| `sys_resource 0x5000000` | `game.tsv` | the NPDM declares 80 MB of system resource |
| `pad_layout full` | `game.tsv` | the battle menu picks a weapon with the D-pad. It reads the controller only, so it stays docked (1920x1080) |
| `shader_groups GlobalShaderCache=global #Engine/=engine #Majesty/=game` | `game.tsv` | the global shader cache, the engine's materials and the game's |

## Frame rate

- **Current:** 60 fps (30 on the Switch). The game's Switch device profile (`Majesty/Config/Switch/SwitchDeviceProfiles.ini`) sets `t.MaxFPS=30` and `rhi.syncinterval=2` (its Windows, PS4 and PS5 profiles set `t.MaxFPS=60`; there is no fixed frame rate). As for Octopath Traveler 0 and DRAGON QUEST VII Reimagined, the host writes 60 and 1 into the two console variables whenever the game sets them back (registered at `main+0x2e50444` and `main+0x134d380`; the TAutoConsoleVariable holds at +0x10 the pointer to its value, the game thread's copy then the render thread's).
- The same scripted route into Hikari's battle at 30 and at 60 fps (frame time p50 33.4 → 16.7 ms, `run/ab.sh`) reached the same scenes at the same times: Unreal steps the game by the time that really passed. `DM_FPS_TARGET=30` keeps the game's own 30.

## Memory

- `nninitStartup` (`main+0xbebd44`) needs virtual address memory, sets a 6 MB heap for the C library's malloc (`SetMemoryHeapSize`) and reserves the engine region with `nn::os::AllocateAddressRegion` (`main+0xbec3b4`): 62 GB unless `-SwitchVirtualAddressSpaceSize=` (MB) set it.
- **Current: the allocator is the host's.** `GCreateMalloc` (`main+0xbecbf0`) mallocs 0x1c38 bytes on the first allocation and constructs them (`main+0xbecc08` → `main+0xc4d778`, which stores the vtable `main+0x64710b0`). The constructor call is cut and the gate after it hands Unreal the host's malloc zone. The vtable has 20 slots, the 4.27 layout without `OnMallocInitialized`: TryMalloc / TryRealloc call +0x18 / +0x28, slots 17 and 18 return 1, 19 the name; the 21st word the host copies is the next vtable's offset to top, which nothing calls.
- **Current: a 2 GB region** with the node-area cut on this SDK 12.3.2 build, in a 3.75 GB guest block. On the Mac: the region mapped up to +1.76 GB of the 3.12 GB alias region, the Unreal heap up to 1.25 GB.

## Rendering

- **Resolved: the traveler selection's map black**, the travelers on their pedestals around it: its pixel shader binds 66 resources, over the host's old limit of 64: [More than 64 bindings in one shader](../../../docs/reference/shaders.md#more-than-64-bindings-in-one-shader).
- **Resolved: the picture bright green and white** from Castti's opening flashback and the battlefield of Hikari's opening on, with pipelines built on demand: the precompile look-ahead lost the scissor: [The precompile look-ahead restores the scissor](../../../docs/reference/shaders.md#the-precompile-look-ahead-restores-the-scissor).
- **Resolved: a point light's shadow geometry skipped** (`[RED] geometry draw needs 261 MiB of scratch`): one 129,032-triangle mesh drawn through Unreal's one-pass point light shadow at the start of the first battle and in the scene after it, now drawn in runs: [Geometry draws above the capture scratch bound](../../../docs/reference/shaders.md#geometry-draws-above-the-capture-scratch-bound). Its first frame takes about 0.4 s on the Mac (two new pipelines and the scratch allocation).

## Files and shaders

- Everything is in `Majesty/Content/Paks/Majesty-Switch.pak` (version 11, the 0xcc footer, 3.3 GB, 376,601 files, Zlib blocks, index not encrypted; the profile's `romfs_marker`), beside the CRIWARE banks (`CueSheet_BGM.awb` and others), the two 720p title background movies (`TitleBackgroundMovie/*.usm`) and vibration data. The update is a delta over the base RomFS, so the merged extraction holds the whole game. The DLC NSP holds a licence only.
- Shaders: 13,980 unique (1,910 vertex, 11,346 pixel, 694 compute, 30 geometry), inline in the cooked packages as LZ4 blocks: [Unreal Engine 4.27 shaders inline in cooked packages (LZ4)](../../../docs/reference/shaders.md#unreal-engine-427-shaders-inline-in-cooked-packages-lz4). The game has no PC version in this repository, so the facts table holds only compute group sizes; every vertex shader is made to link with any pixel shader (`shader_split.py` `separable_pairs`).
- Prewarm list ([`pso_manifest.tsv`](pso_manifest.tsv), 843 lines): recorded on the Mac with prewarm off over the boot, the title, the traveler selection, Hikari's opening and first battle and Castti's opening on the ship.

## Input

- On the traveler selection a traveler's card opens while the quill cursor rests on them; L / R step from traveler to traveler and open each. A scripted press with the stick fully tilted swept the cursor past every traveler (a tilt of 0.3 is inside the game's dead zone), so scripted input takes partly tilted sticks, `L<x>/<y>` and `R<x>/<y>` (`hle_hid.c`; `L-0.6/-0.4~0.5` moves the cursor one traveler at a time).

## Mac routes

- [`smoke.tsv`](smoke.tsv) loads a copy of `saves/hikari-settings` (the initial settings only), selects Hikari, closes the first battle tutorial and executes his first attack. That attack exercises the 129,032-triangle geometry split above and opens the boost tutorial shown by the comparison screenshots.
- **Geometry integration validation (M6 Mac, `e06adb2a` baseline, 440 seconds):** both revisions execute the 129,032-triangle split after the first attack; the corrected candidate completes without a crash, hang or red diagnostic. Baseline/candidate: 59.8/59.8 fps, frame p99 18.06/18.51 ms, peak footprint 3,609/3,762 MB; all 1,903 pipeline bases prebuild. Both comparison screenshots pass (RGB differences 0.32 and 0.36). After that measured window, closing the boost tutorial and taking a further candidate screenshot confirms the battle scene. The earlier failing run remains recorded as the descriptor-lifetime bug's reproduction.
- **Compute primitive-ID follow-up (M6 Mac, `2c31212f` baseline, 440 seconds):** both revisions again execute the 129,032-triangle split; no new red diagnostic, crash, hang or shader-interface failure. Baseline/candidate: 59.8/59.6 fps, frame p99 17.63/17.39 ms, peak footprint 3,830/3,766 MB; all 1,903 pipeline bases prebuild. Both comparison screenshots pass (RGB differences 0.06 and 0.10). After the measured window, closing the boost tutorial in both runs confirms the battle geometry. The [general primitive-ID fix](../../../docs/reference/shaders.md#split-geometry-primitive-ids) is verified independently with a shader that reads the ID; this route checks the changed splitter in gameplay.
- The work folder's `run/ctlrun.sh <run>` starts a run with `DM_CTL`, `run/see.sh <shot> <wait> <presses…>` presses and takes a screenshot, `run/mash.sh` presses through dialog. From `run/save_ref` (the initial settings only): `run/to_ship.sh <run>` goes through the title, New Game and Castti (R L L L L on the traveler selection) to her free play on the ship's deck, `run/to_hikari.sh` to Hikari's battlefield (R L L L), `run/to_battle.sh` on through his first battle and the scene after it, and `run/ab.sh <prefix> "<env>"…` drives several runs at once into Hikari's battlefield with shots along the way (how the scissor fix was found): [05, Scripted input](../../../docs/agents/05-debugging.md#scripted-input-and-thread-scheduling).

## Found on this game

General changes first needed here; each applies to every game:

- **Unreal paks with inline shaders read in version 11, and Zlib / LZ4 pak blocks decoded in Python** (`uepak.py` `inline_shaders`, `Pak.read`; `shader_split.py` `ue_legacy_jobs`, `ue_inline_shaders`; `profile_guess.py` `ue_legacy`): [Unreal Engine 4.27 shaders inline in cooked packages (LZ4)](../../../docs/reference/shaders.md#unreal-engine-427-shaders-inline-in-cooked-packages-lz4).
- **More than 64 bindings per shader** (`NVN_REFL_MAXB`, now 128): [More than 64 bindings in one shader](../../../docs/reference/shaders.md#more-than-64-bindings-in-one-shader).
- **The precompile look-ahead restores the scissor** (`pso_predict_rest`; `DM_NVN_PREDICT=0` turns the look-ahead off): [The precompile look-ahead restores the scissor](../../../docs/reference/shaders.md#the-precompile-look-ahead-restores-the-scissor).
- **Geometry draws above the scratch bound drawn in runs, the index compaction in three dispatches, large scratch arenas released when idle** (`geo_split`, `nvn_geometry.h`, `arena_begin`): [Geometry draws above the capture scratch bound](../../../docs/reference/shaders.md#geometry-draws-above-the-capture-scratch-bound).
- **Recursive splits retain their original descriptor when child draws reuse the geometry job** (`geo_split`): [Recursive geometry splits retain their original draw range](../../../docs/reference/shaders.md#recursive-geometry-splits-retain-their-original-draw-range). The first-attack regression exposed an invalid index read in the job-based integration; a CPU reproduction verifies the ownership fix independently of the game.
- **Guest primitive IDs retain the original draw's offset across compute splits**: [Split geometry primitive IDs](../../../docs/reference/shaders.md#split-geometry-primitive-ids). Found while reviewing this game's large shadow draw; the failure and fix are established with a real translated synthetic shader, independently of game-specific shader behavior.
- **Thread stacks from the host's Unreal heap accepted by `MapMemory`** (`dm_ue_heap_owns`): [Thread stacks from the host's Unreal heap](../../../docs/reference/memory.md#thread-stacks-from-the-hosts-unreal-heap).
- **The SDK-wide 2 MB alignment checked on SDK 12.3.2** (`sdk_patches.py` `MATCH_CUTS`; this build's row removed): [1 GB alignment of regions of 1 GB and more](../../../docs/reference/memory.md#1-gb-alignment-of-regions-of-1-gb-and-more).
- **Partly tilted sticks in scripted input** (`L<x>/<y>`, `hle_hid.c`) and the host Makefile rebuilding on a change to `dm/gfx/nvn/*.inc` alone.

## Open

- **A rare crash at the title** on a task graph thread (`main+0x1d8054`, 2 of 87 Mac boots). The game's CRI cue sheet loader runs one task per cue sheet (`main+0x1e356c`, each under its own manager's mutex at manager+0xe0; the GameThread takes it too) and copied record 2 of a cue sheet's 73 (manager+0x70, 0x70 bytes each, copy assignment `main+0x1d7ddc`) while the record's TArray at +0x60 held count 1 and no data, the state of a TArray between `CopyToEmpty`'s count and its allocation; both crashes stopped at the same record. Probes showed two such tasks at once on two task graph threads, each with its own manager, and no thread holding another's lock; eight boots with `MallocScribble=1` did not crash, which argues against reading freed memory. Which thread writes the record is not found yet.
