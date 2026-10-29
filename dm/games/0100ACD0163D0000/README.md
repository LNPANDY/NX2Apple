# Batman: Arkham Knight (`0100ACD0163D0000`)

Update 1.0.5 (v327680) over the base game; the base NSP is a 7 MB stub and the update holds the game (26.9 GB). SDK 14.3.0. Rocksteady's Unreal Engine 3 (package version 864, licensee 0x80e3) on NVN, with Wwise for the sound, CRI Sofdec for the movies (`.usm`) and Scaleform for the menus. Modules `main` and `sdk`. Plays on the Mac at 30 fps, as on the Switch: the language screen, the health warning, the title, the save select, New Story, the opening cutscene and the cremation, then Pauli's Diner as Officer Owens. An unsigned IPA has not been built; iOS is untested.

Two pull requests brought this game up before this profile, separately: [#339](https://github.com/seedds/nxnative/pull/339) / [#340](https://github.com/seedds/nxnative/pull/340) and [#384](https://github.com/seedds/nxnative/pull/384). This port was done on its own and then checked against them; what it takes from them is named below.

## What it needs

| Setting | Where | Why |
|---|---|---|
| The allocator's construction skipped; the host's allocator in its object | [`patches.py`](patches.py), `hle_uemalloc.c` layout `UE3` | it would reserve 1 GB + 37 GB of address space; see [Memory](#memory) |
| Barriers in the task ring | `patches.py` | its push and pop publish an item with no barrier, and Apple's cores drop items; see [Threads](#threads) |
| Node area cut 1 GB → 62 MB | `dm/tools/sdk_patches.py`, `sdk` build `2aef2cff…` | registered because the profile was brought up on this build, as Cult of the Lamb's |
| `shader_key_skip 0x770+0x78` | [`game.tsv`](game.tsv) | the engine shares one control section among shaders that differ only in GLSLC's compile information; see [Files and shaders](#files-and-shaders) |
| A 2 GB block: `mem_reserve 0x80000000`, `mem_alias 0x58000000` | `game.tsv` | the host heap lies outside the block; see [Memory](#memory) |
| `sys_resource 0x2000000` | `game.tsv` | the NPDM's 32 MB of system resource: virtual address memory |

No frame-rate key: the game asks for present interval 2 and runs at 30 fps, as on the Switch.

## Files and shaders

- RomFS: 5,294 files, 26.7 GB: 4,093 cooked packages (`BmGame/CookedSwitch/*.xxx`, chunks of Oodle Mermaid, 19 GB), the texture caches (`*.tfc`), 1,030 Sofdec movies (`BmGame/Movies/*.usm`, 7.6 GB) and a voice pack per language (`<language>/*.wad`).
- 21,923 shaders (2,564 vertex, 19,233 pixel, 124 compute, 2 geometry), all built for the Mac with no failure: [Unreal Engine 3 shader caches (Oodle packages)](../../../docs/reference/shaders.md#unreal-engine-3-shader-caches-oodle-packages). The global cache (`GlobalShaderCache-Switch.bin`) holds 1,847 records, the combined one (`CombinedShaderCache-Switch.xxx`) 22,874; none of 68 other packages sampled holds a shader.
- **Resolved: 40 of the first shaders the game used were not in the shader map.** Each was one record's control section with another record's code area: the shader loader (`main+0xb7948c`) shares control sections that differ only in GLSLC's compile information, and the host's key hashed those bytes: [Control sections shared among shaders that differ only in their compile information](../../../docs/reference/shaders.md#control-sections-shared-among-shaders-that-differ-only-in-their-compile-information). In the files only +0x7d0..+0x7e7 seemed to matter, but the opening cutscene met a pair that differed at +0x778, as #340 had found; with `0x770+0x78` no shader was missing through the diner.
- **Resolved: four shaders sampled 2D render targets as 3D textures** (`[RED] texture type mismatch … declares slot 129–132 as Metal type 7, texture … is type 2`, `553c51835a24a36a`, `fad24ea404d1bbac`, `26ccc3148f457613` and the compute shader `e4bd7b26b4a2dc5b`; #340 read them as 2D arrays). They sample a volume at world coordinates (`fad24ea404d1bbac`: position × 1/20480 + 0.5) through separate texture slots 1–4, and from the first frames of New Story on the game leaves 2D textures bound there, mostly its half-resolution targets (a BC1 texture for `26ccc3148f457613`): the pass dump of `553c51835a24a36a` (frame 5121 from `save_diner`) shows separate slot 2 holding texture ID 283, a 720x406 RGBA16F target, beside the R32F, RG11B10F and depth targets and two 64x64 textures; the game does create 3D textures (2x2x2 at boot, 32x32x32, 71x40x64), but binds none there. Metal has no 3D view of a 2D texture, so they were bound as is with undefined reads; the host now binds the zero 3D texture: [A 2D texture in a 3D slot binds the zero 3D texture](../../../docs/reference/rendering.md#a-2d-texture-in-a-3d-slot-binds-the-zero-3d-texture). What the Switch reads there is not known.
- **Explained: `[RED] stage 0 cb0 has no uniform buffer bound`, once per run, at boot.** The game's first command buffer (before the first present) updates its two uniform buffers (vertex 128 bytes at pool +0x3400, fragment 116 bytes at +0x300) and draws a quad to the window (vertex shader `86ade63f9df2cdb0`, fragment `4904d66df28dbfbc`, 6 vertices) and then a second draw, with no `CommandBufferBindUniformBuffer` in it at all (the `[nvn] init 0` call counts); from frame 1 on it binds the same two addresses before the same draws (`DM_NVN_PASSDUMP=0-2`). The host reads the zero bank there: [An unbound uniform slot reads the zero bank](../../../docs/reference/rendering.md#an-unbound-uniform-slot-reads-the-zero-bank). The vertex shader makes x and y from rows 6 and 7 of cb0, so with zeros every vertex lands on (0, 0) and the quad draws nothing on a window that is still zero. Nothing to fix in the host; what the Switch reads from the unbound slot is not known.

## Memory

- **Resolved: the provisional build stopped at its address region check.** The static constructors reserve 1 GB for the allocator's tables (`main+0x192eee8`) and 37 GB for its pools (`main+0x192fe50`; the regions reached alias +39.13 GB in 15 s). It is Unreal's binned allocator, built inline in the guarded function behind `GMalloc` (`main+0x192eb30`, the object `main+0x51818c0`); the cut branches past it, and the host runs the heap: [Unreal's FMallocBinned3 replaced by the host allocator](../../../docs/reference/memory.md#unreals-fmallocbinned3-replaced-by-the-host-allocator). Its interface is UE3's (25 slots, 32-bit sizes), found from the vtable offsets of `GMalloc`'s call sites. The same cut and layout are in #339 and #384.
- **Current:** the host heap held 1.75 GB 45 s into the boot and 2.00 GB in the diner; the process 3.7 GB resident, 1.8 GB of it Metal allocations.
- The 2 GB block is #384's: on an iPad Pro (M4), Engage's 5 GB block stopped the game about 50 s in (`FATAL Unreal heap: out of memory … 1.79 GB in use`), since the block, the heap and Metal share the app's address space. On the Mac the route below runs to the diner with it; on iOS it is not checked here.

## Threads

- **Resolved: every run froze as New Story loaded** (frame 7,800 in one, 11,700 in another): the picture stopped, the sound went on. The main thread spun in the game's wait for two jobs it had just handed the `GameAboveNormalWorker` threads (`main+0x12f8010`, the counter `main+0x511c0f0`, the jobs `main+0x12f8bc0`); both workers sat in the host's same-core handoff after signalling the main thread, waiting for it to block. The host held a waker whose affinity mask (0x5) allows another core, which Horizon would move there: [A same-core handoff holds only a waker pinned to that core](../../../docs/reference/threads.md#a-same-core-handoff-holds-only-a-waker-pinned-to-that-core). The fix is in `hle_thread.c`, for every game.
- **The task ring's barriers** are #340's finding (freezes at the menus, in the opening and in the diner, 2 of 3 of its runs; [Lock-free queues published without barriers](../../../docs/reference/threads.md#lock-free-queues-published-without-barriers)). Its cut words were checked against this build's disassembly and are in `patches.py`; this port's runs did not meet that freeze before or after.

## Frame rate

- **Current:** 30 fps in the diner on the Mac (an Apple M6, headless): frame time p50 33.4 / p95 42.8 ms, GPU p50 9.7 ms, about a minute after it loaded; the first seconds there are slower while pipelines are built on first use (p50 41.8 ms), and there is no `pso_manifest.tsv` yet. #384 runs it at 60 with `present_interval display` (the engine's own cap is 62); not taken here.

## Mac routes

- Build with `scripts/build_ipa_from_nsp.py <NSP folder> -k <prod.keys> --platform mac`; its last line runs the game.
- From an empty save, with `DM_CTL` presses (the work folder's `run/route.sh`, about 4 minutes): A at the language screen (about 45 s after boot), A at the health warning, A at the license notice, A at the title, A on the first save slot, A on the new-game options' Continue, A at the autosave notice, A on New Story. The opening cutscene follows; at the cremation prompt ("Incinerate") B must be held for several seconds (`B~6`; short presses do nothing); the diner follows after the credits begin. In the diner the left stick walks and the right stick turns.

## Testing

- 2026-10-29, Mac (headless): the route above from an empty save into Pauli's Diner, a few steps and turns there, with no crash and no shader missing from the map (the four texture-type red lines only).
- 2026-10-29, Mac (headless), with the zero 3D texture: from `save_diner` (it resumes at the cremation) through the cremation into the diner, no texture type mismatch left (`texture type mismatches no view bridges 0`), the cremation and the diner drawn as before; the only red line is `stage 0 cb0 has no uniform buffer bound`, once, at boot ([Files and shaders](#files-and-shaders)).
- Not checked: Gotham beyond the diner, a save and continue, the iPhone or iPad.

## Open

- iOS: no IPA built yet; untested on a device (the 2 GB block comes from #384's iPad run).
- 60 fps, picture settings (render scale, the engine's SMAA): #384 has both; not taken here.
- Only update 1.0.5 is registered.

## Found on this game

- [Unreal Engine 3 shader caches (Oodle packages)](../../../docs/reference/shaders.md#unreal-engine-3-shader-caches-oodle-packages) and [Control sections shared among shaders that differ only in their compile information](../../../docs/reference/shaders.md#control-sections-shared-among-shaders-that-differ-only-in-their-compile-information) (the profile key `shader_key_skip`).
- The `UE3` layout of [Unreal's FMallocBinned3 replaced by the host allocator](../../../docs/reference/memory.md#unreals-fmallocbinned3-replaced-by-the-host-allocator), and an SDK 14.3.0 instance of [the SDK's address-region node area](../../../docs/reference/memory.md#the-sdks-address-region-node-area).
- [A 2D texture in a 3D slot binds the zero 3D texture](../../../docs/reference/rendering.md#a-2d-texture-in-a-3d-slot-binds-the-zero-3d-texture) and [An unbound uniform slot reads the zero bank](../../../docs/reference/rendering.md#an-unbound-uniform-slot-reads-the-zero-bank) (`stage 0 cb0` at boot).
- [A same-core handoff holds only a waker pinned to that core](../../../docs/reference/threads.md#a-same-core-handoff-holds-only-a-waker-pinned-to-that-core) and [Lock-free queues published without barriers](../../../docs/reference/threads.md#lock-free-queues-published-without-barriers).
