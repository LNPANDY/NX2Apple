# Route C implementation plan — shell app + per-game framework

Status: **the dlopen gate is open** (device run on iOS 27.0.1, [probe-dlopen.md](probe-dlopen.md)),
design in [launcher-c-design.md](launcher-c-design.md). This plan turns the design into
milestones with a testable artifact each. The probe proved a one-function framework loads and
runs, but **the real payload is still unproven** (a framework with the game's ~100 MB of `__DM*W`
sections / up to 255 sections, `vm_remap` of its signed `__TEXT` with copy=FALSE,
`getsectiondata` on a dylib header). M1 exists to prove exactly that.

## Milestones

| # | Goal | Testable artifact | Risk | ~Effort |
|---|---|---|---|---|
| M1 | Real game payload as a framework, single game, no shell | `DM_FRAMEWORK=1` single-game IPA whose modules load from `DmGame.framework` | high | 1–1.5 wk |
| M2 | Shell app + one framework: list, pick, launch | `DmShell.app` + 1 framework, playable on a device | med-high | 1 wk |
| M3 | N games: per-game frameworks, one aggregate IPA | shell + N frameworks, two games playable | high | 1 wk |
| M4 | Per-game data/settings, external drive, DLC, msl/pso/profile | two games with isolated data, saves, settings | med | 1 wk |
| M5 | Signing/packaging/incremental hardening, FH gate, docs | two-game IPA, broken-framework tolerance, incremental timing | med | 0.5–1 wk |

## M1 — the first testable artifact

Keep "one game, one IPA" and move the game's modules out of the main executable into
`DmIOS.app/Frameworks/DmGame.framework`, `dlopen` it at launch, take its mach header via
`dlsym` + `dladdr`, and read its sections.

**New files**

- `dm/ios/project-framework.yml`: same app target as `project.yml` but without `Gen/embed.S`, with
  a `DmGame` framework target (`Gen/embed.S` + a marker `.m`, with resources `Gen/framework/dm`,
  `profile.tsv`, `game.manifest.json`), `embed: true`, `link: false`, app RPATH
  `@executable_path/Frameworks`.
- `dm/ios/framework/DmGameMarker.m`: `dmgame_image_marker` — only for `dlsym`/`dladdr`.
- `dm/host/loader_image.h`: `void dm_set_game_image_header(const void *mh);`
- `dm/ios/Sources/FrameworkBootstrap.m/.h`: `dlopen` → `dlsym(marker)` → `dladdr` →
  `dm_set_game_image_header(info.dli_fbase)`, and it logs `[RED]` on failure.
- `dm/ios/tools/gen_manifest.py`: builds `game.manifest.json` (schema below).
- `dm/ios/tests/test_framework_build.py`, `test_framework_link.py`.

**Changed files**

- `dm/host/loader.c:514`: `#define IMAGE_MH (&_mh_execute_header)` becomes a settable global
  (`dm_set_game_image_header`), defaulting to `&_mh_execute_header`. `nro_pieces()` (:521) and
  `map_image()` (:536) use it. **Do not** touch `force_init()` (:154) — `__DATA,swforce` is the
  host's own table.
- `dm/ios/Sources/main.m`: under `DM_FRAMEWORK_BUILD`, set `DM_PROFILE` to the framework's
  `profile.tsv` **before** the first `dm_profile()` call, call `dm_open_game_framework()` before
  `dm_host_preload_start()` (:237), and point `argv[1]` and `DM_NVN_SHMAP` at `<framework>/dm`.
- `dm/ios/tools/build_ipa.sh`: `FRAMEWORK=${DM_FRAMEWORK:-0}`. Framework mode generates
  `Gen/framework/{dm,profile.tsv,game.manifest.json,Info.plist}`, `xcodegen --spec
  project-framework.yml` (:134), signs the framework first and the app executable second
  (:164–174).
- `scripts/build_ipa_from_nsp.py` (~:2075): `--framework` → `DM_FRAMEWORK=1` in `ipa_env`.
- `dm/ios/tools/compile_check.py`: a second pass with `DM_FRAMEWORK_BUILD=1`.
- `dm/ios/tests/test_ipa_unsigned.py`, `test_xcode_workflow.py`: framework packaging/signing
  assertions, and `--prepare-xcode` uses `project-framework.yml`.

