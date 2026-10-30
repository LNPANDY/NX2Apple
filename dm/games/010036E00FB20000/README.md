# The Great Ace Attorney Chronicles (`010036E00FB20000`)

Base game 1.0.0 (v0), with its DLC `010036E00FB21001`. SDK 10.4.1. Capcom's MT Framework on NVN. Modules `main`, `subsdk0` (the SDK's movie module, NintendoSDK_movie, whose extractor runs natively while the host decodes the H.264 movies with VideoToolbox) and `sdk`; `subsdk0` and `sdk` are the same builds as Advance Wars 1+2: Re-Boot Camp's ([0100300012F2A000](../0100300012F2A000/README.md)). Plays on the iPhone; 30 fps, as the game paces itself.

## What it needs

| Setting | Where | Why |
|---|---|---|
| `tex_flush_upload on`, `tex_dirty_upload on` | [`game.tsv`](game.tsv) | the CPU copies every texture into a CPU-cached pool after creating it and never flushes; with `tex_flush_upload` alone the screen stayed black. See [Rendering](#rendering) |
| 4 GB layout: `mem_reserve 0x100000000`, `mem_alias 0x10000000`, `mem_stack 0x10000000`, `app_pool 0xCD500000` | `game.tsv` | the NPDM declares no system resource (META +0x14 = 0): `nninitStartup` sets a heap of the pool − 64 MB (3.14 GB); `main`'s bss is 9.2 MB |
| Node area cut 1 GB → 62 MB, 4 MB / 32 MB / 1 GB alignment → 2 MB (SDK 20's) | `dm/tools/sdk_patches.py` SDK-wide rules, `sdk` build `d9add76f…` | the SDK-wide rules' cuts; made for Advance Wars 1+2: Re-Boot Camp, which shares the build. This game has no virtual address memory and never makes an address region |
| `pad_layout` not set (the default `simple`, 2D) | `game.tsv` | the gamepad starts in the 2D layout (the player-facing README lists it among the games that do) |
| `depth_mode zero` | `game.tsv` | the game sets the near = 0 depth mode, so the pipeline bases made before it runs (the NSP script's Mac prebuild, and a [pipeline archive made offline](../../../docs/development.md#the-pipeline-archive-made-offline) for the iPhone when one is built with `DM_PSO_GPUS`) take its vertex shaders' `main0_z` entries (the host itself follows the mode the game sets) |

## Rendering

- Upper-left window origin, depth mode near = 0, a 1920x1080 RGBA8 swapchain; the game asks for present interval 1 and paces itself at 30 fps. Mario's binding layout (combined textures at `0x20 + 8 × slot`, slots 0–2).
- **Resolved: black screen at boot, with the draws of a dialog box in the pass dump** (sampling 256x256 and 1024x256 textures of format 0x4d). No texture had been uploaded from guest memory (`packaged textures: first uploads 0`), and `DM_NVN_TEXINFO=1024x256` showed storage that already held data at first use (226,555 of 262,144 bytes non-zero): no packaged layout, block-linear, in a 1000 MB `CPU_CACHED | GPU_CACHED | COMPRESSIBLE` pool (flags 0xa4). A log of the pool flushes, texture creations and file reads (temporary lines under `DM_NVN_LOG`) showed how they are filled: every `.tex` is read into staging buffers (512 KB `ReadFile`s, none into the pool), and the CPU copies the texels into the texture's storage after `nvnTextureInitialize`, with no `nvnMemoryPoolFlushMappedRange` over them and no `WriteTexels`; only the four linear 1024x64 text textures are flushed, every frame. `main` has no cache maintenance instruction at all, so there is no flush for the host to take as the signal. With `tex_dirty_upload` a registered texture whose pages the CPU writes after creation is uploaded at its first use (as for FINAL FANTASY TACTICS - The Ivalice Chronicles, [010038B015560000](../010038B015560000/README.md)).
- **Resolved: court-record pictures black, or showing the previous item** (reported on the Japanese release, `0100D7F00FB1A000`, GitHub issue #568). Some BC1 images are written into their storage *before* `nvnTextureInitialize`, which `tex_dirty_upload` does not see: the court record's evidence and profile pictures, and the chapter title cards. For the next item, the game writes the new picture into the same storage and builds a new texture object over it. These are now CPU-written at first use: [Block-compressed storage the CPU wrote before first use](../../../docs/reference/nvn-objects.md#block-compressed-storage-the-cpu-wrote-before-first-use). Nobody has checked yet whether the Western release shows the court-record problem.

## Services

- **Resolved: the first boot crashed in `oe::DisableAlbumImageTakenNotification`** (a null read at `sdk+0x338070`, the first call in `nnMain`, `main+0x6b188c`: the SDK asks am through the applet proxy the host never made).
- The import list against the hooks (`nso_syms.py`, then `main`'s undefined `nn::` symbols no `HLE_FORCE` names) gave the rest before they were met:
  - `oe::IsInStoreDemoModeEnabled` (no);
  - `vi::ListDisplays` (one display, "Default"; the game lists 10 into a stack buffer and does not read them, `main+0x808f08`);
  - `fs::RenameDirectory` (as `RenameFile`);
  - `account::StoreSaveDataThumbnailImage` / `DeleteSaveDataThumbnailImage` (nothing kept);
  - the `ec::ShowShop…` overloads without an `ApplicationId` (the calling application's own pages);
  - `friends::StartFacedFriendRequest` / `StartSendingFriendRequest` (fail);
  - `ngc::ProfanityFilter::MaskProfanityWordsInText(int *, char *, uint32_t)`, `SetMaskMode` and `Finalize`, which this game calls by name rather than through the vtable.
- The touch-screen states (`GetTouchScreenState<16>`) were already hooked by a macro the import table does not see.
- Two NVN calls were red stubs: `nvnDeviceSetIntermediateShaderCache` and `nvnCommandBufferDiscardColor` (a discarded target is undefined, so keeping its content is correct). After that it ran its frame loop at 30 fps; the black screen it showed was its textures (above).
- **Add-on content:** index 1 (`DLC.dlcp`); the game reports it found and added to Special Contents.

## Files and shaders

- Everything is under `nativeNXx64/`: 447 ARC archives (`*.arc`, 17,910 files; version 7, one zlib stream per file) of models (`.mod` / `.mrl`), textures (`.tex`), scripts and messages (`.gmd`), beside loose `.tex` textures, Opus / ADPCM sound and 24 H.264 `.mp4` movies (`shader_split.py` `mtarc_members`; [01](../../../docs/agents/01-extract.md#compressed-romfs-content)). `romfs_marker` is `nativeNXx64/sa/NX_64/root.arc`.
- Shaders: 460 (230 vertex, 230 pixel) in the engine's one shader package, `sc\NX_64\root` (`SPK\0`, type hash `0x02358e1a`) in `nativeNXx64/sa/NX_64/root.arc` (`shader_split.py` `mtspk_shaders`). All build and every binding decodes. The package's own vertex / pixel combinations are not read, so the vertex shaders are paired with the single-stage cover. `CustomShaderPackage.mfx` (`MFX\0`, the effect descriptions) holds no shader code, and neither `main` nor any other ARC entry does.

## Status on the Mac

- The first-boot notices (the DLC found, auto-save), the title and its Options, a new game of The Great Ace Attorney: Adventures, the opening movie, the first episode's opening scenes and its trial, at 30 fps with sound and saves; about 1.1 GB resident, flat over 14 minutes (1.07 GB in the first episode's holding cell).

## Mac routes

- `DM_KEYS="f700:A*1000/24"` (A every 24 frames) goes through the notices, the title and a new game into the opening movie; the first episode's dialogue starts at about frame 6,000 and its trial at about 20,000.

## Found on this game

General host changes first needed here; each applies to every game:

- **CPU-written textures with no flush** (`tex_dirty_upload`): [CPU writes with no flush, caught by page protection](../../../docs/reference/nvn-objects.md#cpu-writes-with-no-flush-caught-by-page-protection-tex_dirty_upload), key in [dm/games/README.md](../README.md).
- **Block-compressed textures written before their first use**: [Block-compressed storage the CPU wrote before first use](../../../docs/reference/nvn-objects.md#block-compressed-storage-the-cpu-wrote-before-first-use).
- **The MT Framework ARC and SPK readers** (`mtarc_members`, `mtspk_shaders`): [SPK shader package in an MT Framework ARC](../../../docs/reference/shaders.md#spk-shader-package-in-an-mt-framework-arc).
- **SDK 10 calls found from the import list**, `nvnDeviceSetIntermediateShaderCache` and `nvnCommandBufferDiscardColor`: [services.md](../../../docs/reference/services.md), [NVN calls that were red stubs](../../../docs/reference/nvn-objects.md#nvn-calls-that-were-red-stubs).
