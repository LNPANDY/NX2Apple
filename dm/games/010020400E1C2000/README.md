# Raging Loop (`010020400E1C2000`)

Base game 1.0.0 (v0), SDK 7.3.2. Unity 2018.3.10f1 IL2CPP with FMOD on NVN. Modules `main`, `subsdk0` (the movie module, which plays `StreamingAssets/Movies/*.mp4`, H.264 Main and AAC) and `sdk`; `sdk` and `subsdk0` are DRAGON QUEST XI S's builds ([01006C300E9F0000](../01006C300E9F0000/README.md)), so that build's cuts apply as they are. No host change was needed. Playable on an iPhone (see [Open](#open)). On the Mac: the publisher logo, the opening movie with its sound, the title, options, a new game through the tutorial and the prologue (the date card, the opening pictures, choices, the in-game menu, scenario chart and log), at 60 fps as on the Switch (the game asks for present interval 1), with saves; no red line at run time.

## What it needs

| Setting | Where | Why |
|---|---|---|
| DRAGON QUEST XI S's `sdk` cuts: node area 1 GB → 62 MB, regions of 4 MB and more aligned to 2 MB (SDK 20's) | `dm/tools/sdk_patches.py` SDK-wide rules, `sdk` build `fcf93a41…` (the constructor at `sdk+0x32c450`, cuts at `+0x32c460` and `+0x32c500`; `AllocateAddressRegion`'s alignments at `+0x32c664`, `+0x32c66c`, `+0x32c670`) | they put StandardAllocator's region 64 MB into the alias region; see [Memory](#memory) |
| `sys_resource 0x1000000` | [`game.tsv`](game.tsv) | the NPDM's 16 MB of system resource: virtual address memory |
| 5 GB guest layout with the hardware pool: `mem_reserve 0x140000000`, `mem_alias 0x118000000`, `mem_stack 0x10000000`, `app_pool 0xCD500000` | `game.tsv` | Engage's block (256 MB in front + 4.375 GB alias region + 256 MB stack region + 128 MB heap region); Unity 2018.3 maps only inside StandardAllocator's region, so the pool stays as on the Switch |
| `shader_groups /Data/=data` | `game.tsv` | |
| No `pad_layout` (the 2D default) | `game.tsv` | controller only; see [Input](#input) |

## Memory

- The NPDM declares 16 MB of system resource, so `IsVirtualAddressMemoryEnabled` is true: `nninitStartup` hands application pool − used memory to StandardAllocator as virtual address memory, one address region in the alias region, and the game never calls `SetMemoryHeapSize` (no heap).
- Unlike Unity 2020 and 2022 (Ace Attorney Investigations Collection, Monster Train 2: a 1 GB pool), Unity 2018.3 reserves no address regions of its own: every page the game maps lies in StandardAllocator's region, which ends at +3.21 GB of the 4.38 GB alias region. So the hardware pool (3.2 GB) leaves no address space short, and only mapped pages cost memory: 377 MB mapped at the peak over the title, the tutorial and the opening (Mac, `DM_SVC` map log). The NSP script's heap check keeps the hardware pool for this game for the same reason ([dm/games/README.md, Adding a game](../README.md#adding-a-game)).
- On the Mac about 0.6 GB resident at the title and 0.77 GB after ten minutes of story (it grows with each new picture and slows down), 0.4 GB of Metal allocations.

## Input

- Controller only: the game reads no touch, docked or handheld (a handheld run with taps on the title's READ logged no touch read). It stays docked at 1920x1080 with the 2D pad layout. Menus answer the left stick as well as the D-pad, and no menu item is selected until a direction is pressed. A advances and selects, B goes back, X opens the menu, Y the scenario chart, L the log, R auto mode.

## Files and shaders

- The story's pictures are loose PNG / JPG files in `StreamingAssets` that the game loads itself.
- 452 shaders: the 48 `Shader` objects of the player's serialized files (`Data/*.assets`, the Unity built-ins in `Data/Resources`; 450 subprograms) and the player's 4 GLSLC outputs in `main`.
- **Resolved: the split stopped with "no bundle has a Shader type tree of the same hash to borrow"** (hash `8db76007…`). There are no bundles, and no game of that Unity version with a bundle was at hand, so `SHADER_2018_3` in `unityfs.py`'s `KNOWN_TREES` is written from AssetRipper's TypeTreeDumps (`StructsDump/release/2018.3.10f1.dump`), checked node for node against the dump (1,325 nodes, the alignment flags included). It is a layout of its own, older than the common structs: no conservative raster state, `BufferBinding` without `m_ArraySize`, `ConstantBuffer` without `m_IsPartialCB`, the parameters in each subprogram and no `m_CommonParameters`, one segment per platform (the pre-2019.3 form Cuphead's trees gave `shader_programs`). Each of the 48 objects reads to its exact end: 450 subprograms of version 201802150 (older than the local keyword list, which starts at 201806140).
- The two built-in `ComputeShader` objects in `unity default resources` stay unread (a `[RED]` line in the split): their 2018 layout lists kernels with no unique variants. The game dispatches no compute.
- To take one file out of an NSP without extracting the RomFS, filter `nx_extract`'s `Copy` by path.
- **Direct-image validation (2026-10-27):** the merged base writes a `RomFS.img` with 1,473 resource files (919,413,381 file-data bytes), no RomFS directory. Every image path, size and first 32 bytes matches an independent LibHac manifest. The image scan retains all 452 registered shader rows unchanged and adds 15 compute shaders from `unity default resources` supported by the current parser; the registered profile's older map/facts therefore stop the full build at table validation. The profile was not changed for this storage work.
- **Direct-image runtime checked:** the current host with the registered 452-shader package rebuilt for chain `157e1b96c8da` ran 4,200 frames (about 70 seconds) through the opening and tutorial, reading the image in place. The log records the image mount (1,518 entries), 143 filesystem opens and no `[RED]` lines; the frame-3,600 screenshot shows the tutorial choices. Evidence stays in `<NSP folder>/010020400E1C2000-work/direct-romfs-run/`. This checks populated-image gameplay; it is not a timing comparison against folder storage.

## Mac routes

- From a fresh save, `DM_KEYS="f700:A,f900:LLeft,f1000:LLeft,f1100:LLeft,f1200:A,f1500:A*14/120,f3300:LDown*5/60,f3640:A,f3900:A*35/120"` skips the opening movie, starts READ, reads through the tutorial, picks "I'm good (to main story)" and reads into the prologue (the motorbike picture at about frame 6,600).

## Found on this game

- **Direct extraction and scanning of a RomFS image:** [RomFS image build pipeline](../../../docs/reference/packing.md#building-creates-a-full-romfs-tree-before-packing-its-image).

- **Unity 2018.3's `Shader` layout written out** (`SHADER_2018_3`, from AssetRipper's TypeTreeDumps): [Unity Shader layouts written out for players without bundles](../../../docs/reference/shaders.md#unity-shader-layouts-written-out-for-players-without-bundles).
- **The heap check keeps the hardware pool** for a Unity 2018.3 game that maps only inside StandardAllocator's region: [dm/games/README.md, Adding a game](../README.md#adding-a-game).

## Open

- Status disagrees: the `game.tsv` header says "Plays on the Mac", docs/development.md says playable on an iPhone.
