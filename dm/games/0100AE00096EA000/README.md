# Hyrule Warriors: Definitive Edition (`0100AE00096EA000`)

Update 1.0.1 (v65536) over the base game, SDK 3.5.1 (OCTOPATH TRAVELER's `sdk` and movie library builds; NVN API 53). Koei Tecmo's KTGL engine on NVN. Modules `main`, `subsdk0` (GLSLC, NVN's run-time shader compiler), `subsdk1` (the movie library, NintendoSDK_movie 3.5.1) and `sdk`. Started from the NSP script's provisional profile.

Status: plays on the Mac (2026-10-31): the first-run questions, the title over its movie, the mode menu, Legend Mode's opening movie, the loading screen and the first battle, The Armies of Ruin, with its in-engine cutscenes, at 60 fps (the game's own choice, see [Frame rate](#frame-rate)) with no red line; 200 KOs and more fought through. Not yet seen: the sound (runs were headless, `DM_AUDIO` off; the renderer produces non-silent PCM), a whole battle to its end, the other modes, the iPhone.

## What it needs

| Setting | Where | Why |
|---|---|---|
| SDK 3's `movie::Decoder(type, format)` taken over | `dm/host/hle_movie.c` (general) | the title's background and every movie; see [Movies](#movies) |
| Short timed waits as polls | `dm/host/hle_thread.c` (general) | two KTGL loops waited out every frame with waits of 30 and 500 ns; see [Power](#power) |
| 4 GB layout: `mem_reserve 0x100000000`, `mem_alias 0x10000000`, `mem_stack 0x10000000`, `app_pool 0xCD500000`, `sys_resource 0x0` | [`game.tsv`](game.tsv) | the NPDM declares no system resource (META +0x14 = 0): no virtual address memory; `nninitStartup` sets a heap of the pool − used memory. The provisional profile's guess, not measured further |
| `pad_layout full` | `game.tsv` | the 3D gamepad layout: the camera is on the right stick |
| GLSLC capture | NSP script | 7 built-in shaders exist only as compiles of the game's own GLSLC at boot ([Built-in shaders compiled with the game's own GLSLC](../../../docs/reference/shaders.md#built-in-shaders-compiled-with-the-games-own-glslc)); the script captures them in its `GLSLC capture` stage (about 30 s) |

## Frame rate

- The game sets present interval 1 for its menus and battles and 2 for its movies (the log's `the game sets present interval` lines), so with the default pacing its battles run at 60 fps on the Mac. Whether the Switch reaches 60 in battle was not checked; it asks for it.
- **Checked: the battles step by the time that passed.** The pause menu's mission clock went from 0:53 to 1:52 over 60.0 s of real time at 60 fps, and the same 3 s stick hold from the battle's start (the same route at 60 fps and with `DM_PRESENT_HZ=30`) put Link at the same spot of the field. No frame-step cut is needed.

## Movies

- **Resolved: a call through a null pointer in the host's `movie::Decoder::Configure` when the title's background movie started** (`CRASH … pc=0 lr=h_movie_Configure+0x2fc`): [SDK 3's `movie::Decoder` constructor takes a type and a format only](../../../docs/reference/movies.md#sdk-3s-moviedecoder-constructor-takes-a-type-and-a-format-only).
- The movies are MP4 (`movie/*.mp4`, 69 files, 3.9 GB; the title's and the opening's are H.264 Main profile, 1280×720), decoded by VideoToolbox in CPU mode as NV12 (`hle_movie_avc.c`); the game makes no audio decoder for them. The game draws the pictures itself; the title screen's background is a movie.

## Power

- **Resolved: the first battle took a host core and a third on the Mac** (CPU 102% of a core, 4.6 W of CPU energy, 358,000 wakeups a second, the main thread's 1,010,651 yields per 300 frames, none of them a back-off sleep). Two KTGL loops wait for their frame's event with waits a thousand times shorter than they look:
  - the main thread (`main+0x2acd7c`, called once a frame from `main+0x2ad8a4`): `TimedWaitEvent(event, 30 ns)`, then until the event comes, `SleepThread(1 µs)` and `TimedWaitEvent(event, 30 ns)` in turn (`main+0x2acdc0`–`0x2ace00`; `main+0x459d28` is `SleepThread(30 ns)` for the later loop at `main+0x2ace18`);
  - the update thread (`0x1015`, `main+0x2ad1e4`): `TimedWaitEvent(event, 500 ns)` in a loop (`mov w20,#0x1f4` at `main+0x2ad200`), 370 ms of CPU a second.
  The host made the 1 µs sleeps yields with a back-off, but each condition-variable wait was another SVC between them, so no run of yields lasted, and the waits of the update thread had no yield at all: [Short timed waits are polls](../../../docs/reference/threads.md#short-timed-waits-are-polls).
- **Current:** the same battle at 60 fps: CPU 27% of a core, 1.5 W, 72,000 wakeups a second, the update thread 67 ms/s; frame time p50 16.70 / p95 16.94 ms. With only the yields' part of the change (a timed-out wait continued the run between yields), 3.1 W and 69%, the update thread still 370 ms/s.

## Files and shaders

- RomFS: 8,698 files, 12.75 GB, loose: `data/` (models, motions, effects, stages, UI textures as `GT1G0600`), `movie/*.mp4` and the music in `sound/BGMProduct.g1l` (the profile's `romfs_marker`). The `.gz` names hold no compressed data: the files are tables of entries (u32 count, then {offset, length} pairs) or plain `GT1G` / `MDLK` data; none starts with a zlib stream.
- Shaders: 1,004 GLSLC outputs: KTGL's G2S containers (`_S2G3000`) stored plainly in the shader tables (`data/action/shader/Normal.bin.gz` 266, `data/deferred/DeferredShader.bin.gz` 235, the stages' terrain and `StageShader.bin.gz`, `data/effect/g1s.bin`, `data/shadow/ShadowShader.bin.gz`), the `_SPK4100` post-effect packages (`data/posteffect/*.kps`) and the 7 captured built-in shaders. `shader_split.py` finds them all by the GLSLC magic, with no reader of its own. All 1,004 build for the Mac.
- The game compiles 7 GLSL sources with its own GLSLC (`subsdk0`) at boot: 2D primitives, particles (`__PARTICLE_TYPE_SPRITE__`, `__PARTICLE_TYPE_RECT__`) and the like; the outputs are captured into `<build>/extract/v65536/glslc_capture` and land in `ps_other` / `vs_other`.

## Mac routes

- Work folder `<NSP folder>/0100AE00096EA000-work/run`: `boot.sh <log> [secs] VAR=…` (the host copied to `build/hwhost`), `ctl.sh` and `see.sh` for driving a run through `DM_CTL`, `to_battle.sh <log>` (from a copy of `save_sys` into the first battle, about 75 s) and `ab_walk.sh <log> [VAR=…]` (the stick-hold check above).
- A fresh save asks two first-run questions (Easy mode? No; control style: Warriors) every boot until the game saves; A, A answers them. Then A at the title, A on Legend Mode, + and Left, A to skip the opening movie; the loading screen's "Continue" is the + button (A does nothing there). At 30 fps the menus take longer, so fixed waits drift.

## Found on this game

General host changes first needed here; each applies to every game:

- **Movies:** [SDK 3's `movie::Decoder` constructor takes a type and a format only](../../../docs/reference/movies.md#sdk-3s-moviedecoder-constructor-takes-a-type-and-a-format-only).
- **Power:** [Short timed waits are polls](../../../docs/reference/threads.md#short-timed-waits-are-polls).

## Open

- The iPhone: not built or tested yet (no iOS shader libraries).
- The sound was not listened to.
- The memory layout is the provisional profile's guess (it boots and plays; about 3.4 GB resident and 1.9 GB of Metal allocations on the Mac in the first battle).
