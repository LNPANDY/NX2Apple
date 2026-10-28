# Persona 4 Golden (`010062B01525C000`)

Update 1.0.2 (`v131072`), SDK 14.3.0. Atlus's own engine with CRI middleware
(CRIWARE), on NVN. Modules `main`, `subsdk0` (NintendoSDK_movie) and `sdk`. No
game-specific rewriter cuts or host rules: `main` has 5 rewrite sites and the
standard rewriter covers them.

On the Mac: the opening movie with sound, the title screen and its menu, a new
game through the first in-game notices, and the Velvet Room dialogue scene, at
60 fps (frame time p50 16.66 ms), drawing 243 render passes a frame in the
busiest scene. No `[RED]` line during a run of 9,900 frames. Not tested on the
iPhone: no IPA was built, and the touch layout is untested.

## What it needs

| Setting | Where | Why |
|---|---|---|
| `sys_resource 0x0` | [`game.tsv`](game.tsv) | the NPDM declares 0 MB of system resource: `IsVirtualAddressMemoryEnabled` is false, so `main` maps its own heap and no heap check runs |
| 3.5 GB layout: `mem_reserve 0xe0000000`, `mem_alias 0x10000000`, `mem_stack 0x10000000`, `app_pool 0xCD500000` | `game.tsv` | the provisional layout, which holds through boot and the first scene: `main` carries about 471 MB of bss, counted by the big-module rule |
| `modules main subsdk0 sdk` | `game.tsv` | `main` imports from all three; `subsdk0` is NintendoSDK_movie |
| `shader_groups /sysdat.cpk/=sysdat` | `game.tsv` | every shader is a BNSH entry under `sysdat.cpk` |
| `romfs_marker data.cpk` | `game.tsv` | the RomFS is a root of CPKs |
| `pad_layout full` | `game.tsv` | the game uses the full controller; the touch layout is untested |

## Files

- RomFS: 12 files, 9.04 GB — eleven `.cpk` at the root (`data.cpk` 7.2 GB,
  `data_movie.cpk` 1.4 GB, one per language, and the small `sysdat.cpk` that
  holds the shaders) plus `data_cri/sound/adx2/common.acf`. The packer extracts
  it as a `DMROMFS1` image (`RomFS.img`, 9.7 GB), which the host mounts
  directly.
- `main` is 5.2 MB of text with 471 MB of bss; `subsdk0` supplies the movie
  player and `sdk` the system services.
- The CPKs are decoded by `cpk.py` (CRILAYLA), so the shader split reads them
  like a folder tree.

## Shaders

- 26 shaders in total, 8 vertex and 18 pixel, all BNSH entries under
  `sysdat.cpk/shaders` (`P4G/`, `system/`, `system/posteffect/hdr/`). All
  translate and compile for Mac.
- No shader pairs and no compute shaders, so `shader_pairs.tsv`,
  `pso_pairs.tsv` and `shader_facts.tsv` hold only their headers.
- `pso_manifest.tsv` covers boot, the opening movie, the title screen and a new
  game into the first Velvet Room scene.

## Memory

- Resident memory was 1370 MB with 1672 MB of Metal allocations at the end of a
  long run, after the game had loaded its opening scenes.

## Open

- The memory keys are the provisional ones; they hold through the tested route
  and were not measured further.
- Only the 1.0.2 build (`v131072`) is registered. The base 1.0.0 build and
  the 1.0.1 update are not.
- iPhone: not built, not installed, not tested.
