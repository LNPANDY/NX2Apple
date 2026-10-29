# The Legend of Zelda: Echoes of Wisdom (`01008CF01BAAC000`)

Update 1.1.0 (v196608) over the base game, SDK 20.5.1, NintendoWare G3d / Ui2d / Vfx / Atk / Font on NVN. Modules `main`, `subsdk0` (GLSLC), `subsdk1` (NintendoSDK_movie) and `sdk`.

## Status

Playable on the Mac: title movie and logo, file selection, the opening autosave and its reload, and Link's opening Suthorn Ruins corridor through the raised door, rubble jump and upper hall. Movement, jumping, sword input and the right-stick camera work. Both Mac and iOS shader builds produce all 9,858 libraries with no unresolved bindings. An unsigned IPA was built (about 7.8 GB); iOS gameplay remains untested.

## What it needs

| Setting | Where | Why |
|---|---|---|
| 4 GB address space, 256 MB alias and stack regions, `app_pool 0xCD500000` | [`game.tsv`](game.tsv) | NPDM declares no system resource; the game sets a 3.11 GB heap inside the 3.25 GB heap region |
| `mem_used 0x6400000` | `game.tsv` | the rewritten modules need 100 MB, exceeding the default 64 MB |
| `sys_resource 0` | `game.tsv` | NPDM META +0x14 is zero: virtual address memory is disabled |
| `pad_layout full` | `game.tsv` | the right stick rotates the camera |

No game-specific rewriter cuts, SDK cuts or host branches are needed for the tested route. Only update 1.1.0 is registered; the base build has not been brought up.

## Rendering and shaders

