# Unicorn Overlord, Asian release (`010054B01AD92000`)

Update 1.05 (v262144) over the base game, SDK 16.2.4: the Korean / Chinese release, under its own title ID. Vanillaware's engine on NVN, as in the western release ([010069401ADB8000](../010069401ADB8000/README.md)), whose note covers the engine. Modules `main` and `sdk`. `sdk` is the western build (`12f16103…`); `main` (`9c3116f0…`) is not the western 1.05's (`c841ffe2…`), so the NSP script's lookup by main build ([`same_build`](../../../scripts/build_ipa_from_nsp.py)) does not find the western profile for it. On the Mac it plays from the logos through the title and a new game into the opening story scene, in Korean, with no red line. The IPA packs; not run on the iPhone yet.

## What it needs

The western profile's keys as they are: `alloc_big_align on`, `mem_used 0x5c00000` and the 4 GB layout (`mem_reserve 0x100000000`, `mem_alias 0x10000000`, `mem_stack 0x10000000`, `app_pool 0xCD500000`), with this release's title ID and build row ([`game.tsv`](game.tsv)). The western note's [What it needs](../010069401ADB8000/README.md#what-it-needs) says why. The `sdk_patches.py` node area cut for `sdk` build `12f16103…` applies to it as to the western release.

No `patches.py`, no `pad_layout` (the iPhone pad starts in the 2D layout).

## Files and shaders

- The data is in 5 CRI CPK archives: `Unicorn.CPK` (the `romfs_marker`), `UnicornPatch.CPK`, `Unicorn_KO.CPK`, `Unicorn_CN.CPK` and `Unicorn_TW.CPK`. The game's languages are ko, zh-Hant and zh-Hans (no en-US); the NSP script picks ko.
- Shaders: GLSLC outputs in `main`, with the same keys as the western release's: 1,725 shaders, and the data rows of `shader_map.tsv`, `shader_pairs.tsv` and `shader_facts.tsv` are identical to the western profile's. `shader_map.tsv.conflicts.tsv`, `bf_want.tsv` and `pso_manifest.tsv` are the western ones (empty).
- Both DLC NSPs (`010054B01AD93001`, `010054B01AD93002`) are licences only: their RomFS holds just the SDK's placeholder file, as in the western release.

## Mac routes

- The western route works as it is: `DM_KEYS=f2400:A*20/300` reaches the opening story scene by frame 5,000.

## Found on this game

Nothing: no host change was needed.

## Open

- Not run on the iPhone.
- Only the merged 1.05 copy is extracted; the base game's own build IDs are not registered.
- Tested only to the opening story scene: no battle, saving or loading yet.
