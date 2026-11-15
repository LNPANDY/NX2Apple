# Roadmap: what to do next, and why

Three investigations ran in parallel (runtime profiles for a universal launcher, a survey of
811 forks, and the Windows front end). This is the joint conclusion, ordered by value per
week of work. Sources are named so each claim can be re-checked.

## 1. Touch look and native aspect — the one capability we do not have

**From [devinhurry/touch-the-wild](https://github.com/devinhurry/touch-the-wild)** (not in
upstream's tree: `hle_look.c`, `touchpad_geometry.h` (once carried here as an experiment, since dropped), `hle_botw_touchhud.c`, `hle_aspect.c`
all verified absent from seedds/nxnative).

Today the only way to turn the camera on a phone is holding a virtual right stick, which turns
at a fixed rate. touch-the-wild injects into the game's **own shared right-stick vector**, so
the camera, aiming and the weapon wheel all see the same input instead of one using a fake
stick and the other an injected value.

Four details worth copying verbatim, because each is a bug that took them time:
- **float exact equality** to recognise the frame it wrote, not an epsilon window,
- **thread-local** copies of the original value, because the camera and action threads both
  call the getter and would otherwise cross-pair,
- normalisation by the frame's VFR ratio, and zero output when the drag stops, and
- `touchpad_geometry.h`: one C header describing the whole virtual pad, used by both the UIKit
  view and a **Mac mouse preview**, so the layout is tuned on a desk instead of on a phone.

Also included: **native aspect ratio** (`hle_aspect.c`) — the game renders at the screen's
aspect, the UI layer is corrected back to a centred 16:9 box, so the HUD keeps its shape and
the 3D view fills the screen.

| Piece | Effort | Note |
|---|---|---|
| `touchpad_geometry.h` + Mac `--touch-preview` | 3–5 days | Visible immediately, zero device time |
| Relative look (`hle_look.c`) | 1–2 weeks | Needs tests, and the four details above are the spec |
| Native aspect (`hle_aspect.c`) | 3–5 days per game | Needs per-game projection offsets |
| BOTW touch HUD (`hle_botw_touchhud.c`) | 3–5 days | Per-game only |

We already have an injection point: `dm_pad_hook` in `dm/host/dm_input.h` (after
`GetNpadState` fills, before the pseudo buttons are overlaid).

## 2. Cheats — free once upstream merges

