# 13 Sentinels: Aegis Rim, Japanese release (`010045C014650000`)

Base game 1.00 (v0), SDK 10.8.2: the Japanese eShop release, Japanese only, under its own title ID. Vanillaware's own engine on NVN, as in the western release ([01003FC01670C000](../01003FC01670C000/README.md)), whose note covers the engine, and the Asian release ([01008D7016438000](../01008D7016438000/README.md)). Modules `main`, `subsdk0` (NintendoSDK_movie 10.8.2) and `sdk`. No module is another release's build: `main` `932cabe1…`, `sdk` `0617f669…` and `subsdk0` `9fafcfc1…`, where the western and Asian releases are SDK 11.4.3 and share their `sdk` and `subsdk0`. So the NSP script's lookup by main build ([`same_build`](../../../scripts/build_ipa_from_nsp.py)) finds no profile for it. Plays on the Mac from the base NSP alone (packed with `--platform mac-app`): the prologue's opening, its first battle won and the story after it, at 60 fps with sound, saving and loading, at 1× and at 2× upscaling. Not tested on the iPhone.

## What it needs

| Setting | Where | Why |
|---|---|---|
| `alloc_big_align on` | [`game.tsv`](game.tsv) | the engine's ring heaps are cut from a memory pool at 64 KB alignment ([the western note, Memory](../01003FC01670C000/README.md#memory)). The provisional profile, without it, crashed with a null write at `main+0x309080` (`x0 = 0`) right after the prologue's autosave, as it entered its first battle; with it, that battle plays |
| 4 GB layout: `mem_reserve 0x100000000`, `mem_alias 0x10000000`, `mem_stack 0x10000000`, `app_pool 0xCD500000` | `game.tsv` | as the western profile: no system resource in the NPDM, the game sets a heap |
| `sys_resource 0x0` | `game.tsv` | the NPDM declares no system resource (the NSP script writes it from the NPDM) |
| `depth_mode zero` | `game.tsv` | the game sets the near = 0 depth mode, so the pipeline bases made before it runs (the NSP script's Mac prebuild, and a [pipeline archive made offline](../../../docs/development.md#the-pipeline-archive-made-offline) for the iPhone when one is built with `DM_PSO_GPUS`) take its vertex shaders' `main0_z` entries (the host itself follows the mode the game sets) |

No `patches.py`, no `sdk_patches.py` cut for its `sdk` build (`0617f669…`), no `pad_layout`. The rest of the profile is the NSP script's provisional one.

## Files and shaders

- The whole RomFS is one CRI CPK archive, `ROBO.CPK` (4.0 GB), which is the `romfs_marker`.
- Shaders: 838 GLSLC outputs in `main`, 751 `shader_map.tsv` rows with the same keys as the Asian release's (`shader_pairs.tsv`, `shader_facts.tsv` and `bf_want.tsv` are identical), at other offsets in `main`.

## Mac routes

- The control data lists only Japanese, so the host picks `ja` whatever the Mac's preferred languages are (log: `language: ja (macOS preferred …; game supports ja)`).
- A new game has no voice-language menu (the western release asks for one): after the logos the prologue's opening plays. Pressing A every 3 s reaches the first battle (the Destruction autosave, Area 0-1, Wave 1) at about two minutes of play time, then its action menu; A on the first action and A on the target win the wave, and the story goes on to a classroom scene.
- Measured on an M2 Pro (2026-10-26) with the window in front: 1× frame time p50 16.67 ms, GPU p50 2–5 ms per frame in battle; 2× (`DM_UPSCALE=2`) GPU p50 about 6 ms and p95 at most 10.3 ms; about 2.2 GB resident; no red line; no audio underrun except right after a test screenshot (a 4K `shot` is a 0.5 s frame).
- With another app in front during a scripted run (`DM_CTL`, which does not pause the game), the game is told it is out of focus and draws at about 27 fps (frame time p50 about 37 ms): judge the frame rate only with the window in front.
- At 2× the battle opens with the map scanned in: buildings edged in red, then digital stripes across it, and within a few seconds the map renders cleanly. Most likely the game's own transition; see [Open](#open).

## Found on this game

Nothing: no host change was needed.

## Open

- Not tested on the iPhone.
- `pso_manifest.tsv` is not recorded yet (no prewarm).
- Only the base game 1.00 was packed.
- Whether the red edges and stripes at the start of a battle also show at 1× (which would make them the game's transition, not an upscaling fault) was not captured.
