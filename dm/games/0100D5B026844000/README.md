# Silver Pines (`0100D5B026844000`)

The base game, 1.0.0 (v0). Unity 6000.3.15f1 IL2CPP with the Universal Render Pipeline, FMOD, SDK 21.4.7, NVN. Modules `main`, `subsdk0` (NintendoSDK_movie) and `sdk`. Plays on the Mac at its own 30 fps. No IPA has been built; iOS is untested.

## What it needs

Nothing beyond the profile the NSP script's survey guessed and the depth mode: no rewriter cuts, no `patches.py`, no host change. The general fixes it relies on came from other games (see [Found on this game](#found-on-this-game)).

| Setting | Where | Why |
|---|---|---|
| 5 GB block: `mem_reserve 0x140000000`, `mem_alias 0x118000000`, `mem_stack 0x10000000` | [`game.tsv`](game.tsv) | virtual address memory: the NPDM declares 16 MB of system resource and `main` never sets a heap |
| `app_pool 0xCD500000` | `game.tsv` | the survey's value; held through the boot, the opening and a reload into the motel street (about 2.1 GB resident) |
| `sys_resource 0x1000000` | `game.tsv` | the NPDM's 16 MB system resource |
| `depth_mode zero` | `game.tsv` | the game calls `nvnDeviceSetDepthMode` with near = 0 (`main0_z` vertex entries); see [Pipeline archive](#pipeline-archive) |

## Files and shaders

- RomFS: 1,718 files, 2.6 GB. Most of it is 1,674 UnityFS bundles (2.21 GB) under `Data/StreamingAssets/aa` (Addressables, `catalog.bin`), plus three FMOD banks and the player's `Data/*.assets` / `.resource` files.
- The split finds 56,386 stage shaders: 27,834 vertex, 27,838 pixel, 713 compute and one geometry shader. All 56,386 build for the Mac. `c1_guard.py` lists 13,372 whose c1 reads are not proven bounded.
- **Resolved by [integer entry points](../../../docs/reference/shaders.md#integer-entry-points-for-integer-colour-outputs): the street and the diner drew only fog.** URP writes its rendering-layers mask into an R8Uint target beside the float colour outputs: colour 1 in the forward pass, colours 4 and 5 in the deferred G-buffer. The 9,720 pixel shaders that do so write it from integer bits (`as_type<float>`). On an earlier nxnative (11be43d), Metal refused every one of their pipelines (float output into an R8Uint attachment), so only the fog layer reached the screen. That checkout needed a hand-written `shader_facts_manual.tsv` with 9,720 `{"fout": {...: "uint"}}` rows. `fs_uint`'s mixed entry point, `main0_m`, now covers exactly those 9,720 shaders by itself; 19,351 shaders also get `main0_u`.
- Movies: the Team17 logo and the title screen's animated background are 1920x1080 VP8, decoded by libvpx.
- A first `--platform mac` build on an M5 (10 cores) takes 45 minutes. The shader stage takes 35 of them: 18,221 Metal compiles, with the rest of the 56,386 shaders' MSL identical to one already compiled. The pipeline prebuild of 27,834 vertex / pixel pairs takes 8.
- A first `--platform mac-app` build on the same M5 takes 47 minutes: the shader stage 37, the pipeline archive for its GPU 7 (`applegpu_g17g`: 27,091 bases from the 27,834 pairs, 1.0 GB; metal-tt peaked at about 4.9 GB of memory), the Mac host and the app (5.9 GB) the rest.

## Pipeline archive

**Resolved by `depth_mode zero`.** The first `--platform mac-app` build made the app's archive for NVN's default depth mode (near = -w). The game sets near = 0, so its first start reported `made for ... depth near=-w ..., this run needs ... depth near=0 ...: the device builds` and prebuilt all 27,834 pairs before presenting a frame (no frame within 110 s on the M5). With `depth_mode zero` the archive is made for near = 0, and the first start reports `holds the bases of every shader pair (16 of 16 probed bases found)` and compiles no base on the device: from a save, the title and its menu, then the motel street. The shader input digest is unchanged. Same mechanism as [Pokémon Scarlet](../0100A3D008C5C000/README.md#pipeline-preparation-depth); see [Depth mode near = 0](../../../docs/reference/shaders.md#depth-mode-near--0-needs-the-per-mode-entry-points).

## Frame rate and memory

- The game paces itself at 30 fps on the host's vsync. In the motel street the frame time is p50 33.4 ms, p95 44 to 47 ms (300-frame windows, headless, no audio).
- About 2.1 GB resident and 1 GB of Metal allocations in the motel street, steady from frame 1,500 to 4,800.

## Mac testing

Build with `scripts/build_ipa_from_nsp.py <NSP folder> -k <prod.keys> --platform mac`; its final line runs the game with the correct paths. The game shows its title only after a button press. The first 30 seconds of a run go to pipeline preparation, so scripted presses (`DM_KEYS`) should start later than that.

## Testing

- 2026-10-28, this profile on `main` (4b0335e), `--platform mac`: the shader split gives the same 56,386 shaders (27,834 vertex, 27,838 pixel, 713 compute, one geometry) and is checked against these tables without a mismatch; stopped in the shader compile (the shader inputs are unchanged since 6d1e07b).
- 2026-10-27, Mac, this profile on `main` (6d1e07b), `--platform mac-app`, started through the app's launcher (window, no audio): a save made on the Mac with an earlier host loads its Traditional Chinese title menu, and Continue goes into the motel street (the neon sign, the lit phone booth, the player and the fog draw). The bundled archive serves every pipeline base (0 compiled on the device). Frame time p50 35 ms, p95 53 ms while another build compiled shaders on the same Mac. No red line other than `nvnTextureViewCompare`.
- 2026-10-27, Mac, this profile on `main` (78cb26d), headless, no audio:
  - **A new save:** the boot, the Team17 VP8 logo, the title with its animated VP8 background, New Game and the difficulty select (text, the portrait, the rain overlay). No red line other than `nvnTextureViewCompare` (below).
  - **A save made on the Mac with an earlier host:** the title (its menu in Traditional Chinese, the save's language) and Continue into the motel street at night. The neon sign, the lit phone booth, the player and the fog all draw. 30 fps.
  - The rerun with this profile registered (not provisional) checked the split against these tables.
- Earlier, on nxnative 11be43d with a hand-written integer-output table and VP8 decoding added locally, the game was played windowed, with sound and a controller, through the opening, the motel street and the diner. FMOD's output reported no underruns, at 30 fps (p95 about 37 ms).

## Found on this game

- [Unity 6 Shader objects](../../../docs/reference/shaders.md#unity-6-shader-objects) (6000.3.15f1): 56,386 stage shaders, read with no change.
- [Integer entry points for integer colour outputs](../../../docs/reference/shaders.md#integer-entry-points-for-integer-colour-outputs): `main0_m` for URP's rendering-layers mask, in 9,720 pixel shaders.
- [VP8 uses the same libvpx worker and output paths](../../../docs/reference/movies.md#vp8-uses-the-same-libvpx-worker-and-output-paths): the logo and the title background.

## Open

- `nvnTextureViewCompare` is unimplemented (`[RED]`, 60 to 75 calls in a short run); no visible effect has been found yet.
- A long play session on this host with audio. No `smoke.tsv` route yet.
- No prewarm list (`pso_manifest.tsv` is empty). A Mac app carries every pair's base in its archive; a run without one (`--platform mac`) builds them at its start.
- iOS: no IPA built, untested.
