# ROMANCE OF THE THREE KINGDOMS 8 REMAKE (`0100C2A01A730000`)

Update 1.1.3 (v851968) over the base game, with its four DLC. SDK 17.5.3 (Ace Attorney Investigations Collection's `sdk` and `subsdk0` builds). Koei Tecmo's KTGL engine on NVN. Modules `main`, `subsdk0` (the movie library, NintendoSDK_movie: the WebM logo and story movies) and `sdk`. Plays on the iPhone (IPA 16.8 GB); 30 fps, as on the Switch; controller only.

## What it needs

| Setting | Where | Why |
|---|---|---|
| 4 GB layout: `mem_reserve 0x100000000`, `mem_alias 0x10000000`, `mem_stack 0x10000000`, `app_pool 0xCD500000`, `sys_resource 0x0` | [`game.tsv`](game.tsv) | the NPDM declares no system resource (META +0x14 = 0): no virtual address memory; `nninitStartup` sets a heap of the pool − used memory (3.13 GB) |
| `mem_used 0x5000000` (80 MB) | `game.tsv` | the rewritten modules take more than the default 64 MB, which `SetHeapSize` checks the request against |
| `pad_layout full` | `game.tsv` | the 3D gamepad layout: the dialogue boxes' auto and log buttons are the right stick and R3 |
| Node area cut 1 GB → 62 MB | `dm/tools/sdk_patches.py`, `sdk` build `311deab1…` | applies to this build by its ID; written for Ace Attorney Investigations Collection ([010005501E68C000](../010005501E68C000/README.md)), whose virtual address memory needs it. This game has none |

## Display and input

- The game draws 1280x720 into its 1920x1080 window textures and crops (`WindowCrop`), docked as well; a screenshot without `DM_NVN_SHOT_OUT` shows the whole texture, the picture in its top-left corner.
- Controller only, with the 3D pad layout. `main` initializes the touch screen and gestures but never reads them (`game.tsv`: `main` imports no `GetTouchScreenState`); it reads a USB mouse (`GetMouseStates`), which the host does not provide. Touches as a mouse would suit it, but OCTOPATH TRAVELER 0, Tears of the Kingdom and Unicorn Overlord also read a mouse and no touch screen, so such a rule needs testing on them first.

## Audio

- **Resolved: `[RED] audren: a second renderer` right after the first open, with the same work buffer and "original device 1 mode 1".** Not a second renderer: SDK 17.5.3's `OpenAudioRenderer` with an event opens it by calling the form without one through the PLT (`sdk+0x1e489c`), which the loader binds to the host's hook, so `ar_open` ran twice for one renderer. The inner call started the render thread before the outer one had created the event, and the outer call took the renderer for a second one. A thread-local flag (`t_in_open`) now hands the inner call straight to the SDK with the host's CPU / manual copy of the parameter, and only the outer call starts the thread.

## Files and shaders

- A newer RDB than Age of Calamity's: `0002/root.rdb` and `0002/system.rdb` are the indexes (`_DRK0000`, with a `.rdx` beside each) over 296 `0002/0x<KTID>.fdata` files (12.2 GB) and `0002/data/0x<KTID>.file` (and `jaJP/`, `zhCN/` copies); `game.tsv` gives 12.6 GB for the RDB data. An `.fdata` starts with `PDRK0000` and u64 0x10, then the same `IDRK0000` entries (the u32 after the lengths is 1 or 0, the padding 16 bytes).
- The compression is new: flag 0x400000 = chunks of u16 stored length, 8 bytes, then a zlib stream; with 0x100000 as well (flags 0x500000) the streams are LZ4 blocks. Each chunk inflates to at most 16 KB and a zero length ends. Of the 51,655 entries, 49,620 are LZ4, 2,026 zlib and 9 stored; all decode to the length in their header (`shader_split.py` `idrk_data`; [01](../../../docs/agents/01-extract.md#compressed-romfs-content)).
- Scenarios, messages, movies and their subtitles sit in loose folders beside the RDB.
- **The update is a multi-program patch:** beside the game's patch (`…0000`, 1.5 GB) it carries a whole second program (`0100C2A01A730001`, 34 MB, a full NCA, not a patch) with its own Control NCA, which `main` starts with `nn::oe::ExecuteProgram(1)` (`main+0xa31910`). **Resolved:** `nx_extract` took the first Program NCA it found, the second program, and failed with `NCA section 1 does not exist` layering it over the base game; it now takes program index 0's NCAs. The host runs program 0 only (`hle_oe.c` logs the call).
- Shaders: 59,363 GLSLC outputs (52,691 pixel, 5,359 vertex, 1,311 compute, 2 geometry): 59,214 in the G2S (`_S2G5000` / `6000` / `7000`) and `_DOK0000` containers of the RDB entries, and 149 in `main`. The vertex shaders are single-stage programs, paired with a cover pixel shader. All build for the Mac (1 h 19 min on a 12-core M6).
- Three shaders get textures of another type than they declare on some slots (`texture type mismatch … bound as is`, once each: a 2D array where a pixel shader declares 3D, cube and 3D textures where two vertex shaders declare 2D); nothing in the scenes below looks wrong.

## Status on the Mac

- From the logo movie and intro, the title and its attract demo, the main menu, a new game through the recommended setup (Ruler, Cao Cao, 195), its opening story on the map, the council (espionage, personnel, the help panel), a saved and loaded game, a month's missions, the city view, a visit and a practice duel in 3D.
- 30 fps, as on the Switch (frame time p50 33.3 ms, p95 34.5 ms; GPU 5–7 ms a frame on the Mac in the duel), sound; about 2 GB resident in the council and 2.5 GB in the duel, flat on a screen left idle. The prewarm list covers that route.

## Mac routes

- The work folder's `run/ctl.sh` drives a run started with `DM_CTL`. From a fresh save: A (skips the intro), A at the title, A (New Game), A on Recommended, A ×3, the quiz's first answers (A, A, A), A on Ruler, X at Confirm Settings, A ×3 and X, then X at the story's Skip dialog: the council of 195 April, about 2 minutes.
- `run/save_ref` holds a manual save there: A, A, Down, A (Load), A, X loads it.

## Found on this game

General host changes first needed here; each applies to every game:

- **Multi-program updates:** `nx_extract` takes program index 0's NCAs: [01, Compressed RomFS content](../../../docs/agents/01-extract.md#compressed-romfs-content).
- **The newer RDB** (`.fdata`, `idrk_data`): [G2S containers in KTGL RDB archives](../../../docs/reference/shaders.md#g2s-containers-in-ktgl-rdb-archives).
- **`OpenAudioRenderer` calling its no-event form through the PLT** (`t_in_open` in `hle_audren.c`): [The SDK's open with an event calls the open without one (`t_in_open`)](../../../docs/reference/audio.md#the-sdks-open-with-an-event-calls-the-open-without-one-t_in_open).

## Open

- Touches as a mouse: not done; it needs testing on the other games that read a mouse and no touch screen (above).
- Of the three texture type mismatches above, the cube textures in the vertex shaders' 2D slots now get a 2D view of their first face ([Compatible views for a mismatched declared texture type](../../../docs/reference/rendering.md#compatible-views-for-a-mismatched-declared-texture-type)) and the 3D textures there are bound as is; the 2D array in the pixel shader's 3D slot now gets the zero 3D texture ([A 2D texture in a 3D slot binds the zero 3D texture](../../../docs/reference/rendering.md#a-2d-texture-in-a-3d-slot-binds-the-zero-3d-texture)), not run on this game since.
