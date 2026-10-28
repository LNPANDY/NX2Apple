# Blasphemous (`0100698009C6E000`)

Update 1.0.8 (v524288) over the base game, SDK 8.3.1, Unity 2017.4.28f1 IL2CPP with FMOD on NVN. Modules `main`, `subsdk0` (NintendoSDK_movie) and `sdk`. Plays on the Mac: title, patch notes, new game, opening H.264 cinematic, awakening, healing, movement, jumping and a sword swing in the first room. Gameplay testing deliberately stops there. iPhone/iPad validation remains open.

## What it needs

| Setting | Where | Why |
|---|---|---|
| `sys_resource 0` | [`game.tsv`](game.tsv) | The NPDM declares no system resource, so Unity uses a heap rather than virtual address memory |
| 4 GB guest block, 3.25 GB heap region, `app_pool 0xCD500000` | `game.tsv` | The standard older-Unity layout; the startup heap request is 3.10 GB |
| `mem_used 0x7000000` | `game.tsv` | The rewritten modules exceed the default 64 MB; the packing script calculates 112 MB so the requested heap fits beside them |
| `shader_groups /Data/=data` | `game.tsv` | The serialized files and AssetBundles are under `Data/` |
| `depth_mode zero` | `game.tsv` | The game sets near=0 at startup; offline pipeline bases use the matching vertex entry point |

No game-specific rewriter cut or host change. The general forward-initialized jump-table fix below is required to rewrite `main`.

## Files and shaders

- The merged RomFS has 4,417 files, 6.07 GiB, including 99 UnityFS bundles, the player's serialized assets, 13 MP4 movies and FMOD banks.
- The DLC NSP is a licence-only package, index 1 (`0100698009C6F001`); packing recognizes the licence. Its content was not separately tested.
- 617 shaders: 304 vertex, 301 pixel and 12 compute. Four GLSLC outputs are in `main`; the other 613 come from Unity assets. All compile on the Mac, with zero unresolved bindings or unfillable driver-bank reads.
- The legacy Unity supplemental pairs plus the serialized pair give 309 pipeline bases; all 309 prebuild successfully. `pso_manifest.tsv` records the checked opening route's 43 unique shader/pipeline entries.
- All 617 shader libraries compile for iOS too. The unsigned IPA is about 0.9 GB (877.5 MiB), built for user sideloading; device runtime validation remains open.

## Performance and validation

- Tested on the Mac on 2026-10-28, in a five-minute startup and opening-room run. No runtime `[RED]` message, abort or crash. The process was stopped after the short control check.
- The first room presents at the game's 60 fps target. Settled 300-frame windows report frame-time p50 about 16.67 ms and GPU p50 about 0.8–1.7 ms. Other builds were active, so these are diagnostic observations rather than an isolated benchmark.
- Resident memory settles around 1,936–1,938 MB in the opening room, with Metal allocations around 2,054–2,055 MB; no sustained growth in the checked interval. This is a brief check, not a long-session leak test.
- FMOD opens one AudioOut. Settled callback windows report zero underruns. The movie module produces visible H.264 pictures and subtitles.
- The Python tool suite and `make -C dm/gfx/tests GAME=0100698009C6E000 run` pass. The rewriter's new fallback has synthetic tests for bounds, base clobbers, incoming branches, invalid targets and table extent. The IPA passes `unzip -tq`; its six shipped profile tables match the repository copies.
- `regress.py check --quick` checked Return of the Obra Dinn (the closest Unity 2017.4 compiler) and Super Mario Bros. Wonder (an established x18 rewrite route). Two games are sufficient for this narrow fallback: every previously recognized site takes its old path, and all five rewritten modules of these games are byte-identical to the baseline. All 17,540 shader outputs and pipeline interfaces are unchanged; both routes reach their frame targets with zero new `[RED]` kinds. Wonder reports **PASS**. Obra Dinn reports **REGRESSION** for FPS 59.8 → 53.4 in the measured window; both runs are marked busy with concurrent jobs, so the performance comparison is inconclusive. Its screenshot changes (RGB 8.5 and 7.97) show a different rowing-animation phase on visual review. The earlier full Obra Dinn run measured 59.9 → 59.1 fps with no runtime errors. The final report is in the NSP work folder's `regress-quick-report/report.md`; other games were not checked.

## Mac route

Build with `scripts/build_ipa_from_nsp.py <NSP folder> -k <prod.keys> --platform mac` and use its printed command. At the title press A, dismiss the first-run patch notes with B, press A on Pilgrimage, then A on the first empty slot. Let the opening advance; B can skip a cinematic segment when enabled.

The opening room initially requires **L to heal** before movement is available. Dismiss the Biliary Flasks tutorial with B. Left stick moves, B jumps and Y swings the sword. The default 2D touch-pad layout exposes these controls.

The checked route used a windowless diagnostic run (`DM_PRESENT_LINK=0`, omit `DM_WINDOW`) with audio and `DM_CTL` screenshots. The save contains the first new-game slot; save reload was not tested.

`smoke.tsv` is a short fresh-save title-screen route, without input or gameplay. A second 40-second boot checked the registered profile and final rewritten modules.

## Found on this game

- [Offset table base initialized after the dispatch](../../../docs/reference/rewriter.md#offset-table-base-initialized-after-the-dispatch): the general rewriter fix, found at `main+0xae95f8`.
- Existing [Unity 2017.4 shader containers](../../../docs/reference/shaders.md#containers-by-engine) and [Unity video planes](../../../docs/reference/movies.md#unitys-video-planes-and-checking-the-movie-path) work without another change.

## Open

- iPhone/iPad runtime validation, save reload, combat encounters, bosses, later areas and DLC content. The base version was inspected for build lookup but was not played or registered.
- An isolated repeat of the noisy Obra Dinn performance comparison above; no claim of an existing-game performance improvement or regression follows from these busy-Mac timings.
