# SHIN MEGAMI TENSEI V: Vengeance (`010069C01AB82000`)

Update 1.0.3 (v196608) over the base cartridge dump. Atlus, Unreal Engine 4.27 (`++UE4+Release-4.27`), SDK 15.3.2, NVN, CRIWARE. Modules `main`, `subsdk0` (NintendoSDK_movie) and `sdk`; the SDK and movie builds are the same as Paper Mario: The Thousand-Year Door 1.0.1.

Status (2026-10-26): opening gameplay tested on the Mac with the capped memory layout: new game on Normal, Canon of Creation, classroom movement, NPC dialogue, saving and loading that save in a fresh process, the Tokyo map, then Shinagawa Station with movement, right-stick camera control, a second save and the station event that follows. 60 fps on the Mac (30 on the Switch) by the host's writes of Unreal's frame limits: [Frame rate](#frame-rate). iOS and combat are untested.

## What it needs

| Setting | Where | Why |
|---|---|---|
| FMallocBinned3 constructor call cut at `main+0x1f2f63c`, with gate `OBS_UE_MALLOC` on it | the rewriter's engine-wide rule (`dm/tools/ue_malloc.py`), no build ID, `hle_uemalloc.c` | its 37 GB pool reservation cannot fit the iPhone address space; the host supplies the UE4 allocator vtable. Until 2026-10-30 this build's own cut, with the gate at `+0x1f2f644` (checked on its main from the archive drive) |
| Engine region given what the alias region has room for, 2.81 GB: gate `OBS_UE_REGION` on the store of its size, `main+0x1b89034` | the rewriter's engine-wide rule (`dm/tools/ue_region.py`), no build ID; the host's room (`hle_svc.c`) | Unreal's `nninitStartup` reserves 62 GB by default. Until 2026-10-31 `game_args -SwitchVirtualAddressSpaceSize=2048`, a 2 GB region |
| `mem_reserve 0xF0000000`, `mem_alias 0xC8000000`, 256 MB stacks | `game.tsv` | a 3.75 GB guest block with a 2 GB engine region and a 128 MB heap region; the C library heap request is 6 MB |
| `sys_resource 0x2800000` | `game.tsv` | the NPDM declares 40 MB of system resource |
| Node-area and large-region alignment cuts | `dm/tools/sdk_patches.py` SDK-wide rules, SDK build `86188952…` | the SDK-wide rules' cuts on this build: 62 MB node area, 2 MB region alignment (SDK 20's) |
| `pad_layout full` | `game.tsv` | both sticks and the D-pad for the 3D game |
| `fps_target 60`, `ue_fps_cvar Project.FrameRateLimit` | `game.tsv`, `hle_fpslock.c` | the host writes 60 into `Project.FrameRateLimit` and 1 into `rhi.SyncInterval`, which the rewriter finds by name (`dm/tools/ue_cvar.py`); see [Frame rate](#frame-rate) |

## Frame rate

- **Current:** 60 fps on the Mac (30 on the Switch). The paks cap the game at 30 twice: `Project.FrameRateLimit=30` in `Project/Platforms/Switch/Config/SwitchDeviceProfiles.ini` and `rhi.syncinterval=2` in `Engine/Platforms/Switch/Config/BaseSwitchDeviceProfiles.ini`, with `r.VSync=1`. `DefaultEngine.ini` has `bUseFixedFrameRate=False` (its `FixedFrameRate=30` is inactive).
- `Project.FrameRateLimit` is the game's own float console variable (`TAutoConsoleVariable` at `main+0x6d6d5d0`, registered at `+0xdd8624`, UTF-16 name at `+0x538ac96`). Its callbacks (`+0xdd7d24`, `+0xdd7f94`) read the value, store it into GameUserSettings' `FrameRateLimit` (+0xb4, the object from `GEngine` at `+0x7ad5ab0`) and apply the settings, which set `t.MaxFPS` (`+0x7ad5848`, registered at `+0x3a7be94`). The host therefore writes the project variable, not `t.MaxFPS`: with only it at 60 and `rhi.SyncInterval` (`+0x796de10`, registered at `+0x2aa0754`) at 1, `t.MaxFPS` read 60 in both copies before anything wrote it. The rewriter finds both by their registered names (`dm/tools/ue_cvar.py`, at exactly these objects); the profile key `ue_fps_cvar` names the project variable instead of `t.MaxFPS` (two rows gated on main build `0a4f14a5…` until 2026-10-30). The boot log shows each copy `30 → 60` and `2 → 1`.
- Unreal steps the game by the time that really passed. From the same slot 2 start, a 1 s hold of the left stick right ends at the same place on the floor and minimap at 30 and 60 fps (`run/w30_walk.png`, `run/w60_walk.png`); the difference is within a frame or two of input timing.
- Measured on the Mac (M4 Pro, host from `main` at 4639c51 with this port): the title holds 16.7 ms (p95 16.9 ms); Shinagawa Station with the objective prompt open, during the station event and while walking and turning the camera runs 59.2–60.1 fps per window, frame p50 16.6–16.8 / p95 17.5–20.3 ms, GPU p50 6–8 ms, about 2.6 GB resident and 1.3 GB of Metal allocations. Single 60 ms frames 3.5 s apart in `run/smvw60.log` are the `DM_CTL` screenshots, not the game. No red line.
- **Resolved:** with the host and rewriter at 435a231 (before this port was moved onto `main`), the same 60 fps route stalled in nearly every 300-frame window (p95 50–80 ms, maxima 150–250 ms, about 37 fps over 30 minutes) while the CPU was mostly idle and the GPU took about 6 ms. The 30 fps runs on that host were flat. The stalls are absent on the current host and rewriter; the commits between them that fixed this were not bisected (candidates include the fence-wake and same-core handoff changes).
- `DM_FPS_TARGET=30` (`Documents/env.txt` on the iPhone) keeps the game's own 30 and saves power.

## Memory

- **Current:** `nninitStartup` is `main+0x1b88a10`. It parses `-SwitchVirtualAddressSpaceSize=` with a value up to 4095 interpreted as MB (`+0x1b88d58`), and always calls `AllocateAddressRegion` (`+0x1b89038`) after choosing the requested or default size; the rewriter's gate on the size's store before it (`+0x1b89034`) gives the region what the alias region has room for, 2.81 GB ([Unreal's engine address region and its options](../../../docs/reference/memory.md#unreals-engine-address-region-and-its-options)). It requests a 6 MB C-library heap at `+0x1b89060`.
- **Resolved by the allocator replacement:** `GCreateMalloc` (`+0x1f2f610`) mallocs 0x1c38 bytes, keeps the object in x19, calls `FMallocBinned3`'s constructor (`+0x1578bc0`) and stores GMalloc at `+0x72c1b10`. The constructor stores vtable `+0x5a7f0a8` and reserves `0x940000000` bytes at `+0x15790b0`. A baseline maps up to +38.5 GB; limiting the region to 2 GB without the replacement crashes during static initialization in the error-report path (`+0x294eb98`, a read from `0x30c0`). The measured vtable has the UE4 layout: TryMalloc / TryRealloc call slots 3 / 5; slots 17 and 18 return 1, slot 19 returns `Binned3`, and there is no OnMallocInitialized slot. See [Unreal's FMallocBinned3 replaced by the host allocator](../../../docs/reference/memory.md#unreals-fmallocbinned3-replaced-by-the-host-allocator).

## Files and shaders

- Six Unreal paks under `Project/Content/Paks`, 13.69 GB in total. The shaders are inline in cooked packages, their Oodle blocks decoded with the game's own decoder and shaders read by `uepak.py` / `shader_split.py` as for [OCTOPATH TRAVELER II](../0100A3501946E000/README.md). The split yields 19,746 unique shaders: 7,966 vertex, 11,058 pixel, 673 compute and 49 geometry. Each vertex shader is linked with a pixel-output cover (`separable_pairs`).
- Seven DLC licences (indices 1–7), each with no RomFS content. Extraction completed without NCA hash errors, including the six files whose names contain `[ERROR]`.
- The supplied NACP supports American English, French, German, Spanish, Italian, Russian and Brazilian Portuguese. The default is American English.

## Rendering

- **Resolved:** two global compute shaders (`2d2093c1f1d3a7e0`, `4fe56176fa5a5dc6`) dispatched at boot failed translation. They use `IGN` buffer-image atomics and consume the returned old value, which the Metal path previously rejected. The general translator now preserves that value, with a zero result and no memory access outside the image: [Bounds of image atomics](../../../docs/reference/shaders.md#bounds-of-image-atomics). Synthetic SPIR-V, Mac/iOS Metal and Mac GPU result/sentinel checks pass. All 19,746 shaders build for both Mac and iOS with chain `86c8282f6fb4`; one folded geometry stage needs no separate Metal library.
- **Resolved:** the first dispatch then failed image admission because reflection classified `texture_buffer` as 2D. Preserving its actual Metal type binds the real four-byte counter storage: [Buffer image reflection keeps its texture type](../../../docs/reference/shaders.md#buffer-image-reflection-keeps-its-texture-type). The corrected Mac runs have no `[RED]` diagnostics through the tested opening.

## Mac runs

The NSP script's build directory is `<NSP folder>/010069C01AB82000_build`; analysis, diagnostic runs and saves are in the sibling `010069C01AB82000-work`. `run/boot-final.sh <log name> <seconds> [VAR=value ...]` runs the current host and shader libraries with isolated saves. A time-limited run's `CRASH sig=14` is its alarm. `DM_CTL` drives input and screenshots; `DM_KBD=Player` supplies the test name.

- **Route:** dismiss the seven first-run DLC notices with B; New Game, Normal, then select Yes (Up, A). Plus opens a cutscene skip prompt, also defaulting to No. Hold the left stick right while pressing A (`LRight+A~3` in `DM_CTL`) to choose not to take the girl's hand, then close the story explanation with B. Skip the classroom scene and close the movement/minimap tutorials. Talk to the three marked groups, then follow the objective at the door. Y + held X advances ordinary dialogue. The D-pad's Left opens Save; slot 1 survives a process restart and loads through Load Game. After the courtyard scene, head south on the Tokyo map and enter Shinagawa: West to reach the station. Slot 2 holds that checkpoint.
- **Performance at 30 fps** (before `fps_target 60`; 60 fps results are under [Frame rate](#frame-rate)): the classroom settles around 33.33 ms per frame, approximately 2.5–2.6 GB resident and 1.4 GB GPU allocations over more than ten minutes; alias mapping reaches 1.25 GB of the 3.125 GB region. The later station settles near 3.3 GB resident, 1.4 GB GPU allocations and 1.76 GB alias mapping, still around 30 fps. First visits have shader/pipeline and loading stalls; these measurements are opening-area observations, not a whole-game bound.
- **Audio:** the real Mac output path (`DM_AUDIO=1`) runs with nonzero six-channel PCM from CRI's AudioOut and regular device callbacks. The separate 32 kHz AudioRenderer is silent in this opening, so its zero-sample count does not describe the game's CRI audio. Audio quality has not been assessed by listening.
- **Validation:** the tool suite passes (186 tests on `main` at 4639c51 with this port, six optional skips), as do the dedicated returning-atomic tests with both Metal SDKs and GPU sentinel checks, reflection fixtures, image-binding/layout checks and the memory-profile check.

## Found on this game

- **Provisional Unreal profiles leave room for the initial heap** (`profile_guess.py`): [Provisional Unreal layout leaves no heap](../../../docs/reference/memory.md#provisional-unreal-layout-leaves-no-heap).
- **Returning `IGN` image atomics** (the offline translator, `t_atomic_return.m`): [Bounds of image atomics](../../../docs/reference/shaders.md#bounds-of-image-atomics).
- **A game's own frame-limit variable written instead of `t.MaxFPS`** (profile key `ue_fps_cvar`, `hle_fpslock.c`): [Unreal's frame limit and present interval, found by name](../../../docs/reference/frame-rate.md#unreals-frame-limit-and-present-interval-found-by-name).
- **Buffer-image reflection preserves its Metal texture type** (`nvn_refl.m`, `t_refl.m`): [Buffer image reflection keeps its texture type](../../../docs/reference/shaders.md#buffer-image-reflection-keeps-its-texture-type).

## Open

- The engine region's gate (2.81 GB instead of the 2 GB `game_args` gave) has not been run on this game yet: the `[mem] Unreal's engine region` line in a boot's log shows it.
- Combat, later areas and the Canon of Vengeance route remain untested, at either frame rate.
- 60 fps on an iPhone is not tested yet.
- The unsigned IPA is built beside the source dumps. Device testing remains the user's next step; no device installation or signing is performed.
