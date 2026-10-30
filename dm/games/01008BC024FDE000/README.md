# STEINS;GATE RE:BOOT (`01008BC024FDE000`)

Update 1.0.3 (v131072) over the base game, SDK 20.5.17 (the same SDK generation as Breath of the Wild and Tears of the Kingdom). M2's ADV engine (`advengine`, m2lib, the E-mote player for the animated characters) on NVN. Modules `main`, `subsdk0` (the SDK's movie library) and `sdk`; `sdk` and `subsdk0` are the builds FINAL FANTASY RESONANCE runs ([0100606026F12000](../0100606026F12000/README.md)). Playable on an iPhone; 60 fps. The README lists its IPA at about 6 GB.

On the Mac: the logos, the title menu (its background is a movie), a new game through the prologue movies into the story, the config pages, save and quick load, at 60 fps with music, voices and movie sound; no red line in 15 minutes of story.

## What it needs

| Setting | Where | Why |
|---|---|---|
| 4 GB layout: `mem_reserve 0x100000000`, `mem_alias 0x10000000`, `mem_stack 0x10000000`, `app_pool 0xCD500000` | [`game.tsv`](game.tsv) | 13 Sentinels' partition, as the other games without virtual address memory: 256 MB in front + 256 MB alias region + 256 MB stack region + 3.25 GB heap region |
| Node area cut 1 GB → 62 MB | `dm/tools/sdk_patches.py` SDK-wide rules, `sdk` build `0023a1b0…` | made for FINAL FANTASY RESONANCE on the same build, now from the SDK-wide rule; this game has no virtual address memory |

