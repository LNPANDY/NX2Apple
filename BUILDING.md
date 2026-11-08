# Building from source

The launcher (see the [README](README.md)) runs the same scripts a terminal does. This page is the by-hand route, for advanced users, for development, or when the launcher is not an option: the tools, your `prod.keys`, and the IPA built from a terminal. Contributing rules are in [CONTRIBUTING.md](CONTRIBUTING.md).

## Get the tools

This is the command-line route the launcher drives for you. The build is upstream's. Follow upstream's [README](https://github.com/seedds/nxnative) to install Xcode, Homebrew tools and the Python packages, then pack an IPA.

```bash
git clone https://github.com/<you>/NX2Apple.git
cd NX2Apple
python3 tools/engine.py sync                      # the engine (nxnative at the pin plus our patches) into engine/, about 80 MB
brew bundle --file=Brewfile                       # xcodegen, zstd, spirv-cross, glslang (the NSP script checks for it), .NET SDK
python3 -m venv .venv                             # Homebrew's Python refuses global pip installs (PEP 668)
.venv/bin/python -m pip install lz4 capstone fonttools zbic nsz "backports.zstd; python_version < '3.14'"
source .venv/bin/activate                         # so that python3 below is the venv's (in each new terminal)
```

## What you need on disk

Three things, none of which ship with the repository:

| What | Where it comes from | Used by |
|---|---|---|
| **`prod.keys`** | dumped from **your own console** (see below) | the extractor, to decrypt your game |
| **The game's NSPs** | dumped from your own cartridge or eShop purchases | the extractor |
| **Xcode + iOS SDK** | the App Store | the app build |

`prod.keys` is the console's key set — a text file of `name = hex value` lines (~230 entries:
`master_key_xx`, `titlekek_xx`, `header_key`, `key_area_key_application_xx`, …). Every Switch
homebrew tool reads this format. It is **not** tied to a specific game: one `prod.keys` decrypts
any of your games. The only requirement is that the file contains keys for the key generation
(firmware era) the game was packaged with — a current dump covers every retail game.

Where to put it is up to you. You pass the path with `-k`:

```bash
# any layout works, e.g.
~/keys/prod.keys
# or keep it beside the game's NSPs
~/Games/Hades2/prod.keys
```

```bash
python3 engine/scripts/build_ipa_from_nsp.py ~/Games/Hades2 -k ~/keys/prod.keys
```

How keys are dumped is documented across the Switch homebrew community (Lockpick_RCM from a
hacked console is the usual route). This repository does not cover that step and ships none of
it. Two practical notes from real dumps:

- **Malformed lines.** Some dumpers emit lines whose hex value has the wrong length (33 bad
  `master_kek_source_*` lines in one real dump), which makes the extraction tool refuse the whole
  file. Delete the offending lines and keep a backup of the original.
- **Updates.** An update NSP's ticket may carry a newer key generation than the base game's. The
  extractor reads the title key straight from the common ticket inside each NSP, so in practice
  both decrypt fine as long as `prod.keys` is reasonably current — verified here with a base
  game on generation 15 and its update on 16, using a keys file that only reached 15.

`backports.zstd` is needed for Tears of the Kingdom's zstd dictionaries. Other games do not use it.

## The nxb builder (nxkit)

[nxkit](https://github.com/v0lumehi/nxkit) builds the `nxb` tool in Rust. `nxb` makes the same files as the build script, faster. The Mac launcher builds with it by default. The setting is "Build with nxb" (Settings, Build tools). With it on, the launcher starts one program, `nxb build`:

```bash
NXB_ENGINE=engine nxb build <NSP folder> --platform mac-app -k <prod.keys> --title-id <title ID> \
  -o <app> --work-dir <build folder> --engine engine --progress json
```

- The program is the `nxb` binary the player chose in Settings (the binary, or the folder that holds it), else the copy inside the app, which `frontend/nxbuild.pin` names. It needs nxb 0.6.3 or newer. The launcher reads `nxb version` first and stops with a message when the nxb is older or the chosen path has no nxb. A launcher with no copy and no chosen path builds with the script and says so in the log.
- The command line is the script's own. The launcher builds the arguments it gives the script (input folder, `.nup` file or dump folder, `-k`, `--work-dir`, `--platform`, `-o`, `--shell-framework`, `--team-id`, `--romfs`, `--env-file`, `--title-id`) and runs `nxb build` with them. DLC, NSZ, XCI and merged packages in the folder are found by nxb itself. A game with no profile is surveyed by nxb. The launcher does not pass `--no-heap-check`, so nxb stops there with exit code 4.
- `--progress json` prints one JSON event per line (`stage`, `step`, `progress`, `stage_end`, `say`, each with `code` and `severity`). The launcher shows them as its own stages and writes every line to the build log.
- Exit code 4 means "not supported yet". The launcher then runs the build script with the same arguments, in the same build. The log keeps nxb's lines and says why the script runs. Every other failure shows nxb's exit code in words and its last error line. The exit codes are 0 done, 1 error, 2 bad arguments, 3 damaged data, 4 not supported yet, 6 missing key and 130 interrupted.
- Turning the setting off builds every game with the script. A player who turned it off before keeps that choice.

## Build the IPA

The main build script packs a **slim IPA by default** (no RomFS inside, as the app reads the game's data from its folder on the device, `Documents/games/<id>/`), so the build above already produced it. To re-pack just the package later:

```bash
GAME=<title id> W=<work dir> PATCHED=<patched dir> \
  ROMFS=<RomFS dir> MSL_IOS=<shader dir> \
  engine/dm/ios/tools/build_ipa.sh <output.ipa>
```

`--full-romfs` (or `DM_FULL_ROMFS=1`) packs the RomFS into the package instead — upstream's
behaviour, only sensible for small games.

The RomFS no longer has to be packed into a shard archive: the build writes the game's data as a single `romfs.img`. Shard archives made earlier (`romfs.idx` with `romfs.00`, `romfs.01`, …) are no longer read; the launcher reports such a folder as having no game data, and the data is sent again once as a `romfs.img`.
