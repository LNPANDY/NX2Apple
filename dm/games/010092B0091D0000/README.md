# Team Sonic Racing (`010092B0091D0000`)

Update 1.0.3 (v131072), SDK 5.6.0, on NVN (API 53.313; 4,516 shaders in Sumo's own containers). Modules `main`, `subsdk0` (the SDK's movie decoder) and `sdk`. Sumo Digital's own engine, with Wwise for sound (straight to `AudioOut`, six channels) and NEX / Pia for online play. The standard host and rewriter run this build with no game-specific fix: no shader overrides, rewriter cuts or host changes. The profile is the NSP script's provisional one, unchanged apart from its comments and app category ([What it needs](#what-it-needs)). Its shaders became readable with the Sumo container reader ([Found on this game](#found-on-this-game)). Only this update is registered in the profile.

On the Mac (2026-10-29): the Sumo Digital and Wwise logos with their movies, the autosave notice, the title, the main menu, then Local Play → Team Grand Prix (Normal, Grand Prix 1) → Sonic → Wisp Circuit: the race briefing, the team screen, the countdown, then about a lap of driving (accelerating, steering, coins, the slingshot behind a teammate) with the full HUD and minimap; in another run, the opening of Team Adventure (its dialogue over the 3D scene). No `[RED]` line, no crash. Menus and the garage run at 60 fps; the game sets present interval 2 when the race starts, so races run at 30 fps, as on the Switch (frame time p50 33.33 ms, GPU p50 3–7 ms at 1080p on an Apple M6). The game wrote its save at its first start, and a second boot read it (the autosave notice was not shown again). The unsigned IPA is built but not tested on an iPhone.

## What it needs

| Setting | Where | Why |
|---|---|---|
| 3.25 GB layout: `mem_reserve 0x100000000`, `mem_alias 0x10000000`, `mem_stack 0x10000000`, `app_pool 0xCD500000` | [`game.tsv`](game.tsv) | the provisional layout, which holds: `main` sets a heap of at most the pool − 64 MB (3.14 GB) |
| `sys_resource 0x0` | `game.tsv` | the NPDM declares 0 MB of system resource: `IsVirtualAddressMemoryEnabled` is false, as on Horizon |
| `modules main subsdk0 sdk` | `game.tsv` | `main` imports from the movie module (`subsdk0`) and `sdk` |
| `shader_groups /data/=data` | `game.tsv` | the provisional guess, kept: every file is under `data/` |
| `pad_layout` (default) | | the full pad: ZR accelerates, the left stick steers, A confirms, B goes back |

## Files

- RomFS: 1,161 files, 6.55 GB: `data/levels` (3.11 GB), `data/sound` (eight Wwise `.pck` banks, 1.78 GB), `data/ui` (615 `.stz`, 1.14 GB), `data/localcharacters`, `data/characters`, `data/gamedata`, `data/gamemodes`, `data/movie` (two `.mp4`), `data/shaders` (two `.nvnbin`), `data/vfx`. Models, levels and effects are `.sp4` resources.
- Movies: the logo movies are H.264 (baseline and high profile) with AAC sound, through the SDK's movie module (VideoToolbox on the host).
- The save is one file, `tsr_save.bin` (2.9 MB).

## Shaders

- **Current:** 4,516 distinct shaders (2,116 vertex, 2,399 pixel, one compute): 28,258 `Ninty_NX` descriptors in 337 `.sp4` resources (zlib-packed `MuxFDMR` streams), 586 in `main` and four stages in the two `.nvnbin` files. All 4,516 translate and compile for the Mac.
- **Open:** the prewarm list (`pso_manifest.tsv`) is empty. The pipeline prebuild of the 4,232 shader pairs covers most pipelines; on a first run, single 50–70 ms frames came from pipelines built on first use in the race (two bases and four shader libraries each).

## Memory

- Resident about 2.4 GB in the race, GPU allocated about 2.7 GB; steady over a few minutes of menus and racing.

## On the Mac

- After the NSP script's `--platform mac` build, its printed command runs the game; with the window covered add `DM_PRESENT_LINK=0` so `DM_CTL` screenshots still come.
- The autosave notice (first start) or the title is up about 25 s after start. From the autosave notice: A, A (Press Start), then in the main menu Right and A (Local Play), A (Grand Prix), A (Team Grand Prix, Normal), A (Grand Prix 1), A, A (Sonic, Ready), about 18 s of loading, then A, A through the briefing and the team screen. Hold ZR to drive.
- Single frames of 55–65 ms came right after `DM_CTL` screenshots (the PNG write).

## Found on this game

- Resolved: the shader split found no shaders: Sumo keeps them in container-relative `Ninty_NX` descriptors, loose `NVNsh` records and zlib-compressed `MuxFDMR` resources → [Sumo Ninty_NX shaders and MuxFDMR streams](../../../docs/reference/shaders.md#sumo-ninty_nx-shaders-and-muxfdmr-streams) ([seedds/nxnative#549](https://github.com/seedds/nxnative/pull/549)).
- Resolved: an iPhone build after a `--platform mac` build removed the Mac shader libraries the Mac run command loads → [An iOS build after a Mac-only build kept no Mac libraries](../../../docs/reference/shaders.md#an-ios-build-after-a-mac-only-build-kept-no-mac-libraries).

Otherwise it runs on mechanisms found on other games, including SDK 5's NVN and services and the six-channel `AudioOut` downmix: with sound on, 0 underruns, and no silent 5 ms block in 34 s of menu music (`DM_AUDIO_DUMP`).

## Open

- iPhone: the IPA is built but not tested.
- The empty prewarm list ([Shaders](#shaders)).
- Only the first lap of one race and the opening of Team Adventure were played: whole races and their results, a full Grand Prix, the rest of Team Adventure, other tracks, the garage, local split-screen, and other languages are untested. Online play is not supported.
