# 13 Sentinels: Aegis Rim (`01003FC01670C000`)

Update 1.10 (v65536) over the base game, SDK 11.4.3. Vanillaware's own engine on NVN. Modules `main`, `subsdk0` (NintendoSDK_movie 11.4.3) and `sdk`; `sdk` and `subsdk0` are byte-identical to Metroid Dread's ([010093801237C000](../010093801237C000/README.md)). Playable on the iPhone; on the Mac a new game gets through the prologue into the first battle.

The Asian release (Japanese, Korean, Chinese) has its own title ID and `main` build, and its own profile: [01008D7016438000](../01008D7016438000/README.md). The Japanese eShop release (Japanese only) has its own title ID, SDK (10.8.2) and builds of every module, and its own profile: [010045C014650000](../010045C014650000/README.md).

## What it needs

| Setting | Where | Why |
|---|---|---|
| `alloc_big_align on` | [`game.tsv`](game.tsv) | the engine cuts ring heaps out of a memory pool at 64 KB GPU alignment, and the pool's storage comes from malloc: without 64 KB-aligned large allocations the third ring heap keeps base 0 and the prologue's first battle writes through a null pointer; see [Memory](#memory) |
| 4 GB layout: `mem_reserve 0x100000000`, `mem_alias 0x10000000`, `mem_stack 0x10000000`, `app_pool 0xCD500000` | `game.tsv` | 256 MB in front + 256 MB alias region + 256 MB stack region + 3.25 GB heap region. No system resource: the game sets a heap |
| `depth_mode zero` | `game.tsv` | the game sets the near = 0 depth mode, so the pipeline bases made before it runs (the NSP script's Mac prebuild, and a [pipeline archive made offline](../../../docs/development.md#the-pipeline-archive-made-offline) for the iPhone when one is built with `DM_PSO_GPUS`) take its vertex shaders' `main0_z` entries (the host itself follows the mode the game sets) |

No `patches.py`, no `sdk_patches.py` cut for its `sdk` build (`2d369d99…`), no `pad_layout` (the iPhone pad starts in the 2D layout).

## Memory

- The NPDM declares no system resource (META +0x14 = 0): the game uses `SetHeapSize`. `main`'s bss is only about 21 MB. Measured with `DM_SVC=1`: the heap request is pool − used = `0xc9400000` (3.14 GB); the alias region gets one page during SDK initialization; thread stacks go into the stack region through `MapMemory`. On the Mac about 2.2 GB is resident in the first battle.
- **Resolved: a null write as soon as the main thread starts recording a command buffer.** A constructor at `main+0x2fa9a0` ran on `this = 0` when the prologue entered its first battle. The object came from one of the engine's ring heaps (`main+0x2d83ec`), and that heap had base 0. At startup the engine takes one GPU memory pool, sized as exactly the sum of three ring heaps, and cuts the heaps out at 64 KB alignment relative to the pool's GPU address (`main+0x30c118`). On the Switch a pool's GPU address is big-page aligned; the host's GPU address is the CPU address, and the storage came from the game's `malloc` (`nn::mem::StandardAllocator::Allocate(size)`) rounded only to 4 KB. Up to 60 KB was lost at the front, the third heap (16 MB) did not fit, and the sub-allocator returned 0. Probing the heap object at the allocation (`DM_PROBE=main:2bec60@x0+8`) showed the zero base directly. **Current:** `alloc_big_align` routes allocations of 64 KB or more to `Allocate(size, 0x10000)` (`hle_os.c`).

## Services

- **Resolved:** SDK 11 calls that reach a service: `hid::GetMouseState` (the first boot aborted in it: the SDK's mouse resource was never initialized), `fs::CleanDirectoryRecursively`, `fs::EnableGlobalFileDataCache`, `oe::SetUserInactivityDetectionTimeExtendedUnsafe`, `time::ToPosixTime` (host `mktime`) and `audio::GetAudioOutName` ([Mouse, keyboard and key code maps](../../../docs/reference/services.md#mouse-keyboard-and-key-code-maps), [Directory, file data cache and save-thumbnail calls](../../../docs/reference/services.md#directory-file-data-cache-and-save-thumbnail-calls), [oe calls answered without an applet proxy](../../../docs/reference/services.md#oe-calls-answered-without-an-applet-proxy), [Time zone rules, calendar conversion and the network clock](../../../docs/reference/services.md#time-zone-rules-calendar-conversion-and-the-network-clock), [Audio device output volume and names](../../../docs/reference/audio.md#audio-device-output-volume-and-names)).

## Files and shaders

- Everything is in six CRI CPK archives (`ROBO_*.CPK`, 4.3 GB; `ROBO_US.CPK` is the profile's `romfs_marker`) that CRI File System opens through `nn::fs`; they hold textures, scripts, CRI ADX2 audio (acb / awb) and CRI USM movies. The host needs nothing but plain file access for them.
- To look inside one: the header and TOC are `@UTF` tables (big-endian columns), masked with CRI's byte stream (`m = 0x655f`, then `m *= 0x4115` per byte); file offsets in the TOC are relative to the smaller of `TocOffset` and `ContentOffset`, and files whose `ExtractSize` differs from `FileSize` are CRILAYLA-compressed. The listing showed no shader container, which is how the shaders were found in `main` instead ([02, Data containers](../../../docs/agents/02-survey.md#data-containers-that-matter-to-the-host)).
- Shaders: no shader file in RomFS. 838 GLSLC compiler outputs (magic `0x19866891`) sit in `main`'s read-only segment, each referenced from a `{pointer, size, 0}` table in `.data` (`shader_split.py` `glslc_shaders`). Each output holds one control section with the code area right after it; a debug section with the NV assembly and the GLSL source follows. The control sections are all at least 0x880 bytes.

## Rendering

- **Synchronization menu smoke check (2026-10-26, Mac M4 Pro):** #158 and #213 with review fixes and current `8393d85a4eae` Mac libraries. Isolated copies of the existing save ran 50 s with fast wake/pass optimizations/deferred encoding (2,853 frames) and with all three optimizations disabled/direct encoding (2,968 frames), without a red line or crash. The wait ledger records one samples-passed report and one timestamp report per frame in both modes. Screenshots show the audio-language selection menu; a 65 s extended route still stopped there (3,864 frames). This validates that menu and its report traffic, not battle/gameplay or a performance gain; neither pass optimization activated. Logs, copied saves and shots are in the NSP work folder's `run/perf-order-on/`, `perf-order-off/` and `perf-scene-on/`. See the general [SyncWait completion](../../../docs/reference/nvn-objects.md#the-games-syncwait-wakes-on-the-gpus-own-signal-of-its-fence), [slice merging](../../../docs/reference/rendering.md#passes-into-other-layers-of-one-texture-level-run-as-one-layered-pass) and [compute hoisting](../../../docs/reference/rendering.md#compute-dispatches-between-the-draws-of-a-pass-run-ahead-of-it) entries. iOS runtime validation remains open.
- **Single-stage programs:** the game builds one NVN program per GLSLC output (838 `ProgramSetShaders` at startup) and combines vertex and pixel programs per draw with `BindProgram` stage bits, so the real pairs exist only at draw time. Every pixel shader input is a plain `float4` at locations 1–9 (the SPH input map, words 6–13, matches the translated MSL inputs for all 375 pixel shaders), so the cover that pairs every vertex shader here is one pixel shader.
- Depth mode: the game sets near = 0 (`nvnDeviceSetDepthMode`), as Link's Awakening and Engage do.
- **Resolved: an assertion a minute and a half into the prologue,** `buffer index (31) must be < 31`: the game binds vertex streams 14 and 15, and the host bound NVN stream *n* to Metal vertex buffer 16 + *n*.
- Every texture is created with `TextureBuilderSetPackagedTextureData`. **Current:** the host copies that data at `TextureInitialize` and uploads it like a packaged texture; the linear ones (the save thumbnails) are excluded and, in a CPU-visible pool, read straight from the pool buffer.
- Attachment loads and stores per frame on the Mac went down about 15% once an inline uniform update inside a render pass stopped ending the pass ([development.md, Power](../../../docs/development.md#power)).

## Cheats

- **A community list is for 1.10** (`4B632573CA5C160E`): a Ryujinx list with invincible, one-hit kill, EP never decreases, plus an entry that installs the code the first two use.
  - Its four `BD405800` (`ldr s0, [x0, #0x58]`) sites are 1.10's. In the base game 1.00 (main `57212E16CB83BB55`) the same functions lie 0x330 lower.
  - Its code cave is the padding before the read-only data, `main+0x451FC4` = the read-only data − 0x3C in both builds. The cave's first two words are the #01 / #02 flags.
  - A `BL` at `main+0x8F0EC` (1.10), in place of `0ABB7F75`, enters the cave.
- **Compiled for 1.00** by `scripts/cheat_anchor.py` ([Cheats carried across game updates](../../../docs/reference/rewriter.md#cheats-carried-across-game-updates)): the EP sites by fingerprint, the hook by body digest (`main+0x8EDBC`), the `BL` re-encoded. Not tried in play.

## Found on this game

General host changes first needed here; each applies to every game:

- **Synchronization review menu check:** [Rendering](#rendering) records the #158/#213 comparison, samples-passed/timestamp traffic and its limits; the general fixes and synthetic regressions are linked there.
- **64 KB-aligned large allocations** (`alloc_big_align`, `hle_os.c`; shared with Unicorn Overlord, [010069401ADB8000](../010069401ADB8000/README.md)): [Ring heaps cut from a pool at 64 KB alignment](../../../docs/reference/memory.md#ring-heaps-cut-from-a-pool-at-64-kb-alignment) and [the profile keys](../README.md#keys).
- **GLSLC outputs in `main`** (`shader_split.py` `glslc_shaders`, the control / code / length check): [GLSLC outputs in `main` and in loose files](../../../docs/reference/shaders.md#glslc-outputs-in-main-and-in-loose-files).
- **Single-stage programs paired with a cover** (`vs_pad`), **a shader cache key that covers the pairs** (`shader_key`, `pair_keyed`), **triangle fans and indexed quads** (a shared fan index buffer; CPU expansion at replay in `nvn_mtl.m`), **vertex streams 14 and 15 at slots 14 and 15** (`VB_SLOT`) and **packaged texture data copied at `TextureInitialize`**: [Single-stage programs paired with a cover](../../../docs/reference/shaders.md#single-stage-programs-paired-with-a-cover), [Shader cache key covering the pairs](../../../docs/reference/shaders.md#shader-cache-key-covering-the-pairs), [Triangle fans and indexed quads](../../../docs/reference/rendering.md#triangle-fans-and-indexed-quads), [Vertex streams 14 and 15 at Metal slots 14 and 15](../../../docs/reference/rendering.md#vertex-streams-14-and-15-at-metal-slots-14-and-15), [Packaged texture data copied at `TextureInitialize`](../../../docs/reference/nvn-objects.md#packaged-texture-data-copied-at-textureinitialize).
- **Finding service calls before the first boot** (`main`'s `nn::` imports filtered against `HLE_FORCE` names): [Listing a game's unhooked imports before they are met](../../../docs/reference/services.md#listing-a-games-unhooked-imports-before-they-are-met).
- **Cheats carried across game updates** (`scripts/cheat_anchor.py`): [rewriter reference](../../../docs/reference/rewriter.md#cheats-carried-across-game-updates).

## Open

- Cheats: the community list's install entry writes 0 to both the #01 / #02 flags on every pass, after those two in file order, so with it on the flags read 0 at the end of each pass. Check in play whether it must be turned off once its code is in.
- `game.tsv` still describes the game as "In bring-up" (the Mac reaching the first battle), while AGENTS.md lists it as playable on the iPhone.
- `game.tsv`: only the merged 1.10 copy is extracted; the base game's own build IDs are added when needed.
