# Super Mario 3D World + Bowser's Fury (`010028600EBDA000`)

Update 1.2.2 (v262144) over the base game, SDK 10.4.0. Nintendo EPD's engine (sead / agl, NintendoWare G3d / Ui2d / Vfx / Atk), a Wii U port, on NVN API 53. Modules `main` and `sdk`. Plays on the iPhone. The README lists its IPA at about 3 GB.

## What it needs

| Setting | Where | Why |
|---|---|---|
| `pad_layout full` | `game.tsv` | the 3D gamepad layout: the right stick turns the camera |
| 4 GB layout: `mem_reserve 0x100000000`, `mem_alias 0x10000000`, `mem_stack 0x10000000`, `app_pool 0xCD500000` | `game.tsv` | no system resource in the NPDM: the game uses `SetHeapSize` (`main`'s bss is only about 7 MB). 13 Sentinels' partition, "until measured" |

No `patches.py`, no `dm/tools/sdk_patches.py` cut for its `sdk` build (`204eaef8…`). `shared_font` and `device_api` are decided by its SDK 10, so no profile key sets them.

## Rendering

- **Resolved: daylight scenes washed out to white.** The game creates its deferred pre-lighting buffer (the G-buffer's fourth target, R11G11B10F) as a one-layer 2D array texture, and the lighting shader samples it as 2D. On Maxwell a non-array sample of an array texture reads layer 0; on Metal the type mismatch returned one fixed value for every read, so the whole picture got one pale ambient colour (bloom blew it out further). The host compares each binding's declared type (the reflection's `dtt`) with the texture and binds a compatible view (`tex_fit`). How it was found: a blit-based pass snapshot of that target showed a correct image while a lighting shader edited to output only that input showed a uniform colour, both resolving to the same Metal texture. Earlier suspects that turned out correct: fog, bindings, the 1D lookup tables, clear colours, the depth convention, the final sRGB view, blend states, GPU luminance readback. There is no tone-mapping pass: the final composite writes `scene + bloom` into an RGB10A2 target.
- **1D textures**: the material shaders sample 64×1 R32F lookup tables created as NVN 1D textures (filled with `WriteTexels`); NVN 1D and 1D-array textures are now one-row 2D / 2D-array Metal textures, since translated shaders never declare `texture1d`.
- **Targets the fragment shader does not write**: volume draws after the G-buffer (`50d813761ca3f1f9` and others) write only outputs 0 and 2, with blending and all channels enabled on targets 1 and 3. Pipelines now get a zero write mask and no blending for colour outputs the shader does not write (reflection `colors`, `color_known`).
- **Current (iPhone): solid magenta blocks in World 1-1.** The blocks are exactly (255, 0, 255), hard-edged, aligned to the 16-pixel grid (16×16, sometimes two stacked). `DM_NVN_MAGSCAN` on the A20 Pro found them first in the 1920×1080 RGB10A2 composite (`ser=30`), in the pass whose shader `66a71a3081b91b9a` renders into that texture while sampling it. They kept appearing with the sparkle particle `5e4de7561c670fee` dropped, so that earlier suspect is not the cause. Writing and sampling one attachment in a pass is undefined in Metal: the M4 Pro happens to return the old content, the A20 Pro now and then returns whole 16×16 blocks as (1, 0, 1), probably blocks of the compressed render target caught mid-write. The host ends the pass before such a draw, copies the attachment's level and layer into a snapshot texture and binds it for that draw (`fb_prepare`). The profile listed `66a71a3081b91b9a` and `30e3ccb0bd304ead` (which samples a G-buffer target of its own pass on the title screen) in a `feedback_snap` key; the host now finds such draws itself (those that write the attachment they sample), as in the same agl program on Captain Toad, Super Mario Odyssey and Origami King's anti-aliasing, and the key is gone. Not run again on this game, which this Mac does not have. A sampled view that spans more levels than the attachment's one is left as before: `3e8567da37eb28a1` renders level 1 of a texture while its view covers levels 0–4 (mip-chain passes).
- **Scaled copy when leaving the title** (1920×1080 → 1280×720, RGB10A2, flags `ENGINE_2D`, probably the captured frame for the transition): Metal blits cannot scale. 04's 3D World section lists it as skipped with a red line; its Link's Awakening section says `copy_t2t_draw` now covers this copy.
- Depth mode: it keeps NVN's GL mode (near = −w).
- Uniform updates inside a pass no longer end it: 5% less attachment traffic on the Mac.
- 11 compute and 1 vertex shader read the driver segment `c0`; it rendered the same after compute `c0` got the dispatch size.
- agl's post-effect program behind `66a71a3081b91b9a` appears in Captain Toad: Treasure Tracker as `54f58a7cab608766` ([01009BF0072D4000](../01009BF0072D4000/README.md)).

## Files and shaders

- RomFS is almost entirely Yaz0-compressed SARC (`*.szs`), which `shader_split.py` decompresses itself (`yaz0`, about 20–45 MB/s per core; the whole 4.7 GB decompressed RomFS scans in about a minute). One SARC, `SystemData/LayoutShader.szs`, is big-endian (BOM `FE FF`), which the SARC reader does not handle; it holds no shader container the game uses.
- 11,080 shaders: bfsha (BNSH) and agl sharcb (BAHS version 9) in `ShaderData/*.szs`, particle effects (BNSH, including 25 compute shaders) in `EffectData`, six layouts and `SystemData/AglResource.szs` (BAHS), and two BNSH in `main`. All bind with Mario's texture handle layout (`0x20 + 8 × slot`); the one failure is a geometry shader (fur fins, `RenderFinFur`), which Metal cannot express.
- SDK 10's shorter control sections: 2,888 of 0x850 bytes (its ShaderData bfsha and six layouts) and 0x848 in BAHS version 9, each followed directly by other data, so keys hash `min(0x880, control +0x20)` bytes (`ctl_len`, `keys_hash`).
- Its particle compute shaders start their instructions at code +0, with no `0x12345679` header.

## Services and SDK 10

- **Resolved: a null-pointer crash early in `nnMain`** (`main+0x759e08`: the device singleton `main+0x1a28ea0` still null): the game checks `nvnDeviceGetInteger(API_MAJOR / API_MINOR)` for major 53 and minor ≥ 313 (`main+0x711c88`) and quietly skips creating its device otherwise. The reported version now follows the SDK (`hle_nvn.c` `nvn_api`: 53.313 for SDK 10 and older). NVN 53 also brings `nvnQueueAcquireTexture`, `nvnSamplerCompare` and the debug group calls (no-ops).
- **Resolved: a crash after the shared fonts load, looking up the "?" glyph** (`main+0x6c73c0`): SDK 10's `ScalableFontEngine::LoadFont` failed with error 403 and `SetFont` with 301. The game records shared fonts as type 0 (`main+0x975658`), calls no `ScalableFontEngineHelper::Decode` and hands the `GetSharedFontAddress` pointer straight to `LoadFont`, so the pointer must be the plain TTF (`font_skip`). Found by probing the engine's error code after each call.
- SDK 10 calls that reach a service: `settings::LanguageCode::Make` and the reversed `operator==(LanguageCode, Language)` (the first comparison in `nnMain` aborted in `sm`), `account::ListAllUsers`, `oe::GetPerformanceConfiguration`, `oe::SetAlbumImageOrientation`, the `nifm` IP queries with SDK 10's `socket::InAddr` / `in_addr` mangling, `prepo::AddSessionId` / `AddInternetConnectionStatus` (entering the save select), and `vi::GetIndirectImageMemoryRequirement`.
- **Resolved: a null read in `applet::CreateLibraryApplet` under `swkbd::InlineKeyboard::Initialize`** (entering the save select after the character select): `hle_swkbd.c` takes over every inline keyboard entry that touches the applet; `GetImageMemoryRequirement` asks vi, hence the vi hook.
- **Resolved: SIGBUS inside a host hook (`snprintf` under `mount_ex` / `h_fs_MountSave`), then a hang**: the save thread has an 8 KB stack (CreateThread stack top `0x…9fe0`, fault `0x21a0` below it), and one file open took 6–7 KB of host stack. Every `hle_fs.c` hook now runs on the big host stack (`HLE_FORCE_BIG`).
- Bowser's Fury also uses `nvnTextureGetSwizzle` and `nvnTextureGetStorageClass`.
- Focus handling mode 3 (no focus notifications; the system suspends the game out of focus).

## Input and Mac routes

- After the title, a character select with four "L + R to join" slots: the game calls `hid::StartLrAssignmentMode` and waits for L and R pressed together on that screen (`L+R~0.5` while it is up; presses on the title before it are lost), then a character choice with A.
- On the game select, holding the stick right for a second (`7:LRight~1`) switches to Bowser's Fury.
- Map and level movement read the left stick only (`LLeft` / `LUp` / `LRight` / `LDown`).
- Into World 1-1 on a fresh save: `DM_KEYS=6:A,10:A,14:L+R~0.5,17:A*3/2,24:Plus*6/3,45:A*6/3,66:LUp~1,70:A,74:LRight~1,78:A,82:LLeft~1,86:A` (World 1-1 by frame ~6000).
- On the Mac, 3D World reaches World 1-1 and Bowser's Fury its open world (`game.tsv`).

## Found on this game

General host changes first needed here; each applies to every game:

- **Compatible texture views for a mismatched declared type** (`tex_fit`), **1D textures as one-row 2D**, **no writes to unwritten colour outputs** (`color_known`), **same-pass feedback snapshots** (`fb_prepare`, `DM_NVN_MAGSCAN`): [Compatible views for a mismatched declared texture type](../../../docs/reference/rendering.md#compatible-views-for-a-mismatched-declared-texture-type), [1D textures as one-row 2D textures](../../../docs/reference/rendering.md#1d-textures-as-one-row-2d-textures), [No writes to colour outputs the shader does not write](../../../docs/reference/rendering.md#no-writes-to-colour-outputs-the-shader-does-not-write), [Same-pass feedback read through a snapshot](../../../docs/reference/rendering.md#same-pass-feedback-read-through-a-snapshot).
- **SDK 10 control section lengths** (`ctl_len`) and **compute code without a header**: [Control sections shorter than 0x880 bytes](../../../docs/reference/shaders.md#control-sections-shorter-than-0x880-bytes), [Compute code with and without a header](../../../docs/reference/shaders.md#compute-code-with-and-without-a-header).
- **The NVN API version by SDK** (`nvn_api`, `device_api`), **plain-TTF shared fonts by SDK** (`font_skip`, `shared_font`), **the inline keyboard** (`hle_swkbd.c`), **file system hooks on the big stack** (`HLE_FORCE_BIG`): [The device's API version](../../../docs/reference/nvn-objects.md#the-devices-api-version), [Shared font address: BFTTF header or bare TTF](../../../docs/reference/services.md#shared-font-address-bfttf-header-or-bare-ttf), [The inline keyboard as a resident library applet](../../../docs/reference/services.md#the-inline-keyboard-as-a-resident-library-applet), [Host calls on small guest stacks](../../../docs/reference/memory.md#host-calls-on-small-guest-stacks).
- **Yaz0 SARC in `shader_split.py`**: [01, Compressed RomFS content](../../../docs/agents/01-extract.md#compressed-romfs-content).
- **`L+R` joins in `DM_KEYS`**: [Player join screens (`hid::StartLrAssignmentMode`)](../../../docs/reference/game-state.md#player-join-screens-hidstartlrassignmentmode).

## Open

- The magenta-block fix: 04 says it waits for a device run; the README lists the game as tested and playable on the iPhone.
- The scaled copy when leaving the title: 04's 3D World section says it is skipped, its Link's Awakening section says `copy_t2t_draw` covers it.
- The fur fin geometry shader (`RenderFinFur`) does not build.
- `game.tsv` still says "In bring-up" and its memory values "until measured".
