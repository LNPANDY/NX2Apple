# Catherine: Full Body (`0100BF00112C0000`)

Update 1.0.1a (v131072) over the base game, SDK 8.2.1. Atlus's GFD engine (the game's code name xrd758) on NVN, with CRI middleware. Modules `main`, `subsdk0` (GLSLC, the run-time shader compiler; the same build as Link's Awakening's, [01006BB00C6F0000](../01006BB00C6F0000/README.md)), `subsdk1` (the SDK's movie library) and `sdk`; `sdk` and the movie module are the builds Super Smash Bros. Ultimate runs ([01006A800016E000](../01006A800016E000/README.md)). Plays on the iPhone; 30 fps, as on the Switch. The README lists its IPA at about 14 GB.

Brought up on the Mac: the ATLUS logo, the title, the puzzle type choice, the Golden Playhouse intro, the anime opening (CRI movies with sound) and the first Nightmare stage with Vincent under control, no red line in a 6-minute run.

## What it needs

| Setting | Where | Why |
|---|---|---|
| `mem_used 0x6000000` (96 MB) | [`game.tsv`](game.tsv) | the rewritten modules take 92 MB, more than the default 64 MB; see [Memory](#memory) |
| 4 GB layout: `mem_reserve 0x100000000`, `mem_alias 0x10000000`, `mem_stack 0x10000000`, `app_pool 0xCD500000` | `game.tsv` | the block of the other games without virtual address memory: 256 MB in front + 256 MB alias region + 256 MB stack region + 3.25 GB heap region |
| Node area cut and 2 MB alignment for regions of 4 MB and more (SDK 20's) | `dm/tools/sdk_patches.py` SDK-wide rules, `sdk` build `5fd4f531…` | made for Super Smash Bros. Ultimate on the same build, now from the SDK-wide rules; this game has no virtual address memory and never makes an address region |
| The 2 shaders it compiles at boot | captured on the Mac (`hle_glslc.c`) | compiled at run time by its own GLSLC from GLSL sources in `main`, captured on the Mac as Three Houses' are ([010055D009F78000](../010055D009F78000/README.md)) |

## Frame rate

- 30 fps, as on the Switch (present interval 2). GPU p50 4.7 ms, CPU about a fifth of a core on the Mac.

## Memory

- The NPDM declares no system resource (META +0x14 = 0): `nninitStartup` sets a 3.11 GB heap in the 4 GB layout (pool − used; `game.tsv` says the pool − 64 MB); `main`'s bss is 48 MB.
- **Resolved: the memory pool for the game's 96 MB GPU heap had no storage (`MemoryPoolInitialize` red line), then a null read at `main+0x2eb954`.** The log said `[mem] SetHeapSize … + modules 0x5c00000 > app pool`: the rewritten modules take 92 MB (`main` 61 MB with its bss, GLSLC 9.5 MB, the movie library 7.6 MB, `sdk` 13.8 MB), so `SetHeapSize(pool − 64 MB)` failed and the game ran on a 32 MB heap, as Age of Calamity did. `mem_used` is 96 MB, the NSP script's guess after the rewrite.
- On the Mac (M6) in the first stage: 0.79 GB resident, 1.9 GB of Metal allocations.

## Shaders

- 3,128 GLSLC outputs (1,244 vertex, 1,872 pixel, 12 compute), all of one stage each: 3,050 loose files in `data/shaders_binary` (`*.vs` / `*.ps`, read like FINAL FANTASY TACTICS' technique files), 76 in `main` and 2 the game compiles at boot with its own GLSLC (captured on the Mac). Single-stage programs paired with the cover, as in 13 Sentinels. Every binding decodes with Mario's layout.
- **Resolved: a null read at `main+0x3316dc` in `nnMain`, right after the window setup** (the program object's interface pointers at +0xd0 / +0xd8 both null). The game compiles two built-in programs at boot with its own GLSLC, and first checks that GLSLC's GPU code version against `nvnDeviceGetInteger` items 0x2E–0x31 (the driver's supported range, `main+0x330dcc`). The host reported Super Mario Odyssey's SDK 7 driver range, 1.5–1.14; this GLSLC writes 1.15, so nothing was compiled and the first uniform lookup read the empty program. The host now reports at least the version the game's own `glslcGetVersion` returns (`hle_glslc.c` `dm_glslc_gpu_code`, `hle_nvn.c`).
- **Resolved: shader type 0 in every vertex shader's SPH** (word 0 = `0x0061`; every other game's vertex shaders have `0x0461`). `shader_split.py` found no stage for them and stopped at the first captured output (`no GLSLC output`). Ryujinx's `ShaderHeader` reads a graphics header's type 0 as a vertex shader; `sph_stage` does too. A census of the other games' packages and of every `main` on hand found no other type-0 vertex shader.
- **Resolved: every post pass and the window drew one texel's colour (a black screen with sound).** Shader type 0 is Maxwell's first vertex slot (VERTEX_CULL_BEFORE_FETCH), and this GLSLC (GPU code version 1.15) writes every vertex shader as two programs in one code area: part A (VertexA) at code +0 (the SPH above) loads the position attribute and writes only the position; part B (VertexB), at control +0x700 with a 0x30-byte header of zeros and an SPH of type 1, reads the other attributes and writes the other outputs. Control +0x748 lists both as {SPH offset, length from the SPH, ?}. The hardware runs A, then B. Translated alone, A left every varying at (0, 0, 0, 1), so the full-screen passes sampled their sources at (0, 0) and the 2D draws their atlases' first texel. `dmsh_build.py` (`vertex_ab`) merges the two as Ryujinx's `TranslatorContext.Translate(VertexA)` does: A's instructions with each unconditional `EXIT` turned into a `BRA` to B's first instruction, then B's, under B's SPH with A's flags and input / output maps ORed in and the larger local memory sizes. In all 1,244: A writes no generic output, A ends in an `EXIT` predicated on CC FCSM_TR (which Ryujinx never takes; left as it is), an unconditional `EXIT` and a `BRA` to itself, and neither part has an absolute or table jump, so moving B keeps every branch. c1 is what follows part B (zero padding in all of them). A type-0 shader with no part B listed is translated as it is.

## Rendering

- **Resolved: the cutscene subtitle band was a hard-edged dark box with a magenta stroke through it.** The band is a 32x512 BC3 gradient the game copies from a staging buffer (`nvnCommandBufferCopyBufferToTexture`, recorded at the start of a frame, `main+0x305e64`), and the GPU copy read the next texture's blocks: the source was right when recorded and when encoded, but the game's resource thread wrote the next texture into the same staging block 64 ms later, before that first submission had even been committed, because the host spent 300 ms building pipelines inside it. On the Switch the GPU runs a submission's copies as soon as the submit returns. A segment is now committed at the first pass boundary after any buffer → texture copy (`g_cut_copy`, `sub_cut` in `nvn_mtl.m`); the `residency set` line counts these cuts (`N after buffer → texture copies`, a few per 300 frames in this game, only while it loads). The game reuses its staging memory about a frame after recording a copy. Found with `DM_NVN_HILITE` on the band's pixel shader, `DM_NVN_TEXRAW` of the texture (decoded: opaque black and magenta blocks, not a fade) and `DM_PROBE_WATCH` on the staging address beside a log of the copy's submission completing.

## Movies and audio

- CRI ADX2 sound (`data/sound*/*.acb` / `.awb`) through one 6-channel AudioOut.
- CRI Sofdec2 movies (`data/movie*/*.usm`) whose H.264 goes through the SDK's `movie::Decoder` (the host's VideoToolbox decoder; mode 1, output format 4).
- **Resolved: a read far outside guest memory at `main+0x344f74` on the first movie picture** (Sofdec2's NV12 → RGB conversion). The player reads `nv12-y-stride`, `nv12-y-offset`, `nv12-uv-stride` and `nv12-uv-offset` from the output format and checks none of the results (`main+0x34e694`); the host set no `nv12-uv-stride`, so the chroma stride was stack garbage. It is the luma stride now, as for any NV12 picture (`hle_movie.c` `md_format`).
- **Resolved on the Mac: the anime intro ends on a black screen until manually skipped.** The host put the end-of-stream flag on the movie's last picture, which Sofdec2 drops, and then waited for that picture for good. The flag now comes on an output without a picture after the last one; the stream (H.264 High, SPS POC type 2) also needs no reorder queue. The host delivers all 1,141 pictures and the game enters Golden Playhouse by itself, from a fresh save with no skip input: [No picture carries the end-of-stream flag](../../../docs/reference/movies.md#no-picture-carries-the-end-of-stream-flag). The same symptom was reported on the iPhone for later story movies; those have not been checked one by one.

## Services

- **Resolved: abort in `sm::Initialize` under `nn::settings::GetAvailableLanguageCodeCount()`** (`main+0x117590`: it compares `LanguageCode::Make(0 … count − 1)` with `GetDesiredLanguage`'s code). The host returns the count of its language table, beside Paper Mario's `GetAvailableLanguageCodes` (`hle_sdk16.c`). The other imports no hook names run in `sdk` (the `LanguageCode` comparison, `ClockSnapshot`'s constructor and getters, fibers, `NumberLineAllocator`).

## Files

- Everything is in five CRI CPK archives (`data/Base.cpk`, `Model.cpk`, `Puzzle.cpk`, `Keyfree.cpk`, `Patch.cpk`); `romfs_marker` is `data/Model.cpk`.
- Only the merged 1.0.1a copy is extracted; the base game's own build IDs are added when needed.

## Input

- + pauses a cutscene (B resumes, Y skips); the left stick moves Vincent, A grabs blocks.

## Mac routes

- From a fresh save, `DM_KEYS="5:A*25/2,60:Plus*14/4,61:Y*14/4,62:A*14/4"` skips the intro scenes into the first Nightmare stage (about frame 3,300); `120:LUp~0.4*40/1.5` then climbs.
- `smoke.tsv` uses only `DM_KEYS="5:A*25/2"`, then waits through the entire anime intro. Golden Playhouse is visible by frame 3,600; a host that flags the last picture stays black.

## Found on this game

General host changes first needed here; each applies to every game:

- **GLSLC GPU code version range follows the game's own GLSLC** (`hle_glslc.c` `dm_glslc_gpu_code`, `hle_nvn.c`; on Bayonetta 3 the reported newest version came to follow the SDK, 1.15 from SDK 8 after this game's GLSLC 8.2.1): [GLSLC GPU code version against the driver's range](../../../docs/reference/shaders.md#glslc-gpu-code-version-against-the-drivers-range), [Newest GPU code version reported by the driver](../../../docs/reference/nvn-objects.md#newest-gpu-code-version-reported-by-the-driver).
- **VertexA / VertexB merge** (`shader_split.py` `sph_stage`, `dmsh_build.py` `vertex_ab`), explained in full under [Shaders](#shaders): [VertexA and VertexB parts merged into one vertex shader](../../../docs/reference/shaders.md#vertexa-and-vertexb-parts-merged-into-one-vertex-shader).
- **Commit at the first pass boundary after a buffer → texture copy** (`g_cut_copy`, `sub_cut`; always on, even with `DM_NVN_CUT=0`): same section.
- **`nv12-uv-stride` in the movie decoder's output format** (`md_format` in `hle_movie.c`): [Output format keys (`md_format`)](../../../docs/reference/movies.md#output-format-keys-md_format).
- **The end-of-stream flag on an output without a picture, and no reorder queue for H.264 POC type 2** (`md_pump` in `hle_movie.c`, `hle_movie_avc.c`): [No picture carries the end-of-stream flag](../../../docs/reference/movies.md#no-picture-carries-the-end-of-stream-flag).
- **`nn::settings::GetAvailableLanguageCodeCount`** (`hle_sdk16.c`): same section.

## Open

- `game.tsv` still describes the game as "In bring-up"; the development notes say it plays on the iPhone.
- The heap: the development notes say 3.11 GB (pool − used), `game.tsv` "the pool − 64 MB (3.11 GB)".
- The profile has no `pad_layout` row, so the virtual gamepad starts in the default 2D layout; the README's list of games that start in 2D does not name it ("the other games in 3D").
