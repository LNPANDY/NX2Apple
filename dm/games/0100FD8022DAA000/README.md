# Super Mario Galaxy 2 (`0100FD8022DAA000`)

Update 1.4.0 (v393216) over the base game, SDK 18.3.5. NERD's Hagi Wii layer, as in Super Mario Galaxy ([010099C022B96000](../010099C022B96000/README.md)): the Wii game's PowerPC code is statically recompiled into `main`, and Hagi stands in for the Wii hardware (GX on **Vulkan** with SPIR-V generated at run time, the DSP, disc reads from the RomFS). Modules `main`, `subsdk0` (NintendoSDK_movie) and `sdk`, the last two Galaxy's builds; `subsdk1`–`subsdk4` (GLSLC, `nn::pcm`, NVIDIA's OpenGL and Vulkan drivers) are not loaded. Everything Galaxy needed from the Vulkan layer and the host carries over; the profile is Galaxy's with its own memory layout and shader list. Brought up on the Mac (the title, file select by touch, the opening and the first storybook stage at 59 fps) and plays on the iPhone.

## What it needs

| Setting | Where | Why |
|---|---|---|
| Node area cut 1 GB → 62 MB, and regions of 4 MB and more aligned to 2 MB as SDK 20 | `dm/tools/sdk_patches.py`, the SDK-wide rules (`MATCH_CUTS`) on `sdk` build `6075151627016eef…` (shared with Galaxy; its row, the node area cut alone, was removed on 2026-10-30 after a run on Monster Train 2, the same build) | the movie player's 384 MB allocator aborted the game at boot; see [Memory](#memory) |
| 1.25 GB block: `mem_reserve 0x50000000`, `mem_alias 0x20000000`, `mem_stack 0x10000000`, `app_pool 0xCD500000` | [`game.tsv`](game.tsv) | a 512 MB alias region for that allocator; the guessed 256 MB held nothing after the node area |
| `op_mode handheld` | `game.tsv` | the pointer (star bits, menus, the file select) is the touch screen in handheld mode; docked it is the Joy-Con gyro, which the host does not have |
| `pad_layout full` | `game.tsv` | the 3D gamepad layout |
| `modules main subsdk0 sdk` | `game.tsv` | `subsdk1`–`subsdk4` are replaced by the host's Vulkan layer |
| `vk_capture.tsv` | profile | the keys of the SPIR-V modules Hagi generates at run time, captured by the NSP script as for Galaxy |

## Memory

- `main`'s bss is about 2.6 GB (the emulated memory). NPDM system resource 8 MB. As in Galaxy: no `SetHeapSize`; the game's memory is `main`'s bss.
- **Resolved: `nn::diag` abort at boot** from `StandardAllocator::Initialize`, long after `nninitStartup`, right after the first Vulkan query pool (`sdk+0x12dad0` ← `main+0x62c52c`). The movie player initializes its own StandardAllocator with virtual address memory, `Initialize(nullptr, 0x18000000)` (384 MB, `main+0x62c280`); Galaxy, on the same SDK, allocates that block from its main allocator first. The guessed 256 MB alias region holds no region after the SDK's 1 GB address-region node area. Fixed by the node area cut for this `sdk` build (`sdk+0x13be4c` / `+0x13bee0`, shared with Galaxy) and a 512 MB alias region: the region is 32 MB aligned, so it starts 64 MB in.
- The block is 1.25 GB = 256 MB in front + 512 MB alias region + 256 MB stack region + 256 MB heap region; with `main`'s 2.7 GB image about 4 GB of address space, as Galaxy's.
- Footprint on the Mac (M4 Pro, the opening's first stage) 1.93 GB, flat from 2 to 5 minutes (1.0 GB of it Metal).

## Shaders

- 3,797 SPIR-V modules, all created about 7 s after launch (Galaxy: 3,089), captured by the NSP script as for Galaxy (`vk_capture.tsv`).
- The same two geometry shaders (GX points and lines) are skipped: those draws come out as one-pixel points and lines.
- `romfs_marker` is `hagi.config`.

## Rendering

- **Resolved (GitHub issue 72): the half of Mario facing the camera's left was white** on an iPhone. spirv-cross writes `FMin` / `FMax` / `FClamp` as `fast::min` / `max` / `clamp`, which leave a NaN operand's result to the GPU. Galaxy's GX lighting normalizes light directions the game leaves at (0, 0, 0) (the key and fill lights of its characters) and takes `max(0, dot(ldir, NaN))` as the spot term: 0 on the M4 Pro with either function, so the attenuation is 1. The fill light sits at the camera's left in view space, so its terminator runs down the middle of a character facing the camera. `vk_shaders.py` (and `dmsh_build.py`, `gl_shaders.py`) now write `precise::` functions, which return the other operand as Maxwell's `FMNMX` does.
- **Resolved (GitHub issue 68): a crash in `bind_res` on an iPhone when the ship took off after the first galaxy.** The replay binds every element of an array the shader takes, and a set may still name an image view the game has destroyed (the hardware reads a descriptor only when a draw samples it). The layer's descriptors were pointers to its own view, sampler and buffer structs; the crash read a freed view's texture from element 1 of the 8-texture array. A descriptor now holds the texture, sampler state and buffer it was written with (retained), as a hardware descriptor holds a copy of the handle. Through the opening and the first storybook stage the game allocates 22,785 descriptor sets and frees none, and destroys only 5 image views (and 1,244 images), so a stale element is rare: a Mac run that kept destroyed objects to catch their binds found none there.

## Frame rate

- **Resolved: on the iPhone only, a steady game's frame-rate counter wandered between 50 and 60.** The `display link up to tick` lines showed about as many empty ticks as frames dropped by merging: frames arrived two in one tick and none in the next. The Vulkan layer's acquire and the `vi::GetDisplayVsyncEvent` thread each kept a 60 Hz clock of their own, and Galaxy runs the Wii's VI retrace on that event, so its frames drifted against the screen. While the display link presents, both follow its ticks now (`hle_vk.m` acquire → `mtl_link_wait_tick`, as NVN's; `hle_sdk16.c` vsync thread → `mtl_link_wait_vsync`), with the old clocks as the fallback. A Mac window measures nothing here unless it is on screen: macOS fires an occluded window's display link about once a second (`display link recovered: stalled 1017 ms`).

