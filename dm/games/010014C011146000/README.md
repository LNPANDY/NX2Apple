# Subnautica: Below Zero (`010014C011146000`)

Update 1.23.55063 (v655360) over the base game, SDK 13.3.5. Unity 2019.4.36f1 IL2CPP with FMOD on NVN. Modules `main`, `subsdk0` (the movie module) and `sdk`; `sdk` and `subsdk0` are the builds of AI: THE SOMNIUM FILES - nirvanA Initiative ([0100713016CCC000](../0100713016CCC000/README.md)) and Pokémon Scarlet 1.0.0 ([0100A3D008C5C000](../0100A3D008C5C000/README.md)). Plays on the Mac. Tested there (a short test, at the user's request): the title, the main menu, a new Survival game, the opening in the hangar and the drop to the planet, then walking and looking around at the crash site, at 30 fps with music. One red line, an audio device stall at the landing ([Audio](#audio)). An unsigned IPA is built; iOS is untested.

## What it needs

| Setting | Where | Why |
|---|---|---|
| `sys_resource 0x800000` | [`game.tsv`](game.tsv) | the NPDM's 8 MB of system resource: virtual address memory |
| 5 GB guest layout: `mem_reserve 0x140000000`, `mem_alias 0x118000000`, `mem_stack 0x10000000`, `app_pool 0x40000000` | `game.tsv` | nirvanA Initiative's layout; the NSP script's heap check set the 1 GB pool; see [Memory](#memory) |
| Node area cut 1 GB → 62 MB | `dm/tools/sdk_patches.py` SDK-wide rules, `sdk` build `3644a676…` | nirvanA Initiative's build |
| Region alignment 4 MB / 32 MB / 1 GB → 2 MB | `dm/tools/sdk_patches.py` SDK-wide rules (measured here; a row on this build until 2026-10-30), `sdk` build `3644a676…` (`sdk+0x37c334`, `+0x37c33c`, `+0x37c340`) | Unity's regions spill past each size class; see [Memory](#memory) |
| ALLOC_BUCKET at most 63 blocks (255 on the Switch) | [`patches.py`](patches.py), `main` build `5b050c55…` (`main+0x6517f4`) | a 1 GB address region of which 80 MB is used; see [Memory](#memory) |
| `pad_layout full` | `game.tsv` | first-person 3D: the right stick looks around |
| `shader_groups /Data/=data` | `game.tsv` | everything is under `Data/`: the player's serialized files and the Addressables bundles in `StreamingAssets/aa/Switch` |

## Memory

- The NPDM declares 8 MB of system resource, so `IsVirtualAddressMemoryEnabled` is true: `nninitStartup` hands application pool − used memory to StandardAllocator as one address region (returning to `main+0x390b90`) and never sets a heap. With the hardware pool the alias region was used up to +4.28 GB of 4.38 GB within a second of `nnMain` (the NSP script's heap check), hence the 1 GB pool. StandardAllocator's region is then 0.94 GB, of which the opening maps 0.57 GB.
- **Resolved: the alias region was full by the end of the opening.** Every other region comes from Unity's virtual allocator (`AllocateAddressRegion` called at `main+0x75a6b0`). Measured with `DM_REGIONS` at the crash site after the opening, with nothing else changed: 336 live regions holding 3.45 GB (2.03 GB mapped) ended at +4.37 GB of the 4.375 GB alias region. The high-water mark reaches +4.0 GB while the Survival game loads (about frame 3,600), and the next region the game asked for would have failed. Two causes, both address space that is reserved and never used:
  - **Size classes.** This `sdk`'s `AllocateAddressRegion` (`sdk+0x37c2d0`) aligns regions by size class, and Unity asks for N MB + 252 KB (92 regions of 2.25 MB, 60 of 4.25 MB, 33 of 16.25 MB, 2 of 32.5 MB), so each spills past a class: 0.87 GB of gaps. The cut gives the three large classes SDK 20's 2 MB, as on Sea of Stars ([Size-class alignment doubles Unity's regions](../../../docs/reference/memory.md#size-class-alignment-doubles-unitys-regions)). Alone it took the end to +4.29 GB (gaps 0.78 GB); after a minute of walking it was at +4.33 GB. What remains of the gaps is the 2 MB alignment itself (0.30 GB) and holes left where Unity freed regions.
  - **The bucket allocator.** Unity's memory manager setup (`main+0x651558`) constructs the `ALLOC_BUCKET` BucketAllocator (constructor `main+0x64dcd8`: granularity 16, 32 buckets, 4 MB blocks, at most 255 blocks), which reserves (blocks + 1) × 4 MB at once: a 1 GB region at +1.04 GB, of which the opening commits 80 MB (20 blocks). Unity 2019.4 reads no `memorysetup` option for it (no such string in `main`). `AddMoreBuckets` (`main+0x64e1ec`) returns false at the block limit, and the allocation then goes to Unity's other allocators, so the limit sizes only the reservation: with a test limit of 2 blocks the game loaded the opening and played it, and the regions ended at +3.46 GB. The cut sets 63 blocks (a 256 MB region, three times what the opening uses). With both cuts the same route and some walking end at 332 regions holding 2.67–2.68 GB (2.00–2.03 GB mapped), 0.77–0.80 GB of gaps, the end at +3.50–3.55 GB (two runs): about 0.85 GB of the alias region left. This is a workaround for the iPhone's address space (the alias region is 64 GB on a Switch), kept in the profile as Pokémon Scarlet's and Sparks of Hope's reservation cuts are.
- Resident about 3.06 GB on the Mac in the world, 1.14 GB of Metal allocations, flat from frame 6,000 to 9,000.

## Files and shaders

- RomFS: 21,861 files, 4.0 GB: 14,633 UnityFS bundles (Addressables, `Data/StreamingAssets/aa/Switch`), 24 FMOD banks, 4,823 `.optoctrees` and 2,306 `.bin` world-streaming files.
- 10,840 shaders: 5,413 vertex, 5,400 pixel, 2 geometry and 25 compute, read with Unity 2019.4's layouts (Pokémon Brilliant Diamond's); the compute kernels are the player's skinning and blend shapes, the ocean's FFT (`FFT512x512`), `UpdateSpectrum`, `DetermineVisibility` and the eye histogram. 11 are the player's GLSLC outputs in `main`. All of them build for the Mac; no run met a shader missing from the map.
- **Current, cause unknown:** every run logs 1 to 8 `[RED] texture type mismatch: … declares slot 135 (or 136) as Metal type 2, texture ID 800 is type 7 (NVN target 2, …)` lines, a 3D texture in a slot the shader declares 2D; Subnautica's player logs the same ([its note](../0100429011144000/README.md#files-and-shaders)). Nothing wrong was seen on screen.

## Frame rate

- 30 fps, as on the Switch: the game sets present interval 1 at its window and 2 once it runs. On the Mac (M-series) frame time p50 33.34 ms, p95 33.49 ms in the world. Long frames on the first run are pipeline compiles (30–45 ms each); GPU time is 4–18 ms a frame.
- Not tried: `present_interval display` for 60 fps.

## Audio

- FMOD on one `AudioOut`; music and effects play.
- **Current, cause unknown: `[RED] audio #0: the device has not called back for 2xx ms while playing`** once per run, in two runs at the same point: right after the 22,000th device callback (about 115 s from boot on the route below), where the landing at the crash site takes a 724 ms frame on the CPU (GPU 12.7 ms). The host's watchdog stands in with the silent sink and restarts the AudioUnit within a second ([audio.md](../../../docs/reference/audio.md)), and sound goes on. Why the device stops calling back during that frame is not found (a host lock the render callback waits on is one candidate).

## Mac routes

- From a fresh save, with `DM_CTL` (`run/ctl.sh` in the work folder) once the title shows (about frame 1,500, then 30 s): `Plus`, `A` (Play), `A` (Start a new game), `A` (Survival), 25 s later `A` (Press any button), 70 s later `A`: the player stands at the crash site with control.

## Open

- iOS untested.
- The audio device stall at the landing ([Audio](#audio)).
- Only the opening and the crash site were played. Address space after longer play, underwater and in bases, is not measured: watch the `[mem] alias region mapped up to` lines.
- A function-matched cut of Unity's `ALLOC_BUCKET` block count would serve every Unity player on an iPhone; each Unity version's constructor call would need review first.

## Found on this game

- The SDK 13.3.5 instance of [Size-class alignment doubles Unity's regions](../../../docs/reference/memory.md#size-class-alignment-doubles-unitys-regions).
