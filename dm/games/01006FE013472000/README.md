# Mario Party Superstars (`01006FE013472000`)

Update 1.1.1 (`v131072`), SDK 11.4.3. NintendoWare Bezel Engine 1.55 on NVN, by NDcube; the `sdk`, `subsdk0` (GLSLC, imported and never called) and `subsdk1` (NintendoSDK_movie) modules are the same builds as [Big Brain Academy: Brain vs. Brain](../0100620012D6E000/README.md)'s, as is `nninitStartup`'s choice of memory setup. The boards and minigames are 126 NROs (`nro/NX_Release/*.nro`, one NRR) that the game loads with `ro::LoadModule`. No `patches.py`: the standard rewriter covers `main`, `sdk` and every NRO, and no game code is cut.

On the Mac (Apple M6, headless, docked): from a fresh save the play-style menu (Offline Play), the player count, the opening scene (skippable with −/+), the title, the plaza with its NPCs, Mario Party with Koopa Troopa's rules, CPU opponents and settings, Yoshi's Tropical Island: the intro, the turn-order roll, turn 1 (dice, a blue space, the CPUs' moves, the Thwomp), a minigame after it (Speed Hockey in one run, Tube It or Lose It in another: rules, practice, the match, results), turn 2 with the game's save and turn 3 (Toadette's Star, a Boo). 60 fps throughout (frame time p50 16.66 ms, p95 about 17.3 ms on the board), with sound, no crash and no `[RED]` line beyond the one below. A short gameplay test, at the user's request: one board, two minigames. Not tested: the other boards and modes, more minigames, local and online play, the iPhone (no IPA built).

## What it needs

| Setting | Where | Why |
|---|---|---|
| `sys_resource 0`, 4 GB layout (`mem_reserve 0x100000000`, `mem_alias 0x10000000`, `mem_stack 0x10000000`), `app_pool 0xCD500000` | [`game.tsv`](game.tsv) | the NPDM declares no system resource, so `nninitStartup` sets a heap of pool − used memory (3.14 GB), as Big Brain Academy's; the provisional profile's guess, unchanged |
| `depth_mode zero` | `game.tsv` | the game sets near = 0, so the prebuilt pipeline bases take the `main0_z` vertex entries |
| `modules main subsdk0 subsdk1 sdk` | `game.tsv` | `subsdk0` is GLSLC, `subsdk1` NintendoSDK_movie |
| `shader_groups /Archive/=archive` | `game.tsv` | the archive shaders; the engine's own in `System.nx.bea` go to `other` |

Everything else needed was general: see [Found on this game](#found-on-this-game).

## Rendering

- 82,790 shaders (30,514 vertex, 52,241 pixel, 23 compute, 12 geometry, among them 1,936 of the engine's in `System.nx.bea` and 71 in `main`), all in Bezel Engine archives' `.bnbshpk` / `.bnsh` entries; 140,036 shader pairs. All build for the Mac. Window origin upper left, depth mode near = 0, swapchain 1920×1080 RGBA8 sRGB, present interval 1.
- **Resolved: characters and NPCs drawn as flat grey silhouettes** (Mario, Luigi, Peach and Daisy in a party, the Koopa host, the Toads, Shy Guys and Kamek in the plaza, the pipe in the opening scene). Their pixel shaders read each light's shadow-map and cube-map handles from the game's storage buffer at a computed offset, which Ryujinx turns into arrays indexed by texture ID; 6,370 shaders (every `_chara/pc` and `_chara/npc` material, some `hsmn_bg` variants) did not load ([Texture handles from game memory index the pools](../../../docs/reference/shaders.md#texture-handles-from-game-memory-index-the-pools)). The texture pool has 2,304 IDs (about 1,300 2D textures and 60 cubes registered on the board), the sampler pool 512.
- **Resolved: the host stopped on the way into a party** (`FATAL shader 56071a5cf62dccc3_b has an unexpected argument buffer layout: encodedLength=88 maxAid=8`): the engine's clustered point lights (`light_primitive_point_cluster.bnsh`) write a storage buffer and images inside a fragment interlock ([Argument buffer members with attributes after their id](../../../docs/reference/shaders.md#argument-buffer-members-with-attributes-after-their-id)).
- `[RED] sampler ID 4095 not registered`, once at boot: nothing visible depends on it.
- The pipeline prebuild of all 140,036 pairs (the NSP script's last step) ran for 50 minutes on the Mac without finishing; the game builds its pipelines as it draws instead (open: whether an archive of that size is worth making).

## Memory

- The heap path: a 3.14 GB heap in the 4 GB layout, as Big Brain Academy.
- Resident on the Mac: 0.9 GB at boot, 2.2 GB at the title with the pipeline prewarm, 2.7 GB on the board in turn 3 (frame 27,900; 2.4 GB of it Metal allocations).
- The texture pool's buffers are rebuilt about once every 28 frames on the board (1,000 rebuilds by frame 28,000, 585 ms in all), as the game registers textures.

## Files

- RomFS: 814 files, 2.69 GB: 477 Bezel Engine archives (`Archive/*.bea`, 2.31 GB, zstd entries), 209 `.bfstm` streams, 126 NROs with their NRR. No movies.
- Languages: en-US, en-GB, ja, fr, de, es-419, es, it, nl, fr-CA, ru, ko, zh-Hant, zh-Hans, pt-BR.

## Mac routes

- Work folder `<NSP folder>/01006FE013472000-work`: `run/boot.sh <log> [secs] VAR=…` runs `build/mpshost` (a renamed copy of `dm/host/dmhost`) on the NSP script's build; `run/ctl.sh`, `step.sh`, `see.sh` press and take shots.
- `run/route.sh <log> [secs]` with `TO=plaza | party | board | minigame`: from the play-style menu (A, A, A: Offline Play, one player, OK), −/+ through the opening scene, L+R at the title into the plaza, the stick left and up to the pipe and A into Mario Party, A through the host's talk and the settings onto Yoshi's Tropical Island, and A through turn 1 to the first minigame's rules (the minigame is random). A press in the plaza within about 4 s of its fade-in is lost.
- `run/save_board`: a save made by the game at the start of turn 2 on Yoshi's Tropical Island.

## Found on this game

General changes first needed here; each applies to every game:

- **Texture and sampler pools for handles traced to no slot** (`Program.cs`, vendored `BindlessElimination.cs`, `dmsh_build.py` `pool_arrays`, `nvn_mtl.m` `pool_gpu`): [Texture handles from game memory index the pools](../../../docs/reference/shaders.md#texture-handles-from-game-memory-index-the-pools).
- **Argument buffer members with attributes after their id** (`dmsh_build.py` `reflect`): [Argument buffer members with attributes after their id](../../../docs/reference/shaders.md#argument-buffer-members-with-attributes-after-their-id).

## Open

- Only one board (Yoshi's Tropical Island) and two minigames (Speed Hockey, Tube It or Lose It) were played; the other boards, the other modes and most minigame NROs were not loaded.
- Only the 1.1.1 build (`v131072`) is registered.
- iPhone: not built, not installed, not tested.
