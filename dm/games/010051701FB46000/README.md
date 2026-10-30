# Monster Train 2 (`010051701FB46000`)

Update 1.1.1 (v131072) over the base game, SDK 18.3.5. Unity 2022.3.54f1 IL2CPP with FMOD on NVN. Modules `main`, `subsdk0` (the movie module, whose `movie::Extractor` demuxes the intro) and `sdk`; the `sdk` is Super Mario Galaxy's build ([010099C022B96000](../010099C022B96000/README.md)). Plays on the iPhone; 60 fps (30 on the Switch). On the Mac: the title, the 90 s intro movie with its sound, the tutorial battle (deployment, three waves, enemies on two floors), the merchant and the route map, at 60 fps with music and saves (the intro plays once per save); no red line, about 2.17 GB resident and 1.21 GB of Metal allocations, flat over twelve minutes.

## What it needs

| Setting | Where | Why |
|---|---|---|
| `present_interval display` | [`game.tsv`](game.tsv) | 60 fps: the game asks for interval 2 and its animations follow the time that passed; see [Frame rate](#frame-rate) |
| `pad_layout full` | `game.tsv` | the 3D layout, whose right stick scrolls the route map as the game's prompt shows |
| `sys_resource 0x1000000` | `game.tsv` | the NPDM's 16 MB of system resource: virtual address memory |
| 5 GB guest layout: `mem_reserve 0x140000000`, `mem_alias 0x118000000`, `mem_stack 0x10000000`, `app_pool 0x40000000` | `game.tsv` | Ace Attorney Investigations Collection's layout ([010005501E68C000](../010005501E68C000/README.md)): with the hardware pool (3.2 GB) StandardAllocator's region alone reached +3.9 GB of the 4.38 GB alias region in `nninitStartup`; see [Memory](#memory) |
| Node area cut 1 GB → 62 MB and regions of 4 MB and more aligned to 2 MB, as SDK 20 | `dm/tools/sdk_patches.py`, the SDK-wide rules (`MATCH_CUTS`) on `sdk` build `60751516…` (Super Mario Galaxy's and Galaxy 2's; the constructor at `sdk+0x13be3c`, the movs at `+0x13be4c` and `+0x13bee0`, the placement's constants at `sdk+0x13c034` / `+0x13c03c` / `+0x13c040`) | the 0.94 GB region sits at alias +0.06 GB either way; the build's row (the node area cut alone) was removed on 2026-10-30 after a smoke run with the rules |
| `svcGetInfo` type 24 (FreeThreadCount) | host, `hle_svc.c` / `thr_limit_used` (every game) | Unity creates a thread only when the count is at least 1; see [Threads](#threads) |
| Movie audio decoder output slots | host, `hle_movie.c` (every game) | the intro hung on a black screen; see [Movies](#movies) |
| `shader_groups /Data/=data` | `game.tsv` | everything is under `Data/`: the player's serialized files (the post-processing compute shaders in `sharedassets2.assets`) and the `StreamingAssets` bundles |

## Frame rate

- **Current:** 60 fps (30 on the Switch). The game asks for present interval 2 (Unity's 30 fps setting) and nothing else holds it at 30: `present_interval display` presents a frame every display tick, and the iPhone's display link runs at 60 Hz. The GPU takes about 2 ms a frame in battle and on the route map (M4 Pro).
- Its animations follow the time that passed (Unity's `deltaTime`; the PC versions run at any refresh rate). From one save, screenshots every third of a second through the move to the merchant (its fade-in, the greeting) match at 30 and 60 fps: mean difference 3.9, against 11.0 (up to 89 in the fade) for what frame counting would show.
- `DM_PRESENT_INTERVAL=game` (`Documents/env.txt` on the iPhone) keeps 30 and saves power.
- **Resolved: `[RED] fs ReadFile into … failed at +0 (EFAULT): VM region … protection 1`, now and then at 60 fps** (two runs in three as the route map loads, never at 30 fps). The destination was texture pool memory, which the dirty-page tracker write-protects after each upload (`nvn_dirty.c`); `ReadFile` lifts the protection first, but the graphics layer can protect the pages again before `pread` writes them, and at 60 fps uploads come twice as often. On EFAULT the host now prepares the rest of the buffer again and reads on, up to eight times (`h_fs_ReadFile`; the first case is logged, `[fs] ReadFile … prepared again`). Four runs at 60 fps: one retry, no failed read.

## Memory

- The NPDM declares 16 MB of system resource, so `IsVirtualAddressMemoryEnabled` is true: `nninitStartup` hands application pool − used memory to StandardAllocator as virtual address memory and never calls `SetMemoryHeapSize` (no heap), as in Ace Attorney Investigations Collection, Brain Memory Training Academy and Patrick's Parabox. The node-area cut was already on this `sdk` build.
- With the hardware pool (3.2 GB), StandardAllocator's region alone took the alias region to +3.9 GB of 4.38 GB in `nninitStartup`; hence their 1 GB pool and 5 GB block (256 MB in front + 4.375 GB alias region + 256 MB stack region + 128 MB heap region).
- Measured on the Mac: the alias region is mapped up to +3.25 GB within 90 s and stays there for 12 minutes (+3.5 GB in a run to the first shop), at most 1.75 GB of it in use. The host does not hold the game to the pool, as for Ace Attorney.

## Threads

- **Resolved: the main thread waited forever on an event right after `nnMain` started, with only three or four threads created.** `main+0x3e7288` starts a thread and waits for it to signal `main+0x539cf80`. Unity's thread start (`main+0x3e1a50`) creates a thread only when `nn::os::GetFreeThreadCount()` is at least 1, and that is `svcGetInfo` type 24 (FreeThreadCount, Horizon 11 and later), which the host answered 0 like every type it did not know: the thread was never asked for (`DM_THR=1` showed no `CreateThread` for it). The host now answers 96 less the game's threads that have not exited (`thr_limit_used`). Of the 20 games extracted on that machine, only this `main` imports the function. With it the game creates 40 threads and reaches its title.

## Movies

- The intro is `StreamingAssets/intro_fmv.mp4`, 90 s of H.264 High with 2 reorder frames and AAC interleaved packet by packet, played by Unity 2022.3's movie player: `movie::Extractor` in `subsdk0` feeds both decoders from one thread in file order. The game's A, B and + do not skip it.
- **Resolved: the movie stayed black after its first picture, the sound never started, and the game kept presenting frames.** The player takes every output a decoder offers and starts playing only once it holds about half a second of audio. The host then gave each decoder 8 output slots and takes input only while one is free (as MediaCodec does). `DM_MOVIE_TRACE=1` (each line names the decoder): Unity held all 8 audio outputs, the audio decoder kept the next 4 packets and handed out no input index, the video packets behind them in the file never came, and the video decoder had given out one picture (the host releases H.264 pictures once more than 4 are queued). Slot counts per decoder kind, measured: 8 audio / 8 video and 8 audio / 32 video hang; 64 audio / 8 video plays, starting with 27 audio and 8 video outputs held (peak 30 audio). Audio decoders then got 64 slots (they had 8 when the game was brought up, 32 since DRAGON QUEST XI S).
- **Current:** an AAC decoder has 32 output slots (`MD_NOUT_AAC`, set for Mario vs. Donkey Kong ([0100B99019412000](../0100B99019412000/README.md)), with this game's peak of 30 held as the reason it is enough), Vorbis 64 (`MD_NOUT`), video 16 (`MD_NOUT_VIDEO`). A PCM slot is 128 KB, allocated when first used.

## Services

- `nvnSyncSetDebugLabel` (a no-op).

## Input

- Controller only: the game reads no touch, docked or handheld (taps on the title and on route map nodes in handheld mode did nothing). It stays docked at 1920x1080 with the 3D pad layout, whose right stick scrolls the route map. A selects and plays cards, B goes back, Y ends the turn.

## Files and shaders

- 15,937 shaders: 15,841 vertex, pixel and geometry shaders in the player's serialized files and bundles, the player's 11 GLSLC outputs in `main` (one of them compute), and 85 kernels of the post-processing stack's `ComputeShader` objects in `Data/sharedassets2.assets`. The `Shader` objects use the Unity 2022.3 layout already in `unityfs.py`. The built-in VR blit's geometry shader does not build.
- **Resolved: the 3D battle scene was black behind a correct UI**, with `[RED] shader 854a8afc9d07f88d is not in the shader map` and `the dispatched program has no compute shader`. `DM_NVN_SHDUMP` saved the program; its code bytes were in `Data/sharedassets2.assets`, uncompressed, inside a `ComputeShader` (class 72): the post-processing stack's colour grading LUT baker (`Lut3DBaker#KGenLut3D_AcesTonemap`), so the LUT the scene is graded through was never baked and stayed black. The split read only `Shader` objects. A `ComputeShader` holds per platform variant a list of kernels, each with its unique variants; a variant's `code` is the program code of a `Shader` subprogram (the 0x60-byte stage header, only the compute block present) and its `threadGroupSize` matches control +0x748. `unity_compute` in `shader_split.py` reads them beside the `Shader` objects of every serialized file. No file carries a class 72 type tree, so `unityfs.py` carries Unity 2022.3.54f1's layout (`COMPUTE_2022_3` in `KNOWN_TREES`, written from AssetRipper's TypeTreeDumps for that version): all 12 objects decode, `resourcesResolved` true at each end. 85 compute shaders came in (86 with the player's own).

## Saves

- The intro plays once per save. A save past the intro starts at the title, and A there continues the run.

## Mac routes

- From a fresh save, `DM_KEYS="14:A"` starts the game; the intro movie plays to its end and the tutorial battle loads at about frame 3,400.
- `DM_KEYS="14:A,110:A*90/2,111:Y*20/9"` plays through the tutorial battle to the merchant by about frame 8,000.

## Found on this game

General host changes first needed here; each applies to every game:

- **`svcGetInfo` type 24, FreeThreadCount** (`thr_limit_used`): [Free thread count (`svcGetInfo` type 24)](../../../docs/reference/threads.md#free-thread-count-svcgetinfo-type-24).
- **Movie decoder output slots per decoder kind** (`MD_NOUT`, `MD_NOUT_AAC`, `MD_NOUT_VIDEO`): [Output slot counts per decoder kind](../../../docs/reference/movies.md#output-slot-counts-per-decoder-kind), [Audio output slots for players that hold every output](../../../docs/reference/movies.md#audio-output-slots-for-players-that-hold-every-output).
- **`nvnSyncSetDebugLabel`** as a no-op (no other source describes it).
- **`ReadFile` re-prepared on EFAULT** against the dirty-page tracker (`h_fs_ReadFile`): [ReadFile into write-protected texture pool pages](../../../docs/reference/services.md#readfile-into-write-protected-texture-pool-pages).
- **Unity `ComputeShader` objects** (`unity_compute`, `COMPUTE_2022_3`): [Unity ComputeShader objects](../../../docs/reference/shaders.md#unity-computeshader-objects).
- **`present_interval display`** for a game that steps by frame time: [dm/games/README.md, Keys](../README.md#keys).
- The spin-wait search takes the movie library's thread loop wider in this game's `subsdk0`: [development.md, Power](../../../docs/development.md#power).

## Open

- docs/development.md says audio decoders have 64 output slots and the 03 entry says video keeps 8; the host now has 32 for AAC (`MD_NOUT_AAC`) and 16 for video (`MD_NOUT_VIDEO`). No source says the intro was played again after those changes.
- The built-in VR blit's geometry shader does not build.
