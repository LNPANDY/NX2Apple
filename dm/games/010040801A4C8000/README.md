# Blasphemous 2 (`010040801A4C8000`)

Update 1.0.8 (v524288) over the base game, SDK 15.3.2, Unity 2021.3.20f1 IL2CPP with FMOD on NVN. Modules `main`, `subsdk0` (NintendoSDK_movie) and `sdk`. Plays on the Mac: title, Pilgrimage menu, a new game, opening H.264 cinematic with subtitles, awakening, movement into the weapon room, healing, Veredicto pickup, jumping and a weapon swing. Control testing deliberately stops there. The unsigned IPA is about 1.5 GB; iPhone/iPad validation remains open.

## What it needs

| Setting | Where | Why |
|---|---|---|
| `sys_resource 0x1000000` | [`game.tsv`](game.tsv) | The NPDM declares 16 MB of system resource, enabling virtual address memory |
| 5 GB guest block, 4.375 GB alias region, 1 GB application pool | `game.tsv` | The initial Mac heap check sets no heap and reaches +4.26 GB of the alias region with the hardware pool. A 1 GB pool leaves room beside StandardAllocator for Unity's own address regions |
| SDK-wide node-area and size-class alignment patches | `dm/tools/sdk_patches.py` | Applied to this SDK by the shared function matcher; no game-specific cut or host change |
| `shader_groups /Data/=data` | `game.tsv` | The serialized files and Addressables bundles all live under `Data/` |

## Files and shaders

- The merged RomFS has 1,428 files, 1.69 GB, including 1,408 UnityFS bundles under `Data/StreamingAssets`. IL2CPP metadata version 29 contains 114 assembly images and 140,569 methods.
- The DLC NSP is a licence-only package, index 1 (`010040801A4C9001`); its content is already in the update. Packing recognizes the licence. Access to the DLC campaign has not been tested.
- 4,354 shaders: 2,174 vertex, 2,178 pixel, one compute and one geometry. Eleven are Unity's GLSLC outputs in `main`, the others come from serialized Shader objects. All 4,354 compile on the Mac, with zero unresolved bindings or unfillable driver-bank reads.
- 2,177 vertex/pixel pairs; the Mac prebuild makes 2,163 bases, leaves 14 for their draws, and reports zero failures.
- All 4,354 libraries compile for iOS too. `pso_manifest.tsv` records the Mac startup and opening rooms, including Veredicto pickup; it contains shader and pipeline keys only.

## Performance and validation

- Tested on the Mac on 2026-10-28. No runtime `[RED]` message, abort or crash in the checked route. The shader split's omitted ComputeShader kernels are recorded below.
- Gameplay runs at the game's 60 fps target: late 300-frame windows report frame-time p50 16.57 ms, p95 19.34 ms, GPU p50 1.62 ms. These are diagnostic windowless measurements, not a device performance claim.
- Resident memory stays around 2.3–2.4 GB in the opening rooms, with about 1.58 GB allocated by Metal. The alias-region high-water mark is +3.51 GB of 4.375 GB; no sustained growth while standing in the weapon room.
- FMOD uses one AudioOut; the callback log reports no underruns in the settled run. NintendoSDK_movie decodes the H.264 pictures, which are visible in the windowless run.
- The Python tool suite passes (379 tests across 37 files, including Mac packaging; 16 skipped). Host and shader-chain sources are unchanged, so other-game runtime regressions were not run.

## Mac route

Build with `scripts/build_ipa_from_nsp.py <NSP folder> -k <prod.keys> --platform mac`. Use the printed command and a `DM_CTL` file to drive the game: A at the title, A on Pilgrimage, A on the first slot, then A on New Game.

The title route can start with `DM_KEYS="f1400:A,f1500:A,f1600:A"`, then the final New Game confirmation through `DM_CTL` once the slot screen is ready. Let the opening play, or hold B to skip when it permits. In play: left stick / D-pad to move, B to jump, Y to attack, X to heal, Up to interact. Move right from the awakening room to the three statues and interact beside the left statue for Veredicto. The default 2D touch-pad layout is sufficient.

Keep the game focused during its opening cinematic. Unity pauses the sequence after a Mac focus-loss notification, while menus and frame submissions can still run. A windowless diagnostic run (omit `DM_WINDOW`, `DM_PRESENT_LINK=0`) plays the cinematic and supports `DM_CTL` screenshots without focus changes. `DM_PRESENT_LINK=0` also allows screenshots when macOS stops the display link of an unfocused window; it is a diagnostic option, not a profile setting.

## Found on this game

Existing mechanisms used by this profile:

- [The SDK's address-region node area](../../../docs/reference/memory.md#the-sdks-address-region-node-area).
- [Size-class alignment doubles Unity's regions](../../../docs/reference/memory.md#size-class-alignment-doubles-unitys-regions).
- [Unity's video planes and checking the movie path](../../../docs/reference/movies.md#unitys-video-planes-and-checking-the-movie-path).

## Open

- iPhone/iPad validation, save reload, combat encounters, later areas and the DLC campaign. Only the opening control check above was run; the base version was surveyed but not played or registered.
- The shader split reports ComputeShader objects in `Data/Resources/unity default resources` whose stripped type hash `abd9135b8ce83d043fef4e9ec7f53366` has no available tree. Their kernels are omitted; no missing-shader runtime diagnostic has appeared in the startup route.
