# Portal 2 (`0100ABD01785C000`)

Update 1.0.3 (`v196608`) over the base game, SDK 13.3.0. Valve's Source engine as NVIDIA Lightspeed Studios ported it to the Switch, the same port as [Portal](../01007BB017812000/README.md): `main` is a 1.7 MB launcher with SDL, and the engine is 21 NRO modules (`nro/*.nro` in the RomFS, registered by `.nrr/launcher_main.nrr`) loaded with `nn::ro`. It renders with NVN, its D3D9 layer linked into `materialsystem.nro`. Modules `main`, `subsdk0` (GLSLC) and `sdk`, the same `sdk` and `subsdk0` builds as Portal's; `subsdk1` is NVIDIA's OpenGL driver and is never loaded. No movie module: the title menu's background is a still scene.

**Current:** plays on the Mac at 60 fps: the title menu, New Game, Chapter 1 from the relaxation vault through the look and sleep prompts, Wheatley's arrival and the talk prompts, the whole container ride and the way out of it (the "Wake Up Call" achievement), with sound; one red line ([Rendering](#rendering)). GPU p50 about 2.4 ms on an Apple M6, NVN submit and present under 0.5 ms; footprint 2.25 GB in the ride, flat over its last 24,000 frames. Not yet built for or tested on an iPhone.

## What it needs

| Setting | Where | Why |
|---|---|---|
| `modules main subsdk0 sdk` | [`game.tsv`](game.tsv) | `main` imports from no subsdk; `materialsystem.nro` calls GLSLC ([Modules only the NROs import from](../../../docs/reference/services.md#modules-only-the-nros-import-from)) |
| 4 GB layout: `mem_reserve 0x100000000`, `mem_alias 0x10000000`, `mem_stack 0x10000000`, `app_pool 0xCD500000`, `sys_resource 0x0` | `game.tsv` | no system resource, so no virtual address memory; the game sets a heap in the 4 GB layout, as Portal does |
| `pad_layout full` | `game.tsv` | first-person: move with the left stick, look with the right |
| `shader_groups /game.zip/=game` | `game.tsv` | the shipped programs come from `game.zip`; the run-time captures go to `other` |

No `render_cond`: see [Rendering](#rendering).

## Rendering

- **Current, harmless:** `[RED] SetRenderEnableConditional: the host draws anyway for now` once a map loads. It is NVIDIA's occlusion culling in the D3D9 layer: `IDirect3DDevice9::SetOcclusionShape` (`materialsystem.nro+0xc1130`) puts each mesh whose bounding shape has a query under `SetRenderEnableConditional(RENDER_IF_NOT_EQUAL, pair)`, else `SetRenderEnable(true)` (cvars `nvn_occlusion_mindist`, `nvn_occlusion_prezdist`). Culling only skips hidden meshes, so drawing them all is the right picture at some GPU cost.
- **Open:** a host built with `render_cond on` evaluated those conditions as 0 / 0 (no report in the submission wrote the pairs; a memory dump later held `0xffff` / 0) and dropped the vault's desk, microwave, fridge, lamp, TV, plant and blinds ([Conditional rendering evaluated at replay](../../../docs/reference/rendering.md#conditional-rendering-evaluated-at-replay)). Who writes the pairs, and when, is not traced.
- About 1,100 NVN calls a frame in the vault.

## Shaders

- As Portal: the D3D9 layer keeps the GLSLC output of every program in the game's precache list in `nxcontent/nvsb/<hash>.nvsb` members of `game.zip`, and compiles the rest with `glslcCompile` ([GLSLC outputs in a zip archive, and those NROs compile at run time](../../../docs/reference/shaders.md#glslc-outputs-in-a-zip-archive-and-those-nros-compile-at-run-time)). The map has 1,186 keys: 1,175 from the `.nvsb` files (834 pixel, 341 vertex) and 11 from the 30 s capture boot (9 outputs).
- No `not in the shader map` line on the whole Chapter 1 route above.

## Files

- The whole game is `game.zip` (7.2 GB) beside the NROs; the Source file system reads it itself. The profile's `romfs_marker` is `game.zip`.
- The boot parameters are `nxcontent/rom_boot_params.txt` in the zip (`-game portal2 … -unlockchapters … +r_portal_stencil_depth 2`); `main` reads them out of the zip, so a `DM_ROMFS_OVERLAY` copy with `+map` changes nothing. `-unlockchapters` notwithstanding, chapters 2 and on show as locked on a fresh save.
- Only the merged update is registered. The base game's build has no profile row.

## Mac routes

- Work folder `<NSP folder>/0100ABD01785C000-work`: `run/boot.sh <log> [seconds] [VAR=value …]` (a renamed host copy, `build/p2host`), `run/ctl.sh` (`DM_CTL` lines, `snap NAME`, `wait S`), `intro1_ents.txt` (the entity lump of `sp_a1_intro1.bsp`, which tells what each scripted step waits for).
- From a fresh save: the title menu at about 35 s; `A` (Play Single Player), `A` (New Game), `A` (The Courtesy Call) loads `sp_a1_intro1` in about 8 s. `RUp~0.6` and `RDown~1.4` answer the look prompts, one at a time once each shows. Then walk round the bed's foot to the framed painting on the bed's wall and face it from close by (`ai_script_conditions` `stare_at_art_aisc`: within 140 units, in a 60° view); turn back to the bed and press `X` (Sleep).
- After the second wake-up: turn round, walk past the wardrobe to the hall door (it opens when you are near it and closes when you step back); `A` at Speak and `A` at Say Apple start the container ride (about two minutes). When it stops, turn left to the torn wall and walk out with a jump. The level exit is the departure elevator further on; not reached yet.
- `X` is use, `A` jump. The save from the end of the ride is the work folder's `save_ride` (no level save yet: Continue Game stays greyed).

## Found on this game

- [No audio input devices](../../../docs/reference/audio.md#no-audio-input-devices): `audio::AcquireAudioDeviceNotificationForInput` on the audio thread at start reached the `audren:u` service and aborted.
- [NVN in NROs under an SDL main that names GL](../../../docs/reference/rendering.md#nvn-in-nros-under-an-sdl-main-that-names-gl): the survey now reads the NROs as the build does.
- [Conditional rendering evaluated at replay](../../../docs/reference/rendering.md#conditional-rendering-evaluated-at-replay): NVIDIA's occlusion culling, and why the profile has no `render_cond`.

## Open

- The test chambers (portals, the portal gun from `sp_a1_intro3`, lasers in Chapter 2) are untested: reach them through the departure elevator.
- The `render_cond` evaluation above.
- An iPhone build and test.
