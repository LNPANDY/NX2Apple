# Super Mario Party Jamboree (`0100965017338000`)

Update 2.3.0 (`v458752`), SDK 17.5.9. NintendoWare Bezel Engine 2.9 on NVN, by NDcube. Modules `main`, `subsdk0` (NintendoSDK_movie) and `sdk`; the boards, minigames and modes are 139 NROs (`nro/NX_Release/*.nro`, registered by one NRR) that the game loads with `ro::LoadModule`. No `patches.py`: the standard rewriter covers `main`, `sdk` and every NRO.

On the Mac (headless, docked): from a fresh save the opening movie with sound, the title, the player count and character setup, the Party Plaza with Toad's tour, the island map, and Mario Party on Mega Wiggler's Tree Party with CPU opponents: the turn-order roll, the dice block, moving on the board, the item shop, the 4-player minigame Snag the Flags (rules, practice and the match), its results, the save and turn 2. 60 fps on the board (frame time p99 about 18 ms), no crash, no `[RED]` line beyond those below. A shorter test than usual, at the user's request: one board, one minigame. Not tested on the iPhone: no IPA was built.

## What it needs

| Setting | Where | Why |
|---|---|---|
| `sys_resource 0`, 4 GB layout (`mem_reserve 0x100000000`, `mem_alias 0x10000000`, `mem_stack 0x10000000`), `app_pool 0xCD500000` | [`game.tsv`](game.tsv) | the game's heap path: a 3.14 GB heap, 32 MB of it malloc's and the rest Bezel's. Its virtual-memory path needs about 5.2 GB of alias region; see [Memory](#memory) |
| `depth_mode zero` | `game.tsv` | the game sets near = 0, so the prebuilt pipeline bases take the `main0_z` vertex entries; without it the NSP script's prebuild did not match and the first start built all 20,541 bases again |
| `modules main subsdk0 sdk` | `game.tsv` | `subsdk0` is NintendoSDK_movie |
| `romfs_marker boot.nbinit` | `game.tsv` | Bezel's boot file at the RomFS root |
| `shader_groups /Archive/=archive` | `game.tsv` | every archive shader is under `Archive/` |

## Memory

