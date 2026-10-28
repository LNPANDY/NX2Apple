# Return of the Obra Dinn (`010032E00E6E2000`)

Update 1.0.1 (`v65536`), Unity 2017.4.28f1 IL2CPP with FMOD, SDK 8.2.0,
NVN. Modules `main`, `subsdk0` (NintendoSDK_movie), and `sdk`. No game-specific
rewriter cuts or host rules.

## What it needs

| Setting | Why |
|---|---|
| `modules main subsdk0 sdk` | The imports require all three modules, in Horizon load order. |
| `sys_resource 0` | The NPDM declares no system resource, so virtual-address memory is disabled and Unity sets a heap. |
| `mem_reserve 0x100000000`, `mem_alias 0x10000000`, `mem_stack 0x10000000` | A 3.25 GB heap region; the observed heap request is 3.14 GB. |
| `mem_used 0x4600000` | Allocation of the rewritten modules, rounded up to 2 MB. |
| `shader_groups /Data/=data` | Unity serialized assets and UnityFS bundles under `Data`. |
| `pad_layout full` | First-person movement and looking need both sticks. |

## Files and shaders

- The update has 275 RomFS files, 1.98 GB, including 13 UnityFS bundles.
- All 122 Shader objects decode to their exact ends. The stripped 2017.4 layout
  matches the release type tree's 1,313 nodes and alignment flags.
- One stripped `internalskinning` ComputeShader object contains 12 kernels;
  all 67,416 bytes decode with the 2017.4 layout (120 nodes and alignment flags).
- 1,272 unique shaders: 633 vertex, 627 pixel, 12 compute. All compile for Mac and iOS.
  `shader_pairs.tsv` has one whole-program pair; `pso_pairs.tsv` supplies 611
  supplemental pass-input cover pairs. The Mac prebuild links all 612 bases.

## Mac validation

The title, save-slot menu, newspaper, opening letter, spoken introduction,
rowing boat and ship's deck render correctly. A brief control check turns the
camera, presses the interaction button and applies forward-stick input; deeper
navigation was deliberately kept outside this check. No missing shaders,
pipeline failures or other `[RED]` lines in the completed `gameplay` and
`light-play` runs. Audio callbacks report no underruns.

The 30-second window at 80–110 seconds of `light-play` presents 1,799 frames
(60.0 fps), with frame time p50 16.66 ms / p99 17.67 ms, GPU p50 6.37 ms,
and no dropped presents. Direct presentation was used for this measurement
(see [Open](#open)). During the four-minute opening/deck run, resident memory
settles around 1.22–1.24 GB after loading the scene; GPU allocation stays around
1.02–1.04 GB instead of growing each frame.

From a fresh save, `DM_KEYS=10:A,12:A,18:A,21:A,24:A,27:A` enters the opening;
the boat is visible around 60 seconds. The short control check adds
`65:RRight~1.4,67:RUp~0.4,70:A,72:LUp~1.5`. Runs, timing TSVs and screenshots
are in the NSP folder's `010032E00E6E2000-work/run/`.

## Found on this game

- [Zero-guarded complemented jump-table index](../../../docs/reference/rewriter.md#zero-guarded-complemented-jump-table-index):
  the update's `main+0x6eea88` and `+0x6eeac0` have seven table entries, since
  the zero case branches away before complementing a three-bit index.
- [Stripped Unity Shader layouts](../../../docs/reference/shaders.md#unity-shader-layouts-written-out-for-players-without-bundles)
  and [ComputeShader objects](../../../docs/reference/shaders.md#unity-computeshader-objects):
  the 2017.4 layouts restore the engine resources and skinning kernels.
- [Legacy Unity stages lose their pass partners](../../../docs/reference/shaders.md#legacy-unity-stages-lose-their-pass-partners):
  the separately selected stages have different blob indices; the pass's pixel
  inputs supply the padding that the `OneBit/Rope` pipelines need.

## Open

- iPhone gameplay has not been tested.
- Later memories, the pocket watch and persistence across a story checkpoint
  have not been checked. The unsigned IPA is 908.7 MB; the Mac app is 2.1 GB.
- The base game 1.0.0 is not registered or validated by this profile. [PR #427's](https://github.com/seedds/nxnative/pull/427)
  base-game report is background evidence; this profile was rebuilt from 1.0.1.
- This Mac's display link repeatedly went silent during the first windowed run.
  Direct presentation (`DM_PRESENT_LINK=0`) isolates gameplay from that known
  [Mac window issue](../../../docs/reference/frame-rate.md#present-thread-rescues-a-silent-display-link);
  the profile keeps the normal presentation default.
