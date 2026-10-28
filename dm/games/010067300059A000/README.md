# Mario + Rabbids Kingdom Battle (`010067300059A000`)

Update 1.9.589692 (v589824) over the supplied base game, SDK 4.4.0, Ubisoft's Snowdrop engine on NVN, with Havok and Wwise. The loaded modules are `main`, `subsdk0` (GLSLC) and `sdk`. The supplied DLC packages are indices 1–4. Brief Mac gameplay testing passed; iOS is unvalidated.

## Memory

- `nninitStartup` sets a 100 MB heap. The NPDM declares 16 MB of system resource, and Snowdrop commits its pages through virtual address memory. The profile keeps the 5 GB guest block, with a 4.375 GB alias region and 256 MB stack region.
- **Resolved: startup null write at `main+0xea25b8`.** [Separate virtual ranges in Snowdrop's page allocator](../../../docs/reference/memory.md#separate-virtual-ranges-in-snowdrops-page-allocator). The allocator constructor (`+0xea217c`) reserves three adjacent 4 GB ranges and does not check reservation failure. The profile's build-gated platform cuts reduce the combined reservation to 3 GB: 2 GB for large allocations, 512 MB for 512 KB pages and 512 MB for 64 KB pages. The constructor's size fields, both combined-size uses and the large allocator's independent maximum page count (`+0xea21f4`, 32768 pages) change together. Its fixed 1 MB large-allocation metadata reserve remains sufficient. The reserve wrapper (`+0xf59fc8`) discards incoming x1/x2, allowing the large-size field override before the call.
- **Resolved: SDK virtual-range overhead.** [The SDK's address-region node area](../../../docs/reference/memory.md#the-sdks-address-region-node-area) and [large-region alignment](../../../docs/reference/memory.md#1-gb-alignment-of-regions-of-1-gb-and-more). SDK build `9de92bad67c4150268943ab4843ace65` has the older VammManager constructor (`sdk+0x93dd8`): a full 1 GB node area, with its limit at `+0x93dfc` and occupied length at `+0x93e8c`. Both become 64 MB; the large-region alignment at `+0x93fe0` becomes 32 MB. These are platform-limit cuts in `sdk_patches.py`.
- **Open:** later pool capacity and the original slab-growth fallbacks need sustained gameplay validation.

## Files and shaders

- The merged RomFS contains 4,004 files, about 2.82 GB, under `moria/sdf` and `moria/sdfconfig`. Shader objects are in Snowdrop's BERG data slices.
- **Resolved: no shaders found.** [Shader records in Snowdrop SDF data slices](../../../docs/reference/shaders.md#shader-records-in-snowdrop-sdf-data-slices). This game uses the zlib record codec; 151 cache records are themselves wrapped in SDF zstd chunks. The section layout matches Sparks of Hope's zstd records. The nested records add 151 stages, including the two fragment programs first missed at the language screen. The controls are 0x838 bytes, and compute code has no code-area header.
- The supplied update and DLC union has 11,625 stages: 10,637 vertex, 734 fragment and 254 compute. Vertex programs use the single-stage cover pairing.
- **Resolved: empty runtime capture stopped packing.** [A GLSL language preamble is not a complete shader](../../../docs/reference/shaders.md#a-glsl-language-preamble-is-not-a-complete-shader). The only `#version` string is a 646-byte header with type macros and no entry point. The initial 30-second run reached its frame loop without calling GLSLC.
- **Resolved: GLSLC rewrite assertion at `subsdk0+0x7340b8`.** [Index copied before the bounds check](../../../docs/reference/rewriter.md#index-copied-before-the-bounds-check). The copy is 71 instructions before the dispatch, across two switches preserving the index and checked register.

## Mac testing

- **Resolved: first-level pipeline compiler abort.** [An unwritten secondary blend source](../../../docs/reference/rendering.md#an-unwritten-secondary-blend-source). Fragment `fd260ce50f4a5625` writes only colour 0, while the draw uses SRC_ALPHA / SRC1_ALPHA for RGB and ZERO / SRC1_ALPHA for alpha. Metal 4's blend specialization crashed in the compiler service; the MTLDevice path reported the missing secondary output. The host folds factors for an absent secondary source to its zero choice. Matching the original GPU's missing-output value remains open in the reference entry.

Game files, logs, saves and binary analysis stay beside the NSPs in `010067300059A000_build` and `010067300059A000-work`. The build script's Mac command supplies the merged RomFS image, all four DLC roots and the shader cache. Use a fresh `DM_CTL` file for each run.

Tested on 2026-10-28 with the registered update, all four DLC images and all 11,625 stamped Mac shader libraries. Language selection, title and campaign menus, File 1 creation, the opening movie, the World 1-1 introduction and pause/resume work. A one-second left-stick movement moved the party along the path and collected two coins. The final run reported no missing shaders or failed pipelines. Testing stopped after this brief exploration check, as requested; battles and sustained play remain untested. Audio was disabled in the final control check.

From a saved File 1, A passes the title, Main Story and file selection. Y skips an already-seen cutscene. Restart Chapter from the pause menu marks the chapter introduction as seen and lets Y skip its replay. Use A for the Ziggy card and Beep-0 dialogue, then the left stick to move the party. The profile's `pso_manifest.tsv` records the menus, introduction and first exploration pipelines.

## iOS build

The NSP script produces the unsigned `MarioRabbidsKingdomBattle.ipa` (about 5 GB), with the update, all four supplied DLC images and 14,143 iOS Metal libraries (11,625 stages plus variants). It has not been installed or tested on an iOS device.

## Found on this game

- [An unwritten secondary blend source](../../../docs/reference/rendering.md#an-unwritten-secondary-blend-source).
- [Index copied before the bounds check](../../../docs/reference/rewriter.md#index-copied-before-the-bounds-check).
- [Separate virtual ranges in Snowdrop's page allocator](../../../docs/reference/memory.md#separate-virtual-ranges-in-snowdrops-page-allocator).
- [The SDK's address-region node area](../../../docs/reference/memory.md#the-sdks-address-region-node-area).
- [1 GB alignment of regions of 1 GB and more](../../../docs/reference/memory.md#1-gb-alignment-of-regions-of-1-gb-and-more).
- [Shader records in Snowdrop SDF data slices](../../../docs/reference/shaders.md#shader-records-in-snowdrop-sdf-data-slices).
- [A GLSL language preamble is not a complete shader](../../../docs/reference/shaders.md#a-glsl-language-preamble-is-not-a-complete-shader).

## Open

- Check later battles, the Donkey Kong DLC and sustained memory use.
- iOS testing is performed by the user.
