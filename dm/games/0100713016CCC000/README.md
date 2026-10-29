# AI: THE SOMNIUM FILES - nirvanA Initiative (`0100713016CCC000`)

Update 1.0.2 (v131072), SDK 13.3.5. Unity 2020.3.30f1 IL2CPP (Patrick's Parabox's Unity, [0100E44016C22000](../0100E44016C22000/README.md)) with FMOD and Addressables bundles. Modules `main`, `subsdk0` (the movie module) and `sdk`. Plays on the Mac and on the iPhone; 60 fps (present interval 1). It needed no host change. The README lists its IPA at about 11.6 GB.

## What it needs

| Setting | Where | Why |
|---|---|---|
| Node area cut 1 GB → 62 MB | `dm/tools/sdk_patches.py`, `sdk` build `3644a676…` | `nninitStartup` hands pool − used to StandardAllocator as virtual address memory and Unity reserves its own regions beside it; see [Memory](#memory) |
| `sys_resource 0x1000000` | [`game.tsv`](game.tsv) | the NPDM declares 16 MB of system resource, so `IsVirtualAddressMemoryEnabled` is true |
| 5 GB block with a 1 GB pool: `mem_reserve 0x140000000`, `mem_alias 0x118000000`, `mem_stack 0x10000000`, `app_pool 0x40000000` | `game.tsv` | Ace Attorney Investigations Collection's layout ([010005501E68C000](../010005501E68C000/README.md)): 256 MB in front + 4.375 GB alias region + 256 MB stack region + 128 MB heap region. With the hardware pool the alias region was nearly full within 5 s |
| `pad_layout full` | `game.tsv` | the 3D gamepad layout: the investigation moves its cursor with the left stick and the view with the right one |

## Memory

- The NPDM declares 16 MB of system resource. `nninitStartup` (`main+0x493300`) hands application pool − used memory to StandardAllocator as virtual address memory (`StandardAllocator::Initialize(nullptr, pool − used)`) and never calls `SetMemoryHeapSize`, as Patrick's Parabox (the same Unity 2020.3.30f1).
- **Node area cut** on the `sdk` build `3644a6760469451cabc99f00c540acc2`: the AddressRegionManager constructor is at `sdk+0x37c130` (limit = alias start + 0x3fe00000 at +0x28, a unit heap of 0x30-byte nodes); the cut changes `mov w8,#0x3fe00000` → `mov w8,#0x3e00000` at `sdk+0x37c140` (the node area limit) and `mov w9` the same at `sdk+0x37c1dc` (its length registered as an occupied region), 62 MB. The same build's region alignment cuts (4 MB, 32 MB and 1 GB classes → 2 MB) came with Pokémon Scarlet and Subnautica: Below Zero ([010014C011146000](../010014C011146000/README.md)).
- **Pool:** with the hardware pool (3.2 GB), StandardAllocator's 1 GB-aligned region and Unity's own regions used the alias region up to +4.26 GB of 4.38 in the first 5 s (the NSP script's heap check). So the profile has a 1 GB pool; the heap check now sets that for such a game (`profile_guess.py` `heap_signals`: the alias region nearly full within seconds and no heap; [dm/games/README.md, Adding a game](../README.md#adding-a-game)).
- **Measured on the Mac** over 15 minutes from boot through a new game into the first investigation (probes on `VammManager::AllocateAddressRegion`'s success path `sdk+0x37c2a0` and `FreeAddressRegion` `sdk+0x37caf8`, commits from the `DM_SVC` map log): StandardAllocator takes 960 MB at +64 MB and commits 0.29 GB of it; Unity's allocator (`main+0x484024`) holds about 1.10 GB in 170 regions (16.25 MB and 2.25 MB blocks, created and freed as scenes load), 1.03 GB of it mapped; 2.1 GB of regions live in all, 1.26 GB mapped, 1.96 GB resident.
- The highest region end climbs (+3.77 GB after 7 minutes) while the live total stays flat: the SDK places each region at the bottom of the highest gap that fits (`sdk+0x37c2d0` walks the gaps from the top down), so new regions go above the highest live one until the top is used, and only then into the holes below.

## Movies

- `subsdk0` is the movie module; the game's movies play through Unity's video player (960x540 NV12 frames).

## Rendering

- Docked, the game draws 1280x720 by its own choice and crops the 1920x1080 window to it. It presents at interval 1 (60 fps).

## Files and shaders

- The shaders are Shader objects in the Addressables bundles of `StreamingAssets/aa` (they carry type trees) and in `Data/Resources`, and 147 ComputeShader kernels, which Unity 2020.3 keys by keyword set (`shader_split.py` `unity_compute`, `variantMap`).
- 6 geometry shaders (a wireframe effect, Unity's VR blit) do not build (`game.tsv`).
- `romfs_marker` is `Data/StreamingAssets/aa/settings.json`.

## Input

- Controller only, docked, with the 3D pad layout (the investigation's view is on the right stick).

## Found on this game

- **ComputeShader variants keyed by keyword set** in Unity 2020.3 (`shader_split.py` `unity_compute`, `variantMap`).
- **The heap check's 1 GB pool rule** for a game whose alias region is nearly full within seconds and that sets no heap (`profile_guess.py` `heap_signals`): [dm/games/README.md, Adding a game](../README.md#adding-a-game).

## Open

- The 6 geometry shaders are listed as not building in `game.tsv`; no source says whether the geometry compute path that now builds AI: THE SOMNIUM FILES' three ([010089B00D09C000](../010089B00D09C000/README.md)) builds these.
- The game has no entry in the development notes; its route on the Mac (a new game into the first investigation) is known only from `game.tsv`'s memory comment.