- **Resolved: null from `nn::bezel::CoreSystem::Allocate` as the Party Plaza or a menu loads.** The provisional profile (16 MB system resource, so virtual address memory; 5 GB block, 4.375 GB alias region) crashed at `main+0x8d9a48` writing past a null 46 MB block, or first read a file into a null 4 MB buffer (`[RED] fs ReadFile into 0x0+0x400000 failed at +0 (EFAULT)`). `nninitStartup` (`main+0x98281c`) is Big Brain Academy's: with virtual address memory, malloc's StandardAllocator gets 2 GB of address space (`main+0x982838`) and Bezel's asks for 56 GB (`main+0x982968`), which the host's allocator gate lowered to the 2.06 GB left. Measured with a 64 GB alias region (`DM_ALIAS_SIZE=0x1000000000 DM_ALIAS_WINDOWS=512`): malloc's region held 5 MB, Bezel's 2.3 GB at the plaza (850 MB at the bottom of its region, 1.46 GB at the top). The profile reports no system resource, so the game takes its heap path ([Bezel Engine's two memory setups](../../../docs/reference/memory.md#bezel-engines-two-memory-setups)). With it the route above ran with nothing in the alias region.
- The heap check's 1 GB pool (made for the virtual-memory path) and the Switch's 3285 MB pool made no difference on that path: the game's regions do not depend on the pool there.
- Resident memory on the Mac was about 4.9 GB, with 2.4 GB of Metal allocations, on the board after the minigame (heap path, frame 51,300).

## Rendering

- 25,693 shaders (8,140 vertex, 17,501 pixel, 35 compute, 12 geometry, 1 hull, 4 domain), 25,447 of them in the archives (most in the 13,839 `.fshb` entries, type tag `_G3DSHA`) and 246 in `main`; 20,541 shader pairs. All build for the Mac. Window origin upper left (set after a lower-left default), depth mode near = 0, swapchain 1920x1080 RGBA8 sRGB, present interval 1.
- **Resolved: flat grey triangles on the board.** On the board and at the minigame podium, flat grey or background-coloured shapes with straight edges covered part of the scene (behind the dice block, beside the path, behind the item shop), changing shape from frame to frame while the camera stood still, and the board's spaces were missing. The spaces are GPU-driven instances: a vertex shader drawn as 62 points with rasterization off (`2b5485a2a731a231`) writes an 80-byte transform per visible instance and counts them, `276504dc5c987ecf` turns the count into nine indirect draw records, and the instanced draws (`5a805bbb08421b86` in the depth pre-pass, `4b05556737e9535f` and `eaa3a44ba28f0744` in the colour pass) read record = instance + `c0[0x644]`, the driver's base-instance word. The host could only put 0 there for an indirect draw, so every draw read the first records ([The base instance of indirect draws comes from Metal](../../../docs/reference/shaders.md#the-base-instance-of-indirect-draws-comes-from-metal)). Found by bisecting the colour pass with `DM_NVN_SKIP_FS` (which never removed the shapes), then following the vertex-stage storage buffer the instanced draws read back to its writer in the pass dump.
- `[RED] NVN unimplemented function called: nvnQueueGetTotalCommandMemoryUsed` / `…ControlMemoryUsed` / `…ComputeMemoryUsed` / `nvnQueueResetMemoryUsageCounts`, about once every few seconds: memory-usage statistics the engine reads; nothing depends on them in the route.
- One `SetRenderEnableConditional` (drawn unconditionally), one `stage 0 cb7 has no uniform buffer bound` and one `sampler ID 4095 not registered`, at boot.
- Run headless while someone works at the Mac: in a covered window the display link stalled for a second at a time and screenshots were not taken.

## Movies

- The opening movie (`movie/flow/op/movie/bq_op.mp4`, H.264 1080p) and the mode previews in the island map are native-texture movies (output 3, mode 2). The opening movie is unskippable on the first start; later −/+ skips it.
- **Resolved: the opening movie froze on its 16th picture.** This SDK returns the output index inside `GetOutputBuffer` in native-texture mode, and the game never releases one ([`GetOutputBuffer` returns the output index in native-texture mode](../../../docs/reference/movies.md#getoutputbuffer-returns-the-output-index-in-native-texture-mode)).

## Files

- RomFS: 1,539 files, 5.30 GB. 949 Bezel Engine archives (`Archive/*.bea`, 4.34 GB; 127,203 zstd entries in the 2.9 form, [Bezel Engine 2.9 archives keep their entries inline](../../../docs/reference/shaders.md#bezel-engine-29-archives-keep-their-entries-inline)), 443 `.bfstm` streams, 139 NROs with their NRR, five MP4 movies.
- Archives are opened per language first (`<name>.nx.enUS.bea`, `.jaJP.bea`), then the common one; the not-found probes are normal.

## Mac routes

- Work folder `<NSP folder>/0100965017338000-work`: `run/boot.sh <log> [secs] VAR=…` runs `build/smpjhost` (a renamed copy of `dm/host/dmhost`) on the NSP script's build; `run/ctlrun.sh` starts it with `DM_CTL`, `run/see.sh` / `step.sh` / `mash.sh` press and take shots, `run/stop.sh` stops it by PID.
- Fresh save: the opening movie runs about 3.5 minutes; then `L+R` at the title, `A` through the player count and character, then about 20 `A` presses through Toad's talk, `LUp` held 3 s to walk up to the balloon, `A`, about 30 `A` through the tour and the island map; `A` on Mario Party, `A` on CPUs, `B` to close the rules, `A` × 3 through the board and settings, then `A` presses roll and go on. `run/save_title` is a save made after the first title.

## Found on this game

General changes first needed here; each applies to every game:

- **Bezel Engine 2.9 archives** (`bea_members` reads inline entries): [Bezel Engine 2.9 archives keep their entries inline](../../../docs/reference/shaders.md#bezel-engine-29-archives-keep-their-entries-inline).
- **Native-texture `GetOutputBuffer` returns the output index**, and a release of an index the client does not hold changes nothing (`hle_movie.c`): [`GetOutputBuffer` returns the output index in native-texture mode](../../../docs/reference/movies.md#getoutputbuffer-returns-the-output-index-in-native-texture-mode).
- **The base instance of indirect draws from Metal** (`dmsh_build.py` `vs_base_instance`): [The base instance of indirect draws comes from Metal](../../../docs/reference/shaders.md#the-base-instance-of-indirect-draws-comes-from-metal).
- **Bezel's memory setups** (profile data only): [Bezel Engine's two memory setups](../../../docs/reference/memory.md#bezel-engines-two-memory-setups).

## Open

- Only one board and one minigame were played; the other boards, modes (Koopathlon, Bowser Kaboom Squad, Rhythm Kitchen, …) and most minigame NROs were not loaded. Motion minigames were turned off at the prompt.
- Only the 2.3.0 build (`v458752`) is registered.
- iPhone: not built, not installed, not tested.
