# NS Port Builder — Qt front end (Windows and macOS)

The SwiftUI app in `../frontend/` is the macOS-native one. This is the **cross-platform**
counterpart: same job, same strings, built with PySide6 so Windows users get a native window.

## Why a second front end

The build pipeline (`scripts/build_ipa_from_nsp.py`) is Python and runs on both systems, but
the SwiftUI app cannot: it needs macOS. Rather than maintain two unrelated GUIs, this one is
written once and runs everywhere Python and Qt do.

| | SwiftUI (`frontend/`) | Qt (this) |
|---|---|---|
| Platforms | macOS 13+ | Windows 10+, macOS 11+ |
| Language | Swift | Python 3.9+ |
| Strings | `Localization.swift` | generated from that same file |
| Build logic | runs the Python scripts | runs the same scripts |

The strings are **generated** from the SwiftUI table (`gen_localization.py`), so the two front
ends cannot drift apart: edit `Localization.swift`, run the generator.

## Run it

```bash
python3 -m venv .venv
.venv/bin/pip install PySide6            # Windows: .venv\Scripts\pip install PySide6
.venv/bin/python -m nspb_qt              # Windows: .venv\Scripts\python -m nspb_qt
```

From this folder. It looks for the repository checkout next to itself, in `~/NX2Apple`, or
wherever `NSPB_REPO` points, and the repository group lets you pick it by hand.

## What works today

