# Super Monkey Ball Banana Rumble (`010031F019294000`)

Update 2.20 (v458752) over the base game, SDK 17.5.8. Unity 2022.3.30f1 IL2CPP on NVN, with CRIWARE (ADX sound; the story movies are Sofdec USM files that CRI Mana decodes in software) and FMOD. Modules `main`, `subsdk0` (NintendoSDK_movie) and `sdk`. The 37 DLC NSPs are licences only. Plays on the Mac at 60 fps, as on the Switch: the title, a new save, the story's opening movie, and the tutorial island (rolling, the camera, the Spin Dash). An unsigned IPA has not been built; iOS is untested.

## What it needs

| Setting | Where | Why |
|---|---|---|
| Node area cut 1 GB → 62 MB and 2 MB region alignment | `dm/tools/sdk_patches.py` SDK-wide rules, `sdk` build `71b1a025…` (`sdk+0x139468` / `+0x1394fc`; `+0x139654`, `+0x13965c`, `+0x139660`) | the SDK-wide function-matched cuts (node area implementation 4, alignment implementation 4); no cut is registered for the build |
| `sys_resource 0x1000000` | [`game.tsv`](game.tsv) | the NPDM's 16 MB of system resource: virtual address memory |
| `app_pool 0x40000000` | `game.tsv` | the heap check's choice: with the hardware pool the alias region was used up to +4.26 GB of 4.38 GB; see [Memory](#memory) |
| `mem_stack 0x28000000` (640 MB), `mem_alias 0x100000000` (4 GB) in the 5 GB block | `game.tsv` | with every other profile's 256 MB stack region, thread creation aborted on some boots; see [Memory](#memory) |
| `depth_mode zero` | `game.tsv` | the game calls `nvnDeviceSetDepthMode` with near = 0; it only decides the mode of the pipeline bases made before the game runs |
| `shader_groups /Data/=data` | `game.tsv` | everything is under `Data/`: the player's serialized files and the `StreamingAssets` bundles |

No code of the game is cut. The game asks for present interval 1, so it needs no frame-rate key.

## Memory

