# Sea of Stars (`01008C0016544000`)

Update 2.0.59001 (v786432) over the base game, SDK 16.2.0. Unity 2021.3.25f1 IL2CPP with Wwise on NVN. Modules `main`, `subsdk0` (NintendoSDK_movie) and `sdk`; the `sdk` is the build of Super Mario Bros. Wonder 1.0.0 / 1.0.1 ([010015100B514000](../010015100B514000/README.md)). The DLC NSP is a licence only. Plays on the Mac at 60 fps, as on the Switch: the logos, the title, a new game (leader and difficulty choice), the Great Archives framing, the Mooncradle prologue's dialogue, walking, climbing and its scene changes, saving and continuing. An unsigned IPA is built; iOS is untested.

## What it needs

| Setting | Where | Why |
|---|---|---|
| Node area 1 GB → 62 MB | `dm/tools/sdk_patches.py` SDK-wide rules, `sdk` build `3053b229…`, `sdk+0x134728` / `+0x1347bc` | `StandardAllocator::Initialize` aborted before `nnMain`; see [Memory](#memory) |
| Region alignment 4 MB / 32 MB / 1 GB → 2 MB (SDK 20's) | `sdk_patches.py` SDK-wide rules (measured here; a row on this build until 2026-10-30), the same build, `sdk+0x134914` / `+0x13491c` / `+0x134920` | Unity's regions took twice their size in address space; see [Memory](#memory) |
| `sys_resource 0x1000000` | [`game.tsv`](game.tsv) | the NPDM's 16 MB of system resource: virtual address memory |
| 5 GB guest layout: `mem_reserve 0x140000000`, `mem_alias 0x118000000`, `mem_stack 0x10000000` | `game.tsv` | Ace Attorney Investigations Collection's layout ([010005501E68C000](../010005501E68C000/README.md)) |
| `app_pool 0x60000000` (1.5 GB) | `game.tsv` | with the hardware pool Unity got no address region; see [Memory](#memory) |
| `pad_layout full` | `game.tsv` | the 3D layout (D-pad, right stick) |

No code of the game is cut. The game asks for present interval 1, so it needs no frame-rate key.

## Memory

- **Resolved: `nn::diag` abort before `nnMain`.** `nninitStartup` (`main+0x8b66a0`) gives application pool − used memory to `StandardAllocator::Initialize(nullptr, size)` (`sdk+0x126380`, abort at `+0x126440`), and its 1 GB-aligned region did not fit after the SDK's 1 GB node area. The `AddressRegionManager` constructor (`sdk+0x134718`) is Brain Memory Training Academy's; its two `mov w8/w9, #0x3fe00000` take the 62 MB cut ([The SDK's address-region node area](../../../docs/reference/memory.md#the-sdks-address-region-node-area)). Mario Wonder 1.0.0 / 1.0.1 ship this `sdk` too, and Mario allocates address regions (361 in its first 100 s). With both cuts, Mario 1.0.0 boots to its title on the Mac and runs five minutes; its only red lines were graphics ones (four pipeline-prebuild link failures and `SetRenderEnableConditional`).
- **Resolved: a write at NULL + 0x3fffe0 about six minutes in, with the hardware pool** (`main+0x48b770`, Unity's `ALLOC_CACHEOBJECTS_THREAD` allocator in x19). Unity's virtual allocator got no address region: the alias region's high-water mark was +4.26 GB of 4.375 GB with 1.26 GB mapped. With a 64 GB alias region the same route reaches +6.0 GB with 1.77 GB mapped: StandardAllocator's 3.06 GB region from +1 GB commits about 0.7 GB, and Unity's own regions follow it.
- A 1.5 GB pool (StandardAllocator reserves 1.44 GB, about twice what it commits) ran 25 minutes without a crash, but still reached +4.26 GB. Region probes found the cause in the SDK's size-class alignment: Unity's N MB + 252 KB requests each take the next size class's slot, 0.86 GB of gaps among 2.59 GB of live regions ([Size-class alignment doubles Unity's regions](../../../docs/reference/memory.md#size-class-alignment-doubles-unitys-regions)). With SDK 20's 2 MB alignment cut into this build, the same live regions end at +3.24 GB, and a 20-minute session keeps the high-water mark at +3.0 GB.
- **Current:** about 2.5 GB resident and 1.13 GB of Metal allocations on the Mac in the Mooncradle prologue (2,449 → 2,466 MB resident from 3 to 13 minutes).

## Files and shaders

- RomFS: 2,243 files, 4.93 GB; 1,126 UnityFS bundles (1.64 GB), Wwise banks and 688 streams, 17 MP4 cinematics, all under `Data/StreamingAssets`.
- 3,898 shaders: 1,901 vertex, 1,905 pixel, 91 compute and one geometry shader. 3,887 come from `Data/`, 11 are the player's GLSLC outputs in `main`. All built for the Mac with no failure, and no run met a shader missing from the map.

## Frame rate

- **Current:** 60 fps on the Mac (frame time p50 16.6 ms; p95 about 20 ms as the median of the 300-frame windows of a 40-minute session, with other jobs on the Mac; CPU about 0.9 W on an M4 Pro). The game asks for present interval 1; no key is needed.
- With other jobs' windows over the game window, macOS stops the display link and nearly every frame is discarded (`on-screen … dropped 281`), so screenshots never come; `DM_PRESENT_LINK=0` presents without it for scripted runs.

## Audio

- Wwise through two `AudioOut`s (one opened at boot from `main+0x8b63f0`, one by the sound engine from `main+0x1850070`, which polls instead of waiting on a release event). No underrun in 20 minutes; `DM_AUDIO_DUMP` holds the title music from about 30 s.
- In the 40-minute session, the host's audio watchdog logged six `[RED] audio #…: the device has not called back for 209–223 ms`, all 12 to 17.5 minutes in, while the IPA build compiled iOS shaders and packed on the same Mac. It restarted the AudioUnit each time, and the game kept presenting frames. The same Core Audio callback stalls are open on [Pokémon Brilliant Diamond](../0100000011D90000/README.md#testing).

## Mac routes

- Build with `scripts/build_ipa_from_nsp.py <NSP folder> -k <prod.keys> --platform mac`; its last line runs the game.
- From a fresh save, through `DM_CTL`: `Plus` at the title (about 45 s after boot), `A` (New Game), `A`, `A`, `Left`, `A` (Zale leads), `A` (Adventure), then `A` every 1.5 s through the Great Archives and the Mooncradle dialogue (about 3 minutes) to the camp, where the player has control.
- The camp: the save pedestal is at its west end, the path south leads to the Mooncradle cliff, whose climbing holds lead back to the pedestal.

## Testing

- 2026-10-26, Mac: boot, logos, title, a new game, the leader and difficulty choices, the Great Archives and Mooncradle prologue dialogue, walking, climbing, three scene changes, saving to slot 1 and continuing from the title, over a 40-minute session and four shorter ones. The only red lines were the audio watchdog's under the IPA build's load ([Audio](#audio)).
- No battle was reached (the prologue's camp has no enemy), and no cinematic MP4 has played yet.

## Open

- Battles and the MP4 cinematics are untested.
- iOS: the unsigned IPA (`SeaOfStars.ipa`, 5.1 GB, 5,454,467,672 bytes, with the fps counter; 3,898 iOS shader libraries) is untested on a device.

## Found on this game

- The SDK 16.2.0 instance of [the SDK's address-region node area](../../../docs/reference/memory.md#the-sdks-address-region-node-area).
- [Size-class alignment doubles Unity's regions](../../../docs/reference/memory.md#size-class-alignment-doubles-unitys-regions).