- Dependency detection per platform: Python + packages, .NET SDK, and either **Xcode + iOS SDK +
  Metal toolchain** (macOS) or the **Windows cross toolchain** (see [Windows build](#windows-build)),
  plus xcodegen / zstd / spirv-cross. Each row has an install button when a command can fix it.
  The interpreter search covers the Pythons **uv** installs (`~/.local/share/uv/python`,
  `~/.local/bin`, `UV_PYTHON_INSTALL_DIR`; `%LOCALAPPDATA%\uv\python` on Windows) and picks the
  newest one that runs at 3.12 or newer — the script's own floor — with the build packages.
- Pick a game folder (or its four inputs separately). Base / update / DLC / `prod.keys` are
  recognised from the dump names.
- Build: runs the same script the SwiftUI app runs, streams its stage lines and log, then packs
  the RomFS archive and reports where the IPA and archive landed.
- `--work-dir` is passed only when the checkout's script declares it (an upstream checkout has
  no such option — issue #5).
- Bilingual: Chinese on Chinese devices, English elsewhere, and the header button switches.

## What is not there yet

- **The Windows build path has run on a real Windows machine** — a handheld PC, which is where the
  bug reports came from — through repository download, git auto-install and the LLVM / SDK / .NET
  downloads. The compile, link, `Metal` compile and the final IPA on Windows have still not been
  exercised end to end against a genuine LLVM-MinGW + iPhoneOS SDK + Metal Developer Tools
  install. See [Windows build → Open risks](#open-risks).
- No self-update. Repository download and update buttons do exist (`Download repository`,
  `Check for updates`, `Pull updates`), and they log what git is doing.
- No per-stage progress bar, no cancel-with-cleanup (cancel terminates the child).

## Layout

```
nspb_qt/
  __main__.py       entry point
  model.py          state, dependency detection, build runner (Qt signals, no widgets)
  ui.py             the window
  platform_util.py  per-OS paths, tool discovery, child environment
  i18n.py           language choice
  localization.py   generated from ../frontend/Sources/NSPortBuilder/Localization.swift
  win/              the Windows build path; imported only when sys.platform is win32
gen_localization.py regenerates localization.py
tests/test_win.py   the Windows-path tests that can run on macOS
```

---

# Windows build

On a Windows PC the pipeline cannot call `xcrun`, `xcodebuild` or `xcodegen`, and
`scripts/build_ipa_from_nsp.py` does not even import (`pwd` is a POSIX-only module). So the app
does not run the script directly on Windows. It runs `nspb_qt/win/driver.py`, which loads the
upstream file **as a module**, replaces the steps that assume a Mac, and calls its `cli()`.

The upstream file is never edited, so the daily sync cannot conflict with this work.

## What each macOS step becomes

| macOS | Windows |
|---|---|
| `xcodegen` + `xcodebuild` | LLVM clang per source file, linked by `ld64.lld` |
| `Launcher.swift` (SwiftUI) | `win/ios/Launcher.m` (UIKit, same `dm_show_launcher` contract) |
| `xcrun -sdk iphoneos metal` | Apple's **Metal Developer Tools for Windows**: `metal.exe` / `metallib.exe` |
| `xcrun -sdk iphoneos clang` | LLVM-MinGW `clang.exe` with `-target arm64-apple-ios26.0 -isysroot <SDK>` |
| `actool` asset catalog | loose PNGs named in `CFBundleIcons` (Pillow) |
| `sips` / `plutil` | Pillow / `plistlib` |
| Darwin compiler-rt (`@available`) | `win/ios/compat_rt.c`, linked only when LLVM has no `libclang_rt.ios.a` |
| `make -n -B dmhost` (source list) | the Makefile rules reproduced in `build_app.host_sources()`, **checked against the Makefile text** |
| `dmsh_xlate` apphost (a Mach-O) | `dotnet dmsh_xlate.dll`, the same locked build |
| `which`, `python3`, `ctypes.CDLL(None)` | `sitecustomize.py` rewrites them at the subprocess boundary |
| app icon via `actool` | Pillow, five sizes |
| `codesign` ad-hoc + entitlements | skipped, since the sideloader re-signs the IPA anyway |
| the IPA's Unix `x` bit | `win/fix_ipa_modes.py` rewrites the zip's central directory in place |

## What you need to install

The app installs everything it can itself: the Dependencies panel has an **Install** button per
row and **Install all missing**, and the rows it can fetch are .NET SDK, LLVM-MinGW and the
iPhoneOS SDK. What it cannot fetch is Apple's Metal Developer Tools (an Apple ID login) and the
optional Vulkan/GL tools.

Everything it downloads goes to `%LOCALAPPDATA%\NS Port Builder\tools`, outside the app folder, so
updating the app (re-extracting its zip) does not throw the 182 MB LLVM archive away.

Run this first if you prefer the command line. It lists what is missing and where to get it:

```bat
python -m nspb_qt.win.doctor
```

1. **Python 3.10+**, then `pip install PySide6 lz4 capstone fonttools pillow`
   (and `backports.zstd` before Python 3.14).
2. **.NET SDK 10** — the app downloads it (the zip, not the installer: no administrator rights,
   about 287 MB), or get it from <https://dotnet.microsoft.com/download/dotnet/10.0> (SDK, x64).
   `nx_extract` targets `net10.0`, so SDK 8 or 9 alone is not enough, and the dependency row says so
   rather than failing halfway through a build.
3. **LLVM-MinGW 20261020** — the app's Dependencies panel downloads and verifies it, or:

   ```bat
   python -m nspb_qt.win.doctor --fix
   ```

   Pinned SHA-256 (also in `toolchain.py`):

   | archive | SHA-256 |
   |---|---|
   | `llvm-mingw-20261020-ucrt-x86_64.zip` | `fd5462b7f5d93b2ff981fcd3f9c7e427e47f3203c64ea91c27bcc444eebd74cd` |

   Only the x86-64 archive is published by this app, so a Windows-on-ARM machine runs it under
   emulation (the dependency panel says so in a `host architecture` row).

   The official `LLVM-*-win64.msi` from llvm.org works too (same clang, same LLD).

4. **An iPhoneOS SDK 26.x** — either route works:

   ```bat
   python -m nspb_qt.win.doctor --sdk                     :: git, no Apple ID
   python -m nspb_qt.win.doctor --sdk-xip Xcode_26.5.xip  :: Apple's own, free Apple ID
   python -m nspb_qt.win.doctor --import-sdk D:\SDKs\iPhoneOS26.0.sdk
   ```

   The git route sparse-clones one SDK out of `xybp888/iOS-SDKs`. The `.xip` route streams
   Apple's archive and writes only `Platforms/iPhoneOS.platform/Developer/SDKs/`.

5. **Metal Developer Tools for Windows 6.x** —
   <https://developer.apple.com/download/all/?q=metal%20developer%20tools> (free Apple ID).
   The app cannot download this for you: Apple gates it behind a login.

6. **spirv-cross** and **zstd** — Windows builds. The Vulkan SDK has `spirv-cross` (and
   `glslangValidator`), and zstd has releases on GitHub.

If auto-detection picks the wrong folder, set it in
`%LOCALAPPDATA%\NS Port Builder\toolchain.json`:

```json
{
  "llvm_dir": "D:\\tools\\llvm-mingw-20261020-ucrt-x86_64",
  "ios_sdk": "D:\\SDKs\\iPhoneOS26.0.sdk",
  "dotnet_dir": "C:\\Program Files\\dotnet",
  "metal_dir": "C:\\Program Files\\Metal Developer Tools",
  "spirv_cross_dir": "C:\\VulkanSDK\\1.4.321.0\\Bin",
  "zstd_dir": "C:\\tools\\zstd"
}
```

Each key also has an environment variable (`NSPB_LLVM_DIR`, `NSPB_IOS_SDK`, `NSPB_DOTNET_DIR`,
`NSPB_METAL_DIR`, …), which wins over the file.

## Downloads, mirrors, and no console windows

Three things about how the app fetches its tools are worth knowing, because each of them was a
bug report from a handheld PC on a mainland connection:

**Mirrors.** GitHub release assets are the slow ones. Every download tries the direct URL plus
two mirrors (`ghfast.top`, `gh-proxy.com`), and picks between them by timing a 256 KB ranged
request — the report that prompted this was a 974-second download that *succeeded*, so failing
over on errors alone would never have helped. The pinned SHA-256 is the only thing that decides
what gets unpacked: a mirror serving different bytes is rejected exactly like a corrupted
download. Microsoft's CDN (the .NET SDK) is not mirrored, because it is fast enough on its own.

**Where tools land.** `%LOCALAPPDATA%\NS Port Builder\tools`. Not inside the app folder: the app
ships as a zip that gets re-extracted for every update, which would take 182 MB of LLVM with it.
Older builds used `<app>\_internal\.tools` and that path is still read, so an existing install
keeps working.

**No console windows.** The app is a windowed process, so every child it started — git, clang,
lld, the PortableGit self-extractor, and the repository's own Python scripts — used to get its
own black console window. On a handheld that read as "a command line appears, shows nothing, and
the install stops". `platform_util.hide_console_for_children()` patches `subprocess.Popen` once at
start-up, so children of children inherit an invisible console too.

## Verify each step

`nspb_qt.win.toolchain` does not trust that a path exists — it runs the tool:

| check | what it proves |
|---|---|
| `probe_compile` | `clang -target arm64-apple-ios26.0 -isysroot <SDK> -c` writes a **0xfeedfacf** arm64 `MH_OBJECT` |
| `probe_link` | `ld64.lld` links an arm64 **`MH_EXECUTE`** with `LC_BUILD_VERSION` platform 2 (iOS) |
| `probe_metal` | `metal.exe` → `.air`, then `metallib.exe` → a non-empty `.metallib` |

```bat
python -m nspb_qt.win.doctor            :: human-readable, runs the probes
python -m nspb_qt.win.doctor --json     :: for a bug report
```

Exit code 0 means every required row passed its probe.

### The one thing llvm-mingw gets wrong

llvm-mingw's release script (`strip-llvm.sh`) **deletes `ld64.lld.exe`**, so the zip only has
`ld.lld.exe`. That is not a dead end: LLD is one binary containing every driver and picks one
from `argv[0]`. Copying `ld.lld.exe` to `ld64.lld.exe` gives the Mach-O linker, and the app does
that automatically (`toolchain.ensure_ld64_lld`). A build of LLD that was stripped down to ELF
only is detected (`MachO` / `ld64.lld` strings absent) and reported instead of failing at link
time.

## Known unsupported game types

These need the game's own arm64 code to run, which upstream does inside a **Mac host**. No
Windows PC can do that, so the build stops with an explanatory message rather than producing a
broken IPA:

- **Run-time shader capture** — GLSLC capture (Fire Emblem: Three Houses, Portal), Vulkan
  capture (Super Mario Galaxy), GL capture of a non-LÖVE game. The game compiles its shaders
  only while running.
- **Unreal / Oodle decoding** — games whose shaders sit inside Oodle-compressed or Trinity packs
  (Pokémon Legends: Z-A, PlatinumGames titles, DRAGON QUEST XI S, …). Upstream decodes them by
  running the game's own decoder.
- **The heap check** for a provisional profile. Replaced by an estimate (a 2 GB pool for a game
  with virtual address memory). See `driver.heap_check`.
- **The pipeline archive** (`pso_offline.py` / `metal-tt`). Apple's Windows Metal tools do not
  ship `metal-tt`, so `DM_PSO_GPUS` is forced to `none`: the device builds those pipeline bases
  on its first start instead (slower first launch, same result).
- **`--prepare-xcode`**, **`--platform mac`** and **`--platform mac-app`**. Refused up front.

Games whose shaders are in the RomFS — Mario Wonder, Odyssey, Mario Kart 8 Deluxe, the Zelda
titles, Metroid Dread — do not need any of that.

## Run a build

```bat
python -m nspb_qt.win.driver D:\Games\MarioWonder -k D:\keys\prod.keys
```

The options are the upstream script's (`-h`). The IPA is unsigned, as on a Mac: sign it with
Sideloadly (Windows), AltStore, or similar, and enable the Increased Memory Limit capability if
the tool offers it. The IPA name and the RomFS archive come out where the macOS build puts them.

## Open risks

The app's own toolchain discovery, downloads and repository handling have now run on a real
Windows machine (a handheld PC). These are the parts that still have not, and that only a full
build on Windows plus a device run can settle:

1. **Shader libraries on the device.** They come from the Windows Metal compiler, not Xcode's.
   They must load and render on iOS 26+ (`newLibraryWithURL`). `own_compilers.py` accepts a
   different compiler version, so the build will not fail — only a device run proves it.
2. **The real rewritten modules.** Sections hundreds of MB, linked by `ld64.lld`, then signed by
   the sideloader.
3. **The UIKit launcher.** `win/ios/Launcher.m` is a hand port of `Launcher.swift`. It honours
   `section` grouping, a toggle's `on`/`off` values, env-file locking and Reset, but no one has
   tapped through it on a device.
4. **Icons without an asset catalog** on iOS 26.
5. **Line endings.** The checkout must keep LF. The shader chain hashes source bytes, so a CRLF
   checkout breaks `dmsh_xlate --source-sha`. `.gitattributes` enforces this, but a ZIP download
   with autocrlf on can still break it.

`nspb_qt/win/doctor.py` is the fastest way to narrow a failure: it separates "a tool is missing"
from "the tool exists but cannot do the job".

