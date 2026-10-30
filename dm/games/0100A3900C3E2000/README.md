# Paper Mario: The Origami King (`0100A3900C3E2000`)

Update 1.0.1 (v65536), SDK 8.3.1. Intelligent Systems' engine on NintendoWare (G3d, Vfx, Atk) on NVN, as [Paper Mario: The Thousand-Year Door](../0100ECD018EBE000/README.md) later. Modules `main`, `subsdk0` (the SDK's movie library) and `sdk`. No game code is cut and no host rule is added. On the Mac (Apple M6): the title, a new game, the opening drive into Toad Town and up to Peach's castle, with Mario under control and walking there, at 30 fps (as on the Switch) with sound and no red line beyond the known unbound-slot one. A short check only; the battles (the ring puzzle), the first world, saves and the iPhone are not tested.

## What it needs

| Setting | Where | Why |
|---|---|---|
| Node area 1 GB → 62 MB, regions of 4 MB and more aligned to 2 MB (SDK 20's) | `dm/tools/sdk_patches.py` SDK-wide rules, `sdk` build `86a2afd8…` (`sdk+0xc96f0` / `+0xc9790`, `+0xc98f4` / `+0xc98fc` / `+0xc9900`) | the SDK-wide rules' cuts (implementation 1 of each), which the provisional profile was booted with (before 2026-10-29 also a row of this build, as the rules skipped builds a profile names). [Blasphemous](../0100698009C6E000/README.md) 1.0.8 ships the same `sdk`; with no virtual address memory it never reaches them. See [Memory](#memory) |
| 5 GB block: `mem_reserve 0x140000000`, `mem_alias 0x118000000`, `mem_stack 0x10000000`, `app_pool 0xCD500000` | [`game.tsv`](game.tsv) | Engage's block, as the provisional profile guessed: 256 MB in front + 4.375 GB alias region + 256 MB stack region + 128 MB heap region (never used) |
| `sys_resource 0x800000` | `game.tsv` | the NPDM declares 8 MB of system resource |

Everything else is the provisional profile's guess, unchanged.

## Memory

- 8 MB of system resource (virtual address memory) and no heap: `main` never calls `SetMemoryHeapSize`.
- `nninitStartup` makes the game's malloc a StandardAllocator over 62 GB of address space (the region returns to `main+0x5c05ac`); the host's cap gives it 4.06 GB ([StandardAllocators over 12 to 62 GB of address space](../../../docs/reference/memory.md#standardallocators-over-12-to-62-gb-of-address-space)). It fits the 4.375 GB alias region after the 62 MB node area and with 32 MB alignment (this `sdk` build aligns regions of 1 GB and more to 1 GB). 1.39 GB mapped at boot. Resident on the Mac: 1.3 GB at frame 300, 2.9 GB by frame 1,800 (still the title), then flat at 3.0–3.2 GB through the opening and the castle (frame 8,400).

## Rendering

9,438 shaders (4,633 vertex, 4,328 pixel, 477 compute), all BNSH: 3,763 in `shaders/*.bfsha.zst` and 5,675 in the particle effects (`effect/*.ptcl.zst`). Every one translated and built on the first split.

- **Resolved: magenta 16×16 blocks** (exactly (255, 0, 255), on the 16-pixel grid, a 16×16 or 16×8 block in some frames: on the castle path, beside the HUD) on the Mac. The anti-aliasing pass (`shaders/aa.bfsha` variation 1, pixel shader `8dc20835c07cd7ff`) samples the 1920×1080 RGB10A2 scene target (format 90) it renders into, once a frame ([Same-pass feedback read through a snapshot](../../../docs/reference/rendering.md#same-pass-feedback-read-through-a-snapshot)). With `DM_NVN_FB_SNAP=all` the only snapshotted shader was this one; with it in a `feedback_snap` key the same route's screenshots (frames 3,600–5,400) went from 258–261 magenta pixels to 0–6 (single pixels of the festival confetti). The host now finds the draw itself (it writes the attachment it samples) and the key is gone: on 2026-10-30 the route's 19 screenshots (every 100 frames from 3,600) held up to 273 magenta pixels in blocks with `DM_NVN_FB_SNAP=0` and 0–8 single pixels without a list, and this shader was the only one snapshotted. Variation 0 (`62cf4a72bc36a17b`) was not drawn on this route.
- `stage 0 cb5 has no uniform buffer bound` at the title, as on The Thousand-Year Door ([An unbound uniform slot reads the zero bank](../../../docs/reference/rendering.md#an-unbound-uniform-slot-reads-the-zero-bank)).

## Frame rate

- 30 fps, as on the Switch: the frame time is 33.3 ms at p50 on the Mac with a GPU time of 5–7 ms. No frame step: a 60 fps upgrade would need the engine's clock found, as The Thousand-Year Door's (open).

## Mac routes

- A fresh save reaches Peach's castle with Mario under control with `DM_KEYS="25:A~0.3,32:A*80/2.5"` (the title, which starts a new game on an empty save; A every 2.5 s through the opening; control at about 210 s, frame 6,300). With 60 presses the route stops on Luigi's "park the kart" line before the castle. Presses of 0.15 s at the title were sometimes missed; 0.3 s holds took.

## Found on this game

Nothing new: every mechanism it needed was there. It is listed under [Same-pass feedback read through a snapshot](../../../docs/reference/rendering.md#same-pass-feedback-read-through-a-snapshot).

## Open

- Not tested: battles, the first world past the castle, saves and loading, the movies, the iPhone (no IPA built).
- 60 fps.
