# SteamWorld Dig (`01009320084A4000`)

Update 1.12.0 (v65536), SDK 3.4.0, on NVN (9 shaders, BNSH files). Modules `main` and `sdk`. Image & Form's own engine (the SteamWorld series' engine, the one [SteamWorld Dig 2](../0100CA9002322000/README.md) and [SteamWorld Heist: Ultimate Edition](../010016100A186000/README.md) run on), with its shaders as loose `.bnsh` files in `Shaders/`. It ships the same `sdk` build as SteamWorld Dig 2. The standard host and rewriter run this build with no game-specific fix: no shader overrides, rewriter cuts or host changes. The profile is the NSP script's provisional one, unchanged apart from its comments and app category ([What it needs](#what-it-needs)). Only this update is registered in the profile.

On the Mac (2026-10-29, a short gameplay check, as for the other SteamWorld games): the title, slot A, the opening in the mine and its lines, then control of Rusty: walking, jumping onto ledges, climbing ladders, the pause menu and quitting to the main menu, at 60 fps (frame time p50 16.67 ms, GPU p50 about 1.6–4 ms at 1080p) and no `[RED]` line; the sound was choppy until the audio fix in [Found on this game](#found-on-this-game). The game committed its save when the new game started; in a second run the title listed slot A and Play loaded it. The unsigned IPA is built with the frame rate counter but not tested on an iPhone.

## What it needs

| Setting | Where | Why |
|---|---|---|
| 3.25 GB layout: `mem_reserve 0x100000000`, `mem_alias 0x10000000`, `mem_stack 0x10000000`, `app_pool 0xCD500000` | [`game.tsv`](game.tsv) | the provisional layout, which holds: `main` sets a heap of at most the pool − 64 MB |
| `sys_resource 0x0` | `game.tsv` | the NPDM declares 0 MB of system resource: `IsVirtualAddressMemoryEnabled` is false, as on Horizon |
| `modules main sdk` | `game.tsv` | `main` imports only from `sdk`; the game has no movie decoder |
| `shader_groups` (one per RomFS folder) | `game.tsv` | the provisional guess, kept: every shader is in `Shaders/`, so all 9 are in the `shaders` group |
| `pad_layout` (default, `simple`) | | the 2D virtual pad; the left stick walks and climbs, B jumps, A confirms and attacks, X uses a tool (the pause screen's legend) |

## Files

- RomFS: 396 files, 0.09 GB: `Audio/` (165 WAV sounds, 27 Ogg music files), `Sprites/`, `Levels/`, `Definitions/`, `Textures/`, `Menus/`, `Fonts/`, `Language/` (en-US, ja, fr, de, es, it, ru), `Shaders/` (7 `.bnsh` files); many files are zlib-packed `.z`.
- The save holds `session.xml` (the three slots), `profile_<n>.xml` and `controls.cfg` at its root. The game saves its progress at checkpoints only: quitting from the pause menu warns that unsaved progress is lost, and a new game reloaded from slot A starts the opening again.

## Shaders

- **Current:** 9 distinct shaders (7 pixel, 2 vertex) from the 7 `.bnsh` files in `Shaders/` (`BasicEffect_Color`, `BasicEffect_ColorTexture` and five full-screen pixel shaders: bloom blend, blur, fake nearest, gamma, rescale colour), all translated for the Mac.
- **Open:** the prewarm list (`pso_manifest.tsv`) is empty. The first Mac boot compiled 5 pipeline bases (126 ms, off the submit thread) by the title; a list recorded through the title and the first mine would spare the iPhone's first start those waits.

## Memory

- The process footprint stayed under 1.2 GB (1172 MiB in the mine).

## On the Mac

- After the NSP script's `--platform mac` build, its printed command runs the game; with the window covered add `DM_PRESENT_LINK=0` so `DM_CTL` screenshots still come.
- The title is up within about 20 s of start. A (Start), A (Play, slot A), then about 28 presses of A through the opening's lines give control. Left stick left walks west to the cave; B jumps, Up on a ladder climbs.
- Single frames of 40–190 ms came right after `DM_CTL` screenshots (the PNG write) and at scene changes, with no pipeline, shader library or texture upload in them; the few others were 25–80 ms ([Open](#open)).

## Found on this game

- Resolved: the sound was choppy (69% of the 5 ms blocks silent) because the host looked for the `AudioRenderSystem` at SDK 16's offset in `AudioRendererImpl`; SDK 3.4 keeps it at `+0x50`. After the fix, no blocks are silent once the music starts → [Where the `AudioRenderSystem` sits in `AudioRendererImpl`](../../../docs/reference/audio.md#where-the-audiorendersystem-sits-in-audiorendererimpl).

Otherwise it runs on mechanisms found on other games, including SDK 3.4.0's NVN and services.

## Open

- iPhone: the IPA is built but not tested.
- The empty prewarm list ([Shaders](#shaders)).
- The single 25–80 ms frames in play away from screenshots: cause unknown (not pipelines or uploads), as on [SteamWorld Dig 2](../0100CA9002322000/README.md#open).
- Only the first minutes were played; digging, the town (Tumbleton), shops, a checkpoint save and its reload, the other languages are untested.
