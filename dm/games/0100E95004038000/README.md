# Xenoblade Chronicles 2

Base title ID `0100E95004038000`, update 2.1.0 (`v983040`), SDK 3.5.0,
Monolith's engine, NVN. Modules: `main`, `subsdk0` (NintendoSDK_movie), `sdk`.
The build IDs are in [game.tsv](game.tsv).

## Current status

Opening gameplay tested on an Apple-silicon Mac (2026-10-27). The game boots,
mounts all six supplied add-on content entries, renders its title and menus,
completes King Crustip and reaches Argentum in Chapter One. Field tutorials,
walking and the menu work. The general queue raster-origin fix restores the
lighting and geometry without a game-specific rule or rewriter cut.

All 15,572 shaders build for Mac and iOS. The unsigned IPA has been rebuilt
with this fix: 18,331,894,202 bytes (17.07 GiB), 78,482 ZIP entries, all ZIP
CRCs valid, with all shader libraries and six DLC mount entries. It has no
code signature or provisioning profile. iOS runtime testing, DLC gameplay
and later areas remain open.
System → Save and a restart into Argentum were exercised during bring-up;
the save was created with the isolated winding diagnostic and reloaded with
the production path. The final fixed host also loads it and walks in Argentum.

## Profile and memory

The NPDM declares no system resource. Startup sets a `0xC9400000`-byte heap
inside the profile's 4 GB guest reservation. The application pool remains
`0xCD500000`, with 256 MB each for alias memory and stacks. No game-specific
rewriter cuts are used. `pad_layout full` supplies both sticks and the D-pad.

## Files and shaders

The merged base/update RomFS contains 28,376 files (13.05 GB), including 154
WebM movies and `bf2.arh` / `bf2.ard`. The ARH1 index names 40,733 packed assets.
The existing Monolith archive reader decodes its XBC1-compressed HCPS programs.
The complete split, including the supplied DLC, finds 15,572 keys: 4,726 vertex, 10,830 pixel,
three geometry and 13 compute, with 12,028 variation pairs. Six stages come
from the standalone SLCT at `main+0x9ce0e0`; the other 15,566 come from assets.
Of those keys, 2,834 first appear in DLC assets, 12,732 in the base/update
assets and six in main. Full Mac and iOS compilation passes, including all
three geometry shaders. DLC gameplay remains unvalidated.

## Rendering

**Resolved, dark and inside-out geometry:** the game creates its queue before
switching the device from the default lower-left origin to upper-left
(`boot31properties`). Mario Wonder sets upper-left before queue creation
(`wonder33order`). The native SDK's `DeviceSetWindowOriginMode` at
`sdk+0x2bfac0` only stores the mode. Its queue initializer at `sdk+0x2c54ec`
calls `0x2dba3c` at `0x2c594c`, which calls `0x2db3b0` at `0x2dc2ec`.
That helper emits `SET_WINDOW_ORIGIN` at `0x2db670`–`0x2db6a0`: the lower-left
device state selects `0x801004eb`, upper-left selects `0x800004eb`. This helper
has no caller outside queue initialization. Later viewport construction at
`0x2d5ca0` reads the device's current mode. These SDK offsets refer to build
`867b345248124ef3d70e3202e221e978`.

