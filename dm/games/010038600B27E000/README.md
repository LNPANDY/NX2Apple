# Bastion (`010038600B27E000`)

Base game 1.0.0 (v0), SDK 5.4.0, NVN API 53.313. Supergiant Games' C# engine on MonoGame 3.0 (`Microsoft.Xna.Framework`, `MonoGame.Framework, Version=3.0.0.0` in the XNB files) compiled into `main`, XACT sound banks (`Content/Audio/*.xgs` / `.xsb` / `.xwb`) through the audio renderer, on NVN. Modules `main` and `sdk` only.

On the Mac: the WB Games and Supergiant logos, the title, the main menu, Story → Normal Mode, the opening in The Rippling Walls and the first walk across it (the ground assembling under the Kid), at 60 fps (frame p50 16.67 ms, GPU 1.5–3.6 ms) with music, no red line; about 1.34 GB resident and 1.64–1.66 GB of Metal allocations, steady from frame 5,700 to 8,700 of the walk. Not run on the iPhone yet.

## What it needs

The provisional profile's guesses held: no key needed changing. Three host and tool changes were needed, each general (see [Found on this game](#found-on-this-game)).

| Setting | Where | Why |
|---|---|---|
| `sys_resource 0x0` | [`game.tsv`](game.tsv) | the NPDM declares no system resource, so `IsVirtualAddressMemoryEnabled` is false, as on Horizon: no virtual address memory. The game sets a heap of the application pool − used memory |
| 4 GB layout: `mem_reserve 0x100000000`, `mem_alias 0x10000000`, `mem_stack 0x10000000`, `app_pool 0xCD500000` | `game.tsv` | 256 MB in front + 256 MB alias region + 256 MB stack region + 3.25 GB heap region |
| `mem_used 0x4c00000` (76 MB) | `game.tsv` | the rewritten modules are larger than the default 64 MB of used memory (the NSP script's figure after the rewrite) |
| `shader_groups /Content/=content /Resources/=resources` | `game.tsv` | the MonoGame effects; see [Shaders](#shaders) |

No `pad_layout`: the virtual gamepad starts in the 2D layout (the default). No `patches.py`: the rewriter needs no cut.

## Shaders

- **Current:** 72 (18 pixel and 30 vertex in `Resources`, 24 pixel in `Content/Effects`), in MonoGame effects of MGFX version 5, read by `shader_split.py` (`mgfx_effect`): [MGFX version 5 effects (MonoGame 3.0)](../../../docs/reference/shaders.md#mgfx-version-5-effects-monogame-30). Every binding decodes, with Mario's binding layout.
- The 24 XNB effects in `Content/Effects` hold one pixel shader each; the vertex shaders come from MonoGame's stock effects in `Resources/*.dx11.mgfxo` (SpriteBatch's among them), so they are paired as single-stage programs.
- `Resources/EnvironmentMapEffect.dx11.mgfxo` and `SkinnedEffect.dx11.mgfxo` hold only DirectX bytecode, and no draw asked for a shader the map lacks on the route above.

## Rendering

- The window origin is lower left (GL), and the window textures are 1920x1080; the game draws into 1600x900 of them and crops the window to that (`WindowCrop 0,0 1600x900`). A raw `DM_NVN_SHOT` is the whole texture; `DM_NVN_SHOT_OUT` gives the presented picture.
- **Resolved: an abort at the first present.** The game fills both window textures with `WriteTexels` at boot (`main+0x9374`) and presents one before drawing into it; the host uploaded that CPU-written texture on the present thread. See [A CPU-written window texture resolved where the present is queued](../../../docs/reference/rendering.md#a-cpu-written-window-texture-resolved-where-the-present-is-queued).
- The logo screens' background is a pale green drawn by the game (the pass clears to black first), through the same pipeline as the logos, whose colours are right. Not compared with a console.

## Audio

- **Resolved: no sound.** SDK 5.4.0's command list has SDK 6's header, its first list walked in the newer layout too, and its DeviceSink is a 0x138-byte form of SDK 4's: [SDK 5: a startup list that walks in two layouts, and a 0x138-byte DeviceSink](../../../docs/reference/audio.md#sdk-5-a-startup-list-that-walks-in-two-layouts-and-a-0x138-byte-devicesink). The title music now plays from about 13 s after boot (`DM_AUDIO_DUMP`: tonal, spectral flatness about 0.1).

## Mac routes

- A fresh save into The Rippling Walls: `DM_KEYS="24:A,28:A,32:A"` (the title at about 20 s, Story, Normal Mode); the Kid lies in bed until the stick moves, from about 60 s. Then `62:LDown~1.5,65:LRight~1.5,68:LRight~2,71:LUp~2,74:LRight~2,77:LUp~2,80:LRight~2,83:LUp~2` gets him up and walks him along the first path. [`smoke.tsv`](smoke.tsv) is the first part.
- The prewarm list ([`pso_manifest.tsv`](pso_manifest.tsv)) was recorded over that whole route.

## Found on this game

General host changes first needed here; each applies to every game:

- **MGFX version 5** (MonoGame 3.0) effects, whose shaders are whole GLSLC outputs (`mgfx_effect` in `shader_split.py`): [MGFX version 5 effects (MonoGame 3.0)](../../../docs/reference/shaders.md#mgfx-version-5-effects-monogame-30).
- **A storage texture is resolved where the present is queued** (`present_enqueue` in `nvn_mtl.m`): [A CPU-written window texture resolved where the present is queued](../../../docs/reference/rendering.md#a-cpu-written-window-texture-resolved-where-the-present-is-queued).
- **SDK 5's audio command list**: a header layout only from a list that walks in exactly one, and the 0x138-byte DeviceSink (`hle_audren.c`): [SDK 5: a startup list that walks in two layouts, and a 0x138-byte DeviceSink](../../../docs/reference/audio.md#sdk-5-a-startup-list-that-walks-in-two-layouts-and-a-0x138-byte-devicesink).

## Open

- Not run on the iPhone.
- Two early boots (both with `DM_NVN_SHOT`, of five with it) stayed at frame 1 for the whole run: the main thread was in the game's decompressor (`main+0x1b4c9bc`, called from `main+0x19280`), running and waiting on nothing, but with 2.3 s of CPU in 24 s and 3.3 s in 59 s. The 16 boots after them, 8 with `DM_NVN_SHOT`, and every run since went on. Cause unknown; reads from the RomFS image on the external drive under load from other work are suspected, not shown.
- Only the base game is extracted; no update was checked.