The pad layout is the default 2D one (no `pad_layout` row) and the operation mode the default docked one; see [Input](#input).

## Memory

- The NPDM declares no system resource (META +0x14 = 0): the game uses `SetHeapSize` (3.05 GB) in the 4 GB layout. The modules take about 35 MB, under the default used memory.
- About 1.0–1.1 GB resident in the story on the Mac.
- **Resolved: GPU memory grew with every picture shown.** The game decodes each picture it shows (ASTC 4x4 images up to 4096 wide, RGBA8 render targets, R8 masks) into one scratch region of a pool that lives for good, finalizes that texture when it is done with it and builds the next one in the same region with another size or format; during some transitions it builds a new render target every frame, one pixel wider each time (614x720, 615x720, …). The storage-sharing table (`g_alias`) kept every one of them until the pool was finalized: from a quick save, 297 entries and 1.29 GB of GPU memory at frame 6,600; 468 entries and 1.58 GB 24,000 frames into a new game. With `alias_take_over` (a new shared texture takes over the entries of its pool whose storage it overlaps under another description): 97 entries and 0.93 GB at frame 6,600 on the same route; 15 minutes of story from the quick save (53,700 frames) stayed at 1.08–1.15 GB of GPU memory and 1.02–1.13 GB resident, and a new game from boot stays at 0.97–1.03 GB from its first story scene to frame 27,300 (with the 16-submission guard). GPU memory now stays near 1 GB where it used to grow with every picture.

## Rendering

- 487 shaders (483 pixel, 4 vertex) in five BNSH in `main`; RomFS holds none. The build decodes every binding. Its frames are light: a background, the E-mote characters, the text window.
- **1280x720 in both modes, by the game's own choice.** The window is 1920x1080 and the game crops it (`nvnWindowSetCrop`) to the 1280x720 it draws; the present scales the crop to the screen. Its render size setting (engine object + 0x6000) holds 1920x1080 docked from its constructor (`main+0x383eb0`) until its start-up code sets 1280x720 (`main+0x17c50` → the setter `main+0x389e90`), whatever the host reports. Raw screenshots (`DM_NVN_SHOT`) show the whole swap texture, the picture in its lower-left corner (lower-left window origin); `DM_NVN_SHOT_OUT=960x540` gives the presented picture.
- **How the render size write was found:** the static search for stores with offset 0x6000, conditional probes on 25 candidate stores and a wrapper around the host's `memcpy` / `memset` (the guest's go straight to the host's libc, `hle_table.c`, where guest probes cannot see them) all found nothing; a watch that unprotected the page for every fault missed the write among the bursts of stores to the engine object's page; `DM_PROBE_WATCH` found it on the first run (`main+0x389e90`, a setter its start-up code calls with 0) ([05, Probes without a debugger](../../../docs/agents/05-debugging.md#probes-without-a-debugger-dm_probe)).
- **A film look:** the backgrounds carry a green scratch line, coloured dust specks, chromatic fringes and displaced rows; by every sign the art's own film effect (not yet compared with a Switch capture).

## Movies and audio

- 87 H.264 / AAC MP4 movies in `movie/`, demuxed by the SDK's `movie::Extractor` in `subsdk0` and decoded by the host (`hle_movie.c`): decoders opened with output 4 (NV12 into the client's buffer, 1280 × 720 × 1.5 bytes) in mode 1. The title menu's background is one of those movies.
- **Resolved: a null read at `sdk+0x1f2314` as the first movie starts** (the title menu's background, right after the first press), in `nn::audio::SetAudioOutVolume`, called from `main+0x1c4fbc` on the AudioOut the game opens for the movie's AAC sound (`OpenDefaultAudioOut` without an event, `main+0x1c48c0`). The SDK's version calls the audout session's virtual method, and the host never made the session. The game sets the volume every frame while a movie plays. The host keeps it per output and scales the PCM16 it plays, saturating; `GetAudioOutVolume` reads it back (`hle_audio.c`). It was among `main`'s imports that no host hook names; the others there fill the game's own structures or run in `sdk` (the CPU audio renderer, the swkbd and hid argument builders). It was the one call the game needed ([AudioOut volume kept per output](../../../docs/reference/audio.md#audioout-volume-kept-per-output)).
- Its sound goes through the hardware Opus decoder calls (`hle_codec.c`).

## Files and shaders

- Everything else is in the game's own PSB archives (`<name>_info.psb.m` index + `<name>_body.bin` data, mzs-compressed but for the plain PSB sound and voice bodies), which it reads itself. `romfs_marker` is `image_hd_body.bin`.
- Only the merged 1.0.3 copy is extracted; the base game's own build IDs are added when needed.

## Input

- Buttons only: it reads the touch screen in handheld mode but takes nothing from it, so the profile keeps the default docked mode and the 2D pad layout.
- Controls (its HELP screen): A enter, B cancel / hide text, X back log, Y auto mode, L force skip, R skip mode, ZL / ZR phone trigger, − tips, + system menu, R3 quick save (R3 needs the 3D pad layout).

## Mac routes

- Into the story from a quick save: A on the title, Right to CONTINUE, A, Right to QUICK LOAD, A, A on the save, Left to OK, A loads the quick save. The menu takes presses late and unevenly while its background movie starts (100 to 500 frames after the title's A), so check a `DM_KEYS` route's frames with screenshots.

## Found on this game

General host changes first needed here; each applies to every game:

- **`nn::audio::SetAudioOutVolume` / `GetAudioOutVolume`** per output (`hle_audio.c`): [AudioOut volume kept per output](../../../docs/reference/audio.md#audioout-volume-kept-per-output).
- **Storage takeover in the storage-sharing texture table** (`alias_take_over` in `nvn_mtl.m`, with its guards for live texture objects and lookups in the last 16 submissions, and the `shared textures N (…)` memory line): [Shared-storage entries taken over by a new texture](../../../docs/reference/rendering.md#shared-storage-entries-taken-over-by-a-new-texture).
- The halfword jump-table padding (`half_count`) changed 1 to 6 tables in some `main`s, this one among them: [Halfword jump table landing pads sized to the largest entry](../../../docs/reference/rewriter.md#halfword-jump-table-landing-pads-sized-to-the-largest-entry).

## Open

- 04 and `game.tsv` say the start-up code sets the render size to 1280x720 through the setter `main+0x389e90`; 05 describes the same setter as one "its start-up code calls with 0". Not reconciled.
