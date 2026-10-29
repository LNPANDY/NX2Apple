# SteamWorld Dig 2 (`0100CA9002322000`)

Update 4.1.1 (v196608), SDK 3.4.0, on NVN (18 shaders, BNSH files). Modules `main` and `sdk`. Image & Form's own engine (the SteamWorld series' engine, the one [SteamWorld Heist: Ultimate Edition](../010016100A186000/README.md) runs on), with its shaders in a zip `.impak` archive in RomFS. SDK 3.4.0 is the oldest in the games table. The standard host and rewriter run this build with no game-specific fix: no shader overrides, rewriter cuts or host changes. The profile is the NSP script's provisional one, unchanged apart from its comments and app category ([What it needs](#what-it-needs)). Only this update is registered in the profile.

On the Mac (2026-10-29, a short gameplay check, as for the SteamWorld Heist games): the title, a new game (slot 1, Normal), the opening on the cliff, then the first stretch of desert: walking, jumping and the tutorial prompts (walk, jump, wall jump), at 60 fps (frame time p50 16.67 ms, GPU p50 about 1.5 ms at 1080p) with audio rendered (choppy until the audio fix in [Found on this game](#found-on-this-game)) and no `[RED]` line from the game. The game saved after the new game started; in a second run the title listed the slot ("Game 1") and Continue loaded it. The unsigned IPA is built with the frame rate counter but not tested on an iPhone.

## What it needs

| Setting | Where | Why |
|---|---|---|
| 3.25 GB layout: `mem_reserve 0x100000000`, `mem_alias 0x10000000`, `mem_stack 0x10000000`, `app_pool 0xCD500000` | [`game.tsv`](game.tsv) | the provisional layout, which holds: `main` sets a heap of at most the pool − 64 MB |
| `sys_resource 0x0` | `game.tsv` | the NPDM declares 0 MB of system resource: `IsVirtualAddressMemoryEnabled` is false, as on Horizon |
| `modules main sdk` | `game.tsv` | `main` imports only from `sdk`; the game has no movie decoder (its cutscenes are textures, `.bntx.z`) |
| `shader_groups` (one per RomFS folder) | `game.tsv` | the provisional guess, kept: every shader is in `data01.impak` at the RomFS root, which no group names, so all 18 are in the `other` packages |
| `pad_layout` (default, `simple`) | | the 2D virtual pad; the left stick walks, B jumps, A confirms |

## Files

- RomFS: 412 files, 0.15 GB: `Audio/` (224 WAV sounds, 29 Ogg music files), `Atlases/`, `Characters/`, `Textures/`, `Cutscenes/` as `.bntx.z`, `Fonts/`, `Language/` (en-US, fr, de, es, it, ru), and `data01.impak` (a zip archive) at the root.
- The save holds `savegame_000.dat` at its root.

## Shaders

- **Current:** 18 distinct shaders (12 pixel, 6 vertex) from the `.bnsh` files in `data01.impak` (`Shaders/BasicEffect_*`), all translated for the Mac.
- **Open:** the prewarm list (`pso_manifest.tsv`) is empty. The first Mac boot compiled 3 pipeline bases (126 ms, off the submit thread) by the title; a list recorded through the title and the first area would spare the iPhone's first start those waits.

## Memory

- The process footprint stayed under 1 GB (703 MiB in the first area).

## On the Mac

- After the NSP script's `--platform mac` build, its printed command runs the game; with the window covered add `DM_PRESENT_LINK=0` so `DM_CTL` screenshots still come.
- The title comes about 15 s after start. With a fresh save: A (Start Game), A (slot 1), A (Normal), then A through the opening's lines (about six presses) gives control. Left stick right walks east, B jumps.
- Single frames of 25–260 ms come at scene changes (the title, the new game's load). In the first area a single frame of about 45 ms came every 10–25 s with no pipeline, shader library or texture upload in it ([Open](#open)).
- Every frame takes one write-protection fault for the game's writes beside a packaged texture, which the host protects again without a re-upload ([writes beside a texture](../../../docs/reference/nvn-objects.md#writes-beside-a-packaged-texture-in-a-shared-host-page)); no re-uploads came of it.

## Found on this game

- Resolved: the sound was choppy because the host looked for the `AudioRenderSystem` at SDK 16's offset in `AudioRendererImpl`; this `sdk` (the same build as [SteamWorld Dig](../01009320084A4000/README.md)'s) keeps it at `+0x50`. After the fix, a 40 s dump has no silent blocks once the music starts → [Where the `AudioRenderSystem` sits in `AudioRendererImpl`](../../../docs/reference/audio.md#where-the-audiorendersystem-sits-in-audiorendererimpl).

Otherwise it runs on mechanisms found on other games, including SDK 3.4.0's NVN and services.

## Open

- iPhone: the IPA is built but not tested.
- The empty prewarm list ([Shaders](#shaders)).
- The single 45 ms frames in the first area: cause unknown (not pipelines or uploads; the game's own work or a host wait was not told apart).
- Twice the host's audio watchdog logged `[RED] audio #0: the device has not called back for 2xx ms` (once at boot, once at a Mac output-device change) and restarted the AudioUnit; both times the game's frames took 50 ms until it restarted, which suggests the game waits on the audio renderer each frame (not confirmed). The same line is recorded on other games ([Baba Is You](../01002CD00A51C000/README.md), [Sea of Stars](../01008C0016544000/README.md)).
- Only the first minutes were played; digging, the mines, the town, the other languages are untested.