[wingbywings/nxnative](https://github.com/wingbywings/nxnative) ported Atmosphère's dmnt cheat
VM (all opcodes 0x0–0xFFF, `[name]`/`{master}` syntax, 0x80 codes / 0x100 words / 0x400 program
caps, 256 static registers) plus build-time baking and an in-game menu. **Upstream PR #268 is
open.** When it lands, the daily sync carries it and we expose one switch in `settings.tsv`.

If the PR stalls, gnosticgeek/nxnative has a Markdown-format variant with a Mac sidebar
(~1 week).

## 3. BC texture decode — halves the device requirement

Our README says "iOS 26+ and a recent iPhone" because BC formats need a modern GPU. Two forks
proved the way out:
- `carl1347/nxnative`, `hieutran0413/nxnative`: restore `nvn_bcdec.c` (public domain `bcdec`),
  `-mcpu=apple-a14`. **3–5 days**, low risk.
- `pyaesonephyogameacc2003-arch`: BC1/2/3 → ASTC 4x4 (8 bits per texel, 4x smaller), one core
  text shared by the CPU path and a Metal kernel so both agree. 1–2 weeks, bigger win.

Enabling this brings iPhone 14/15 and A16 iPads into range.

## 4. Settings capability gating (AnySwitch's idea, not its code)

[chayan-bit/AnySwitch](https://github.com/chayan-bit/AnySwitch) has a declarative settings
registry (`DmSettings.m`, 505 lines): each row carries `key` (= a `DM_*` variable), type,
range, default, `apply` (restart or live), **`requires`** (a capability) and
**`defaultAtFps`**.

The two ideas worth taking without the code:
- **`requires`** — do not show "internal resolution" on a Vulkan game that has no NVN path.
  A hidden row is better than a dead switch.
- **`defaultAtFps`** — 30 fps games default to sharp upscaling, 60 fps to bilinear (saves
  ~4 ms/frame). One data row, read once per second.

We already read one table from three places (`dm/games/settings.tsv` → `Launcher.swift` →
`frontend-qt`), and adding two columns keeps that structure.

Also from that fork: `nvn_ambient.h` (227 lines, present stage only) — ambient letterbox that
samples the frame's edges so a 16:9 game on a 4:3 iPad has a coloured surround instead of black.

## 5. Windows build — the shim layer, not the WebUI

Our `frontend-qt` detects tools on Windows but cannot build: `build_ipa_from_nsp.py` calls
`xcrun` / `xcodebuild` / `xcodegen` unconditionally.

Two forks solved it. **Copy the small one:**

| | zenvyzenshiro/NXNativeWindows | xbunax/nxnative |
|---|---|---|
| Size | ~24 files (`win/` shim) | full FastAPI WebUI (720 KB, 98 files) |
| Approach | `xcrun.py` maps every `xcrun metal/metallib/clang`, `sips`, `plutil` to a Windows equivalent, `Launcher.m` replaces the SwiftUI launcher, and `sdk/extract_xip.py` unpacks `iPhoneOS.sdk` | same idea plus its own staging/overlay/patch build system |
| Verified on | Windows 11, LLVM 23.1.4, Metal Tools 6.2, iPhoneOS 27.1 — **Balatro built, sideloaded, ran on an A16 iPad** | Hades II IPA produced, not verified on a device |
| Fit for us | High — we already have two front ends | Low — it would be a third |

Toolchain (pinned in both forks): LLVM-MinGW `20261020`, iPhoneOS SDK from
`xybp888/iOS-SDKs` (SHA-256 per release), Apple's **Metal Developer Tools for Windows**
(manual download, needs an Apple ID) providing `metal.exe` + `metallib.exe`.

Effort: ~1 week for "Windows can produce an IPA".

## 6. Universal launcher — proven feasible, bounded by Apple's rules

The investigation overturned an assumption of mine: **all 36 `game_profile.h` macros can be
runtime.** A host built with runtime profiles produced four different guest layouts from one
binary (TotK / ACNH / Mario Galaxy / 13 Sentinels), all correct, with the full test suite green
and a clean iOS cross-compile.

What actually bounds a universal launcher is different:

1. **iOS cannot load executable code from disk.** Patched modules must be compiled into the
   signed binary, so every supported game's code is aggregated **at build time** — the launcher
   cannot stream game payloads.
2. **255 Mach-O section limit, and silent merging below it.** Two games' same-named modules
   merge into one section with no error (measured: the second game's code silently
   disappeared). The NRO scheme (3 shared sections + a table keyed `(game, module)`) fixes it
   and was validated packing 2 games × 2 modules.
3. **Size.** ~104 MB of modules per game, and shader libraries are larger (BotW's shadow libs
   alone 344 MB). A bundle realistically holds **4–8 games**.

| Architecture | Games per IPA | Effort |
|---|---|---|
| A. One IPA per game + `Documents/games/<id>/{romfs,msl,save,log}` | 1 | **1 week** |
| B. Fat launcher with several games' modules embedded | 4–8 | 3–4 weeks |
| C. Shell app + per-game signed framework via `dlopen` | unbounded | large, unvalidated |

**A already delivers what external storage needs** (romfs from an external folder, per-game
saves and logs) and enables the runtime-profile work that was already done. Do A first, B only
if 4–8 games in one app is worth it, and C needs a `dlopen` experiment before any commitment.

External storage on iOS: `UIDocumentPickerViewController` for the folder, persist a security-
scoped bookmark in UserDefaults, store the picked location there (done: `romfs.img` is read from any
security-scoped path, `dm_picked_data_path`; the shard-archive reader this note first assumed is gone).

## Safety note from the fork survey

Four of the 811 forks commit `prod.keys`, `atmosphere.zip` or DLC into their repositories
(Ghoshish/nxnative, JUAN-DEVRPA/nxnative, and two others). Any "sync by copying files" scheme
must work from an **allow-list**, never a deny-list. Our `sync_upstream.py` already does
(`VENDORED` = `dm scripts docs AGENTS.md ref`, plus an `OURS` set and a marker check per
carrier).
