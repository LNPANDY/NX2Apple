# Pikmin 4 (`0100B7C00933A000`)

Update 1.1.1 (v262144) over the base game, SDK 10.4.8 (its own `sdk` build). Nintendo EPD / Eighting, Unreal Engine 4.26.2 (`Carrot4`; `SDK MW+EpicGames+UnrealEngine-4_26_2` in `main`), NVN, PhysX 3.4, Wwise (its own `AudioOut` sink, Opus through the host's software decoder), VP9 movies through Unreal's Switch media player and the SDK's movie module. Modules `main`, `subsdk0` (the movie module: the title and the opening are VP9 movies) and `sdk`. Plays on the iPhone (IPA 10.8 GB); 30 fps, as on the Switch.

Status: on the Mac, the boot, the title (a VP9 movie behind the logo), the main menu, a new game (the auto-save notice, players, creature activity level), the opening (the shadow-play story, the cutscenes with Olimar and Moss) and the Olimar prologue in play, Continue from a save; 30 fps as on the Switch, Wwise sound, about 2.6–2.8 GB resident and 1.7 GB of Metal allocations, no red line. The title is up about 25 s after launch. The prewarm list covers that route (806 lines).

## What it needs

| Setting | Where | Why |
|---|---|---|
| Engine region given what the alias region has room for, 4.06 GB: gate `OBS_UE_REGION` on the store of its size, `main+0x353f57c` | the rewriter's engine-wide rule (`dm/tools/ue_region.py`), no build ID; the host's room (`hle_svc.c`) | Unreal's `nninitStartup` reserves 62 GB by default. Until 2026-10-31 this build's `patches.py` cut the default to 4064 MB (`main+0x353f56c` and `main+0x353f578`). This build reserves the region only when `-SwitchVirtualAddressSpaceSize=` is absent, so the profile has no `game_args`; see [Memory](#memory) |
| FMallocBinned3 constructor call cut, `main+0x353f788` `bl 0x35ba610` → `nop`, with gate `OBS_UE_MALLOC` on it (x0 = the new object) | the rewriter's engine-wide rule (`dm/tools/ue_malloc.py`), no build ID | its pools are cut out of the engine region; the host runs Unreal's heap (`hle_uemalloc.c`, the UE 4.27 layout). Until 2026-10-30 this build's own cut, with the gate at `main+0x353f78c` |
| Node area cut 1 GB → 62 MB (`sdk+0x340ea0` / `+0x340f3c`) and 2 MB alignment for regions of 4 MB and more, as SDK 20 (`sdk+0x341094`, `+0x34109c`, `+0x3410a0`) | `dm/tools/sdk_patches.py` SDK-wide rules, `sdk` build `30a1e87b…` | the SDK 10.4.1 build's AddressRegionManager at the same offsets, with the same cuts; the region starts 62 MB in and a 4 GB region needs no 1 GB alignment slack |
| Engage's 5 GB block: `mem_reserve 0x140000000`, `mem_alias 0x118000000`, `mem_stack 0x10000000`, `app_pool 0xCD500000` | [`game.tsv`](game.tsv) | 256 MB in front + 4.375 GB alias region + 256 MB stack region + 128 MB heap region, as FINAL FANTASY RESONANCE's |
| `sys_resource 0x5000000` | `game.tsv` | the NPDM declares 80 MB of system resource |
| `pad_layout full` | `game.tsv` | a 3D game with a free camera on the right stick; it plays with the controller, so it stays docked (1920x1080) |

## Frame rate

- **Current:** 30 fps, as on the Switch. The game steps a fixed frame time (`bUseFixedFrameRate=True` in `DefaultEngine.ini`, Unreal's default `FixedFrameRate` of 30) and asks for present interval 2 (`rhi.SyncInterval=2` in `SwitchDeviceProfiles.ini`, `r.VSync=1`), so a faster present rate would speed the game up, not smooth it. No `fps_target`.

## Memory

- `nninitStartup` needs virtual address memory, sets a 6 MB heap for the C library's malloc and reserves one address region for the engine, 62 GB.
- **Resolved: `nn::diag::Abort` from `main+0x352fbec` (Unreal's fatal error) with `-SwitchVirtualAddressSpaceSize=` given.** This `nninitStartup` (`main+0x353f1xx`) reads the argument into `main+0x93c2130` (MB up to 4095) but reserves the region only when the argument is absent: `ldr x8,[x22,#0x130]; cbnz x8` jumps past the default 62 GB and its `nn::os::AllocateAddressRegion(main+0x93c2128, 62 GB)` (`main+0x353f564`). With the argument the base stayed 0, and the first commit, `AllocateMemoryPages(0, 2 MB)` while the RHI starts (`main+0x353ff8c`, result 0xe03), failed. The game's own code, not the host's: Unreal Engine 4.27 and 5 reserve the region either way. The profile has no `game_args`; the default path's store of the size (`str x8` at `main+0x353f57c`) takes the rewriter's engine-wide gate, which gives the region what the alias region has room for, 4.06 GB (until 2026-10-31 a cut of the default to 4064 MB in this build's `patches.py`).
- **Current: the allocator is the host's.** It is made as in UE 4.27 (DRAGON QUEST VII Reimagined, [0100A9D01C446000](../0100A9D01C446000/README.md)), with the same 21-slot FMalloc vtable: `GCreateMalloc` (`main+0x353f770`) mallocs 0x1c38 bytes on the first allocation and constructs them (`main+0x353f788` → `main+0x35ba610`, the one store of the vtable `main+0x8da4758` outside its two destructors; found from the FMallocBinned3 error strings through the relocated slots). The constructor call is cut by the rewriter's engine-wide rule (`dm/tools/ue_malloc.py`), and at the gate on it the host puts its allocator's vtable into the object in x0 (`hle_uemalloc.c`). The Unreal heap lives on a malloc zone outside the guest block.
- The SDK 10.4.8 build's AddressRegionManager is the 10.4.1 build's (Advance Wars 1+2, The Great Ace Attorney Chronicles) at the same offsets and takes the same three cuts.
- With Engage's 5 GB block, from the boot into the Olimar prologue: up to +1.5 GB of the alias region with 1.0 GB mapped, an Unreal heap of 1 GB, 1.7 GB of Metal allocations (about 2.8 GB resident).

## Files and shaders

- IoStore containers `Carrot4/Content/Paks/Carrot4-Switch.utoc` / `.ucas` (7.5 GB, TOC version 2; `.ucas` is the profile's `romfs_marker`) hold the cooked packages; everything else is in `Carrot4-Switch.pak` (3.5 GB, version 11 with the magic 0xcc from the end as DRAGON QUEST VII Reimagined's, 10,046 files, Zlib, index not encrypted): the configs, 1,294 Wwise `.wem` files, the WebM movies (stored) and the two shader code archives (stored).
- The update (v262144, 0.9 GB) is a delta over the base RomFS.
- Shaders: 15,727 distinct (16,190 in the two archives), every one an LZ4 block (`uepak.py` `lz4_shaders`), as DRAGON QUEST VII Reimagined's; all build. Every vertex shader is made to link with any pixel shader (`shader_split.py` `separable_pairs`).

## Services

- **Resolved: the boot sat at a black loading screen for good, CPU nearly idle, every thread waiting, about 1 boot in 6 (3 in 4 with four Mac hosts at once).** The title movie was never opened and the save files never probed. The game's boot state machine (`main+0x1f2f0e0`, state at `this+0xd4`) stayed in state 7, which polls the status word (+0x14) of the game's BCAT news runnable ("OlimarMemo") for 0, 4, 5, 6 or 7; it read 1. The runnable's constructor (`main+0x203f3b0`) clears the status, starts `FBCATThread` and only then stores 1; the thread's `Run` (`main+0x203f510`) stores 2, calls `nn::nifm::SubmitNetworkRequest`, sleeps while `IsNetworkRequestOnHold`, and stores 6 when `IsNetworkAvailable` is false. On a Switch the request stays on hold while the nifm service evaluates it, so the constructor's 1 always comes first; the host answered "not on hold" at once, and a thread that ran before the constructor's store finished at 6, which the 1 then overwrote. The host now keeps a submitted request on hold for the first query, then settles it as unavailable, as Horizon's asynchronous request does (`hle_net.c`); the thread sleeps 10 ms between its queries. 12 of 12 boots with four hosts at once reached the title (first with a 50 ms hold, which Hades showed was too long for a game that counts its queries, then with the hold for one query; a host that answers at once hung 1 of 4 in the same test).
- How it was found: the hung boots' logs diverged from good ones at the save probe (`DM_FS=1`), the thread dumps showed nothing but idle waits, and `DM_PROBE` on the state machine (found by probing the save probe's call stack and dumping the state each tick), then `peek` lines in a hung run's `DM_CTL` file, followed the pointers to the status word. A probe on the hot path slowed the boot enough to hide the race (8 of 8 good).

## Rewriter

- **Resolved: `AssertionError: 0x…` in `site_window` on an `adrp` inside an exclusive window** (`main+0x43da14c`: `ldaxr x9,[x9]; cmp x9,x25; b.ne out; adrp x10 + add x10` (the same address again, for the store); `mov x18,x26; stlxr w9,x8,[x10]`, then loads and `cbnz w9` back). A window that uses x18 is copied into the patch area, where the `adrp` would build another page; it is now re-encoded for the copy's address with the same target page (`window_adrp`).
- **Resolved: `observation gate neither at a function entry, after a bl nor before a call`** on the epilogue `ldp x29, x30, [sp, #0x10]` right after the cut allocator constructor call (`main+0x353f78c`; the rule checks the image after the cuts, so the `bl` before it is a `nop` by then). `scratch_dead` now accepts a `ret` ahead as it does a `bl`.
- The spin-wait search takes 80 → 83 loops in `main` since the store rule.

## Input

- The 3D pad layout (the camera is on the right stick); it plays with the controller, docked.

## Mac routes

- The work folder's `run/ctlrun.sh <run>` starts a run with `DM_CTL`, `run/see.sh <shot> <wait> <presses…>` presses and takes a screenshot, `run/mash.sh` presses A in rounds.
- The title is up about 25 s into a boot: A (main menu), A (Story), A (the save file), A (Load). From a fresh save, A (Story) shows the auto-save notice; then the number of players and the creature activity level start the opening.
- `smoke.tsv` (for `scripts/regress.py`) starts from a save in the Olimar prologue, kept as `saves/prologue` in the NSP folder: A every 3 s goes through the cutscenes and their dialogue, and Olimar stands on Moss in play from about 130 s.

## Found on this game

General host changes first needed here; each applies to every game:

- **A network request kept on hold before it settles** (`hle_net.c`, `nn::nifm`): [Network requests stay on hold before they settle](../../../docs/reference/services.md#network-requests-stay-on-hold-before-they-settle).
- **Rewriter:** an `adrp` re-encoded inside a copied exclusive window (`window_adrp`) and gates before a `ret` (`scratch_dead`): [`adrp` inside an exclusive window](../../../docs/reference/rewriter.md#adrp-inside-an-exclusive-window), [Observation gates on any relocatable instruction](../../../docs/reference/rewriter.md#observation-gates-on-any-relocatable-instruction) (the `scratch_dead` rule, removed on 2026-10-31). Spin waits that store (`patch_nso.py` "Spin waits"): [development.md, Power](../../../docs/development.md#power).
- **An Unreal engine region that `-SwitchVirtualAddressSpaceSize=` cannot size**, given what the alias region has room for at its default path's store (`dm/tools/ue_region.py`; a cut in this build's `patches.py` until 2026-10-31): [Unreal's engine address region and its options](../../../docs/reference/memory.md#unreals-engine-address-region-and-its-options).

## Open

- The engine region's gate (4.06 GB instead of the 4064 MB cut) has not been run on this game yet: check the boot into the Olimar prologue (`[mem] Unreal's engine region` in the log).
