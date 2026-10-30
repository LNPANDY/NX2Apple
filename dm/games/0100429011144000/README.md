# Subnautica (`0100429011144000`)

Update 1.23.83358 (v458752) over the base game, SDK 13.3.5. Unity 2019.4.36f1 IL2CPP with FMOD on NVN, the engine of [Subnautica: Below Zero](../010014C011146000/README.md): its `sdk` and `subsdk0` (the movie module) are Below Zero's builds, which AI: THE SOMNIUM FILES - nirvanA Initiative ([0100713016CCC000](../0100713016CCC000/README.md)) and Pokémon Scarlet 1.0.0 ([0100A3D008C5C000](../0100A3D008C5C000/README.md)) ship too; only `main` differs. Plays on the Mac. Tested there (a short test): the title, the main menu, a new Survival game, the lifepod opening with control, picking up and using the fire extinguisher, at 30 fps with music, in a 15-minute run. Leaving the lifepod was not reached. iOS is untested.

## What it needs

| Setting | Where | Why |
|---|---|---|
| `sys_resource 0x800000` | [`game.tsv`](game.tsv) | the NPDM's 8 MB of system resource: virtual address memory |
| 5 GB guest layout: `mem_reserve 0x140000000`, `mem_alias 0x118000000`, `mem_stack 0x10000000`, `app_pool 0x40000000` | `game.tsv` | Below Zero's layout (a 1 GB pool); see [Memory](#memory) |
| Node area cut 1 GB → 62 MB, region alignment 4 MB / 32 MB / 1 GB → 2 MB | `dm/tools/sdk_patches.py` SDK-wide rules, `sdk` build `3644a676…` | nirvanA Initiative's and Below Zero's build |
| ALLOC_BUCKET at most 63 blocks (255 on the Switch) | [`patches.py`](patches.py), `main` build `b3db5a1e…` (`main+0x60ea64`) | Below Zero's cut, carried over; see [Memory](#memory) |
| `pad_layout full` | `game.tsv` | first-person 3D: the right stick looks around |
| `shader_groups /Data/=data` | `game.tsv` | everything is under `Data/`: the player's serialized files and the Addressables bundles in `StreamingAssets/aa/Switch` |

## Memory

- As on Below Zero, `nninitStartup` hands application pool − used memory to StandardAllocator as one address region (0.94 GB, returning to `main+0x34de00`) and never sets a heap, and every other region comes from Unity's virtual allocator (`AllocateAddressRegion` called at `main+0x717924`).
- **The ALLOC_BUCKET cut.** `nso_fnmap.py` from Below Zero's `main` finds the BucketAllocator constructor (`main+0x60af48`) and `AddMoreBuckets` (`main+0x60b45c`) as exact matches; the memory manager setup's call (`main+0x60e7c8` in the function at `main+0x60e720`) passes the same arguments (granularity 16, 32 buckets, 4 MB blocks, `mov w5, #0xff` at `main+0x60ea64`) with the `ALLOC_BUCKET` name. With the cut its reservation is 0.25 GB at +1.04 GB. This is a workaround for the iPhone's address space (the alias region is 64 GB on a Switch), as on Below Zero.
- Measured with `DM_REGIONS` on the Mac: in the lifepod after 8 minutes, 330 live regions holding 2.50 GB (1.87 GB mapped), 0.84 GB of gaps, the end at +3.40 GB of the 4.375 GB alias region; at the end of a 15-minute run 321 regions, 2.47 GB, the end at +3.33 GB. The high-water mark reached +3.26 GB while the Survival game loaded.
- Resident about 3.0 GB on the Mac in the lifepod, 0.87 GB of Metal allocations, flat from frame 21,000 to 27,000.

## Files and shaders

- RomFS: 15,570 files, 3.9 GB: 5,467 UnityFS bundles (Addressables, `Data/StreamingAssets/aa/Switch`), 20 FMOD banks, 5,416 `.optoctrees` and 4,582 `.bin` world-streaming files (`SNUnmanagedData/Build18`).
- 17,956 shaders: 8,972 vertex, 8,957 pixel, 2 geometry and 25 compute, read with Unity 2019.4's layouts; 11 are the player's GLSLC outputs in `main`. All of them build for the Mac (8 minutes with an empty cache); the first boot prebuilds 16,548 pipeline pairs in about 45 s, and no run met a shader missing from the map.
- **Current, cause unknown:** `[RED] texture type mismatch: shader … declares slot 135 (or 136) as Metal type 2, texture ID 800 is type 7 (NVN target 2, format 0x38, Metal format 71); bound as is`, 5 to 8 times a run in two pixel shaders: a 3D RGBA8 texture in a slot the translated shader declares 2D, the reverse of [A 2D texture in a 3D slot binds the zero 3D texture](../../../docs/reference/rendering.md#a-2d-texture-in-a-3d-slot-binds-the-zero-3d-texture). Every Below Zero run logs the same lines. Nothing wrong was seen on screen; which pass and texture these are is not found.

## Frame rate

- 30 fps, as on the Switch: the game sets present interval 1 at its window and 2 once it runs. On the Mac (M-series) frame time p50 33.33 ms, p95 33.5–33.7 ms in the lifepod; GPU p50 3–6 ms, p95 under 9 ms; CPU energy 0.9 W.
- The game crops its window textures to the size it renders (`WindowCrop 0,0 1440x810` of 1920x1080 at the menu): a DM_CTL screenshot without `DM_NVN_SHOT_OUT` shows the whole window texture, the screen and `DM_NVN_SHOT_OUT=1920x1080` the crop.
- Not tried: `present_interval display` for 60 fps.

## Audio

- FMOD on one `AudioOut`; music and effects play.
- **Current, cause unknown:** `[RED] audio #0: the device has not called back for 216–219 ms while playing` once in each of three runs: twice right after `AudioOut Start` (3–5 s from boot), once at frame 3,300 (about 110 s, in the menu). In two of them the log shows the Mac's output device changing at that moment (`audio device buffer: … after output changed`), so a device change on the Mac is one candidate; for the stall right after the start, the device's start-up latency is another, as the watchdog in `hle_audio.c` counts its 200 ms from `AudioOutputUnitStart`. The restart a second later plays on. Below Zero's line comes at the landing instead ([its note](../010014C011146000/README.md#audio)).

## Mac routes

- From a fresh save, with `DM_CTL` (`run/ctl.sh` in the work folder) 35 s after the first frame (after the first boot's pipeline prebuild): `Plus`, `A` (Play), `A` (New Game), `A` (Survival), 40 s later `A` (Press any button), about 60 s later the player has control in the lifepod. The fire extinguisher lies on the floor beside the ladder; standing in the fire kills the player ("You died.").

## Open

- iOS untested.
- Leaving the lifepod and swimming: the world outside, its streaming and the address space it takes (watch the `[mem] alias region mapped up to` lines) are not measured.
- The audio stall at start ([Audio](#audio)) and the texture type mismatch ([Files and shaders](#files-and-shaders)).

## Found on this game

- Nothing new: the `sdk` cuts and the ALLOC_BUCKET cut are Below Zero's.
