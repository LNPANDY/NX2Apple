# BALL x PIT (`010086A022444000`)

Update 1.293 (v393216), SDK 20.5.19 (its own `sdk` build). Unity 6000.0.62f1 IL2CPP with FMOD, Addressables and Rewired, on NVN, as Hollow Knight: Silksong ([010013C00E930000](../010013C00E930000/README.md)). Modules `main`, `subsdk0` (the SDK's movie library) and `sdk`. Plays on the iPhone (IPA 1.1 GB); 60 fps. It needed no host change.

On the Mac: the boot, the title, a new game, the intro and the descent into the pit, the first dive and its tutorial (moving, aiming and shooting the balls, gems and XP, the enemy waves that overrun the player and end it), and the base-building tutorial (the sidebar, the build menu, placing a wheat field and a forest, the first harvest with ZR), with FMOD sound. 60 fps (frame time p50 16.66 ms, p95 about 16.8 ms; GPU 1–5 ms a frame), about 1.6 GB resident and 0.7 GB of Metal allocations, flat over 10 minutes; no red line on that route. The title is up within 25 s of launch. The prewarm list covers that route (297 lines).

## What it needs

| Setting | Where | Why |
|---|---|---|
| Node area cut 1 GB → 62 MB | `dm/tools/sdk_patches.py` SDK-wide rules, `sdk` build `8bfebccd…` | Unity 6 takes all its memory through `AllocateAddressRegion`, after the node area; see [Memory](#memory) |
| `sys_resource 0x1000000` | [`game.tsv`](game.tsv) | the NPDM declares 16 MB of system resource, so `IsVirtualAddressMemoryEnabled` is true |
| 5 GB block: `mem_reserve 0x140000000`, `mem_alias 0x118000000`, `mem_stack 0x10000000`, `app_pool 0xCD500000` | `game.tsv` | Engage's block of the other Unity games with virtual address memory (4.375 GB alias region) |
| `pad_layout full` | `game.tsv` | the 3D gamepad layout: in a dive the right stick aims |

## Memory

- As Hollow Knight: Silksong: 16 MB of system resource, no heap (`main` never sets one), Unity 6 reserving and committing its memory itself through `nn::os::AllocateAddressRegion` and `AllocateMemoryPages` in the alias region, Engage's 5 GB block, and the node-area cut on this `sdk` build.
- **Node area cut** on `sdk` build `8bfebccd6f5c1392597b364b9ab22a8d`: its AddressRegionManager constructor is the SDK 20.5.22 build's (Tears of the Kingdom's, [0100F2C0115B6000](../0100F2C0115B6000/README.md)) at the same offsets: the constructor at `sdk+0x145cfc`, the limit at `sdk+0x145d0c`, the occupied length at `sdk+0x145d78` (`mov w8 / w9,#0x3fe00000` → `#0x3e00000`).
- The provisional profile was right as generated; the `sdk` build only needed the cut ([The SDK's address-region node area](../../../docs/reference/memory.md#the-sdks-address-region-node-area)).
- Measured on the Mac over 10 minutes of the first dive and the base: the alias region's high-water mark +2.00 GB of 4.375 GB, 1.26 GB mapped, 1.6 GB resident, 0.7 GB of GPU memory, flat.

## Rendering

- Docked, the game draws 1280x720 into 1920x1080 window textures and crops the window to 1280x720 (`nvnWindowSetCrop`), which the present scales to the screen. A Mac shot shows the crop only with `DM_NVN_SHOT_OUT`.

## Files and shaders

- 38,099 shaders (18,913 vertex, 18,917 pixel, 116 compute, 76 hull and domain, one geometry), 11 of them the player's own GLSLC outputs in `main`; everything is under `Data/` (`shader_groups /Data/=data`).
- Addressables: 11 bundles in `StreamingAssets/aa/Switch`; FMOD banks in `StreamingAssets` (one stereo AudioOut).
- The loose serialized files (`resources.assets`, `sharedassets1.assets`, the built-in resources) have no type trees. They borrow the `Shader` tree that 10 of the bundles carry (the same type hash; `shader_split.py` defers a file that raises `NoTree` to a second pass), so `unityfs.py` needed no layout, as for Silksong ([Unity 6 Shader objects](../../../docs/reference/shaders.md#unity-6-shader-objects)).
- `romfs_marker` is `Data/sharedassets1.assets`.

## Input

- Docked with the 3D pad layout (`pad_layout full`); it reads no touch. In a dive the left stick moves, the right stick aims, ZR shoots and X toggles autofire. In the base the left stick moves the build cursor, A confirms, B goes back, X opens the sidebar, ZR sends a worker out to harvest and ZL + R pans.

## Mac routes

- The work folder's `run/ctlrun.sh <run>` starts a run with `DM_CTL`; `run/see.sh <shot> <wait> <presses…>` presses and takes a screenshot; `run/route.sh <prefix>` plays the route above from a fresh save (start the run with `SV=` set to an empty save folder).

## Found on this game

- The spin-wait search's store rule takes more loops here: `main` 87 → 94, and the movie library's thread loop in `subsdk0` is wider: [development.md, Power](../../../docs/development.md#power).