**Done when**

- Off-device: `compile_check.py` passes both ways, `test_framework_link.py` builds a synthetic
  framework with `xcodebuild -target DmGame CODE_SIGNING_ALLOWED=NO` and `otool -l` shows
  `__TEXT,__dm<mod>x0`, `__DM<mod>W,__img`, `__TEXT,__dm<mod>x1`, `__DATA,__dm_nro_tab`,
  `test_framework_build.py` packs/signs a stand-in (framework has no entitlements), and the default
  path (no `DM_FRAMEWORK`) is unchanged and the IPA has no `Frameworks/`.
- On device: sideload the `DM_FRAMEWORK=1` IPA. The log shows the framework path, handle, image
  base and each module's base/size, `DM_LOADHASH=1` per-module sha256 lines match the default
  build exactly (proof the framework path loads byte-identical code), a second run with an NRO
  game (SSBU) shows `__DATA,__dm_nro_tab` and `nro.tsv` working, and iOS 26 and 27 pass if available.

## M2 — shell + one framework

`DmShell.app` lists one game. Play sets the environment, `dlopen`s the framework, calls
`dm_set_game_image_header` + `dm_host_preload_start`, then shows the existing game view.

- New: `dm/ios/project-shell.yml`, `dm/ios/Shell/{ShellMain.m,ShellView.swift,GameManifest.swift,
  GameLibrary.swift,GameData.m,GameLauncher.m,BootState.m}`, `dm/ios/tools/build_shell.sh`,
  `dm/ios/tests/{test_shell_library.py,test_framework_bootstrap.py}`.
- Changed: `main.m`'s `game_dir_for`/`romfs_dir_ok`/`romfs_locate`/`set_data_env` move to
  `GameData.m` (explicit title id/marker, no `dm_profile()`), `g_boot_ok` moves to `BootState`,
  `front_ios.m` presents the shell root only after preload, `Launcher.swift` reads
  `DM_LAUNCHER_JSON` (bundle fallback), and `LauncherSettings.swift` gains a per-game key/suite.
- `dm/host/main.c:95` falls back to the compiled `DM_GAME_MODULES`: the shell passes the manifest
  modules in argv explicitly (no code change), or the fallback changes to
  `dm_profile()->modules` — pick one in M2 and keep the default path identical.
- Done when: `xcodebuild -scheme DmShell` builds, `test_shell_library.py` covers the three states
  (playable / needsData / needsFramework / broken), and on a device the shell + 1 framework lists and plays and the
  log shows per-game `DM_PROFILE`/`DM_ROMFS`/`DM_SAVE`.

## M3 — N games in one IPA

- New: `dm/ios/tools/pack_launcher_ipa.py` (reads each manifest, validates chain vs
  `dm/gfx/nvn/dmsh_chain.h`, unique title ids, `CFBundleExecutable` vs manifest, signs in order:
  framework → shell executable (entitlements) → shell bundle, and calls `pack_ipa.py`),
  `tests/test_pack_launcher_ipa.py`, optional `framework_cache.py`.
- Changed: `build_ipa.sh` gains `DM_FRAMEWORK_ONLY=1` (framework + manifest, no app, no pack),
  `build_ipa_from_nsp.py` gains `--framework-only`, and `GameLibrary.swift` scans
  `Frameworks/*.framework/game.manifest.json` + `Documents/games/*/`.
- Done when: two synthetic frameworks pack, chain mismatch and duplicate title ids are rejected,
  and on a device one IPA holds two games that both play and a broken framework only breaks its own row.

## M4 — per-game data, settings, external drive, DLC

- `GameDataPicker.swift`, `test_shell_data.py`. `DataBookmark` keys become
  `pickedDataBookmark.<titleID>` with migration, `GameData.m` resolves like `main.m:69–117` with
  explicit title id/marker, `GameLauncher.m` sets `DM_AOC_DIR`, `DM_MSL_DIR`, `DM_PSO_BUNDLE`
  per game first and then app-wide, `LauncherSettings` is per game, and `GameLibrary` never treats
  a data file as "code installed" (design §233–240).
