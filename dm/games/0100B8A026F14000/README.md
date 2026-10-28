# FINAL FANTASY RESONANCE, Asian release (`0100B8A026F14000`)

Update 1.0.1 (v65536), SDK 20.5.17, Unreal Engine 5.6.1, NVN and CRIWARE sound/movies. This is the regional build described as HK/Chinese in [PR #126](https://github.com/seedds/nxnative/pull/126) and [PR #304](https://github.com/seedds/nxnative/pull/304), and Korean in [PR #289](https://github.com/seedds/nxnative/pull/289). All three register the same title ID and `main` build, `b7f965b9d7227db8e29f04e84ea7331b`; they need one profile. Language is selected separately (`ko`, `zh-Hant` or `zh-Hans`). The [JP release's note](../0100606026F12000/README.md) describes the shared engine and mechanisms.

**Status:** contributors report Mac field/save gameplay and the first battle/summon, and iPhone Air gameplay through the first scene at 60 fps. These are the source PRs' results, retained with their scope below. Consolidation has not rerun this regional build; only the JP release is available locally.

## What it needs

| Setting | Where | Why |
|---|---|---|
| FMallocBinned3 constructor cut `main+0x137f0` | [`patches.py`](patches.py), `main` `b7f965b9…` | verified `bl 0xae770` -> `nop`; the constructor reserves 38 GB of address space. The host takes over the object at `main+0x77c6210` with the 32-slot vtable layout at `main+0x67df800` (`hle_uemalloc.c`, `UE5_6`) |
| 4064 MB engine region in the 5 GB guest block | [`game.tsv`](game.tsv) | the same layout as the JP release: its [memory section](../0100606026F12000/README.md#memory) explains why a 2 GB region is too small. The shared `sdk` build's node-area cut already applies |
| `fps_target 60`, game present interval | `game.tsv`, `hle_fpslock.c` | write both copies of this build's `rhi.SyncInterval` through the console object at `main+0x8adca10+0x10`; #289 identified its registering constructor at `main+0x149e0a0`. The engine then requests interval 1 itself. `DM_FPS_TARGET=30` restores interval 2; `0` leaves the game's setting alone |
| `tex_dyn_slots on` | `game.tsv` | the same 2,077 particle vertex shaders as the JP release select separate textures dynamically through `c2` |
| Buffer texture/image types and unsigned fragment output | [`shader_facts_manual.tsv`](shader_facts_manual.tsv) | #289 supplies 35 keyed facts, including #304's `c254eaa40e0c4f1e` unsigned output for `CopyStencilToLightingChannelsPS` and its `R8Uint` attachment. The generated facts merge these over the control-section facts |
| `pad_layout full` | `game.tsv` | the field uses both sticks, including its camera |

The regional `main` has its own build-gated allocator, frame-rate and rewriter registrations. `subsdk0=ab62fe8edd07a6a293f885d54359e559` and `sdk=0023a1b06130cd795f7bc4613772af0a` are shared with the JP release. No additional SDK cut is needed, and no `present_interval display` override is needed for the registered frame-rate write.

## Shader tables and prewarm

The profile retains #126's package/index ordering. All three submissions contain the same **73,496 stage/key entries** (9,253 vertex, 61,305 pixel, 2,934 compute and four geometry); #126 and #304 maps are byte-identical, and all three shader-pair tables are byte-identical. #289 orders its `#IO` extraction sources differently, so its package/index rows must not be spliced into this map. Shader facts and prewarm entries are keyed by shader hash and can be retained independently of that ordering.

The shader libraries are the same engine-global and game-material libraries described in the JP note's [files section](../0100606026F12000/README.md#files): 3,542 + 70,702 shaders, extracted from IoStore through the game's own Oodle service. #289 records two type-8 library chunks and 5,919 type-9 shader groups. Its [`pso_manifest.tsv`](pso_manifest.tsv) contributes 191 shader, 111 render-pipeline and 47 compute-pipeline seeds from its Mac route. The serialized render keys still have the current 432-byte layout; shader keys refer to the retained map. These are recorded seeds, not a claim of newly measured prepare time.

The update tag is normalized to `v65536`, as used by the NSP script and #289. #126/#304 called this same module build `v1`; the display version remains 1.0.1. The earlier 73,488-shader figure in #126's description is superseded by the complete map's 73,496 entries.

## Reported testing

These reports predate the consolidated profile. They do not establish a current-chain regression result.

- **#126, huangzhuangchao, head `30972248`:** the full NSP-script run used base 1.0.0 plus update 1.0.1, rewrote every module and reportedly built all 73,496 requested shaders. Mac gameplay reached the field with sound and a working save. Profile listing and `dm/tools/tests/test_patches.py` passed.
- **#289, willreg, head `1842ed09`:** the latest PR description reports title, New Game (Normal), opening, first field, Continue, first battle and Eldrake summon on the Mac at 60.0 fps, with no missing shaders or red lines. The enemies, Eldrake placement, turn timeline, battle menu and summon cutscene rendered correctly. Earlier measurements were 59.7-59.8 fps, 16.7 ms median frame time, a 28 GB guest reservation and Unreal's heap on a host malloc zone. Its description reports all 73,496 shaders building without failure.
- **#304, 4202217, head `3b32d7d6`:** an iPhone Air played from the launcher through the opening and difficulty choice into the first scene in Traditional Chinese (`DM_LANG=zh-Hant`), at 60 fps with the host Unreal allocator active; DLC `0100B8A026F15002` packed. Roadside fire/light, smoke, fireball and shield effects rendered without flicker with b1tdr3amer24's [#168 fixes](https://github.com/seedds/nxnative/issues/168) applied on top. That effect test was not on #304 alone; the fixes have since landed in `99d0aae3`.

#289's branch checks: 29 Python tool-test files passed; host unit, TSan and memory-TSan tests passed; 5,334 texture checks passed; all 65 graphics targets compiled and CPU targets passed; the iOS compile check covered 178 files without failure; the iOS smoke build succeeded; the pinned ruff/pyright ratchet had no new findings. #304 reported 196 tool tests with six skips. These remain historical checks of those branches, not of this source tree.

**Historical contradictions:** #289's checked-in note still lists misplaced Eldrake, an isolated texture mismatch, shader failures and no iPhone testing; its later PR description reports corrected Mac battle/summon rendering and a complete build, while also retaining an older eight-failure paragraph. The later Mac report supersedes its earlier rendering status. Exact shader success counts remain tied to the source revision; #304 provides independent iPhone evidence.

## Mac routes

The [JP routes](../0100606026F12000/README.md#mac-routes) were used in #289: brightness, title, New Game, Normal and the opening lead to the first field at about frame 9,600 at 30 fps. Continue resumes its field save, then walking north enters the first battle. #289 used a packaged Mac `.app` so it stayed active during the run. Scripted `DM_KEYS` input and keyboard input take different paths; its packaged battle run also checked the battle UI and summon skill.

## Found on this game

- The existing [host Unreal allocator](../../../docs/reference/memory.md#unreals-fmallocbinned3-replaced-by-the-host-allocator) applies to this regional build at the verified offsets above.
- The [bindless-phi fix](../../../docs/reference/shaders.md#bindless-reads-whose-handle-phi-also-carries-other-values) and [aligned buffer-texture copy](../../../docs/reference/rendering.md#buffer-textures-at-offsets-below-16-bytes) from #168 were confirmed on an iPhone Air in #304's particle-effect test.
- **Resolved bring-up failures, #304:** the provisional 62 GB engine request failed guest-address-space reservation. A capped region without the regional allocator takeover then faulted at `main+0x1385c` (`sig=11`, address `0x30`) because the allocator vtable remained zero. Registering both the cut and takeover with the capped layout got past both failures.
- **Historical image-extent abort, #304:** the old emulated image-atomic path compared a bound texture with the translator's guessed declaration and aborted in the first scene. Native Metal image atomics replaced that path in `f8642c48` ([image atomics](../../../docs/reference/shaders.md#image-atomics)); its old `imga_extent` patch is not carried here.

## Consolidation checks (2026-10-28)

- All 73,496 regional stage/key entries matched the local JP shader set. Each JP record was checked against the regional control-and-code hash and reordered into a separate validation package with this profile's indices. This establishes identical shader inputs, not identical regional executable/resource behavior.
- On the initial `f4a24b87` base, the regional Mac host built; all 178 iOS source files compiled, and the complete host and Metal graphics suites passed. Python tool tests: 491 run, 16 skipped, no failures. Before publication, rebasing onto `39509760` passed all 509 Python tool tests (16 skipped), 78 focused profile/docs tests and the production frame-limit tests again. The generated game-patch index was refreshed for the regional registrations.
- The production frame-limit test covers the regional build at 60 and 30 fps, disabled override, repeated writes after a level resets the interval, a mismatched build and a console pointer that is not initialized yet. Both thread copies are checked.
- All 35 manual facts were checked against the merged generated table, every shader/compute prewarm key exists in the map, and the current production parser accepted all 111 recorded render-pipeline keys. Their embedded shader keys and stages also match the retained map.

## Open

- **Current:** fresh regional gameplay is unavailable because its NSP/executable build is not local. The contributor reports above are the regional runtime evidence. A full Mac/iOS build of the hash-verified shared shader inputs is queued, cooperatively paused for another regression's compile/measurement window; it is not yet a green shader result. An ANIMAL WELL full regression control is queued after it. Fewer than five controls are appropriate here because the host changes add only exact-build registrations for this regional `main`; synthetic tests exercise that build and an unknown build directly, while the existing-game run checks that unrelated builds remain unaffected.
- **Current, independent translator work:** #304's `GenerateCall` fix handles call arguments that the AST optimizer turns into constants/expressions. It reports compute translation improving from 1,102 to 2,096, with all 2,096 compiling for iPhone. Current `main` still looks every argument up as a local variable; the fix needs separate review, current translator/chain rebuilding and multi-game validation. This profile does not mask that failure or replace it with a profile switch.
- The contributors tested opening/early field/battle scenarios, not a full playthrough. The precise shader failures and memory use on the current chain remain to be checked on this regional build.
