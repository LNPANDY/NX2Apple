# Mario + Rabbids Sparks of Hope (`0100317013770000`)

Update 1.6.2225577 (v393216) over the base game, SDK 13.3.5, Ubisoft's Snowdrop engine on NVN, with Havok and Wwise. The ExeFS loads `main` and `sdk`; the seven supplied DLC NSPs are indices 1–7. **Mac: playable opening exploration, including a saved campaign reload. iOS remains unvalidated.**

## Memory

- The NPDM declares 16 MB of system resource. `nninitStartup` (`main+0x4d1300`) sets a 10 MB heap; the engine takes its memory through address regions and commits pages on demand.
- **Resolved: startup reservation failure.** [Separate virtual ranges in Snowdrop's page allocator](../../../docs/reference/memory.md#separate-virtual-ranges-in-snowdrops-page-allocator). The constructor (`main+0x1642b8`) originally gives each pool 4 GB, alongside a 1.1875 MB metadata region. `patches.py` reserves 3 GB with 2 GB for large allocations, 512 MB for 512 KB pages and 512 MB for 64 KB pages. Both uses of the combined size change together (`+0x1642fc`, `+0x164308`); `+0x1642c8` initializes the slab-size fields, and `+0x164300` / `+0x16430c` override the large range. SDK build `43211771ed39e7fcef03d88e27091831` also needs its node area cut to 62 MB (`+0x37c140`, `+0x37c1dc`) and large regions aligned to 32 MB (`+0x37c33c`). With the node cut alone, the 3 GB reservation still fails.
- **Resolved: large allocations crossed the class boundary.** The large allocator's initialization (`main+0x168310`) separately takes a maximum 64 KB page count in `w5`, stored at object `+8`. `patches.py` changes it from 65536 to 32768 (`+0x164338`) to match the 2 GB range. The initial outer-boundary cut alone left this child allocator at its original 4 GB capacity: while loading the first campaign it returned a 12 MB compressed-file buffer exactly at the 512 KB pool's base. `free` routed that pointer to slab handling and interpreted compressed payload as its owner (`main+0x1668dc`). The corrected rewrite loads and reloads the opening campaign. The fixed 1 MB large-allocation metadata reserve (`+0x168308`) still holds more nodes than the reduced capacity needs.
- **Resolved: UI contexts without address space (GitHub issue #483).** Shaking the overalls bush in “An \"Overall\" Nice Day”, or loading a save from the first planet, wrote to `0x78` at `main+0x2c534a8` (`lr=main+0x2c53484`): the 136-byte entry array of a UI node context (`Moria::Services::UI::Shared::Nodes::Context`, built at `main+0x2c4a228`) had no base. Each context reserves 576 KB and 256 KB of address space and never checks the reservation. Measured with a 64 GB alias region (`DM_ALIAS_SIZE=0x1000000000`, `DM_REGIONS`) in the opening quest: the node area (62 MB), a 1.06 GB pool of 4,194,304 272-byte slots (`main+0x94364`), Snowdrop's 3 GB, a 152.6 MB pool of 16-byte entries (`main+0x14dbd4`) and 147 contexts (119.5 MB) end at +4.515 GB, past the profile's 4.375 GB; 150 contexts after the overalls. On the profile's layout the regions reach +4.375 GB, only 110 of the 147 contexts got their 576 KB range, and the overalls bush crashes as in the issue. The 1.06 GB pool had nothing committed: only the memory system's startup (`main+0x94260`) and its teardown (`main+0x94214`) name it or the default-pool slot it fills. `patches.py` gives it 65,536 slots (17 MB, `+0x94354`), which leaves about 1 GB for the contexts and later regions. The same route then picks up the overalls without a crash.
- **Current measurements; later capacity open.** In the reloaded opening quest, 64 KB pages held 291.9 MB active / 296.3 MB of bump space, 512 KB pages held 156 MB / 213.5 MB, and large allocations held 1007.4 MB within a 1280 MB managed span (2048 MB capacity). The shortage flag was zero. The slab allocators (`main+0x164aa8`, `+0x1649a8`) set the game's shortage flag (`+0x169f20`) at their derived ends and retain their original 4 GB reserve fallback. Later worlds and sustained battle play still need capacity testing.

## Files and shaders

- The merged RomFS holds 352 files under `moria/sdf/nx`: Snowdrop `.sdfdata` slices, a `.sdftoc`, a `.sdfver` and a `.mapping`. DLC can supply further slices and shaders.
- **Resolved: no shaders found by the split.** The shaders are compressed records in `BERG` archives: [Shader records in Snowdrop SDF data slices](../../../docs/reference/shaders.md#shader-records-in-snowdrop-sdf-data-slices). The split reads every supplied RomFS, including DLC.
- The registered shader union contains 23,280 stages: 20,400 vertex, 2,599 fragment and 281 compute. Base plus update contributes 18,459; DLC indices 5, 6 and 7 add 632, 2,193 and 1,996 respectively. Indices 1–4 add no unique shaders. Every stage compiles for the Mac, including the pulling and shadow-input variants. A different installed DLC set gets shader tables derived from that set while retaining the registered module fixes.

## Rendering

- **Resolved: compute image writes discarded.** [Image bindings supply shader-write intent](../../../docs/reference/nvn-objects.md#image-bindings-supply-shader-write-intent). The game registers its depth-conversion output through `RegisterTexture` with only `COMPRESSIBLE`; the writable image binding now upgrades its backing before dispatch. The final Mac run uses the real image and renders the lit castle grounds.
- **Current: inactive menu placeholder warnings.** Fragment shaders `184b0b673101a2da`, `4143b4dfc3115f89`, `a5c80eb8e6380096`, `0ca739a46129f292` and `ad34a496c970dff1` declare a 3D texture in slot 3, but some menu draws bind the game's 2D placeholder (texture ID 262). All ten sampling sites are guarded by fragment CB0 float `+0x180` being nonzero or NaN. A capture spanning frames 878–909 found 148 placeholder draws, each with this float exactly zero, and 42 draws with a real 3D texture, each with 150.0. No overlapping deferred uniform updates occurred. The type warning describes an unused binding on this captured route; no shader or binding workaround was added.

## Mac testing

Tested on 2026-10-27 with the registered update and all seven supplied DLC packages. Title and campaign menus, creating File 1, the opening Peach dialogue, walking around the castle grounds, camera movement and collecting coins work. Reloading File 1 returns to the active “An \"Overall\" Nice Day” quest. The final validation uses all 23,280 stamped Mac shader libraries and their generated uniform tables; the earlier image-write failure is gone and no shader libraries are missing on this route.

To drive the Mac test, set `DM_GAME=0100317013770000`, use the rewritten `patched_v393216` modules, the merged update RomFS, the shader output's Mac directory and `DM_AOC_DIR=<build>/aoc`. From a clean boot, `DM_KEYS=40:A,44:A,48:A,52:A` passes the title, campaign menu, File 1 and Continue Journey. Advance the first dialogue with A when starting a new file; use the left stick to walk and the right stick for the camera. Keep `DM_SAVE` in the NSP work folder. Give each boot a fresh `DM_CTL` file so old inputs and diagnostic settings do not replay.

Game files, logs and analysis stay beside the NSPs, in `0100317013770000_build` and `0100317013770000-work`.

## iOS build

The NSP script produced `MarioRabbidsSparksOfHope.ipa` (9.8 GB) on 2026-10-27, containing the registered update, all seven DLC packages and 23,280 iOS shader libraries. The app is unsigned, for the user to sideload. It has not been installed or tested on an iOS device.

## Found on this game

- [Image bindings supply shader-write intent](../../../docs/reference/nvn-objects.md#image-bindings-supply-shader-write-intent): compute writes to render textures used as images, even when their builder omitted `IMAGE`.
- [oe calls answered without an applet proxy](../../../docs/reference/services.md#oe-calls-answered-without-an-applet-proxy): `EnableAlbumImageTakenNotification` reaches the am proxy the host does not create. The host now handles it alongside the disable call.
- [Shader records in Snowdrop SDF data slices](../../../docs/reference/shaders.md#shader-records-in-snowdrop-sdf-data-slices).
- [Separate virtual ranges in Snowdrop's page allocator](../../../docs/reference/memory.md#separate-virtual-ranges-in-snowdrops-page-allocator).

## Open

- Play into a battle, check later rendering and measure memory over sustained play; the initial exploration test does not establish whole-game compatibility.
- Docked mode: coins are reported with wrong colours (GitHub issue #483; correct in handheld). Not investigated.
- iOS testing is performed by the user.
