# Services and SDK calls

SDK calls and system services the host answers (`dm/host/hle_*.c`). Each entry: symptom, cause, fix, the games it was found on. The [symptom index](../agents/symptoms.md) lists every symptom.

## Service connections

### SDK calls that open a system service through sm

- **Symptom:** `sm::Initialize` aborts right after `ConnectToNamedPort` (SVC 0x1F) and `SendSyncRequest` (0x21); abort inside `nn::sm::Initialize`, the log showing `SVC 0x1f` (ConnectToNamedPort, port name `sm:`) and `SVC 0x21` answered by placeholders, then an `nn::diag` abort; abort with no message at start-up in a service call the host has no hook for (`Break` from `sdk+…` with an `nn::diag` backtrace).
- **Cause:** an SDK path reached a system service the host doesn't replace: the SDK's IPC to the service fails and it calls `AbortImpl`. Often it is an SDK call the host does not hook, for example a newer overload of a hooked call.
- **Fix:** hook the public SDK entry point named in the backtrace (`HLE_FORCE` in the relevant `hle_*.c`). Symbolize the abort backtrace against the SDK's exports to find the caller (resolve the frames with `sdis.py --sym` on the decompressed module) and hook that name. List the game's imports of that service the host does not hook ([Listing a game's unhooked imports before they are met](#listing-a-games-unhooked-imports-before-they-are-met)) and add the ones that talk to a service; library helpers that only fill the game's own buffers need nothing. Look at how the game uses the result before choosing it (a `bcat` mount failure is the game's own "nothing delivered" path).
- **Found on:** [Super Mario Galaxy](../../dm/games/010099C022B96000/README.md) (SDK 18): `nn::hid::InitializeTouchScreen(int, int)`, the SDK 18 overload of the hooked `InitializeTouchScreen()`; [Super Mario Odyssey](../../dm/games/0100000000010000/README.md) (SDK 7): `account::OpenPreselectedUser`, then `bcat::Initialize`, then `audio::AcquireAudioDeviceSwitchNotification`, and a null read in `account::GetLastOpenedUser`.
- **Note:** the same abort from other services: `ec::InitializeForShopServiceAccessors` ([Shop service accessors](#shop-service-accessors)), `pctl::IsFreeCommunicationAvailable` ([Parental controls and free communication](#parental-controls-and-free-communication)), `oe::FinishStartupLogo` ([The startup logo](#the-startup-logo)), `hid::VibrationNode::Update` ([Vibration values flushed by the SDK's vibration graph](#vibration-values-flushed-by-the-sdks-vibration-graph)), `audio::GetAudioDeviceOutputVolume` ([Audio device output volume and names](audio.md#audio-device-output-volume-and-names)), `capsrv::InitializeForApplication` ([Album calls fail with no album](#album-calls-fail-with-no-album)), `settings::LanguageCode` ([Language codes](#language-codes)), and the rest of this file.

### SDK 3.6.0 answered as SDK 4

- SDK 3.6.0 booted to its frame loop with the provisional profile as generated and no host change: the services, the NVN API version (53, as for every SDK up to 10), the audio output and the heap all answered as for SDK 4.
- **Found on:** [Bayonetta 2](../../dm/games/01007960049A0000/README.md) (PlatinumGames' engine in its Wii U form): what it needed was graphics ([Clears of attachments larger than the render pass](rendering.md#clears-of-attachments-larger-than-the-render-pass), [`Downsample` of a single-sample texture](rendering.md#downsample-of-a-single-sample-texture)) and a reader for its CRI CPK archives ([BNSH files in PlatinumGames DAT archives inside CRI CPK archives](shaders.md#bnsh-files-in-platinumgames-dat-archives-inside-cri-cpk-archives)); [Bayonetta](../../dm/games/010076F0049A2000/README.md), on the same `sdk` and `subsdk0` builds, then needed no change at all (its profile is Bayonetta 2's with its own build row and tables, and the route from the boot to the first fight logged no red line). [OCTOPATH TRAVELER](../../dm/games/010057D006492000/README.md)'s SDK 3.5.1 answered as SDK 4 as well (NVN 53.313); its audio renderer needed the update lock found without `SdkMutexType` ([No `SdkMutexType` in SDK 3](audio.md#no-sdkmutextype-in-sdk-3)).

### Listing a game's unhooked imports before they are met

Most service calls can be found before they crash, before the first boot or the next one: the calls that would abort in `sm::Initialize` (or read a null service object) are in the import list.

- **Procedure:** list `main`'s `nn::` imports (its undefined imports) that no host hook names, by namespace: the survey's import table (`nso_syms.py`), then `main`'s undefined `nn::` symbols that no hook (`HLE` / `HLE_FORCE`) names ([02](../agents/02-survey.md#imports-vs-host-hooks)), and read each one's SDK code. This gives the calls a game will make before they are met. The import list itself says where to look: diff the undefined symbols against the closest title the host already runs (and every other game's imports), drop what the host hooks, and the rest are the candidates. To find which `sdk` function aborted, map the backtrace offsets to the nearest exported symbol ([The Legend of Zelda: Tears of the Kingdom](../../dm/games/0100F2C0115B6000/README.md) 1.4.3).
- **What needs nothing:** most `nn::os` / `nn::mem` imports run natively in `sdk`. Calls that are pure computations need nothing, nor do socket calls behind a `Socket()` that already fails offline, nor library helpers that only fill the game's own structures.
- **Hook names:** hooks are `HLE_FORCE`, `SSF`, `SKF`, `IKB_IGNORE` across `dm/host` and `dm/gfx`. `strings` misses names the symbol table stores as the tail of a longer one, so list them with `nso_syms.dynsyms`.
- **The survey table's blind spots:** it counts only names given to `HLE` / `HLE_FORCE` directly: hooks made through macros (`SKF` and `SSF` in `hle_net.c`, `TOUCH(N)` in `hle_hid.c`) show as missing. The touch-screen states (`GetTouchScreenState<16>`) were already hooked by such a macro, which the import table does not see. It once listed every vi call as unhooked: `nso_syms.py host_hooks` read only `dm/host`, and the vi hooks are in `dm/gfx` (it reads `dm/gfx` and `dm/gfx/nvn` now; found on [Absolum](../../dm/games/0100A83022A22000/README.md)).
- **What it found** (the calls themselves are in the entries of their service below):
  - [Pokémon Sword](../../dm/games/0100ABF008968000/README.md) (SDK 7, one boot each): the import list against the hooks and every other game's imports named all of them beforehand: 33 `nn::` imports no host hook names and no other game imports.
  - [13 Sentinels: Aegis Rim](../../dm/games/01003FC01670C000/README.md) (SDK 11).
  - [Monster Hunter Rise](../../dm/games/0100B04011742000/README.md) (SDK 11, one boot each): the import list against the hooks and the other SDK 11 games found most of them before the first boot.
  - [DRAGON QUEST XI S](../../dm/games/01006C300E9F0000/README.md).
  - [Octopath Traveler 0](../../dm/games/01005270232F2000/README.md): the pure computations were the swkbd presets, the web argument constructors, `time::GetDayOfWeek` and the audio resampler.
  - [DRAGON QUEST VII Reimagined](../../dm/games/0100A9D01C446000/README.md) (SDK 19.3.1): the import list against the hooks gave the rest before they were met; the rest fill the game's own structures or sit behind a socket that fails offline.
  - [Pokémon Legends: Z-A](../../dm/games/0100F43008C44000/README.md) (19.3.11): the import list against the hooks (the survey's `nso_syms.py` table, then `main`'s undefined `nn::` symbols that no `HLE_FORCE` names) left 86 candidates; most only fill the game's own structures (error and web argument builders, `prepo` report buffers, `swkbd` configuration, the audio resampler, `nn::async`). The ones that reach a service were hooked before they were met where the answer is clear: `time::ToPosixTime` with an explicit rule, `album::SaveCurrentScreenshot`, `err::ShowApplicationError` and the `ShowShopAddOnContentList(UserHandle)` overload.
  - [STEINS;GATE RE:BOOT](../../dm/games/01008BC024FDE000/README.md) (SDK 20.5.17): `nn::audio::SetAudioOutVolume` ([AudioOut volume kept per output](audio.md#audioout-volume-kept-per-output)) was among `main`'s imports that no host hook names; the others there fill the game's own structures or run in `sdk` (the CPU audio renderer, the swkbd and hid argument builders).
  - [Paper Mario: The Thousand-Year Door](../../dm/games/0100ECD018EBE000/README.md) (SDK 15.3.2): `nn::settings::GetAvailableLanguageCodes` was the one import of `main` that no host hook names and that reaches a service; `fs::MountRamDisk` and the swkbd and hid helpers it also imports run in `sdk` or were never called.
  - [Catherine: Full Body](../../dm/games/0100BF00112C0000/README.md) (SDK 8.2.1): besides `GetAvailableLanguageCodeCount`, the other imports no hook names run in `sdk` (the `LanguageCode` comparison, `ClockSnapshot`'s constructor and getters, fibers, `NumberLineAllocator`).
  - [Animal Crossing: New Horizons](../../dm/games/01006F8002326000/README.md) (SDK 20.5.4): the clock, region and album calls under their own entries below were found in `main`'s imports before the first boot.
  - [The Great Ace Attorney Chronicles](../../dm/games/010036E00FB20000/README.md) (SDK 10.4.1): listed after its first boot crashed in `oe::DisableAlbumImageTakenNotification`; the calls found are in the entries under `## Display, window and operation mode`, `## File system and save data` and `## Accounts, network, shop and parental controls`.
  - [Big Brain Academy: Brain vs. Brain](../../dm/games/0100620012D6E000/README.md) (SDK 11.4.3).

### A game update imports SDK calls the base game did not

- **Symptom:** a game update aborts at boot where the base game ran.
- **Cause:** the update imports SDK functions the base game didn't. Mario 1.2.1 added 28, among them `nn::nfp` (amiibo, initialized at boot), `pl::IsRunningOnOunce` (is this a Switch 2), `ec::ShowShopApplicationInformationForUpgrade`, `account::PopOpenUsers` and `aoc::CountAddOnContent`.
- **Fix:** diff the undefined dynamic symbols of the two `main` modules before the first run, and read the call sites before choosing answers: Mario only reads the count from `PopOpenUsers` and falls back to `TryOpenPreselectedUser` on 0, and only counts add-on content when running on a Switch 2. The host answers as a Switch 1 with no amiibo and no add-on content (`hle_sdk16.c`, `hle_account.c`, `hle_misc.c`).
- **Found on:** [Super Mario Bros. Wonder](../../dm/games/010015100B514000/README.md) (update 1.2.1).

### Game-linked HIPC clients of system services

- **Symptom:** abort in `sm::Initialize` under `sf::hipc::InitializeHipcServiceResolution`, right after the first frames (from `main+0x5b8198`).
- **Cause:** `main` links its own clients of `olsc:u` (cloud save data backup settings) and `npns` (push notifications), which talk HIPC through `sm` and `svcSendSyncRequest`. For each user the game asks whether backup is on and switches it off where it is (`main+0x2809c8c`); a failed connect aborts as well.
- **Fix:** `hle_sf.c` takes over the SDK's HIPC client entry points (`InitializeHipcServiceResolution`, `ConnectToHipcService`, `SendSyncRequest`, `CloseClientSessionHandle` and the control requests `QueryPointerBufferSize`, `ConvertSessionToDomain`, `DuplicateSession(Ex)`): a service it serves (`olsc:u`) gets a host session, and every request on it succeeds with zeroed output, which reads as backup off for every user. Any other name is refused with a red line, as `sm` refuses a service nobody registered (`npns` was never connected). `DM_SF_TRACE=1` dumps each request.
- **Found on:** [Animal Crossing: New Horizons](../../dm/games/01006F8002326000/README.md) (SDK 20.5.4).

## SDK names that changed between versions

### Older SDK names for the same calls

- **Symptom:** a call the host hooks under its newer name reaches the SDK's own code on an older game.
- **Cause:** older SDKs export other names for the same calls.
- **Fix:** hook both generations. SDK 12 names: `ListAudioDeviceName` / `GetActiveAudioDeviceName`, singular `hid::GetNpadState`, `OpenDefaultAudioOut`. SDK 11 names: `fs::CommitSaveData(mount)` is the older name of `fs::Commit`.
- **Found on:** [Metroid Dread](../../dm/games/010093801237C000/README.md) (SDK 11 names).
- **Note:** overloads change too: SDK 18's `nn::hid::InitializeTouchScreen(int, int)` ([Super Mario Galaxy](../../dm/games/010099C022B96000/README.md), [SDK calls that open a system service through sm](#sdk-calls-that-open-a-system-service-through-sm)), SDK 19's `LoadModule` with one more bool ([`nn::ro` and its port](#nnro-and-its-port)), and `vi::CreateLayer` with the layer's size ([Absolum](../../dm/games/0100A83022A22000/README.md), [`vi::CreateLayer` with the layer's size](#vicreatelayer-with-the-layers-size)).

### SDK 4's `friends::GetBlockedUserList` without a `Uid`

- **Symptom:** abort in `sm::Initialize` under `nn::friends::GetBlockedUserList` after the opening movie.
- **Cause:** SDK 4's overload without the `Uid` (`EPiPNS_7account23NetworkServiceAccountIdEii`), which the host did not take over.
- **Fix:** it reports an empty list with success: the game turns a failure into an error for the error applet (`main+0x8ff9f0`). The overload with a `Uid` keeps reporting a failure, which [DRAGON QUEST XI S](../../dm/games/01006C300E9F0000/README.md) takes as it is ([Account, friends, play data and Nintendo Account calls](#account-friends-play-data-and-nintendo-account-calls)).
- **Found on:** [DARK SOULS: REMASTERED](../../dm/games/01004AB00A260000/README.md) (SDK 4.5.0, the oldest so far; one boot).

### SDK 6's `account::OpenPreselectedUser` returns a Result

- **Symptom:** the first loading screen never ends; `DM_FS=1` shows `save:/system` "not found" and no `fs mount save`.
- **Cause:** in SDK 6 `account::OpenPreselectedUser` returns a Result, and the game skips its save mount when it is not 0 (`main+0x53b7e0`). The host's hook returned void and left the handle pointer in w0.
- **Fix:** the hook returns 0 now; SDK 7 and later callers ignore it.
- **Found on:** [Fire Emblem: Three Houses](../../dm/games/010055D009F78000/README.md) (SDK 6.5.0).

## File system and save data

### The SDK's own `fs::IsMounted` reads an empty mount table

- **Symptom:** IL2CPP "Could not open …/global-metadata.dat" (then a crash in its logger).
- **Cause:** IL2CPP checks `nn::fs::IsMounted("rom")` before opening; the SDK's own `IsMounted` reads a mount table the host never fills.
- **Fix:** answer from the host's mount table (`hle_fs.c`).
- **Note:** the C library's path checks read the same empty table through `IsPathMounted` ([C library path checks ask the file system's limits](#c-library-path-checks-ask-the-file-systems-limits)).

### File handles with low bits set, and backslash paths

- **Symptom:** a 10-byte read of the wrong RomFS file, then a null pointer at boot; files named `rom:\StartupUI.pak` are not found.
- **Cause:** on Horizon a `FileHandle` is a pointer to the SDK's `FileAccessor`, a heap object, so its low bits are clear, and a game's file device may mask them off (`handle & ~7`) before `ReadFile`. The host's RomFS-image handle kept the entry index in its low bits, so entry 7 was read as entry 0. Separately, Horizon's file system accessor turns every backslash in a path into a slash before it normalizes the path (`FileSystemAccessor::SetUpPath`, on every mount except the PC host's); the host treated a backslash as part of a name.
- **Fix:** the guest gets the host's handle shifted left by 4, 16-byte aligned like an AArch64 heap block (`FH_OUT` / `FH_IN`). Each guest path resolver (`img_path`, `host_path_ex`, `set_guest_name`, `dir_snapshot`) turns backslashes into slashes first, so overlays, `..` and guest names see the same path (`hle_fs.c`; `dm/host/tests/t_fs.c`).
- **Found on:** Metroid Prime 4: Beyond (SDK 19; bring-up in [issue #229](https://github.com/seedds/nxnative/issues/229), from [PR #513](https://github.com/seedds/nxnative/pull/513)); not in the games table yet.

### C library path checks ask the file system's limits

- **Symptom:** Addressables never start (no `StreamingAssets/aa/settings.json` in the `DM_FS=1` output at all), then a null asset crash (`main+0x31100ec`).
- **Cause:** Unity 2022's C# file API reaches the SDK's C library, not `nn::fs`: `File.Exists` → `SystemNative_Stat` → `stat` = `open` + `fstat` + `close` (`sdk+0x948b0`). nnmusl's path check (`sdk+0x904e0`, then the converter `sdk+0x8ef50`) asks `nn::fs::IsPathMounted`, `GetPathLengthMax`, `GetUtf16PathLengthMax`, `GetEntryNameLengthMax` and `GetUtf16EntryNameLengthMax` before it calls `nn::fs::GetEntryType` / `OpenFile`, and the SDK's own versions read the empty mount table (`IsPathMounted` false; the next one aborted with Result 0x35f202).
- **Fix:** the host answers them from its mount table, with Horizon's 0x300-byte limits and no UTF-16 limit (`hle_fs.c`). The path .NET builds is `/rom:/…`; nnmusl's converter turns it back into `rom:/…`.
- **Found on:** [Ace Attorney Investigations Collection](../../dm/games/010005501E68C000/README.md) (1.0.0.2, SDK 17.5.3, Unity 2022.3 IL2CPP).
- **Note:** armyja's fork (GitHub issue #18) patched the managed stat wrappers by address instead; these hooks need no per-build table.

### Paths with `.` and `..` components

- **Symptom:** an Atk task aborts in a `switch` default (`UnexpectedDefaultImpl`, then `AbortImpl`) while a stream sound loads.
- **Cause:** the stream path was `rom:/system/snd/../../sounds/streams/…`, and the host answered "not found" for any `..` component. Horizon's path normalizer resolves `.` and `..` lexically and fails only above the mount root.
- **Fix:** `host_path_ex` now does the same (`norm_rest` in `hle_fs.c`).
- **Found on:** [Metroid Dread](../../dm/games/010093801237C000/README.md) (`main+0x1225a8c`).

### RomFS lookups on large directories

- **Symptom:** a long black screen at boot with nothing in the log (Engage: about 17 s on the Mac, 32 s on an iPhone); sampling the process (`sample <pid> 3`) shows `getxattr` under `path_component` at the top of stack.
- **Cause:** the game is walking RomFS, and every path component scanned its whole parent directory. That scan maps the game's case-sensitive names onto APFS, so it calls `getxattr` on each entry, and Engage has directories of 38,000 files. The rest of the time was the listing itself: `ReadDirectory` called `stat`, `getxattr` and a failing `fopen("<file>.holes")` for every entry.
- **Fix:** read-only mounts now use a per-directory name index built at the first lookup (`dir_index_get` in `hle_fs.c`), which also speeds up every file Wwise opens during play. In listings, now only `.dm-case-*` names (the only ones that carry the xattr) read it, directories take their type from `d_type`, and files use `fstatat` / `openat` relative to the directory.
- **Found on:** [Fire Emblem Engage](../../dm/games/0100A6301214E000/README.md): with the name index the first frame came at 5.7 s on the Mac; with the listing fix too it comes at 1.8 s on the Mac (9.9 s → expected about 3 s on an iPhone), and the opening movie starts at 7 s instead of 49 s.

### ReadFile into write-protected texture pool pages

- **Symptom:** `[RED] fs ReadFile into … failed at +0 (EFAULT): VM region … protection 1`, now and then.
- **Cause:** the destination was texture pool memory, which the dirty-page tracker write-protects after each upload (`nvn_dirty.c`). `ReadFile` lifts the protection first (`dm_guest_write_prepare`), but the graphics layer can protect the pages again before `pread` writes them, and a system call gets EFAULT where a plain write would fault into the tracker's handler; at 60 fps uploads come twice as often.
- **Fix:** on EFAULT the host now prepares the rest of the buffer again (unprotect, mark dirty, so the texture is uploaded again) and reads on, up to eight times (`h_fs_ReadFile`; the first case is logged, `[fs] ReadFile … prepared again`).
- **Found on:** [Monster Train 2](../../dm/games/010051701FB46000/README.md) at 60 fps: two runs in three as the route map loads, never at 30 fps.
- **Check:** four runs at 60 fps: one retry, no failed read.

### File-not-found noise from optional paths

- **Symptom:** `fs … not found` lines with `DM_FS=1`.
- **Cause:** games probe many optional paths (debug parameters, other-language voice files).
- **Note:** only a missing file followed by a failure matters.
- **Found on:** every game (general).

### Directory, file data cache and save-thumbnail calls

- **Symptom:** a missing `fs::DeleteDirectory`; undefined `nn::fs::` / `nn::account::` imports with no hook, found from the import list ([Listing a game's unhooked imports before they are met](#listing-a-games-unhooked-imports-before-they-are-met)) before they were met.
- **Fix:** hooked: `fs::DeleteDirectory` (an empty directory), `fs::CleanDirectoryRecursively`, `fs::RenameDirectory` (done as `RenameFile`); `fs::EnableGlobalFileDataCache`, `fs::DisableGlobalFileDataCache`, `fs::EnableIndividualFileDataCache` / `DisableIndividualFileDataCache`; `account::StoreSaveDataThumbnailImage` / `DeleteSaveDataThumbnailImage` (nothing kept) (`hle_fs.c`, `hle_account.c`).
- **Found on:** [Metroid Dread](../../dm/games/010093801237C000/README.md) (SDK 11: `fs::DeleteDirectory` was missing); [13 Sentinels: Aegis Rim](../../dm/games/01003FC01670C000/README.md) (SDK 11: `CleanDirectoryRecursively`, `EnableGlobalFileDataCache`); [DRAGON QUEST XI S](../../dm/games/01006C300E9F0000/README.md) (SDK 7.3.2: `DisableGlobalFileDataCache`); [The Great Ace Attorney Chronicles](../../dm/games/010036E00FB20000/README.md) (SDK 10.4.1: `RenameDirectory`, the thumbnail calls), [Big Brain Academy: Brain vs. Brain](../../dm/games/0100620012D6E000/README.md) (SDK 11.4.3: the individual file data cache).

### `fs::Commit` with a list of mounts

- **Symptom:** the SDK's own code opened fsp-srv and aborted, leaving the save writes uncommitted.
- **Cause:** `fs::Commit(const char* const*, int)`, the mount-list overload, had no hook.
- **Fix:** the host commits the list as one transaction when every name is the same host save; cache and temporary storage in the list are skipped (their writes are already on disk, as for the single-name `Commit`), and a list of two separate saves is refused without committing either.
- **Found on:** [Animal Crossing: New Horizons](../../dm/games/01006F8002326000/README.md) (PR #25).
- **Note:** SDK 11's `fs::CommitSaveData(mount)` is the older name of `fs::Commit` ([Older SDK names for the same calls](#older-sdk-names-for-the-same-calls)); `fs::Commit` with a `CommitOption` is under [Device save data on the account save's directory](#device-save-data-on-the-account-saves-directory).

### Save-write failures stay with their backing transaction

- **Symptom:** a failed write in one independent save can make another save's next `Commit` fail and discard its successful changes; the damaged save may then commit its truncated working file.
- **Cause:** the host used one process-wide failure marker, consumed by whichever save committed first.
- **Fix:** each canonical backing save owns its failure state. Open file handles retain that transaction identity, aliases share it, and each commit waits for in-flight writes or size changes to its backing save before consuming or restoring its failure marker (`hle_fs.c`). Concurrent first writes initialize the shared failure-injection settings with `pthread_once`.
- **Check:** `t_fs_commit_list` injects write failures after truncation in either of two independent saves, verifies that the other save commits its changes, and checks failure propagation through aliases, rename failure handling, and a failed recovery clone. It blocks writes and size changes through an alias while another save commits, then verifies that both Commit ABIs wait for the affected I/O and refuse its failure. `make -C dm/host/tests GAME=<title ID> fs-tsan` also checks concurrent first writes and failed file I/O concurrent with mounting another alias.
- **Found on:** the [two-save host regression](../../dm/host/tests/t_fs_commit_list.c). [Mario Kart 8 Deluxe](../../dm/games/0100152000022000/README.md) uses independent device and account saves.

### Save data size queries

- **Symptom:** SIGSEGV at address 0 in `nn::fs::GetSaveDataSizeMax`, about 13 minutes into a new game.
- **Cause:** Unreal's save system asks before its first save; the SDK's version reads the fsp-srv object the host never made.
- **Fix:** it reports 256 MB of data and journal, as `GetSaveDataSize` does (`hle_fs.c`). `fs::GetCacheStorageSize` and `fs::GetFreeSpaceSize` give the same answers. Also hooked: `fs::GetSaveDataSize` / `ExtendSaveData` and the one-argument `fs::MountCacheStorage`.
- **Found on:** [Octopath Traveler 0](../../dm/games/01005270232F2000/README.md) (`GetSaveDataSizeMax`, `GetCacheStorageSize`, `GetFreeSpaceSize`, found by the import list); [Monster Hunter Rise](../../dm/games/0100B04011742000/README.md) (SDK 11: `GetSaveDataSize`, `ExtendSaveData`, `MountCacheStorage`).

### Cache storage and other titles' save data

- **Symptom:** each aborted in `sm::Initialize` or read a null applet proxy, one per boot.
- **Cause:** SDK 20 file system calls that reach a service.
- **Fix:** cache storage: `OpenCacheStorageList` / `ReadCacheStorageList` report none, `CreateCacheStorage` / `MountCacheStorage` use a host folder beside the temporary storage. `fs::IsSaveDataExisting(ApplicationId, Uid)` for another title (it asks for Breath of the Wild's save: none) and `MountSaveDataReadOnly`.
- **Found on:** [The Legend of Zelda: Tears of the Kingdom](../../dm/games/0100F2C0115B6000/README.md) (1.4.3, the same `sdk` build as Breath of the Wild 1.9.0).

### Device save data on the account save's directory

- **Symptom:** the island lives in device save data, which the host did not mount.
- **Cause:** 3.0.3's `main` mounts no account save data; the island is in device save data (`MountDeviceSaveData`, `GetDeviceSaveDataSize`, `ExtendDeviceSaveData`).
- **Fix:** the host gives device save data the account save's host directory and transaction (one player). A second mount name over a save already mounted now shares that mount's transaction (`mount_ex`); it used to clone the committed directory again, over the first name's pending writes. Also `fs::Commit` with a `CommitOption` (its one flag clears the restore flag) and `GetSaveDataRestoreFlag` (never restored from a backup).
- **Found on:** [Animal Crossing: New Horizons](../../dm/games/01006F8002326000/README.md) (3.0.3, SDK 20.5.4).
- **Note:** a game whose `main` imports `MountSaveData` too gets its device save as a save of its own ([Device and account save data as two saves](#device-and-account-save-data-as-two-saves)).

### Device and account save data as two saves

- **Symptom:** every boot asks to pick a Mii again (`DM_FS=1`: `UserSave:/userdata.dat` not found although the host save has it).
- **Cause:** the game mounts `CommonSave` with `MountDeviceSaveData` and `UserSave` with `MountSaveData(uid)` (`main+0x8b0c84`), two saves on Horizon; the host made device save data the account save (for Animal Crossing: New Horizons, which mounts only device save data), so both names shared one directory. At boot the save manager deletes `CommonSave:/userdata.dat` (`main+0x8b1910`, through its file device's `DeleteFile`, `main+0x633afc`; a probe there with `@*x1+8` shows the name) and commits, and in the shared directory that was the account save's own file.
- **Fix:** a game whose `main` imports `MountSaveData` too gets its device save as `<DM_SAVE>_device`, a transaction of its own (`hle_fs.c`); of the games on hand only this one imports both, so Animal Crossing's islands stay where they are.
- **Found on:** [Mario Kart 8 Deluxe](../../dm/games/0100152000022000/README.md) (4.0.0, SDK 4.4.0; one boot).

### System data stand-in for the MiiModel archive

- **Symptom:** abort in `fs::detail::GetFileSystemProxyServiceObject` under `fs::QueryMountSystemDataCacheSize` (`main+0x8f23bc`).
- **Cause:** the game mounts system data 0100000000000802, MiiModel, as `MiiResource:` and reads `NXTexture{Low,Mid}{Linear,SRGB}.dat` and `Shape{Mid,High}.dat` whole; the SDK's Mii rendering is linked into `main` (`main+0x8f1400`–`+0x8fc000`).
- **Fix:** firmware content is not the host's to ship, so the host writes a stand-in of the same layout with every part empty (`dm_mii_standin` in `hle_mii.c`, mounted by `hle_fs.c` `MountSystemData`; any other system data answers "target not found"). Heads build and draw nothing; bodies and favourite colours show.
- **Found on:** [Mario Kart 8 Deluxe](../../dm/games/0100152000022000/README.md) (4.0.0, SDK 4.4.0; one boot).
- **Note:** the layout as the code reads it: texture file +0xc the largest decompressed size of each of 11 part kinds, +0x38 their alignments, from +0x64 one 0x1c-byte entry per part (offset, size, stored size, 4 zlib parameters, then width, height, format, mips); shape file +0xc / +0x3c the same for 12 kinds, from +0x6c one 0x58-byte entry per part (offset, size, stored size, parameters, five vertex attribute offsets and sizes, index offset and byte size, bounding box), then hair (132 × 0x48, +0x12704) and faceline (12 × 0x24, +0x14c24) transforms. A texture of size 0 is skipped (`main+0x8faaf4`); shapes cannot all be absent, because the faceline is drawn without a check (a null buffer read at `main+0xa690d0` under `main+0x8286c4`), so every shape entry points at one shared mesh of one vertex and the triangle (0, 0, 0), 32 bytes of zeros in a stored zlib block. The largest sizes must not be 0: they size the model's memory pool (`main+0x8f2e6c`), whose alignment is the first one. The Mii database itself: [Mii database answered by the host](#mii-database-answered-by-the-host).

## Add-on content

### Add-on content from `DM_AOC_DIR`

- **Symptom:** DLC the player owns is not unlocked.
- **Fix:** the host reports add-on content from `DM_AOC_DIR`, one numbered folder per DLC index (title ID − base − 0x1000) holding that DLC's RomFS. `build_ipa_from_nsp.py` extracts the DLC NSPs in the folder with `nx_extract --aoc`, `build_ipa.sh` copies them to `<App>/aoc/`, and the app sets `DM_AOC_DIR`. `aoc::CountAddOnContent` / `ListAddOnContent` report those indices (`hle_misc.c`), and `fs::MountAddOnContent` mounts the folder read-only (`hle_fs.c`). D2R keeps its fixed `{1}` without `DM_AOC_DIR`; `DM_AOC_OWNED=0` reports none.
- **Found on:** [Fire Emblem Engage](../../dm/games/0100A6301214E000/README.md): its two DLC packages each hold one empty marker file (`e0`, `h0`), and the content is already in update 2.0.0. `DLCManager.RefreshHasList` marks a content owned when its mount succeeded (probe `main+0x29f3c88`).

### Owned add-on content lists beyond 64 entries

- **Symptom:** some owned DLC is missing, and `aoc: reporting` stops at 64 add-on contents.
- **Cause:** `hle_misc.c` stored only 64 indices and stopped reading `DM_AOC_DIR` when that array filled, before sorting. The omitted indices depended on directory order; its 256-byte log buffer also truncated longer lists.
- **Fix:** the shared array holds 2000 indices, covering the scanner's existing accepted range (1..2000), and a static buffer holds the complete index log without increasing guest-stack use. Folder and `.img` discovery, sorting, deduplication, pagination and `DM_AOC_OWNED=0` retain their behavior. This applies to every game using the add-on content hooks.
- **Open:** the existing 1..2000 acceptance range is retained; it is not established here as Horizon's full legal range. More than 2000 accepted folder/image entries can still fill the array before deduplication, even when their unique indices fit.
- **Found on:** [Super Smash Bros. Ultimate](../../dm/games/01006A800016E000/README.md) (13.0.5, 99 DLC licences; PR #441).

### Add-on content mount cache sized as RomFS working memory

- **Symptom:** SIGSEGV in `crypto::detail::CbcModeAes128Helper::DecryptBlocks` with a null destination (`main+0x8737e8`, right after `aoc:` is mounted).
- **Cause:** the add-on content (0100152000023001: `contents.dat` and `version.txt`, the courses are in the update) is decrypted in `AocHeap`, a 0x3130-byte heap that also holds the mount cache. The host answered `QueryMountAddOnContentCacheSize` with 4 KB, and the 0x1400-byte decryption buffer then did not fit.
- **Fix:** on Horizon the cache is the RomFS's file table as `RomFsFileSystem::GetRequiredWorkingMemorySize` sizes it: both hash tables (4 bytes a bucket, the builder's bucket count) and all directory and file entries (0x18 / 0x20 bytes plus the name, padded to 4), 0x88 bytes for these two files. The host computes that from the folder it mounts (`romfs_work_size` in `hle_fs.c`); `rom` keeps its minimum answer, which is too small rather than too large.
- **Found on:** [Mario Kart 8 Deluxe](../../dm/games/0100152000022000/README.md) (4.0.0, SDK 4.4.0; one boot).

### Add-on content queries on a small guest stack

- **Symptom:** SIGBUS in `__vfprintf` under `aoc_load`, from `h_aoc_Count` (a store to `0x…67ff0`, right below a page of the guest thread's stack).
- **Cause:** the first add-on content query lists `DM_AOC_DIR` and logs, a few KB of stack, and the game asks from a thread with little left.
- **Fix:** `aoc::CountAddOnContent` and `ListAddOnContent` run on the big host stack (`HLE_FORCE_BIG`, `hle_misc.c`).
- **Found on:** [Digimon Story Cyber Sleuth: Complete Edition](../../dm/games/010014E00DB56000/README.md) (SDK 6.4.0; one boot).

## Input

### Controller disconnect between style and player lookup

- **Symptom:** clang reports a negative shift in `fill` or `vib_targets` (`hle_hid.c`).
- **Cause:** a style check looked up the connected player, then input or vibration routing looked it up again. A disconnect between the reads made the second result -1, used in `1u << player`.
- **Fix:** look up the player once and derive the style from that same result before constructing the player mask.
- **Found on:** clang static analysis ([issue #424](https://github.com/seedds/nxnative/issues/424)); no gameplay failure reported.

### History reads fill every requested entry

- **Symptom:** buttons and menus work, the sticks do nothing in play (Super Mario Odyssey: its first hint, "Look Around", waited forever); an `nn::diag` abort with Result 0x2aca in the first frames of `nnMain` (Hollow Knight: Silksong, Unity 6000.0.50f1: `bt: sdk+0x514580 main+0x1296c64 …`).
- **Cause:** games read whole histories and ignore the returned count. Odyssey reads all 16 entries of `GetNpadStates`; the host filled only the newest. It polls every controller slot each frame, which moves the shared sampling number on by about 16, so the stick samples it combined were mostly empty, while buttons and the stick's direction bits (which menus use) still came through. Silksong's `main+0x1296c60` calls `hid::GetDebugPadStates(states, 16)` every frame, and the SDK's own reads a debug pad resource nothing initialized (module 202, hid); the host had only the single-state `GetDebugPadState`.
- **Fix:** the host now fills every requested `GetNpadStates` entry with the current state under consecutive sampling numbers; the `GetDebugPadStates` history form answers every requested entry as not connected, newest first with consecutive sampling numbers (`hle_hid.c`). `DM_KEYS` takes `RLeft` / `RUp` / `RRight` / `RDown` for the right stick.
- **Found on:** [Super Mario Odyssey](../../dm/games/0100000000010000/README.md); [Hollow Knight: Silksong](../../dm/games/010013C00E930000/README.md).
- **Note:** Odyssey's six-axis history is read the same way ([Six-axis sensors](#six-axis-sensors)).

### Npad style set update event

- **Symptom:** the game never reads the controller (the title's "Press L+R" never sees a press; no `GetNpadState` call at all).
- **Cause:** it waits for the event bound by `hid::BindNpadStyleSetUpdateEvent` before reading.
- **Fix:** the host now signals it once when it is bound for a connected controller, and again when a player's controller connects or goes away.
- **Found on:** [The Legend of Zelda: Link's Awakening](../../dm/games/01006BB00C6F0000/README.md) (SDK 8.2.0).

### Six-axis sensors

- **Symptom:** motion moves never happen; shaking does nothing (Super Mario Odyssey: cap throws by shaking).
- **Cause:** the host handed out six-axis handles but reported no sensor.
- **Fix:** it now reports one per connected controller: two for handheld or dual Joy-Cons, one otherwise, with the style, npad id and device in the handle. At rest the sensor lies flat: acceleration (0, 0, −1) G, no rotation, identity direction. Samples are 5 ms apart on the guest clock and numbered by time, so a history read returns the samples at those times. `DM_BTN_SHAKE` (`dm_input.h`: the iPhone shaken, Space on the Mac, `DM_KEYS` `Shake`) plays a side-to-side shake in whole cycles.
- **Found on:** [Super Mario Odyssey](../../dm/games/0100000000010000/README.md): it reads all 16 history entries per sensor and ignores the count, like its npad history ([History reads fill every requested entry](#history-reads-fill-every-requested-entry)).
- **Note:** find a game's swing detector by probing the accelerometer value it reads (`DM_PROBE=main:626248@x8+10` in Odyssey 1.4.1).

### Live controller motion

- **Symptom:** motion controls do nothing with a controller that has a gyroscope (Breath of the Wild: aiming with its Motion Controls option on); the six-axis sensor always lies flat.
- **Cause:** the host's six-axis sensor had no source of motion: flat at rest, apart from the `DM_BTN_SHAKE` shake ([Six-axis sensors](#six-axis-sensors)).
- **Fix:** a controller with a gyroscope drives its player's sensor on the Mac and iOS (`GCMotion`, `motion_apple.h` → `dm_motion_set`, `hle_hid.c`); on iOS the phone's own device motion drives player 1's while no controller supplies fresh motion (`DmGamepad.m`). The orientation is integrated from the gyro with tilt correction toward the measured gravity (`motion_fusion.h`), in `SixAxisSensorState`'s units (G, revolutions/s, revolutions). After 300 ms without a sample the source expires; without another source the sensor lies flat again. A shake still adds on top. The switches are in [development.md, How it works](../development.md#how-it-works) (Input).
- **Source routing (resolved, review of PR #351):** sharing one integrator let phone and controller callbacks mix orientations, including with `DM_PHONE_MOTION=1`; checking only `hasRotationRate` also let zero-only controller reports suppress the phone. Each source now has its own orientation and timestamp: auto prefers fresh controller data, forced mode selects only the phone, and the Apple adapter waits for actual data before publishing. One-player games merge motion from the same controller slots as buttons. Motion settings initialize once with `pthread_once`; per-source locks also protect diagnostic timestamps. `t_hid` covers routing, expiry and concurrent startup under ThreadSanitizer; `t_motion_apple` covers activation, zero-only reports and detachment.
- **Upright initialization (resolved, review of PR #351):** the heading reference was parallel to gravity when the phone started upright, so projection produced a zero vector and silently left the orientation flat. A nonparallel reference now primes the orientation on the first sample; `t_motion` covers all six axis-aligned starting poses.
- **Back from the background (iOS):** iOS turns a manual-activation controller's sensors (DualSense, DualShock 4) off while the app is in the background and leaves them off, so the gyro stayed dead until the controller reconnected (reported by MacNativeGames on the iPad). Becoming active again sets `sensorsActive` once more for every attached controller (`dm_motion_rearm`, `front_ios.m`); not tested on a device here.
- **Found on:** [The Legend of Zelda: Breath of the Wild](../../dm/games/01007EF00011E000/README.md) (1.9.0): motion aiming on a Mac with a DualSense. The iOS paths have not been tested on a device.
- **Note:** history entries repeat the newest sample; yaw drifts as on the console, with no recenter. The console's own sensor still reports no states ([SDK 20 six-axis sensor and amiibo (`nfp`) calls](#sdk-20-six-axis-sensor-and-amiibo-nfp-calls)), so motion follows the controller in docked mode.
- **Open:** [PR #286](https://github.com/seedds/nxnative/pull/286) has iPad aiming measurements and calibration controls to compare on a device before choosing shared defaults. Related reports: [#153](https://github.com/seedds/nxnative/issues/153), [#389](https://github.com/seedds/nxnative/issues/389).

### The phone's motion in the picture's frame

- **Symptom:** on iPhone Duo's inner display the phone's gyro is turned a quarter turn: tilting up and down moves the pointer left and right, and the other way round ([GitHub issue #569](https://github.com/seedds/nxnative/issues/569)); the outer display is right.
- **Cause:** Core Motion delivered the phone's samples in the hardware frame, and `DmGamepad.m` turned them into the Switch frame by the interface orientation (`motion_phone_to_switch`, `motion_fusion.h`). That holds only where the hardware frame is the screen's portrait frame, as on a phone with one display. The Duo's inner display is a quarter turn from it, and it ignores the app's supported orientations.
- **Fix:** on iOS 27 and later the pad view, full screen over the picture, is the motion manager's `deviceMotionBody`: Core Motion then delivers rotation rate, gravity and user acceleration in that view's frame, for whichever display shows it and however it is turned, which is the Switch frame as it is (x to the right of the picture, y to its top, z toward the player), and the orientation map is skipped. iOS 26 keeps the map. No device model or fold state is checked.
- **Found on:** [Super Mario Galaxy](../../dm/games/010099C022B96000/README.md): the gyro pointer on the inner display, reported by klave7. Not yet tested on a device: on the Duo's inner and outer displays and on a phone with one display running iOS 27, `DM_MOTION_LOG=1` should read acc `0 0 -1` with the phone flat and still.
- **Open:** while the scene is not full screen (Split View on the inner display) Core Motion falls back to the hardware frame without a flag that says so, and the samples are still taken as the view's frame.

### Switch Pro Controller advertises motion but sends zeroes

- **Symptom:** a Pro Controller's buttons work on the Mac, but its gyro pointer never moves; `GCMotion` callbacks arrive with acceleration and rotation all zero.
- **Cause:** the macOS driver can expose empty motion through GameController while its underlying Nintendo HID `0x30` reports contain IMU data ([PR #296](https://github.com/seedds/nxnative/pull/296)). The OS driver lies outside this repository; the passive HID adapter is a workaround for that platform defect.
- **Fix:** `motion_pro_mac.h` listens nonexclusively to vendor `057E`, product `2009`, without sending commands or changing the driver's configuration. `motion_pro.h` converts the three signed little-endian samples to G and rad/s in the Switch frame; their nominal 5 ms spacing reaches the shared integrator through `dm_motion_set_hid`. Each HID device owns its buffer and decoder. HID, GameController and phone orientations stay separate; usable GameController data wins, otherwise fresh HID data supplies that player's controller motion. Removal, focus loss or ambiguous routing clears only the HID source; 300 ms of silence expires it. `DM_MOTION_HID=0` disables the reader; `DM_MOTION=0` disables all motion.
- **Routing limit:** GameController exposes no public per-controller HID identity. Raw motion is enabled only with one physical Pro and one GameController Pro, using that controller's existing player slot (including `DM_KBD_PLAYER=own` / `DM_PAD_MERGE`). Multiple Pros keep their GameController paths; raw data is never assigned to the first controller by guesswork. Synthetic GameController HID devices are excluded with Apple's `GCSyntheticDevice` property.
- **Open:** passive reading cannot obtain factory calibration without issuing SPI commands alongside the OS driver. Nominal scales are 4096 counts/G and 70 mdps/count ([protocol research](https://github.com/dekuNukem/Nintendo_Switch_Reverse_Engineering/blob/master/imu_sensor_notes.md)); no automatic bias learning removes slow intentional turns. Sample order follows that research and [Linux hid-nintendo](https://github.com/torvalds/linux/blob/master/drivers/hid/hid-nintendo.c); SDL reverses it. Confirm order, sensitivity, drift and reconnects on hardware before calling the reworked reader device-tested. `t_motion_pro`, `t_motion_pro_mac` and `t_hid` cover decoding, timestamps, ownership, removal, ambiguity and source fallback with synthetic inputs.
- **Found on:** [Super Mario Galaxy](../../dm/games/010099C022B96000/README.md), docked pointer on a Pro Controller.

### SDK 20 six-axis sensor and amiibo (`nfp`) calls

- **Symptom:** SDK 20 calls that reach a service; `nfp`'s `AttachActivateEvent` / `AttachDeactivateEvent` crashed in the SDK at `sdk+0x3f2a78`.
- **Fix:** the console six-axis sensor (`hid::*SevenSixAxisSensor*`) reports zero states; more `nfp` calls are hooked: `AttachActivateEvent` / `AttachDeactivateEvent`, the two-argument `Mount`, `Unmount`, `GetCommonInfo`, `GetRegisterInfo`, `GetState`, `Finalize`. The host answers as a console with no amiibo.
- **Found on:** [The Legend of Zelda: Breath of the Wild](../../dm/games/01007EF00011E000/README.md) (1.9.0, SDK 20.5.22). [Super Mario Bros. Wonder](../../dm/games/010015100B514000/README.md) 1.2.1 already initialized `nn::nfp` at boot ([A game update imports SDK calls the base game did not](#a-game-update-imports-sdk-calls-the-base-game-did-not)).

### Vibration values flushed by the SDK's vibration graph

- **Symptom:** abort in `nn::sm::Initialize` under `nn::hid::VibrationNode::Update`.
- **Cause:** the SDK's vibration graph flushes queued values with `hid::detail::SendVibrationValues`, which opens the hid service. The game sets handles on its `VibrationTarget`s even when the host reports no vibration device.
- **Fix:** the flush calls it through the PLT, so an `HLE_FORCE` on that symbol catches it and returns success (`hle_hid.c`).
- **Found on:** [Metroid Dread](../../dm/games/010093801237C000/README.md).

### Whether a vibration device is mounted

- **Symptom:** with rumble on, `[RED] sf: the game connects to service hid itself`, then `CRASH sig=11 addr=0` in `hid::detail::IsVibrationDeviceMounted` (`sdk+0x24254c` in SDK 7), under `hid::IsVibrationDeviceMounted`. With rumble off in the host's settings the game never asks.
- **Cause:** the SDK's own call opens the hid service, which sm refuses (0xe15), and reads the null service object. Games ask only for handles `GetVibrationDeviceHandles` returned, which it returns none of with rumble off.
- **Fix:** `hle_hid.c` answers it. On Horizon a device is mounted when the npad's connected controller has the handle's style and an actuator on that side; the host reports it mounted when the channel has an output, as `GetVibrationDeviceInfo` reports the device.
- **Found on:** [Super Mario Odyssey](../../dm/games/0100000000010000/README.md) 1.4.1, entering a Sand Kingdom pipe (`main+0x5d3150` asks for each handle of a controller whether any is mounted; GitHub issue #715). No other local game imports it.

### Vibration handles before a controller is reported

- **Symptom:** `DM_RUMBLE_LOG=1` shows the game's startup handle request answered with none, then every vibration value sent to handle 0 and reaching no output for the whole session, although a controller with haptics (a DualSense on the Mac) is connected. A game that rumbles would stay silent.
- **Cause:** `hid::GetVibrationDeviceHandles` answered 0 handles until a controller's haptics were routed. Games ask once at startup, before GameController reports the pad, and keep the answer. On Horizon the handles are computed from the npad id and style alone (libnx `_hidGetVibrationDeviceHandles`).
- **Fix (resolved):** the handles no longer wait for a routed output: with rumble on and an output sink installed (`dm_haptics_enabled`), a connected npad style gets its two handles; `vib_send` checks for an output at each send (`hle_hid.c`). No sink, rumble off or a disconnected npad still get none, and `IsVibrationPermitted` still follows the routed outputs. `DM_RUMBLE_LOG=1` logs the handle requests and, once a second, the values sent, those with no routed output and the peak amplitude. Each input value is counted separately, including mixed batches; a mutex protects the diagnostic totals across game threads. `t_hid` covers cached startup handles delivering a nonzero value after routing, mixed-batch diagnostics and concurrent sends; `t_hid_tsan` checks those sends for data races.
- **Found on:** [Unicorn Overlord](../../dm/games/010069401ADB8000/README.md) (the Asian release, `010054B01AD92000`), in the log only: the game has no rumble of its own (it sends amplitude 0 throughout), so nothing could be felt before or after. Not yet checked on a game that rumbles.

### Controller haptic engines without advanced players

- **Symptom:** a controller (an Xbox Wireless Controller, a GameSir Super Nova, a GameSir Cyclone) never vibrates in a game on the Mac or the iPhone, though iOS Settings' Identify buzzes it; the log repeats `[RED] haptics: controller left handle create player: Couldn’t communicate with a helper application. (NSCocoaErrorDomain 4097)`. The engine itself starts.
- **Cause:** the engines that `GCDeviceHaptics` makes are served by `gamecontrollerd`, which tells CoreHaptics whether it offers advanced pattern players (`HapticServerConfig.supportsAdvancedPatternPlayers`; its log: `Server returned: supports audio: 0 adv players: 0`). `-[CHHapticEngine createAdvancedPlayerWithPattern:error:]` does not check that; the request reaches the server, which refuses it, and the XPC reply comes back as NSCocoaErrorDomain 4097, on every locality (All, Default, Handles, Left Handle, Right Handle). The output made only advanced players (a looping 30 s event driven by dynamic parameters), and a player failure is retried on the same handle, so the fallback to the default locality could not help either. On the Mac the refusal also leaves that engine unusable: a plain player or a restart on it fails with -4810. A plain `CHHapticPatternPlayer` on a new engine plays and takes dynamic intensity and sharpness controls.
- **Fix (resolved):** when the advanced player cannot be made, the channel drops that engine, makes a new one and keeps using plain players (`haptics_apple.m`, log line `has no advanced players … plain players`). A plain player cannot loop, and one stopped in the middle of an event left the Xbox controller's motors running at its level after the engine and the process were gone, until the controller was switched off. So plain players play pulses of 0.5 s that end on their own: the next one is scheduled where the last ends while the effect lasts, each starts at the current level (its pattern's initial control) and takes later levels as controls, and a stop sends level 0 to the playing pulses and stops the engine only after the last one has ended. Checked on an Xbox controller through the host's own `haptics_apple.m`: low and high levels are told apart, full level feels like a plain pattern at intensity 1, and the motors stop after the effect. `t_haptics_apple` covers a server without advanced players: the new engine, the pulses following each other, no pulse cut by a stop.
- **Left and right handle engines override each other (current).** Without advanced players, the engines of `LeftHandle` and `RightHandle` playing at once were not felt on the Xbox controller, while one engine on `Handles` (or on `All`) at the same intensity was; a trigger engine playing beside them likewise drowned them out. So a split route whose first advanced player is refused becomes one engine on `Handles` (`Default` when the controller does not list it) that plays both motors mixed (`merge`, log line `plays both motors on one engine`): the rumble is the same on both sides. `t_haptics_apple` covers the merge.
- **Low levels on rotating motors (open).** Controller motors and the Switch's resonant actuators disagree at low amplitudes, in two directions. The Xbox controller's motors showed nothing at intensity 0.05, a faint buzz from about 0.1 and a soft one at 0.3, so Breath of the Wild's charged attack (0.07 for about 3 s, `DM_RUMBLE_LOG=1`) was not felt even at `DM_RUMBLE_GAIN=2.5`. Mario Kart 8 Deluxe holds its low band at 0.1–0.4 all race long (about 30 changes a second, 0.84 peaks every few seconds): a texture on a Joy-Con, rumble that never lets up on a DualShock 4's motors. A floor with a square-root rise (0.15 + 0.85·√x) fixed the first and would make the second much worse, so the mapping stays linear. `DM_RUMBLE_MIN=0..0.9` (default 0) silences controller levels below it and stretches the rest over the full range, on every controller route; 0.45 leaves Mario Kart 8 Deluxe's crashes and drifts, as an emulator gives them on that controller. `t_haptics_apple` covers the cutoff.
- **Found on:** [The Legend of Zelda: Breath of the Wild](../../dm/games/01007EF00011E000/README.md) (1.9.0), on macOS 27.0.1 with an Xbox Wireless Controller over Bluetooth and an Xbox 360 USB receiver; [NieR:Automata The End of YoRHa Edition](../../dm/games/010056B015FE8000/README.md) (the Asian release, `0100B8E016F76000`) on an iPhone with a GameSir Super Nova in DualShock 4 mode, which plain players fixed; [Mario Kart 8 Deluxe](../../dm/games/0100152000022000/README.md) (4.0.1) on macOS 27.0.1 with a GameSir Cyclone; the same error in issue #219 (Sifu, provisional profile), controller unnamed.

### DualShock 4 rumble through its effects report

- **Symptom:** on the Mac, a DualShock 4 or a controller that presents itself as one (a GameSir Cyclone over Bluetooth: HID vendor `054C`, product `05C4`, `productCategory` "DualShock 4") does not rumble; Core Haptics failed on every locality with NSCocoaErrorDomain 4097 (issue #363, also in a minimal Swift app), while the same controller rumbles in an SDL-based emulator.
- **Cause:** the Core Haptics route was the only one. SDL's hidapi driver does not use it for a DualShock 4: it writes the controller's effects report, which needs no haptics server and keeps the strong and weak motors apart, where a server without advanced players merges them (above).
- **Fix (resolved):** on the Mac, a controller GameController calls a DualShock 4 is driven through that report when an IOHIDManager match on vendor `054C`, product `05C4` / `09CC` / `0BA0` is there (`ds4_route`, log line `rumble through the DualShock 4 effects report`): report `0x11` over Bluetooth (78 bytes, flags `0xC4`, rumble-only flag `0x01` so the light bar is left alone, CRC32 over `0xA2` and the first 74 bytes), `0x05` over USB (32 bytes), sent only when a motor byte changes. As the emulators feed SDL, the strong motor follows the low band and the weak one the high band (0.85 / 0.15 left / right), linearly, with `DM_RUMBLE_GAIN` and `DM_RUMBLE_MIN`. Without the HID device the controller keeps the Core Haptics route. GameController does not name a controller's HID device, so two DualShock 4s each get one, possibly swapped. `t_haptics_apple` covers the CRC and the fallback without the device; no test drives the report itself. iOS is unchanged.
- **Found on:** [Mario Kart 8 Deluxe](../../dm/games/0100152000022000/README.md) (4.0.1) and [The Legend of Zelda: Breath of the Wild](../../dm/games/01007EF00011E000/README.md) (1.9.0) with a GameSir Cyclone over Bluetooth on an M5 Pro, macOS 27.0.1: rumble on crashes and drifts (with `DM_RUMBLE_MIN=0.45`), on hits and chopping, stopping after each. Not checked: a genuine Sony DualShock 4, the USB report.

### Scripted presses on a path of their own

- **Symptom:** with a controller connected (a DualShock 4 here), `DM_KEYS` and `DM_CTL` presses are logged (`DM_KEYS: … press …`) but the game does not react to them, or only now and then; without the controller the same script works.
- **Cause:** scripted presses went through player 1's controller path (`dm_pad_set`). A connected controller publishes its whole state there on every change, replacing scripted holds and sticks; the press latch preserves only the first read. Script release also cleared the physical controller's state.
- **Fix (resolved):** `DM_KEYS` and `DM_CTL` set buttons, a press latch and sticks of their own (`script_set` in `hle_hid.c`), ORed with the keyboard / touch path and player 1's controller when the game reads player 1; for the sticks, the one deflected more wins. Shake includes the scripted path too.
- **Check:** `dm/host/tests/t_hid.c` (`t_script`) runs the scripted publisher with a controller update during the hold: buttons survive repeated reads after the latch is consumed, the scripted stick wins over drift, shake continues, and release preserves physical input. Short presses are latched once, all four axes reach the handheld npad, and player 2 stays separate.
- **Found on:** Batman: Arkham Knight (`0100ACD0163D0000`), reported in [PR #326](https://github.com/seedds/nxnative/pull/326) while driving the opening route with `DM_KEYS` and a DualShock 4. Reproduced independently in the host HID test without game files; its game profile is not in this checkout.

### Touch gestures recognized from the touch points

- **Symptom:** taps in handheld mode do nothing, though the game reads the touch screen (the title's PRESS ANY BUTTON, the menus' cards).
- **Cause:** the game's touch handler (`main+0x42f1ac`) uses `GetTouchScreenState` only to track the finger and takes its taps, pans and swipes from `hid::GetGestureStates` (it acts on types 5–9), which the host answered with no entries.
- **Fix:** the host now recognizes gestures from the same touch points, by yuzu's rules plus an 8 px slop before a touch counts as moving (`hle_touch.c` `gesture_sample`, unit test `t_gesture`; only in handheld mode, as touches): Touch, Press after 0.5 s, Pan, Pinch / Rotate with two fingers, Cancel on a change in the finger count, then Tap (IsDoubleTap within 0.35 s), Swipe above 400 px/s or Complete, and Idle. For every game.
- **Check:** every menu, the cards, the map's drag and flick worked by touch with it. `DM_TOUCH_LOG=1` logs each gesture entry, and a `DM_CTL` line `drag <x0> <y0> <x1> <y1> [seconds]` moves a finger for testing pans and swipes on the Mac.
- **Found on:** [Taiko Risshiden V DX](../../dm/games/0100346017304000/README.md) (SDK 12.3.3, Koei Tecmo's KTGL).

### Mouse, keyboard and key code maps

- **Symptom:** the first boot aborted in `hid::GetMouseState` (the SDK's mouse resource was never initialized).
- **Fix:** hooked: `hid::GetMouseState`, `hid::GetKeyboardStates`, and `kpr::GetKeyCodeMap`, which asks the settings service (`settings::detail::GetKeyCodeMap`) for the keyboard layout's map; the host leaves the map zero.
- **Found on:** [13 Sentinels: Aegis Rim](../../dm/games/01003FC01670C000/README.md) (SDK 11, `GetMouseState`); [Monster Hunter Rise](../../dm/games/0100B04011742000/README.md) (SDK 11, `GetKeyboardStates`); [DRAGON QUEST VII Reimagined](../../dm/games/0100A9D01C446000/README.md) (`kpr::GetKeyCodeMap`: the game zeroes a 0x1000-byte map and fetches it only once a keyboard reports keys, `main+0x1f0eb4`).

### Poké Ball Plus (Palma)

- **Symptom:** the first boot crashed in `hid::detail::SetPalmaBoostMode`, a null read at `sdk+0x238eb0` (the hid service never opened).
- **Fix:** the Poké Ball Plus calls (`hid::*Palma*`, 26 functions) answer that none is connected: no npad has the Palma style, so the game never gets a connection handle, and every call on a handle fails (`hle_hid.c`).
- **Found on:** [Pokémon Sword](../../dm/games/0100ABF008968000/README.md) (SDK 7).

### IR camera reported unconnected

- **Symptom:** undefined `irsensor` imports found from the import list ([Listing a game's unhooked imports before they are met](#listing-a-games-unhooked-imports-before-they-are-met)).
- **Cause:** Bezel Engine's input layer makes one (an IR camera) per controller and asks its status (`main+0x497f84`).
- **Fix:** the IR camera (`irsensor`) answers every camera unconnected, and processors cannot run.
- **Found on:** [Big Brain Academy: Brain vs. Brain](../../dm/games/0100620012D6E000/README.md) (SDK 11.4.3, NintendoWare Bezel Engine).

## Software keyboard and applets

### System applets opened by `Show…` calls

- **Symptom:** null read in `sdk` under `nn::applet::CreateLibraryApplet` (Engage: title menu → DLC → `nn::ec::ShowShopAddOnContentList`); `Show…` overloads found in the imports before they were met.
- **Cause:** every `Show…` call that opens a system applet (eShop, friend lists, web pages, error screens) goes through the applet proxy that `oe::Initialize` would have set up, and the host has none.
- **Fix:** hook each `Show…` overload the game imports: list `main`'s undefined symbols containing `Show` / `Applet` and grep the host sources for each mangled name; one overload missing is enough to crash. The shop calls return `void` and act as if the player closed the shop (`hle_misc.c`); the friends and web ones return failure (`hle_friends.c`, `hle_offline.c`). `web::ShowOfflineHtmlPage` is cut, as `ShowWebPage`. `err::ShowNetworkServiceError` and `err::ShowApplicationError` are logged. Also hooked, found in the imports before they were met: the `ShowShopAddOnContentList(UserHandle)` overload, and the `ec::ShowShop…` overloads without an `ApplicationId` (they show the calling application's own pages). `ec::ShowShopSubscriptionDetails` is under [Shop service accessors](#shop-service-accessors).
- **Found on:** [Fire Emblem Engage](../../dm/games/0100A6301214E000/README.md) (the shop calls); [Octopath Traveler 0](../../dm/games/01005270232F2000/README.md) (`web::ShowOfflineHtmlPage`); [Pokémon Sword](../../dm/games/0100ABF008968000/README.md) (SDK 7, `err::ShowNetworkServiceError`); [Pokémon Legends: Z-A](../../dm/games/0100F43008C44000/README.md) (19.3.11: `ShowShopAddOnContentList(UserHandle)`, `err::ShowApplicationError`); [The Great Ace Attorney Chronicles](../../dm/games/010036E00FB20000/README.md) (SDK 10.4.1: the overloads without an `ApplicationId`).

### Library applets take the application's focus

- **Symptom:** entering 2P stops the game on its 2P screen: the same frame repeats, the music plays, no controller does anything, until the window loses and regains focus (Mario Kart 8 Deluxe, every launch). With one controller, once that was fixed: the 2P character select ignores input while the log shows the controller applet opened again every few frames.
- **Cause:** on Horizon a library applet takes the application's focus. am sends message 15 with OutOfFocus when it opens and 15 with InFocus when it closes, and the `Show…` call returns once it has closed. The host's stand-ins answered at once with no focus change. Mario Kart applies the controller applet's answer only after that InFocus notification: its notification thread (`main+0x8ea560`, blocking `PopNotificationMessage`) sets a flag on 15 with state 1, and the per-frame `main+0x87b5d0` takes the flag before it applies the answer (`main+0x87b300`). Second: with fewer controllers than the game's minimum, the host answered success with the connected count. A Switch never gives that answer (its applet waits for controllers until the player closes it), and the game, which asks for two in 2P, opened the applet again.
- **Fix:** `hle_oe.c` counts open applets apart from the front end's focus. The game sees the front end's state, or 2 while an applet is open over a game in focus; each change of what it sees is one 15 (under focus modes 1 and 2, [Focus handling mode decides whether focus changes are notified](#focus-handling-mode-decides-whether-focus-changes-are-notified)). `DM_APPLET("name");` (`hle.h`) at the top of a stand-in holds the game out of focus until the stand-in returns: the controller applet (both overloads), strap guide and firmware update, `swkbd::ShowKeyboard`, the Mii editor, the user selector and creator, the error applets and the shop pages. Stand-ins that report the applet could not start (friends, web, the license notice, the album, amiibo) open none. The inline keyboard is left as it was: its applet draws into the game's own picture and is not believed to take focus (not checked). An instant open and close merges into one pending 15 that reads 1, which is all Mario Kart needs; a game that must see the 2 would need more. `ShowControllerSupport` with fewer players than the minimum (`ControllerSupportArg` +0) returns `ResultControllerSupportCanceled` (2202-3101), what the SDK's `ShowControllerSupportCore` (SDK 4.4.0 `sdk+0x24eeb0`) returns when the player closes the applet; Mario Kart goes back to its engine class menu, as on a Switch. `DM_OE_SCRIPT` now also starts for a game that only uses the blocking `PopNotificationMessage`.
- **Found on:** [Mario Kart 8 Deluxe](../../dm/games/0100152000022000/README.md) (4.0.0 and 4.0.1; GitHub issue #550).
- **Check:** `t_oe` and `t_hid` (`dm/host/tests`). On the Mac, from a save past the Mii pick: L+R at the title, Down, A (2P), A (Grand Prix), A (50cc). The log shows `oe library applet: controller support`, then `oe focus state → 2 (library applet open)` and `→ 1 (library applet closed)`, and the character select takes input. With one controller the applet logs `too few, closed as the player would (canceled)` once and the engine class menu comes back.

### The software keyboard blocks only its caller

- **Symptom:** the sound stutters and the input box lags while the player types a name (Octopath Traveler 0 on an iPhone: one 4.7 s frame, 5,035 wakeups a second instead of about 1,800, and no audio underruns).
- **Cause:** the host froze the guest clock while `swkbd::ShowKeyboard` was up (d2r-mobile's choice, so that monsters did not attack while the player typed). Unreal calls it off its game thread, so the game kept running, and every thread that waits on the clock spun while its audio mixing starved. On the Switch the applet blocks only the caller while the clock runs.
- **Fix:** the host now does the same (`hle_swkbd.c`). The iOS input box froze the clock a second time around its own wait (`front_ios.m`), so the first fix changed nothing on the phone (4,977 ms and 2,577 ms frames, 5,181 wakeups a second): look for every caller of `guest_clock_freeze_for`, the front ends included. The inline keyboard keeps the freeze: its game (Monster Hunter Rise) does not block on hardware at all, and the host's input box blocks it.
- **Found on:** [Octopath Traveler 0](../../dm/games/01005270232F2000/README.md).
- **Check:** on the Mac `DM_KBD=<text> DM_TEST_SWKBD_HOLD_MS=8000` holds the keyboard up: frozen, 8.8 fps and 7,936 wakeups a second in that window; running, 30 fps and 1,788.

### The inline keyboard as a resident library applet

- **Symptom:** null read in `applet::CreateLibraryApplet` under `swkbd::InlineKeyboard::Initialize` (3D World, entering the save select after the character select).
- **Cause:** the inline keyboard is a resident library applet whose results arrive through `Calc`.
- **Fix:** `hle_swkbd.c` takes over every entry that touches the applet: `Appear` arms a request, and the next `Calc` asks for the text the way `ShowKeyboard` does (`DM_KBD`, else the front end's input box) and hands it to the game's changed-string and enter callbacks, or calls its cancel callback; `GetImage` reports no picture. `GetImageMemoryRequirement` is not a pure computation: it asks vi, hence the `vi::GetIndirectImageMemoryRequirement` hook ([vi layer and display calls without vi service objects](#vi-layer-and-display-calls-without-vi-service-objects)).
- **Found on:** [Super Mario 3D World + Bowser's Fury](../../dm/games/010028600EBDA000/README.md).

### Inline keyboard window size, setters and callbacks

- **Symptom:** texture creation returns null right after the inline keyboard's `Initialize`, then a null read at `main+0x7713044`.
- **Cause:** the game makes three textures of `swkbd::InlineKeyboard::GetWindowSize`, and the host answered 0 × 0 (its creation function returns null for a size of 0, `main+0x77112b8`).
- **Fix:** it is 1280 × 720 as on hardware now. SDK 11 adds keyboard setters (window mode, key top alpha / scale / position, touch, hardware keyboard, user words, dictionaries; ignored) and two callbacks the applet makes from `Calc`: finished-initialize after `Initialize` and released-user-words after `UnsetUserWordInfo`. The host makes them on the next `Calc`.
- **Found on:** [Monster Hunter Rise](../../dm/games/0100B04011742000/README.md).

### Inline keyboard text callbacks and `Calc` states

- **Symptom:** the hunter's name box stays empty, then stays open with the name in it (Monster Hunter Rise, character creation).
- **Cause:** the inline keyboard used to count every `Appear` as a cancel. The game also finishes the entry only when `Calc` returns 1 (ready / hidden) after a non-zero value (`main+0x6fb3e6c`); the hook returned nothing.
- **Fix:** the text arrives through the enter callback, whose argument is the text inline (`char16_t[502]`, the length at +0x3EC; the changed-string argument adds three cursor positions at +0x3F0..+0x3F8: `ikb_str_arg`, read off the game's callbacks at `main+0x6fb3910` / `main+0x6fb3afc`). `Calc` now returns 0 until initialization finishes, 3 while shown and 1 otherwise. `SetFinishedKeyboardCallback` is called on the `Calc` after `Disappear`. AppearArg's `textMaxLength` (+0x20) limits the text.
- **Found on:** [Monster Hunter Rise](../../dm/games/0100B04011742000/README.md).

### `nn::ngc::ProfanityFilter` vtable and by-name overloads

- **Symptom:** `CRASH sig=10` at a heap address, called from `main+0x6bca160` right after the name was entered (Monster Hunter Rise); crash in `lmem::AllocateFromExpHeap` under `ngc::ProfanityFilter::MaskProfanityWordsInText` right after the character name is entered (DARK SOULS: REMASTERED); filter methods among the undefined imports with no hook, found from the import list before they were met (The Great Ace Attorney Chronicles).
- **Cause:** `nn::ngc::ProfanityFilter` is polymorphic and Monster Hunter Rise masks the name through its vtable (slot 8, `MaskProfanityWordsInText(int *, char16_t *, uint32_t)`). The constructor hook did nothing, so the object kept what the heap held. Other games call the methods by name: DARK SOULS: REMASTERED calls the UTF-16 overload (`EPiPtj`) by name, and the host had taken it over only in the filter's vtable, so the SDK's version ran on a filter whose word list the host never loaded; The Great Ace Attorney Chronicles calls `ngc::ProfanityFilter::MaskProfanityWordsInText(int *, char *, uint32_t)`, `SetMaskMode` and `Finalize` by name rather than through the vtable.
- **Fix:** the filter now gets a host vtable (`ngc_vtable` in `hle_misc.c`): each slot of the SDK's `_ZTVN2nn3ngc15ProfanityFilterE` is matched by address with the class's methods, and slots the loader already bound to forced take-overs keep them. The `unsigned short` and `char16_t` overloads are taken over by name too, as are the `char` overload, `SetMaskMode` and `Finalize` (`hle_misc.c`). Nothing is masked or reported.
- **Found on:** [Monster Hunter Rise](../../dm/games/0100B04011742000/README.md) (the vtable); [DARK SOULS: REMASTERED](../../dm/games/01004AB00A260000/README.md) (SDK 4.5.0; one boot: the UTF-16 overload by name); [The Great Ace Attorney Chronicles](../../dm/games/010036E00FB20000/README.md) (SDK 10.4.1: the `char` overload, `SetMaskMode`, `Finalize`).

## Display, window and operation mode

### `vi::CreateLayer` with the layer's size

- **Symptom:** SIGSEGV in `vi::CreateLayer(Layer**, Display*, int, int)` (`sdk+0x3f9bc4`, from SDL3's Switch video driver at `main+0x239304`).
- **Cause:** the overload with the layer's size; the host had only the two-argument one.
- **Fix:** it returns the static layer (`hle_vi.c`).
- **Found on:** [Absolum](../../dm/games/0100A83022A22000/README.md) (SDK 18.3.2, FNA on .NET NativeAOT with SDL3; one boot each).

### `vi::CreateLayer` with `LayerCreationSettings` (SDK 22)

- **Symptom:** SIGSEGV at `sdk+0x44ea94` reading address 0, in `vi::CreateLayer`, right after `am::GetSelfController()`; the caller is the game's window setup (`main+0x978cb6c`).
- **Cause:** SDK 22 adds `CreateLayer(Layer**, Display*, const LayerCreationSettings*)`; the game builds the settings with the SDK's `LayerCreationSettings(int w, int h)` (`{w, h, 2}`, `sdk+0x4526a0`), and the SDK's `CreateLayer` asks the applet's self controller, which the host never made.
- **Fix:** the host takes it over like the sized overload (`hle_vi.c`): the static layer, and the size recorded for an EGL surface.
- **Found on:** [EA SPORTS FC 27](../../dm/games/0100C49025D3E000/README.md) (SDK 22.2.0): 1920x1080.

### vi layer and display calls without vi service objects

- **Symptom:** SIGSEGV in `vi::SetLayerCrop`.
- **Cause:** the SDK's version dereferences vi service objects the host never made.
- **Fix:** `SetLayerCrop` only records the crop for the present ([The NVN present crops by the vi layer crop](rendering.md#the-nvn-present-crops-by-the-vi-layer-crop)); `DestroyLayer`, `CloseDisplay` and `vi::Finalize` are host no-ops. Also hooked: `vi::GetIndirectImageMemoryRequirement` (asked by the inline keyboard's `GetImageMemoryRequirement`, [The inline keyboard as a resident library applet](#the-inline-keyboard-as-a-resident-library-applet)); `vi::ListDisplays` (one display, "Default"; the game lists 10 into a stack buffer and does not read them, `main+0x808f08`), found from the import list before it was met.
- **Found on:** [The Legend of Zelda: Link's Awakening](../../dm/games/01006BB00C6F0000/README.md) (SDK 8.2.0); [Super Mario 3D World + Bowser's Fury](../../dm/games/010028600EBDA000/README.md) (SDK 10: `vi::GetIndirectImageMemoryRequirement`); [The Great Ace Attorney Chronicles](../../dm/games/010036E00FB20000/README.md) (SDK 10.4.1: `vi::ListDisplays`).

### Layer frame numbers

- **Symptom:** SIGSEGV in `android::Surface::getQueuedFrameNumber` under `nn::vi::GetLatestFrameNumber`.
- **Cause:** Unreal paces frames by the layer's frame number (`main+0x10140e8`); the SDK reads the vi service's surface, which the host never made.
- **Fix:** `hle_vi.c` answers with the frames presented so far; `ListFrameHistory` returns no entries.
- **Found on:** [Octopath Traveler 0](../../dm/games/01005270232F2000/README.md).

### Default display panel identifier

- **Symptom:** SIGSEGV in `vi::GetDefaultDisplayPanelIdentifier` (`main+0xa9a4`, before the window).
- **Cause:** the SDK's version calls through the vi service object the host never made. The game reads a u32 kind and, from kind 2, 0x14 more bytes; anything else makes it use zeros.
- **Fix:** the host answers an all-zero identifier (`hle_vi.c`).
- **Note:** a passed TV latency calibration in this game is saved per TV panel identity, the host's all-zero one included ([TV latency calibration's late, beat-timed listening window](game-state.md#tv-latency-calibrations-late-beat-timed-listening-window)).
- **Found on:** [Rhythm Heaven Groove](../../dm/games/0100D9F01D474000/README.md) (SDK 21.4.0, one boot).

### oe calls answered without an applet proxy

- **Symptom:** the first boot crashed in `oe::DisableAlbumImageTakenNotification`: a null read at `sdk+0x338070`, the first call in `nnMain` (`main+0x6b188c`); enabling those notifications also gives a null read at `sdk+0x33b0f0` (Xenoblade Chronicles 3); other `oe` calls that reach am, found in the imports before they were met.
- **Symptom:** a null read at `sdk+0x36ec60` in `oe::EnableAlbumImageTakenNotification`, called from `nnMain` (`main+0x286268`).
- **Fix:** `EnableAlbumImageTakenNotification` uses the same host implementation as the disable call: no system-album notifications are produced. Found on [Mario + Rabbids Sparks of Hope](../../dm/games/0100317013770000/README.md) (SDK 13.3.5); the next boot reaches the NVN frame loop.
- **Cause:** the SDK asks am through the applet proxy the host never made.
- **Album notification enable:** `oe::EnableAlbumImageTakenNotification` follows the existing disable takeover. The host produces no Horizon album captures, so enabling notifications produces no messages. Found on [Xenoblade Chronicles 3](../../dm/games/010074F013262000/README.md) (SDK 12.3.9, `main+0x127fac4`).
- **Inactivity extension:** `oe::GetUserInactivityDetectionTimeExtensionMode` also reads the absent SelfController (`sdk+0x3391f0`, after Xenoblade Chronicles 3's opening movie). The host retains the requested mode: 0 initially or when either setter receives false, 1 for `SetUserInactivityDetectionTimeExtended(true)`, 2 for its `Unsafe` form. The boolean query is mode != 0, matching SDK 12.3.9's implementation. This state does not make the host turn the screen off. `t_oe` checks both setters and both queries.
- **Fix:** hooked (`hle_oe.c`): `oe::DisableAlbumImageTakenNotification`; `oe::IsInStoreDemoModeEnabled` (no); `oe::GetDefaultDisplayResolution` and its change event; `oe::SendServerMaintenanceOverlayNotification`; `oe::SetUserInactivityDetectionTimeExtendedUnsafe`; `oe::GetPerformanceConfiguration`; `oe::SetAlbumImageOrientation`; `oe::Begin` / `EndAutoSleepDisabledSection` and `IsAutoSleepDisabled` (counted); `oe::ExecuteProgram` (logged red: the host runs one program). The ones with a symptom of their own follow: [The startup logo](#the-startup-logo), [Copyright frame buffer overlay](#copyright-frame-buffer-overlay), [Applet resource user ID, launch parameters and VR mode](#applet-resource-user-id-launch-parameters-and-vr-mode), [CPU overclock calls without an apm session](#cpu-overclock-calls-without-an-apm-session), [Focus handling mode decides whether focus changes are notified](#focus-handling-mode-decides-whether-focus-changes-are-notified).
- **Found on:** [Monster Hunter Rise](../../dm/games/0100B04011742000/README.md) (SDK 11: `GetDefaultDisplayResolution`, `SendServerMaintenanceOverlayNotification`); [13 Sentinels: Aegis Rim](../../dm/games/01003FC01670C000/README.md) (SDK 11: `SetUserInactivityDetectionTimeExtendedUnsafe`); [Super Mario 3D World + Bowser's Fury](../../dm/games/010028600EBDA000/README.md) (SDK 10: `GetPerformanceConfiguration`, `SetAlbumImageOrientation`); [DRAGON QUEST XI S](../../dm/games/01006C300E9F0000/README.md) (SDK 7.3.2: the auto-sleep calls); [Octopath Traveler 0](../../dm/games/01005270232F2000/README.md) (`oe::ExecuteProgram`); [The Great Ace Attorney Chronicles](../../dm/games/010036E00FB20000/README.md) (SDK 10.4.1, Capcom's MT Framework: `DisableAlbumImageTakenNotification`, then `IsInStoreDemoModeEnabled` from the import list); [Donkey Kong Country: Tropical Freeze](../../dm/games/0100C1F0051B6000/README.md) (SDK 4.4.0: `GetUserInactivityDetectionTimeExtensionMode`, a null read at `sdk+0x15b73c` when the first level's cinematic camera starts, `CScreenDimmingUtil::DisableScreenDimming`). After all of its fixes The Great Ace Attorney Chronicles runs its frame loop at 30 fps; the black screen it showed was its textures, never uploaded (CPU-written textures, the profile's `tex_flush_upload` and `tex_dirty_upload`: [Mapped-range flushes taken as uploads (`tex_flush_upload`)](nvn-objects.md#mapped-range-flushes-taken-as-uploads-tex_flush_upload), [CPU writes with no flush, caught by page protection (`tex_dirty_upload`)](nvn-objects.md#cpu-writes-with-no-flush-caught-by-page-protection-tex_dirty_upload)).

### The startup logo

- **Symptom:** abort in `nn::sm::Initialize` under `nn::oe::FinishStartupLogo`, right after the first frames.
- **Cause:** it reaches the applet proxy through `am::GetApplicationFunctions`.
- **Fix:** the host has no startup logo: a no-op hook (`hle_oe.c`).
- **Found on:** [Metroid Dread](../../dm/games/010093801237C000/README.md).

### Copyright frame buffer overlay

- **Symptom:** null read in `oe::InitializeCopyrightFrameBuffer`, right after the window setup.
- **Cause:** the copyright frame buffer is an overlay the system draws only into screenshots and recordings; the SDK hands it to am as transfer memory.
- **Fix:** `InitializeCopyrightFrameBuffer`, `SetCopyrightImage` and `SetCopyrightVisibility` are host no-ops (`hle_oe.c`).
- **Found on:** [Hyrule Warriors: Age of Calamity](../../dm/games/01002B00111A2000/README.md) (SDK 9.6).

### Applet resource user ID, launch parameters and VR mode

- **Symptom:** SDK 20 calls that reach a service, each one boot; SDK 20's `OpenAudioRenderer` aborts on an ARUID of 0.
- **Cause:** the SDK's own `applet::GetAppletResourceUserId` returns 0 without am, and SDK 20's `OpenAudioRenderer` aborts on that.
- **Fix:** `applet::GetAppletResourceUserId` reports 0x80; the VR-mode calls (`pl::IsVrMode` / `BeginVrMode` / `EndVrMode`; `BeginVrMode` returns 0xd08e, the SDK's own refusal); `pctl::CheckStereoVisionPermission` (bool, not permitted: the host has no VR display); `oe::TryPopLaunchParameter` (none) ([The Legend of Zelda: Breath of the Wild](../../dm/games/01007EF00011E000/README.md) 1.9.0, SDK 20.5.22). `oe::GetPreviousProgramIndex` reports −1: launched from the home menu ([The Legend of Zelda: Tears of the Kingdom](../../dm/games/0100F2C0115B6000/README.md) 1.4.3).
- **Found on:** [The Legend of Zelda: Breath of the Wild](../../dm/games/01007EF00011E000/README.md), [The Legend of Zelda: Tears of the Kingdom](../../dm/games/0100F2C0115B6000/README.md).

### CPU overclock calls without an apm session

- **Symptom:** a null read in `sdk+0x35258` (apm's session) in `oe::IsCpuOverclockEnabled`, the first call in `nnMain`; null read at `sdk+0x362b8` (`apm::SetCpuOverclockEnabled`) in the first calls of `nnMain` (`main+0x2e1e4c`).
- **Cause:** `oe::IsCpuOverclockEnabled` and `oe::SetCpuOverclockEnabled(bool)` go through the apm session the host never opened.
- **Fix:** `oe::IsCpuOverclockEnabled` is hooked; for `SetCpuOverclockEnabled` the host keeps the flag and the query reports it (`hle_oe.c`); it does not scale clocks.
- **Found on:** [Monster Hunter Rise](../../dm/games/0100B04011742000/README.md) (SDK 11: `IsCpuOverclockEnabled`); [Taiko Risshiden V DX](../../dm/games/0100346017304000/README.md) (SDK 12.3.3: `SetCpuOverclockEnabled`).

### Focus handling mode decides whether focus changes are notified

- **Symptom:** the game freezes after switching apps and back, picture still, sound on; the main loop waits in its pause handshake (`main+0x5d10d4` / `main+0x5cea68`). Mac repro `DM_OE_SCRIPT=bg=1@20,bg=0@25`.
- **Cause:** the game's own pause deadlocks. The game set focus handling mode 3. The SDK (`oe::SetFocusHandlingMode`, SDK 18 `sdk+0x3c5770`) turns modes 0 and 3 into "no focus notifications, the system suspends the game out of focus"; only 1 and 2 notify. The host sent message 15 anyway, and Galaxy 2's Wii layer ran a pause the console never triggers.
- **Fix:** `hle_oe.c` now queues 15 only under modes 1 and 2 (or when no mode was set).
- **Found on:** [Super Mario Galaxy 2](../../dm/games/0100FD8022DAA000/README.md) (one of two causes of the freeze; the other is [Guest clock reads wait while the app is in the background](#guest-clock-reads-wait-while-the-app-is-in-the-background)).
- **Note:** modes seen: 1 Monster Hunter Rise; 2 Wonder, Breath of the Wild, Tears of the Kingdom, Link's Awakening, Cuphead; 3 Galaxy, Galaxy 2, 3D World, Odyssey.

### Album calls fail with no album

- **Symptom:** abort in `sm::Initialize` under `capsrv::InitializeForApplication` (`album::Initialize`); calls that reach the album service, found in the imports before they were met.
- **Fix:** with no album they fail: `album::Initialize` (saving to the album now fails, `hle_offline.c`); SDK 7's `album::SaveScreenshot` without an orientation (fails); SDK 20's `SaveAndShareScreenshot` with a share ID and `GetSharePostedLastUrl`; `album::SaveCurrentScreenshot`.
- **Found on:** [Monster Hunter Rise](../../dm/games/0100B04011742000/README.md) (SDK 11: `album::Initialize`); [DRAGON QUEST XI S](../../dm/games/01006C300E9F0000/README.md) (SDK 7.3.2: `album::SaveScreenshot`); [Animal Crossing: New Horizons](../../dm/games/01006F8002326000/README.md) (SDK 20.5.4: the sharing calls); [Pokémon Legends: Z-A](../../dm/games/0100F43008C44000/README.md) (19.3.11: `SaveCurrentScreenshot`).

## Accounts, network, shop and parental controls

### Account, friends, play data and Nintendo Account calls

- **Symptom:** a null read at `sdk+0x336ccc` in `pdm::QueryApplicationPlayStatistics` (Pokémon Sword, the second boot); undefined `nn::account::` / `nn::friends::` imports with no hook, found from the import list ([Listing a game's unhooked imports before they are met](#listing-a-games-unhooked-imports-before-they-are-met)) before they were met.
- **Fix:** hooked (`hle_account.c`, `hle_friends.c`, `hle_offline.c`): `account::ListAllUsers`; `account::PushOpenUsers` (nothing to hand over); `account::LoadCachedNintendoAccountInfo` (fails: no Nintendo Account; Big Brain Academy then skips the birthday and country getters); `friends::GetBlockedUserList`, `DeclareOpen` / `DeclareCloseOnlinePlaySession` (unavailable); `friends::StartFacedFriendRequest` / `StartSendingFriendRequest` (fail); the Nintendo Account request's `GetAuthorizationCode` and `GetState` (both fail, as `GetIdToken`); `pdm::QueryApplicationPlayStatistics`, which asks how often this user launched two other games and reads only the launch count, so each is never played.
- **Found on:** [Super Mario 3D World + Bowser's Fury](../../dm/games/010028600EBDA000/README.md) (SDK 10, `ListAllUsers`); [Octopath Traveler 0](../../dm/games/01005270232F2000/README.md) (`PushOpenUsers`); [DRAGON QUEST XI S](../../dm/games/01006C300E9F0000/README.md) (the friends calls); [DRAGON QUEST VII Reimagined](../../dm/games/0100A9D01C446000/README.md) (the Nintendo Account request); [Pokémon Sword](../../dm/games/0100ABF008968000/README.md) (SDK 7, `pdm`); [The Great Ace Attorney Chronicles](../../dm/games/010036E00FB20000/README.md) (SDK 10.4.1: the friend requests); [Big Brain Academy: Brain vs. Brain](../../dm/games/0100620012D6E000/README.md) (SDK 11.4.3: `LoadCachedNintendoAccountInfo`).
- **Note:** [Super Mario Odyssey](../../dm/games/0100000000010000/README.md)'s `account::OpenPreselectedUser` and `account::GetLastOpenedUser` are in [SDK calls that open a system service through sm](#sdk-calls-that-open-a-system-service-through-sm); SDK 6's `OpenPreselectedUser` in [SDK 6's `account::OpenPreselectedUser` returns a Result](#sdk-6s-accountopenpreselecteduser-returns-a-result); SDK 4's `GetBlockedUserList` without a `Uid` in [SDK 4's `friends::GetBlockedUserList` without a `Uid`](#sdk-4s-friendsgetblockeduserlist-without-a-uid); the save thumbnail calls in [Directory, file data cache and save-thumbnail calls](#directory-file-data-cache-and-save-thumbnail-calls).

### Mii database answered by the host

- **Symptom:** `[RED] sf: the game connects to service mii:e … mii:u itself`, then an abort.
- **Cause:** `nn::mii::Database` keeps an `IDatabaseService` of the mii service at +0 (`Database::Initialize`, `sdk+0x1c5664`), and `AppendMii` / `ShowMiiEdit` start the MiiEdit applet.
- **Fix:** `hle_mii.c` takes over the public methods: a console with no Mii of its own (an empty database: no index, nothing to update) that still has the six default Miis every console has. A CharInfo the host builds is the default Mii's parameters with Switch common colours, a create ID with version 4 and variant bits (fixed per default Mii, so a saved choice finds the same Mii; fresh for `BuildRandom`, which the title's demo race calls for 12 racers) and the nickname "no name"; every field is within `CharInfoRaw::Verify`'s ranges (`sdk+0x1b68c8`). The Mii editor is cancelled (0xE7E, which `ShowMiiEdit` itself treats as success).
- **Found on:** [Mario Kart 8 Deluxe](../../dm/games/0100152000022000/README.md) (4.0.0, SDK 4.4.0; one boot). The game asks for the default Miis with `Get(…, 6, SourceFlag 2)` and never reads the count (`main+0x81e954`): its boot-time list of Mii icons (`main+0x419dc8`) builds a head model for each of the six, and zeroed entries failed the model's `CharInfoAccessor::IsValid` (`CharModel::Initialize` returned 0xd67e, `main+0x8f15b0`) and crashed at `main+0x8f152c`.
- **Note:** the heads' model data is a stand-in with every part empty ([System data stand-in for the MiiModel archive](#system-data-stand-in-for-the-miimodel-archive)).

### Shop service accessors

- **Symptom:** the abort with no message (`SVC 0x15` / `0x1f` / `0x21` placeholders, then `Break` with `sm::Finalize` under `ShopServiceAccessServer::Proxy::Initialize`) from `ec::InitializeForShopServiceAccessors`, called from Unreal's `FOnlineSubsystemSwitch::Init` at the start of `nnMain`.
- **Cause:** the shop service accessor library reaches the shop service.
- **Fix:** the library init succeeds with nothing to set up, an accessor never initializes, and its async response is complete at once with no data (`hle_misc.c`); the accessor and response are stubbed whole because the SDK's destructor aborts unless `Finalize` succeeds. Also hooked: `ec::FinalizeForShopServiceAccessors`, the shop response's `Cancel` and `GetErrorCode`, and `ec::ShowShopSubscriptionDetails`.
- **Found on:** [DRAGON QUEST XI S](../../dm/games/01006C300E9F0000/README.md) (SDK 7.3.2: the game then runs its opening movie at 30 fps); [DRAGON QUEST VII Reimagined](../../dm/games/0100A9D01C446000/README.md) (SDK 19.3.1: `FinalizeForShopServiceAccessors`, `Cancel`, `GetErrorCode`, `ShowShopSubscriptionDetails`, found by the import list).
- **Note:** the shop's `Show…` pages are under [System applets opened by `Show…` calls](#system-applets-opened-by-show-calls).

### Parental controls and free communication

- **Symptom:** abort in `nn::sm::Initialize` under `nn::pctl::IsFreeCommunicationAvailable` (Engage, entering its first battle map).
- **Cause:** the SDK connects to the parental-control service through `sm`.
- **Fix:** the host answers it like the other free-communication calls: not available (`hle_misc.c`). `pctl::CheckFreeCommunicationPermission`: never.
- **Found on:** [Fire Emblem Engage](../../dm/games/0100A6301214E000/README.md); [DRAGON QUEST XI S](../../dm/games/01006C300E9F0000/README.md) (`CheckFreeCommunicationPermission`).
- **Note:** `pctl::CheckStereoVisionPermission` is under [Applet resource user ID, launch parameters and VR mode](#applet-resource-user-id-launch-parameters-and-vr-mode).

### Network interface, LDN, socket and play report calls

- **Symptom:** play report calls met entering the save select (3D World); undefined `nn::ldn::` / `nn::socket::` imports with no hook, found from the import list before they were met (Big Brain Academy).
- **Fix:** hooked (`hle_net.c`, `hle_offline.c`): the `nifm` IP queries with SDK 10's `socket::InAddr` / `in_addr` mangling; `prepo::AddSessionId` / `AddInternetConnectionStatus`; `ldn::GetNetworkConfig`; SDK 11's socket overloads with plain `sockaddr` / `int` arguments (`Connect`, `Accept`, `GetSockName`, `Get` / `SetSockOpt`, `Fcntl`, `Recv`, `Send`).
- **Found on:** [Super Mario 3D World + Bowser's Fury](../../dm/games/010028600EBDA000/README.md) (SDK 10: `nifm`, `prepo`); [Big Brain Academy: Brain vs. Brain](../../dm/games/0100620012D6E000/README.md) (SDK 11.4.3: LDN, sockets).

### Network requests stay on hold before they settle

- **Symptom:** the boot sits at a black loading screen for good, CPU nearly idle, every thread waiting, about 1 boot in 6 (3 in 4 with four Mac hosts at once); the title movie is never opened, and the save files are never probed.
- **Cause:** a race the host's instant offline answers lost. The game's boot state machine (`main+0x1f2f0e0`, state at `this+0xd4`, found by probing the save probe's call stack and dumping the state each tick) stayed in state 7, which polls the status word (+0x14) of the game's BCAT news runnable ("OlimarMemo") for 0, 4, 5, 6 or 7; it read 1. The runnable's constructor (`main+0x203f3b0`) clears the status, starts `FBCATThread` and only then stores 1; the thread's `Run` (`main+0x203f510`) stores 2, calls `nn::nifm::SubmitNetworkRequest`, sleeps while `IsNetworkRequestOnHold`, and stores 6 when `IsNetworkAvailable` is false. On a Switch the request stays on hold while the nifm service evaluates it, so the constructor's 1 always comes first; the host answered "not on hold" at once, and a thread that ran before the constructor's store finished at 6, which the 1 then overwrote.
- **Fix:** a submitted request is on hold for the first `IsNetworkRequestOnHold` after the submission and settled as unavailable at the next (`hle_net.c`). On Horizon each query is an IPC to the nifm service, which evaluates the request as it serves them, offline a rejection; Pikmin 4 sleeps 10 ms between its queries, so the constructor's store always comes first.
- **Note:** the first fix held the request for 50 ms of host time. A game that bounds its wait by the number of queries never saw that end: Hades' `NetworkPollThread` (`main+0x27aaa0`) yields between queries and cancels after 2,000 (2,000 IPCs on a Switch, 0.1 ms here), then submits again at once, which kept a host core busy (1.17 billion queries a minute; with [A wait at two yields is not progress](threads.md#a-wait-at-two-yields-is-not-progress), 216,000 yields and half the CPU). Its stamp, `now_ns() | 1`, also read as settled whenever the next query came within the same 42 ns tick of the Mac's clock: 30% of Hades' submissions, and 42% back to back.
- **Found on:** [Pikmin 4](../../dm/games/0100B7C00933A000/README.md) (Unreal Engine 4.26.2); [Hades](../../dm/games/0100535012974000/README.md) (the 50 ms hold).
- **Check:** 12 of 12 boots with four hosts at once reached the title, with both fixes; a host that answers at once hung 1 of 4 in the same test.
- **Note:** how it was found: the hung boots' logs diverged from good ones at the save probe (`DM_FS=1`), the thread dumps showed nothing but idle waits, and `DM_PROBE` on the state machine, then `peek` lines in a hung run's `DM_CTL` file, followed the pointers to the status word (a probe on the hot path slowed the boot enough to hide the race: 8 of 8 good).

### Socket `Poll` and `Select` with nothing to wait on

- **Symptom:** one thread at 100% CPU from boot, with one SVC in 99 s (`NexusRevolution Socket`, `main+0x92c7c4`, the game's network thread).
- **Cause:** it calls `nn::socket::Poll(fds, 0, 33)`: no descriptors and a 33 ms timeout, which on hardware is a 33 ms sleep. The host failed every socket call at once, so the thread spun 11,000 times a second (88,000 hits of a probe in 8 s).
- **Fix:** `Poll` and `Select` with nothing to wait on (no descriptors, or only negative ones, which POSIX ignores) now wait out their timeout and return 0, in every mangling the host takes over, including SDK 4's `Select(int, fd_set*, …, timeval*)`; an endless timeout returns 0 after 100 ms, since a thread inside a host hook pauses for IL2CPP's collector only once the hook returns (`hle_net.c`, `dm_guest_sleep_ns` in `hle_thread.c`).
- **Found on:** [DARK SOULS: REMASTERED](../../dm/games/01004AB00A260000/README.md) (SDK 4.5.0; one boot). Guest CPU fell from 1,030 to 60 ms per second.

## Settings, languages and fonts

### Language codes

- **Symptom:** the first comparison in `nnMain` aborted in `sm`.
- **Fix:** hooked: `settings::LanguageCode::Make` and the reversed `operator==(LanguageCode, Language)`.
- **Found on:** [Super Mario 3D World + Bowser's Fury](../../dm/games/010028600EBDA000/README.md) (SDK 10).

### Chinese language aliases in settings comparisons

- **Symptom:** `DM_LANG=zh-Hans` or `zh-Hant` reaches the game unchanged, but its startup menu falls back to Japanese; the older `zh-CN` or `zh-TW` spelling selects Chinese.
- **Cause:** Odyssey 1.4.1's language selectors (`main+0x977b30`, `main+0x977d30`) compare the desired code through `settings::operator==(LanguageCode, Language)` with only the deprecated `Language::Chinese` (6) and `Taiwanese` (11) entries, never `SimplifiedChinese` (15) or `TraditionalChinese` (16); its control data lists Simplified and Traditional Chinese, which the NSP script spells `zh-Hans` and `zh-Hant` (it turns `zh-CN` and `zh-TW` into those too). The real operator compares bytes with `MakeLanguageCode`, so on the console the system must hand this game `zh-CN` / `zh-TW`; the host compared bytes the same way with `DM_LANG`'s spelling, so `zh-Hans` did not match `zh-CN` and `zh-Hant` did not match `zh-TW`.
- **Fix:** both settings equality hooks share an alias-aware comparison (`hle_sdk16.c`): Simplified Chinese's two spellings match each other, as do Traditional Chinese's. The scripts stay distinct; `GetDesiredLanguage`, `LanguageCode::Make` and the available language list keep their original codes and indices. No title-specific override. This stands in for the system's choice of spelling, whose rule per title is not known (open): a game that compares the code with its own strings, or looks up `zh-CN`'s index in the available list, still needs the exact spelling. A synthetic full matrix tests both operand orders, malformed codes and the unchanged list.
- **Found on:** [Super Mario Odyssey](../../dm/games/0100000000010000/README.md) (1.4.1, SDK 7.3.2; fresh-save Mac startup menus in Simplified and Traditional Chinese after the comparison fix).

### Available language codes and their count

- **Symptom:** abort in `sm::Initialize` under `nn::settings::GetAvailableLanguageCodes` (early in `nnMain`, `main+0x327888`); abort in `sm::Initialize` under `nn::settings::GetAvailableLanguageCodeCount()` (`main+0x117590`).
- **Cause:** Paper Mario asks for up to 32 codes and takes the index of `oe::GetDesiredLanguage`'s code in the list as its language. Catherine compares `LanguageCode::Make(0 … count − 1)` with `GetDesiredLanguage`'s code.
- **Fix:** the host lists the system's codes in `nn::settings::Language` order, the table `LanguageCode::Make` uses, and reports the count of that table (`hle_sdk16.c`).
- **Found on:** [Paper Mario: The Thousand-Year Door](../../dm/games/0100ECD018EBE000/README.md) (SDK 15.3.2, the codes), [Catherine: Full Body](../../dm/games/0100BF00112C0000/README.md) (SDK 8.2.1, the count; one boot).

### Region code from the language

- **Fix:** `oe::GetRegionCode` answers from the language: Japan, the Americas, Europe or Hong Kong / Taiwan / Korea.
- **Found on:** [Animal Crossing: New Horizons](../../dm/games/01006F8002326000/README.md) (SDK 20.5.4; found in `main`'s imports before the first boot).

### Shared font address: BFTTF header or bare TTF

- **Symptom:** the font engine runs on garbage; crash after the shared fonts load, looking up the "?" glyph (`main+0x6c73c0`, a font cache lookup returning null), with SDK 10's `ScalableFontEngine::LoadFont` failing with error 403 and `SetFont` with 301 on both stand-in fonts; or Japanese, Korean or Chinese text draws nothing in a Unity game while Latin text is fine (Patrick's Parabox's language menu showed three blank lines).
- **Cause:** consumers read the shared font differently.
  - The SDK's font engine calls `ScalableFontEngineHelper::Decode(ptr, size)`, which XOR-decodes in place unless the first word is the "already decoded" marker (LE `0x18029a7f`). So for a game that decodes it the system shared font must look like BFTTF: serve `marker + bswap(size ^ 0x49621806) + TTF` (`hle_sdk16.c`). Mario decodes the pointer and needs the 8-byte BFTTF header in front.
  - 3D World records shared fonts as type 0 (`main+0x975658`), calls no `ScalableFontEngineHelper::Decode` and hands the `GetSharedFontAddress` pointer straight to `LoadFont`, so the pointer must be the plain TTF. SDK 10 and older games all take the plain TTF.
  - Unity's Switch player hands the shared fonts straight to FreeType. In Patrick's Parabox (SDK 13) the game's one font (Jost, a Unity dynamic font) falls back to the OS fonts for those glyphs, and the player loads them from the shared fonts: `main+0x2390b0` maps the names `Switch_Font_STD`, `Switch_Font_CN_Simplified`, `Switch_Font_CN_Extended`, `Switch_Font_CN_Traditional`, `Switch_Font_KR` and `Switch_Font_NIN_Extended` to types 0–5 and hands `GetSharedFontAddress` / `GetSharedFontSize` straight to FreeType's `FT_New_Memory_Face` (`main+0x23b2e0`), as libnx homebrew does with the same pl offsets. The host gave every SDK 11+ game the 8-byte BFTTF header in front, so every face failed to open.
  - The SDK's `GetSharedFontAddress` is the shared memory base plus the pl service's offset, with no adjustment, and that offset points past the header (yuzu's pl service: "font offset and size do not account for the header"); Captain Toad (SDK 8) records its shared fonts as plain TTFs and calls `Decode` only for its BFTTF formats.
  - A game on a newer SDK can import `Decode` (and so get the header) yet hand the address straight to `LoadFont` the same way (The Legend of Zelda: Echoes of Wisdom 1.1.0, SDK 20.5.1: `main+0x8b37c` crashed at address 0x38).
- **Fix:** the host first decided by the SDK version alone (SDK 10 and older the TTF, SDK 11+ the header). Now the address is the header (marker form above) only for a game on SDK 11 or later whose `main` imports `nn::fontll::ScalableFontEngineHelper::Decode` (Wonder, Breath of the Wild, Tears of the Kingdom, Pokémon Legends: Z-A); every other game gets the TTF itself (`font_skip` in `hle_sdk16.c`, `dm_main_imports` in `loader.c`; the profile key `shared_font` overrides). The host's `LoadFont` takeover passes the TTF past the header whenever it is given the host's own BFTTF base, so the address form `font_skip` picks only matters to `Decode` and other readers (`hle_sdk16.c` `h_font_LoadFont`).
- **Check:** 3D World's case was found by probing the engine's error code after each call (`DM_PROBE` on the instruction after `GetError`).
- **Note:** of the games on hand, the ones that call `GetSharedFontAddress` without importing `Decode` are all Unity players (Engage, Ace Attorney Investigations Collection, Brain Memory Training Academy, Patrick's Parabox). To see which fonts a Unity game asks for, probe its name mapper's entry (`DM_PROBE=main:2390b0` on Patrick's Parabox 1.0.1; the function is the one `main` caller of `GetSharedFontLoadState`).
- **Found on:** [Super Mario 3D World + Bowser's Fury](../../dm/games/010028600EBDA000/README.md) (SDK 10, the plain TTF); [Super Mario Bros. Wonder](../../dm/games/010015100B514000/README.md), [The Legend of Zelda: Breath of the Wild](../../dm/games/01007EF00011E000/README.md), [The Legend of Zelda: Tears of the Kingdom](../../dm/games/0100F2C0115B6000/README.md), [Pokémon Legends: Z-A](../../dm/games/0100F43008C44000/README.md) (the `Decode` importers); [Patrick's Parabox](../../dm/games/0100E44016C22000/README.md) (the blank CJK text, 1.0.1); [Captain Toad: Treasure Tracker](../../dm/games/01009BF0072D4000/README.md) (SDK 8, plain TTFs); [Fire Emblem Engage](../../dm/games/0100A6301214E000/README.md), [Ace Attorney Investigations Collection](../../dm/games/010005501E68C000/README.md), [Brain Memory Training Academy](../../dm/games/0100F5D01DA3A000/README.md) (the other Unity players); The Legend of Zelda: Echoes of Wisdom 1.1.0 (no profile).

### Shared fonts requested all at once

- **Symptom:** abort in `nn::sm::Initialize` under `nn::pl::sharedresource::GetPlatformSharedResourceManager` (first thing in `nnMain`).
- **Cause:** the game asks for every shared font at once with `pl::GetSharedFont(int *, SharedFontData *, int, LanguageCode)` (`sdk+0x40f270`), not by type. `SharedFontData` is 0x18 bytes {u32 type, address, size}; the SDK adds the pl service's offsets, which point past each font's 8-byte BFTTF header, to the shared memory base, and the game hands each address straight to `ScalableFontEngine::LoadFont` (`main+0x501ff0`).
- **Fix:** the hook returns the six types in order with the stand-in TTFs past the header, whatever the profile's `shared_font` (`hle_sdk16.c`).
- **Found on:** [Rhythm Heaven Groove](../../dm/games/0100D9F01D474000/README.md) (SDK 21.4.0, one boot).

### Shared font load request

- **Fix:** `pl::RequestSharedFontLoad` is hooked (an SDK 20 call that reaches a service).
- **Found on:** [The Legend of Zelda: Breath of the Wild](../../dm/games/01007EF00011E000/README.md) (1.9.0, SDK 20.5.22).

### Nintendo-extension glyphs for button icons

- **Symptom:** controller-button icons in text show as `?`.
- **Cause:** those glyphs come from the system shared font's Nintendo-extension set (private-use code points; Mario's `GameMsg/Key.msbt` uses U+E0E0–E0F0 for A/B/X/Y/L/R/ZL/ZR/SL/SR/D-pad/+/−, U+E0AB–E0AE for D-pad directions, U+E090–E097 for stick arrows, U+E100/E101 for sticks).
- **Fix:** `dm/tools/make_ext_font.py` generates a stand-in `nintendo_ext.ttf` with those icons; the host serves it for shared-font type 5 (`DM_FONT_DIR` or `DM_SHARED_FONT_EXT`) and a desktop font for the other types.
- **Note:** to find which code points a title uses, scan the `TXT2` sections of its MSBT files for U+E000–F8FF.
- **Found on:** [Super Mario Bros. Wonder](../../dm/games/010015100B514000/README.md).

### Shared fonts on iOS

- **Symptom:** on a phone, `GetSharedFontLoadState` would report "not loaded".
- **Cause:** the macOS stand-in path (`/System/Library/Fonts/Supplemental/Arial Unicode.ttf`) does not exist on a phone.
- **Fix:** the iOS app ships `dm/font/standard.ttf` and `dm/font/nintendo_ext.ttf` (copied / generated by `build_ipa.sh`) and sets `DM_FONT_DIR`.
- **Found on:** every game on iOS (general).

## C library, time and random numbers

### Time zone rules, calendar conversion and the network clock

- **Fix:** hooked: `time::ToPosixTime` (host `mktime`), and `time::ToPosixTime` with an explicit rule (the host's zone, as for `ToCalendarTime`); `time::LoadTimeZoneRule` and the `ToCalendarTime` overload with a rule (the host's zone is used); `time::StandardNetworkSystemClock::IsAccuracySufficient` (offline: no). `time::GetDayOfWeek` is a pure computation and needs nothing.
- **Found on:** [13 Sentinels: Aegis Rim](../../dm/games/01003FC01670C000/README.md) (SDK 11, `ToPosixTime`); [Monster Hunter Rise](../../dm/games/0100B04011742000/README.md) (SDK 11, the rest); [Octopath Traveler 0](../../dm/games/01005270232F2000/README.md) (`GetDayOfWeek`); [Pokémon Legends: Z-A](../../dm/games/0100F43008C44000/README.md) (19.3.11, `ToPosixTime` with an explicit rule, found in the imports before it was met).

### Steady clock, clock snapshots and user clocks

- **Symptom:** SDK calls that reach the time service, each aborting in `sm::Initialize` (or found in the imports before they were met).
- **Fix:**
  - `time::StandardSteadyClock::GetCurrentTimePoint`: host monotonic seconds, fixed source ID; `GetSpanBetween` runs in `sdk` ([The Legend of Zelda: Breath of the Wild](../../dm/games/01007EF00011E000/README.md) 1.9.0, SDK 20.5.22).
  - `time::ClockSnapshot::CreateWithStandardSystemClock` and `CreateWithAdjustableSystemClock`: 0xD0 bytes, filled on the host from the steady clock, the user clock and the calendar; the network fields stay 0. The type byte at `+0xcd` is 1 for standard and 2 for adjustable snapshots (0 means uninitialized), as verified in [Tears of the Kingdom's SDK](../../dm/games/0100F2C0115B6000/README.md#services). The adjustable entry also dereferences the absent time-service session without a host take-over. `t_time` checks both registrations, guarded buffers, the adjustable calendar and location, and snapshot arithmetic. The adjustable crash and boot fix were reported for Tomodachi Life: Living the Dream in [PR #385](https://github.com/seedds/nxnative/pull/385); that gameplay report has not been repeated here.
  - The adjustable user clock (`time::AdjustableUserSystemClock::GetCurrentTime`, which the game's days follow) reads the time service's shared memory in the SDK (`MonotonicSystemClock::GetCurrentTime`, `sdk+0x4421cc`), which the host never maps, so it is the host's clock, as the user clock; `time::GetStandardSteadyClockCurrentTimePoint`, the free-function form of the steady clock ([Animal Crossing: New Horizons](../../dm/games/01006F8002326000/README.md) SDK 20.5.4, found in `main`'s imports before the first boot).
- **Found on:** [The Legend of Zelda: Breath of the Wild](../../dm/games/01007EF00011E000/README.md), [The Legend of Zelda: Tears of the Kingdom](../../dm/games/0100F2C0115B6000/README.md), [Animal Crossing: New Horizons](../../dm/games/01006F8002326000/README.md).

### Hooks whose return type did not match the SDK

- **Symptom:** a call the host answers reads as failed when it succeeded, or reads leftover register bits. Super Smash Bros. Ultimate refills the Spirit Board at every visit, since the elapsed time between two snapshots never reads as known.
- **Cause:** four take-overs declared another return type than the SDK's own function: `time::CalculateSpanBetween` returns bool (true when the span is stored), and the host returned a Result 0; `nifm::HandleNetworkRequestErrorResult` returns bool, and the host returned a Result whose low bit happened to be 0; `audio::AcquireAudioDeviceNotificationForOutput` and `pl::BeginVrMode` return a Result, and the host's were `void`. Checked in the `sdk` of SDK 12 to 20 (Metroid Dread `sdk+0x3ab540`, `+0x336210`, `+0x534a0`; Breath of the Wild `sdk+0x412970`).
- **Fix:** each returns what the SDK does: the span call 1 or 0; the network call 0 (not resolved, offline); the notification 0 the first time and 0x499 (already acquired) after; `BeginVrMode` 0xd08e, the SDK's own answer when `pctl::CheckStereoVisionPermission` refuses, which the host now does too, having no VR display (Breath of the Wild's options then stay 2D, as MacNativeGames found). `t_time` checks the span call's values.
- **Found on:** reported by MacNativeGames on [Super Smash Bros. Ultimate](../../dm/games/01006A800016E000/README.md) (the Spirit Board) and Breath of the Wild 1.6.0 / 1.9.0 (the VR option); the Spirit Board was not replayed here.

### `clock_gettime(CLOCK_REALTIME)` through the time source pointer

- **Symptom:** `std::terminate` (`Break` from `sdk+0x5bfa48`) at the first real-time read (right after the first-boot dialog, `main+0x3f3f68` → `system_clock::now()`).
- **Cause:** `clock_gettime(CLOCK_REALTIME)` calls through a source pointer (`sdk+0xb05010`) that `nntimeStartup` sets once `time::Initialize` succeeds: 1 = `nn::time::GetStandardUserSystemClockCurrentTimespec`, 2 = the adjustable clock's (`sdk+0x8e414`). Both asked the time service.
- **Fix:** they are host take-overs now (`hle_time.c`), and `system_clock::now()` works on any build.
- **Found on:** [Ace Attorney Investigations Collection](../../dm/games/010005501E68C000/README.md) (1.0.0.2, SDK 17.5.3).

### Guest clock reads wait while the app is in the background

- **Symptom:** after switching apps and back, one guest thread at 100% in a tight loop (`main+0x9abd0`, `x10 = 0`); the game freezes, picture still, sound on. Mac repro `DM_OE_SCRIPT=bg=1@20,bg=0@25`.
- **Cause:** the frame pacing measured a frame period of 0 (`main+0x5926a8`: the clock difference between two frames). The host freezes the guest clock in the background but its threads went on, so two frames read the same time.
- **Fix:** guest reads of the system counter (the `cntpct` gate, `svc GetSystemTick`) now wait while the app is in the background (`hle_os.c` `guest_clock_read_wait`); host work and the keyboard freeze ([The software keyboard blocks only its caller](#the-software-keyboard-blocks-only-its-caller)) keep the frozen clock.
- **Found on:** [Super Mario Galaxy 2](../../dm/games/0100FD8022DAA000/README.md) (one of two causes; the other is [Focus handling mode decides whether focus changes are notified](#focus-handling-mode-decides-whether-focus-changes-are-notified)).

### Cryptographically random bytes

- **Symptom:** abort in `sm::Initialize` under `nn::crypto::GenerateCryptographicallyRandomBytes` (Unicorn Overlord: `std::random_device` → the `sdk`'s own `getentropy` → `InitializeCsrng`; Z-A: the first call in `nnMain`, `main+0x1734b4`).
- **Cause:** the bytes come from the csrng service. The `sdk` defines `getentropy`, so the host's `getentropy` hook never sees the call, but the call into `nn::crypto` goes through the `sdk`'s PLT.
- **Fix:** an `HLE_FORCE` on it fills from the host's entropy stream, the same stream as `getentropy` (`hle_os.c`).
- **Found on:** [Unicorn Overlord](../../dm/games/010069401ADB8000/README.md) (SDK 16.2.4; one boot), [Pokémon Legends: Z-A](../../dm/games/0100F43008C44000/README.md) (19.3.11; one boot).

### `clock_gettime` is `nn::time`'s steady clock (SDK 22)

- **Symptom:** `libc++abi: terminating due to uncaught exception of type std::__1::system_error` (the arguments came out as rubbish, the format named the failure) once the game's own code ran, with `sdk+0x5f2e60` (`std::terminate`) and `sdk+0x66ad2c`/`sdk+0x66acc8` (`get_terminate`/`terminate`) in the backtrace.
- **Cause:** SDK 22's exported `clock_gettime` (`sdk+0xa1430`) accepts `CLOCK_REALTIME` and `CLOCK_MONOTONIC` and returns `ENOTSUP` for ids 2–11; both accepted ids jump through musl ifunc slots in the SDK's data (`sdk+0xba5018`, `sdk+0xba5020`) whose `R_AARCH64_GLOB_DAT` relocations bind `nn::time::GetAdjustableUserSystemClockCurrentTimespec`, `_ZN2nn4time41GetStandardUserSystemClockCurrentTimespecEP8timespec` and **`_ZN2nn4time37GetStandardSteadyClockCurrentTimespecEP8timespec`** (`sdk+0xb92298`). The first two were answered from [the CLOCK_REALTIME entry](#clock_gettimeclock_realtime-through-the-time-source-pointer); the steady one was not, so the SDK's shared-memory client ran, could not read the time service's page, and returned an error, which `std::chrono::steady_clock::now()` (`sdk+0x5f2e10`: `mov w0,#1; bl clock_gettime; cbnz w0` → `std::__1::__throw_system_error`) turned into the exception.
- **Fix:** `hle_time.c` answers `GetStandardSteadyClockCurrentTimespec` with the host's monotonic clock (`struct timespec` from `clock_gettime(CLOCK_MONOTONIC)`). The network-clock variants (`_ZN2nn4time44GetStandardNetworkSystemClockCurrentTimespecEP8timespec`, `_ZN2nn4time46GetAdjustableNetworkSystemClockCurrentTimespecEP8timespec`) are left unbound: none of the games seen reaches them, and the network clock is not accurate from the host anyway. To name such a failure, `hle_sdk16.c` takes `nn::diag::detail::VAbortImpl` (an assert, an uncaught C++ exception or an SDK check with a message): it logs `[diag] abort at <function>: <expression> (<file>:<line>) message format <format>` and then aborts as `AbortImpl` does. Only the format is printed: the host cannot expand a `va_list` the guest built.
- **Check:** with `DM_AUDIO=1`, a run to the first room has no `[diag]` line and the frame counter keeps advancing.
- **Found on:** [Well Dweller](../../dm/games/0100217023F6C000/README.md) (SDK 22.2.0), in `std::chrono::steady_clock::now()` called from GameMaker's frame-timing helper.

## Modules and symbols

### Host symbol indexes avoid repeated name scans

- **Symptom:** relocation repeatedly scans all HLE and forced-takeover entries, and named-stub reuse becomes quadratic as more imports are missing.
- **Cause:** module exports already had a name index, but `resolve_import`, `hle_implements`, `force_lookup` and stub reuse still searched their tables linearly.
- **Fix:** open-addressed name indexes store entry numbers. HLE duplicates retain the first entry; forced-takeover duplicates still abort. Stub insertion grows its index above half capacity and retains existing stub numbers. Resolution is serialized at startup and by the module write lock during runtime NRO loading; module string tables stay mapped across unload.
- **Found on:** [The Legend of Zelda: Breath of the Wild](../../dm/games/01007EF00011E000/README.md#found-on-this-game), reported in [PR #261](https://github.com/seedds/nxnative/pull/261).
- **Check:** `make -C dm/host/tests GAME=010015100B514000 symbols nro` covers collisions that wrap around the table, duplicate precedence/rejection, absent sections and names, counting-wrapper selection, all 4,096 stubs through growth and reuse at capacity, and NRO relocation/lifecycle. The symbol test also passes AddressSanitizer and UBSan. A local arm64 Mac synthetic 270-entry HLE table with 25% misses, Apple clang 21 at `-O1`, took 375–442 ns per linear lookup versus 15 ns indexed (25–29x; three runs of 360,000 lookups). This measures lookup cost, not overall game loading time; no new gameplay run here.

### Global symbol resolution in load order

- **Symptom:** a library's `free` rejects a pointer (`CentralHeap::Free` → `NotNMallocPtrError`).
- **Cause:** the game's `main` defines its own `operator new` / `delete` (Unity's memory manager) and `sdk` has a copy forwarding to `malloc` / `free`.
- **Fix:** symbols are resolved globally in load order (the first module's definition wins, also for a module's references to its own exports); only local / non-default-visibility symbols bind to the module itself (`loader.c`). The loader logs how many references bind to an earlier module.

### Undefined weak imports bind to 0

- **Symptom:** a weakly imported function the game calls although nothing defines it: an `UNIMPL` line, then an abort.
- **Cause:** the loader bound every undefined import to a named stub, so the address test the compiler emits for a weak symbol saw a function.
- **Fix:** an undefined weak symbol that no module defines and the host does not implement is now 0, as Horizon's rtld binds it (`loader.c`, logged as `undefined weak … bound to 0`).
- **Found on:** [Octopath Traveler 0](../../dm/games/01005270232F2000/README.md) (the `thread_local` init function `_ZTHN13LowLevelTasks5FTask10ActiveTaskE`).

### `nn::ro` and its port

- **Symptom:** crash in `nn::ro::InitializeWithPortName`.
- **Cause:** `nn::ro` connects to `ldr:ro`.
- **Fix:** take over `Initialize` and answer `LookupSymbol` from the loaded modules (`hle_ro.c`). Check the mangled names against the new title's imports: SDK 19's `LoadModule` takes one more bool (`_ZN2nn2ro10LoadModuleEPNS0_6ModuleEPKvPvmib`), so the hook for the older form did not catch it and the SDK's own code would have run.
- **Found on:** [Hades II](../../dm/games/0100A00019DE0000/README.md) (SDK 19's `LoadModule`).

### `ro::ProtectRelro` runs natively

- `nn::ro::ProtectRelro` (called from `main`'s DSO init), a new import of SDK 20, needs nothing: it runs natively on the host's no-op `SetMemoryPermission` / `SetMemoryAttribute`. Found on [The Legend of Zelda: Breath of the Wild](../../dm/games/01007EF00011E000/README.md) (1.9.0, SDK 20.5.22).

### Loading NROs with `ro::LoadModule`

- **Symptom:** the frame loop runs, but the game waits for code it loads itself (`ro::RegisterModuleInfo` / `ro::GetBufferSize` red lines; `main` imports 1,045 `lua2cpp::create_agent_*` functions, global, that no ExeFS module defines, bound to stubs at start).
- **Cause:** the fighters' code is 98 NROs inside `data.arc`, registered by `.nrr/cross2_*.nrr`. The SDK's own `LoadModule` (SDK 8.2.1 `LoadModuleInternal`, `sdk+0x347460`) uses the service only to map the image, then zeroes bss, relocates through rtld's module lists, calls the module's init and binds the variables of the modules loaded before; the host replaces rtld, so it takes over the whole call.
- **Fix:** the NROs are collected at pack time by the SHA-256s the NRRs list (`dm/tools/nro_collect.py`: loose files, the current files of an indexed archive, or a scan for stored and zstd-framed NROs; Smash's NRRs of older releases also register 666 superseded copies, which `data.arc` still holds and which are left out), rewritten like any module (`patch_nso.py` reads NROs: the flat image, segments at +0x20, build ID at +0x40) and listed in `<patched dir>/nro.tsv`. The host maps them all at start and keeps them out of symbol lookups; `LoadModule` finds one by the image's SHA-256, restores its data and bss (after the first load), relocates it against the modules loaded then in load order, binds the earlier modules' symbol relocations it defines (main's `lua2cpp` stubs), fills `nn::ro::Module` as the SDK does (+0 module, +8 state 1, +0x10 image, +0x18 buffer) and calls its `DT_INIT`; `UnloadModule` calls `DT_FINI` and binds every relocation that pointed into it again (`loader.c` "NRO modules", `hle_ro.c`). `GetBufferSize` returns the bss size from header +0x38 as the SDK does. The startup init pass must skip NROs (their init ran unrelocated and crashed). Only data is written at a load, so it works with code embedded in the iOS executable: `gen_embed.py` packs the NROs into three sections (`__dm_nro_x0`, `__DM_NRO_W`, `__dm_nro_x1`) and a table of their pieces (`__dm_nro_tab`), since a Mach-O file has at most 255 sections and three per NRO would pass it, and `map_image` maps an NRO from there (`loader.c` `nro_pieces`).
- **Found on:** [Super Smash Bros. Ultimate](../../dm/games/01006A800016E000/README.md) (13.0.5): it loads six NROs in its first 30 s and calls none of the stubs. Played on an iPhone.

### NRO tables sized from the manifest and snapshots taken on demand

- **Symptom:** `FATAL .../nro.tsv: more NROs than module slots (MAX_MOD 128)` before `nnMain` (GitHub issue [#372](https://github.com/seedds/nxnative/issues/372)); after increasing the capacity, startup eagerly copies several GB of inactive NRO data and bss.
- **Cause:** the host used fixed 128-entry module and activation tables. It also allocated and copied every NRO's full writable image at startup so reload could restore it, including initially zero bss.
- **Fix:** count the manifest once before loading and allocate both tables at their final size, preserving every `module_t` address. Keep each NRO's initialized data only when it is first loaded, before relocation and initialization. Reload restores that data and zeroes bss; unused NROs need no snapshot. The original NRO header supplies the initialized data size.
- **Found on:** [FINAL FANTASY X/X-2 HD Remaster](../../dm/games/0100BC300CB48000/README.md), 1,432 NROs plus three initial modules; 5,836 MB of writable data and bss versus 767 MB of initialized data across all NROs. Most effect modules stay inactive on a short route.
- **Check:** `make -C dm/host/tests GAME=01007BB017812000 nro` exercises manifest sizing, the last slot of a 1,435-slot table, load order, initialized-data restoration and zeroed bss after reload.

### Online SDKs in NROs are never loaded

- **Symptom:** `[EOS] Failed to create platform` (the game plays offline); `refused …: an online SDK (Epic Online Services), not loaded`; `refused an NRR that registers only online SDKs (1 hashes)`.
- **Cause:** Epic Online Services in an NRO (`rom:/nro/EOSSDK-Switch-Shipping.nro`, loaded with `ro::LoadModule`; `main` imports the `EOS_*` functions). Before the host loaded NROs, the imports stayed `UNIMPL` stubs and `EOS_Platform_Create` handed back a garbage handle; the game checks it and plays offline.
- **Fix:** the host now loads NROs ([Loading NROs with `ro::LoadModule`](#loading-nros-with-roloadmodule)), but never an online SDK, whatever the game: an NRO that exports `EOS_Platform_Create` is left out of the pack (`dm/tools/nro_collect.py` `ONLINE_SDKS`, a `refused` row in `nro.tsv`) and `ro::LoadModule` refuses it with one log line (`refused …: an online SDK (Epic Online Services), not loaded`), also by the export when an older `nro.tsv` has it. An NRR that registers only such modules fails `RegisterModuleInfo`, as every registration did before the host loaded NROs, so the game takes the path it took then. So both games behave as before: offline, local saves.
- **Found on:** [Absolum](../../dm/games/0100A83022A22000/README.md) (SDK 18.3.2, one boot each); [Hades](../../dm/games/0100535012974000/README.md): it never asks for the module (checked on 1.0.38233: `refused an NRR that registers only online SDKs (1 hashes)`, no `LoadModule`, its frames as before). Hades' `main` imports only EOS Auth, Connect and PlayerDataStorage, Epic-account cross-save the host cannot serve; the real SDK would at best fail its login and at worst wait on time-outs or contact Epic's servers, with an unknown risk to the player's account.
- **Note:** open question for the maintainer: always load, refuse online SDKs (as now), or decide per profile.

### GPU driver modules that are never loaded

- **Symptom:** `main` imports EGL (SDL3's GL support) and `vkGetInstanceProcAddr` (its Vulkan support), but the game renders with NVN (`FNA3D_Driver_NVN.cpp`).
- **Cause:** NVIDIA's OpenGL and Vulkan drivers (`subsdk1`, `subsdk0`) program the GPU through NvRm, which the host does not have.
- **Fix:** they are never loaded (`profile_guess.py` `GPU_DRIVERS`); the EGL imports stay unbound stubs that nothing calls.
- **Found on:** [Absolum](../../dm/games/0100A83022A22000/README.md) (FNA3D).

### Modules only the NROs import from

- **Symptom:** `UNIMPL _ZN5movie12SetAllocatorEPFPvmmS0_EPFvS0_S0_EPFS0_S0_mS0_ES0_`, `UNIMPL glslcInitialize`, then `UNIMPL _ZN5movie9ExtractorC1ENS_13ContainerTypeE` and a crash reading address 0x18 in an NRO (`pc=nro18+0x97f4`) as the first movie starts.
- **Cause:** the provisional profile loads a subsdk only when `main` imports something from it that the host does not supply. The survey extracts only the code modules, so the NROs in the RomFS were not looked at. Portal's `main` is a launcher with SDL; its Source engine NROs play the movies through NintendoSDK_movie (`subsdk2`, imported by `video_nx.nro`) and initialize and call GLSLC (`subsdk0`, imported by `materialsystem.nro` and `video_nx.nro`). Left out, their imports were bound to stubs, and the stub constructor of `movie::Extractor` left the object empty.
- **Fix:** once the rewrite stage has collected the NROs, the NSP script adds to a provisional profile every subsdk whose exports an NRO imports and that no loaded module, other NRO or host hook supplies (`profile_guess.py` `nro_modules`, written under a section `After the NRO collection`). NVIDIA's GPU drivers stay out, as above.
- **Found on:** [Portal](../../dm/games/01007BB017812000/README.md) (`modules main subsdk0 subsdk2 sdk`; `subsdk1`, NVIDIA's OpenGL driver, stays out).

### `ro::LookupModuleSymbol` for a name the module does not define

- **Symptom:** `[RED] ro::LookupModuleSymbol BuiltDebug: not defined in that module` once at boot; nothing goes wrong after it.
- **Cause:** the Source engine asks each module it loads for `BuiltDebug`, which only its debug builds define. `ldr:ro` fails such a lookup on Horizon too, and the game takes the failure as "release build".
- **Fix:** the host's answer was already Horizon's (a failure result). The line is no longer red when the module is a loaded one; a lookup in a module the host does not know stays red (`hle_ro.c`).
- **Found on:** [Portal](../../dm/games/01007BB017812000/README.md).

### IL2CPP common string table intact

- Not needed in the end: the tolerant common string table of pull request #15. [Ace Attorney Investigations Collection](../../dm/games/010005501E68C000/README.md) 1.0.0.2's `main` has the table intact at `main+0x46169ac`, 109 entries ending at `Hash128`.

### Code inherited from another title at fixed addresses

- **Symptom:** harmless on the build it was written for, silent memory corruption on any other.
- **Cause:** code that calls fixed module addresses. d2r-mobile's 3D render scale read a renderer pointer at `main+0x31e0848` and called `main+0x8582f0`; in Mario v0 that is the middle of a static initializer and only did nothing because the pointer happened to read 0.
- **Fix:** such code checks `module_t.build_id` now (written into `fixups.tsv` by the rewriter) and stays off on other builds.
- **Found on:** [Super Mario Bros. Wonder](../../dm/games/010015100B514000/README.md) (v0, code inherited from d2r-mobile).
