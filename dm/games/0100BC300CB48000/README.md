# FINAL FANTASY X/X-2 HD Remaster (`0100BC300CB48000`)

Base game 1.0.0 (`v0`), SDK 5.4.0, with the supplied DLC indices 1 and 2. Square Enix / Virtuos PhyreEngine, FMOD, NVN. Initial modules `main`, `subsdk0` (NintendoSDK_movie) and `sdk`; the collection launcher, FFX, X-2, Last Mission and effect code live in 1,432 NROs registered by separate NRR files.

**Current:** Mac validation passes the collection launcher, FFX's opening 3D scene with sound, and X-2's first battle: target selection, attacks, defeated enemies, damage and spell effects. All 5,752 shaders translate for Mac and iOS. The unsigned IPA is built (26.5 GiB, base plus both supplied DLC packs). Testing is deliberately short; FFX combat, later maps and a device run are not yet validated.

## What it needs

| Setting | Where | Why |
|---|---|---|
| `modules main subsdk0 sdk` | [`game.tsv`](game.tsv) | The game NROs import the movie module even though `main` does not |
| 4 GB address layout, `sys_resource 0x0` | `game.tsv` | The NPDM declares no system resource; startup takes a conventional heap, measured at 3.08 GB |
| `mem_used 0x8000000` | `game.tsv` | The rewritten initial modules exceed the default 64 MB; 128 MB covers them |
| `.vbf` / movie / texture containers stored in the bundle | `game.tsv` `zip_store` | These assets are already compressed or read by offset |

No game-specific rewriter cuts or fixed host addresses are needed.

## Modules and issue #372