The [general queue raster-origin fix](../../../docs/reference/rendering.md#queue-initialization-captures-the-raster-origin)
preserves this distinction without a game rule or SDK-version gate.
`boot34queue` loads Chapter One and walks in Argentum with correct geometry
and lighting. The earlier global winding experiment was rejected because it
broke Mario Wonder; the queue-state fix passes Wonder's full smoke route.

Before the fix, indirect-lighting pair `468bd9c28161136f` / `93d0e7a7c14cdfb0`
writes nothing. Its depth test is off, stencil comparison is
ALWAYS, culling is BACK and front-face winding is CW. Native post-vertex
capture gives `(-1,-1,0.5,1)`, `(3,-1,0.5,1)`, `(-1,3,0.5,1)`; the byte
indices are `00 01 02`. Those vertices also occur unchanged at
`main+0x9d3c30` in build `f77f1559371c0ec6d50e78774ac59d95`.
The material buffers and reflection cubes contain valid images. Highlighting
the five direct-lighting material shaders reaches their expected geometry;
highlighting the indirect-lighting draw does not. A native D16 depth-equality
fixture passes tags 1 through 8, ruling out that earlier hypothesis.

The engine initializes all seven reusable polygon states to CW at
`main+0x6ff6a4` in that build. The SDK's original polygon binder and
window-origin command encoding were compared with Mario Wonder's SDK 16
driver: both encode the same front-face and upper/lower-left origin rules.
The difference is initialization order, rather than SDK-version semantics.

**Resolved, title logo:** the game deliberately hides `IMG_Logo` when its save
buffer does not begin with `0x0300a15b` (`main+0x489140` through `0x489180` in
the build above). A fresh save buffer begins with zero. Forcing visibility in
an isolated diagnostic draws the 800×312 BC3 logo correctly; no such patch is
retained. More decisively, `boot28save` creates `bf2savefile.sav` through
System → Save after reaching Argentum, and `boot29reload` uses unmodified game
modules and the production rendering path: its frame 600 shows the logo and
Chapter One's blue-sky title, and frame 1800 is back in Argentum. The absent
fresh-save logo is not a texture-loading or language-selection defect.
One startup layout shader,
`da21866ffe3a9d7a`, reads a 3D texture through a declared 2D slot; its relation
to a visible defect is not established.

## Validation

- Python tool suite: 292 tests pass, 16 skipped. The complete Metal graphics
  suite passes. The queue-origin fixture passes 389 checks in each encoding
  mode, including actual culling, fragment facing and attachment coverage.
  All 178 iOS source compile checks pass.
- `boot34queue` validates saved-game loading and walking with the fix.
  After refreshing the standard NSP Mac build and all 15,572 Mac libraries,
  `boot38packagedmac` repeats loading into Argentum with that build's host.
  `boot37play` starts fresh with real audio, completes the opening battle,
  plays Chapter One's cutscene, skips it through the game's confirmation,
  advances the field tutorials and walks in Argentum (`field37.png`). It
  runs for fifteen minutes without a guest crash. A separate twenty-minute
  windowed/audio run (`boot36play`) remains in the battle tutorial.
  The fifteen-minute run reports fifteen audio underruns during concurrent
  validation/build work; its timing is not used as a performance measurement.
- Full local regression report:
  `0100E95004038000-work/regress-harness/reports/20261027-161811-check/report.md`.
  No shaders or interfaces change. Mario Wonder and Hades smoke routes pass.
  Xenoblade 2's screenshots show the corrected lighting, but this sweep's
  timing and frame-deadline checks fail while other validation builds run.
  The isolated repeat,
  `0100E95004038000-work/regress-harness/reports/20261027-174408-check/report.md`,
  passes both games' frame deadlines without new red lines: Xenoblade 2
  stays at 30.1 fps (frame p99 33.46 → 33.42 ms), Wonder at 59.7 fps
  (19.21 → 17.31 ms). Xenoblade 2 is labelled REGRESSION only for the
  intended screenshot change; Wonder's image passes unchanged. Balatro is outside
  the harness's GL chain support. Bayonetta 2/3 and OCTOPATH TRAVELER I/II
  lack package files required by the baseline shader build; Yoshi's Crafted
  World has no profile in the baseline revision. These are unchecked.

- **Current, [#424](https://github.com/seedds/nxnative/issues/424) controls
  (2026-10-27):** the unchanged `1963fab7` host reproduces the startup texture
  warning described above and peak footprints of 1,522 and 2,070 MB, versus
  the first baseline's 564 MB and the patched run's 1,274 MB. A byte-identical
  HEAD copy also misses both scheduled captures. These flags are not specific
  to the analyzer fixes. The 65-second startup route reaches different
  workloads between runs, so its timing difference is inconclusive. An
  alternating fresh-save idle-title benchmark, two runs per host with the same
  shaders, also has unstable timing: p99 134.51/712.67 ms on HEAD and
  117.44/180.31 ms patched. This does not establish a patch-induced slowdown
  or a stable performance baseline. Reports are in the NSP work folder's
  `issue424-controls/` and `issue424-idle-benchmark/results-valid/`; the earlier
  idle benchmark with an incorrect shader-cache path is marked invalid.

### Controller motion review

**Current (PR #351, 2026-10-27):** the full regression comparison of `6d1e07b`
with `f978e28` reaches the tutorial on both hosts, with unchanged shaders and
no new red lines, but flags windowed frame timing. The candidate repeatedly
logs one-second display-link stalls; the baseline also stalls and misses both
requested screenshots. Its windowed visual comparison is unavailable.

Two cached-archive A/B repeats in reverse order reproduce the large spikes on
both hosts, with nearly identical median frame rates. A second two-run pair
using direct presentation (`DM_PRESENT_LINK=0`) has matching 33.24 ms median
frame times and overlapping p99 ranges. These controls do not reproduce a
consistent slowdown from the gyro change. Windowed performance remains open
for a controlled foreground run; see [silent display links](../../../docs/reference/frame-rate.md#present-thread-rescues-a-silent-display-link).
`DM_WINDOW=0` still creates a window: the Mac front end checks whether the
variable exists.

The original flagged report is `nx-harness/reports/pr351-review/` on the game
drive. The cached-archive controls are in this game's
`0100E95004038000-work/regress/pr351-windowed-ab/` and
`0100E95004038000-work/regress/pr351-direct-ab/`; their public tables are in
[PR #351](https://github.com/seedds/nxnative/pull/351).


## Integration with main

Rebased onto `75065df` (2026-10-27), whose shader chain is `157e1b96c8da`.
The complete Metal suite, all 389 queue-origin checks in both encoding modes,
347 Python tool tests (16 skipped) and all 178 iOS source compile checks pass
on the integrated code. The Python app-bundle fixture needs access to macOS's
icon tools outside the sandbox.

All 15,572 Mac shaders rebuild with that chain. `boot40main` uses the refreshed
host, libraries and merged `RomFS.img`, loads the saved game into Argentum
and exercises walking; its frame 1500 shows the correctly lit field.

The final rebase includes `349abd0`, with the same shader chain. Repeated
checks pass: 389 queue-origin checks in each encoding mode, 73 pipeline
archive checks, 79 prewarm checks on each Metal path, 108 affected Python
tests and all 178 iOS compile checks. `boot41latestmain` loads Argentum and
walks with that host, with no crash or new red lines. The impact report is
in `0100E95004038000-work/regress-harness/main-integration-impact/`.

The delivered IPA above retains the gameplay-tested `9bdef355` base plus this
queue-origin fix, with shader chain `7fbca6dd477d`; it was not replaced during
this integration. The regression reports above also refer to that base.

## Mac development files

The supplied folder is `/Volumes/S790/nsp/Xenoblade Chronicles 2/`. Extraction,
rewritten modules and shader builds live in `0100E95004038000_build/`; binary
analysis, bounded runs, saves and logs live in `0100E95004038000-work/`.
`run/boot.py` accepts a log name, duration and environment assignments.
`boot01.log` records the initial startup and clearing frames; it stops because
that diagnostic launch did not yet have a shader map configured.

## Found on this game

- [Monolith ARH1, XBC1 and HCPS/SLCT shader containers](../../../docs/reference/shaders.md#monolith-arh1-xbc1-and-hcpsslct-shader-containers).
- [Queue initialization captures the raster origin](../../../docs/reference/rendering.md#queue-initialization-captures-the-raster-origin).
- [Present thread rescues a silent display link](../../../docs/reference/frame-rate.md#present-thread-rescues-a-silent-display-link): the motion review's windowed timing comparison is confounded by repeated stalls; see [Controller motion review](#controller-motion-review).
