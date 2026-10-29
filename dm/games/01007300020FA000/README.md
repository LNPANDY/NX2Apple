# ASTRAL CHAIN (`01007300020FA000`)

Update 1.0.1 (v65536) over the base game. PlatinumGames' engine, SDK 6.4.0, NVN, Wwise audio through `AudioOut`; modules `main` and `sdk`. The 1.0.1 profile enables a 60 fps gameplay target with corrected game timing; fixed-step cinematics retain 30 fps. Mac testing completes motorcycle combat and reaches the first on-foot checkpoint. An unsigned IPA builds; iPhone testing is pending.

## What it needs

| Setting | Where | Why |
|---|---|---|
| `mem_reserve 0xf0000000`, `mem_alias 0x10000000`, `mem_stack 0x10000000`, `app_pool 0xCD500000` | [`game.tsv`](game.tsv) | 3 GB heap region; the first Mac boot requests 2.96 GB, with the game's 191 MB BSS counted as used memory |
| `sys_resource 0x0` | `game.tsv` | the NPDM declares no system resource; no virtual address memory |
| `pad_layout full` | `game.tsv` | movement and camera use both sticks |
| `fps_target 60` | `game.tsv`, [`patches.py`](patches.py) | host-paced gameplay with fractional timer carry, integer input windows and camera smoothing; only the verified 1.0.1 main build |
| `depth_mode zero` | `game.tsv` | the game sets the near = 0 depth mode, so the pipeline bases made before it runs (the NSP script's Mac prebuild, and a [pipeline archive made offline](../../../docs/development.md#the-pipeline-archive-made-offline) for the iPhone when one is built with `DM_PSO_GPUS`) take its vertex shaders' `main0_z` entries (the host itself follows the mode the game sets) |

## Files and shaders

- 82 PKZ archives, version `0x10000`, holding 8,556 Zstandard-compressed entries, alongside Bink 2 movies (`.bk2`) and Wwise banks and streams. The PKZ directory and name-table layout matches version `0x20000`; every entry's bounds were checked and one entry per archive was decoded before extending the reader.
- `root.pkz` contains PlatinumGames DAT shader archives. The full split finds 1,348 distinct shaders: 540 vertex, 738 pixel, 70 compute. Single-stage programs produce 1,620 cover pairs. All 1,348 compile for Mac and iOS, with zero undecoded bindings and zero unfillable driver-bank reads.
- GPU code versions in the root shader archives include 1.9, 1.12 and 1.15, despite the linked SDK being 6.4.0. The game sets upper-left window origin, near-zero depth, a 1600×900 swap chain and present interval 2.

## Services and SDK

- **Resolved: startup fails, then cleanup reads null at `main+0x9c0d1c`.** `main+0x40d6c0` loads `hwfillcolor`; its vertex shader is version 1.15. The shader loader compares byte 7 with the driver's newest minor at `main+0x9e97d0` and rejects the old answer 1.14. A probe at `main+0x9dcf28` confirms failure before the subsequent cleanup crash. The host now advertises the translator's supported GPU-code range independently of the linked SDK. No game-code cut is needed.
- [Issue #170](https://github.com/seedds/nxnative/issues/170) independently reports the same initialization crash and PKZ version. Its shader-map generic-type warning was also confirmed: `g_shmap` holds strings, and its declaration now agrees. Its translator source-hash failure was not reproduced; the pinned translator built all shaders without rebuilding the translator.

## Status on the Mac

- ZL+ZR prompt, logos, opening real-time cinematic, character creation (including software-keyboard naming), save creation/reload and the motorcycle tutorial render on an M4 Pro. The original 30 fps run had a warm frame median of 33.34 ms. The 60 fps validation and its limits are below.
- Wwise opens a stereo `AudioOut`; the 15-minute `play03` run reaches 84,000 device callbacks with zero reported underruns. Resident memory grows from 1.44 GB at the title to 2.57 GB on entering the tutorial; Metal allocated memory is about 3.02 GB there.
- The first boot rendered in a Mac window. A later windowed run stalled in the display link; the sustained measurements and screenshots use `DM_WINDOW` unset and `DM_PRESENT_LINK=0`. They measure offscreen native rendering, not on-screen presentation quality.
- **Current:** entering the motorcycle scene reports one cube/2D texture mismatch, handled by the existing [zero-cube fallback](../../../docs/reference/rendering.md#a-2d-texture-in-a-cube-slot-binds-the-zero-cube). The scene renders, but that binding has not been traced to establish whether it is an intentional placeholder.
- Work folder: `/Volumes/T7/nsp/ASTRAL CHAIN/01007300020FA000-work`. `run/boot.py <log-name> <seconds> [KEY=VALUE ...]` launches a bounded run, with its control file at `run/<log-name>.ctl`, logs and saves beside it. The build artifacts and extracted data are in the adjacent `01007300020FA000_build`.

## Frame rate

**Current: 60 fps gameplay target on 1.0.1**, main build `4b159f0f7a360669738390ee8657b4f0`. The profile uses the host's frame step and pacing instead of simply overriding present interval 2. `DM_FPS_TARGET=30` selects a 30 fps cap with the same timing; `DM_FPS_TARGET=0` executes the original instructions at every hook.

**Resolved: half-frame steps stop integer timers.** The earlier four-cut [FPSLocker experiment](https://github.com/masagrator/FPSLocker-Warehouse/blob/v4/SaltySD/plugins/FPSLocker/patches/01007300020FA000/4B159F0F7A360669.yaml) raised the title frame rate, but `main+0x48be14` and `main+0x57e7e0` truncated the half-frame step to zero. The new clock stores the floating 30 Hz step at clock `+0xd0`, carries fractional ticks at `+0xd4` and publishes whole ticks at `+0xd8`. Both 60 half-step updates and 30 full-step updates advance integer timers by 30 ticks. Action/input windows, hit-stop, pad repeat and rumble counters consume those whole ticks; camera interpolation uses elapsed-time decay.

The timer and camera helpers are adapted from the MIT-licensed [AstralChain-Dynamic-FPS v1.1.1](https://github.com/yogesh1239/AstralChain-Dynamic-FPS/tree/79965b4df077f64b27b74456d0db88c6afac5bbe), with its license retained in `patches.py`. Its measured-time core and interval overrides are replaced by a host-paced clock. All 112 hook sites check their original bytes, and the complete set is build-ID gated. Helpers are relocated into the rewriter's allocated patch area rather than overwriting the upstream code caves. With this main's 191 MB BSS, helpers sit before the module base; frame state is at `main+0xccec000`, image size `0xccf0000` (the general allocation fix is linked below).

The engine's fixed-step mode (`w21 == 0` at `main+0x91dc10`) sets the host's 30 fps cinematic flag and a two-vsync step. Variable-step gameplay releases that cap and consumes the host's chosen step, including catch-up after late frames. This preserves the fixed-step mode's original clock rather than forcing every cinematic to 60 fps. Other real-time cinematics can use the engine's variable-step mode. Audio/video synchronization across all movies has not been verified; the upstream patch reports some remaining drift and incomplete timer coverage.

Validation on the M4 Pro:

- ARM64 execution tests run the emitted stubs without game files: fractional carry, integer consumers (including the zero-tick branch), first-sample initialization, cinematic cap/release, input-window duration and flags, original behavior with target 0, and camera decay after equal elapsed time. The original integer conversion failed the 60-half-step check before the fix.
- Native `timing61` loads a save, passes character creation, completes motorcycle combat with firing, steering and evasion, and reaches the first on-foot checkpoint. Movement and camera rendering work there, with sampled windows reaching 60.0 fps. The warmed title holds 60 fps (16.6 ms median); the fixed-step opening cinematic changes to 30 and character creation releases the cap to 60. Motorcycle rendering reaches 59.7 fps but also dips under concurrent machine load; sustained 60 fps throughout gameplay is not established.
- Host telemetry records 30.00 game seconds in 30.00 real seconds in a 60 fps window. With adaptive holds during motorcycle combat, representative windows are 40.98/40.87 and 61.05/60.93 seconds (ratios 1.003 and 1.002). This checks clock speed, not all combat mechanics or on-screen presentation. Later stalls can exhaust catch-up; it is not an unlimited compensation for arbitrary pauses.
- The run uses offscreen native rendering as described above. Later Legion combat, Bink movies, end credits and iPhone performance remain untested.

## Found on this game

- [Frame-step state with a front patch area](../../../docs/reference/rewriter.md#frame-step-state-with-a-front-patch-area).
- [PKZ version 1 archives](../../../docs/reference/shaders.md#pkz-version-1-archives).
- [Newest GPU code version reported by the driver](../../../docs/reference/nvn-objects.md#newest-gpu-code-version-reported-by-the-driver): precompiled shader versions do not follow the linked SDK.
- [The alpha test through a library of its own](../../../docs/reference/rendering.md#the-alpha-test-through-a-library-of-its-own): the death effect's tendrils (`EffectOpacityBlood`, alpha written by the shader, no `discard`) stayed solid black; reported on PR #32 with an implementation of its own (358 of one frame's 3,048 draws alpha-tested, function 5, GREATER).

## Open

- Check the death effect's tendrils with the host's alpha test (reported fixed on PR #32 with another implementation).
- Validate the unsigned IPA on an iPhone, including memory pressure and touch controls.
- Trace the tutorial's cube placeholder and validate visible effects against the original game.
- Validate later combat input windows, camera behavior and cinematic audio/video sync with the 60 fps profile; establish sustained performance without competing workloads.
- Later levels and Bink movies are untested.
