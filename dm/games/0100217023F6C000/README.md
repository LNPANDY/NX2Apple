# Well Dweller (`0100217023F6C000`)

Version 1.0.0, SDK **22.2.0** (`nnSdk-22_2_0`, `NintendoSDK_NVN-22_2_0`, `NintendoSDK_OpenGL-22_2_0`). A **GameMaker Studio 2** game: the RomFS holds the runner's data file (`game.win`, 229 MB, `FORM`/`GEN8`), its entitlements, three `audiogroup*.dat` banks, `options.ini` with `[LLVM-Switch] SDKDir=…`, and its pictures.

It renders with **OpenGL**, not NVN: `main` imports exactly nine EGL entry points (`eglChooseConfig`, `eglCreateContext`, `eglCreateWindowSurface`, `eglDestroySurface`, `eglGetDisplay`, `eglGetProcAddress`, `eglInitialize`, `eglMakeCurrent`, `eglSwapBuffers`) and every GL function through `eglGetProcAddress`. The context is `OpenGL 3.2`. Modules `main`, `subsdk1` (`NintendoSDK_movie`) and `sdk`; `subsdk0` (NVIDIA's GL driver) is never loaded.

On the Mac: the language list, the title screen, the opening story and the first room with its dialog render at 60 fps with sound, played with the keyboard (WASD + J/K) or a pad.

## What it needs

| Setting | Where | Why |
|---|---|---|
| `modules main subsdk1 sdk` | [`game.tsv`](game.tsv) | `main` takes nothing from NVIDIA's GL driver: the GL layer answers its EGL imports, so `subsdk0` stays unloaded |
| `sys_resource 0x0`; `mem_reserve 0x100000000`, `mem_alias 0x10000000`, `mem_stack 0x10000000`, `app_pool 0xCD500000`, `mem_used 0x6a00000` | [`game.tsv`](game.tsv) | the NPDM declares no system resource, so `nninitStartup` gives its malloc a heap of the pool minus used memory (3.10 GB), mapped as it is touched |
| [`gl_capture.tsv`](gl_capture.tsv) | profile | the 93 shaders the runner puts together at run time, which no game file holds; the NSP script captures them on the Mac; see [Shaders](#shaders) |
| `shader_groups /=romfs` | [`game.tsv`](game.tsv) | no NVN shaders: the profile's NVN tables stay empty and the GL library comes from `gl_shaders.py` |

## Rendering (OpenGL)

- **Shaders at run time:** the runner writes each variant of its GLSL as text, in **GLSL ES 1.00 without a `#version` line** (`attribute`, `varying`, `gl_FragColor`, `precision mediump`), names a variable `sample`, and declares its light environment and a few others as struct uniforms (`uniform LightEnv { … };`, which the game addresses by dotted member names such as `u_LightEnv.m_dirLights_dir`). Both needed the translator: [GLSL ES 1.00 sources without a `#version` line](../../../docs/reference/shaders.md#glsl-es-100-sources-without-a-version-line), [Struct uniforms become member rows](../../../docs/reference/shaders.md#struct-uniforms-become-member-rows).
- **Draws from client memory:** every sprite, the room background and the screen composite are drawn from client-memory vertex arrays (`glVertexAttribPointer` with no buffer bound); only the text path uses a real buffer, which is why the window first showed text alone. Dropped draws went from 11,885 per 300 frames to 0: [Draws from client memory](../../../docs/reference/rendering.md#draws-from-client-memory).
- **Two targets:** the runner renders its room into a **1280x720 surface** of its own (framebuffer 1, colour texture 5) and composites that surface onto the 1920x1080 window with one 4-vertex `GL_TRIANGLE_STRIP` sampling texture 5, whose matrix has a negative y scale, since the runner keeps its surfaces y down while the window is y up. A second surface (framebuffer 2, colour texture 189) carries the rotation and scaling of the first. So a draw log that shows 1280x720 targets under a window that looks right is expected here.
- **`glFlush` at the pause menu:** the runner calls it when it opens the menu; without it the game jumped to address 0 (`CRASH sig=11 addr=0 pc=0 lr=main+0x3409a78`): [`glFlush` hands the frame so far to the GPU](../../../docs/reference/rendering.md#glflush-hands-the-frame-so-far-to-the-gpu).
- **Small gaps filled while bringing it up:** `glDepthRange` / `glDepthRangef` (0..1 only), `GL_DEPTH_CLAMP` (Metal clamps to the depth range already) and `GL_MAX_TEXTURE_MAX_ANISOTROPY` (16).

## Shaders

- **Current:** 93 sources in [`gl_capture.tsv`](gl_capture.tsv) — the runner's sprite, text, lighting, fog and outline programs and their variants — captured on the Mac with `DM_GL_CAPTURE` and translated to one `.metallib` by `gl_shaders.py`. The set is stable from boot through the first room's dialog; a room with an effect no earlier scene used would add one, which the capture table makes the build report.

## Audio

- With `DM_AUDIO=1` on the Mac the first room's music plays: 0 underruns after the boot's first 194 padded callbacks.

## Found on this game

General host changes first needed here; each applies to every game on the same SDK or path:

- **Resolved: ZBIC modules** (NSO flag bit 7, system 22.0.0 on): `main` could not be read at all: [ZBIC-compressed NSO segments](../../../docs/reference/packing.md#zbic-compressed-nso-segments).
- **Resolved: the thread ID at ThreadLocalRegion+0x110** (SDK 22): an `nn::diag` abort with `Result 0` at the first heap lock, in `main`'s static initialisers: [The thread ID at ThreadLocalRegion+0x110 (SDK 22)](../../../docs/reference/threads.md#the-thread-id-at-threadlocalregion0x110-sdk-22).
- **Resolved: `clock_gettime(CLOCK_MONOTONIC)`** (SDK 22): an uncaught `std::system_error` from `std::chrono::steady_clock::now()`: [`clock_gettime` is `nn::time`'s steady clock (SDK 22)](../../../docs/reference/services.md#clock_gettime-is-nntimes-steady-clock-sdk-22).
- **SDK aborts with a message** (`nn::diag::detail::VAbortImpl`) log their format before the abort, which is how the `system_error` above was named: [`clock_gettime` is `nn::time`'s steady clock (SDK 22)](../../../docs/reference/services.md#clock_gettime-is-nntimes-steady-clock-sdk-22).
- **Resolved: no audio**, `OpenAudioOut` without a release event (SDK 22): [`OpenAudioOut` without a release event (SDK 22)](../../../docs/reference/audio.md#openaudioout-without-a-release-event-sdk-22).
- **Resolved: a crash at `pc 0` in `nv::GetGraphicsMemoryInfo`** on a title with no NVN device: [`nv::GetGraphicsMemoryInfo` with no graphics device](../../../docs/reference/memory.md#nvgetgraphicsmemoryinfo-with-no-graphics-device).
- **The GL layer:** client-memory vertex arrays, `glFlush`, and the bring-up switches `DM_GL_DRAWLOG`, `DM_GL_FBLOG` and `DM_GL_MISSES` (see [env_switches.tsv](../../../docs/env_switches.tsv)); the translator's ES 1.00 dialect and struct uniforms (links above).

## Open

- **`save:/Settings.sav` is never written.** The runner asks the language on every launch (`fs path not found: save:/Settings.sav`, then `save:/Settings.sav` is not on the RomFS either). `save:/WELLDWELLER/blob.sav` is written and committed (`save commit #1 … swapped atomically`), so the save mount works: the settings file is written on a clean quit, which the host's kill does not give the runner.
- **Verified up to the first room, its dialog and the pause menu** (OPTIONS with its CONTROLS/GRAPHICS/AUDIO/GAMEPLAY tabs, STATS, PAGES, MAP). Later rooms, the map itself and the save flow after a room are unverified.
- **Audio and video were not measured against each other** (the report of `DM_AUDIO_DUMP` shows music, and the video runs at 60 fps, but no lip-sync or cutscene timing was checked).
