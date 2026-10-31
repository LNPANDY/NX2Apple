# Atelier Ryza: Ever Darkness & the Secret Hideout DX (`0100199023B2E000`)

Update 1.2.0 (v65536; the title screen says "Ver. 1.02") over the base game, SDK 18.3.2. Gust's engine on Koei Tecmo's KTGL (`KtglFsThread_Host`, `KTSL2` sound) on NVN. Modules `main`, `subsdk0` (NintendoSDK_movie: the opening movie) and `sdk`. The DLC NSP is a licence only. Plays on the Mac at 30 fps, as on the Switch: the opening movie, the title, a new game through the opening story into the field on Kurken Island (walking, the menu, the map), and a load of that save. An unsigned IPA has not been built; iOS is untested.

## What it needs

| Setting | Where | Why |
|---|---|---|
| 4 GB layout: `mem_reserve 0x100000000`, `mem_alias 0x10000000`, `mem_stack 0x10000000`, `app_pool 0xCD500000`, `sys_resource 0x0` | [`game.tsv`](game.tsv) | the NPDM declares no system resource: no virtual address memory; `nninitStartup` sets a heap of 3.14 GB in the 3.25 GB heap region |
| `pad_layout full` | `game.tsv` | a 3D game: the right stick turns the camera, the D-pad opens the event log and the map |
| Node area cut 1 GB → 62 MB and 2 MB region alignment | `dm/tools/sdk_patches.py` SDK-wide rules, `sdk` build `f118ae1c…` (`sdk+0x13be4c`, `+0x13bee0`; `+0x13c034`, `+0x13c03c`, `+0x13c040`) | the SDK-wide function-matched cuts; no cut is registered for the build |

No code of the game is cut, and the profile needs no run-time key: the game sets present interval 1 and paces itself to 30 fps.

## Files and shaders

- RomFS: 14,163 loose files, 10.35 GB, nearly all under `Data/NX`: G1T textures, G1S shader files, `*.elixir.gz` archives, `KTSL2` sound banks, four MP4 movies; event scripts and XML tables beside them.
- 1,049 shaders (595 pixel, 394 vertex, 58 compute, 2 geometry), all built for the Mac: GLSLC outputs in the G2S containers (`_S2G3000` / `_S2G7000`) of `Data/NX/Shader/*.g1s` and `PostEffect/*.g1s`, the bare outputs of `ShaderOriginal/*.fpo` / `*.cpo`, the elixir archives, and 67 in `main`. The vertex shaders are single-stage programs, paired with a cover pixel shader.
- **Resolved: every frame black, the title screen included, with 26 shaders not in the shader map in the first minute.** They were the post effects' GLSLC outputs in `Data/NX/PostEffect/pe_pack.elixir.gz`, one of the 156 `.gz` files (of 4,112) in Gust's chunked zlib; the other 3,956 are `CRAE` archives stored as they are. The split now inflates that form: [Gust's chunked zlib `.gz` files](../../../docs/reference/shaders.md#gusts-chunked-zlib-gz-files). Two of the dumped shaders had a split shader's code area with other compile information at control +0x7d0 (`CopyDepthToColor.fpo`'s against the archive's copy): another compile of the same source, not a shared control section, so `shader_key_skip` was not the answer.
- **Resolved: up to five `texture type mismatch … bound as is` lines over the opening** for a cube texture (NVN target 8, format 0x42) in a slot declared 2D: a compute shader of `CLC.g1s` (slot 1), pixel shaders of the `PBB-*` materials (slots 8 and 20) and the river's vertex shader `e8af9589084ea494` (`ObjectRiver_Gb.g1s`, slot 0). The host now binds the cube's first face as a 2D view: [Compatible views for a mismatched declared texture type](../../../docs/reference/rendering.md#compatible-views-for-a-mismatched-declared-texture-type). The field looked the same before and after.
- **Current:** the same slots hold other textures in other runs, so they look like stale bindings the draws do not set: the river's slot 0 a buffer texture in some runs (read as zero, one red line), the `PBB-*` pixel shaders' slot 20 a 3D texture in one run (no view bridges it; two red lines). Nothing on screen looks wrong.

## Display, input and movies

- The window texture is 1920x1080 with a full crop; the scene renders into 1600x900 targets. Screenshots in this note were taken with `DM_NVN_SHOT_OUT=1280x720`.
- The opening movie is H.264 1280x720 with AAC, which NintendoSDK_movie decodes through the host's movie service.
- The game reads the six-axis sensor handles but no touch screen and no mouse.

## Frame rate and memory

- **Current:** 30 fps on the Mac (an Apple M6, headless): frame time p50 33.4 ms, p95 35.0 ms in the field, GPU about 7 ms a frame.
- About 4.0 GB resident and 2.4 GB of Metal allocations in the field, 3.9 to 4.0 GB over the opening story and the first minutes of play.
- The prewarm list (`pso_manifest.tsv`, 318 lines) was recorded over the route below, from boot to the field, and a load of that save.

## Mac routes

- Build with `scripts/build_ipa_from_nsp.py <NSP folder> -k <prod.keys> --platform mac`; its last line runs the game.
- From a fresh save: A at about 45 s and again 3 s later, Plus skips the rest of the opening, A at "Press any button", A on New Game; then A every second goes through the opening story into the field on Kurken Island (about 4 minutes; `DM_KEYS=45:A,48:A,52:Plus,56:A,62:A*260/1`). The game autosaves there.
- With a save, the title menu selects Load Game: the same keys up to about 68 s load the autosave into the field.
- In the field the left stick walks relative to the camera, R runs, Y swings the staff, X opens the menu and D-pad Down the full map.

## Testing

- 2026-10-30, Mac (headless, no audio), the provisional profile and then this one: the routes above, the menu and the map, and walking in the field; no red line but the texture type mismatches above once the shaders were split.
- 2026-10-30, `--platform mac` from this profile in `dm/games`: the split matched these tables and all 1,049 shaders built (under a minute from the cache).
- 2026-10-30, Mac (headless), the worktree's host with this profile: the save load route, walking, the menu; the prewarm list read (318 lines; 172 shaders, 143 render and 3 compute pipelines in 0.34 s). Another session's shader builds loaded the Mac meanwhile (load average about 20), and frame time p95 rose to 60–85 ms with short submits and GPU times: the game's own threads were starved, not the host's NVN path.

## Open

- iOS: no IPA built yet; untested on a device. The Mac's 4.0 GB resident in the field is close to what an iPhone allows a game.
- Not reached: a battle, synthesis, the mainland; sound on a Mac with audio out was not listened to.
- The texture type mismatches above: what the Switch reads from a cube texture through a 2D sample (taken to be the first face) was not measured, nor what it reads from the buffer and 3D textures left in those slots.
- Only update 1.2.0 is registered. Other versions come from a derived profile.

## Found on this game

- [Gust's chunked zlib `.gz` files](../../../docs/reference/shaders.md#gusts-chunked-zlib-gz-files): `gust_gz` in `shader_split.py`, 921 → 1,049 shaders.
- [Compatible views for a mismatched declared texture type](../../../docs/reference/rendering.md#compatible-views-for-a-mismatched-declared-texture-type): the cube → 2D view (`tex_fit`).
- An SDK 18.3.2 instance of [the SDK's address-region node area](../../../docs/reference/memory.md#the-sdks-address-region-node-area), cut by the SDK-wide rule.
