# Super Smash Bros. Ultimate (`01006A800016E000`)

Update 13.0.5 (`v2031616`) over the base game, with its 99 DLC licences; SDK 8.2.1. Bandai Namco / Sora's engine (namespaces `app`, `lib`, `phx`, `nu`) on NVN. Modules `main`, `subsdk0` (NintendoSDK_movie) and `sdk`, the same `sdk` and movie builds as Catherine: Full Body ([0100BF00112C0000](../0100BF00112C0000/README.md)); the fighters' code is 98 NRO modules loaded at run time. Plays on the iPhone (IPA 17.5 GB; offline). On the Mac: the opening movie, the title, the first launch's DLC unlocks and Challenges board, the main menu, the Smash rulesets, stage select, fighter select, 2-player battles (Frigate Orpheon, Big Blue, Great Bay, Find Mii) at 60 fps with about 2.7 ms of GPU per frame and 2 GB resident (1.2 GB of Metal allocations), quitting a battle to its results and a second battle whose fighters' NROs the game loaded again.

## What it needs

| Setting | Where | Why |
|---|---|---|
| Engine region 62 GB → 4 GB (11 instructions) | [`patches.py`](patches.py), `main` `21450c64…`; for other builds the same cuts as one function-matched patch of four functions (`MATCH_CUTS`) | the game aborts in its static initialisers when its 62 GB address region fails; see [Memory](#memory) |
| Node area 1 GB → 62 MB, regions of 1 GB and more aligned to 32 MB | `dm/tools/sdk_patches.py`, `sdk` build `5fd4f531…` (`sdk+0x336b50` / `+0x336bf0`, `+0x336d5c`) | with them the cut region starts 64 MB into the alias region instead of 1.95 GB |
| 5 GB guest layout: `mem_reserve 0x140000000`, `mem_alias 0x118000000`, `mem_stack 0x10000000`, `app_pool 0xCD500000` | [`game.tsv`](game.tsv) | a 4.375 GB alias region, where the game maps its memory itself |
| `sys_resource 0x1000000` | `game.tsv` | the NPDM declares 16 MB of system resource (virtual address memory); `main` never sets a heap |
| NRO modules | `dm/tools/nro_collect.py` (`nro.tsv`), `loader.c` "NRO modules", `hle_ro.c`, `gen_embed.py` | the fighter, item and common scripts; see [Fighter code at run time](#fighter-code-at-run-time) |

No `pad_layout` key (the iPhone pad starts in the 3D layout).

## Memory

- **Resolved: an abort in the static initialisers, before `nnMain`** (`main+0x37c9bd0`), when the engine's own 62 GB address region failed. The engine's memory (the `nu::` allocator behind `nu::VirtualAllocHook`, set up by a static constructor at `main+0x37c9a20`) reserves 62 GB with `nn::os::AllocateAddressRegion(0xf80000000)` (`main+0x37c9a5c`) and hands it out in 64 KB units: a number line of free ranges, first [0, 0xf7f20) units from the region's start (`main+0x37c9b98`, given to `main+0x37c9c00`), and the top 14 MB (region + 0xf7f200000) as the pool of its range nodes, committed 64 KB at a time up to the region's end (the bound checks at `main+0x37c9a9c`, `+0x37c9c50`, `+0x37ca3cc` and `+0x37caf68`). The size, the header offset, the page count and three region-end bounds all follow from 62 GB, so `patches.py` cuts all 11 instructions to a 4 GB region (the node pool at 4 GB − 14 MB, the first free range 0xff20 units); the application pool (3.2 GB) bounds what it can commit.
- Booted once with a 64 GB alias region (`mem_reserve 0x1030000000`, `mem_alias 0x1008000000`) and `DM_SVC=1`'s map log: the game commits from the region's start upward (1.73 GB contiguous at the title, 75 s in) and its page tables (the node pool) from the top; a battle commits up to 2.5 GB (`DM_ALIAS_WINDOWS`).
- **Current: other builds of `main` (GitHub issue #375, 13.0.1 `b9b166df…`).** The 11 cuts are keyed to 13.0.5's build, so another build packed from a derived profile got none and aborted at the same place. They are now also one function-matched patch (`MATCH_CUTS`) of the four functions they lie in: the constructor (`main+0x37c9a20`, 472 bytes, 8 of them) and the three functions with a region-end bound (`+0x37c9c00`, `+0x37ca180`, `+0x37caf10`). It applies only when all four match, since a region cut in some and not the others would put the node pool outside the region. On 13.0.5 it gives exactly the registered cuts. The base game 1.0.0 (`fd471eb4…`, extracted ExeFS only) has the same allocator, the 62 GB constant at five sites (`main+0x27f869c`, `+0x27f86d4`, `+0x27f8868`, `+0x27f9108`, `+0x27f9c80`), but none of the four functions is the same code, so the patch does not apply there and the NSP script says so. 13.0.1 has not been checked here (no copy): the issue's search for the original words found none, but a search of the NSO file itself would miss them, as its segments are compressed. Open: whether 13.0.1's four functions match; if not, its own implementation under the same name, reviewed by disassembly.
- The cut region still did not fit: SDK 8 has the same 1 GB node area and 1 GB alignment of regions of 1 GB and more as the newer SDKs (constructor `sdk+0x336b40`, `orr w9, wzr, #0x3fe00000` at `+0x336b50` / `+0x336bf0`; `VammManager::AllocateAddressRegion`'s alignment at `+0x336d5c`); with them it started 1.95 GB into the alias region (measured with a 64 GB one). They are cut in `sdk_patches.py` as on DRAGON QUEST XI S's SDK 7.3.2 build ([01006C300E9F0000](../01006C300E9F0000/README.md)), whose AddressRegionManager this is at other offsets; the region then starts 64 MB into the 4.375 GB alias region of the 5 GB block.

## Fighter code at run time

- **Resolved: the frame loop ran, but the game waited for code it loads itself** (`ro::RegisterModuleInfo` / `ro::GetBufferSize` red lines). `main` imports 1,045 `lua2cpp::create_agent_*` functions, global, that no ExeFS module defines, bound to stubs at start. The fighter, item and common scripts are 98 NRO modules in `data.arc` (`prebuilt:/nro/release/lua2cpp_<name>.nro`, 193 MB), registered by `.nrr/cross2_*.nrr`. The game loads them with `nn::ro::LoadModule` as fighters appear (common and item at boot, the opening movie's fighters, each battle's) and unloads them after.
- **Current:** they are collected at pack time by the SHA-256s the NRRs list (`dm/tools/nro_collect.py`, among `data.arc`'s current files; the NRRs of older releases also register 666 superseded copies, which `data.arc` still holds and which are left out), rewritten like any module and loaded by the host, which binds `main`'s `lua2cpp` stubs to them. 87 need no rewrite at all, 11 have one `x18` site each. The game loads six NROs in its first 30 s and calls none of the stubs.
- On iOS they are packed into three sections of the executable (`gen_embed.py`: `__dm_nro_x0`, `__DM_NRO_W`, `__dm_nro_x1`, and a table of their pieces, `__dm_nro_tab`), 157 MB of code; a Mach-O file has at most 255 sections, and three per NRO would pass it (`loader.c` `nro_pieces`). Played on an iPhone.

## Rewriter

- **Resolved: an unhandled jump table, its far base passed through other registers** (`main+0x2b74458`: `ldrb w18,[x14]; sub w18,w18,#1; cmp w18,#6; b.hi; ldrsw x18,[x7,x18,lsl #2]; add x18,x18,x7; br x18`). `x7` is built by `adrp` + `add` 688 instructions before, then parked in `x30` around a loop (`mov x30,x7` … `mov x7,x30`), so the far chain met a `mov` and stopped; the function-wide search found a second `adrp x7` + `add` pair (another table further on) whose seven targets also lie in the function. It was that `main`'s only unhandled site; Smash's `sdk` and movie module come out byte-identical with the fix.

## Services

- **Resolved: a jump to pc=0 right after the NVN bootstrap loader** (`lr=main+0x37fe930`, `[RED] NVN address lookup of an unknown name: nvnSetExternalDebuggerEnabledNVX`). The game fetches an NVX extension of the SDK 8 driver by name and calls it without checking the pointer. The real driver has it, so it joins `dm/gfx/nvn/names.txt` as a no-op (thunks regenerated with `gen_protos.py`; no prototype in `nvn.h`, so `NVN_NOPROTO`).
- **Resolved: only 64 of the 99 DLC licences were reported** (PR #441). Challenger Packs 1-4 and 11 (indices 2-5 and 12: Joker, Hero, Banjo & Kazooie, Terry and Sora), plus costume and spirit packs, were among the omissions. The contributor rebuilt the Mac app and confirmed all 99 indices in its startup log; the general fix is linked below. Integration also checked the actual 99 DLC folders with the host's count/list hooks under ASan/UBSan: the baseline returned 64, the candidate all 99 in order, including paginated queries. **Open:** DLC fighter availability in character select and an iOS rebuild with this fix have not been verified.

## Rendering

- **Resolved: a pink window, every command buffer ignored, while headless runs looked right** (`DM_WINDOW=1`). The first presents failed on the display command buffer with `kIOGPUCommandBufferCallbackErrorPageFault`, and after a few of those macOS ignored every submission of the process ("Ignored (for causing prior/excessive GPU errors)"). The game presents its window texture in its first frames before drawing into it; the texture was made on that first resolution in the present path and added to the residency set (`res_add`), but only a submission commits the set, so the display command buffer sampled a texture outside the committed set. Headless runs never present, which is why they looked right.

## Files and shaders

- The RomFS is one `data.arc` (17.6 GB; the profile's `romfs_marker`) beside 14 NRRs. Its header (magic `0xABCDEF9876543210`) gives the offsets of the music, file and shared-file sections and of the file system table (one zstd frame of 50 MB); paths are Hash40s (CRC-32 of the path, its length in the top byte). A path leads to its current file through its info index, file info, info-to-data entry and file data, at file section + directory offset + 4 × its offset, zstd or stored (`dm/gfx/tools/smash_arc.py` documents the layout) ([01, Compressed RomFS content](../../../docs/agents/01-extract.md#compressed-romfs-content)).
- The archive also keeps every earlier version of updated files, which no path leads to any more: 183,882 data blobs, 169,939 of them current (the 98 fighter NROs, 764 with their old versions, which the NRRs of older releases still list). A file's first bytes name its format: SSBH `HBSS` resources (`RDHS` shader databases, `XFUN` effect libraries, `LDOM` / `HSEM` / `LTAM` / `MINA` / `LEKS` models, meshes, materials, animations, skeletons), `EFFN` effects, `SARC` UI layouts, `BNTX`, `NUS3` sound and the NROs (`NRO0` at +0x10).
- Shaders: 35,012 (22,197 vertex, 12,761 pixel, 53 compute, 1 geometry): GLSLC outputs in the 41 SSBH shader databases (`.nushdb`, 7,764), BNSH in the effects (`EFFN`, 26,419) and UI layouts (SARC, 752), and 77 in `main`. The split reads `data.arc`'s current files (`shader_split.py` `smash_arc_jobs`).

## Mac routes

- The work folder's `run/ctl.sh` drives a run started with `DM_CTL` (`run/step.sh <log> <shot> <frames> <presses…>` presses, waits on the frame counter and takes a shot).
- From `run/save_ref` (past the first launch): A skips the movie, A at the title reaches the main menu, A (Smash), A (a ruleset), A (Random stage), then at the fighter select (after its "Joined!" banner) `LUp~0.85`, `LLeft~0.85`, `LDown~0.3`, `LRight~0.4` lands on Mario, A, Plus.

## Found on this game

General host changes first needed here; each applies to every game:

- **The complete owned DLC list:** [Owned add-on content lists beyond 64 entries](../../../docs/reference/services.md#owned-add-on-content-lists-beyond-64-entries).
- **NRO modules loaded at run time:** collected by the NRRs' SHA-256s (`nro_collect.py`, `nro.tsv`), rewritten (`patch_nso.py` reads NROs), mapped at start and activated by `nn::ro::LoadModule` / `UnloadModule` (`loader.c` "NRO modules", `hle_ro.c`; `DM_NRO=0` turns it off), embedded on iOS (`gen_embed.py`, `nro_pieces`): [Loading NROs with `ro::LoadModule`](../../../docs/reference/services.md#loading-nros-with-roloadmodule), [development.md, The packing script in detail](../../../docs/development.md#the-packing-script-in-detail).
- **Register copies followed back to a jump table's base** (`copied_base`): [Far table base passed through other registers](../../../docs/reference/rewriter.md#far-table-base-passed-through-other-registers).
- **`nvnSetExternalDebuggerEnabledNVX`** as a no-op (`names.txt`, `NVN_NOPROTO`): [Extensions fetched by name and called unchecked](../../../docs/reference/nvn-objects.md#extensions-fetched-by-name-and-called-unchecked).
- **The residency set committed at present** (`present_now` → `res_commit`): [The residency set committed before a present](../../../docs/reference/rendering.md#the-residency-set-committed-before-a-present).
- **The indexed archive reader** (`smash_arc.py`, `smash_arc_jobs`): [01, Compressed RomFS content](../../../docs/agents/01-extract.md#compressed-romfs-content).
- **Function-matched patches of several functions, and the pack-time report of what an unregistered build kept** (`nso_match.py` `match_patch`, `<module>.match.tsv`, `report_fix_coverage`): [Function-matched cuts for unregistered builds](../../../docs/reference/rewriter.md#function-matched-cuts-for-unregistered-builds).
- **The address region table and the NSP script's region check** (`patch_nso.py` "Address regions", `hle_svc.c`, `DM_REGIONS`): its engine region, 4 GB through `nn::os::AllocateAddressRegion`, returning to `main+0x37c9a64` (its constructor's call), opened up to 14 MB below its end: [Measuring address regions and commits](../../../docs/reference/memory.md#measuring-address-regions-and-commits).

## Open

- The one geometry shader among the 35,012: whether it builds is not recorded.
- The base game 1.0.0 (v0) packed alone (a derived profile) stops before the address region check: the NRO collection's `data.arc` reader (`dm/gfx/tools/smash_arc.py`) knows only 13.x's file system table, and 1.0.0's is not one zstd frame (`ZstdError: Unknown frame descriptor`); with the NROs skipped, the rewrite of its `main` (`fd471eb4…`) stops at a jump table it cannot resolve (`patch_nso.py`, `jump table f5c9cc`). Its engine region is not measured.