- Done when: two titles' `Documents/games/<id>/{romfs.img,romfs,save,temp,msl,pso,aoc}` are
  isolated, a stale bookmark falls back, an identity mismatch falls back, and DLC `aoc/<index>.img`
  mounts (`hle_fs.c:516-518`).

## Manifest (`game.manifest.json`, in the framework root)

Required keys: `schema` (1), `title_id` (16 hex), `name`, `display_version`, `package_version`,
`modules` (≥1), `nro_count`, `chain` (`b-<hex>`), `loader` (`FR`|`FH`), `framework`
(`<name>.framework`), `framework_executable`, `image_marker` (`dmgame_image_marker`), `profile`
(`profile.tsv`), `shader_map` (`dm/shader_map.tsv`), `launcher` (`dm/launcher.json`),
`romfs_marker`, `romfs_identity` (`DMROMFSID1 …`), `min_os`. Optional keys are `icon`, `built_by`,
`built_at`, `bytes`. Validation: schema, `CFBundleExecutable`, framework name, chain equal to the
shell's `DMSH_CHAIN`, unique title ids, and at launch the loader cross-checks sections per module
(`__TEXT,__dm<mod>x0`, `__DM<mod>W,__img`, `__TEXT,__dm<mod>x1`, and `__DATA,__dm_nro_tab` when
`nro_count > 0`) — a mismatch marks the game `broken` without affecting others.

Discovery: frameworks come from `Bundle.main.privateFrameworksURL/*.framework` and data from
`Documents/games/<title_id>/` (`romfs.img` complete, or
`romfs/<manifest.romfs_marker>`), with a per-title bookmark for external drives, and the results merge into
playable / needsData / needsFramework / broken.

## Environment at game start

| Variable | Value in the shell |
|---|---|
| `DM_PROFILE` | `Documents/games/<id>/profile.tsv`, else `<framework>/profile.tsv` — before any `dm_profile()` |
| `DM_ROMFS` | picked path → `Documents/games/<id>/romfs.img` → `.../romfs/` (same order as `main.m:69–117`) |
| `DM_SAVE` / `DM_TEMP` | `Documents/games/<id>/{save,temp}` |
| `DM_MSL_DIR` | `Documents/games/<id>/msl` if present, else `<App>/msl` |
| `DM_PSO_BUNDLE` | `Documents/games/<id>/pso` if present, else `<App>/pso` |
| `DM_NVN_SHMAP` | `<framework>/dm/shader_map.tsv` |
| `DM_LANG` | per-game saved choice / the framework's `launcher.json` default |
| `DM_AOC_DIR` | `Documents/games/<id>/aoc` (`<index>.img` or folder) |
| `DM_FONT_DIR` | `<App>/dm/font` (shared) |
| others (`DM_SHOW_FPS`, `DM_METAL_HUD`, …) | shell settings + `Documents/env.txt` + bundle `dm/env.txt`, same precedence as `main.m:181–215` |

Order: set `DM_PROFILE` → resolve data (explicit title id) → set the rest → `dlopen` + `dlsym` +
`dladdr` + `dm_set_game_image_header` → `dm_host_preload_start` with
`argv = [dmhost, <framework>/dm, <manifest modules…>]` → present the game view.
`dm_host_preload_start` and `dm_profile()` each run **once per process**: one game per process,
`exit(0)` on quit (same conclusion as design §4/R4).

## Signing and packaging order

1. Build each `<Game>.framework` unsigned.
2. Sign the framework bundle first (no entitlements).
3. Build `DmShell.app` and place frameworks in `DmShell.app/Frameworks/`.
4. Sign the shell executable with `com.apple.developer.kernel.increased-memory-limit`.
5. Sign the shell bundle last so `CodeResources` covers every nested CDHash (same order as
   `build_probe.sh:79–86`).
