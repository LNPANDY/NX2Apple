# Captain Toad: Treasure Tracker (`01009BF0072D4000`)

Update 1.4.2 (v393216) over the base game, SDK 8.2.0. Nintendo EPD Tokyo's engine (the `al` library over sead / agl, as Super Mario 3D World and Super Mario Odyssey; NintendoWare G3d / Ui2d / Vfx / Atk), on NVN. Modules `main` and `sdk`; the `sdk` is the build Link's Awakening 1.1.0 runs ([01006BB00C6F0000](../01006BB00C6F0000/README.md)). `main` exports its symbols (48,804 defined), so `sdis.py --find` names most functions. Brought up with no host change; plays on the Mac and on the iPhone. The README lists its IPA at about 2 GB.

On the Mac: the opening course, the cutscene that follows it and the title menu; the first save, the Episode 1 book and Plucky Pass Beginnings; the Special Episode's book (add-on content 1). 60 fps with no red line. Three minutes in a course: about 950 MB resident and 690 MB of Metal allocations, flat.

## What it needs

| Setting | Where | Why |
|---|---|---|
| `op_mode handheld` | [`game.tsv`](game.tsv) | docked, the game's pointer (touch blocks, stunning enemies) is the Joy-Con gyro, which the host does not have; handheld, it is the touch screen, which the iPhone front end feeds with the touches no gamepad control takes. Handheld also renders at 720p |
| `pad_layout full` | `game.tsv` | the virtual gamepad starts in the 3D layout: the right stick turns the camera |
| 4 GB layout: `mem_reserve 0x100000000`, `mem_alias 0x10000000`, `mem_stack 0x10000000`, `app_pool 0xCD500000` | `game.tsv` | no system resource in the NPDM: the game sets a 3.00 GB heap (pool − 64 MB). `main`'s bss is only 1.4 MB. 13 Sentinels' partition, as the other EPD games without virtual address memory |

No `patches.py`; `dm/tools/sdk_patches.py`'s SDK-wide rules cut its `sdk` build (`3ae34e68…`): the node area and 2 MB alignment of large regions.

## Rendering

- **Resolved: same-pass feedback on the Mac too.** agl's post-effect program 987 (`54f58a7cab608766`, `agl_technique_pfx.sharcb`, the same program as 3D World's `66a71a3081b91b9a` in another build) writes the 1920x1080 RGB10A2 image as an attachment while sampling it. In 3D World the 16x16 magenta blocks showed only on the iPhone; here a Mac (Apple M6) showed one in about half the frames of the opening course, moving with the falling leaves. `DM_NVN_FB_SNAP=all` cleared every frame and named this one shader, which the profile then listed in a `feedback_snap` key. The host now snapshots such draws without a list ([Same-pass feedback read through a snapshot](../../../docs/reference/rendering.md#same-pass-feedback-read-through-a-snapshot)); this game was not run again with it (not on this Mac).
- Its opening course renders with agl's transient targets: the storage-sharing table keeps its 26 entries and takes none over under the takeover rule (found on STEINS;GATE RE:BOOT), with the same memory and frame times as before.

## Files and shaders

- RomFS is almost entirely Yaz0-compressed SARC (`*.szs`).
- 7,258 shaders: bfsha (BNSH) in `ShaderData`, agl sharcb (BAHS) and layout BNSH in `SystemData`, particle effects in `EffectData` and 40 BNSH in `main`, all with Mario's binding layout (every binding decodes). The one that does not build is the fin fur geometry shader (`RenderFinFur`), as in 3D World: Metal has no geometry stage.
- `main` imports `glslcCompile` and holds agl's GLSL sources, but no module defines it, so nothing is compiled at run time. `shader_split.py` now asks for captured GLSLC outputs only when a module of the profile defines `glslcCompile`, as `profile_guess.py` does.
- Shared fonts: it records them as plain TTFs and calls `Decode` only for its BFTTF formats (SDK 8: the address is the TTF).

## Add-on content

- Index 1 is the Special Episode; index 2 holds a 1-byte marker file.

## Mac routes

- A fresh save starts in the opening course with control of Toad. `DM_KEYS="f900:LUp+LRight~2.0,f1030:LUp+LLeft~2.2,f1170:LDown+LLeft~2.8,f1345:LDown+LRight~0.4,f1375:LUp+LRight~2.0,f1500:LDown+LRight~1.5,f1595:LUp+LRight~1.4,f1685:LUp+LLeft~0.9"` walks him to the star: through the arch, up the back ramp, around the rock on the grass top and over the roof. The course clears at about frame 2,100 and the title menu comes at about 5,200, with the first save; A dismisses the title's notices.
- From that save, `DM_KEYS="f600:A,f1000:LRight~0.3,f1300:A"` starts Plucky Pass Beginnings (play from about frame 1,900).
- How the route was found: screenshots alone took a dozen runs and still lost Toad behind the scenery, and turning the camera mid-route made the same input land differently each run. A probe reads the player's position every frame, `DM_PROBE=main:1fb2e0@*x0+48+8` (`PlayerActor::control`, the actor's pose at +0x48, the position 8 bytes into it, as `al::getTrans` reads it: x, y (height), z as three floats); the guest heap is laid out the same in every run, so the actor is at the same address. The stage map (`StageData/<stage>.szs`, a BYML) lists every actor with its `Translate`, including the goal and the rail the guide character walks. Stick directions are camera-relative: on the default camera two directions together (`LUp+LRight`) move along one world axis. Holding against walls, which stop the player at the same place in every run, made the route reproduce in 5 of 5 runs.

## Found on this game

General host changes first needed here; each applies to every game:

- **GLSLC captures only when a module defines `glslcCompile`** (`shader_split.py`, as `profile_guess.py`): [Built-in shaders compiled with the game's own GLSLC](../../../docs/reference/shaders.md#built-in-shaders-compiled-with-the-games-own-glslc).
- **Routes planned from a position probe and the stage map**: [05, Scripted input and thread scheduling](../../../docs/agents/05-debugging.md#scripted-input-and-thread-scheduling).

## Open

- The fin fur geometry shader does not build.
