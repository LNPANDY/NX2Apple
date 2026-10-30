# Pokémon Sword (`0100ABF008968000`)

Update 1.3.2 (`v458752`) over the base game, SDK 7.3.2. Game Freak's engine before Trinity, on NVN, with Wwise sound (a 6-channel `AudioOut`), Pia / NEX networking and Silicon Studio's YEBIS post effects. Modules `main`, `subsdk0` (the movie module), `subsdk1` (GLSLC, which `main` imports but never calls) and `sdk`; `sdk` and `subsdk0` are the same builds as Super Mario Odyssey 1.4.1's ([0100000000010000](../0100000000010000/README.md)). Started from the provisional profile the NSP script wrote from its survey (`dm/games/profile_guess.py`). Plays on the iPhone (IPA 12.4 GB) at 30 fps, as on the Switch. Pokémon Shield ([01008DB008C2C000](../01008DB008C2C000/README.md)) has the same modules but `main` and the same shaders.

## What it needs

| Setting | Where | Why |
|---|---|---|
| 4 GB layout: `mem_reserve 0x100000000`, `mem_alias 0x10000000`, `mem_stack 0x10000000`, `app_pool 0xCD500000`, `sys_resource 0x0` | [`game.tsv`](game.tsv) | no virtual address memory (the NPDM declares no system resource): `nninitStartup` sets a 3.13 GB heap |
| `mem_used 0x4c00000` | `game.tsv` | the rewritten modules (76 MB: `main` 25 MB of text, GLSLC 4.8 MB) are larger than the default 64 MB of used memory |
| `pad_layout full` | `game.tsv` | the 3D gamepad layout: the camera is on the right stick |
| Node area cut and 2 MB alignment of large regions (SDK 20's) | `dm/tools/sdk_patches.py` SDK-wide rules, `sdk` build `fcf93a41…` | DRAGON QUEST XI S's build, cut by the SDK-wide rules; this game has no virtual address memory |

No `patches.py`.

## Performance and memory

- On the Mac: 30 fps as on the Switch (frame time p50 33.3 ms, p95 35–36 ms; GPU 4–9 ms a frame on an M6; CPU 42% of a core, 0.15 W), with sound. Resident memory 1.8 GB after the title, 2.4 GB after 17 minutes of new areas, 1.9 GB of Metal allocations. No red line on the route below. The prewarm list covers it (3,273 lines).

## Services

SDK 7 calls, one boot each; the import list against the hooks and every other game's imports named all of them beforehand (33 `nn::` imports no host hook names and no other game imports) ([Listing a game's unhooked imports before they are met](../../../docs/reference/services.md#listing-a-games-unhooked-imports-before-they-are-met)):

- **Resolved: the Poké Ball Plus** (`hid::*Palma*`, 26 functions; the first boot crashed in `hid::detail::SetPalmaBoostMode`, a null read at `sdk+0x238eb0`, the hid service never opened). The host answers that none is connected: no npad has the Palma style, so the game never gets a connection handle, and every call on a handle fails (`hle_hid.c`).
- **Resolved: `pdm::QueryApplicationPlayStatistics`** (the second boot: a null read at `sdk+0x336ccc`). The game asks how often this user launched two other games (the Let's Go play statistics) and reads only the launch count, so each is never played (`hle_offline.c`).
- `err::ShowNetworkServiceError` is logged.
- `nvnDeviceGetWindowOriginMode` and `nvnDeviceGetDepthMode` were red stubs: the game sets neither mode and reads both.

## Files and shaders

- 7,699 GFPAK archives under `bin/archive` (7.9 GB of the 12.1 GB RomFS) hold the models, textures, effects and maps, beside loose message tables, battle data, Wwise banks (`bin/sound/NX64/wwise/bank/Stream.pck` is the profile's `romfs_marker`) and BNSH files. A GFPAK is `GFLXPACK`, u32 version 0x1000, u32 0, u32 file count, u32 folder count, u64 offset of the file table, u64 offset of the file hashes (FNV-1a 64 of each path; no names are stored), u64 offset of the folder table pointers; the file table holds 0x18 bytes per file {u16 level, u16 compression, u32 length, u32 stored length, u32 0, u64 data offset}, compression 0 stored, 1 zlib, 2 LZ4 (one block), 3 Oodle Kraken (pkNX). All 201,635 entries of Sword's are LZ4, so the split needs no Oodle. Inside: BNTX textures, BNSH shader archives, models (`.gfbmdl`) and animations ([01, Compressed RomFS content](../../../docs/agents/01-extract.md#compressed-romfs-content)).
- Shaders: 41,516. Nearly all are BNSH entries of the GFPAK archives (the models' and effects' shader archives; `shader_split.py` `gfpak_members`), beside loose BNSH files (`bin/battle/waza/model/**/*.bnsh_vsh` / `_fsh`, `bin/graphics`, `system_resource/shader`), two in `main`, and YEBIS's 3,155 (below). The provisional split, with no GFPAK reader, found 3,126.
- **Resolved: shaders in no file (YEBIS,** the post-effect library: bloom, glare, depth of field, vignette; `C:/workspace/YEBIS_draft/src/GPU/…` in `main`). After the GFPAK reader, 38 shaders the opening drew were still missing from the map (`DM_NVN_SHDUMP`): no RomFS file and no module held their code, stored or LZ4, and none was a patched copy of a split shader (the nearest ones of the same length differ in hundreds of bytes). The game does not compile them at run time either (`main` imports `glslcCompile` from `subsdk1` but never calls it; it holds no GLSL source). A temporary trace in `nvnProgramSetShaders` (the key's code and control addresses, a backtrace and the heap around them) showed control sections packed back to back with technique names such as `ps_BrightPassT1_THRESHOLD_LUMINANCE_S1` beside them. The names are in `main`, and so is the data: the only zlib stream in `main` that inflates (`main+0x1c98ed9`, 39.5 MB) is YEBIS's `.tfxo` file, a text header (the shader count, `hlsl`, `TexUtil_NVN_NX`, the technique list) and 3,155 shaders, each a control section (its own length 0x850 on SDK 7) directly followed by its code area (`tfxo_streams`, `tfxo_shaders`; 3,015 distinct, 3,112 pixel and 43 vertex, single-stage programs). They covered all 38.

## Rendering

- **Resolved: a G-buffer of float and integer targets** (`failed to create render pipeline … output of type float4 is not compatible with a MTLPixelFormatRGBA16Uint color attachment`, 10 pipelines as the opening's stadium loads). The scene shaders write colour 0 and 2 as floats and colour 1 from integer bits (`as_type<float>`) into an RGBA16Uint target. Luigi's Mansion 3's integer entry point (`main0_u`, every output an integer) does not fit a pipeline with a float target as well. **Current:** such a shader gets a third entry point, `main0_m`, that returns only the outputs written from integer bits as unsigned integers (`uint_mask_m` in its reflection: colour 1 in all 336 of Sword's), taken for a pipeline whose integer attachments are exactly those (`pso_mixed_uint`).
- **Resolved: cube views of one layer** (an abort in Metal's validation as the player first walks out of the house: `newSliceRange.length(1) must be a multiple of (6)`). The environment maps are 6-layer textures (target 2D array, depth 6) sampled through views with target CUBEMAP and layers 0 + 1. As in the hardware's texture header, a cube view counts its layers in cubes; Metal counts faces.
- **Resolved: writes beside a texture** (73,232 re-uploads in 70 s from a save, 12 GB of upload staging in 8 minutes, frame times rising from 33 to 75 ms). The game keeps each texture of its models in a memory pool of its own, the pool's storage 4 KB after its own object, in the same 16 KB host page, and writes there every frame. The dirty-page tracker marks whole host pages, so every such texture counted as changed at each use; hashing showed every re-uploaded content unchanged. With the fix, the same 70 s: 0 re-uploads and 72,584 checks (`writes beside a texture only` in the `packaged textures` line).

## Input

- The 3D pad layout (the camera is on the right stick).

## Mac routes

- The work folder's `run/ctl.sh` drives a run started with `DM_CTL`, `run/step.sh <shot> [wait] <presses…>` presses and takes a screenshot (headless: a window that loses focus is throttled and its shots never come), and `run/route_out.sh <run>` boots a copy of `run/save_ref` (in the bedroom with the Bag) through the title and out of the front door.
- From a fresh save, A at the language (about frame 600), the photo and the name (`DM_KBD`) reach the opening.
- `run/save_hop` is a save in Hop's kitchen, before the walk to Wedgehurst: from it, down 2.5 s out of the house, left 3.5 s, up 0.5 s, left 5 s, right 0.6 s and up 8 s reach the hill above Wedgehurst, and A presses with the stick up through the station scene lead back to Hop's yard and the starters (the camera turns with each move: walk in short steps onto the court and press A facing the Pokémon).
- The route checked on the Mac: the first boot's language, photo and name choices, the opening (the Champion's broadcast, the stadium), Postwick (the house, the Bag, Hop's house), the walk to Wedgehurst and Leon's arrival at the station, the evening in Hop's yard, the starter choice (Scorbunny) and the first battle against Hop (Wooloo, then Grookey), the title screen and a save and load.

## Found on this game

General host changes first needed here; each applies to every game:

- **The Poké Ball Plus answered as absent** (`hle_hid.c`), **play statistics as never played** (`hle_offline.c`), `err::ShowNetworkServiceError`, `nvnDeviceGetWindowOriginMode` / `nvnDeviceGetDepthMode`: [Poké Ball Plus (Palma)](../../../docs/reference/services.md#poké-ball-plus-palma), [Account, friends, play data and Nintendo Account calls](../../../docs/reference/services.md#account-friends-play-data-and-nintendo-account-calls), [System applets opened by `Show…` calls](../../../docs/reference/services.md#system-applets-opened-by-show-calls), [Device getters that were red stubs](../../../docs/reference/nvn-objects.md#device-getters-that-were-red-stubs).
- **The GFPAK reader** (`gfpak_members`) and **`.tfxo` streams in `main`** (`tfxo_streams`, `tfxo_shaders`): [BNSH entries of GFPAK archives](../../../docs/reference/shaders.md#bnsh-entries-of-gfpak-archives), [Shaders in a zlib stream in main (YEBIS .tfxo)](../../../docs/reference/shaders.md#shaders-in-a-zlib-stream-in-main-yebis-tfxo), [01, Compressed RomFS content](../../../docs/agents/01-extract.md#compressed-romfs-content).
- **A mixed float / integer pixel shader entry point** (`fs_uint`, `main0_m`, `uint_mask_m`, `pso_mixed_uint`), **cube views counted in cubes** (`tex_by_id`) and **packaged textures whose shared edge pages are written but whose own bytes are not, protected again instead of re-uploaded** (`pkg_edges_take`, `pkg_edges_clean`; `t_nvn` 6c1): same section.