6. `pack_ipa.py` unchanged (mapping pairs, `--skip`, fingerprint reuse), and `pack_launcher_ipa.py`
   orchestrates, skips the shell's `Frameworks/` in the generic map and maps each framework
   explicitly.
7. Self-check: `codesign -vvv --verify --strict` on framework and app, `otool -l` for
   `LC_ID_DYLIB=@rpath/<game>.framework/<game>` and app `LC_RPATH`, and `plutil` on both Info.plists.

Incremental: `pack_ipa.py` keys on size/mtime/ctime/inode, and ad-hoc re-signing rewrites bytes —
cache each signed framework per game (`$W/build/ios/frameworks/<id>/`) and never re-sign an
unchanged one, so a shell change then rewrites only the shell entries.

## Tests

Off-device: the tool-test loop, `compile_check.py` in both modes, `xcodegen` + `xcodebuild` of the
framework from a synthetic `Gen`, macOS `dlopen`/`dlsym`/`dladdr` of a small dylib
(`getsectiondata`/`vm_remap` are covered by M1 on device), synthetic aggregate IPA checks
(`unzip -l`, `codesign -vvv`, negative chain/duplicate cases), `test_shell_library.py` three-state
cases, and `test_shell_data.py` environment/isolation.

On-device (minimum): M1 one real NVN game + one NRO game with `DM_LOADHASH` matching the default
build, M2 shell + 1, M3 shell + 2 with a broken framework, M4 two games with data/settings/DLC/
external drive, and M5 upgrade/reinstall (bookmarks), incremental timing, iOS 26.1/27.

## Top risks

1. **Real payload unproven (M1)** — run a real game, not the probe, and compare `DM_LOADHASH` with the
   default build. A `dlopen` success does not imply `vm_remap` works.
2. **Nested re-signing / entitlements** — framework first, shell last, and the framework carries no
   entitlements. Test with AltStore, Sideloadly and i4Tools once, record which one.
3. **Size / re-sign / install limit** — code dimension stays 4–8 games/IPA (not unbounded), data
   stays in Documents, and every added game means a new IPA, re-signed.
4. **Shell lifecycle / globals / ObjC** — one game per process, one preload, `DM_PROFILE` before the
   first `dm_profile()`, and FH must handle duplicated ObjC classes (design §36–42, 277–284).
5. **Complexity regressing the default path** — default `project.yml` untouched, framework mode is
   opt-in, existing tests must stay green, and a cache prevents re-signing.

## FH fallback trigger (decidable)

Switch to FH only when **all** hold: `dlopen` and `dlsym(marker)` succeed and `dladdr` gives the
framework base, and a plain control dylib/framework in the bundle loads and runs, but
`getsectiondata(framework_mh, "__TEXT", "__dm<mod>x0")` returns NULL for real modules, or dyld
rejects a pure-module dylib carrying several `__DM<mod>W` sections. If `dlopen` fails for any
bundle framework (contradicting the probe), or `vm_remap` of signed pages cannot execute, FH does
not help (it also maps an image) — fall back to architecture A/B instead of spending the week.

## Documentation to update as this lands

- `docs/ROADMAP.md`: C is **not** unbounded (code dimension 4–8 games/IPA, and every added game needs a
  re-signed IPA, while the data dimension is the unbounded one — see design §136–153). The `romfs_locate`
  row is stale (`main.m` already does per-game + picker + identity).
- `docs/WORK-IN-PROGRESS.md`: C7 "experiment passed, M1–M5 in progress", architecture A's per-game
  layout is done, and the runtime profile is on main since `3b36083f`.
- `README.md` / `README.zh-CN.md`: v0.4.7's "launcher not started" note is stale.
- `docs/probe-dlopen.md`: device result recorded (done in #139), and keep "what it does not prove".
- `docs/launcher-c-design.md`: status line. The text at §52–53 says omitting argv lets the profile's modules
  apply, but `dm/host/main.c:95` falls back to the compiled macro — fix the doc or the code in M2.
- `docs/development.md`, `docs/reference/packing.md`, `docs/frontends.md`: `--framework`,
  `build_shell.sh`, `pack_launcher_ipa.py`, signing order, incremental cache, and what the shell is.
