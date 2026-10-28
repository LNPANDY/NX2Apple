# FINAL FANTASY CRYSTAL CHRONICLES Remastered Edition (`0100CE4010AAC000`)

Update 1.0.3 (v196608) over the base cartridge (v0 = 1.0.0, whose control data says display version 1.0.1), SDK 8.2.1. Unity 2018.4.2f1 IL2CPP with FMOD, on NVN. Modules `main`, `subsdk0` (the movie module) and `sdk`. Brought up on the Mac on 2026-10-25: boot, intro movies and in-engine cutscenes, title, the village, field and dungeon play with Mog carrying the chalice, at 30 fps. Not tried on an iPhone; an IPA has not been built and its size is not yet measured. The Mac app (`--platform mac-app`) is 5.34 GB (RomFS 3.9 GiB and Mac shader libraries 1.1 GiB); the README gallery picture is a Mac frame of field play (2026-10-26).

Build IDs (first 16 hex digits, as cheat files name them): 1.0.0 `DF154E1D08E39646`, 1.0.1 `687AB956C7A3914B`, 1.0.2 `1369AD3EA91E2C40`, 1.0.3 `E1D8B399B787AE41` (the version table of [switch-cheats-db](https://github.com/HamletDuFromage/switch-cheats-db/blob/master/versions/0100CE4010AAC000.json)). Only 1.0.0 and 1.0.3 were on hand.

## What it needs

| Setting | Where | Why |
|---|---|---|
| ThreadedStreamBuffer cuts (8 per build) | [`patches.py`](patches.py) | without them the boot deadlocks in 3 of 5 runs: [Unity's stream buffer handshake loses a wake-up on Apple cores](../../../docs/reference/threads.md#unitys-stream-buffer-handshake-loses-a-wake-up-on-apple-cores) |
| the profile's other keys | [`game.tsv`](game.tsv) | the provisional profile's static guesses (`build_ipa_from_nsp.py` / `profile_guess.py`), unchanged: they boot and play |
| default present interval (30 fps) | none | the game logic counts frames: see [Frame rate](#frame-rate) |

`dm/tools/sdk_patches.py` has no cut for its `sdk` build (`5fd4f531c1195e9e5510c9e73f22cd39`).

## Code

- **Rewriter: a jump-table form of its own.** `main+0x2d103cc` and `+0x2d10590` (1.0.0) index an offset table with a register masked in the block that branches in (`and x6,x17,#0x7ff; …; cbz w18,L`), while the bounds check in the dispatch block masks the same source again (`L: and w18,w17,#0x7ff; cmp w18,#3; b.hi`). `jump_masked_pred` in `dm/tools/patch_nso.py` resolves it, tried only after every older form has failed.
- **The freeze.** All guest threads asleep on condition variables before the first frame; the main thread in `AcquireSemaphore` after posting a command to `UnityGfxDeviceWorker`, the worker one wait later. The cause is a store-release followed by a plain load in Unity's `ThreadedStreamBuffer` sleep handshake (details and the fix in the threads reference above). To carry the 8 sites to another build, match ±24 instructions around each with PC-relative immediates masked: each 1.0.0 site had exactly one match in 1.0.3, all moved by +0x25380. [`patches.py`](patches.py) holds only the registered 1.0.3 build; for a base-cartridge (1.0.0, main `df154e1d08e3964689eecef47fc057e6`) build, the same `ldr` → `ldar` cuts go at `main+0x1e426d0`, `0x1e43028`, `0x1e43118`, `0x1e4319c`, `0x1e42cdc`, `0x1e42dd4`, `0x1e42e58` (`080140b9` → `08fddf88`) and `0x1e43448` (`290140b9` → `29fddf88`), in a provisional profile's `patches.py`.

## Files and shaders

- The game's own maps and effects use 1,207 shaders kept as whole GLSLC outputs in the TextAsset `shader.switch.vfxsb` of `Data/resources.assets`, not in Unity `Shader` objects. Before `shader_split.py` read Unity TextAssets the terrain drew with black holes and the log listed ~57 keys "not in the shader map": [GLSLC outputs in a Unity TextAsset](../../../docs/reference/shaders.md). The split gives 31,525 shaders for 1.0.3: 31,509 graphics shaders (1.0.0: 31,635) and the 16 compute kernels below.
- The 3 Unity 2018.4 `ComputeShader` objects (`EyeHistogram`, `Internal-BlendShape`, `Internal-Skinning`: 16 kernels) are read since `unityfs.py` carries the 2019.4 layout their type hash `1a95529a…` names (ecbeae1); no run has asked for one.

## Frame rate

- The game asks for present interval 2 (30 fps). `DM_PRESENT_INTERVAL=display` (60 fps) keeps the intro's timing (the title movie came at 105 s at 60 fps and 108 s at 30 fps) but **gameplay runs twice as fast**: the logic counts frames. A 60 fps patch would need the game's frame step found and cut (as Dark Souls Remastered's `patches.py`); none is published for any build.
- On an M2 Pro the GPU takes about 5.7 ms per frame in the village, well inside the 33.3 ms of a 30 fps frame.

## Mac routes

- Run with `DM_GAMES_DIR` unset (the profile is here) and `DM_ROMFS=<extract>/v196608/RomFS`. The intro reaches the title at about 105 s, the in-engine opening plays by itself.
- With lldb on the running game, ignore `EXC_BAD_ACCESS` / pass `SIGBUS` and `SIGSEGV` (the host's write-protection faults) and always detach (`-k "process detach"`); a debugger killed while attached takes the game with it ([05-debugging.md](../../../docs/agents/05-debugging.md)).

## Found on this game

General changes first needed here; each applies to every game:

- **Jump tables masked in the predecessor block** (`jump_masked_pred`, `dm/tools/patch_nso.py`).
- **`patches.py` of profiles in `DM_GAMES_DIR`** (a provisional profile can carry cuts; `patch_nso.py`, `build_ipa_from_nsp.py` `patch_files`).
- **Unity ThreadedStreamBuffer memory order:** [threads reference](../../../docs/reference/threads.md#unitys-stream-buffer-handshake-loses-a-wake-up-on-apple-cores).
- **GLSLC outputs in Unity TextAssets** (`unity_text_glslc`, `unityfs.text_assets`): [shaders reference](../../../docs/reference/shaders.md).

## Open

- The ThreadedStreamBuffer cuts for 1.0.0–1.0.2: only 1.0.3 is registered; the 1.0.0 sites are listed under [Code](#code). Function-matched cuts (`MATCH_CUTS`) once their fingerprints are checked on those builds.
- 60 fps: find and cut the frame step.
- iPhone: not tried; build an unsigned IPA and record its packaged size for the README gallery.