- `nninitStartup` hands application pool − used memory to `StandardAllocator::Initialize(nullptr, size)` as one address region (it returns to `main+0x10f7140`) and never calls `SetMemoryHeapSize`, as in the other Unity games with virtual address memory. With the 1 GB pool that region is 0.91 GB at alias +0.06 GB.
- Unity's own allocator (`main+0x1b8402c`) reserves most of its regions as 4 MB or 2 MB plus 0x3f000 bytes, which the 2 MB region alignment rounds to 6 MB and 4 MB of address space.
- **Resolved: an `nn::diag` abort at `sdk+0x13b2b8` (Result 0) on some boots, at the title.** The backtrace is `nn::os::detail::ThreadManager::CreateThread` (`sdk+0x135608`) → `ThreadManagerImplByHorizon::MapAliasStack`. `StackGuardManager::MapAtRandomAddress` (`sdk+0x138140`) asks `AddressSpaceAllocatorBase::AllocateSpace` (`sdk+0x139070`) for a random place for the new stack in the stack region; `AllocateSpace` tries 512 random addresses and returns 0 when none has the stack and its guard pages free, and `MapAliasStack` aborts on that (its third outcome; the other, 2, is a failed map that it retries). With `DM_THR=1 DM_SVC=1`, the game maps 48 stacks into the stack region in its first 30 s, 106 MB in all: 33 of 1 MB and nine of 8 MB. In the 256 MB stack region every other profile uses, the start positions an existing stack rules out for a new 8 MB one add up to more than the region, so the 512 tries find none on some boots. Horizon gives a 39-bit process a 2 GB stack region. A 640 MB stack region, taken from the alias region in the same 5 GB block (an iPhone has no room for a larger block), holds them; see [Thread stacks placed at random in the stack region](../../../docs/reference/memory.md#thread-stacks-placed-at-random-in-the-stack-region).
- **Current:** the alias region reached +3.25 GB of its 4 GB in the tutorial island, with at most 1.50 GB mapped; about 2.2 to 2.5 GB resident and 0.8 to 0.9 GB of Metal allocations on the Mac, flat over a 15-minute run. That run mapped 52 stacks, 138 MB in all (13 of 8 MB), into the 640 MB stack region.

## Files and shaders

- RomFS: 12,442 files, 3.49 GB; 12,294 UnityFS bundles (1.63 GB), 24 USM movies (1.69 GB) and the CRI ADX banks (`.acb` / `.awb`), nearly all under `Data/StreamingAssets`.
- 59,226 shaders from `Data/` and the player's GLSLC outputs in `main`; all build for the Mac.
- **Resolved: a red `texture type mismatch` line for URP's `CopyDepth`** (`a3d53d20b89e6015`, at the title: `declares slot 128 as Metal type 2, texture … is type 4`). The shader reads the multisample depth through `texture2d_ms`, which the reflection reader recorded as 2D; the binding was right. See [Multisample texture slots](../../../docs/reference/rendering.md#multisample-texture-slots).

## Frame rate

- **Current:** 60 fps on the Mac (an Apple M6, headless): frame time p50 16.7 ms, p95 19.4 ms on the tutorial island while other builds compiled shaders on the same Mac.

## Audio and movies

- CRI ADX sound and FMOD through one six-channel `AudioOut`.
- The story movies are USM files that CRI Mana decodes on its own threads (`CriManaDecodeThread`, `CRI MPV Worker`) into textures the game draws; they play with no host support. A press shows "A Skip"; A then opens "Skip movie?" with No selected.

## Mac routes

- Build with `scripts/build_ipa_from_nsp.py <NSP folder> -k <prod.keys> --platform mac`; its last line runs the game. The picture is a 1280x720 crop of the 1920x1080 window texture (`nvnWindowSetCrop`): screenshots from `DM_CTL` / `DM_NVN_SHOT` need `DM_NVN_SHOT_OUT=1280x720` (or the window's size) to show the crop rather than the whole texture.
- From a fresh save, through `DM_CTL`: A at "Press any Button!" (about 20 s after boot), A (the autosave notice), A ("Creating save data"). The opening movie starts; A, A, Left, A skips it. A (the tilt card) starts the tutorial island: tilt the left stick to roll, the right stick turns the camera, and A goes through the dialogue. The Spin Dash wants B released while the stick is still tilted: `B~0.6`, `B+LUp~0.6`, `LUp~1` as three lines.

## Testing

- 2026-10-30, Mac (headless, no audio), this profile in the worktree: the route above from a fresh save through the opening movie, the tutorial island's rolling and camera steps, the next movie and the Spin Dash lesson, with no red line once the shaders were built.
- 2026-10-30, Mac (headless, no audio), 15 minutes of scripted play on the tutorial island (`DM_SVC=1 DM_THR=1`): 50,000 frames at 60 fps (p95 20.9 ms), no red line, no crash.
- 2026-10-30, `--platform mac` from this profile in `dm/games`: the split checked against these tables with no mismatch; all 59,226 shaders built and stamped, the pipeline prebuild 21 minutes. The first build, from the provisional profile on a Mac shared with other shader builds, took 2 hours (shaders 79 minutes).

## Open

- iOS: no IPA built yet; untested on a device.
- Not checked: the story's first world, the battle and multiplayer modes, sound on a Mac with audio out.
- Only update 2.20 is registered. Other versions come from a derived profile.

## Found on this game

- [Thread stacks placed at random in the stack region](../../../docs/reference/memory.md#thread-stacks-placed-at-random-in-the-stack-region): the 640 MB stack region.
- [Multisample texture slots](../../../docs/reference/rendering.md#multisample-texture-slots): `texture2d_ms` and `depth2d_ms` read as their own types, and zero multisample textures for unbound ones.
- An SDK 17.5.8 instance of [the SDK's address-region node area](../../../docs/reference/memory.md#the-sdks-address-region-node-area), cut by the SDK-wide rule.
