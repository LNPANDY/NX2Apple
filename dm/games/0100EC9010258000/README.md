# Streets of Rage 4 (`0100EC9010258000`)

Update 1.0.9 (v458752), SDK 9.3.1, on NVN (127 shaders, MonoGame effects). Modules `main`, `subsdk0` (NintendoSDK_movie) and `sdk`. MonoGame for the Switch: MonoGame's and the game's C# compiled to C++ by Sickhead's BRUTE (its sources under `F:/SoR4/_Code/MonoGame/Switch/Brute/`), with a Boehm-style collector that stops threads at safepoints; Wwise sound through AudioOut; H.264 movies through the SDK's decoder into NVN textures. The profile is the NSP script's provisional one with only the shader group corrected ([What it needs](#what-it-needs)). It needed two host changes, both general: the SVC gate no longer writes below the guest's stack pointer, and `nvnCommandBufferDrawTexture` is implemented ([Found on this game](#found-on-this-game)). Only this update is registered in the profile.

On the Mac (2026-10-29, a short gameplay check): the publisher logos and the intro movie, the title and its menus, Story mode's save slot, difficulty and character select, the opening text crawl (X skips it), then stage 1 as Axel: walking, combos and enemies knocked down, all at 60 fps (frame time p50 16.62 / p95 16.89 ms over the stage) with no `[RED]` line. A second boot showed slot 1 at "Stage 1 – Normal", so the save and its reload work. The sound output (`audio #1`, the game's own AudioOut) ran without underruns but was not listened to. The unsigned IPA has not been built from this profile or tested on an iPhone.

## What it needs

| Setting | Where | Why |
|---|---|---|
| 3.25 GB layout: `mem_reserve 0x100000000`, `mem_alias 0x10000000`, `mem_stack 0x10000000`, `app_pool 0xCD500000` | [`game.tsv`](game.tsv) | the provisional layout, which holds: `main` sets a heap of at most the pool − 64 MB − its 27 MB of bss |
| `sys_resource 0x0` | `game.tsv` | the NPDM declares 0 MB of system resource: `IsVirtualAddressMemoryEnabled` is false, as on Horizon |
| `mem_used 0x76d8000` | `game.tsv` | the rewritten modules are over the default 64 MB (`main` has 52 MB of code and 27 MB of bss); written by the NSP script after the rewrite |
| `shader_groups /shader/=shader` | `game.tsv` | the game's effects are the XNB files in `shader/`; the provisional guess also named the sound bank, video and gui folders, which hold none. Same shader keys either way |

## Files

- RomFS: 555 files, 3.68 GB. `GeneratedSoundBanks/Switch` (0.95 GB, Wwise banks and 479 `.wem` streams), `videos/` (0.62 GB, 17 MP4 movies with subtitles), 19 files at the root (2.11 GB, among them `textures`, the RomFS marker), `shader/` (14 XNB effects) and `gui/` fonts.
- The save holds `config_sor4` and `save_sor4`; the first boot logs `File does not exist: save:/config_sor4.`, as on a fresh console.

## Shaders

- **Current:** 127 shaders (49 vertex, 78 pixel), all translated for the Mac: 64 from the MonoGame effects in `main` (SpriteBatch's and the engine's) and 63 from the 14 XNB effects in `shader/` (`post`, `glow`, `palettize`, `eliteshield`, …). Read as MGFX effects: [MGFX effects in MonoGame XNB files](../../../docs/reference/shaders.md#mgfx-effects-in-monogame-xnb-files).
- The prewarm list (`pso_manifest.tsv`) is empty: the NSP script's prebuild makes the bases of the 98 shader pairs (`shader_pairs.tsv`) before the first frame.

## Rendering

- Each frame clears a 1920×1080 scene target and draws into it; during a movie, the frame comes in with `nvnCommandBufferDrawTexture` from one of two textures the decoder writes in turn (IDs 256 and 257 of a second texture pool). One draw of the scene target onto the window texture presents it.

## Memory

- Resident memory grew from 1.85 GB at the title to 2.63 GB in stage 1 (GPU allocated 0.89 → 1.65 GB) and levelled off there.

## On the Mac

- After the NSP script's `--platform mac` build, its printed command runs the game. `DM_PRESENT_LINK=0` keeps it presenting with the window behind others, as `DM_CTL` screenshots need.
- With a fresh save: Plus at about 15 s skips the intro movie, A (Story), A (slot 1), A (New game), A (Normal), A (Axel), A (start); X skips the text crawl, and stage 1 starts about 10 s later. Y attacks, A jumps, Plus pauses.

## Found on this game

- **SVCs leave the stack below sp untouched** (BRUTE's collector freed an array a sleeping thread still held, in two boots of three): [threads](../../../docs/reference/threads.md#svcs-leave-the-stack-below-sp-untouched).
- **`nvnCommandBufferDrawTexture`** (black screen; then the movie frame from the wrong texture pool): [rendering](../../../docs/reference/rendering.md#nvncommandbufferdrawtexture).

## Open

- iPhone: an IPA from this profile is not built or tested. Resident memory reaches 2.6 GB on the Mac in stage 1.
- Only stage 1's start was played; later stages, the other modes (Arcade, Boss Rush, Battle), two players and the other languages are untested. The sound was not listened to.
- `DrawTexture` with blending on is drawn without it (a red line); this game's draw has blending off.
