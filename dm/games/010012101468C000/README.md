# Metroid Prime Remastered (`010012101468C000`)

The base game 1.0.0 (v0), SDK 12.3.1, Retro Studios' own engine (RFRM forms, the engine of [Donkey Kong Country: Tropical Freeze](../0100C1F0051B6000/README.md) in a little-endian form), NVN. Modules `main`, `subsdk0` (the SDK's movie library) and `sdk`. `main` exports its own C++ names (`CGraphicsDeviceContext`, `NMaterialArchive`, `CSceneProxy` …), so its functions can be named from its dynamic symbols. RomFS is 341 files, 6.7 GB: `MaterialArchive.arc`, `MiscData.pak`, `StartupUI.pak`, `KernelMPRT.pak`, the preload packs under `Preload/` (`DuplicateData.pak` alone is 1.5 GB), `UI/MPR1/UIMP1.pak` and a `.pak` per room under `Worlds/`.

Brought up on the Mac: boot, the title, the save slot and difficulty menus, a new game's opening (the briefing, the gunship's approach) and the first room of the Frigate Orpheon. Played for about a minute on the Frigate's landing deck: walking, turning and firing, with the HUD, the hint texts and the lock-on markers. 60 fps (frame time p50 16.67 ms; the long frames are loads and first uses of pipelines), no red line but one (below); the audio renderer produces sound (71,573 of the first 72,000 rendered frames not silent; not listened to); memory levels off at about 4.3 GB resident and 2.6 GB of Metal allocations once the Frigate is loaded and stays there (frames 14,700 to 32,700). Not yet tested on the iPhone.

## What it needs

