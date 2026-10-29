# Cult of the Lamb (`01002E7016C46000`)

Update 1.5.28 (v1966080; the menu shows 1.5.27) over the base game, SDK 19.3.14. Unity 2022.3.62f3 IL2CPP with FMOD on NVN. Modules `main`, `subsdk0` (NintendoSDK_movie) and `sdk`. The six DLC NSPs are licences only. Plays on the Mac at 60 fps, as on the Switch: the Devolver Digital movie, the title, the intro movie (skipped with B), a new save, the opening walk to the bishops, the sacrifice, The One Who Waits and his choice, and the first fight. An unsigned IPA has not been built; iOS is untested.

## What it needs

| Setting | Where | Why |
|---|---|---|
| Node area cut 1 GB → 62 MB | `dm/tools/sdk_patches.py`, `sdk` build `871fb219…` (the constructor at `sdk+0x1423ec`, the movs at `+0x1423fc` and `+0x142468`) | the SDK-wide rule's cut (implementation 5), registered because the profile was brought up on this build; see [Memory](#memory) |
| `sys_resource 0x1000000` | [`game.tsv`](game.tsv) | the NPDM's 16 MB of system resource: virtual address memory |
| 5 GB guest layout: `mem_reserve 0x140000000`, `mem_alias 0x118000000`, `mem_stack 0x10000000`, `app_pool 0x40000000` | `game.tsv` | Ace Attorney Investigations Collection's and Monster Train 2's layout; with the hardware pool Unity ran out of address regions, see [Memory](#memory) |
| `depth_mode zero` | `game.tsv` | the game calls `nvnDeviceSetDepthMode` with near = 0; it only decides the mode of the pipeline bases made before the game runs |
| `shader_groups /Data/=data` | `game.tsv` | everything is under `Data/`: the player's serialized files and the `StreamingAssets` bundles |

No code of the game is cut. The game asks for present interval 1, so it needs no frame-rate key.

## Memory

- `nninitStartup` hands application pool − used memory to `StandardAllocator::Initialize(nullptr, size)` as one address region (it returns to `main+0xb7e45c`) and never calls `SetMemoryHeapSize`, as in the other Unity games with virtual address memory.
- The `sdk`'s `AddressRegionManager` keeps a 1 GB node area at the start of the alias region. The SDK-wide function rule cut it to 62 MB while the profile was provisional; the SDK-wide rules skip builds a profile names, so with this profile in `dm/games` the `sdk` was rewritten with no cut until the two cuts were registered for its build. The rewrite with them is byte for byte the one the provisional profile played on. Region placement aligns to 64 KB or 2 MB only (`sdk+0x142544`), as SDK 20, so it needs no alignment cut ([Size-class alignment doubles Unity's regions](../../../docs/reference/memory.md#size-class-alignment-doubles-unitys-regions) does not apply).
- **Resolved: a title of only its cream clear colour, then a crash at the first movie, with the hardware pool (3.2 GB).** StandardAllocator's region took 3.14 GB at alias +0.06 GB, and Unity's own regions reached +4.25 GB of the 4.38 GB alias region 25 s after boot, with 1.0 GB mapped. The title's assets did not load: each frame cleared to the background colour and drew 117 draws, none of them visible. A press of A started the intro movie, and the movie thread crashed in Unity's `ALLOC_DEFAULT_THREAD` allocator (a write at `NULL + 0xffffe0`, `main+0x6f86ec`). The heap check's 15 s ended at +4.10 GB, just outside the 0.25 GB margin at which `profile_guess.py` picks a 1 GB pool. With `app_pool 0x40000000` StandardAllocator's region is 0.93 GB, the title draws in full and the movie plays.
- Those runs also logged `[RED] texture object invalid while recording` (call site `main+0xc18474`), `texture object no longer valid` and `no render target could get an MTLTexture` once each, about 25 s after boot. No run with the 1 GB pool has logged them; not investigated further.
- **Current:** with the 1 GB pool the alias region reaches +2.26 GB at the title and +3.51 GB in the first fight, with at most 1.75 GB mapped; about 2.7 GB resident and 1.0 GB of Metal allocations on the Mac.

## Files and shaders

- RomFS: 10,443 files, 1.65 GB; 10,312 UnityFS bundles, 100 FMOD banks and 4 MP4 movies, nearly all under `Data/StreamingAssets`.
- 53,559 shaders: 53,548 from `Data/` (26,706 vertex, 26,706 pixel, 135 compute, one geometry) and the player's 11 GLSLC outputs in `main`. All built for the Mac with no failure.

## Frame rate

- **Current:** 60 fps on the Mac (an Apple M6, macOS 27.0.1, headless): frame time p50 16.6 ms, p95 about 20 ms in the first fight; CPU about 46% of a core.

## Audio and movies

- FMOD through one `AudioOut`; no underrun over the session.
- The Devolver Digital logo and the intro movie (H.264 1920×1080 with AAC, VideoToolbox) play; B skips the intro.

## Mac routes

- Build with `scripts/build_ipa_from_nsp.py <NSP folder> -k <prod.keys> --platform mac`; its last line runs the game.
- From a fresh save, through `DM_CTL`: A at "Press Any Button to Start" (about 40 s after boot), hold B to skip the intro movie, A (Play), A (the first New Save). The opening walk starts about 25 s later: hold up along the path to the bishops; the scene waits with no prompt until the lamb walks onto the pentagram ("Kneel to be Sacrificed", A). A through The One Who Waits' dialogue (left, A for "Yes."), and the first fight follows (Y attacks, B dodges).

## Testing

- 2026-10-28, Mac (headless, about 10 minutes): the route above to the first fight, with no red line and no crash.
- 2026-10-28, Mac, from this profile in `dm/games` (the `sdk` cuts registered, the shaders rebuilt for its inputs): the title, the intro movie, the save menu and the opening walk, with no red line.
- Not checked: the cult base, a save and continue (the save menu still showed four empty slots after the first fight), the DLC content, the iPhone.

## Open

- iOS: no IPA built yet; untested on a device.
- Only update 1.5.28 is registered. The base game 1.0.0 (v0) has a different `main` build and would come from a derived profile.

## Found on this game

- An SDK 19.3.14 instance of [the SDK's address-region node area](../../../docs/reference/memory.md#the-sdks-address-region-node-area).