- **Resolved:** [issue #372](https://github.com/seedds/nxnative/issues/372) is valid for the old loader limit. This copy has 1,432 actual registered NROs, not duplicate manifest rows. The loader now sizes its tables from the manifest ([NRO tables and snapshots](../../../docs/reference/services.md#nro-tables-sized-from-the-manifest-and-snapshots-taken-on-demand)).
- **Resolved:** `magic_0898_2015.nro` (`nro576`) has build-ID bytes that decode as `ldr x18` at `+0x44`. The NRO header must be excluded from rewriting ([NRO metadata](../../../docs/reference/rewriter.md#nro-metadata-inside-the-text-segment)).
- The launcher's `ffx_GameLauncher.nro` is `nro815`; FFX's `ffx_phyreApp_2015.nro` is `nro484`; X-2's `ffx2_phyreApp_2015.nro` is `nro839`, in this manifest's hash order. These labels are diagnostics, not address gates.
- The launcher unloads before the selected game loads. Its static allocator supplies real thread stacks from NRO bss ([NRO-backed stacks](../../../docs/reference/memory.md#thread-stacks-backed-by-active-nro-data)).
- Preloading must not charge NRO bss as additional guest memory ([NRO accounting](../../../docs/reference/memory.md#offline-nro-copies-are-not-additional-guest-memory)). Snapshots now retain initialized data only, on first load: inactive effect modules do not commit a pristine copy of their bss.

## Files and shaders

- Base RomFS: `data/FFX_Data.vbf`, `data/Common_Data.vbf`, `data/metamenu.vbf`, loose Phyre UI effects, NROs, and FFX movies. DLC index 1 contains `data/FFX2_Data.vbf` and X-2 movies. Index 2 contains collection movies and their subtitle timing files.
- VBF magic `SRYK`: two hash tables, file records, string table and 64 KB raw/zlib blocks. Effects are `RYHP` containers with adjacent NVN code and control sections, often unaligned ([Phyre shaders in VBF](../../../docs/reference/shaders.md#phyre-nvn-effects-in-virtuos-vbf-archives)).
- Tables cover the base and both supplied DLC packs: 5,752 unique programs, 974 vertex and 4,778 pixel; 1,948 padding pairs. Mac and iOS translation: 5,752/5,752, with 973 pulling vertex libraries and no failed translation.
- **Resolved:** X-2's first fragment-only binding reused the destroyed launcher's vertex program because the replay state was global. Each queue now owns its bindings ([Queue state](../../../docs/reference/nvn-objects.md#bindings-belong-to-each-queue)).
- Integer border-colour setters are needed during initialization ([Integer sampler border colours](../../../docs/reference/nvn-objects.md#integer-sampler-border-colours)).

## Mac routes

Run the command printed by `scripts/build_ipa_from_nsp.py --platform mac`. Use `DM_CTL` for menu navigation; `DM_KEYS` can automate a repeatable route.

- Fresh launch: logos, then the collection menu in roughly 10–15 seconds. `A` selects FFX. Its opening sequence reaches the ruined Zanarkand scene with characters and music.
- From the collection menu: `Down`, `Down`, `A` selects X-2. The title initially selects Load; with no save it reports “There is no saved data.” Dismiss it, select New Game with `Up`, and confirm.
- X-2's opening movie lasts about 3 minutes 40 seconds. After the following real-time arena sequence, the first battle begins roughly 5–6 minutes into a fresh launch. `A` selects Attack and confirms a target. The brief check defeated both Goons and reached Leblanc's Thunder attack; it stopped during that battle.
- Windowless diagnostic runs keep focus stable when other windows are being used. A windowed run losing focus makes the game throttle; screenshots at fixed wall times can then miss their expected frames.

## Validation

- 2026-10-28: Mac route above; no game-specific code cuts. The X-2 battle also exercises effect-NRO unload/reload. The short FFX opening route is recorded in `smoke.tsv`.
- Host unit suite and memory sanitizer checks pass; native graphics suite passes, including 394 queue-state/culling checks and 159 NVN checks. All 38 Python tool-test modules pass; graphics Python tests pass (84 tests, four skipped). Documentation checks pass.
- The unsigned IPA's directory, bundle identity and critical resources were checked: 1,432 embedded NRO table records, 1,432 manifest entries, 5,752 iOS shader libraries, matching library stamp and no signature. No device installation or device run was performed.
- Shared-code regression selection: Smash for the NRO path (static checks; it has no smoke route), Wonder and Odyssey for Nintendo's NVN paths, Kirby for another engine's NVN resource lifecycle, and Obra Dinn for Unity. Short smoke routes were chosen to limit gameplay; other builds on the same Mac make timing comparisons noisy.
- Final quick regression: Smash (static only, no shader corpus or smoke route), Kirby and Odyssey are marked pass. Odyssey reaches the same scene at 59.9 fps in both runs. Obra Dinn is marked changed (28.6 → 59.9 fps); the baseline logged loss of window focus, so this is not a controlled performance improvement. Wonder is flagged for a screenshot mismatch: the baseline reached the Flower Kingdom dialogue, while the candidate was still confirming its character; both pictures render correctly, but the timed-input route does not compare the same scene. There are no new shader/interface failures or red diagnostics in the four boot routes. The overall report remains REGRESSION because of Wonder; it is retained in the NSP folder's `0100BC300CB48000-work/regress-final/`.

## Found on this game

- [NRO tables and snapshots](../../../docs/reference/services.md#nro-tables-sized-from-the-manifest-and-snapshots-taken-on-demand).
- [NRO metadata](../../../docs/reference/rewriter.md#nro-metadata-inside-the-text-segment).
- [NRO memory accounting](../../../docs/reference/memory.md#offline-nro-copies-are-not-additional-guest-memory) and [thread-stack backing](../../../docs/reference/memory.md#thread-stacks-backed-by-active-nro-data).
- [Phyre shaders in VBF](../../../docs/reference/shaders.md#phyre-nvn-effects-in-virtuos-vbf-archives).
- [Queue state](../../../docs/reference/nvn-objects.md#bindings-belong-to-each-queue) and [integer border colours](../../../docs/reference/nvn-objects.md#integer-sampler-border-colours).

## Open

- FFX combat; later areas and effects in both games.
- A single `no render target could get an MTLTexture` diagnostic occurs when starting the X-2 movie; subsequent movie frames display normally. The attachment lifetime at that handoff remains to be investigated.
- Eternal Calm, Last Mission and bonus movies.
- iPhone validation of the unsigned IPA, including memory pressure and audio.