- **Resolved: the Mac app had no shader-pair tables** ([Shader-pair tables in a Mac app](../../../docs/reference/shaders.md#shader-pair-tables-in-a-mac-app)), so the host skipped the pipeline prebuild although all 9,858 shader libraries were built. The first app had a 308.4 ms frame, 283.5 ms of it pipeline acquisition and 5.9 ms GPU work. With the tables an offline prebuild built all 7,495 bases with no failure. A player first reported audio over half a second ahead of the picture and drops to about 50 fps; after repacking, completing the prebuild and restarting the same opening, audio in sync or only slightly off and no stutter seen. This is playtest feedback, not a controlled cold-cache A/B (the learned pipeline list and the restart changed too), so neither a general synchronization fix nor hitch-free later play is established. Found by [PR #260](https://github.com/seedds/nxnative/pull/260).
- **Open: short dips below 50 fps on entering the castle or changing scenes** (a later playtest, not sustained slow movement). A nearby foreground frame took 212.0 ms (189.7 ms submit/present, 7.1 ms GPU) with six new pipelines, 46 new shader libraries, 134.3 ms of pipeline and library acquisition and 34.0 MB of first texture uploads (6.7 ms); 145 hybrid draws, so the prebuilt stand-ins were in use. This does not isolate compiler CPU time, and other long transition frames had little or no pipeline work. The pipeline archive bundled with the app (since [PR #241](https://github.com/seedds/nxnative/pull/241)) has not been measured on this game. Background-window timing is excluded.
- **Current:** lower-left window origin and near-zero depth, both selected from the game's NVN calls. The existing host handling used by [Link's Awakening](../01006BB00C6F0000/README.md#rendering) applies.
- **Resolved: a false red cube/2D warning at the first raised-door transition.** The particle fragment shader `aca252efc381a89d` (`region_common/effect/Common.ptcl`, BNSH at `0x59bc000`, variation 3868) chooses reflection cube slot 14 only when the first integer in uniform slot 13 is positive; otherwise it samples cube slot 13. The captured failing draw has that integer equal to zero and a valid 64×64 cube in slot 13. Slot 14 retains a 1408×792 2D depth-stencil texture (ID 272), so it is unused by this draw. The NVN descriptor itself is 2D: no cube view was lost. The existing zero-cube binding is valid; reporting the binding as a rendering error was wrong. Its [general handling](../../../docs/reference/rendering.md#a-2d-texture-in-a-cube-slot-binds-the-zero-cube) now reports an informational fallback. The particle shader and rendered output require no workaround.
- **Warning validation:** the isolated replay first reproduced the red line in 52.6 s; tracing captured the conditional input and selector. After the fix, the same fallback and the following room render without red lines (63.3 s through frame 3600). The GPU regression has 42 checks under Metal API validation: all pass, versus six false diagnostic failures before the fix. Reproduction scripts, isolated saves, logs and the room screenshot remain under the game's work folder in `cube-repro/`. The unsigned IPA was rebuilt with the fix.
- 9,858 unique shaders: 5,268 vertex, 4,553 pixel and 37 compute; 7,495 variation pairs. The split finds 9,818 in RomFS containers and 40 in `main`. No unbuilt shader and no undecoded binding in the full Mac build.
- **Current:** 281 prewarm entries in [`pso_manifest.tsv`](pso_manifest.tsv), recorded through the title, menus, save reload and opening corridor. The final Mac check loaded 144 shaders, 129 render pipelines and eight compute pipelines in 0.37 s of background work, with no unmatched shader keys.
- Files: models and maps in `region_common/actor` and `region_common/map`, shared BNTX textures in `region_common/sharedtexture`, 96 `.bfsha` archives under `region_common/shader`, six `.ptcl` effect files, and SARC `.arc` UI archives. Nineteen WebM movies; NintendoWare sound in `region_common/audio/edward.bfsar` and `.bfstm` streams.

## Audio and memory

- **Current:** the SDK audio renderer runs at 48 kHz, 240 samples per frame, 96 voices and a six-input DeviceSink. The Mac callback reports non-silent output and no underruns in the tested route.
- The first dungeon corridor settles around 1.7–1.8 GB resident with 1.3 GB allocated by Metal. Level transitions change the footprint; the seven-minute repeat ends at 1,831 MB resident / 1,261 MB Metal, with a stable 490-pool count and no continuing growth in the stationary corridor windows.
- The corridor runs at the game's 60 fps when the Mac window is presenting. First-use pipeline compilation causes hitches (see the shader-pair tables under [Rendering and shaders](#rendering-and-shaders)). Window-inactive timing is not a gameplay frame-rate measurement.
- **Validation:** four-minute and seven-minute repeats through the opening corridor, followed by an 85-second run of the finalized profile with prewarming enabled. The final run has no red line. Timed runs end deliberately with SIGALRM (`CRASH sig=14`), rather than a game crash. The unsigned IPA's ZIP CRC check passed; it contains all 9,858 base shader libraries and no signing entries.

## Mac routes

The development build is `01008CF01BAAC000_build/` beside the NSPs, with runs and diagnostic saves in `01008CF01BAAC000-work/run/`. Set `DM_ROMFS` to the build's `extract/v196608/RomFS`, `DM_MSL_DIR` to `shader/cache`, and `DM_NVN_SHMAP` to this profile's `shader_map.tsv`.

- A fresh save starts the opening prologue and creates File 1's Suthorn Ruins autosave. Subsequent starts show the title.
- From that save, `DM_KEYS="f600:L+R~0.5,f720:A,f840:A,f960:Up,f1080:A"` selects File 1, the autosave, then Yes (the confirmation initially selects No).
- In the opening corridor, `LUp~5` reaches the first raised door platform; `LUp+B~1.2` jumps onto it and triggers the opening. In the next room, jump over the low rubble with B, then walk up the stairs. The right stick rotates the view; Y swings the sword.
- `DM_CTL=<file>` accepts live inputs and `shot <absolute PNG path>` as described in [debugging](../../../docs/agents/05-debugging.md#scripted-input-and-thread-scheduling).

## Open

- Later gameplay and iOS runtime validation remain open.

## Found on this game

- **Mac app pair tables:** [Shader-pair tables in a Mac app](../../../docs/reference/shaders.md#shader-pair-tables-in-a-mac-app).
- **Unused conditional cube inputs are not rendering errors:** [A 2D texture in a cube slot binds the zero cube](../../../docs/reference/rendering.md#a-2d-texture-in-a-cube-slot-binds-the-zero-cube).
- **A stale `DM_ROMFS` crashed the game 0.3 s after `nnMain`:** [A stale `DM_ROMFS` path crashes the game soon after `nnMain`](../../../docs/reference/packing.md#a-stale-dm_romfs-path-crashes-the-game-soon-after-nnmain).