## CPU

- Hagi's sleep poll (`main+0x11ec`) is one of the polls that keep x19–x28 between yields (the yield-progress rule, `thr_yield`).

## Background

Mac repro of both: `DM_OE_SCRIPT=bg=1@20,bg=0@25`. The game froze after switching apps and back, picture still, sound on, for two causes:

- **Resolved: the game's own pause deadlocked** (the main loop waits in its pause handshake, `main+0x5d10d4` / `main+0x5cea68`). The game sets focus handling mode 3, which the SDK (`oe::SetFocusHandlingMode`, SDK 18 `sdk+0x3c5770`) turns into "no focus notifications, the system suspends the game out of focus"; only modes 1 and 2 notify. The host sent message 15 anyway, and Galaxy 2's Wii layer ran a pause the console never triggers. `hle_oe.c` now queues 15 only under modes 1 and 2 (or when no mode was set).
- **Resolved: one guest thread at 100% after the return, in a tight loop** (`main+0x9abd0`, `x10 = 0`). The frame pacing measured a frame period of 0 (`main+0x5926a8`: the clock difference between two frames). The host froze the guest clock in the background but its threads went on, so two frames read the same time. Guest reads of the system counter (the `cntpct` gate, `svc GetSystemTick`) now wait while the app is in the background (`hle_os.c` `guest_clock_read_wait`).

## Damaged NSP

- The base NSP in hand fails the hash check on `data/texture_replace/MarioGalaxy.hix` and `MarioGalaxy_Sub.har`; it was packed with `--allow-damaged`.

## Mac routes

- From a fresh save, `DM_KEYS="f1600:A,f2000:T0.268x0.579,f2400:T0.641x0.778,f2800:T0.128x0.426,f3200:T0.641x0.778,f3600:T0.659x0.366,f4000:T0.8125x0.889,f4500:A*6/300,f6000:LRight+A~1.2*200/100,f6050:Y*200/100"` creates file 1 (Mario icon, Regular Mode), plays the opening and walks the first storybook stage to the spin tutorial and on (about frame 11,000). `DM_KEYS` runs its steps one after another, so a hold blocks the steps after it: walking and jumping go in one step (`LRight+A`).

## Found on this game

General host changes first needed here; each applies to every game:

- **`precise::` min / max / clamp** in every translator (`dmsh_build.py` `precise`, `vk_shaders.py`, `gl_shaders.py`; issue 72): [min, max and clamp with a NaN operand](../../../docs/reference/shaders.md#min-max-and-clamp-with-a-nan-operand).
- **Vulkan descriptors hold the Metal objects** (issue 68): [Descriptors hold the Metal objects they were written with](../../../docs/reference/rendering.md#descriptors-hold-the-metal-objects-they-were-written-with).
- **Vulkan acquire and the vsync event thread follow the display link** (`mtl_link_wait_tick`, `mtl_link_wait_vsync`): [Vulkan acquire and vsync event follow the display link](../../../docs/reference/frame-rate.md#vulkan-acquire-and-vsync-event-follow-the-display-link).
- **Focus message 15 only under focus handling modes 1 and 2** (`hle_oe.c`) and **the guest clock waits in the background** (`guest_clock_read_wait`): [Focus handling mode decides whether focus changes are notified](../../../docs/reference/services.md#focus-handling-mode-decides-whether-focus-changes-are-notified), [Guest clock reads wait while the app is in the background](../../../docs/reference/services.md#guest-clock-reads-wait-while-the-app-is-in-the-background).
- **A yield whose callee-saved registers moved counts as progress** (`thr_yield`; this game's poll keeps them): [Yields that make progress return at once](../../../docs/reference/threads.md#yields-that-make-progress-return-at-once-thr_yield).

## Open

- GX points and lines (the geometry shaders) are not translated; the player README lists one-pixel point and line effects as a known issue.
- `game.tsv` says values marked "Galaxy's" are not measured for this game; none of its rows is marked so.
