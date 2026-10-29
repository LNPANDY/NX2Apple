# Paper Mario: The Thousand-Year Door (`0100ECD018EBE000`)

Update 1.0.1 (v65536), SDK 15.3.2. Intelligent Systems' engine on NintendoWare (G3d, Vfx, Atk) on NVN. Modules `main`, `subsdk0` (the SDK's movie library) and `sdk`; `sdk` is the build Celeste ships ([01002B30028F6000](../01002B30028F6000/README.md)). Playable on the iPhone since the spin waits ([CPU](#cpu)); 60 fps (30 on the Switch) through the host's frame step. On the Mac: the title, a new file, the storybook prologue, Peach in Rogueport, Mario's house, the letter and the boat into Rogueport, with Mario under control on the docks, with music and sound, at 60 fps and the game's normal speed; no crash in eight minutes.

## What it needs

| Setting | Where | Why |
|---|---|---|
| Frame step floor 2 → 1 | [`patches.py`](patches.py), `main` `0effe4af…` at `main+0x2e77a4` | with the floor at 2 a frame shown every vsync still stepped two vsyncs: double speed; see [Frame rate](#frame-rate) |
| Frame-step stub, `fps_target 60` | `patches.py` `FRAME_STEP` (site `main+0x2e77f8`), [`game.tsv`](game.tsv) | the base clock steps by the host's vsyncs, so game time = real time at any rate |
| `fps_hold off` | `game.tsv` | holding late frames left the render workers idle and the hold stuck at 20 fps |
| Allocator address space 62 GB → 4.06 GB | the host's StandardAllocator cap (`hle_svc.c`), every build | `StandardAllocator::Initialize(nullptr, 0xf80000000, false)` does not fit a phone; see [Memory](#memory) |
| Node area 1 GB → 62 MB, regions of 1 GB and more aligned to 32 MB | `dm/tools/sdk_patches.py`, `sdk` build `86188952…` (`sdk+0x12e0f0` / `+0x12e184`, `+0x12e2e0`) | Absolum's cuts on this build: the malloc region was placed 0.69 GB past the 1 GB node area |
| 5 GB block: `mem_reserve 0x140000000`, `mem_alias 0x118000000`, `mem_stack 0x10000000`, `app_pool 0xCD500000` | `game.tsv` | Engage's block: 256 MB in front + 4.375 GB alias region + 256 MB stack region + 128 MB heap region (never used) |
| `sys_resource 0x800000` | `game.tsv` | the NPDM declares 8 MB of system resource |
| `pad_layout full` | `game.tsv` | the D-pad opens the Gear and Journal menus (the HUD shows it in Rogueport): the iPhone pad starts in the 3D layout, which has one |

## Frame rate

- **Current:** 60 fps (30 on the Switch). The game asks for present interval 2, fixed at startup, and steps its clocks in 60 Hz vsyncs. Every frame `main+0x2e7750` measures the time since the last one (`oe::GetProgramTotalActiveTime`), rounds it to vsyncs and clamps it to [2, cap] (a step above cap + 10 counts as 2), and stores it as the base clock's step (time object +0x44, `main+0x2e77f8`). The base clock (time object +0x20, `main+0x2e753c`) advances by that step, the field and battle clocks below it by it times their scale, and game seconds by step / 60; timers, fades, animation and the scripts' frame counts follow the clocks.
- Presented every vsync without a change, it ran at double speed (each fade took half its time). With the floor cut to 1 alone, a frame time between one and two vsyncs rounded down to 1 ran the game slow whenever 60 did not hold (a run at 44 fps took 10–20% longer for each fade). The stub stores the host's step instead, the vsyncs the frame stays on screen (1 at 60 fps, 2 when 60 does not hold), and counts the vsyncs stepped; before the host has decided a step, and at target 0, the game's own. x16 and x17 are dead at the site. The log's `frame step: game time … of real time` reads 0.994–1.003. With `fps_target 60` the fades take as long as at 30 fps (the same press script, `DM_NVN_REGLUM` brightness curves).
- **`fps_hold off`:** the frame waits for its three render worker threads (`gfx::ParallelManager`), idle during a hold, so the cost of a frame grew with the hold (1.4 vsyncs at hold 1, 3.3 at hold 2 on a loaded Mac) and the hold stuck at 3 vsyncs, 20 fps; without holds the same load gave 32–58 fps at 0.994 of real time. `DM_FPS_HOLD=on` brings the holds back.
- `DM_FPS_TARGET=30` (`Documents/env.txt` on the iPhone) keeps the game's 30 fps.

## Startup

- **Resolved in the host; reporter confirmed iPhone startup:** black screen before the first frame, with the main thread at `main+0x32796c` and `SYS_Notification` waiting in the native notification HLE. See [Native HLE waits release the guest core](../../../docs/reference/threads.md#native-hle-waits-release-the-guest-core). Full gameplay was not revalidated.
- **Mac startup comparison, 2026-10-26:** the original notification HLE on host `1402ded2` reproduces the same stop at `main+0x32796c`, with the priority-28 `SYS_Notification` sleeping and the priority-44 main thread in its wake handoff; the no-progress watchdog exits at tick 0 after 15 s. With the host fix, the same extracted 1.0.1 game passes startup and runs for 70 s, beyond frame 2,100, then exits cleanly on request. This was a frame-loop test while the shaders were still compiling: missing libraries prevented visual validation. Logs are in the NSP folder's `0100ECD018EBE000-work/pr291/{unpatched-startup,fixed-startup}/game.log`, with separate fresh saves.
- **Open validation:** the first Mac shader build was stopped after the startup comparison, with reusable compiler outputs retained. Complete the normal `--platform mac` build before a visual gameplay run; that run and a new iPhone test remain open.

## CPU

- **Resolved: Rogueport at 24 fps on the first iPhone build:** frame p50 42 ms against 8 ms of GPU time, with the three `gfx::ParallelManager` workers (pinned to cores 0–2, priority 45) at 94% of a core each and the main thread waiting for them. `main+0xa8e680` is their loop. While a batch is pending, an idle worker polls the job cursor (`main+0xa8e784`) through a serial job, which only worker 1 runs, and through the end of a parallel-for, registering with it and backing out. The first worker to finish a parallel-for polls until the others are done (`main+0xa8e9a8`). None of these polls makes an SVC; the general spin wait rule now handles them.
- Results on the Rogueport route on the Mac, side by side with the committed build of the time under the same load: frame p95 29–37 → 18–22 ms, CPU 93–129% → 38–57% of a core, the workers 576–885 → 65–94 ms/s, CPU energy 22–32 → 11–17 mJ per frame. Loops found: 17 in `main`, 5 in `sdk`, 8 in `subsdk0`. Rewriting `main` takes 11.7 s of CPU instead of 20.5 ([development.md, Power](../../../docs/development.md#power)).

## Memory

- 8 MB of system resource (virtual address memory) and no heap: `main` never calls `SetMemoryHeapSize`.
- **Resolved: `nn::diag` abort at `sdk+0x11ff34` (`StandardAllocator::Initialize`) in `nninitStartup`** (called from `main+0x31370c`). `nninitStartup` (`main+0x3136b8`) makes the game's malloc a StandardAllocator over 62 GB of address space (`Initialize(nullptr, 0xf80000000, false)`, `main+0x3136e8`), out of which it cuts 256 MB, 16 MB and 1 MB allocators. Booted once with a 64 GB alias region, the region came 0.69 GB past the 1 GB node area, at the next 1 GB boundary: this `sdk` build (Celeste's, which has no virtual address memory) aligns regions of 1 GB and more to 1 GB, as Absolum's ([0100A83022A22000](../0100A83022A22000/README.md)) did. Absolum's three cuts on it (the AddressRegionManager constructor `sdk+0x12e0e0`: `+0x12e0f0` / `+0x12e184`; `AllocateAddressRegion` at `sdk+0x12e1d0`, its alignment at `+0x12e2e0`) and 4 GB of address space for the allocator (then a cut on `main`, as Pokémon Legends: Z-A's ([0100F43008C44000](../0100F43008C44000/README.md)); now the host's cap, 4.06 GB: below) put the region at alias +62 MB to +4.06 GB in Engage's 5 GB block. The pool (3.2 GB) bounds what it maps.
- **Current: the host's StandardAllocator cap, for every build; the `main` cut at `main+0x3136e8` is gone** ([StandardAllocators over 12 to 62 GB of address space](../../../docs/reference/memory.md#standardallocators-over-12-to-62-gb-of-address-space)). The gate at `StandardAllocator::Initialize` gives the 62 GB request 4.06 GB, what the 4.375 GB alias region has room for. Checked on 1.0.1 with the route into Rogueport's docks (480 s, frame 28,500), headless from a fresh save with the same keys, against the same build with the cut: the same frames reached, `[RED]` kinds and alias region use, screenshots of the same scenes (only animation and fade timing differ).
- The allocator maps 1.5 GB at boot and 2.0 GB by the arrival in Rogueport, under the hardware pool; about 2.4 GB resident on the Mac there.

## Rewriter

- **Resolved: `CRASH sig=10 addr=0` on an `stp` relative to `sp`, with `sp` not a multiple of 16** (`main+0x2bbba4`: `sub sp, sp, #0xc0` then `stp d15, d14, [sp, #0x60]` with sp ending in `…9dc`). Horizon leaves stack alignment checking off for user code; Apple's kernel faults on an sp-based access while sp is misaligned. The game's script engine (AngelScript) calls native functions through six hand-written bridges (`main+0x17c140` and five more beside it): each reserves the callee's stack arguments with `sub sp, sp, x19`, x19 being their sizes added up (4 for one int, `[x0 + 0x238]`), and gives them back with `add sp, sp, x19` after the call, so the callee ran with sp 4 bytes off. Of the 22 games' modules on hand then, only this `main` has the form (6 sites).

## Services

- **Resolved: abort in `sm::Initialize` under `nn::settings::GetAvailableLanguageCodes`** (early in `nnMain`, `main+0x327888`). The game asks for up to 32 codes and takes the index of `oe::GetDesiredLanguage`'s code in the list as its language. The host lists the system's codes in `nn::settings::Language` order, the table `LanguageCode::Make` uses (`hle_sdk16.c`). It was the one import of `main` that no host hook names and that reaches a service; `fs::MountRamDisk` and the swkbd and hid helpers it also imports run in `sdk` or were never called ([Listing a game's unhooked imports before they are met](../../../docs/reference/services.md#listing-a-games-unhooked-imports-before-they-are-met)).

## Rendering

11,858 shaders (3,154 vertex, 7,826 pixel, 874 compute, 4 domain), all BNSH; every one builds with Mario's binding layout ([Zstd files recognised by their magic](../../../docs/reference/shaders.md#zstd-files-recognised-by-their-magic)).

- **Resolved: a texture picked at run time between bound slots** (2,386 pixel shaders: 5,476 cube samples, 487 2D). The handle is read from the driver table of combined texture handles (c2 `0x20 + 8 × slot`, slots 0, 7, 8, 13 and 28, constant offsets only) and chosen by branches, so the translator falls back to an array indexed by the handle's texture ID. These read the whole texture and sampler pools now ([Texture handles from game memory index the pools](../../../docs/reference/shaders.md#texture-handles-from-game-memory-index-the-pools)), and the profile key `tex_dyn_slots`, which put slot indices in the table and bound slot k at element k, is gone. Checked on the Mac (2026-10-29): a fresh save through the prologue, Mario's house and the boat to Rogueport's docks, with no missing or wrong surface seen, at 60 fps; its cube pool held 15 textures.
- **Resolved: an array of handles in a uniform buffer** (the reflection shaders, `reflection.bfsha`: `array<texture2d<float>, 32> fp_t2d_cb14_0` and its samplers). A loop reads one handle per light from the game's uniform buffer c14 (uniform slot 11) at a computed offset; Ryujinx's texture array from a buffer indexes it by the handle's byte offset ÷ 8 (an NVN handle is 64-bit, the shader computes `(word >> 2) << 1 | (word & 3) >> 1`). The build read the name as one bindless texture (`tex_ubo`, offset 0), so the argument buffer was 32 entries longer than the reflection said and the host stopped at the shader's first load (`unexpected argument buffer layout: encodedLength=640 maxAid=48`). The first run with the fix showed elements 0–3, 6 and 8–12 holding textures, among them the shader's fixed handles at +8, +16 and +24 and the lights' from +64. No chain change: the build already wrote the array type.
- **Resolved: `nvnCommandBufferClearColori` / `ClearColorui`**: an integer target is cleared once Mario stands on Rogueport's docks, about frame 12,300 of a new file.
- **Resolved: a format-converting copy into a packaged texture** (a 128x128 RGBA8 render target into an RG8 texture, mirrored in Y, as the boat arrives in Rogueport, about frame 10,950): `copy_t2t_draw` declined a destination made without render-target use.
- **Resolved: an unbound uniform slot** (`stage 0 cb5 has no uniform buffer bound`, at the title): the argument buffer kept a null pointer there.
- Conditional rendering: the engine calls `SetRenderEnableConditional`; drawn unconditionally (the profile has no `render_cond`), no screen played looked wrong.
- The 4 domain shaders of `shaders/tessellation.bfsha` have no Metal stage; nothing seen so far draws with them.

## Movies

- `subsdk0` is the SDK's movie library: WebM movies (VP9 + Vorbis) through `movie::Extractor`, decoded by the host.

## Files and shaders

- Nearly every RomFS file is zstd, named `.zst` (8,726 of the RomFS's 9,959 files, the shader archives among them); `sound/sound.bfsar` is the profile's `romfs_marker`. The event scripts and data tables are ELF files the engine reads as data.
- Shaders: 8,993 in `shaders/*.bfsha.zst` and 2,865 in the particle effects (`effect/particle/*.ptcl.zst`). **Resolved:** `shader_split.py` decompressed only `.zs` files and found 0 shaders; it now goes by the zstd magic (`28 b5 2f fd`) whatever the name. Of the other 21 games' RomFS on hand then, only Super Mario Galaxy's `GDDR3.zst` had such a file.

## Input

- Buttons and sticks, docked (1920x1080). The 3D pad layout (`pad_layout full`).

## Mac routes

- A fresh save reaches Rogueport's docks with `DM_KEYS="35:A,45:A,55:A,65:A*195/2"` (the title, File 1, Start, then A every 2 s through the dialogue; Mario is under control at about 415 s, at 60 fps as at 30).

## Found on this game

General host changes first needed here; each applies to every game:

- **Blocking native HLE waits release the guest core:** [Native HLE waits release the guest core](../../../docs/reference/threads.md#native-hle-waits-release-the-guest-core).
- **Spin waits:** the rewriter copies pure poll loops and sends their back-edges through a gate that polls 2 ms, then sleeps (`patch_nso.py` "Spin waits", `dm_spin_wait`, `DM_SPIN`, `DM_SPIN_POLL`, `DM_SPIN_LIST`): [development.md, Power](../../../docs/development.md#power), [05, Scripted input and thread scheduling](../../../docs/agents/05-debugging.md#scripted-input-and-thread-scheduling).
- **`sub sp, sp, xN` rounded up to 16** (`site_sp_align`; `insn_census.py` counts the sites): [Stack arguments reserved with sub sp, sp, xN](../../../docs/reference/rewriter.md#stack-arguments-reserved-with-sub-sp-sp-xn).
- **Zstd by magic** in `shader_split.py`, **`tex_dyn_slots` for combined handles** (`tex_fit_elem`), **handle arrays in a uniform buffer** (`NVN_RB_TEXU` / `SAMPU` with `n`, array length from the MSL type), **integer clears** converted at replay, **render-target use for a copy destination** (`tex_upgrade`) and **an unbound uniform slot reading the all-zero bank**: [Zstd files recognised by their magic](../../../docs/reference/shaders.md#zstd-files-recognised-by-their-magic), [Texture slots picked at run time](../../../docs/reference/shaders.md#texture-slots-picked-at-run-time), [An array of handles in a uniform buffer](../../../docs/reference/shaders.md#an-array-of-handles-in-a-uniform-buffer), [Integer colour clears](../../../docs/reference/rendering.md#integer-colour-clears), [Render-target use added on demand](../../../docs/reference/rendering.md#render-target-use-added-on-demand), [An unbound uniform slot reads the zero bank](../../../docs/reference/rendering.md#an-unbound-uniform-slot-reads-the-zero-bank).
- **`nn::settings::GetAvailableLanguageCodes`** (`hle_sdk16.c`): [Available language codes and their count](../../../docs/reference/services.md#available-language-codes-and-their-count).
- **The host's StandardAllocator cap** (`hle_svc.c`, the `stdalloc_cap` key): [StandardAllocators over 12 to 62 GB of address space](../../../docs/reference/memory.md#standardallocators-over-12-to-62-gb-of-address-space).

## Open

- The 4 domain shaders of `shaders/tessellation.bfsha` have no Metal stage and the host does not run them; nothing seen so far draws with them.
