# DARK SOULS: REMASTERED (`01004AB00A260000`)

Update 1.0.3 (v196608; the base game v0 is not extracted), SDK 4.5.0, NVN API 53.313. FromSoftware's dantelion2 engine with Havok and FMOD (sound through one 6-channel AudioOut). Modules `main`, `subsdk0` (the SDK's movie library) and `sdk`. Plays on the iPhone at 60 fps and the game's normal speed (30 on the Switch) through two rewriter cuts.

On the Mac: the logos and the opening movie, the title (offline), the first-run Brightness, Options and Button settings, character creation with the name through the inline keyboard, the opening cutscene and the Undead Asylum cell (walking, the camera, pillaging the corpse), at 60 fps with music and sound; no red line but the conditional rendering note. About 1.6 GB resident in the Asylum, flat over three minutes.

## What it needs

| Setting | Where | Why |
|---|---|---|
| Frame limiter `mov w1,#30` → `#60` at `main+0x706fa4` | [`patches.py`](patches.py), `main` build `df3766a2…` | the render thread's CPU limiter sleeps out 1000 / fps ms; see [Frame rate](#frame-rate) |
| Frame update step `ldr s8,[x8,#0x6ec]` (1/30) → `ldr s8,[x8,#0x834]` (1/60) at `main+0x667904` | `patches.py`, `main` build `df3766a2…` | the frame update takes a fixed step: with the limiter cut alone everything ran twice as fast on the iPhone |
| `pad_layout full` | [`game.tsv`](game.tsv) | the 3D layout: the right stick turns the camera and the D-pad switches spells and items |
| `sys_resource 0x0` | `game.tsv` | the NPDM declares 0 MB of system resource: `IsVirtualAddressMemoryEnabled` is false, as on Horizon. The game sets a 3.10 GB heap (pool − used) |
| 4 GB layout: `mem_reserve 0x100000000`, `mem_alias 0x10000000`, `mem_stack 0x10000000`, `app_pool 0xCD500000` | `game.tsv` | the 4 GB layout of the games without virtual address memory |
| `mem_used 0x6e00000` (110 MB) | `game.tsv` | the rewritten modules (110 MB with `main`'s 51 MB bss) are larger than the default 64 MB of used memory the game takes off the pool for its heap |
| `shader_groups .bdt#=dvdbnd` | `game.tsv` | the shaders in the dvdbnd archives; see [Files and shaders](#files-and-shaders) |

No `render_cond`: `SetRenderEnableConditional` is drawn unconditionally, as in Big Brain Academy; nothing seen looked wrong.

## Frame rate

- **Current: 60 fps** (30 on the Switch). The game presents at interval 1, yet every frame took exactly 33.3 ms of "frame work". The cap is the render thread's own limiter (`HGCommandDispatcher`, `main+0x8a4b28`): `main+0x707090(this, fps)` sleeps out 1000 / fps ms less the time since its last call (`nn::os::GetSystemTick`), when more than 2 ms are left; the main thread waits for the render thread. The 30 is a constant at the only call (`main+0x706fa4`), which the first cut makes 60. Found from the render thread's backtrace in the thread dump, not from the NVN calls. The limiter's frame-skip mode only starts above 36.4 ms a frame, so 60 does not reach it.
- **Resolved: twice the game's speed on the iPhone.** The game does not step by the time that passed: the main thread's frame update (`main+0x6a337c`, on the manager at GOT `0x2287be0`) takes a fixed step, the float 1/30 at `main+0x167a6ec`, loaded at `main+0x667904`. The second cut loads the 1/60 that rodata holds at `main+0x167a834` instead; the community's 60 fps cheat for this build changes the same two words. A 0.8 s walk that looked the same at 30 and 60 fps on the Mac had been taken for a time-based game. Some 20 other loads of that 1/30 turn parameters counted in 30 fps frames into seconds or step single systems; they stay. Probing every site that loads such a constant (`DM_PROBE`, 16 per run) tells per-frame steps from one-off conversions, but which of them sets the game's speed only shows by timing the game.
- **Resolved: stalls of 30–60 ms about once a second, at 30 fps and at 60** (in the Asylum cell: 99th percentile 63–127 ms). The thread that acquires the window (here the render thread) runs under a time-constraint policy whose computation the host re-declares every 120 frames; it was 1.25 × the 90th percentile of that thread's CPU time per frame. This render thread needs 1.9–2.0 ms a frame with one or two frames in 120 near 4.4 ms, against 2.5 ms declared, and each frame past the declaration stalled the thread. Probes on both threads' waits showed the main thread waiting 20–34 ms for the render thread once a second; adding probes slowed the render thread and the stalls vanished, and `DM_RT=0` or a fixed `DM_RT_COMP=5` / `10` removed them too (99th percentile 18–21 ms) at the same CPU energy. The declaration now also covers 1.1 × the window's peak (`rt_comp_tick` in `hle_nvn.c`): 5.6 ms here, 60.0 fps, 99th percentile 21 ms.

## Rendering

FromSoftware's engine draws forward into a 1920x1080 RGBA16F target, with depth of field, light shafts and bloom at quarter size.

- **Resolved: distant walls and floors smeared sideways.** The map materials (`FRPG_Phn_*Lit*`) read their combined texture / sampler handles from a uniform buffer (`fp_t_cb13_*`, resolved at replay by `ubo_handle`), and the game keeps 12 sampler pools of 2,304 entries, each with its own samplers under the same IDs (ID 261 is clamp-to-edge with LOD 0..0 in one pool, repeat with mips in others), one per command buffer that records the scene. The replay resolved uniform-buffer handles in the first pool, so the walls' tiling base textures (u ≈ −3.45) took a clamp-to-edge sampler and repeated their edge column across the wall. The replay now keeps the texture and sampler pools bound (`OP_SET_TEX_POOL` / `OP_SET_SAMP_POOL`) and adds their bases to handles read from uniform buffers (`ubo_tex_id` / `ubo_samp_id` in `nvn_mtl.m`). Found by highlighting the six most common fragment shaders of the scene pass (`DM_NVN_HILITE`), then the next six, and reading the wall draw's binding lines (`DM_NVN_PASSDUMP_ALL`).
- **Resolved: 6,734 red lines in one run.** The list of command buffers that bound a non-first pool had 64 entries and was never cleared, and this game binds a non-first pool in more than 64. The bases of bound handles now live in each command buffer (`cmd_t` `tex_base` / `samp_base`).

## Files and shaders

- RomFS is two dvdbnd archives, `dvdbnd0.bdt` and `dvdbnd1.bdt` (3.6 GB), which the game reads itself, each indexed by the `.bhd5` beside it: `BHD5`, 0xff (little-endian), u32 1, u32 file size, u32 bucket count, u32 0, u64 bucket table offset; each 16-byte bucket `{u32 count, u32, u64 offset}` points at 16-byte entries `{u32 path hash, u32 size, u64 offset}` (paths only hashed).
- 5,184 entries are DCX containers (`DCX\0`, big-endian header, `DFLT` = a zlib stream at +0x4c), most of them BND3 archives (28-byte entries `{u8 flags, i32 size, u64 offset, i32 ID, u32 name offset, i32 unpacked size}` in formats 0x5c / 0x7c). Only archives that contain a GLSLC magic are parsed (the others use format 0x78).
- **Current:** 3,099 shaders (391 vertex, 2,708 pixel), GLSLC outputs: 3,040 in six BND3 archives in `dvdbnd0.bdt`, one per entry (`.vpo` vertex, `.fpo` pixel, named `Shader/FRPG_Sfx/NVNShaderBinary/ps/…` or by base name in the two FLVER material archives, 2,602 + 486 entries), and 59 more in `main`. `shader_split.py` reads them with `bhd5_entries`, `undcx`, `bnd3_members` and `bdt_shaders`, in 64 jobs by entry range, about 10 s. Single-stage programs, as in 13 Sentinels; every binding decodes.
- **Resolved: SDK 4's GLSLC outputs** (version 0x20.4). Pixel shaders' control sections store at +0x20 a value 12 bytes short of their length, so the code area is not right after it, and 44 of `main`'s 72 outputs and most of the archives' pixel shaders failed the reader's check. `glslc_section` reads such outputs through their own section headers. It also gave Three Houses 8 and Age of Calamity 3 shaders that used to be dropped.

## Movies

- `subsdk0` is the SDK's movie library: its `movie::Extractor` demuxes the H.264 MP4 movies (`movww/`, `movjp/`) and the host decodes them into the game's RGBA texture (a native-texture movie, as in Monster Hunter Rise).
- **Resolved: a call through a null pointer in the host's `movie::Decoder::Configure` right after `nnMain` starts the logos.** SDK 4's `Decoder` constructor has no priority argument (`_ZN5movie7DecoderC1ENS_11DecoderTypeENS_19DecoderOutputFormatENS_11DecoderModeE`); the host took over only the four-argument one, so the SDK built its own decoder and the host's `Configure` read that object as its own. Both forms are taken over now (`hle_movie.c`).
- **Resolved: `FATAL movie: missing SDK symbol _ZNK5movie6Buffer10GetNvnSyncEv`** at the first frame of the movie. SDK 4's `movie::Buffer` carries the texture object but no sync object. The lookup is optional now; the game reads the texture once `GetOutputBuffer` returns, which the CPU write satisfies.

## Services

SDK 4.5.0 boots, one each:

- **Resolved: abort in `sm::Initialize` under `nn::friends::GetBlockedUserList`** after the opening movie: SDK 4's overload without the `Uid` (`EPiPNS_7account23NetworkServiceAccountIdEii`). It reports an empty list with success: the game turns a failure into an error for the error applet (`main+0x8ff9f0`).
- **Resolved: crash in `lmem::AllocateFromExpHeap` under `ngc::ProfanityFilter::MaskProfanityWordsInText` right after the character name is entered.** The game calls the UTF-16 overload (`EPiPtj`) by name; the host had taken it over only in the filter's vtable, so the SDK's version ran on a filter whose word list the host never loaded. The `unsigned short` and `char16_t` overloads are taken over by name too (`hle_misc.c`).
- **Resolved: one thread at 100% CPU from boot, with one SVC in 99 s** (`NexusRevolution Socket`, `main+0x92c7c4`, the game's network thread). It calls `nn::socket::Poll(fds, 0, 33)`: no descriptors and a 33 ms timeout, which on hardware is a 33 ms sleep. The host failed every socket call at once, so the thread spun 11,000 times a second (88,000 hits of a probe in 8 s). `Poll` and `Select` with nothing to wait on now wait out their timeout and return 0, including SDK 4's `Select(int, fd_set*, …, timeval*)` (`hle_net.c`, `dm_guest_sleep_ns` in `hle_thread.c`). Guest CPU fell from 1,030 to 60 ms per second.

## Input

- The game maps its buttons by position: B confirms, A goes back (its prompts say so); menus that seem to ignore A are not a host fault.
- The first boot shows two notices before the title menu ("Unable to connect to the network", then "Game will start in offline mode"), and a new game first walks through Brightness, Options and Button settings.

## Mac routes

- From a fresh save, `DM_KBD=Ash DM_KEYS="20:A~0.2,25:Plus~0.2,40:A~0.2,50:A~0.2,60:A~0.2,70:B~0.2,80:Down~0.08,82:B~0.2,90:Up~0.08,92:B~0.2,100:Down~0.08,102:B~0.2,110:B~0.2,116:B~0.2,122:B~0.2*15/3,168:Left~0.1,170:B~0.2,185:Plus~0.2,190:B~0.2,200:Plus~0.2,210:B~0.2"` goes through the two network notices, New Game, the first-run settings, character creation (a Warrior with the default look) and the opening into the Asylum cell (control at about 245 s). The steps are in seconds, not frames: the loads take different frame counts from run to run.
- From a save made there, `DM_KEYS="20:A,25:Plus,40:A,50:A,60:A,70:B,76:B,82:B"` continues into the cell at about 90 s.

## Found on this game

General host changes first needed here; each applies to every game:

- **SDK 4's GLSLC outputs read through their section headers** (`glslc_section`) and **uniform-buffer handles resolved against the bound pools** (`OP_SET_TEX_POOL` / `OP_SET_SAMP_POOL`, `ubo_tex_id` / `ubo_samp_id`, `cmd_t` `tex_base` / `samp_base`): [GLSLC outputs read through their section headers](../../../docs/reference/shaders.md#glslc-outputs-read-through-their-section-headers), [Handles from uniform buffers take the bound pools' bases](../../../docs/reference/shaders.md#handles-from-uniform-buffers-take-the-bound-pools-bases), [Bases of bound handles kept in the command buffer](../../../docs/reference/shaders.md#bases-of-bound-handles-kept-in-the-command-buffer).
- **The dvdbnd / DCX / BND3 reader** (`bdt_shaders`): [GLSLC outputs in FromSoftware's BND3 and dvdbnd archives](../../../docs/reference/shaders.md#glslc-outputs-in-fromsoftwares-bnd3-and-dvdbnd-archives).
- **SDK 4's movie decoder constructor and its buffer without a sync object** (`hle_movie.c`), **`friends::GetBlockedUserList` without a `Uid`**, **the UTF-16 profanity masking by name** (`hle_misc.c`), and **`Poll` / `Select` with nothing to wait on sleeping out their timeout** (`hle_net.c`): [SDK 4's `movie::Decoder` constructor without a priority](../../../docs/reference/movies.md#sdk-4s-moviedecoder-constructor-without-a-priority), [SDK 4's `movie::Buffer` has no sync object](../../../docs/reference/movies.md#sdk-4s-moviebuffer-has-no-sync-object), [SDK 4's `friends::GetBlockedUserList` without a `Uid`](../../../docs/reference/services.md#sdk-4s-friendsgetblockeduserlist-without-a-uid), [`nn::ngc::ProfanityFilter` vtable and by-name overloads](../../../docs/reference/services.md#nnngcprofanityfilter-vtable-and-by-name-overloads), [Socket `Poll` and `Select` with nothing to wait on](../../../docs/reference/services.md#socket-poll-and-select-with-nothing-to-wait-on).
- **The real-time declaration covering the window thread's peak frames** (`rt_comp_tick` in `hle_nvn.c`): [Time-constraint computation declared below the thread's peaks](../../../docs/reference/frame-rate.md#time-constraint-computation-declared-below-the-threads-peaks).
- [The alpha test through a library of its own](../../../docs/reference/rendering.md#the-alpha-test-through-a-library-of-its-own): grass, ferns and tree leaves came out as solid quads (Firelink Shrine, Darkroot Garden), reported with an implementation of its own on PR #32.

## Open

- Check the foliage with the host's alpha test (reported fixed on PR #32 with another implementation).
- Climbing ladders still misplays at 60 fps (with the community's cheat too).
- Once, loading a save on the iPhone stayed on the loading screen (no save write, no red line); the next launch loaded it, and it has not come back.
- SDK 4.5.0 is called "the oldest so far" in `game.tsv`, the bring-up notes and `AGENTS.md`, while Mario Kart 8 Deluxe ([0100152000022000](../0100152000022000/README.md)) is SDK 4.4.0, also called the oldest.
- [shaders.md](../../../docs/reference/shaders.md#glslc-outputs-read-through-their-section-headers) speaks of `main`'s 72 GLSLC outputs (44 of which failed the old check), `game.tsv` of 59 shaders in `main`; the sources do not say how the two counts relate.
