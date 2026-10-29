# EA SPORTS FC 27 (`0100C49025D3E000`)

Update 1.8d.310c (v393216), SDK 22.2.0, on NVN (API 55.15). **Frostbite** 2025.1.2 (`Info_Nx_retail.BuildSettings`): its data in superbundles (`.toc` tables, `.cas` files, Oodle Leviathan), its NVN renderer in an NRO the game loads at run time, `Engine.Render.Core2.PlatformNvn.nro` (with its symbol file `.nrs` beside it in the RomFS). Modules `main` (185.6 MB of text) and `sdk`; the NRO is collected from the RomFS and rewritten like them.

On the Mac (2026-10-29): the accessibility settings, the EA SPORTS and FC 27 logos, the title, the offline notice (no EA servers), the user agreement, the favourite-team setup, the main menu over its 3D training ground, Kick Off, and a Classic Match (Atlanta United v Orlando City at Mercedes-Benz Stadium): the stadium and crowd, the pre-match presentation (tifo, coaches, line-ups), kick-off, and the first half and into the second (67 minutes of match time) played with the pad (passing, shooting, a goal for Orlando, a corner, the in-game tactics tutorial). The game runs at 30 fps on the Switch; here menus and the match run at 60 ([Frame rate](#frame-rate)): frame time p50 16.7 ms, the match clock at its 30 fps rate. Resident memory stays at about 3.5 GB, GPU allocated 1.9 GB.

## What it needs

| Setting | Where | Why |
|---|---|---|
| 7 GB block with a 5.25 GB alias region: `mem_reserve 0x1c0000000`, `mem_alias 0x150000000`, `mem_stack 0x10000000`, `app_pool 0xCD500000` | [`game.tsv`](game.tsv) | Frostbite reserves its arenas as address regions ([Memory](#memory)); the heap region keeps the 1.25 GB the heap check measured (`main` asks for a 1.19 GB heap) |
| `sys_resource 0x600000` | `game.tsv` | the NPDM declares 6 MB of system resource: virtual address memory |
| `shader_key_skip 0x7d0+0x18` | `game.tsv` | the renderer's control-block cache ([Shaders](#shaders)) |
| `shader_groups /Data/=data /Patch/=patch` | `game.tsv` | the shaders are in the base data's and the update's cas files |
| [`dual_want.tsv`](dual_want.tsv) | profile | the six pixel shaders a match blends with their output 1 as the second source (dual-source blending), noted with `DM_NVN_DUAL_WANT` |
| `fps_target 60`, `present_interval display` | `game.tsv` | 60 fps: the host sets Frostbite's simulation rate and the game's frame regulator ([Frame rate](#frame-rate)); the game's present interval 2 is ignored |
| the node-area cut on `sdk` `fed212d6…` | [`dm/tools/sdk_patches.py`](../../tools/sdk_patches.py) | SDK 22's AddressRegionManager takes 1 GB of the alias region as its node area ([The SDK's address-region node area](../../../docs/reference/memory.md#the-sdks-address-region-node-area)); registered for this build, and the SDK-wide rule now covers SDK 22 |

## Files

- RomFS: 197 files, 31.8 GB, nearly all in `Data/NX` (the base game's superbundles and 18 install chunks of cas files) and `Patch/NX` (the update's); `Data/layout.toc` names the install chunks, `Data/initfs_NX` is encrypted (the game decrypts it). 83,325 bundles in all. `Scripts/BootIni/MemoryInit.ini` sets the engine's arenas; `oo2tex.key` is Oodle Texture's.
- The save is one container written through `save commit` lines; the game asks the accessibility settings on every start so far.

## Shaders

- **Current:** 7,873 shaders (1,520 vertex, 3,131 pixel, 3,222 compute) from the 10,401 `CompiledBytecode` resources of the bundles: [CompiledBytecode resources in Frostbite superbundles](../../../docs/reference/shaders.md#compiledbytecode-resources-in-frostbite-superbundles). The split decodes them with the game's own Oodle in the Mac host in about 30 s. All translate and compile for the Mac.
- **The control-block cache:** `fb::ShaderPlatformDataNvn` (renderer NRO) copies each shader's code into its pool and keeps one copy of each control section in a cache keyed by a hash that leaves out GLSLC's compile information (`s_controlBlockCacheMutex`), so a program gets the control section of the first shader with the same rest: at run time +0x7d0..+0x7e7 name another shader. Without `shader_key_skip`, 10 of the first menus' programs were not in the map (their code areas were the files', their control sections another resource's); with it the 10,342 keys are 7,873 shaders ([Control sections shared among shaders that differ only in their compile information](../../../docs/reference/shaders.md#control-sections-shared-among-shaders-that-differ-only-in-their-compile-information)).
- **Open:** the resources name no vertex / pixel pairs (Frostbite pairs them in its pipeline data), so there is no pipeline prebuild list; the prewarm list (`pso_manifest.tsv`) is empty.
- **Resolved:** `dc446d7f52c14ea6` (pixel; `[RED] … B binding fp_t2d_cb196610_10570000 has no resolved slot number`), met in a match, did not load. Its loop over separate texture slots i = 1, 2, … reads each handle word at c2 byte 0x168 + 8i and samples an array of c2 handles at element 45 + i (the handle's byte offset ÷ 8), with one separate sampler word (c2 byte 0x570) ORed into every handle; the translator's 32-element array clamped every index to 31, the build did not decode the sampler word, and it refused the loop's own read of each handle word at a computed c2 index → [Arrays of c2 handles cover the whole table, with a separate sampler word](../../../docs/reference/shaders.md#arrays-of-c2-handles-cover-the-whole-table-with-a-separate-sampler-word).
- **Open:** five shaders have a binding whose slot the build does not decode, and the translator leaves out seven (two with a bindless `texture2D` whose handle source it cannot find, four with `PrmtI`, one with `AtomCas`); none was met in the menus or a match.

## Memory

- Frostbite's `VirtualAlloc` (`main+0x17f9884`, `VirtualAlloc_Posix.cpp`) reserves each arena of `MemoryInit.ini` as an address region: 264 regions, 2.8 GB, in its first minute, three of them 512 MB, while it maps 0.7 GB. With the SDK's 1 GB node area they ran past the 4.38 GB alias region within seconds (`Couldn't reserve memory of size: 536870912 …`, then a deliberate store to address 0 at `main+0x17f98c4`). With the node-area cut they reach alias +3.5 GB at the title, +3.75 GB in the menus +4.25 GB 23 minutes into a match and +4.50 GB at 67 minutes (1.3 GB mapped) in a 4.75 GB alias region, hence the 5.25 GB one. Late in that match 655 live regions held 3.05 GB but spanned 4.52 GB: 1.41 GB lay in 654 gaps, nearly one after each region, as the SDK's AddressRegionManager placed them (open: whether the mark levels off over a whole match).
- Measured with a Switch-sized alias region (`DM_ALIAS_SIZE=0x1000000000`, `DM_REGIONS`).

## Frame rate

- **Current:** 60 fps in the menus and a Classic Match (1.8d.310c, Mac): frame time p50 16.66 ms, p95 18.2 ms; the match clock went 02:40 → 04:00 → 05:20 at 10.3 s steps, as at 30 fps (01:20 → 02:39). `fps_target 30` runs the game's own 30.
- **What sets 30 on the Switch:** three things, each needed. Frostbite's `SimulationTimeSettings` (`ForceSimRate` 30, `MaxSimFps` 30) caps the simulation's ticks; the game's frame regulator, an object at `[main+0xda20e38]` whose tick (`main+0x99ea580`) waits 1 / `[+0x8]` s from the last frame (the constructor sets 60.0 at `main+0x99e80c8`), gets 30.0 in `[+0x8]` and `[+0x10]` from `main+0x5d501c0` whenever `GameRenderSettings.Enable` is 1, a constant of this build; and `BaseDisplaySettings.PresentInterval` is 2.
- **What the host does:** the simulation settings are found by name in `main`'s reflection data, on any build ([Frostbite's simulation rate, found by name](../../../docs/reference/frame-rate.md#frostbites-simulation-rate-found-by-name)); the regulator is a build-gated row of `hle_fpslock.c` (the game sets 30 again at some screen changes; the host writes 60 back); `present_interval display` ignores the interval. Only the simulation and the regulator at 60 together give 60 at the right speed: the regulator and present interval alone gave 60 frames a second with the match clock at half speed (3.65 game seconds a second); the simulation at 60 with the regulator at 30 (a build without the row) gives 30 fps at the right speed.
- **Not needed:** `GameplayFeatures.DeltaTicks` (4.0; it becomes the int at `main+0xd10b6d8` that sets the gameplay rate `60 / DeltaTicks` at `[regulator]+0x1e54c`) stays as the game sets it. Forcing that int to 1 instead crashed the match at kick-off (`main+0x4ccd66c`).
- **Open:** a new build needs the regulator row carried over (`nso_fnmap.py`, then check `main+0x5d501c0` and the regulator's global by disassembly): `main` has unwind entries for only 405 functions, so a function-matched cut cannot follow it. Until then such a build runs at 30 fps at the right speed.

## On the Mac

- After the NSP script's `--platform mac` build, its printed command runs the game; the work folder's `run/boot.sh <log> [secs] [VAR=…]` runs a renamed copy of the host (`build/fchost`); `run/ctl.sh "snap NAME" "A" "wait 3" …` drives a run started with `DM_CTL=<work>/run/ctl.txt DM_PRESENT_LINK=0`.
- First start: the accessibility settings are up about 15 s after start. A (Continue), A (skip the logo), A (Let's Play!), A (OK on the offline notice), A (Continue on the user agreement), A, A, A (country, league, club of the favourite team), then the main menu; B closes its welcome panel, Down four times selects Kick Off.
- With that save (the work folder's `run/save`): the title is up about 20 s after start; A, A (title, offline notice), Down four times and A (Kick Off), A (Classic Match), A (Start Match), A (the difficulty notice), about 45 s of loading, then hold A (`A~2.5`) twice to skip the presentation. The left stick moves, A passes, B shoots.

## Found on this game

General changes first needed here; each applies to every game on the same path:

- **Resolved: a text longer than a branch reaches** (185.6 MB): the rewriter splits the patch area in two → [Two patch areas for a text longer than a branch reaches](../../../docs/reference/rewriter.md#two-patch-areas-for-a-text-longer-than-a-branch-reaches).
- **Resolved: no shader container found** → [CompiledBytecode resources in Frostbite superbundles](../../../docs/reference/shaders.md#compiledbytecode-resources-in-frostbite-superbundles) (`dm/gfx/tools/frostbite.py`).
- **Resolved: `vi::CreateLayer` with `LayerCreationSettings` (SDK 22)** → [`vi::CreateLayer` with `LayerCreationSettings` (SDK 22)](../../../docs/reference/services.md#vicreatelayer-with-layercreationsettings-sdk-22).
- **Resolved: builder storage getters** (`nvnTextureBuilderGetMemoryOffset`, `…GetRawStorageClass`) → [Builder storage getters](../../../docs/reference/nvn-objects.md#builder-storage-getters).
- **Resolved: the SDK 22 node area** → [The SDK's address-region node area](../../../docs/reference/memory.md#the-sdks-address-region-node-area).
- **Resolved: a depth plane copied into a depth-only texture** → [Depth plane copies between depth formats](../../../docs/reference/rendering.md#depth-plane-copies-between-depth-formats).
- **Resolved: 30 fps** (the simulation rate) → [Frostbite's simulation rate, found by name](../../../docs/reference/frame-rate.md#frostbites-simulation-rate-found-by-name).
- **Resolved: a shader with an array of c2 handles and a separate sampler word** (its lights) → [Arrays of c2 handles cover the whole table, with a separate sampler word](../../../docs/reference/shaders.md#arrays-of-c2-handles-cover-the-whole-table-with-a-separate-sampler-word).
- **Resolved: `[RED] sampler ID 4096 not registered`** at the title, separate textures bound with bit 32 set → [Bound handles are the driver's 32-bit words](../../../docs/reference/nvn-objects.md#bound-handles-are-the-drivers-32-bit-words).
- **Resolved: a copy to address 0 at the match load**, `nvnBufferMap` of a GPU-only buffer → [`Map` of a pool without CPU access returns NULL](../../../docs/reference/nvn-objects.md#map-of-a-pool-without-cpu-access-returns-null).

## Open

- **iPhone:** not built or tested. The 7 GB block is more than the 5 GB proven on a phone without the extended-virtual-addressing entitlement, so the game's arenas likely need less address space there (open: whether its command line or `MemoryInit.ini` can size them).
- **Gameplay:** a whole match, its result screens, other modes (Career, Ultimate Team offline parts, Tournaments), other stadiums and weather, local multiplayer and other languages are untested.
- Online play needs EA's servers: offline only.