| Setting | Where | Why |
|---|---|---|
| 4 GB layout: `mem_reserve 0x100000000`, `mem_alias 0x10000000`, `mem_stack 0x10000000`, `app_pool 0xCD500000` | [`game.tsv`](game.tsv) | no virtual address memory: `nninitStartup` binary-searches its heap from 4.5 GB down and settles on 3.11 GB in the 3.25 GB heap region, as Tropical Freeze does ([memory.md](../../../docs/reference/memory.md#a-heap-request-beyond-the-heap-region-returns-resultoutofmemory)) |
| `mem_used 0x6600000` | `game.tsv` | the rewritten modules are larger than the default 64 MB of used memory |
| `sys_resource 0x0` | `game.tsv` | the NPDM declares 0 MB of system resource |
| `modules main subsdk0 sdk` | `game.tsv` | every module `main` imports from |
| `shader_groups` (`/Worlds/`, `/Preload/`, `/UI/`) | `game.tsv` | the shader split's groups ([Shaders](#shaders)) |
| [`dual_want.tsv`](dual_want.tsv) | profile | `ab809a7456f59614` writes colour output 1 that a pipeline blends as the second source |

No rendering key: what the game needed beyond the profile is general ([Found on this game](#found-on-this-game)).

## Shaders

- **Resolved: an empty split** (only the startup archive's 8 shaders). Retro's forms are little-endian here, a pack's resource list sits in a `TOCC` form with 52-byte entries, and four vertex stages carry GLSLC data past their control section's own length: [SNVN program records in Retro Studios' RFRM forms](../../../docs/reference/shaders.md#snvn-program-records-in-retro-studios-rfrm-forms). 40,483 shaders: 20,233 vertex, 20,233 pixel, 12 geometry and 5 compute, from `MaterialArchive.arc` (1,141 stages), the 778 `MTRL` resources of the packs and the startup archive in `main` (`main+0x1d0e7a4`, 8 stages: the title logo's quads); 20,233 vertex / pixel pairs. The split takes about 6 minutes (most of it reading `DuplicateData.pak`), the Mac libraries about 17.
- **Resolved: `[RED] shader … reflection conversion failed: … c0 dynamic index c0+0x630`** and `Shader instruction Pixld is not implemented` in the build, `nvnProgramSetSampleShading` unimplemented. The game shades per sample: 438 of `MaterialArchive.arc`'s 562 pixel shaders read the sample index (`PIXLD.MYINDEX`), and 30 of them look up GLSLC's sample position table in the driver segment and pack the position into an integer G-buffer target: [Pixel `c0 + 0x620`: the sample index and GLSLC's sample position table](../../../docs/reference/shaders.md#pixel-c0--0x620-the-sample-index-and-glslcs-sample-position-table). Every render target met so far is single-sample (1600×900 docked).

## Rendering

- **Resolved: the world black, the HUD drawn over it** (the gunship invisible in the opening, the Frigate's hull and rooms black in play; menus, text and effects fine). The scene target held the whole room after the opaque passes (`DM_NVN_TEXSNAP`), and a full-screen pass (`1b17e5a457135e3b`) turned it black: the volumetric fog, which samples a 100×57×64 RGBA16F froxel volume at each pixel's depth and blends it over the scene. The volume is filled by `1cbc19f806a08166`, 5,700 points drawn with rasterization off whose vertex shader writes the 3D image; the host skipped that draw because only storage buffer writes counted, so the volume stayed zero (colour × 0 + 0): [Rasterizer discard preserves vertex storage writes](../../../docs/reference/rendering.md#rasterizer-discard-preserves-vertex-storage-writes). The profile keys `tex_flush_upload` / `tex_dirty_upload` changed nothing (no CPU writes it: its guest memory stays zero), so the profile does not set them.

## Current

- `vertex attribute format 0x27 (8 / 16-bit integer) feeds a float input` (RGBA8UI): converted on the CPU at replay, as for [Need for Speed: Hot Pursuit Remastered](../010029B0118E8000/README.md); no visible effect.
- A translucent cyan panel with a grid stands between two red lights where Samus lands, and fills the left of the view as she walks past it: drawn in the 3D scene, apparently one of the Frigate's holograms; not compared with the Switch.

## Mac routes

The work folder is `<NSP folder>/010012101468C000-work`: `host.sh` copies the worktree's `dm/host/dmhost` to `build/mprhost`; `run/boot.sh <log> [secs] VAR=value…` runs it on the NSP script's build (`010012101468C000_build`: the RomFS image, the rewritten modules, the shader libraries in `shader/cache`); `run/ctl.sh press|snap` drives a run started with `DM_CTL=run/ctl.txt`, and `run/at.sh <log> <frame> <ctl lines>…` sends control lines once the run passes a frame (for `memdump`, `texlist`, `passdump`). `tools/sym.py main <offsets>` names `main` offsets by its dynamic symbols; `tools/a64.py` disassembles.

- From a fresh save: `DM_KEYS=f1600:A,f2200:A,f2800:A,f3600:A,f4200:A`: the title (press A), the start of the menu, save slot 1 (New Game), difficulty (Normal), the save message; the briefing and the gunship's approach follow, and the game takes control on the Frigate Orpheon at about frame 12,000 (Samus's visor up, energy 99). Skipping the opening was not tried, and there is no save yet past the new file.

## Found on this game

General host and tool changes first needed here; each applies to every game:

- **Little-endian RFRM forms, `TOCC` resource lists and GLSLC's extra control data** (`rfrm_order`, `rfrm_shaders`, `snvn_records`): [shaders.md](../../../docs/reference/shaders.md#snvn-program-records-in-retro-studios-rfrm-forms).
- **The sample index (`PIXLD.MYINDEX`) and the pixel stage's sample position rows of `c0`** (translator, `SAMPLE_ROWS`, `c0_sample_rows`, `nvnProgramSetSampleShading`): [shaders.md](../../../docs/reference/shaders.md#pixel-c0--0x620-the-sample-index-and-glslcs-sample-position-table).
- **Image stores of vertex shaders drawn with rasterizer discard** (`vs_writes`): [rendering.md](../../../docs/reference/rendering.md#rasterizer-discard-preserves-vertex-storage-writes).

## Open

- The iPhone: no IPA built or tested yet, and the pipeline prewarm list `pso_manifest.tsv` is still empty.
- Only the opening and the Frigate's landing deck have been played; the Frigate's interior, Tallon IV, the visors, the Morph Ball, bosses and the movies (`FMV0` resources, the SDK movie library in `subsdk0`) are untested.
- Sample shading and the sample position table were met only on single-sample targets; the table's nibble order for several samples is the hardware's, not seen in a game.
