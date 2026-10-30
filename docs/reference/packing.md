# Packing

## Build tools

### Homebrew .NET is on PATH but apphosts cannot find the runtime

- **Symptom:** the first extraction stops with `nx_extract exit code 131` and `.NET location: Not found`, even though `dotnet` is on `PATH`. The shader translator can fail the same way.
- **Cause:** standalone .NET apphosts search runtime roots and registered installations, not `PATH` ([.NET runtime discovery](https://learn.microsoft.com/en-us/dotnet/core/tools/dotnet-environment-variables#dotnet_root-dotnet_rootx86-dotnet_root_x86-dotnet_root_x64)). Homebrew's formula installs the runtime under `libexec` and its `bin/dotnet` can be a wrapper that sets `DOTNET_ROOT` only for its own child ([Homebrew caveat](https://formulae.brew.sh/formula/dotnet)). Resolving that wrapper's symlink gives `bin`, not the runtime root.
- **Fix:** `scripts/build_ipa_from_nsp.py` `configure_dotnet` derives the root from the `Microsoft.NETCore.App` entry in `dotnet --list-runtimes`, using the build's environment, before any extraction or survey. It exports `DOTNET_ROOT` both to that environment and to `os.environ`, for tools launched with an explicit environment and those that inherit it. Caller-supplied roots, including architecture-specific overrides, retain precedence. A failed or malformed probe leaves the environment unchanged rather than guessing the wrapper's directory.
- **Found on:** [Balatro](../../dm/games/0100CD801CE5E000/README.md), first extraction with Homebrew .NET ([PR #284](https://github.com/seedds/nxnative/pull/284)). Applies to every game's build on that installation setup.

### The shader step stops with an empty `xlate_source`

- **Symptom:** the extraction and captures succeed, then the shader step stops with `translation chain tools do not match the lock file: xlate_source: lock … / actual` and nothing after `actual`, which reads like a stale translator.
- **Cause:** the translator (`dmsh_xlate_bin/dmsh_xlate`) is a universal framework-dependent apphost. When it finds no .NET 10 runtime for the slice it starts as, it exits 131 with an empty stdout. A Python under Rosetta (an Intel Homebrew's) starts it as x86_64, and it finds only the arm64 .NET; extraction is not affected, because `nx_extract` is built for the SDK's own architecture only. An Intel .NET on Apple silicon, or a `DOTNET_ROOT` that names one, fails the same way. `tools_now` (then in `dmsh_chain.py`) kept only the stdout of `dmsh_xlate --source-sha`, without its exit code or stderr, so the apphost's own message was lost.
- **Fix:** the NSP script checks the environment before extracting anything: `check_native_python` stops under Rosetta (`sysctl.proc_translated`), and `check_prereqs` starts the translator once with `--source-sha` and stops with its first message line (`check_translator`). It also checks glslang and, for an iPhone build, the iOS SDK (`check_ios_sdk`, before the Metal check, whose message would blame the Metal toolchain). `own_compilers.py` no longer asks a Mac-only shader build (`DMSH_TARGETS=mac`) for the iOS Metal compiler. `tool_lock.py` records `--source-sha`'s failure instead of its empty stdout (`xlate_embedded`: `does not run (<first message line>)`), so `dmsh_build.py` run directly and `--update-lock` stop with the same message as the NSP script, without the lock and rebuild lines. The tool checks used to be in `dmsh_chain.py`, which is part of the chain version and of every shader's cache key, so that fix rebuilt every library; they now live in `tool_lock.py`, outside both, and a change to them rebuilds nothing.
- **Found on:** NX2Apple builds ([LNPANDY/NX2Apple#31](https://github.com/LNPANDY/NX2Apple/issues/31), item 3; [PR #477](https://github.com/seedds/nxnative/pull/477), [PR #487](https://github.com/seedds/nxnative/pull/487)); reproduced with `arch -x86_64`. Applies to every game.

## IPA archives

### A streamed file changes size and the IPA fails its CRC check

- **Symptom:** packing succeeds, but `unzip -t` or Python's `ZipFile.testzip()` reports a bad CRC for a large deflated file.
- **Cause:** `pack_ipa.py` wrote the uncompressed size collected before reading. Its streaming check compared the output size only for stored files, so a compressible file that grew or shrank still published an archive with the old size.
- **Fix:** count uncompressed bytes as they are read and compare them with the listed size before completing either streamed method. A mismatch stops the pack and removes the partial archive, preserving the previous IPA and its reuse index. Regression tests cover growth and shrinkage with both deflate and store.
- **Found on:** synthetic IPA inputs while reviewing [PR #279](https://github.com/seedds/nxnative/pull/279); no game files required.

## RomFS images

### RomFS folder transfers fail or leave stale game files

- **Symptom:** `devicectl` copying a large RomFS folder fails with POSIX error 24 (`EMFILE`) or spends most of its time on small files; deleting an old folder during iOS startup hits the launch watchdog. A push after changing extracted files can also keep sending old assets if an image is reused solely because it exists.
- **Cause:** a folder transfer performs hundreds of thousands of file operations. The image cache must track its source tree, and magic plus total length cannot establish that an image's index is valid. Accepting that weak check before deleting the working folder loses the fallback when mounting later rejects the index.
- **Fix:** `dm/tools/romfs_image.py` packs one `DMROMFS1` file: a 32-byte header, file bytes, then the index and name pool. Each directory has a sorted, contiguous run of child entries; the host binary-searches each path component and reads file ranges with `pread` through one descriptor per mount. Overlay folders keep precedence and directory listings merge both sources. The shared `dm/host/romfs_image.h` loader checks the full index before either mounting or iOS folder cleanup: length, entry and name bounds, file ranges, a rooted breadth-first directory tree, and sorted, unique child names. It supports an empty root too. Invalid images fall back to the folders on iOS; an explicit invalid `DM_ROMFS` image is refused with a `[RED]` line. The index check detects interrupted sequential transfers and structural damage, not same-length corruption inside file contents. The packer publishes by rename only after the source stays stable. Its reuse stamp tracks source names and file metadata including ctime, the packer and image identity; the push helper always checks it, and `--repack` forces a rebuild. Usage: [Quick reinstalls](../development.md#quick-reinstalls).
- **Found on:** [Tears of the Kingdom](../../dm/games/0100F2C0115B6000/README.md#files-and-shaders), whose 304,000-file transfer and startup deletion failures are reported in [PR #369](https://github.com/seedds/nxnative/pull/369). [ANIMAL WELL](../../dm/games/010020D01AD24000/README.md#files) provides the empty-image boot case. Synthetic packer/host tests cover actual file reads, case aliases, overlay merging, corrupt indexes and changed sources; the macOS Foundation test executes iOS's locator to check that rejected images preserve its folder.

### A stale `DM_ROMFS` path crashes the game soon after `nnMain`

- **Symptom:** a direct `dmhost` run logs `fs mount rom: → <path> (read-only)` for a path that does not exist, then crashes in the game's code a fraction of a second after `nnMain` (Echoes of Wisdom: `CRASH sig=11 addr=0x88` 0.3 s in). The host now stops at the mount instead with `FATAL the game files <path> (rom:) are missing: neither a folder nor a RomFS image`.
- **Cause:** an old run command still named the extraction's `RomFS` folder after a rebuild replaced it with `RomFS.img` ([RomFS folder transfers](#romfs-folder-transfers-fail-or-leave-stale-game-files)). The read-only mount accepted any path, so every read failed and the game used the missing data. The iOS app and the Mac app launcher check their game files before they start the host; direct runs had no such check.
- **Fix:** `mount_ex` (`dm/host/hle_fs.c`) stops on a read-only, non-save mount whose path is neither a folder nor a regular file, with the same `stat` that tells an image from a folder. Add-on content and system data check their paths before mounting, so only the rom mount (`DM_ROMFS`, or `$DM_ROOT/romfs` when it is unset) reaches it. `dm/host/tests/t_fs.c` checks a missing path and a fifo in a forked child.
- **Found on:** [Echoes of Wisdom](../../dm/games/01008CF01BAAC000/README.md#found-on-this-game) 1.1.0 on the Mac ([issue #615](https://github.com/seedds/nxnative/issues/615), [PR #616](https://github.com/seedds/nxnative/pull/616)).

### Separate RomFS deployment loses its image or folder fallback

- **Symptom:** a successful `--romfs separate --no-keep-extracted` build prints a push command pointing at deleted game files. On iOS, a complete image for another build can also prevent startup despite a valid `Documents/romfs` folder.
- **Cause:** separate mode omitted the extraction-retention check, so normal post-build cleanup deleted the image needed for transfer. The startup identity rejection returned before the existing folder lookup.
- **Fix:** reject separate mode without `--keep-extracted` before extraction or building. Reject a mismatching image while continuing to the validated folder fallback; move a folder aside for deletion only after accepting the image. Matching images and the default bundled route retain their behavior. The identity covers image size, header and index, not same-length file-content changes.
- **Found on:** synthetic CLI and Foundation startup tests while integrating [PR #493](https://github.com/seedds/nxnative/pull/493), after [PR #478](https://github.com/seedds/nxnative/pull/478); no game or device is needed to reproduce either failure.

### A hand-copied RomFS.img is not found on iOS

- **Symptom:** a `--romfs separate` app whose image was copied into its Documents folder by hand (Finder, the Files app, a LiveContainer guest) logs `boot: game files not found (Documents/romfs.img, Documents/romfs or <App>/romfs)`, and a build with `romfs.id` shows "There is no game file image on this device.", though the complete image is there. Renaming it to `romfs.img` makes the game start.
- **Cause:** the NSP script writes the image as `extract/<version>/RomFS.img`, and `push_romfs.sh` copies it to `Documents/romfs.img`. A hand copy keeps the source's name. The Mac's file system ignores letter case, so the mismatch never shows there, but iOS's does not, and `main.m` looked up only the exact `romfs.img`.
- **Fix:** `main.m` (`romfs_document_images`) lists Documents for `romfs.img` in any letter case, `romfs.img` itself first, and takes the first that is complete and passes the `romfs.id` check; a rejected or incomplete one falls through to the next spelling, then to the folders. The identity report, the backup exclusion and the log lines use the names found. Folder names (`Documents/romfs`) are still matched exactly.
- **Found on:** South Park: The Fractured But Whole 1.05 (`01008F2005154000`, no profile here) on an iPhone 15 Pro Max, [issue #582](https://github.com/seedds/nxnative/issues/582). The Foundation startup test runs the locator on a case-sensitive APFS disk image.

### Building creates a full RomFS tree before packing its image

- **Symptom:** reducing the iPhone transfer to one image still creates thousands of resource files on the Mac, and build scanners require the expanded folder.
- **Cause:** folder extraction followed by a separate image pack duplicates the work; ordinary filesystem APIs cannot address files inside an image.
- **Fix:** the NSP pipeline passes `--romfs-image` to `nx_extract`. LibHac layers the update over the base and checks its integrity while the writer streams file bytes into a temporary `DMROMFS1` image, appends the sorted directory index and publishes by rename. ExeFS remains expanded; RomFS and each DLC remain one physical file. `dm/tools/romfs.py` gives the scanners read-only virtual paths, bounded seeks and archive mappings (Python 3.12+), without changing the process's standard filesystem APIs. The IPA packer maps the physical image to `Payload/DmIOS.app/romfs.img`; iOS and the Mac launcher validate and mount it in place. Neither installation nor startup expands the resource files. Documents overrides and legacy folder inputs remain supported. A source image is uncompressed; the IPA can deflate it, so file-count reduction does not imply a smaller installed byte count. Full images for separate game versions cannot share unchanged individual files through APFS clones as legacy folder extraction did.
- **Found on:** [ANIMAL WELL](../../dm/games/010020D01AD24000/README.md#files), whose direct image is an empty root (56 bytes); the local Baba Is You provisional build exercises 6,374 files in a 103,473,292-byte image, 131 shaders and an unsigned IPA containing only the single image entry. [Raging Loop](../../dm/games/010020400E1C2000/README.md#files-and-shaders) supplies Unity resources: all 1,473 source manifest entries match the image, and every registered shader remains in the scan. Synthetic integration tests call the actual LibHac writer, read unaligned archive ranges, and exercise IPA mapping, Xcode staging and bundled-image startup.

### The zstd command given a path inside the image

- **Symptom:** the NSP script stops at the shader split of a registered profile with `[RED] 13744 file(s) could not be read, their shaders are left out (first: AI/FileEntry/FileEntry.Product.100.byml.zs: CalledProcessError: Command ['zstd', '-d', '-c', '-q', '…/extract/v0/RomFS.img/AI/…'] returned non-zero exit status 1.)`.
- **Cause:** `shader_split.py`'s `unzs` read a `.zs` file through `romfs.open`, which reads inside the image, but then handed its path to the `zstd` command, which can only open real files (`Not a directory`).
- **Fix:** `unzs` feeds the command the bytes it read (`input=`). No other tool hands an external command a path inside the image. Test: `test_romfs_read.py` `test_zstd_file_inside_an_image`.
- **Found on:** [Super Mario Bros. Wonder](../../dm/games/010015100B514000/README.md#shaders): every file of its RomFS is zstd-compressed, 13,744 left out in both versions; the first image-backed build after the folder extraction.

## Launcher metadata

### A Mac front end's default settings change Metal execution paths

- **Symptom:** starting a Mac app through a front end with unchanged settings enables the encode thread, and can disable Metal 4 pipelines and the pipeline archive; starting the same app from Finder keeps the host's defaults.
- **Cause:** Mac `launcher.json` reused iOS defaults from `settings.tsv`. `rec_on` in `nvn_rec.h` defaults off on Mac and on on iOS; `pso4_on` in `nvn_mtl.m` defaults on on Mac and follows the profile on iOS. The exported defaults instead enabled the encode thread everywhere and followed the profile for Metal 4 everywhere. A front end applying those values changed the Mac host's behavior without a player override.
- **Fix:** a setting's default may be `<ios>|<mac>`, selected before resolving a profile macro or build variable. Metal 4 uses `DM_GAME_PSO_MTL4|1`, the encode thread `1|0`. The generator validates the platform and the pair. Tests cover a profile with Metal 4 on and one with it off, and both platforms; the host and shader chain are unchanged.
- **Found on:** synthetic metadata generation for [Super Mario Bros. Wonder](../../dm/games/010015100B514000/README.md) while reviewing [PR #352](https://github.com/seedds/nxnative/pull/352); checked against the native defaults, without a gameplay run.

## External drives

### A game folder on an exFAT drive reads one update as two, or fails to remove a folder

- **Symptom:** with the NSP folder on an exFAT or FAT drive, the build leaves out an update whose name has no `[v…]` tag (the folder seems to hold two), or a stage stops with `FileNotFoundError` on a `._<name>` path inside `<id>_build/` and the next run fails on the half-deleted folder.
- **Cause:** these file systems have no extended attributes, so macOS keeps a file's attributes (a download's quarantine flag) in an AppleDouble file `._<name>` beside it, and deletes it with the file. `scan_nsps` took `._Update [<title ID>800].nsp`, 4 KB of metadata, for an update: its name carries the title ID. Deleting `x` takes `._x` with it, so `shutil.rmtree`'s later unlink of the listed `._x` found it gone; before Python 3.13 that error ended the removal.
- **Fix:** `scripts/build_ipa_from_nsp.py` `scan_nsps` takes a file only when its header is one nx_extract opens (`is_package`: `PFS0` at 0, or an XCI's `HEAD` at 0x100), and says which files it skips. The name tag alone no longer counts, so the same check also rejects any other tagged file that is not a package. Names that start with `._` are skipped without a line. The script's `rmtree` passes ENOENT from `shutil.rmtree` (the entry is gone, which is the goal) and raises every other error. `dm/tools/tests/test_nsp_external_drive.py` and `test_nsp_scan.py` cover both without game files.
- **Found on:** the NX2Apple fork's users, who keep games on external drives ([PR #476](https://github.com/seedds/nxnative/pull/476), part of [issue #388](https://github.com/seedds/nxnative/issues/388)); reproduced on an exFAT disk image made with `hdiutil create -fs ExFAT`. Applies to every game.

### The c1 guard stops on an AppleDouble file after the shader build

- **Symptom:** with the build folder on an exFAT or FAT drive, the shader step compiles every library and then stops in `c1_guard.py` with `UnicodeDecodeError: 'utf-8' codec can't decode byte …` (dmsh_build.py: `[RED] c1_guard.py failed`), reading a `._<key>_b.metal`.
- **Cause:** the same AppleDouble files as above, beside the shader build's outputs. `c1_guard.py` took every name ending in `.metal` for a shader's MSL and read the binary `._` file as text. `cb_extent.py` (every `_b.json`) skipped it only because it ignores what it cannot parse, and `dmsh_mtlcache.py` (every `_b.metal`) took `._<key>_b` for a shader, found no readable reflection for it and so filled the Metal cache from none of that folder's libraries.
- **Fix:** the three take only the names the shader build writes, `<16 hex key>_b….metal` / `.json` as `dmsh_build.py` (`OUT_KEY`) and `regress.py` already did: `c1_guard.py` `outputs` (which `cb_extent.py` uses too) and `dmsh_mtlcache.py` `OUTPUT`. None of them is part of the chain version. `dm/tools/tests/test_nsp_chain.py` runs both table tools on a folder with `._` files; the old `c1_guard.py` stops on it. On 13 Sentinels' 751 shaders both tables are unchanged.
- **Found on:** a user's iOS shader build on an external drive ([PR #555](https://github.com/seedds/nxnative/pull/555)). Applies to every NVN game.

## Compressed inputs

### NSZ decompression rejects `--keys`

- **Symptom:** `decompress NSZ` stops immediately with `nsz: error: unrecognized arguments: --keys …`.
- **Cause:** `nsz` 4.6.1 has no `--keys` argument. It loads `keys.txt` beside `sys.argv[0]`, or falls back to `~/.switch/prod.keys`, while importing its modules, before parsing arguments ([4.6.1 key loader](https://github.com/nicoboss/nsz/blob/4.6.1/nsz/nut/Keys.py)). Version 5.0 supports `--keys` ([argument parser](https://github.com/nicoboss/nsz/blob/5.0.0/nsz/ParseArguments.py)); staging `keys.txt` also supports 4.6.1.
- **Fix:** `scripts/build_ipa_from_nsp.py` `decompress_nsz` prefers the current Python's module: it links the file selected by `-k` as `keys.txt` in the conversion's temporary folder and runs `nsz -D` there, with `sys.argv[0]` set to `nsz` before import. Without the module, `nsz_command` probes `nsz` and `nsz-cli-macos-arm64` on the build's PATH and passes `--keys` to the first whose successful help lists that option. An unsupported or failed candidate does not hide the next one; when none works, the error lists the reasons and installation options. Executable, input and output paths are absolute because conversion changes directories. The temporary folder and link are removed on success or failure; the user's default keys are untouched.
- **Found on:** [Super Mario Odyssey](../../dm/games/0100000000010000/README.md), converting its v0 NSZ. Applies to NSZ and XCZ inputs for every game. Synthetic tests during [PR #327](https://github.com/seedds/nxnative/pull/327) also reproduce an older console script hiding the release binary, a failed help probe containing `--keys`, and a relative PATH executable failing after the directory change; no game files are needed for those cases.

### ZBIC-compressed NSO segments

- **Symptom:** the NSP script or any module tool stops on `main`: `compressed with zstd (NSO flag bit 7), which this loader does not decode yet`; with the decoder but without its package, `ZBIC (zstd) segments need the zbic package (python3 -m pip install zbic)`.
- **Cause:** from system 22.0.0, an NSO may store its segments as **ZBIC**, NSO flag bit 7 for the whole module (the per-segment compression and check-hash bits keep their meaning). ZBIC is Nintendo's variant of zstd, not a container around standard frames: its frames start with the magic `ZBIC` and its FSE tables are written with binary interpolative coding, so neither `compression.zstd` nor the `zstd` command can read them.
- **Fix:** `dm/tools/nso.py` decodes such segments with the [`zbic`](https://pypi.org/project/zbic/) package (Kinnay's, zstd with Atmosphère's ZBIC changes), imported only for a flag-bit-7 module, so an LZ4 title needs nothing new; every segment is still held to the header's size and SHA-256. zstd has no fixed ratio bound, so a ZBIC segment is held only to its own size, where an LZ4 one is also held to 255 bytes per stored byte. Install it with the other tools (README, step 1).
- **Check:** Well Dweller's `main` decodes to 85,370,056 bytes with segments `0x39680d0 / 0x9f7e74 / 0x9b1930`, every SHA-256 matching; `dm/tools/tests/test_nso.py` checks that a flag-bit-7 module whose segments are not ZBIC is an Error naming ZBIC.
- **Found on:** [Well Dweller](../../dm/games/0100217023F6C000/README.md) (SDK 22.2.0).

## Package identification

### An NSP without a ticket or a title ID in its name stops with "no NSP with a readable title ID"

- **Symptom:** `[RED] no NSP with a readable title ID in <folder>`, although the keys open the package (the launcher's key check passes). Renaming the file to `Game [0100XXXXXXXXXXXX].nsp` makes the build go on.
- **Cause:** `title_of` took the title ID only from the ticket's file name (`<rights ID>.tik`) or from a `[title ID]` tag in the package's file name. Many NSPs carry no ticket (standard-crypto dumps, repacks), and a download's file name often has no tag.
- **Fix:** with neither, `title_of` asks the package: `nx_extract <prod.keys> --title <package>` opens it, decrypts the header of each meta NCA with the keys' `header_key` and prints the lowest title ID (the base game's before its update's or a DLC's). It works for NSP, NSZ (the meta NCA is not compressed), XCI and XCZ, and runs only when the ticket and the tag are both missing, so the common cases stay a read of the file name table. `nx_extract` is built into a temporary folder for it, since the build folder is named after the title ID. Key values are never printed.
- **Found on:** NX2Apple, [LNPANDY/NX2Apple#177](https://github.com/LNPANDY/NX2Apple/issues/177) ([Tears of the Kingdom](../../dm/games/0100F2C0115B6000/README.md), whose base NSP has no ticket). Applies to every game.

## Cartridge dumps

### A cartridge dump with its update on it extracts the update as the base game

- **Symptom:** the extraction of a game whose base is an XCI that also carries its update (a "1G+1U" dump) stops with `[RED] nx_extract exit code -6`. `extract_v<version>.log` lists the update's build IDs even for the base game alone, then ends in an unhandled exception from the RomFS (`ResultFsNonRealDataVerificationFailed (2002-4604): Hash error!` from `RomFsFileSystem..ctor`, or `ArgumentException` / `InvalidOperationException` from the patch layers).
- **Cause:** the XCI's secure partition holds the update's NCAs beside the base game's, and the update's Program NCA has the program's title ID too. `nx_extract` took the first Program NCA of the lowest title ID as the base, which is the update's when the dump lists it first. Its data section is a patch (BKTR) over the base RomFS, so it cannot be read alone or under another patch. The ExeFS still opens, with the update's build IDs, because an update's code section is complete. The Control NCA (display version, icon) was also whichever of the two came last.
- **Fix:** `dm/tools/nx_extract/Program.cs` `OpenNsp` reads the base package's content metas (`*.cnmt` in its Meta NCAs) and keeps only the NCAs that its Application content meta lists, and prints how many it left out. When none of them is a Program NCA (NCA files renamed, so their names are not content IDs), it prints a `[RED]` line and reads every NCA as before. An NSP or a base-only XCI keeps every NCA but its meta NCA, so it extracts as before (Balatro's NSPs and Monster Hunter Rise's XCI give identical manifests). The update is still taken from the update NSP in the folder; the one on the cartridge is not used, so an XCI alone packs the base game's version.
- **Found on:** [The Legend of Zelda: Tears of the Kingdom](../../dm/games/0100F2C0115B6000/README.md), a 1G+1U XCI (base v0 with update 1.4.3, whose 524 MB Program NCA is listed before the base's 17.1 GB one) beside the 1.4.3 update NSP ([PR #311](https://github.com/seedds/nxnative/pull/311)). Reproduced with a package of Balatro's update NSP followed by its base NSP: the base alone and the base with the update now give the same manifests and control data as the separate NSPs. Applies to any game's XCI that carries its update.

## Sparse base games

### The survey's build ID lookup stops on the base game alone with a hash error

- **Symptom:** for a game with no profile, the NSP script stops at `build ID lookup · main of the base game` with `[RED] nx_extract exit code -6`; `<title ID>_survey/logs/exefs.log` ends in `ResultFsNonRealDataVerificationFailed (2002-4604): Hash error!` from `PartitionFileSystemMetaCore.QueryMetaDataSize` under `Nca.OpenFileSystem`, although every NCA in both NSPs matches its content ID (the SHA-256 that names it) and the base game with its update extracts cleanly.
- **Cause:** the base game's Program NCA is sparse: its code and data sections carry a sparse layer and leave out data that the update supplies, so the base is smaller than its update (1.6 GB against 2.9 GB). Horizon mounts such an NCA only through its patch; read alone, the left-out ranges fail the hash check from the first block of the ExeFS. The lookup (`same_build`) tries main's build ID of the newest update first, then of the base game alone, and `run` stopped the build on the second attempt's failure.
- **Fix:** `dm/tools/nx_extract/Program.cs` stops with exit code 4 and `[RED] the base game's program is sparse: it can be read only with its update NSP` when it is given a sparse base without an update (any enabled section of the Program NCA with a sparse layer). `scripts/build_ipa_from_nsp.py` `run` takes the exit codes a caller accepts (`ok`), and `same_build` accepts 4: the base game alone then has no main of its own and the lookup goes on. The base game with its update reads as before (LibHac layers the update over the sparse base; the whole 4.2 GB merged RomFS of the game below reads with every hash check on).
- **Found on:** Minecraft Dungeons II (`0100A7C01B792000`, no profile yet), base v0 (SDK 22.2.0) with update v131072 (1.1.3.0). Applies to any game whose base Program NCA is sparse.
