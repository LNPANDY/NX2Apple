# Advance Wars 1+2: Re-Boot Camp (`0100300012F2A000`)

Base game 1.0.0 (v0), the only version, SDK 10.4.1 (The Great Ace Attorney Chronicles' `sdk` and movie module builds, [010036E00FB20000](../010036E00FB20000/README.md)). Unity 2020.2.1f3 IL2CPP on NVN; FMOD sound through `AudioOut`; Bink 2 movies (`.bk2`) decoded by Bink's Unity plugin in `main`; Pia / NEX for online play. Modules `main`, `subsdk0` (`NintendoSDK_movie`, which `main` imports from; the movies seen so far, the opening among them, are Bink's) and `sdk`. Plays on the iPhone (IPA 7.1 GB).

On the Mac: the boot, the Bink opening movie, the title, Nell's introduction, a new casual campaign and the first training battle (Field Training, Troop Orders); sound, about 2.5 GB resident and 1.6–1.9 GB of Metal allocations, level over 15 minutes with no red line.

## What it needs

| Setting | Where | Why |
|---|---|---|
| Node area cut 1 GB → 62 MB, and 2 MB alignment for regions of 4 MB and more (SDK 20's) | `dm/tools/sdk_patches.py` SDK-wide rules, `sdk` build `d9add76f…` | StandardAllocator's region (more than 1 GB) aborted in `nninitStartup`; see [Memory](#memory) |
| `sys_resource 0x1000000` | [`game.tsv`](game.tsv) | the NPDM declares 16 MB of system resource (virtual address memory) |
| 5 GB block with a 2 GB pool: `mem_reserve 0x140000000`, `mem_alias 0x118000000`, `mem_stack 0x10000000`, `app_pool 0x80000000` | `game.tsv` | Engage's 5 GB block (4.375 GB alias region). The heap check's 1 GB pool ran the game's malloc dry at the first loading screen |
| `pad_layout full` | `game.tsv` | the 3D gamepad layout: the map cursor moves with the D-pad |

## Frame rate

- 60 fps in the menus, 30 fps in battle by the game's own limit (present interval 1, the frame's work 33 ms with the CPU and GPU mostly idle).

## Memory

- The NPDM declares virtual address memory: `nninitStartup` (`main+0x365310`) hands pool − used to StandardAllocator as one address region and `main` sets no heap; Unity reserves its own regions beside it.
- **Resolved: `StandardAllocator::Initialize` aborted in `nninitStartup`** (`sdk+0x2edf90`, its `CentralHeap::Init` at `sdk+0x2ee060`; the heap check reported "the host stopped before nnMain"). The `sdk` build is The Great Ace Attorney Chronicles', which has no virtual address memory. Its AddressRegionManager constructor (`sdk+0x340e90`) loads the node area with `orr w8 / w9, wzr, #0x3fe00000` (`e8230b32` at `+0x340ea0`, `e9230b32` at `+0x340f3c`), the SDK 7 / 8 form, so the search for the `mov` form finds nothing there. `AllocateAddressRegion` (`sdk+0x341030`) aligns a region by its size (64 KB under 2 MB, 2 MB under 4 MB, 4 MB under 32 MB, 32 MB under 1 GB, else 1 GB, at `+0x34109c`), as DRAGON QUEST XI S's SDK 7.3.2 build, and the region is more than 1 GB. The cuts: both `orr` → `mov w8 / w9,#0x3e00000` (62 MB) and `orr w10,wzr,#0x40000000` → `mov w10,#0x2000000` at `+0x34109c` (32 MB, as from 32 MB up). Pikmin 4's SDK 10.4.8 build ([0100B7C00933A000](../0100B7C00933A000/README.md)) has the same cuts at the same offsets.
- **Resolved: then the frames stopped at the first loading screen, a graphics worker at 100% CPU** (17 s in, `UnityGfxDeviceWorker` running, the main thread waiting on a condition variable, no red line). The heap check had set a 1 GB pool (the hardware pool had used the alias region up to +4.25 GB within seconds), as for the other Unity games with virtual address memory, and that left the game's malloc too little: Unity's GPU memory pool block allocation (`main+0x96f430`) calls `aligned_alloc` through `main+0x866810`, halves the request after each failure, and once the request rounds to 0 calls on for ever with a size of 0. `sample <pid>` on the Mac host showed the spin (the guest frames are `???` in the host's image list; subtract the module base from the log's `base` lines); it worked here where lldb does not.
- **Current:** a 2 GB pool. Through 15 minutes of the title, the opening movie, the menus and the first training battle: 2.26 GB of the alias region mapped, its high-water mark +3.27 GB; the process holds about 2.5 GB on the Mac, 1.6–1.9 GB of it Metal allocations. The 1 GB of the heap check is a starting point, not a measurement ([dm/games/README.md, Adding a game](../README.md#adding-a-game)).

## Movies

- The opening and the other movies seen so far are Bink 2 (`.bk2`), decoded by Bink's Unity plugin in `main`. Their 32 shaders are loose in `main` ([Files and shaders](#files-and-shaders)); without them every movie drew white.

## Files and shaders

- Everything is in Addressables bundles under `Data/StreamingAssets/aa/Switch`, read as Engage's (`unityfs.py`). `romfs_marker` is `Data/StreamingAssets/music.bank`.
- 20,424 shaders, all of which build: 20,392 from the bundles and Unity's 11 GLSLC outputs in `main`, and Bink's 32 (2 vertex, 22 pixel, 8 compute).
- **Resolved: every movie drew white.** Bink's movie player builds its programs from 32 control sections and code areas in `main`'s read-only segment that are in no GLSLC output and no BNSH file. 26 are 0x20-byte records in two tables in `.data` (`{code area pointer, control section pointer, u32 code length, u32 control length}`, both pointers relative relocations). The code takes the other 6 by address (`adrp` + `add` to the control section and, a few instructions away, to the code area it copies with `memcpy`); the code area lies right after the control section's own length (+0x20, 16-byte aligned) or right before it, and two control sections share one code area. Both neighbours can pass the header and length checks, so the reader (`shader_split.py` `raw_shaders`) takes only a code area the code builds the address of, the nearest one to the control section's. The 8 compute shaders' code areas have no header (SDK 10). Without them the shaders were not in the map (two `[RED] shader … is not in the shader map` lines and `program has no vertex shader` as the opening movie starts). Of 25 `main`s on hand no other has such control sections.

## Input

- The 3D pad layout: the map cursor moves with the D-pad (the tutorial battle was played with it on the Mac).

## Packing

- A regional release of the same build (`0100300012FFF000`, issue #114) packs from a profile derived from this one, with the folder's title ID and `main.npdm`'s program ID (`same_build`, `game.py` `by_build`; [development.md, The packing script in detail](../../../docs/development.md#the-packing-script-in-detail)).

## Mac routes

- The work folder's `run/step.sh <shot> <wait> <presses…>` drives a run started with `DM_CTL`. About 22 s into a boot the opening movie plays: A skips it, `L+R~0.5` opens the main menu (the first time Nell's introduction, A about 25 times, then the file select); A (Campaign), A, A (Advance Wars, the file), A, A, A, A (the mission, Field Training, Troop Orders) start the first battle.

## Found on this game

- **Shader control sections loose in `main`** (`shader_split.py` `raw_shaders`): [Loose control sections and code areas in `main` (Bink 2)](../../../docs/reference/shaders.md#loose-control-sections-and-code-areas-in-main-bink-2).
- **`sdk` node-area and 1 GB alignment cuts in the `orr` form** of the SDK 7 / 8 constructor: [The SDK's address-region node area](../../../docs/reference/memory.md#the-sdks-address-region-node-area), [1 GB alignment of regions of 1 GB and more](../../../docs/reference/memory.md#1-gb-alignment-of-regions-of-1-gb-and-more).
- **The heap check's 1 GB pool is too small here**: [dm/games/README.md, Adding a game](../README.md#adding-a-game).
- The spin-wait search's store rule takes one wider loop in its `main`: [development.md, Power](../../../docs/development.md#power).
