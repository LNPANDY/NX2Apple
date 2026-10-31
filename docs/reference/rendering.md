# Rendering

The replay on Metal (`dm/gfx/nvn/nvn_mtl.m`) and the Vulkan and OpenGL layers. Each entry: symptom, cause, fix, the games it was found on. The [symptom index](../agents/symptoms.md) lists every symptom.

## Textures and formats

### Null textures in diagnostic logs

- **Symptom:** clang reports null dereferences in `nvnWindowInitialize` and `clear_tex`; clearing a null texture crashes with `DM_NVN_PASSDUMP=1`.
- **Cause:** window initialization checked the texture count but logged the first texture's dimensions without checking its pointer. Clear replay tolerated a null texture but its pass dump unconditionally read the texture serial.
- **Fix:** check the first texture before logging its dimensions (`hle_nvn.c`) and log serial 0 for a null clear texture (`nvn_mtl.m`).
- **Found on:** clang static analysis ([issue #424](https://github.com/seedds/nxnative/issues/424)); synthetic null-texture tests, with no gameplay failure reported.

### Texture objects copied into command records

- **Symptom:** Metal aborts on a texture descriptor with an absurd size (`height (1869367126) greater than … 16384`).
- **Cause:** a command record kept a pointer to the game's `NVNtexture` and read it at replay. NVN commands do not depend on the API object once recorded.
- **Fix:** the host now copies the texture object into the record (`REC_SNAP` / `tex_snap` in `hle_nvn.c`: render targets, texture copies and clears). Replay rejects objects without the texture magic and sizes beyond Metal's limits, with a red line instead of an abort.
- **Note:** the first red lines name the call site and the object's first bytes. In Engage those bytes were 32-bit triangle indices, i.e. another write had already overrun into the texture object; that stopped once the alias region had address space left ([Size-aligned regions exhaust the alias address space](memory.md#size-aligned-regions-exhaust-the-alias-address-space)).
- **Found on:** [Fire Emblem Engage](../../dm/games/0100A6301214E000/README.md).

### New textures start as zero

- **Symptom:** a decoded movie stays black even though its YUV textures contain the picture; disabling its depth test makes it visible.
- **Cause:** Metal leaves a new texture's content undefined; a freshly mapped Switch memory pool reads as 0, and feedback effects (such as Mario's fountain wave simulation, [Metal 4 does not order operations inside one encoder](#metal-4-does-not-order-operations-inside-one-encoder)) never clear their state texture.
- **Fix:** non-packaged colour textures are zero-filled from a shared zero buffer when created (`tex_zero_fill`, batched with the uploads). Depth and stencil textures, including multisample textures, are cleared to zero in render passes in the same upload batch, for every level and slice. Upload-failure recovery tracks these destinations too.
- **Found on:** [Super Mario Bros. Wonder](../../dm/games/010015100B514000/README.md); [Pokémon Brilliant Diamond](../../dm/games/0100000011D90000/README.md): the opening movie's YUV conversion uses GEQUAL against a new 1920×1080 depth texture that the game never clears. Metal supplied depth 1, discarding the movie; zero initialization restores it without a shader override.
- **Check:** `t_clear_ds` poisons depth and stencil before calling the real initializer and checks both become zero; depth clear, stencil-view and upload-budget tests cover the related paths.

### Texture swizzle through swizzled Metal views

- **Symptom:** glyphs render as white boxes (the font atlas is `(1, 1, 1, R)`).
- **Fix:** `TextureBuilderSetSwizzle` / `TextureViewSetSwizzle` are applied with Metal swizzled texture views (NVN and Metal channel enums have the same values). The swizzle names components of the NVN format, which the format's own mapping finds in Metal's (`nvn_fmt_to_mtl`: alpha 1 for RGBX-type formats; red and blue swapped for the RGB565 family, but only in linear and buffer textures, which read guest memory in place: every other host texture holds Metal's order, [RGB565-family textures in Metal's channel order](#rgb565-family-textures-in-metals-channel-order)).
- **Note:** Metal makes a swizzled view read-only (usage 0x1), so an image slot gets the same view without the mapping (`img_fit`), and the on-chip read merge leaves a swizzled sample alone.
- **Found on:** [Super Mario Bros. Wonder](../../dm/games/010015100B514000/README.md) (the font atlas); The Legend of Zelda: Echoes of Wisdom's hearts (GitHub PR #66, the RGB565 red / blue swap).

### RGB565-family textures in Metal's channel order

- **Symptom:** RGB565, RGB5A1 or RGB5 textures sample with red and blue exchanged: smeared, banded rock, the shapes right and the colours wrong; or what the GPU cleared, drew or copied into such a texture reads back to the game, or samples, with red and blue exchanged.
- **Cause:** Metal has these formats only with red and blue exchanged (`B5G6R5Unorm`, `BGR5A1Unorm`; red at bit 11 or 10, the guest's at bit 0), and the host kept them in two orders: packaged textures (`NvPkg`) in the guest's, swapped when sampled, plain ones in Metal's, as Metal renders and clears into them. Every path that moved bytes from one to the other without converting exchanged the colours: the one-time fill of a plain texture (`tex_init_fill`), buffer → texture and texture → buffer copies, `ReadTexels`, a clear or a draw into a packaged texture, a texture copy between a plain and a packaged one, the readback of a copy into a packaged texture's storage.
- **Fix:** one order. Every host texture of these formats holds Metal's order; only guest memory holds the guest's, and bytes are converted where they cross (`rb_packed_shift`, from `nvn_fmt_to_mtl`'s swap): every upload is repacked on the CPU (`pkg_upload_`; these formats leave the GPU deswizzle), buffer ↔ texture copies exchange the fields on the GPU in the copy encoder (`rb_swap_gpu`: through a staging area of the frame arena into the texture, in place in the buffer out of it; the GPU may have written the buffer earlier in the submission), and `ReadTexels` and the readback into a packaged texture's storage exchange them on the CPU (`rb_swap_rows`). Clears, draws and texture copies then need nothing. Linear and buffer textures read guest memory in place: they keep the guest's order and the swap when sampled (`tex_by_id`), and copies into or out of them stay raw (`rb_copy_shift`).
- **Note:** a view of one of these textures in another format of the same size (RG8, R16) now sees Metal's order where it saw the guest's in a packaged texture; no game is known to make one. A linear render target of these formats is drawn in Metal's order into guest memory; not seen.
- **Check:** `t_view_swizzle` fills RGB565, RGB5A1, RGB5 and BGR565 textures from `CPU_UNCACHED` and `CPU_NO_ACCESS` pools through the real `tex_init_fill`, reads them on the GPU, draws into one texel and reads both again, and checks the guest storage is unchanged (379 checks). `t_readback` records the real commands for RGB565, RGB5A1 and RGB5: a buffer → texture copy sampled, copied back and read with `ReadTexels`; a Metal clear to red copied out and read; a packaged texture sampled, one with a texel cleared, one copied into from the cleared plain texture and read from its storage (78 checks, none failed). With the host before the fix, 18 of `t_readback`'s fail.
- **Found on:** [The Legend of Zelda: Tears of the Kingdom](../../dm/games/0100F2C0115B6000/README.md#rendering) (GitHub issue #183, the Depths' cave walls: their initial-fill RGB565 / RGB5A1 textures), found and checked in the game by the issue's reporters (M1 with 1.2.1, M4 with 1.4.3); the copy paths found reviewing that fix, checked by the tests only.

### `nvnTextureCompare` compares the channel mapping

- **Symptom:** dark boxes and cream cloud rectangles behind HUD prompts, a black stamina wheel and a black System menu background (layout captures).
- **Cause:** agl's layouts rebuild a capture texture on the same storage with a new channel mapping, and replace the registered descriptor only if `nvnTextureCompare` reports the two textures different. The host compared the description and the storage but not the mapping, so every rebuild was dropped.
- **Fix:** `nvnTextureCompare` compares the mapping too, an unset mapping counting as (R, G, B, A). `t_nvn` covers the comparison. From GitHub PR #6.
- **Found on:** [The Legend of Zelda: Breath of the Wild](../../dm/games/01007EF00011E000/README.md): panes tagged `CaptureOn` (about 140 layouts, e.g. `PaGuideKeySmoke_00`; user data `A8`, `CaptureScale` 0.5, `MultiFilter`) are drawn into a target, blurred at half size and copied into a capture texture that the layout's materials sample in place of the placeholder `FBLayout_00`. The game creates it with its per-format default mapping (one call site, `main+0xecb0bc`: R8 → (R, 0, 0, 1), RG8 → (R, G, 0, 1), and so on), then rebuilds it with the capture's own mapping: `main+0xf597dc` picks (1, 1, 1, R) for an `A8` capture (the material colour kept, the mask as alpha) and alpha 1 when the pane says `CaptureOutputAlpha` 255 (read at `main+0xf58e98`; an RGB10A2 capture then reads (R, G, B, 1)); `main+0xecacf0` stores the mapping and rebuilds the texture (`main+0xecabe8`), and `main+0xec33f0` replaces the descriptor only on a difference. The captures kept (R, 0, 0, 1), whose alpha is always 1: hard-edged dark boxes behind every prompt (the shadow pane `e6a88e12dbae9743`: black, alpha = capture alpha × vertex alpha 180/255) and rectangles filled with cream cloud (the glow `aa209f57b133e862`: alpha = min(cloud alpha, capture alpha)). Checked on the Mac by the PR's author (M4 Pro, unchanged shader libraries): green stamina, the purple noise meter and the game's own blurred System menu background. [Super Mario Odyssey](../../dm/games/0100000000010000/README.md): its layouts rebuild their captures through the same agl code (`main+0x982320` replaces the registered descriptor only if `nvnTextureCompare` reports a difference), so the fix covers them too.
- **Note:** before the cause was known, a profile key, `alpha_from_red`, listed the layout library's pixel shaders and bound such render targets through a view mapped (R, 0, 0, R). In BotW (all 26 pixel-shader variants, `main`'s BNSH at 0x1d83000) that fixed the alpha but zeroed green and blue, so tinted panes such as the stamina wheel came out black, and the System menu background (a capture with alpha forced to 1) stayed black. In Odyssey (all 26 layout pixel shaders, `main`'s BNSH at 0x132c000) it had turned the coin counters' solid white cards into the right shapes. With the comparison fixed it found no (R, 0, 0, 1) target on either game (the mapping a capture is rebuilt with replaces it, on the Mac and the iPhone alike), so the key and its host code (`tex_alpha_red`, DM_NVN_ALPHA_RED) were removed (c76f6798); Odyssey's note has the A/B runs.

### Texture views cached by texture and view parameters

- **Symptom:** `newTextureViewWithPixelFormat` takes a large share of the replay thread (45% in Age of Calamity) when a game registers textures into a ring of IDs before every bind.
- **Cause:** KTGL registers a texture into the next ID of a ring before every bind (`RegisterTexture`, `GetTextureHandle` and `BindTexture` counts are equal: 8,000 a frame in battle, up to 28,000 after the cutscene). Only 1 in 6 registrations repeated what the ID held, so the per-ID view (`treg_t.view`) was rebuilt for half of all binds.
- **Fix:** views are now also kept by texture serial and view parameters (4 per texture), checked against the current base texture on each hit, and dropped when the texture or its pool is finalized; a registration identical to what the ID holds keeps its view and the registration generation (`vc_get` in `nvn_mtl.m`).
- **Found on:** [Hyrule Warriors: Age of Calamity](../../dm/games/01002B00111A2000/README.md): 2,036 views were made in a 15-minute Mac battle run, 211 million reused; the replay before the cutscene went from 14.3 to 10.8 ms a frame.

### Compatible views for a mismatched declared texture type

- **Symptom:** daylight scenes washed out to white (every read of a texture returned one fixed value); `texture type mismatch` red lines.
- **Cause:** on Maxwell the sample instruction carries its own dimension, and a non-array sample of an array texture reads layer 0. On Metal a 2D array bound to a `texture2d` argument is a type mismatch, and every read returned one fixed value. 3D World creates its deferred pre-lighting buffer (the G-buffer's fourth target, R11G11B10F) as a *one-layer 2D array* texture, and the lighting shader samples it as 2D, so the whole picture got one pale ambient colour (bloom then blew it out further).
- **Fix:** the host compares each texture binding's declared type (the reflection's `dtt`) with the texture it resolves to and binds a compatible view: 2D array ↔ 2D, 2D array → cube / cube array, cube → 2D (its first face, the layer a non-array sample of a cube's six layers reads) (`tex_fit` in `nvn_mtl.m`, cached per texture-pool entry); any other mismatch is reported once.
- **Found on:** [Super Mario 3D World + Bowser's Fury](../../dm/games/010028600EBDA000/README.md). The cube → 2D view on [Atelier Ryza DX](../../dm/games/0100199023B2E000/README.md), whose draws leave cube textures in slots they read as 2D (`texture type mismatch … declares slot … as Metal type 2, texture ID … is type 5 (NVN target 8 …); bound as is`, up to five over the opening, the textures different in each run): the lines are gone and the field looks the same (0.3 % of pixels differ between the two hosts at the same frame, scattered particles and foliage). A Metal view of one cube face as 2D passes the API validation layer. What the Switch reads there was not measured; [ROMANCE OF THE THREE KINGDOMS 8 REMAKE](../../dm/games/0100C2A01A730000/README.md) has the same case in two vertex shaders, not run since.
- **Note:** how it was found: a blit-based pass snapshot of that target showed a correct, colourful image while a lighting shader edited to output only that input showed a uniform colour, and both resolved to the same Metal texture. Earlier suspects that turned out correct: fog, bindings, the 1D lookup tables, clear colours, the depth convention, the final sRGB view, blend states, GPU luminance readback. There is no tone-mapping pass in this game: the final composite writes `scene + bloom` into an RGB10A2 target.

### Compatible views made from the texture under a view

- **Symptom:** with `MTL_SHADER_VALIDATION=1`, `Invalid Metal usage: Texture is not resident` for a texture allocated in `tex_fit`; without validation those reads are undefined.
- **Cause:** Metal takes a view's residency from the texture it was made from. `tex_fit` made its view of the texture the binding resolved to, which is often a view itself (the view cache's, a level and layer range or a swizzle), so the new view hung under a texture that is not in the residency set although the texture under both is.
- **Fix:** `tex_fit` makes the view from the texture at the bottom of the chain, with the bound view's level and layer offsets, level count and swizzle (`t_tex_fit_root`).
- **Found on:** [The Legend of Zelda: Breath of the Wild](../../dm/games/01007EF00011E000/README.md): a 64x64 environment cube read from a 2D-array view, 7 draws in the outdoors frame replayed with `nvn_replay` under shader validation.

### 1D textures as one-row 2D textures

- **Symptom:** a type mismatch when a Metal 1D texture is bound to a shader's `texture2d` argument.
- **Cause:** translated shaders never declare `texture1d` (none of the five games' libraries did at the time).
- **Fix:** NVN 1D and 1D-array textures are created as one-row 2D / 2D-array Metal textures.
- **Found on:** [Super Mario 3D World + Bowser's Fury](../../dm/games/010028600EBDA000/README.md): the material shaders sample 64×1 R32F lookup tables created as NVN 1D textures (and filled with `WriteTexels`).

### Cube textures held as 6-layer 2D arrays

- **Symptom:** shaders that sample a cube texture as `texturecube_array` get a type mismatch.
- **Cause:** Metal can make a cube-array view only of a 2D-array base texture.
- **Fix:** NVN cube textures are created as 6-layer 2D arrays and bound through cube / cube-array views by `tex_fit`, which also maps a cube array read as a cube to its first cube.
- **Found on:** [The Legend of Zelda: Breath of the Wild](../../dm/games/01007EF00011E000/README.md): 1,512 shaders sample the environment probes as `texturecube_array` while a single cube texture is bound.

### Cube map arrays count layer-faces

- **Symptom:** an abort in `MTLTextureDescriptor` validation, `arrayLength (510) … greater than the max allowed size (341)`, when the prologue movie ends.
- **Cause:** as in OpenGL, an NVN cube map array's depth is its number of layer-faces (a multiple of 6: 510 for 85 cubes), while a Metal cube array's `arrayLength` counts cubes. The host took the depth as a cube count in three places: the Metal texture, the upload's layer count and the guest layout (`nvn_tex.c` `shape`), so `GetStorageSize` reported six times the storage.
- **Fix:** a cube array is now created like a cube, as a 2D array of all its faces, and `tex_fit` makes the cube-array view a shader asks for (`t_nvn` checks the storage size against a 2D array's).
- **Found on:** [DRAGON QUEST XI S](../../dm/games/01006C300E9F0000/README.md).

### Cube views count their layers in cubes

- **Symptom:** an abort in Metal's validation: `newSliceRange.length(1) must be a multiple of (6)`.
- **Cause:** environment maps are 6-layer textures (target 2D array, depth 6) sampled through views with target CUBEMAP and layers 0 + 1. As in the hardware's texture header, a cube view counts its layers in cubes; Metal counts faces.
- **Fix:** a cube view whose layer count is not a multiple of 6 now takes its layers as cubes when the texture has that many faces (`tex_by_id`; else it is read as a 2D array with a red line).
- **Found on:** [Pokémon Sword](../../dm/games/0100ABF008968000/README.md) (as the player first walks out of the house).

### A 2D texture in a cube slot binds the zero cube

- **Symptom:** `texture type mismatch … declares slot 10 as Metal type 5, texture … is type 3` (undefined reads); the later `[RED] texture type mismatch: shader declares a cube, texture is 2D` could also report an unused conditional input as an error.
- **Cause:** a 2D texture bound where the shader declares a cube (a placeholder for an environment map) has no cube view. The same for a 2D array of fewer than six layers, which is how the host holds some NVN 2D textures. A uniform-controlled branch may choose a different cube input while the unused slot retains a 2D descriptor. Binding all statically declared Metal resources does not establish that this input is sampled.
- **Fix:** the zero cube is bound instead of a type mismatch with undefined reads (`tex_fit`). This supported binding fallback is informational (`cube binding fallback`), rather than a red error: it cannot diagnose which branch the shader executes. Other unsupported texture mismatches still report errors.
- **Found on:** [Pokémon Legends: Z-A](../../dm/games/0100F43008C44000/README.md); [Mario Kart 8 Deluxe](../../dm/games/0100152000022000/README.md) binds a 2D array of fewer than six layers (format 0x44) at slot 10 of two pixel shaders that declare a cube there as a race loads, and it was bound as is; [Echoes of Wisdom](../../dm/games/01008CF01BAAC000/README.md#rendering-and-shaders) exposed the false error for an unused conditional cube input.
- **Check:** `make -C dm/gfx/tests GAME=<id> check_t_cube_placeholder` uses production `tex_fit` and GPU sampling under Metal API validation. For 2D descriptors and one- and five-layer arrays, an unselected fallback preserves the other cube's blue output, a selected fallback reads zero, and binding alone raises no error; both cube and cube-array arguments are covered.

### A 2D texture in a 3D slot binds the zero 3D texture

- **Symptom:** `[RED] texture type mismatch: shader … declares slot … as Metal type 7, texture ID … is type 2 … bound as is` (or type 3, a 2D array); the reads are undefined.
- **Cause:** the game leaves a 2D texture bound in a slot its shader samples as a 3D texture, and Metal makes a 3D view only of a 3D texture. Batman: Arkham Knight's shaders sample a volume at world coordinates through separate texture slots that hold 2D textures, mostly half-resolution render targets, from the first frames of New Story on (`553c51835a24a36a`, separate slot 2: a 720x406 RGBA16F target); the pass dump shows the game binding them there, so no bind was lost, and the game does create 3D textures (2x2x2, 32x32x32, 71x40x64). What the Switch's texture unit reads from a 2D texture header through a 3D instruction is not known.
- **Fix:** as for a cube slot, `tex_fit` binds the zero 3D texture, a defined read, for a 2D texture or 2D array in a 3D slot, and logs the first case (`3D binding fallback`); other mismatches no view bridges are still reported and bound as is.
- **Found on:** [Batman: Arkham Knight](../../dm/games/0100ACD0163D0000/README.md#files-and-shaders) (four shaders, 3,813 draws in a run to the diner). The same red line is recorded on [FINAL FANTASY RESONANCE](../../dm/games/0100606026F12000/README.md), [ROMANCE OF THE THREE KINGDOMS 8 REMAKE](../../dm/games/0100C2A01A730000/README.md), [Luigi's Mansion 3](../../dm/games/0100DCA0064A6000/README.md) and [Hyrule Warriors: Age of Calamity](../../dm/games/01002B00111A2000/README.md), none of them run with this rule.
- **Check:** `make -C dm/gfx/tests GAME=<id> check_t_cube_placeholder` also covers a 2D texture and one- and five-layer 2D arrays in a `texture3d` argument: an unselected fallback leaves the real volume's output alone, a selected one reads zero.

### Multisample texture slots

- **Symptom:** `[RED] texture type mismatch: shader … declares slot … as Metal type 2, texture ID … is type 4 (NVN target 5, …); bound as is`, for a shader whose MSL declares the slot `texture2d_ms`.
- **Cause:** the reflection reader (`nvn_refl.m` `dummy_kind`) had no rule for `texture2d_ms`, `depth2d_ms` and their arrays, so it recorded such a slot as 2D. The multisample texture the game binds there was reported as a mismatch although the binding was right; an unbound slot got a 2D zero texture, which a multisample argument does not take; and a handle pool for such a slot would be built of 2D textures. The dummy tables were also indexed by the Metal type masked with 7, where the 2D multisample array (8) shared the 1D entry.
- **Fix:** the multisample types are read as `MTLTextureType2DMultisample` and `2DMultisampleArray`. Their zero textures are 4-sample private textures cleared by a render pass (`dummy_tex`; the integer classes as RGBA16, as the 128-bit formats have no multisample form), and the dummy tables have an entry for each Metal texture type.
- **Found on:** [Super Monkey Ball Banana Rumble](../../dm/games/010031F019294000/README.md#files-and-shaders): URP's `CopyDepth` (`a3d53d20b89e6015`) reads the multisample depth buffer at the title.
- **Check:** `make -C dm/gfx/tests GAME=<id> check_t_ms_slot`: the reflection of each multisample type, the multisample dummies of every pixel class, the 1D dummy beside the multisample array's, and a kernel reading the float, uint and depth dummies through multisample arguments under Metal API validation (all samples 0).

### Integer views for images a shader declares uint or int

- **Symptom:** translucent UI (frosted text bands, button guides, dialog headers) yellow and white.
- **Cause:** the composite shader loads the window texture's texel as `r32ui`, unpacks the four bytes and stores the blend through a float view of the same image. The host bound the RGBA8Unorm texture to the `texture2d<uint>` argument as it was, whose reads are undefined (Metal's validation layer does not check textures in argument tables).
- **Fix:** an image slot the shader declares as uint / int now gets a view of the same texel size in that class (`img_fit` in `nvn_mtl.m`). The format-view usage costs lossless compression, so a texture gets it only when a shader needs such a view: it is upgraded (copied into a texture with the usage) before the next draw pass opens, as the copy cannot run inside the draw's own pass; until then that one draw reads it as before.
- **Found on:** [FINAL FANTASY TACTICS - The Ivalice Chronicles](../../dm/games/010038B015560000/README.md): the last passes have no render target; fragment shaders composite each UI layer into the window texture with image stores, blending in software (`uirender.tec`, `4cf1975ed1e36590`).

### Buffer textures read by 1D integer fetches (row wrap)

- **Symptom:** `texture type mismatch: shader declares 2, texture is 9`; the slot read 0.
- **Cause:** Maxwell fetches a texture buffer and a 1D texture with the same instructions (TLD with integer coordinates only, TLDS `Texture1DLodZero`), and the bound descriptor decides which it is. Without PC reflection the translator has no type answer and reads such a slot as a 2D texture at `(x, 0)`, and the host could only bind a dummy when the game put a buffer texture there.
- **Fix:** the vendored translator (`InstEmitTexture.cs`, marked `nxnative:`) now addresses every such fetch as `(x & 0x3FFF, x >> 14)` and reports the slot (`fetch1d` in the reflection). The host binds a buffer texture in a flagged slot as a linear 2D texture of 16,384-texel rows over the same pool memory (`tbuf_as_2d` in `nvn_mtl.m`, `nvn_tbuf_rows` in `nvn_tex.c`), cached by texture serial beside the views. A real 1D texture, which the host creates as a single row at most 16,384 wide, reads as before. A mismatch no view can bridge is logged once per shader and slot, with its texture ID, NVN target and formats (`tex_mis_note`).
- **Note:** limits: a size query on a buffer of more than 16,384 elements returns 16,384 (no shader both size-queries and fetches such a slot in Age of Calamity; the build summary counts them), and the rows stop at the end of the Metal buffer.
- **Found on:** [Hyrule Warriors: Age of Calamity](../../dm/games/01002B00111A2000/README.md): 16,438 such shaders (98,970 bindings; slots 16–21 hold KTGL's light and decal lists).
- **Check:** Age of Calamity's 15-minute Mac battle bound 15.7 million of them through 320 row textures, none failed; the scene is darker and more saturated than with the zeros (mean luma 163 against 178 at the start of the battle), GPU time unchanged.

### Buffer textures at offsets below 16 bytes

- **Symptom:** particle effects drawn at the wrong scale or place, or flickering, where the particle data is a buffer texture at a pool offset that is not a multiple of 16; log line `buffer texture at pool offset …, below Metal's 16-byte alignment`.
- **Cause:** Metal requires 16-byte alignment for texture buffer views (`minimumTextureBufferAlignmentForPixelFormat`), and an Apple GPU addresses a view created at a smaller offset from the 16-byte boundary below it: on an M4 Pro, R32Float views at offsets 4, 8 and 12 read element 0 where elements 1, 2 and 3 are expected, for every format and width tried, shared and private buffers, bound directly or in an argument buffer (`t_tbuf_align`). The host used to leave such a view as a dummy, then created it at the offset on the strength of a measurement on an M6 that the M4 Pro contradicts. NVN places buffer textures at any element-aligned offset, and no Metal view can start there.
- **Fix:** the view is still created at the offset, and a shader reads it through a copy of its bytes at an aligned offset of a shared staging block (`tbuf_shadow` in `nvn_mtl.m`), made at its first binding in each submission and cached for the rest of it; aligned views are untouched. This is a workaround for the platform limit, with gaps that are **open**: the copy holds what the CPU wrote before the submission was encoded, so a GPU write to the buffer in the same submission, or in one still running, is not seen; a view in a pool the CPU cannot access is bound as is (`[RED]` once); and shader writes through an image view at such an offset land at the boundary below (`[RED]` once at creation). A shader-side element offset (the view at the boundary below, the shader adding the skew) would close all three, at the cost of a chain change and a per-binding value in the argument buffer.
- **Found on:** [Octopath Traveler 0](../../dm/games/01005270232F2000/README.md): one at pool offset `0x168`, read by its particle shaders ([Texture slots picked at run time](shaders.md#texture-slots-picked-at-run-time), `shaders.md`). [FINAL FANTASY RESONANCE](../../dm/games/0100606026F12000/README.md): particle data at offsets 4, 8 and 12 past the boundary (village fires, smoke).

### Buffer texture rows at a pool offset the device will not view

- **Symptom:** lighting that alternates between lit and unlit from one frame to the next on an iPhone, the same scene steady on a Mac; log lines `texture buffer (texture ID …, … at pool offset …) has no 2D-row form for a wrapped 1D fetch: the slot reads 0` and `texture type mismatch: … a buffer texture: the slot reads 0 (dummy)`.
- **Cause:** [row wrap](#buffer-textures-read-by-1d-integer-fetches-row-wrap) views a buffer texture at its pool offset, and Metal views only at a multiple of `minimumLinearTextureAlignmentForPixelFormat`, which is per device: 16 bytes for 32-bit formats on an M6 Mac, 32 on an M1 Pro, larger on an A17 Pro. Three Houses keeps two copies of its light list 32 bytes apart, so on the phone one copy was bridged and the other read zeros, and the picture alternated with the list (the two copies alternate per rendered frame, which is why no present-interval or frame-rate setting changed it).
- **Fix:** `tbuf_as_2d` (`nvn_mtl.m`) copies the rows of a buffer texture at an unaligned offset into the submission's arena (`tbuf_rows_copy`; 256-byte offsets, already resident, recycled once the submission is done) and reads the 2D rows there, one copy per texture per submission; rows at an aligned offset are untouched. The copy's cost is counted in the periodic `tbuf_as_2d` line (`… copied into aligned rows (N MB)`). This is a workaround for the platform limit, with the gaps of the 16-byte case above, **open**: the copy holds what the CPU wrote before the submission was encoded, and a buffer in a pool the CPU cannot map still reads zeros (`[RED]` once). The shader-side element offset named there would close them here too.
- **Found on:** [Fire Emblem: Three Houses](../../dm/games/010055D009F78000/README.md): its lighting flickered on an iPhone 15 Pro class device, its two light-list copies 32 bytes apart.
- **Check:** on an M1 Pro with `DM_TBUF_ALIGN=64`, a Mac that cannot see the problem otherwise: `[RED]` lines naming the same shaders and slots as the phone's log on the base this was found on (18 of them, `094a2d11253f126c_b` slots 18/19/20, `f54830a75e07e14a_b` slot 20, `6797af67f88a4ddd_b` slot 0), and a static terrain patch that stops being static — `YAVG` two values 0.008 apart alternating frame to frame, against one value for 12 frames with the alignment the Mac reports. With the copy in, the same forced alignment fails nothing, copies 5,058 times over the run (4,592 MB, about 2 copies and 2 MB a frame) and leaves the single value the aligned path gives; with the Mac's own alignment no texture takes the copy. Three Houses' own frames on the phone then hold 60 fps with the flicker gone.
- **Not checked:** another device's alignment (the value is read, not assumed); a game whose such buffer is written by the GPU in the same submission (the copy would be stale).

### Automatic block height truncates

- **Symptom:** torn digits and a background in blue steps (Rhythm Heaven Groove's latency calibration).
- **Cause:** NVN chooses the automatic block height by truncating `height_in_blocks * 1.5 / 8`, while `nvn_tex.c` rounded the division up, so some sizes (a 160×160 BC3 texture: H3 instead of H2) were read with the wrong layout; Rhythm Heaven Groove's BC7 textures without a packaged layout were read with the wrong block height.
- **Fix:** truncating height in blocks × 1.5 / 8, as MacNativeGames found: `nvn_tex.c` now truncates for every game (`pick_tile(ah * 3 / 16)`). It changes layouts at 6–10, 17–21, 38–42 and 81–85 block rows, which matters only for data the game lays out itself (no packaged layout: Tears of the Kingdom's flushed textures, Monster Hunter Rise's sparse ones); those were not re-checked.
- **Found on:** found by MacNativeGames on [The Legend of Zelda: Tears of the Kingdom](../../dm/games/0100F2C0115B6000/README.md) (listed there as open); confirmed by [Rhythm Heaven Groove](../../dm/games/0100D9F01D474000/README.md) on its two 40-block-row textures (two BC7 textures): the rule matches every size checked by eye: 672×160 and 1232×160 (40 block rows: 4 GOBs, where rounding up gives 8), and 112×112 (4), 288×208 (8) and 880×432 (16), where both roundings agree and `floor(rows / 8)`, the other rule that fits 40 rows, does not; and by Touchable (a d2r-mobile port of Tears of the Kingdom) on 16 of its texture files.
- **Check:** a dump of the guest bytes deswizzled in Python with 1 to 16 GOBs and decoded with `texture2ddecoder` shows the right one by eye; a smoothness score does not, because a block height too tall reads padding and looks smooth.
- **Not checked:** the games whose textures the game lays out itself (above).

### Sparse textures laid out in 64 KB tiles

- **Symptom:** magenta (the ASTC error colour) on streamed textures in a sparse pool; `DM_NVN_ZBLOCK` finds such textures (all-zero blocks).
- **Cause:** sparse textures have a layout of their own: they are mapped in 64 KB tiles, one row of blocks 128 GOBs / (block height × block depth) wide. The game's files hold its streamed textures pre-swizzled that way, and it places each level at the offset the host reports; the host laid them out unpadded.
- **Fix:** `nvn_tex.c` `level_walk`: a level at least one tile wide, high and deep is laid out with its width padded to whole tiles, the levels from the first smaller one on form the mip tail (packed as usual), and the storage is whole tiles, 64 KB aligned.
- **Found on:** [Monster Hunter Rise](../../dm/games/0100B04011742000/README.md): laid out unpadded, the 1024×1024 ASTC 6×6 clothes of Hinoa and Minoto (43 GOBs wide instead of 48, level 1 at 0x81000 instead of 0x90000) read 2,183 all-zero blocks in level 0 and 3,043 in level 1, which ASTC decodes as its error colour: their trousers, sleeves and gloves were magenta, worst in Kamura Village.

### Sparse textures take the block height of their 64 KB tile

- **Symptom:** a CPU-filled texture shuffled into a patchwork of rectangles (OCTOPATH TRAVELER's world map on the traveler selection).
- **Cause:** a sparse 2D texture without a packaged layout is laid out with the block height of its 64 KB tile, whose shape in blocks is the standard one: 256×256, 256×128, 128×128, 128×64 and 64×64 blocks for 1, 2, 4, 8 and 16 bytes per block, i.e. 32, 16, 16, 8 and 8 GOBs. The host used the [automatic block height](#automatic-block-height-truncates): 16 GOBs for the 4096×2048 BC1 map (512 block rows), whose tiles then landed in the wrong places.
- **Fix:** `nvn_tex.c` `sparse_tile_h` gives such a texture its tile's block height; a packaged layout still wins.
- **Found on:** [OCTOPATH TRAVELER](../../dm/games/010057D006492000/README.md) (Unreal Engine 4.18 flags its streamed and CPU-loaded textures sparse).
- **Check:** the map's guest bytes deswizzled in Python at 1 to 32 GOBs read right only at 8; a 512×512 RGBA8 sprite sheet only at 16; [Monster Hunter Rise](../../dm/games/0100B04011742000/README.md)'s packaged ASTC 6×6 textures (16 bytes per block) carry 8 in their layout. The 1- and 2-byte heights follow the same tile shapes and were not seen.

### Sparse textures of 8- and 16-byte blocks: blocks at most 8 GOBs high

- **Symptom:** crashes that move between runs (30–70% of boots, in the first minute): in the allocator, on bogus pointers, in unrelated threads. Unreal's purgatory proxy ([05-debugging](../agents/05-debugging.md)) finds freed 64 KB-aligned blocks modified; with the parked blocks read-only, the faulting store is a `memcpy` of texture mip data from the texture streamer into the buffer `RHILockTexture2D` returned.
- **Cause:** with the automatic block height the host gave sparse textures the same block height as plain ones (16 GOBs for 96 or more block rows), so a 64 KB tile was 8 GOBs wide. For 8- and 16-byte blocks (DXT1, DXT5 and the like) the real layout uses blocks of at most 8 GOBs and so tiles 16 GOBs (1,024 bytes) wide: the game's pre-swizzled data for a 384×384 DXT5 level is 32 GOBs × two 8-GOB block rows, 0x40000 bytes, where the host's layout said 0x30000 (the padding sits at the end of each 8-GOB block in the dump). 4-byte texels keep 16-GOB blocks (a 1350×270 BGRA8 level is 88 GOBs × three 16-GOB block rows, 0x210000 bytes). Unreal's NVN RHI sizes its lock buffer from the host's level layout and copies the cooked level in at its own size, past the end of the buffer.
- **Fix:** `nvn_tex.c` `sparse_tile_h` (see [Sparse textures take the block height of their 64 KB tile](#sparse-textures-take-the-block-height-of-their-64-kb-tile)): a sparse texture without a packaged layout and with 8 or 16 bytes per block takes 8-GOB blocks. `dm/gfx/tests/t_sparse_layout.c` checks 15 measured textures and Monster Hunter Rise's level offsets.
- **Found on:** [Yoshi's Crafted World](../../dm/games/01006000040C2000/README.md): 9 streamed DXT5 textures (384×384 to 1920×912) overran their buffers by 0x8000–0x20000 bytes; after the fix none of 10,578 level copies did, and 10 of 10 boots ran clean.

### Sparse textures smaller than a tile keep the automatic block height

- **Symptom:** a small CPU-filled sparse texture shows part of its image beside fragments, cut off at the bottom (Yoshi's Crafted World's loading icon: the left half of a chalk drawing and two stray strokes).
- **Cause:** a sparse texture smaller than one 64 KB tile in width or height is all mip tail, laid out as a plain texture with the [automatic block height](#automatic-block-height-truncates), but the host gave every sparse texture its tile's block height. The 192×160 DXT5 icon (12 × 5 GOBs, under the 16 × 8 GOBs of a 16-byte tile) is laid out in 4 GOBs and was read with 8; a 384×384 DXT1 (12 GOBs wide, under the 16-GOB tile width, 96 block rows) in 16, also read with 8. The storage sizes stay the same, so only the picture shows it.
- **Fix:** `nvn_tex.c` `nvn_tex_layout` gives a sparse texture its tile's block height only when level 0 is at least one tile wide and high, the test `level_walk` uses for padding; the tile's shape for that test and for `nvn_tex_sparse_tiles` comes from the block size (`tile_shape_h`), not from the block height the texture got. `t_tex_layout.c` checks both block heights and the icon's tile shape.
- **Found on:** [Yoshi's Crafted World](../../dm/games/01006000040C2000/README.md): the guest bytes of the icon and of the DXT1 deswizzled in Python read right only at 4 and 16 GOBs; its 384×384 DXT5 (24 GOBs wide, at least one tile) still reads right only padded to 32 GOBs at 8.

### Sparse textures bound from their first mapped level

- **Symptom:** streamed textures read 0 (magenta on Monster Hunter Rise's title screen's clothes).
- **Cause:** the translator drops TEX's LOD clamp and its residency predicate, so streamed textures were sampled at levels the game had not mapped yet.
- **Fix:** a sparse texture is bound as a view starting at its first level whose pages, and those of every smaller level, are all mapped (`sparse_view` in `nvn_mtl.m`). That samples exactly as a minimum LOD would; the view follows each upload.
- **Found on:** [Monster Hunter Rise](../../dm/games/0100B04011742000/README.md).

### Sampler reduction (min / max)

- **Cause:** a sampler built with `SamplerBuilderSetReductionFilter` (min / max) was averaged by the host. Metal 26 has the same thing (`MTLSamplerDescriptor.reductionMode`), but ignores it with a nearest or no mip filter.
- **Fix:** reduction samplers filter mips linearly (`samp_by_id`): at the integer LODs reductions are used with, that is the same level.
- **Found on:** [Pokémon Legends: Z-A](../../dm/games/0100F43008C44000/README.md): its depth pyramid is built with a min-reduction sampler (`SamplerBuilderSetReductionFilter 1`; `151607c7a92386cc` samples the level above at an explicit LOD).

### Sampler LOD bias

- **Symptom:** textures a mip level sharper or blurrier than on the Switch where the game biases its sampler; in the Vulkan layer, a red line `sampler LOD bias … not implemented`.
- **Cause:** the host kept NVN's `SamplerBuilderSetLodBias` and Vulkan's `mipLodBias` but never gave them to Metal, taking them for something Metal samplers lack. Metal 26 has `MTLSamplerDescriptor.lodBias` (range −16 to 15.99).
- **Fix:** `samp_by_id` (NVN) and `vkCreateSampler` set it, clamped to that range (Vulkan to the ±15 the device reports as `maxSamplerLodBias`).
- **Found on:** [Super Mario Galaxy](../../dm/games/010099C022B96000/README.md) (the Vulkan red line). MacNativeGames uses the property for its own MetalFX bias, which pointed to it.

### Border colours Metal has no sampler state for

- **Symptom:** whatever a game keeps in a texture that it samples past its edge with clamp-to-border reads the wrong value there: grass flattened along Link's path in Tears of the Kingdom, its bend map filled with "bent" wherever the window scrolled.
- **Cause:** NVN's `SamplerBuilderSetBorderColor` takes any RGBA colour; `MTLSamplerBorderColor` has transparent black, opaque black and opaque white only, and `samp_by_id` took the nearest of them. Tears of the Kingdom's border (0.5, 0.5, 0.5, 0.5) became (0, 0, 0, 0).
- **Fix:** a filtered sample is linear in the border colour, so two samples through samplers that differ only in their Metal border colour give the exact one: r = s_n + (s_w − s_n)·k, k = (B − Bn) / (Bw − Bn) per channel. The build (`dmsh_build.py border_emu`) wraps every sample through a sampler member of the argument buffer in `dm_bs(…)`, adds a twin sampler member `<member>_w` for each, and one block `dm_border` (a mask word, then k per sampler; `DMSH_BORDER_*` in `dmsh_abi.h`). The host (`nvn_border.h`) keeps the nearest Metal colour for the sampler and makes a twin only for a colour Metal lacks when a wrap mode reaches the border and no min / max reduction is set; `encode_args` binds the twin and sets the sampler's bit and k, and binds the shared zero bank as the block otherwise. Every other sample costs one uniform branch on the mask; the twin sample runs only for those samplers. The readable-tile variants (`dmsh_fetch.py`) replace a wrapped sample whole, so a tile read is never corrected.
- **Not covered:** samples through sampler arrays, `sample_compare` and `gather`, and samples of integer textures (not filtered; their border colour is an integer one) keep the nearest Metal colour; so does the Vulkan layer, which has its own translation.
- **Found on:** [The Legend of Zelda: Tears of the Kingdom](../../dm/games/0100F2C0115B6000/README.md): the grass bend map, a 256×256 RG8 window that follows Link, advanced by `ff9def5b3c418851` with wrap 5 and border 0.5.
- **Check:** `t_border` (nvn_border's choices for opaque, translucent and Metal's own colours, and the registry's twins) and `test_dmsh_border.py` (the rewrite, the reflection, the readable-tile variant, the compile for macOS and iOS, and with `make check_t_border` the GPU: corrected samples against Maxwell's bilinear filter with the border colour, and Metal's nearest colour with the mask clear).

### Texture fields Metal refuses

- **Symptom:** the process ends at once (the window vanishes), with `-[MTLTextureDescriptorInternal validateWithDevice:]` failing an assertion such as `requests 9 mipmap levels, but the dimensions (1, 1, 1) can only support 1`, or `sampleCount must be > 1 for multisample textures`.
- **Cause:** NVN takes texture fields Metal refuses, and Metal aborts instead of returning nil: more mip levels than the size holds (on NVN the extra levels are 1×1), an array or 3D texture of no layers, more than 2048 layers (a 1D array's layer count is its height, which the size check let through), and sample counts the GPU lacks (an M4 Pro has 1, 2 and 4; NVN also has 8 and 16). A blit at a level the Metal texture lacks is not checked either.
- **Fix:** `tex_desc` makes such textures with the levels their size holds and one layer for none. Textures of more than 2048 layers, and multisample textures of one sample or of a sample count the GPU lacks, are not made, as textures past Metal's size limits are (fewer samples would leave shaders reading sample indices past the texture). A red line names each case once. Copies and `ReadTexels` at a level the host texture lacks are skipped (`tex_level_ok`). Retail data is within every bound except, possibly, 8- or 16-sample targets.
- **Found on:** reported by MacNativeGames (`f864eb0`): a mod's 1×1 texture in Tears of the Kingdom declaring 9 levels. No game here is known to reach it; the sample counts (an M4 Pro has 1, 2 and 4, and a multisample texture of one sample aborts) were checked on that Mac while porting the fix.
- **Check:** `t_view_levels` makes each case with Metal's validation layer on: a 1×1 texture of 9 levels, a 3D texture whose depth holds the levels, an array of no layers, a 1D array of 4,096 layers, an 8-sample and a 1-sample multisample texture, and a copy at a missing level.

### Unreal's texture streaming pool

- **Symptom:** in an Unreal Engine game, textures and lighting turn blurry and muddy about a second after an area loads and stay that way, whatever the frame rate, render scale or upscaling; no red line.
- **Cause:** not the host: the game's own budget. Unreal's texture streamer keeps at most `r.Streaming.PoolSize` megabytes of streamed mips resident and drops the top mips of what is in view once it is past them; lightmaps stream too, so the lighting goes flat with the textures. The game's Switch device profile sets the pool (DRAGON QUEST VII Reimagined: 200, and 1000 on Windows), so the Switch looks the same. The host's texture sizes, which the streamer counts, follow the NVN driver's layout (`nvn_tex_layout`).
- **Fix (an improvement over the Switch):** the profile key `ue_texture_pool <MB>` (`DM_UE_TEXTURE_POOL` overrides) raises the variable to that size whenever the game sets a smaller one; a larger value, or −1 (no pool size), stays (`hle_uecvar.c`, on every present). Unreal's streaming manager reads the variable again when it changes (DRAGON QUEST VII Reimagined `main+0x342230`: game thread copy, MB → bytes, into the pool size that `main+0x4d98b00` reports to the streamer), so a write at run time takes effect. The variable is found by its name, with no address per build: the rewriter names it in main's fixups ([Unreal's frame limit and present interval, found by name](frame-rate.md#unreals-frame-limit-and-present-interval-found-by-name)); until 2026-10-30 the host searched for it on the first present (`dm_ue_cvar`, 35 ms). It applies on the Mac; on iOS only `DM_UE_TEXTURE_POOL` (`Documents/env.txt`) turns it on, until an iPhone run shows the memory fits.
- **Found on:** [DRAGON QUEST VII Reimagined](../../dm/games/0100A9D01C446000/README.md) (GitHub issue #589). The rewriter finds the pool in every Unreal main on the drive: OCTOPATH TRAVELER and Yoshi's Crafted World (UE 4.1x, UTF-32), Pikmin 4 (4.26), OCTOPATH TRAVELER II and DRAGON QUEST VII Reimagined (4.27), Octopath Traveler 0 (UE 5) and FINAL FANTASY RESONANCE (5.6).
- **Check:** `t_uecvar` (the variable named in main's table, or not; the value raised, kept and left); the search itself, `test_ue_cvar.py`. On a Mac run, `DM_CTL` `cvari <main offset> <MB>` sets the pool while the game runs, for an A/B at one spot.

## Render targets, passes and clears

### Transient render targets shared by storage

- **Symptom:** ≈13 MB/frame leak.
- **Cause:** the game builds new texture objects every frame over the same storage and never finalizes them; each new object allocated a new private Metal texture.
- **Fix:** host textures are shared by `(pool, offset, description)`.
- **Found on:** [Super Mario Bros. Wonder](../../dm/games/010015100B514000/README.md).

### IMAGE usage does not split texture storage

- **Symptom:** a model has correct geometry, base colour and normals but appears as a black silhouette; deferred lighting's material-ID depth texture stays zero.
- **Cause:** render and stencil-sampling descriptors name the same pool, offset and layout, differing only by `NVN_TEXTURE_FLAGS_IMAGE`. Including that usage flag in the storage key made two independent Metal textures; sampling read the empty one's stencil.
- **Fix:** the storage key excludes `IMAGE`. Sampling shares the original texture. A writable image binding prepares any needed `ShaderWrite` usage before opening its encoder; the upgrade copies the pixels and replaces every name of the old texture. Upgrading while encoding arguments would end the active encoder underneath its caller.
- **Check:** `t_stencil_view` writes both planes, reads through an IMAGE stencil descriptor and copies to separate storage under Metal validation; `t_upgrade_alias` checks image-write preparation and every live/finalized alias.
- **Found on:** [Xenoblade Chronicles 3](../../dm/games/010074F013262000/README.md).

### Shared-storage entries taken over by a new texture

- **Symptom:** GPU memory grows with every image shown; the memory line's `shared textures` count keeps rising.
- **Cause:** the game decodes each picture it shows into one scratch region of a pool that lives for good, finalizes that texture when it is done with it and builds the next one in the same region with another size or format; during some transitions it builds a new render target every frame, one pixel wider each time (614x720, 615x720, …). The storage-sharing table (`g_alias`, keyed by pool, offset and description; [Transient render targets shared by storage](#transient-render-targets-shared-by-storage)) kept every one of them until the pool was finalized.
- **Fix:** a new shared texture takes over the entries of its pool whose storage it overlaps under another description (`alias_take_over` in `nvn_mtl.m`), unless a live texture object still resolves to one (Wonder's transient render targets, rebuilt on new objects every frame and never finalized) or a lookup found it in the last 16 submissions (Breath of the Wild finalizes its transient render targets before every submit and builds them again the next frame; targets sharing storage would otherwise evict each other every frame). An entry that only a finalized serial in `g_ghost` still holds loses the table's reference and is retired with that serial. The memory line reports `shared textures N (M of them unreferenced; evicted with pools …, on storage takeover …)`: the unreferenced ones wait for their storage to be reused or their pool to go.
- **Found on:** [STEINS;GATE RE:BOOT](../../dm/games/01008BC024FDE000/README.md) (ASTC 4x4 images up to 4096 wide, RGBA8 render targets, R8 masks): from a quick save, 297 entries and 1.29 GB of GPU memory at frame 6,600; 468 entries and 1.58 GB 24,000 frames into a new game. With the fix: 97 entries and 0.93 GB at frame 6,600; 15 minutes of story from the quick save (53,700 frames) stayed at 1.08–1.15 GB of GPU memory and 1.02–1.13 GB resident, and a new game from boot stays at 0.97–1.03 GB from its first story scene to frame 27,300 (with the 16-submission guard).
- **Check:** Captain Toad: Treasure Tracker's opening course, rendered with agl's transient targets, keeps its 26 entries and takes none over, with the same memory and frame times as before.

### Live resolution variants share physical image storage

- **Symptom:** GPU memory grows as resolution changes or rooms load, although almost every retained texture still has a live NVN descriptor; reclaiming unused sharing-table entries cannot recover it.
- **Cause:** an NVN texture object describes storage in a pool. Several live descriptions at the same pool offset can describe the same physical memory at different resolutions, but `(pool, offset, description)` sharing allocated a separate private Metal texture for every size. The live-object guard in `alias_take_over` correctly kept those descriptors, and consequently kept all their independent allocations.
- **Fix:** `image_texture` in `nvn_mtl.m` gives a declared resolution family an exact-sized placement heap. Eligibility is GPU-only, mapped, non-sparse storage, exactly `COMPRESSIBLE|IMAGE`, single-level, single-sample 2D images. Sharing stays within one NVN pool, offset and format. Live descriptions are recorded at initialization so the first used resolution can allocate the largest declared requirement; a single-description address retains its ordinary allocation. No power-of-two capacity or extra pixel-format-view usage is imposed. A fresh heap is zeroed through its largest description; creating a later alias never queues a zero fill over another alias's content. Metal 4 residency names the heap, and encoder boundaries include resource-alias visibility while these heaps exist. Each texture holds its heap owner; normal sharing-table eviction and deferred texture release retire the allocation after its last texture/view goes, without a pool-lifetime heap cache.
- **Limits:** this handles initialized resolution families, not arbitrary overlapping offsets, cross-format inheritance, CPU-visible or sparse storage. If a larger description is declared later and cannot fit an existing heap, it gets a new exact allocation; old heaps follow their existing textures' lifetimes. Inherited texels are not translated between incompatible texture layouts. No game-specific profile switch is used.
- **Check:** `make -C dm/gfx/tests GAME=0100DCA0064A6000 check_t_image_alias` runs under Metal validation with direct and deferred encoding: 128 live descriptions retain their individual dimensions while sharing one allocation; small-first fresh storage, literal pixels across resolution changes, descriptor creation after a writer, indirect Metal 4 argument-buffer access, native integer-image atomics, depth/stencil clears and stencil views, pool/offset/format separation, excluded CPU-visible/sparse images and repeated destruction are checked. Integer-image matching restores the `ShaderAtomic` usage that Metal omits from its queried usage flags.
- **Found on:** [Luigi's Mansion 3](../../dm/games/0100DCA0064A6000/README.md#texture-memory-2026-10-27), investigated from [#257](https://github.com/seedds/nxnative/issues/257) and [#100](https://github.com/seedds/nxnative/issues/100). The game's note records the live-allocation census and Mac comparison; other games and long iOS sessions remain unvalidated.

### Render-target views that change the format

- **Symptom:** the whole picture came out darker and more saturated on the Mac and the iPhone: comparing with a Switch screenshot, every channel at every level equalled the Switch value decoded from sRGB once more (0.55 → 0.26, 0.75 → 0.52).
- **Cause:** Mario's last pass writes the `RGBA8` swapchain texture through an `RGBA8_SRGB` view (`TextureViewSetFormat` 0x38 on a 0x25 texture), so the GPU encodes the linear shader output to sRGB on write. The host used to attach the base texture, which stored the linear values unencoded.
- **Fix:** `attach` now attaches a Metal view of the view's format, so the pipelines get that format too; the view is kept until the submission completes. A format change that is not an sRGB / linear pair needs `MTLTextureUsagePixelFormatView` on the base texture; without it the host draws in the base format and reports `render target view format … cannot be attached`.
- **Present step:** the matching rule: the Switch scans out the stored bytes, so an sRGB-typed swapchain texture (`RGBA8_SRGB` / `BGRA8_SRGB`) is sampled through a non-sRGB view (`present_raw_src`); sampling it directly would decode it once more on screen only, which a `DM_NVN_SHOT` capture (raw bytes) does not show. Mario's swapchain is `RGBA8`, so this path is for other games (`t_present_crop` covers it).
- **Check:** `DM_NVN_PASSDUMP` prints these views as `V <pass> c<i> view format …`; Mario uses only this one (1 of 80 passes in a course frame).
- **Found on:** [Super Mario Bros. Wonder](../../dm/games/010015100B514000/README.md).

### Render-target use added on demand

- **Symptom:** a clear of, or a format-converting copy into, a texture made without render-target use is declined.
- **Cause:** a whole-level clear and `copy_t2t_draw` (which renders into the destination, [Copies a blit cannot do, drawn](#copies-a-blit-cannot-do-drawn)) need a texture with render-target use.
- **Fix:** the texture is upgraded to render-target use first, as format views are upgraded (`tex_upgrade`; [Integer views for images a shader declares uint or int](#integer-views-for-images-a-shader-declares-uint-or-int)).
- **Found on:** [Monster Hunter Rise](../../dm/games/0100B04011742000/README.md) (the clear of a 32x80 packaged texture); [Paper Mario: The Thousand-Year Door](../../dm/games/0100ECD018EBE000/README.md) (a format-converting copy of a 128x128 RGBA8 render target into a packaged RG8 texture, mirrored in Y, as the boat arrives in Rogueport, about frame 10,950: `copy_t2t_draw` declined a destination made without render-target use).

### A texture upgrade while a draw binds its arguments ends the pass

- **Symptom:** `CRASH sig=11 addr=0x794` in `-[AGXG16GFamilyRenderContext_mtlnext drawIndexedPrimitives:…]+0x50`, called from `draw_`, right after the log line `texture upgraded to allow format views` (Metal API validation reports nothing first).
- **Cause:** `draw_` takes its render encoder from `rp_begin_ex`, then binds the program's arguments (`encode_args`). Binding a texture view of another format calls `tex_by_id`, which upgrades a texture made without `PixelFormatView` (`tex_upgrade`); the upgrade copies the old texture through `blit()`, which ends the render pass (`rp_end`). The draw then encoded on that ended encoder: the driver reads the context it released at end of encoding (`ldr x21, [x0, ivar]`, then `[x21 + 0x794]`).
- **Fix:** after `encode_args`, a draw whose pass ended (`g_enc != en`) is encoded again from the start in a new pass; the texture is already upgraded, so the second binding does not end it (a second end would be logged red and the draw skipped).
- **Found on:** [Need for Speed: Hot Pursuit Remastered](../../dm/games/010029B0118E8000/README.md) (a 4096x1024 texture sampled through a view of another format at its first loading screen).

### Compressed textures as render targets through an uncompressed shadow

- **Symptom:** `render target is a compressed-format texture …`; the pass's draws did nothing (the attachment was left out), or the pipeline-descriptor validation aborts the process.
- **Cause:** a GPU block encoder writes a BC texture through an uncompressed integer view (one texel per block). Metal can neither attach a compressed format nor make an uncompressed view of one.
- **Fix:** such a pass draws into an uncompressed shadow of blocks × blocks in the view's format: the level's (or layer's, or depth plane's) blocks are copied into it through a buffer before the pass and back after it (`bcrt_attach` / `bcrt_flush` in `nvn_mtl.m`; the method comes from PR #11). The shadows stay resident and are reused, and they are kept out of the load-skip and store-elision bookkeeping. `attach`, the pipeline prediction and the sampling views go by the NVN format, so BC textures are never attached or viewed raw. The encoder's output must be declared `uint` ([Integer fragment outputs declared by hand](shaders.md#integer-fragment-outputs-declared-by-hand)).
- **Found on:** [The Legend of Zelda: Breath of the Wild](../../dm/games/01007EF00011E000/README.md): agl's BC4 block encoder (`8e2cc2671cae6020`) writes a 32×32 RGTC1 (BC4) texture through an `RGBA16UI` view (one texel per 8-byte block); its twin for a 2D source (`93aa5e22a8202409`) failed in an iPhone run; GitHub issue #4 (reported from an iPhone 14 Pro / A16). [The Legend of Zelda: Tears of the Kingdom](../../dm/games/0100F2C0115B6000/README.md): agl's BC4 block encoder (`0544282c162305db`, the same shader Mario Wonder ships) encodes a 32×32×32 BC4 3D texture one depth plane per pass through an `RGBA16UI` view; a raw dump at frame 1500 of the new-game route: the texture was all zeros before, now all 32 planes hold encoded blocks.
- **Note:** the A16 has no BC formats; the host used to store BC textures decompressed on such GPUs (about 3.9 GB instead of 2.8 GB for BotW, over iOS's limit on a 6 GB iPhone), and that path has since been removed: only GPUs with BC are supported ([GPUs without BC textures are refused at start](#gpus-without-bc-textures-are-refused-at-start)).

### GPUs without BC textures are refused at start

- **Symptom:** on an iPhone before the A17 Pro, the game runs until its first BC texture, then `failed assertion 'Texture Descriptor Validation' … MTLTextureDescriptor has invalid pixelFormat (134).` (or another number from 130 to 153, Metal's BC formats; 134 is `BC3_RGBA`) and `CRASH sig=6`, the backtrace through `tex_mtl`, `tex_by_id` and `encode_args`.
- **Cause:** BC textures are created and uploaded as BC, with no decompression path ([Compressed textures as render targets](#compressed-textures-as-render-targets-through-an-uncompressed-shadow), note), and the A16 and older iPhone GPUs have no BC formats (`MTLDevice.supportsBCTextureCompression` false). The format mapping is right; the device cannot make the texture.
- **Fix:** the device is checked before anything runs. The iOS app (`boot_env` in `dm/ios/Sources/main.m`) does not start the host or the launcher on such a GPU: the screen says the device is not supported and names the GPU and the devices that are (iPhone 15 Pro or newer, M1 iPads or newer), and the log has a `[RED] boot:` line. `mtl_init` (`nvn_mtl.m`) stops every other route the same way, with a `FATAL … has no BC texture formats` line, for the NVN, Vulkan and GL layers alike; the classic-only path of a device without Metal 4 (a virtual Mac's shader capture) is left as it was.
- **Found on:** [FINAL FANTASY X/X-2 HD Remaster](../../dm/games/0100BC300CB48000/README.md): [GitHub issue #704](https://github.com/seedds/nxnative/issues/704), an iPhone 15 (A16) with another region's copy (`0100B3600AE9A000`): the launcher ran (no BC textures), FFX aborted at its first BC3 texture.

### A depth texture drawn through a colour view

- **Symptom:** the boot aborts in Metal's pipeline validation: `MTLPixelFormatDepth16Unorm is not color renderable`.
- **Cause:** a depth texture drawn through a colour view (a 1024×1024 D16 texture through an R16 view); Metal has no colour view of a depth texture.
- **Fix:** such a pass draws into a colour shadow of the same pixel size, copied in before and back after the pass through a buffer, as a compressed render target is ([Compressed textures as render targets through an uncompressed shadow](#compressed-textures-as-render-targets-through-an-uncompressed-shadow); `shrt_block`; D16 and D32F, whose Metal pixel is the NVN pixel; not D24S8).
- **Found on:** [Luigi's Mansion 3](../../dm/games/0100DCA0064A6000/README.md).

### The same texture attached at two colour slots

- **Symptom:** a G-buffer target holds only scattered squares (a different order for each 32×32 tile).
- **Cause:** on Maxwell the ROP writes only masked channels, so two slots holding the same texture with one at write mask 0 do not interfere. On Apple's TBDR each attachment has its own tile memory and the whole tile is stored at the end of the pass, so the copy stored later (loaded, never written) overwrote the other one's writes.
- **Fix:** a slot whose texture, level and layer repeat an earlier slot is left unattached (`rt_dup_slot`), also in pipeline prediction; a draw that really writes such a slot is reported once (`color slot … holds the same texture as an earlier slot`). Records hold copies of texture objects (`tex_snap`), so slots are compared by serial, not by pointer.
- **Found on:** [The Legend of Zelda: Breath of the Wild](../../dm/games/01007EF00011E000/README.md): the G-buffer passes attach the albedo and another buffer twice each (c1 = c2, c3 = c4), the duplicate slots with write mask 0; the albedo held only scattered squares.

### Passes with no render target

- **Symptom:** `no render target could get an MTLTexture` (the pass skipped).
- **Cause:** a fragment shader that only stores to a storage buffer draws into a viewport with no colour or depth target set.
- **Fix:** the host opens an attachment-less pass at the viewport's size (`bare_dims` in `nvn_mtl.m`, from PR #11).
- **Found on:** [The Legend of Zelda: Tears of the Kingdom](../../dm/games/0100F2C0115B6000/README.md): an agl fragment shader draws one triangle into a 1×1 viewport (it samples a 64×64 cube map, and the game reads the result back from the buffer). Compared at the same frames of the new-game route, the cave's rock and stone blocks now get ambient light they lacked, and Zelda's bloom halo in the descent cutscene is gone.

### Layered passes for vertex shaders that write the layer

- **Symptom:** a black world: everything rendered through a 3D LUT built by layered draws comes out black (every plane went to plane 0); `DM_NVN_PASSDUMP` shows no `L` line.
- **Cause:** a Metal vertex shader selects the attachment layer per primitive only when the render pass has `renderTargetArrayLength`.
- **Fix:** a draw whose vertex shader writes the layer opens a layered pass (`g_rp_layered` in `draw`, `g_pass.layered` in `rp_begin_ex`): the pass gets every layer the attachments have from their attached one on (3D textures: depth planes), and it is split when the next draw's shader differs. `DM_NVN_PASSDUMP` prints `L … layered pass: n layers`.
- **Found on:** [Pokémon Legends: Z-A](../../dm/games/0100F43008C44000/README.md): the 3D scene came out black once the opening reached Lumiose. The game builds its 32×32×32 colour grading LUT with `b29f08619f379a83`, one instance per depth plane, each writing its plane through `render_target_array_index`, and tone-maps the frame through that LUT.

### Passes into other layers of one texture level run as one layered pass

- **Symptom:** a frame-time spike every few frames (the Metal HUD's frame-time line jumps by several ms at a regular interval) while the scene stands still; `DM_NVN_GPUPROF` over consecutive frames shows the slow frame with about 130 more render passes, each one draw into a 64x64 to 8x8 face of a cube or array level, and the next pass starting late.
- **Cause:** on Apple GPUs a render pass costs about 35–40 µs whatever it draws (M2 Max, with or without barriers: a Metal 4 microbenchmark of 132 one-draw 64x64 cube-face passes took 5.4 ms, 4.2 ms without barriers). An environment cube map filtered face by face, one pass per face and level, pays that cost once per face.
- **Fix:** the draw that opens a pass looks ahead (`sm_scan`, `sm_plan` in `nvn_mtl.m`): when its only target is one layer of an array or cube texture level and the following targets switch to other layers of the same level with nothing but state, uniform updates and draws between them (no game barrier, clear, copy or dispatch), the pass is opened over those layers (`renderTargetArrayLength`) and `OP_SET_RT` switches layers inside it. Each draw reaches its layer through a vertex amplification view mapping (count 1, `renderTargetArrayIndexOffset`); a pipeline built with the default `maxVertexAmplificationCount` of 1 ignores the mapping (every draw landed in the first layer), so these draws use pipelines built with 2 (`sm_amp_get`, keyed `AMP_MARK`), compiled in the background on first use while the passes stay apart. A draw that samples the attachment or a clear ends the merged pass. `DM_NVN_SLICE_MERGE=0` turns it off; `DM_NVN_PASSDUMP` prints `L … slice-merged pass` and `M … goes on in layer n`, and the residency set line counts merged passes and layer switches.
- **Found on:** [Breath of the Wild](../../dm/games/01007EF00011E000/README.md): every tenth frame filters the environment cube map in 132 passes (22 levels of 6 faces); 284 → 173 render passes in that frame, frame p95 13.2 → 11.1 ms at 900p on an M2 Max.
- **Check:** `DM_NVN_TEXDUMP=layers=100:path` dumps the first such frame with and without the switch: the 173 targets matched (105 identical, the rest within 1% RMSE, the scene's rain).
- **Resolved in review of #213:** the first draw now gets the attachment-read check before planning a merged pass. Every later check refuses unknown bindless/dynamic reads (`TEXU`, `TEXD`, `TEXA`, image atomics and their reflection flags), and considers textures sharing the attachment's storage. Slot-only reads cannot prove those draws independent. `t_perf_order` checks all six array layers' pixels and five actual continuations after pipeline warm-up, plus the first-draw and unknown-read refusals. It runs with both encoding modes and merging disabled.

### Compute dispatches between the draws of a pass run ahead of it

- **Symptom:** a GPU-bound frame with many passes on the same targets, one after the other, each preceded by a compute encoder of one dispatch (`DM_NVN_GPUPROF`: `compute / copy after pass … dispatches 1` between render passes of the same size); about 4 ms of GPU idle a frame inside command buffers in Metal System Trace.
- **Cause:** Metal cannot dispatch compute inside a render pass, so every dispatch between two draws ends the pass; on Apple GPUs each extra pass and encoder costs its fixed 35–40 µs plus the store and reload of every attachment.
- **Fix:** `cs_hoist_try` (`nvn_mtl.m`, `DM_NVN_CS_HOIST`, on by default, `0` off): when a draw opens a pass, the ops up to the first one that would end the pass anyway are scanned, and each dispatch met on the way runs before the pass when moving it ahead of the draws before it changes nothing they read (no storage buffer they read, no colour attachment of the pass sampled, no image written, the draws write no memory). A dispatch that samples the pass's depth moves only while no draw before it in the pass writes depth, so it sees the same depth. `DM_NVN_PASSDUMP` prints `H … dispatch … moved ahead of the pass`; the residency set line counts moved dispatches and why scans stopped.
- **Found on:** [Breath of the Wild](../../dm/games/01007EF00011E000/README.md): the NintendoWare VFX GPU particles run one dispatch per emitter between the effect draws of the G-buffer and of the half-resolution passes; 28 → 8 compute encoders and 149 → 132 render passes a frame, frame p50 9.9 → 9.0 ms at 900p on an M2 Max. Its particle collision samples the G-buffer depth, and no draw before those dispatches writes depth (counted: 0 stops).
- **Check:** the cube-filter frame's 173 targets dumped with and without (`DM_NVN_TEXDUMP=layers=100`): every 3D target within 0.7% RMSE; only the 2D overlay of the final picture differed (a loading banner's animation, timed by the wall clock).
- **Resolved in review of #213:** a nonzero game barrier stops the scan. A sample of depth-stencil storage cannot move ahead of either a depth or stencil write. Unknown indexed-indirect ranges and bindless/dynamic draw texture reads refuse hoisting; fixed-slot sampled textures contribute their storage ranges (including linear and buffer-backed textures). Sparse virtual addresses, unknown sizes and overflowing ranges do not prove independence. Compute uniform/storage accesses overlapping attachment storage also refuse hoisting; sampled texture storage is compared by extent, including different offsets into one linear buffer. Texture registration uses its actual unfair lock. These are general dependency checks, without profile rules.
- **Regression:** `t_perf_order` drives the production replay with an independent dispatch (moved exactly once, GPU writes 73), an explicit barrier (not moved), and the scanner with a stencil-only view after a stencil-writing draw. It also checks indirect index ranges, sampled buffer storage, unknown texture reads and aliased attachments. The initial PR failed 13 harness assertions; restoring only its depth-only write guard makes the stencil case fail too. The fixed harness passes under Metal validation in both encoding modes and with optimizations disabled. [BotW gameplay](../../dm/games/01007EF00011E000/README.md#final-synchronization-and-pass-validation-2026-10-26-current) exercises both optimizations on/off; it retains pass savings but does not demonstrate a timing gain in the tested 60 fps workload. [Metroid Dread gameplay](../../dm/games/010093801237C000/README.md#final-gameplay-validation-2026-10-26-current) broadens coverage without activating either optimization.

### Clears of attachments larger than the render pass

- **Symptom:** a scene drawn only in a small square in the top-left corner of a black screen; speckled and blocky patches; a full-screen overlay showing one tile; the texture dump right after the scene pass shows the picture only in the corner, and `DM_NVN_HILITE` on the scene's shaders lights only the corner.
- **Cause:** a Metal render pass covers only the smallest of its attachments, and so does a clear in its load action. A clear folded into a pass whose other attachment is smaller cleared only that corner of the larger target, so later draws failed the depth test against the previous frames' depth everywhere else. NVN clears the whole target.
- **Fix:** `rp_begin_ex_` (`nvn_mtl.m`) clears an attachment larger than the pass in a pass of its own first and loads it in the real one (`C … cleared in a pass of its own` in a pass dump).
- **Found on:** [Bayonetta 2](../../dm/games/01007960049A0000/README.md): every frame starts with a pass whose colour target is 32x32 (then 256x256 ones) beside the 1280x720 depth buffer, and the game clears the depth there; the story's opening narration showed its scene in a 32x32 or 256x256 square of a black screen. [Bayonetta](../../dm/games/010076F0049A2000/README.md) needed nothing more.
- **Not checked:** the fix in other games beyond the unit tests.

### Lazy clears folded into the next pass

- **Fix:** lazy clears (`DM_NVN_LAZY_CLEAR`) fold clear-only passes into the pass that follows.
- **Found on:** [The Legend of Zelda: Breath of the Wild](../../dm/games/01007EF00011E000/README.md): the four clear-only passes before the G-buffer fold into its first pass (about 30 MB less loaded and stored a frame at 1600x900).

### A channel mask that covers every channel is a whole clear

- **Symptom:** `texture clear case not implemented … mask 0x1`.
- **Cause:** an R8 render target cleared with channel mask 0x1.
- **Fix:** a mask that covers every channel the format has is a whole clear (`mtl_pf_chmask`).
- **Found on:** [FINAL FANTASY TACTICS - The Ivalice Chronicles](../../dm/games/010038B015560000/README.md).

### Texture clears with partial channel masks or regions

- **Symptom:** `texture clear case not implemented … mask 0x8` while entering a rendered scene.
- **Cause:** `ClearTexture` only handled whole-level clears whose mask covered every channel. Persona 5 Royal clears only alpha on a 1920x1080 RGBA8 target; a load-action clear cannot preserve its RGB channels.
- **Fix:** partial colour texture clears use the existing clear-triangle shaders in a load/store pass, with the requested channel mask and rectangle. The viewport comes from the selected mip, the region selects the slices or depth planes, and the current draw scissor does not affect the operation. Whole-level whole-channel clears keep the load-action path. `t_clear_tex` checks pixel and channel preservation, mip/layer selection, integer values, an empty mask and the whole-clear path under Metal validation.
- **Found on:** [Persona 5 Royal](../../dm/games/01005CA01580E000/README.md), the opening casino.

### Scissored colour clears

- **Cause:** NVN `ClearColor` honours the scissor. Clears are normally folded into the next pass's load action, which only works for a full-target clear; Mario clears sub-rectangles of small targets to zero (pyramid levels packed into 480×272, 256×256 and 64×36 targets).
- **Fix:** a zero clear outside a pass with a partial scissor is now a copy from the shared zero buffer into that rectangle of the attachment's level / slice (`clear_rect_zero`).
- **Check:** `DM_NVN_CLEARLOG=1` logs clears that are still skipped (mid-pass, partial channel mask or non-zero colour with a partial scissor).
- **Found on:** [Super Mario Bros. Wonder](../../dm/games/010015100B514000/README.md).

### Clears inside a pass, with a partial mask or a partial scissor

- **Symptom:** red lines for unimplemented mid-pass, partial-mask and partial-scissor clears (the clears were dropped); `depth-stencil clear with a scissor or partial stencil mask, cleared whole` (logged once).
- **Cause:** NVN clears obey the scissor and the clear's own channel or stencil write mask, and can come between draws, while a Metal load action clears a whole attachment at the start of a pass.
- **Fix:** such clears are drawn as one triangle over the pass in the open render encoder (`clear_color_tri` / `clear_ds_tri` in `nvn_mtl.m`, adapted from MacNativeGames, MIT). The pipeline has the pass's formats, the clear's mask as the write mask of its slot and no writes to the other slots. Depth is `ALWAYS` (and written for a depth clear), stencil `REPLACE` through the clear's write mask, the scissor is clamped as for draws, and visibility counting is off for the triangle. The value comes from the frame arena through the triangle's own argument tables, and the draws' tables are put back after it. A clear outside a pass opens the pass as a draw would. Clears a load action can express keep it. Two cases are still cleared whole, logged once: a depth / stencil clear with a scissor outside a pass, and a partial stencil write mask.
- **Found on:** [The Legend of Zelda: Tears of the Kingdom](../../dm/games/0100F2C0115B6000/README.md): it issues the first whole-cleared case (a depth clear scissored to 8×8 of a 64×64 target), and so does Wonder ([Super Mario Bros. Wonder](../../dm/games/010015100B514000/README.md)). With `render_cond` ([Conditional rendering evaluated at replay](#conditional-rendering-evaluated-at-replay)) TOTK's scissored colour clears are all skipped; without it they are 50×50 tiles of a 500×400 target cleared to opaque black, about five a frame. [Metroid Dread](../../dm/games/010093801237C000/README.md) logged the red line once while loading on its smoke route.

### Depth16 load-clears match fragment writes

- **Symptom:** a tile grid in Ultrahand and Recall highlights; an `EQUAL` depth test rejects fragments writing the same depth as a cleared Depth16 target.
- **Cause:** Apple GPUs truncate a `Depth16Unorm` load-clear but round fragment depth. A clear of 0.5 stores 32767 while a fragment writing 0.5 stores 32768.
- **Fix:** `nvn_depth16_clear_value` selects the nearest D16 value in double precision and adds a quarter-unit margin inside both its truncation and rounding bins, surviving Metal's conversion of the descriptor to float. Both attachment load-clears (`rp_begin_ex_`) and whole-texture clears (`clear_tex`) use it only for `Depth16Unorm`. Other formats and clears drawn as fragments retain their existing conversion. `t_depth16_clear` compares both production command paths with fragment-written reference depths, including half-bin boundaries and adjacent floats.
- **Found on:** [The Legend of Zelda: Tears of the Kingdom](../../dm/games/0100F2C0115B6000/README.md), reported in MacNativeGames commit `3d90e41` and ported in PR #199. The conversion difference is reproduced here with a synthetic Mac GPU test; the game's highlight effect and the iPhone have not been rechecked.

### Integer colour clears

- **Cause:** `nvnCommandBufferClearColori` / `ClearColorui` clear an integer target.
- **Fix:** recorded as a float clear; both replay paths convert the value to the attachment's integer type.
- **Found on:** [Paper Mario: The Thousand-Year Door](../../dm/games/0100ECD018EBE000/README.md) (an integer target cleared once Mario stands on Rogueport's docks, about frame 12,300 of a new file).

### Same-pass feedback read through a snapshot

- **Symptom:** solid magenta blocks, exactly (255, 0, 255), hard-edged and aligned to the 16-pixel grid (16×16, sometimes two stacked): Super Mario 3D World and Super Mario Odyssey showed them only on the iPhone; Captain Toad and Origami King on a Mac, Apple M6, Captain Toad in about half the frames of the opening course, moving with the falling leaves. On an RG11B10F target (no alpha) the blocks are pure black or neon green, (0, 252, 0), and flicker, sometimes only part of a tile: Super Mario Bros. Wonder on an Apple M6 and an M1, most visible on the speech bubbles of dialogue; or non-finite pixels that bloom spreads into green blobs (NieR:Automata on the Mac).
- **Cause:** a draw writes an attachment while sampling it (agl's post-effect program writes the RGB10A2 image as an attachment while sampling it; Origami King's anti-aliasing and NieR's FXAA likewise). Writing and sampling one attachment within a render pass is undefined in Metal: the M4 Pro happens to return the old content, while the A20 Pro and the Apple M6 now and then return whole 16×16 blocks as (1, 0, 1), probably blocks of the compressed render target caught while another tile stores them. On the Switch the read returns the content from before the draw.
- **Fix:** `fb_prepare` in `nvn_mtl.m`, for every game. A draw whose fragment stage samples the level and layer of a colour attachment of its pass, and that writes that attachment (its channel mask and the shader's fragment outputs) or follows a draw of the same Metal pass that wrote it, samples a snapshot instead: the host ends the pass, copies the attachment's level and layer into a snapshot texture in the replay stream and binds it for that draw. NVN makes rendering visible to texture reads only through `nvnCommandBufferBarrier`, so a snapshot taken since the game's last barrier (and in the same submission) holds everything the game may expect to read: later such draws reuse it without ending the pass. A pass that read the attachment directly ends before a draw that writes it, so the earlier reads cannot see these writes in other tiles. A draw that samples an attachment nothing in its pass writes reads it directly, and a sampled view that spans more levels than the attachment's one (mip-chain passes) is left as it is. The binding scan covers combined slots 0–127 and separate texture slots 128–255 (`NTEX`), using the argument encoder's handle lookup; an earlier bound of 128 silently skipped separate bindings. Before this rule, each game's profile listed its shaders in a `feedback_snap` key (six profiles), and a shader not yet seen to break stayed unprotected. `DM_NVN_FB_SNAP=0` turns the snapshots off, `all` takes a fresh one for every draw that samples an attachment of its pass.
- **Check:** `make -C dm/gfx/tests GAME=<id> check_t_feedback` exercises the production snapshot and argument encoder at slots 0, 128 and 255 (GPU readback must retain a red snapshot after the original attachment is overwritten green, then read the green original on the next draw), and the rule: a draw that writes nothing reads an unwritten attachment directly, a writing draw takes a snapshot, the next one reuses it without ending the pass, a writing draw after a direct read ends the pass, a game barrier makes the next one take a fresh snapshot. 69 checks pass with Metal API validation on the Apple M6. On that Mac without a list (2026-10-30): Origami King's castle route went from blocks of up to 273 magenta pixels in its screenshots with `DM_NVN_FB_SNAP=0` to 0–8 single pixels; Wonder's opening course from blocks in 4 of 97 screenshots to 0 of 160; NieR's opening flight from 662,086 non-finite pixels in 19 `DM_NVN_MAGSCAN` frames to none. Each snapshotted only the shaders its profile had listed.
- **Found on:**
  - [Super Mario 3D World + Bowser's Fury](../../dm/games/010028600EBDA000/README.md): `DM_NVN_MAGSCAN` on the A20 Pro found the blocks first in the 1920×1080 RGB10A2 composite (`ser=30`) in World 1-1, in the pass whose shader `66a71a3081b91b9a` renders into that texture while sampling it. They kept appearing with the sparkle particle `5e4de7561c670fee` dropped, so that earlier suspect (picked by position) is not the cause. The profile listed `66a71a3081b91b9a` and `30e3ccb0bd304ead` (which samples a G-buffer target of its own pass on the title screen); in 1-1 that is one 8 MB copy per frame. `3e8567da37eb28a1` renders level 1 of a texture while its view covers levels 0–4 (mip-chain passes) and is left as it is. The source said the fix was in place and waiting for a device run when written; the README lists the game as tested and playable on the iPhone.
  - [NieR:Automata The End of YoRHa Edition](../../dm/games/010056B015FE8000/README.md): its FXAA (`fd2c47b73f0e7e24`, `filter09.pso`) samples the RG11B10F scene target it renders into through a **separate** texture bind, and `fb_prepare` took only combined slots (`b->reg >= 128` was skipped), so the key had no effect. On the Mac some of its reads came back NaN in red and blue; the bloom spread them into green blobs and the eye adaptation darkened the frame (`DM_NVN_MAGSCAN`: 50,000+ non-finite pixels a frame over the opening's ocean, 0 with the snapshot). Separate texture binds now take the snapshot too.
  - [Captain Toad: Treasure Tracker](../../dm/games/01009BF0072D4000/README.md): agl's post-effect program 987 (`54f58a7cab608766`, the same program as 3D World's `66a71a3081b91b9a` in another build); `DM_NVN_FB_SNAP=all` cleared every frame and named this one shader, which the profile then listed.
  - [Super Mario Odyssey](../../dm/games/0100000000010000/README.md#rendering): 16×16 magenta blocks on an iPhone 17 Pro (1.4.1), reported with `DM_NVN_FB_SNAP` runs that named the same agl post-effect program (`5345f3231650f0b7`) on the 1280×720 RGB10A2 image ([seedds/nxnative#544](https://github.com/seedds/nxnative/pull/544)). Odyssey draws it so only in handheld mode (the iPhone's): docked, it renders at 1600×900 and the post-effect reads another target. The report proposed a sixth list; the host now finds such draws itself, and on the Mac with `DM_OPMODE=0` the rule snapshots this shader from frame 617, where the iPhone's log had named it.
  - [Super Mario Bros. Wonder](../../dm/games/010015100B514000/README.md#rendering): black and green blocks on the Mac (Apple M6; an M1 in [seedds/nxnative#377](https://github.com/seedds/nxnative/issues/377)) from its two feedback draws `a7e5c6fd501cf21f` and `22a61cb1ec732aef` on the RG11B10F scene, the same keys in v0 and 1.2.1, which had shown nothing on the iPhone. Screenshots with a flicker detector: v0's opening course 6 of 160 frames with blocks before, 0 of 150 with both listed; 1.2.1's Badge House dialogue 23 of 158 before, 0 of 158 after.
  - [The Legend of Zelda: Breath of the Wild](../../dm/games/01007EF00011E000/README.md): the cost case (below): over a thousand draws a frame sample a G-buffer target of their own pass, about 460 of them writing it.
  - [Paper Mario: The Origami King](../../dm/games/0100A3900C3E2000/README.md#rendering): magenta 16×16 blocks on the Mac (Apple M6) from its anti-aliasing pass `8dc20835c07cd7ff` (`shaders/aa.bfsha`) on the 1920×1080 RGB10A2 scene, the only shader `DM_NVN_FB_SNAP=all` snapshotted; about one block a frame at Peach's castle before, none with it listed.
- **Note:** the cost. Breath of the Wild's G-buffer decals write and sample their own targets (`4d3d5a4408c2e8d9`, `753d0169ae3ce4f0` and others on the 1600×900 G-buffer), about 460 such draws a frame outdoors on the Great Plateau; a fresh snapshot for each (`DM_NVN_FB_SNAP=all`) takes the Mac's GPU time from about 4 to 28 ms a frame (frame time 16.6 → 36.6 ms before). Between the game's barriers they need about ten snapshots a frame, and about 50 draws reuse each: GPU time p50 3.5–4.1 ms with `DM_NVN_FB_SNAP=0` and 3.7–4.5 ms with the rule over four runs each (2026-10-30, Apple M6, the outdoor save looking around, frames 4,800–6,900; the frame time stays at its 30 fps budget). The decals had shown no blocks on the iPhone; the snapshot makes them read what the Switch guarantees rather than what the tile happened to hold. `DM_NVN_FB_SNAP=all` with a screenshot detector shows whether blocks come from such a draw at all, and a pass dump (`N … same-pass feedback sampling` lines after the draw's `K` keys) names the shaders.

### Lower-left window origin

- **Symptom:** text a game renders into textures for the title and the menus comes out upside down, while the scene looks right.
- **Cause:** a game that never calls `nvnDeviceSetWindowOriginMode` keeps NVN's default, lower-left (OpenGL), where NDC y = -1 lands on a render target's first memory row. Read as upper-left, every texture the game renders and samples came out flipped and cancelled out, but not the text, and the game copies the frame with `MIRROR_Y`.
- **Fix:** viewport and scissor rectangles, fragment coordinates, copies and texture coordinates address the same memory rows in both conventions, so the host flips the direction inside the viewport (negative viewport height) and flips the window image at present and in raw screenshots (`g_origin_ll` in `nvn_mtl.m`). Facing also follows the [raster flip captured at queue initialization](#queue-initialization-captures-the-raster-origin).
- **Found on:** [The Legend of Zelda: Link's Awakening](../../dm/games/01006BB00C6F0000/README.md); the six games before it all switch to upper-left.
- **Note:** the window's Y-direction system register under this origin is open ([Open: the window Y-direction register `SR_Y_DIRECTION`](shaders.md#open-the-window-y-direction-register-sr_y_direction)); the OpenGL layer renders through this origin ([GL orientation through the lower-left origin](#gl-orientation-through-the-lower-left-origin)), and Absolum combines it with a viewport swizzle ([Viewport swizzles applied as a flipped viewport](#viewport-swizzles-applied-as-a-flipped-viewport)).

### Queue initialization captures the raster origin

- **Symptom:** geometry appears inside out and almost black; a fullscreen indirect-lighting triangle is entirely culled even though its vertex data and polygon state match the game.
- **Cause:** NVN emits `SET_WINDOW_ORIGIN.FLIP_Y` into a queue's initial GPU state. `DeviceSetWindowOriginMode` only changes the device field that later viewport construction reads; it does not rewrite an existing queue's raster flip. Deriving Metal winding from the current device origin loses this distinction when the game creates a queue before changing the origin. Reversing winding globally fixes that sequence but breaks games that set their origin first.
- **Fix:** `queue_t.origin_ll` captures the device origin in `nvnQueueInitialize`. Each submission selects that queue's raster origin under the submission lock. Metal winding uses this captured origin; viewport direction and presentation keep using the device origin. The full-coverage proof also accounts for the difference between these origins, and for a negative-Y viewport swizzle.
- **Check:** `t_queue_origin` alternates two queues created with different origins on one device. GPU readback checks CW/CCW triangles, both current device origins, every cull mode, `front_facing`, negative-Y swizzles and the full-coverage proof: 389 checks pass with direct and deferred Metal encoding; restoring the previous winding expression fails 48. The complete Metal suite passes. Mario Wonder's full smoke route passes with the fix.
- **Found on:** [Xenoblade Chronicles 2](../../dm/games/0100E95004038000/README.md#rendering), with native SDK initialization evidence and the comparison with Mario Wonder recorded there.

### The residency set committed before a present

- **Symptom:** a pink window with every command buffer ignored while headless runs look right: the first presents fail on the display command buffer with `kIOGPUCommandBufferCallbackErrorPageFault`, and after a few of those macOS ignores every submission of the process ("Ignored (for causing prior/excessive GPU errors)").
- **Cause:** the game presents its window texture in its first frames before drawing into it; the texture was made on that first resolution in the present path and added to the residency set (`res_add`), but only a submission commits the set, so the display command buffer sampled a texture outside the committed set. Headless runs never present, which is why they looked right.
- **Fix:** `present_now` commits the residency set after resolving the presented texture (`res_commit`, free when nothing changed), for every game.
- **Found on:** [Super Smash Bros. Ultimate](../../dm/games/01006A800016E000/README.md) (13.0.5, `DM_WINDOW=1`).
- **Check:** Breath of the Wild windowed with the change: its title, 60 fps, no GPU error.

### A present snapshot's copy needs the same residency commit

- **Symptom:** with present snapshots on (`DM_PRESENT_SNAP`, the iOS launcher's **Frame buffering**), a frozen, corrupted picture from the first presents; the first error is already `kIOGPUCommandBufferCallbackErrorSubmissionsIgnored` ("Ignored (for causing prior/excessive GPU errors)") on the display command buffer, then on every upload, segment and submission command buffer, and `[RED] present snapshots: the previous copy into a ring slot did not finish within 2 s`. With snapshots off the same game runs.
- **Cause:** the case of [the entry above](#the-residency-set-committed-before-a-present), on the snapshot path: `snap_take` resolves the presented texture and copies it into a ring slot on the game's queue before `present_now` runs, and only `present_now` committed the residency set. A window texture presented before any submission had used it was outside the committed set when the copy read it. The copy's command buffer has no error handler, so its fault shows only as the ignored command buffers after it.
- **Fix:** `snap_take` commits the residency set after resolving the source (`res_commit`, free when nothing changed), for every game.
- **Found on:** [DRAGON QUEST XI S](../../dm/games/01006C300E9F0000/README.md) 1.0.4 on an iPad mini 7 (A17 Pro), which presents three times before its first submission ([GitHub issue #626](https://github.com/seedds/nxnative/issues/626)). The reporter's Apple M4 test did not fault without the fix.
- **Not checked:** the iPad with the fix.

### A CPU-written window texture resolved where the present is queued

- **Symptom:** an abort at the first present: `[RED] upload batches belong to the submit thread only: up_begin called on thread 'nvn-present-link'`, with `pkg_upload`, `tex_mtl` and `present_now` in the backtrace.
- **Cause:** the game fills its window textures with `nvnTextureWriteTexels` at boot and presents one before drawing into it. A texture whose content comes from its storage (CPU-written, packaged) is uploaded when it is first resolved, in an upload batch only the submit thread may open, and the first resolution of this one was `present_now` on the present thread.
- **Fix:** `present_enqueue`, on the thread that queues the present, resolves a storage texture (`tex_from_storage`) when that is the submit thread and commits the upload batch (`up_flush`), so the display command buffer comes after the upload on the queue and the present thread finds the texture uploaded. For every game; a texture that is not taken from its storage is resolved on the present thread as before.
- **Found on:** [Bastion](../../dm/games/010038600B27E000/README.md) (1.0.0, SDK 5.4.0: both 1920x1080 window textures written by `main+0x9374`).

### The present upscales through MetalFX

- **Symptom:** a game that renders below the screen's resolution looks soft on a phone, in a large Mac window or on a 4K screen.
- **Cause:** the drawable has the layer's native pixel size (`front_ios.m`, `front_mac.m`), and the present pass (`present_encode_m4`) scaled the presented texture into it bilinearly.
- **Fix:** `DM_PRESENT_UPSCALE=metalfx` (the iOS launcher's **Upscaling**; off by default on every platform, no profile key): where the picture's rectangle on the canvas (`present_viewport`) is larger than the content (`fx_wanted`), the present copies the content to the origin of a texture of its size (MetalFX reads from the origin, so a crop with an offset works too), MetalFX's spatial scaler (`MTL4FXSpatialScaler`, perceptual colour processing: the input is the raw gamma-encoded bytes the present samples) scales it into a texture of the rectangle's size in the present's Metal 4 command buffer, and the present pass draws that 1:1 (`fx_encode`). Letterbox, the lower-left origin and the drawable format stay the present pass's. The copy waits for the queue's earlier work and ends with a producer barrier that the scaler's encoders wait behind. A new size or format makes a new scaler after the presents on the GPU finish, at most once every 30 presents (a window being resized shows bilinear frames meanwhile); a size MetalFX refuses stays bilinear. Whole-window captures and `DM_NVN_SHOT_OUT` screenshots draw the picture the same way (`present_offscreen_m4`), with separate scaler state and resources retained until GPU completion; `DM_NVN_SHOT` and `DM_CTL` "shot" still save the game's own frame. Tests: `t_present_crop` (sizing, offset crops, letterbox, sRGB bytes, lower-left origin, standard fallback, resize throttling and asynchronous whole-window capture).
- **Found on:** [The Legend of Zelda: Breath of the Wild — upscaling and measurements](../../dm/games/01007EF00011E000/README.md#upscaling-current).
- **Limit:** the scaler takes the presented frame, including any filtering and HUD drawing the game already performed. Feeding it an earlier scene target would mean replacing a draw of the game's own, and nothing general identifies which draw is a plain upscale. Scaler support is checked at runtime; unsupported devices, sizes and formats use standard scaling.

### The NVN present crops by the vi layer crop

- **Symptom:** in handheld mode the picture fills only two thirds of the screen's width and height, in the bottom-left corner (the top-left with the upper-left origin), the rest black.
- **Cause:** the game keeps its 1920x1080 window textures in handheld mode, draws 1280x720 into them and crops through `vi::SetLayerCrop`, never `nvnWindowSetCrop`. The host recorded the layer crop (`hle_vi.c`) only for the Vulkan present ([Swapchain pre-transform and layer crop](#swapchain-pre-transform-and-layer-crop)); the NVN present read only the window's crop and showed the whole texture.
- **Fix:** the NVN present shows the window's own crop when the game set one, else the vi layer crop (`present_crop` in `hle_nvn.c`); on the Switch both become the crop of the buffer queued to the layer. A layer crop that does not fit the window texture is reported once in red and the whole texture is shown, as before.
- **Check:** `t_present_crop`: the window's crop wins, the layer crop is used without one, one larger than the texture is ignored, and a real `nvnQueuePresentTexture` queues the layer crop (that check fails with the old call). On an iPhone 15 Pro in handheld mode Link's Awakening's picture fills the screen's height.
- **Found on:** [The Legend of Zelda: Link's Awakening](../../dm/games/01006BB00C6F0000/README.md#rendering) (1.1.0, handheld mode on the iPhone).

## Blend, depth and stencil

### No writes to colour outputs the shader does not write

- **Symptom:** undefined values blended into attachments the fragment shader leaves alone.
- **Cause:** Maxwell leaves targets outside the shader's output map untouched; on Metal such an attachment gets undefined values blended in.
- **Fix:** pipelines get a zero write mask and no blending for colour outputs the shader does not write (reflection `colors`, `color_known` in `nvn_refl.m`).
- **Found on:** [Super Mario 3D World + Bowser's Fury](../../dm/games/010028600EBDA000/README.md): volume draws after the G-buffer (`50d813761ca3f1f9` and others) write only outputs 0 and 2, with blending and all channels enabled on targets 1 and 3.
- **Check:** all five games' regressions were unchanged by it.

### The alpha test through a library of its own

- **Symptom:** foliage, hair and fences drawn as solid quads (the parts the texture leaves transparent filled with its colour or black), dissolve effects solid instead of breaking up; once per run `SetAlphaRef …: the host has no alpha test`.
- **Cause:** `nvnColorStateSetAlphaTest` and `nvnCommandBufferSetAlphaRef` select Maxwell's fixed-function alpha test: the alpha a pixel shader writes to colour 0 is compared with the reference before blending, and the fragment is dropped when the comparison fails. Metal has none, and the host recorded the function without applying it and only logged the reference.
- **Fix:** the chain builds a second library for every pixel shader whose colour 0 has a float alpha, `<key>_ba` (`dm/gfx/tools/dmsh_alpha.py`): the same entry points (`main0`, and `main0_u` / `main0_m` / `main0_d` where the shader has them), each taking the function and the reference from fragment buffer `DMSH_ALPHA_BUFFER` (30) and testing colour 0's alpha before each return, `discard_fragment()` when it fails. `SetAlphaRef` is recorded (`OP_ALPHA_REF`). A pipeline drawn with a function other than `ALWAYS` has `pso_key.atest` set and takes its fragment from that library (`atest_key`, `at_fn`, loaded on first need); its draws bind the function and reference, a copy in the frame arena per value and pass (`at_bind`). The function and the reference are data, so one pipeline serves every function and a reference that changes every draw keeps it; draws without the test keep the base library, whose size and load time do not change. As in OpenGL, there is no test when colour 0 goes to an integer target. `[[early_fragment_tests]]` stays in the variant: such a shader has its depth written before the test, on Maxwell too. Alpha-tested draws count as discarding for the first-draw load elision (`first_draw_covers`). Prewarm rows written before the key field read as alpha test off (`pso_skey_parse`). Not covered: a readable-tile merged draw (`bf_fn`) draws without the test, with a red line naming the shader. `t_alpha.m` replays every function against references 0, 0.3125, 0.5, 1 and NaN over an alpha ramp, and `test_dmsh_alpha.py` checks the variant and compiles it for the Mac and the iPhone.
- **Found on:** reported on [DARK SOULS: REMASTERED](../../dm/games/01004AB00A260000/README.md) (grass and ferns in Firelink Shrine and Darkroot Garden, PR #32), [ASTRAL CHAIN](../../dm/games/01007300020FA000/README.md) (the death effect's tendrils, `EffectOpacityBlood`, solid black) and [Animal Crossing: New Horizons](../../dm/games/01006F8002326000/README.md) (the island map, issue #73, PR #430), each with an implementation of its own; not yet checked in those games with this one.

### Logic operations through a library of its own

- **Symptom:** data a game builds in an integer target by combining draws comes out wrong; in Xenoblade Chronicles 2 indoor lighting has hard-edged dark boxes (world-space boxes in perspective, darker with the time of day) and lighter translucent rectangles elsewhere. A pass dump shows `lo=7` (or any value other than 3) on the `D` lines of the draws that write the target.
- **Cause:** `nvnColorStateSetLogicOp` makes the hardware combine the bits a pixel shader writes with the bits already in the target (CLEAR, AND, …, OR, …, SET) in place of blending; as in OpenGL and Vulkan it acts on integer targets. Metal has none, and the host recorded the operation without applying it, so every draw wrote with COPY. Xenoblade Chronicles 2 builds a per-pixel list of up to four light probes in an RG32Uint target: each probe's box writes its index into the next free byte with OR, and every other fragment writes 0 and relies on OR to leave the list as it is. With COPY each fragment replaced the list, so inside every probe volume the indirect-lighting pass read the wrong probes or none.
- **Fix:** the chain builds a library for every pixel shader with integer colour outputs, `<key>_bl` (`dm/gfx/tools/dmsh_logic.py`): its integer entry points (`main0_u`, `main0_m`) read each integer output's attachment (`[[color(n)]]`, framebuffer fetch) and combine it with the output by the operation and the target's channel masks from fragment buffer `DMSH_LOGIC_BUFFER` (29) before each return. Each read depends on the function constant `DMSH_LOGIC_FC + n` (Metal refuses a pipeline that reads an output whose target the pass lacks); the host specializes the entry per set of targets and keeps each (`lo_fn`). A pipeline drawn with an operation other than COPY whose fragment takes an integer entry point has `pso_key.logic` set (`lop_key`; the field was padding, so older prewarm rows read it as off), and its draws bind the operation and the masks (8, 16 or 32 bits a channel, RGB10A2's 10 and 2), a copy in the frame arena per value and pass (`lo_bind`). The operation is data, so one pipeline serves every operation; draws with COPY keep the base library and read no attachment. Logic-op draws count as reading the target for the first-draw load elision (`first_draw_covers`) and end a readable-tile merged pass before them. Not covered, with a red line: a float, normalized or signed integer target, and a merged pass's first phase. `t_logic.m` replays all 16 operations into RG32Uint and RGBA8Uint targets; `test_dmsh_logic.py` checks the variant and compiles it for the Mac and the iPhone.
- **Found on:** [Xenoblade Chronicles 2](../../dm/games/0100E95004038000/README.md#rendering): the probe-list writers, `shd_lgt.wishp` var3 (`ef07fd3d5046164f`, `aa9a0923524b7e46`, `2717a0aa47361bbd`, `d95874c161deb77d`, `f24b58784a33adea`), read by the indirect-lighting pass `93d0e7a7c14cdfb0` (GitHub issue #643).

### Advanced blend modes as Porter-Duff factors

- **Symptom:** `nvnBlendStateSetAdvancedMode 8` (SRC_OVER) logged and blended with the state's own functions.
- **Cause:** the hardware ignores the blend state's own functions while an advanced mode is set.
- **Fix:** the blend state keeps the mode, the premultiplied-source flag and the overlap (`blend_st` in `nvn_obj.h`), and the pipeline (`adv_blend` in `nvn_mtl.m`) blends the Porter-Duff modes (ZERO, SRC, DST, SRC/DST_OVER, _IN, _OUT, _ATOP, XOR, the PLUS modes) with the fixed-function factors they amount to under uncorrelated overlap, with premultiplied colours as NV_blend_equation_advanced defines them; a source that is not premultiplied is multiplied by As where the source factor is ONE. Multiply, screen, overlay, the HSL modes and the other overlaps need the destination colour in the shader and keep the state's functions, with a red line naming the mode.
- **Found on:** [Mario vs. Donkey Kong](../../dm/games/0100B99019412000/README.md) (SRC_OVER, on one blend state in the levels).

### Depth clamp

- **Fix:** `SetDepthClamp` is recorded (`OP_DEPTH_CLAMP`) and replayed as Metal's depth clip mode (it used to be ignored).
- **Found on:** [Fire Emblem: Three Houses](../../dm/games/010055D009F78000/README.md) (the game turns it on).

### Telling depth rejection from no rasterization

- `DM_NVN_DEPTHOVR` (depth test forced to `ALWAYS`) with `HILITE` tells "rejected by depth" from "never rasterized". `TEXSNAP` copies used to run before the pass they were meant to show (classic-queue command buffer committed ahead of the Metal 4 one); they now go through the replay's copy encoder.
- **Found on:** [The Legend of Zelda: Tears of the Kingdom](../../dm/games/0100F2C0115B6000/README.md), tracing the tile lighting: the G-buffer class byte selects per-class half-resolution passes through a depth buffer of class values (`gl_FragDepth = mix(0.5, 1, nibble-swapped class / 255)`, then full-screen or per-tile quads with depth `EQUAL`).

### Stencil-mode texture views read through `X32_Stencil8`

- **Symptom:** striped lighting: black and white bands that follow depth on every lit surface, as if every pixel were in or out of shadow at random.
- **Cause:** a shader that reads a depth-stencil texture through a view whose `nvnTextureViewSetDepthStencilMode` is `STENCIL`: the host ignored the mode and bound depth, so a stencil test read bits of the depth value's float bits.
- **Fix:** `tex_by_id` binds an `X32_Stencil8` view for such a view. The shader declares a float texture (the translator has no integer texture type) and takes the raw bits with `as_type<uint>`, and a read of the integer view gives the stencil value in those bits. Metal allows such a view only of a texture with the pixel-format-view usage: Apple GPUs read it correctly without, but the API validation layer aborts at the first one (PR #106, Luigi's Mansion 3). Upgrading the texture when the view appears recreated the depth buffer while it was attached, and the next occlusion-counted draw crashed inside `setVisibilityResultMode`, so every depth-stencil texture has that usage from the start (`tex_desc`; Vulkan depth-stencil images too, `vkCreateImage`), which costs nothing measured (on an M4 Pro the same allocated size and GPU time); `t_stencil_view` checks it under validation.
- **Found on:** [Pokémon Legends: Z-A](../../dm/games/0100F43008C44000/README.md): the deferred lighting pixel shader (`ead6e2a32540b19a`, 31 bindings) first reads the depth-stencil buffer through such a view, tests stencil bit 6 and discards. [Luigi's Mansion 3](../../dm/games/0100DCA0064A6000/README.md) (PR #106, the validation abort).
- **Note:** inputs ruled out on the way in Z-A: the G-buffer albedo, the normals (12-bit pairs packed into 3 bytes, noisy by design), the screen-space shadow mask, the scaled depth copies and conditional rendering (`render_cond` changes nothing in this game and stays off).

### Stencil-mode textures from the texture builder

- **Symptom:** a character drawn as a dithered silhouette inside a dithered square (DRAGON QUEST VII Reimagined's hero).
- **Cause:** Unreal's stencil shader resources are second textures on the depth buffer's storage built with `nvnTextureBuilderSetDepthStencilMode(STENCIL)`, which the host only logged, so the character occlusion mask read depth where it tests stencil bits.
- **Fix:** the builder's mode now goes to the texture (`tex_t.stencil`), whose sampling view is the `X32_Stencil8` one a stencil-mode texture view already got.
- **Found on:** [DRAGON QUEST VII Reimagined](../../dm/games/0100A9D01C446000/README.md) (the character occlusion mask, `edbfc7a088be545e`).

### Conservative rasterization remains unimplemented

- **Symptom:** `[nvn] SetConservativeRasterEnable on: ignored by host for now`, followed by `[RED] NVN unimplemented function called: nvnCommandBufferSetConservativeRasterDilate`.
- **Cause:** `hle_nvn.c` ignores the enable setter and has no implementation for the dilation setter. The requested raster coverage state never reaches Metal.
- **Fix:** **Open.** Neither setter has been implemented. The opening indoor scene renders and accepts input, but the visual contribution of the missing coverage state has not been isolated. The diagnostic remains visible.
- **Found on:** [Pokémon Scarlet](../../dm/games/0100A3D008C5C000/README.md#open) (1.0.0, the first playable bedroom).

## Vertex input and draws

### Integer vertex inputs

- **Symptom:** characters (skinned models) invisible or stretched into streaks while the level renders; `vertex attribute format … does not match shader input type …` for a remaining mismatch.
- **Cause:** integer vertex inputs (bone indices) translated as float: without PC reflection the translator declares every vertex input `float4`. Skinned models read their bone index (`R8UI` / `RG8UI` / `RGBA8UI`) as raw integer bits (`as_type<int>(in.m_N.x) * 48`); Metal converted the integers to floats, and every bone index was garbage.
- **Fix:** `dmsh_build.py` (`int_inputs`) now re-translates a vertex shader with `uint` inputs when every use of an input is an integer bit cast (529 of 4,854 in Mario), and the host makes the Metal vertex format agree with the declared type (`vfmt_for_ct`; signedness swaps of 32-bit components and 32-bit float→int reinterpretation keep the bits, while float-type formats and 8- and 16-bit integers of the other sign go through [shadow vertex inputs](#shadow-vertex-inputs), next entry). A remaining mismatch is reported as `vertex attribute format … does not match shader input type …`.
- **Check:** finding the draws: log model file ranges with `DM_PROBE=main:480f0` (x1 = file data, x2 = size), match the vertex/index buffer addresses in `DM_NVN_PASSDUMP_ALL` against them, then `DM_NVN_HILITE` their fragment shader.
- **Found on:** [Super Mario Bros. Wonder](../../dm/games/010015100B514000/README.md) (skinned characters).

### Shadow vertex inputs

- **Symptom:** red lines 89 and 96 (`vconv_bind`, the CPU conversion every draw); about a quarter of Age of Calamity's replay thread in battle.
- **Cause:** an input that `int_inputs` declares an integer may still be fed a format of another class. A float-type format (half, unorm / snorm, 10:10:10:2, 11:11:10) leaves the converted float32 bits in the register; an 8- or 16-bit integer of the other signedness is widened by the format's own sign (Fire Emblem: Three Houses, [CPU conversion of vertex attributes the input type cannot take](#cpu-conversion-of-vertex-attributes-the-input-type-cannot-take)). Metal reads a format only into an input of its own class, so the replay used to convert those attributes on the CPU every draw (`vconv_bind`).
- **Fix:** shadow inputs (`<key>_bv`, `dm/gfx/tools/dmsh_vin.py`): the build also writes a side library for each such vertex shader. In it, every integer input is declared again as a `float4` and as the integer of the other sign, at Metal attribute indices 16–30 (NVN uses 0–15), and the body starts with `in.m_N = dm_in.m_N | as_type<T>(dm_in.m_N_vf) | as_type<T>(dm_in.m_N_vo)`. The host sends each attribute to the index of its format's class and the zero buffer to the others (`vin_ct`, `vin_on` in `nvn_mtl.m`; pipeline keys unchanged), so a pipeline with any mix of formats reads Maxwell's register bits. The float shadows are assigned first: with more than 7 integer inputs the last ones get only the float shadow (169 of 8,201 inputs in Age of Calamity).
- **Note:** a format with no shadow keeps the CPU conversion, as do transform feedback draws (`main0_tf` has no variant) and `DM_NVN_VCONV_CPU=1`. The host loads a side library only for a pipeline that routes an attribute to a shadow, but the build cannot tell which shaders will need one (an input used only as an integer may hold bone indices or float bits), so it writes them all. Shadows cover only integer inputs, so 8- and 16-bit integer formats feeding float inputs still go through the CPU.
- **Found on:**
  - [Hyrule Warriors: Age of Calamity](../../dm/games/01002B00111A2000/README.md): 2,259 libraries, 77 MB each for Mac and iOS. Its Mac battle at 60 fps against the CPU conversion: 0 vertices converted instead of 545,000 per submission, submit + present 10.0 → 5.7 ms a frame, CPU 3.97 → 2.44 W, GPU unchanged, the same picture.
  - Other games have 0–2,000 libraries (at most 31 MB on iOS), except [Monster Hunter Rise](../../dm/games/0100B04011742000/README.md): 16,781 libraries, 344 MB on iOS (21% of its shader libraries, 1.5% of its IPA), and its Mac and iPhone runs so far load none. Its 8- and 16-bit integer formats feeding float inputs (red line 99, about 60,000 vertices per submission on its Mac route into the opening) still go through the CPU.

### Pulling vertex inputs

- **Cause:** a pipeline's vertex descriptor fixes the vertex layout it is drawn with, so a shader pair drawn with a layout it has no pipeline for waits until one is compiled.
- **Fix:** pulling inputs (`<key>_bp`, `dm/gfx/tools/dmsh_pull.py`, decoder `dm/gfx/tools/dmsh_pull.metal`): a side library of every vertex shader with stage inputs, whose `main0` / `main0_z` have no `[[stage_in]]`. They read their inputs themselves from a per-draw layout block at buffer 16 (`dm_vlayout`): per stream the base address, stride and divisor, and per NVN attribute the raw attribute state word. The base instance comes from `[[base_instance]]`, so indirect draws are right too. `dm_fetch` decodes the NVN format at run time into the register words Maxwell's fetch gives the shader, and the input takes them with `as_type`. A pipeline made with it has no vertex descriptor, so it serves every vertex layout a shader pair is drawn with; it is meant for drawing while the pipeline for the draw's own layout is still being built.
- **Note:** the words are bit-identical to Metal's vertex-descriptor fetch for every format `vfmt` knows, and to the host's CPU conversion for the integer-read-as-float formats. unorm / snorm go through the `unpack_*` builtins, because a plain division under fast math is off by one unit in the last place for some values; NaNs of R11G11B10F come out canonical, as from Metal's fetch. With a divisor the element is `base instance + (instance - base instance) / divisor`, Metal's own rule. Positions match the vertex-descriptor pipeline's (`[[invariant]]`, preserved invariance).
- **Note:** the run-time format decode costs GPU time: on an M2 Max, 8 attributes in a vertex-bound draw of tiny visible triangles took 65 % longer (about 1.0 ms per million vertices) than with the vertex descriptor. With the formats as compile-time constants it was 9 %, and with the whole layout compiled in, 0. So these pipelines only stand in until the fast one is built. Other entry points (transform feedback, geometry capture, layer) get no variant; shaders without stage inputs need none, since their pipelines have no vertex descriptor.
- **Symptom:** an unsigned iOS build reports `[RED] pulling library ... not usable (no library)` and its draws wait for pipelines even with the profile's `pso_mtl4 on`, or packaging with `IOS_PULL=1` fails with `SKIPS[@]: unbound variable`.
- **Cause:** the IPA packer used to strip `_bp.metallib` unless `IOS_PULL=1`, independently of the runtime's profile default. The inclusion path expanded an empty array under `set -u`, which macOS Bash 3.2 treats as unset.
- **Fix:** `build_ipa.sh` takes the default library inclusion from the generated `DM_GAME_PSO_MTL4` compiled into the host; `IOS_PULL=0` / `1` still overrides it. Packing options always contain `--store`, so both inclusion and exclusion work under Bash 3.2. A runtime `DM_PSO_MTL4=1` override for a profile with the path off needs an IPA built with `IOS_PULL=1` too. An IPA that packs a [pipeline archive made offline](../development.md#the-pipeline-archive-made-offline) (`pso/`) always carries the `_bp` libraries, whatever `IOS_PULL` says, since the archive's bases are made of them.
- **Check:** `dm/gfx/tests/t_pull.m` (the words against Metal's fetch and the CPU conversion), `t_pull_inv.m` (a depth prepass with one pipeline and depth-equal with the other), `test_dmsh_pull.py`; `dm/ios/tests/test_profile_pack.py` packs tiny fixtures through the actual archive step and checks profile defaults, explicit overrides and an IPA with a pipeline archive in the ZIP.
- **Found on:** [The Legend of Zelda: Breath of the Wild](../../dm/games/01007EF00011E000/README.md): draws that waited for their pipeline on a cold start.

### Float32 vertex padding through integer inputs

- **Symptom:** a fullscreen post-process draw writes no color, then a later blur composite darkens scenery while the character remains visible.
- **Cause:** reinterpreting Float1/2/3 as UInt1/2/3 preserves supplied bits but pads missing `w` with integer `1`. A shader that bitcasts the input back to float receives `w=1.4e-45`, rather than `1.0`, and can clip the whole draw. Float4 has no missing components.
- **Fix:** short float32 vectors use the existing float shadow input, or CPU expansion with float `(0,0,0,1)` defaults when shadows are unavailable or disabled. Float4 keeps direct reinterpretation. `t_float_pad` checks signed/unsigned GPU fetch, CPU fallback and Float4 controls.
- **Found on:** [Xenoblade Chronicles: Definitive Edition](../../dm/games/0100FF500E34A000/README.md) (the game profile is a separate, pending contribution).

### CPU conversion of vertex attributes the input type cannot take

- **Symptom:** `Vertex attribute m_36(5) of type uint4 cannot be read using MTLAttributeFormatHalf2` (draws dropped: black silhouettes); UVs collapse onto one texel (flat tan characters); vertices far out of view (negative 16-bit values widened with zeros).
- **Cause:** `int_inputs` declares an input `uint` when its first translation only bit-casts it, and the shader then takes it back with `as_type<float>`. Maxwell's fetch converts by the format and the register holds the float32 bits, and widens integers by the format's signedness, whatever type the shader gives the register. Metal refuses a float-type format for an integer input; reading the raw bytes as integers gives denormals. For a signed format on an unsigned input `vfmt_for_ct` swapped `Short4` for `UShort4`, which keeps the 16 bits but widens them with zeros, so every negative value read as 32,768–65,535.
- **Fix:** the replay converts such attributes (half, unorm / snorm 8 and 16, 10:10:10:2, 11:11:10, BGRA8 into an int / uint input) on the CPU into float32 bits, four components with the fetch's (0, 0, 0, 1.0) defaults, in the frame arena, and binds them as UInt4 / Int4 on buffer slots 1–12 (`vconv_bind`, once per range and layout per submission; red line 89). 8- and 16-bit integer formats whose signedness differs from the input's go through the same conversion (`vconv_int` in `nvn_mtl.m`, red line 96 once): 32-bit values extended by the format's own sign, missing components (0, 0, 0, 1) as integers.
- **Found on:** [Fire Emblem: Three Houses](../../dm/games/010055D009F78000/README.md): KTGL's character and soldier shaders, fed a Half2 (UVs); also [Hyrule Warriors: Age of Calamity](../../dm/games/01002B00111A2000/README.md)'s soldiers (flat tan). The ground under close-up battle cameras was flat steel blue: the terrain's vertex shader (`56778feb1cfdee7e`) reads its grid position from an `RGBA16I` attribute (x and z the grid cell, y the height, which spans the whole int16 range), and so does the side pass that draws the river surface into targets of its own (`db725c85ca060403`).
- **Note:** [shadow vertex inputs](#shadow-vertex-inputs) (`dmsh_vin.py`) have since replaced both conversions; they remain for the formats shadow inputs cannot take (and for transform feedback draws and `DM_NVN_VCONV_CPU=1`), and the profile-side answer for one shader is [Integer-typed vertex inputs fed normalized formats](shaders.md#integer-typed-vertex-inputs-fed-normalized-formats).
- **Note:** how the steel-blue ground was traced, since two steps misled: where the ground was missing nothing wrote the depth (reversed-Z, cleared to 0), the lighting takes depth 0 for sky and paints the fog colour, and the never-cleared G-buffer colour targets kept an old image there (cobblestones of a mesh under the terrain, which from the map camera showed through the gaps like a road). A `HILITE` colour over the gap was stale too (the never-cleared albedo), and the end-of-frame depth showed 0 there. Recomputing every draw's clip positions from `CBDUMP` data showed that no draw of the shader reached the gap; then the side pass's layer, which showed only scattered tiles of the river, led to the vertex format. Ruled out on the way: depth clamp (Metal's clip and clamp modes gave the same depth), the pass without a depth attachment (142595 is a screen-space decal pass: it samples the depth and writes albedo and normals), polygon offset (none), dropped draws.
- **Note:** to confirm in Three Houses: 64-pixel rectangles in the albedo where decals land. The decal pass (`417a523053457352`, slots 16 and 18) and the lighting (`094a2d11253f126c`, `f54830a75e07e14a`, slots 18–20) read their decal and light lists from texture buffers that the translation declared `texture2d`, because those handles have no PC type (`texture type mismatch: shader declares 2, texture is 9`); skipping the decal pass removed the rectangles. Since row wrap ([Buffer textures read by 1D integer fetches (row wrap)](#buffer-textures-read-by-1d-integer-fetches-row-wrap), general) they read the real lists: slot 18 holds 1,052,640 elements, 65 rows. On the Mac prologue route the torches and burning houses now light the battle map and the close-up ground (they lit nothing before), and the blood decals take the scene's light instead of showing as dark blue patches. The rectangles did not appear on that route in either build (no 64-pixel structure in the close-up frames), so the scene where they were seen still has to be checked.

### Vertex formats Metal lacks

- **Symptom:** `vertex attribute format … not mapped` (printed once).
- **Cause / Fix:** Mario uses `RGB10A2SN` (0x69) → `MTLVertexFormatInt1010102Normalized`. Unmapped formats fall back to a 4-component read and print the line once. The integer-read-as-float formats (`*_UI2F` / `*_I2F`, 0x51–0x68), which Metal has no vertex format for, are converted on the CPU at replay like the other conversions (`vconv_i2f`).
- **Found on:** [Super Mario Bros. Wonder](../../dm/games/010015100B514000/README.md) (`RGB10A2SN`); [The Legend of Zelda: Breath of the Wild](../../dm/games/01007EF00011E000/README.md) has an `RG8_UI2F` attribute.

### Vertex streams 14 and 15 at Metal slots 14 and 15

- **Symptom:** the assertion `buffer index (31) must be < 31`.
- **Cause:** the host bound NVN stream *n* to Metal vertex buffer 16 + *n*, but Metal has slots 0–30 only (30 is the host's constant fallback), so stream 15 went to 31.
- **Fix:** translated shaders use only `buffer(0)`, so streams 14 and 15 now go to slots 14 and 15 (`VB_SLOT`).
- **Found on:** [13 Sentinels: Aegis Rim](../../dm/games/01003FC01670C000/README.md) (a minute and a half into the prologue).

### Vertex streams at addresses that are not 4-byte aligned

- **Symptom:** Scaleform fills come out as solid white or light grey sheets over the whole screen, hard-edged triangles and bands, and the menu text is missing (a language list or a title screen that is all white behind its button prompt).
- **Cause:** Metal reads a vertex buffer only from a 4-byte-aligned address: bound at an address 2 mod 4, every vertex was read 2 bytes early. NVN takes any address, and Scaleform's vertex streams (16-byte vertices: two RGBA8 attributes and an RG32F position) sit at addresses such as `…6d6a`. The positions became garbage spanning the screen, and the shapes, white with alpha 0.2–0.7 by their colour transforms, overlapped many times.
- **Fix:** `bind_vbufs` copies a stream whose address is not 4-byte aligned into the submission's arena (`vbuf_unaligned`; one copy per address and size until guest writes or pool mappings change, up to 64 MB) and binds the copy. CPU copies require a host-readable, non-sparse range without pending GPU writers in this or an earlier submission; otherwise `vbuf_prepare` encodes an ordered GPU copy before the render encoder, including feedback and geometry captures. Submissions and pool mappings invalidate copies; buffer and shader writes invalidate the copies they can overlap, so unrelated uniform updates keep their vertex copies. The log's `vertex bindings` line counts the copies; `t_vbuf` checks byte-aligned readbacks, reuse, queued writes, writes between draws and pool replacement. The index buffers at addresses 2 mod 4 (16-bit indices) needed nothing.
- **Found on:** Batman: Arkham Knight (`0100ACD0163D0000`; its profile and note are in a PR of their own) (Scaleform GFx; 2–13 copies of 3–18 MB a frame in the menus and at the title, which the draws' vertex ranges could narrow). With the copy the language menu and the title screen draw right.

### Vertex fetches past a stream's bound size

- **Symptom:** hard-edged translucent slabs and triangles over the scene that move with the camera, where a full-screen pass blends an effect in (Super Mario Odyssey: white wedges through the Cascade Kingdom's waterfall mist, one edge through the centre of the screen).
- **Cause:** NVN binds each vertex stream with a size (`nvnCommandBufferBindVertexBuffers`), and Maxwell's fetch reads zeros past it: a draw may ask for more vertices than the stream holds, and those vertices collapse into degenerate triangles. Metal's fetch has no such limit and read on into whatever followed the stream in the pool. agl's half-resolution composite draws `DrawArrays(TRIANGLES, 0, 9)` from a 36-byte stream holding one full-screen triangle; vertices 6–8 read (0, 0), (0, 1), (0.98, 0.20) from the pool's next bytes, a second triangle that blended the mist in twice. A numpy model of the composite from the frame's inputs matched the GPU's output everywhere but there, where the output matched the composite applied twice (1 % against 39 % error).
- **Fix:** before the draw's render encoder, `vbuf_prepare` takes the inputs the vertex shader reads and the draw's last element per stream (`vstream_last`: the last vertex of a direct draw, the last instance of a per-instance stream, element 0 of a stride-0 stream), and where that reaches past the bound size (`vbuf_need`, element sizes from `vattr_bytes`), binds the stream as a copy of its bound bytes followed by zeros up to the last byte read. The copy is `vbuf_unaligned`'s (per submission, CPU or ordered GPU copy); the vertex table, the pulling pipelines' layout and transform feedback take it, and the CPU-converted inputs (`vconv_bind`) convert zero bytes past the bound range. `t_vbuf` reads the zeros back on the GPU; `t_pull` checks `vattr_bytes` against Metal's element sizes.
- **Open:** per-vertex streams of indexed draws, indirect draws and the batched geometry captures are not bounded (their last element is not known on the CPU without scanning the indices or reading the arguments).
- **Found on:** [Super Mario Odyssey](../../dm/games/0100000000010000/README.md) (GitHub issue #558): the composite of agl's half-resolution translucent pass (`alProgramShader`, vertex `40cc99352976d0ff`, pixel `934386ce027e72be`), every frame the half-resolution effects draw.

### Programs bound per stage

- **Symptom:** scenes and characters black, only foliage, light shafts and the HUD drawn; pass dumps full of `Z … draw skipped: no program bound`.
- **Cause:** NVN's `BindProgram(program, stageBits)` binds per stage, and a null program unbinds just those stages. Metroid Dread's depth prepass calls `BindProgram(program, vertex | fragment)`, then `BindProgram(null, fragment)`, and draws depth with the vertex shader alone. The host replaced its single bound program on every bind, so a null bind meant "no program bound", and all of the prepass's ~140 draws per frame were dropped. The depth buffer stayed empty, and the G-buffer passes, which test depth `EQUAL` without writing, passed no pixel.
- **Fix:** the replay tracks the program per stage (`bind_stages` in `nvn_mtl.m`). When the stages come from different programs, or the fragment stage is unbound, it builds a composite program, which gives a vertex-only pipeline for the prepass. Games that always bind every stage from one program (Mario, Engage) are unchanged.
- **Found on:** [Metroid Dread](../../dm/games/010093801237C000/README.md): the combinations it uses are (program, 0x3), (null, 0x2), (null, 0x7). [13 Sentinels: Aegis Rim](../../dm/games/01003FC01670C000/README.md) builds one program per GLSLC output and pairs them only through these composites ([Single-stage programs paired with a cover](shaders.md#single-stage-programs-paired-with-a-cover)).
- **Note:** pass dumps print a `Z` line wherever a draw is dropped (no program, no pipeline, empty scissor, both faces culled, no render pass). That is how this one was found: 144 `Z … draw skipped: no program bound` lines in a frame whose G-buffer pass had draws but stayed black.

### Composite program taken again after a replay state restore

- **Symptom:** `[RED] failed to create render pipeline (vertex 790573a52b9c5053_b fragment f39fb42850f50ecd_b): Fragment input(s) user(locn0),user(locn1) … not written by vertex shader`, once on entering the first investigation; `texture type mismatch: shader declares a cube, texture is 2D` (a pixel shader run with another pair's bindings).
- **Cause:** a draw ran with the vertex shader of another Shader object (`Legacy Shaders/VertexLit`'s shadow caster with the pixel shader of `PSYNC/BG_AlphaTest`, whose own pass pairs it with `00b462fe0dec6e06`). Unity binds the vertex and fragment programs apart, so every draw's pair is a composite of `bind_stages`, one of a ring of 64. The precompile prediction (`pso_predict_rest`, at a submission's first pipeline miss) saves the replay state, replays the rest of the submission's binds and restores it; in a 280-draw submission it made more than 64 composites, reused the slot the saved `S.prog` named, and the draws after it up to the next bind ran with that slot's new pair. The fusion probe and redraw and the deferred-draw replay restore `S` from copies the same way.
- **Fix:** each restore takes the composite again from the per-stage bindings it restored (`prog_resolve`, logged as `combined program taken again after a state restore`); a draw already under way keeps its `NvProg`, whose release is deferred. Every game.
- **Found on:** [AI: THE SOMNIUM FILES](../../dm/games/010089B00D09C000/README.md) (Unity 2017.4).
- **Check:** two runs each from one save with one key script, prewarm off: the old host logged the `texture type mismatch` line both times, the fixed host no red line, with the slot taken again twice.

### Compute programs bound apart from graphics programs

- **Symptom:** `no program bound before the draw`, `program has no vertex shader` (a draw after a dispatch is dropped); `the dispatched program has no compute shader` (a dispatch after a graphics bind).
- **Cause:** `BindProgram(program, stageBits)` with the compute bit replaced the one bound program, so a draw after a dispatch found the compute program (or none), and a dispatch after a graphics bind found no compute shader.
- **Fix:** the replay keeps the compute program apart (`S.cprog` in `nvn_mtl.m`, and `g_pp_cprog` in the pass analysis).
- **Found on:** [Hyrule Warriors: Age of Calamity](../../dm/games/01002B00111A2000/README.md): the game interleaves dispatches and draws; its intro movie's NV12 → RGB draw was dropped and the movie played black under its "+ Skip" prompt.

### Instanced array draws

- Instanced array draws (`DrawArraysInstanced`) carry instance count and base instance in the `OP_DRAW` record.
- **Found on:** [Super Mario Bros. Wonder](../../dm/games/010015100B514000/README.md).

### 8-bit index buffers

- **Cause:** Metal has only 16/32-bit indices.
- **Fix:** 8-bit indices are widened to 16-bit at replay into the frame arena.
- **Found on:** [Super Mario Bros. Wonder](../../dm/games/010015100B514000/README.md): its full-screen passes and its final copy use them.

### 8-bit indices widened on the GPU after a write in the same submission

- **Symptom:** a red line: the 8-bit index buffer had GPU-side writes in the submission (indices read stale).
- **Cause:** Metal has no 8-bit index type, so replay widens 8-bit indices to 16-bit on the CPU. When a copy, update or fill encoded earlier in the submission covers them (`pend_hits`), the CPU reads the bytes from before that write.
- **Fix:** those draws are widened on the GPU (`wide_run`): a compute pass reads the indices from a 16-byte-aligned address, with the byte shift as a constant, and writes 16-bit ones into the frame arena. As in `ixc_run`, the first such draw widens every such draw after it up to the next buffer write outside a render pass, so only a draw met inside an open render pass with no widening yet would split it. Draws whose indices no write covers keep the CPU widening. Log line `8-bit index GPU expansion`.
- **Found on:** [The Legend of Zelda: Tears of the Kingdom](../../dm/games/0100F2C0115B6000/README.md): about one draw per widening, up to a dozen widenings a frame on the title and load screens, no pass split.

### Triangle fans and indexed quads

- **Cause:** Metal has neither triangle fans nor quads.
- **Fix:** non-indexed fans draw through a shared `(0, i, i+1)` index buffer with `first` as the base vertex; indexed fans and quads are expanded on the CPU into a 32-bit triangle list in the frame arena at replay (`nvn_mtl.m`, as for 8-bit indices).
- **Found on:** [13 Sentinels: Aegis Rim](../../dm/games/01003FC01670C000/README.md).

### Indirect draws and dispatches read by the GPU

- **Symptom:** indirect draws whose record the GPU writes earlier in the frame cannot be read on the CPU at replay; GPU-driven effects drawn as indirect quads, which Metal has no primitive for.
- **Cause:** `nvnCommandBufferDrawArraysIndirect`'s record `{count, instances, first, base instance}` has the layout of `MTLDrawPrimitivesIndirectArguments` (and `DrawElementsIndirect`'s `{count, instances, first index, base vertex, base instance}` that of `MTLDrawIndexedPrimitivesIndirectArguments`), but quads, fans and indexed draws with 8-bit indices have no Metal form.
- **Fix:** the replay issues Metal indirect draws from the pool buffer. `ixc_run` in `nvn_mtl.m` converts records of quads, fans and indexed ones with 8-bit indices with a compute pass into indexed indirect arguments in the frame arena, and the draw indexes the shared quad / fan index buffers (indexed ones get a 32-bit list expanded on the GPU). A compute pass cannot run inside a render pass, so when the first such draw is met it converts every such draw up to the next buffer write outside a render pass (copy, update, fill, texture → buffer, dispatch; they bump `g_wr_epoch`). Each record is then read after its last writer, and only a draw met inside an already open render pass splits it. `DispatchComputeIndirect` → `dispatchThreadgroupsWithIndirectBuffer`; when the shader reads the driver segment, the GPU copies the counts into c0 + 0x200 first.
- **Found on:** [Hyrule Warriors: Age of Calamity](../../dm/games/01002B00111A2000/README.md) (its GPU-driven effects are indirect quads).
- **Check:** `DM_NVN_IXCLOG=<n>` logs the first n conversions (record → arguments) once the GPU has run them.

### Indirect-count multi-draws

- **Symptom:** an empty G-buffer pass (the title screen showed only the UI); later, the submitting thread waiting for the GPU before each such draw (36–54 fps in Kamura Village on an iPhone).
- **Cause:** `nvnCommandBufferMultiDrawElementsIndirectCount` / `MultiDrawArraysIndirectCount` were empty. The scene is GPU-driven: compute culling writes the draw records (stride 20) and a u32 count, then up to `max` draws (1–49 per call) are made from them. Metal has no draw count read by the GPU.
- **Fix:** each call is recorded as `max` ordinary indirect draws that carry the count's address and their index (capped at 1,024). A compute pass copies each such draw's record into the frame arena, or zeros past the count, and the draw reads the copy, so a draw past the count draws nothing (`mdx_run` in `nvn_mtl.m`). Like `ixc_run`, it runs at the first such draw with no copy and takes every later one up to the next write that could change a record or count; copies are keyed by record and count address, since the game draws the same records with two counts. Draws of one multi-draw replayed back to back are encoded without the rest of `draw` (`mdx_next`).
- **Found on:** [Monster Hunter Rise](../../dm/games/0100B04011742000/README.md).
- **Note:** the replay used to commit its work and wait for the GPU before the first such draw after each GPU write, then read the count on the CPU (`mdi_wait`, now only for quads, fans and 8-bit indices). In Kamura Village that wait held the submitting thread 14 of its 20 ms a frame on an iPhone (36–54 fps). On the Mac the same scene's submit took 20 ms of wall time for 6.1 ms of work, and now 5.1 ms, all of it work.

### `nvnCommandBufferDrawTexture`

- **Symptom:** a black screen while the frame loop runs at full rate, with `[RED] NVN unimplemented function called: nvnCommandBufferDrawTexture`; once drawn, the picture alternates frame by frame between the right image and another texture's (a solid colour, a still image).
- **Cause:** the call draws a texture region (texels, through the handle's sampler) into the destination region of the bound colour targets (pixels) without a shader of the game's, and the host had no implementation. Its handle holds IDs of the texture and sampler pools the command buffer bound, as a bind's does: read as IDs of the first pool, a game that draws from a second pool got that pool's textures at the same IDs.
- **Fix:** recorded as `OP_DRAW_TEX` with the handle moved to the bound pools, as `bind_handles` does (`hle_nvn.c`), and replayed by `draw_tex` (`nvn_mtl.m`): its own render pass per bound colour target after the pass in progress, the pending clears landed first, with the scissor and channel mask; the replay's analyses (pass fusion, deferral, clear hoisting, the store lookahead) treat it as a texture copy. Region coordinates map to the targets' rows directly in either window origin, since the host keeps the Switch's memory layout. Blending is not applied (`[RED] DrawTexture with blending on`), and integer, depth and compressed targets are not drawn.
- **Found on:** [Streets of Rage 4](../../dm/games/0100EC9010258000/README.md): its scene target gets the movie frame this way (the intro, the title's flames), from movie textures registered at IDs 256 and 257 of a second texture pool.

### Rasterizer discard preserves vertex storage writes

- **Symptom:** the HUD and sky render but the battle's characters and terrain are absent; the replay logs `draw skipped: rasterizer discard` between model draws.
- **Cause:** the replay returned from every discarded draw without active transform feedback. Rasterizer discard only suppresses rasterization: vertex storage writes and atomics still execute. Metal additionally requires a void-returning vertex function when rasterization is disabled.
- **Fix:** the offline builder adds `main0_discard` to vertex shaders with writable reflected bindings. It retains the original body and early returns and drops only the stage outputs. Replay uses that entry in a separate pipeline with no fragment stage and rasterization disabled, with the ordinary array/indexed/instanced draw machinery and GPU-write tracking. Switching discard marks the pipeline dirty; discarded draws cannot prove an attachment fully overwritten. Pure vertex shaders with neither storage writes nor active feedback can still be skipped. Transform feedback retains its capture entry.
- **Check:** `t_rast_discard` passes 19 checks under Metal validation: array/indexed storage writes despite an empty scissor and both faces culled, two instances, unchanged clear colours, normal rendering between two discard phases, and an ordered storage-write consumer. `test_discard.py` compiles a generated entry with side effects before two different returns for Mac and iOS.
- **Found on:** [Xenoblade Chronicles 3](../../dm/games/010074F013262000/README.md#files-and-shaders); its note tracks the gameplay verification.

### Primitive barriers order vertex storage writes

- **Symptom:** exploding meshes and displaced model parts after vertex-only work; native post-vertex captures can contain valid positions for some meshes while other palettes are incorrect.
- **Cause:** `ORDER_PRIMITIVES` was omitted from the pass-splitting condition after shader storage writes. A primitive barrier orders earlier vertex work before later vertex work, including its storage writes. Metal does not supply that ordering between draws in one render encoder. Xenoblade Chronicles 3 uses barrier `0x21` after vertex shaders update its bone matrices; fragment-only barrier handling left dependent vertex work unordered.
- **Fix:** a primitive barrier after shader writes ends the render pass, as fragment barriers already do. The next encoder's full consumer barrier supplies the required visibility.
- **Check:** `t_rast_discard` passes 19 GPU checks under Metal validation, including a 4,096-vertex storage producer followed by a primitive barrier and a vertex consumer in the same submission.
- **Found on:** [Xenoblade Chronicles 3](../../dm/games/010074F013262000/README.md#files-and-shaders); `boot24barrier` removes the exploding meshes.

### Ordering barriers before a draw that writes

- **Symptom:** a character's mesh stretched for one frame into a long wedge or sheet that reaches another character, and other characters missing in that frame; intermittent (about one frame in a hundred near a group of characters). A pass dump shows `barrier bits 0x1 (render pass open)` before vertex-only draws (`fs=-`, `discard=1`) that bind a storage buffer `rw` which the draws before them read `ro`.
- **Cause:** a barrier with an ordering bit (ORDER_PRIMITIVES, ORDER_FRAGMENTS, ORDER_FRAGMENTS_TILED) also makes the earlier work finish before a later draw writes, so a write cannot reach memory those draws still read. The host ended the pass at such a barrier only when the pass already had shader writes ([Primitive barriers order vertex storage writes](#primitive-barriers-order-vertex-storage-writes)), so a write after it ran in the same Metal pass as the readers, where Metal gives no order between draws. Xenoblade Chronicles 2 skins each character with a vertex-only draw (`shd_post.wishp` var122) that writes its blended bone matrices from slot 0 of one shared 384,000-byte buffer, which the character's draws then read, and puts ORDER_PRIMITIVES before the next character's: one dumped frame had 91 such draws, 43 of them in a pass with the previous character's draws, whose later vertices could read the next character's matrices.
- **Fix:** an ordering barrier in an open pass without shader writes leaves a mark (`g_pass_order`: primitives, fragments), and the next draw whose program writes an image or a storage buffer is ordered after the pass's earlier draws (`order_draw`). When those draws read memory only in their vertex stage (`order_note`: anything bound in a later stage but samplers and driver data counts), or the barrier orders only primitives (NVN leaves the earlier fragments unordered then too), a barrier inside the pass from the vertex stage to the writer's stages does it (`barrierAfterEncoderStages`), and the pass keeps its attachments; otherwise, for a write in a geometry or tessellation stage, or in a merged or deferred pass, the pass ends first (Metal has no barrier from the fragment stage back to the vertex stage inside a pass). A draw without writes changes nothing. Ending the pass instead split Xenoblade Chronicles 2's geometry pass about a hundred times a frame (510 passes instead of 400, GPU p50 8.8 → 10.3 ms at Goldmouth Return Port); the in-pass barrier keeps 400 passes and the GPU time (8.2 to 8.7 ms). `t_rast_discard` checks six cases under Metal validation.
- **Found on:** [Xenoblade Chronicles 2](../../dm/games/0100E95004038000/README.md#rendering): the stretched geometry of GitHub issue #643, at Goldmouth Return Port and in the Argentum Bazaar.

### Transform feedback captured by a vertex entry point

- **Symptom:** characters collapsed into one thin spike (vertex streams read from feedback buffers that were never written); a character covered by a solid box while it moves (its fur shells pulled toward lagged positions that were never written); a pass dump shows draws with a vertex shader and no fragment shader (`fs=-`) before the draws that read them, and `Y tf begin … written 0/0/0/0` with no `T … tf capture` line.
- **Cause:** a game that skins on the GPU with transform feedback: a vertex-only program runs under `SetRasterizerDiscard` between `BeginTransformFeedback` / `EndTransformFeedback` and writes into feedback buffers that later draws read as vertex streams. The host ignored all of it, so the streams kept whatever was there. Metal has no feedback stage.
- **Fix:**
  - the layout comes from the program's control section (`tf_layout` in `dmsh_build.py`): +0x6dc u16 strides, +0x6e8 per-buffer output counts, +0x6ec buffer count, and per buffer b the output locations (0x20 + n) at +0xdc + 0x80 b and matching **byte** component counts at +0x4dc + 0x80 b. Multiple outputs are interleaved in that order. Unknown forms get a red line and no capture entry;
  - `main0_tf` (`vs_tf`) retains the body and stores the output bits into Metal vertex buffers 8–11, with the GPU-prepared capture record at buffer 14. The reflection lists `entry_tf` and `tf_strides`. Geometry programs give their output reader the same entry; it gathers the packed point/line/triangle indices while writing linear feedback records;
  - `nvn_feedback.inc` keeps offsets and counts on the GPU. Begin clears them; End/Pause save them in the game's opaque 32-byte control buffer; Resume restores them. A compute helper bounds each capture by all active streams and complete primitives. `DrawTransformFeedback` uses the saved count as indirect array-draw arguments. Captures, counter copies and consuming draws follow encoder ordering, and captured ranges enter GPU-write tracking. Plain vertex capture supports array point/line/triangle lists with or without rasterizer discard, including instances; indexed/indirect vertex capture remains open. Geometry capture uses the existing general assembly and compute path. `DM_NVN_PASSDUMP` prints the records as `Y tf …` and array captures as `T … tf capture`.
- **Check:** `test_transform_feedback.py` compiles generated vertex/geometry entries for Mac and iOS; `t_transform_feedback` checks interleaving, saved offsets, resume, bounded capture, GPU-produced geometry counts, complete primitives and a following draw that consumes the saved count in the same submission.
- **Found on:** [Pokémon Legends: Z-A](../../dm/games/0100F43008C44000/README.md): the character preview. 28 such shaders (e.g. `681cc42e48c0bbc0` in the `special/imgui.trsha` pack; skin indices in attribute 12, weights in 13) write positions (location 0 xyz, 12 bytes a vertex) and packed normal and tangent bits (locations 1 and 2, x only, 4 bytes) into three feedback buffers; the character draws read them as vertex streams 0–2 (`RGB32F`, `RGB10A2SN`, `RGB10A2SN`). Every buffer in this game holds one output from x on (strides 12/4/4, 12/12/12, 12/4, 12). The game draws these while its frame target is bound. The pass dump showed a pass of 19 draws with `fs=-` before the character pass. Tears of the Kingdom's 14,766 and Ace Attorney's 2,475 vertex shaders have no feedback at all.
  - [Donkey Kong Country: Tropical Freeze](../../dm/games/0100C1F0051B6000/README.md): DK's fur. While DK moved, his fur shells (an instanced draw, `648304c43bbe3463` / `5b5ffba62bca9e0a`, three shells on the body's index buffer) covered him as one solid box. Each frame a vertex-only draw (`6979dd3cdbd62373` / `7dcdaed991c74bfe`, 3,400 vertices) captures the fur's lagged positions into one buffer, two outputs per vertex (xyz each, stride 24; output count 2, component bytes `03 03`), and the shells read them as vertex attribute 6. Two things kept the buffer at zero (`DM_NVN_KEYDUMP=5b5ffba62bca9e0a`: stream 6 held zeros and `2.3e24`): the old one-output rule rejected the layout (`[RED] … transform feedback buffer 0 has a layout of unknown form`), and the game draws the capture with rasterization on (no fragment shader, colour mask 0, no `SetRasterizerDiscard`), which the host did not capture. Four of its 11,644 vertex shaders have this form; over Z-A's and this game's 23,277 vertex shaders together, the old and new readings give identical layouts and capture code for all 28 shaders the old rule took.

- **Found on:** [Xenoblade Chronicles 3](../../dm/games/010074F013262000/README.md#files-and-shaders): effect vertex and geometry programs use interleaved outputs, including eleven outputs in a 172-byte stream, and draw from saved feedback counts.

### Geometry-shader draws encoded a run at a time

- **Symptom:** a scene drawn with a geometry shader per mesh runs at 5 to 15 fps on the Mac, with the submitting thread or the GPU taking most of the frame.
- **Cause:** the general geometry replay (`nvn_geometry.inc`) handled each draw on its own. It waited for the GPU before every indexed draw (the indices are assembled on the CPU), ended the open render pass, and ran four encoders: the vertex capture, the geometry kernel, the index compaction in one GPU thread, and the raster draw reopening the pass with its loads.
- **Fix:**
  - CPU index assembly waits when pending or current/prior GPU writes, unknown ranges or sparse aliases prevent a safe read (`geo_index_wait`); native capture retains GPU ordering, and unique capture indices use a bounded bitset instead of `qsort`;
  - the compaction (`k_nvn_geo_pack_msl` in `nvn_geometry.h`) uses three blocked parallel prefix-scan stages (`geo_pack_count`, `geo_pack_scan`, `geo_pack_write`) with threadgroup barriers;
  - the first geometry draw of a run looks ahead (`geo_run_walk`, with state replay only) across the geometry draws that follow it with only state, query reports and event signals in between. It encodes all their vertex captures in one render pass and all their kernels and compactions in one compute pass. Each later draw of the run then only rasterizes its prepared output in the open render pass, omitting inactive colour attachments across the run when `geo_color_omit` holds.
- **Found on:** [NieR:Automata The End of YoRHa Edition](../../dm/games/010056B015FE8000/README.md) and [US 1.0.3](../../dm/games/010056B015FE8000/README.md): about 70 index-build draws a frame in the flight section and up to 932 in heavy outdoor combat.

### Helper encoders end the open copy encoder first

- **Symptom:** `SIGSEGV` in `-[AGXG18GFamilyComputeContext_mtlnext performEndEncoding]` (from `rp_begin_ex_`, or in its `dealloc` on the encoding thread); Metal validation (`MTL_DEBUG_LAYER=1 MTL_DEBUG_LAYER_ERROR_MODE=nslog`) names it: "Command buffer already has an open command encoder".
- **Cause:** `tf_draw` opened its render encoder while the copy encoder (`g_blit`) was open, which the inline updates `ubd_land` copies there leave behind, as does a copy or a dispatch just before it.
- **Fix:** every other helper pass ends `g_blit` before it opens its own encoder, and now `tf_draw` does too (GitHub issue #101).
- **Found on:** [Pokémon Legends: Z-A](../../dm/games/0100F43008C44000/README.md): two minutes into a new game, about frame 3390 on the Mac, with the encoding thread on and off.

### Viewport swizzles applied as a flipped viewport

- **Symptom:** the whole picture upside down (Absolum's title logo and "Press Any Button" mirrored top to bottom); a red-reporting stub for `nvnCommandBufferSetViewportSwizzles`.
- **Cause:** the game keeps NVN's lower-left window origin (handled as for Link's Awakening, [Lower-left window origin](#lower-left-window-origin)) and, twice a frame, sets viewport 0's swizzle with `nvnCommandBufferSetViewportSwizzles` to (x, −y, z, w), which negates clip-space y: how a renderer with OpenGL heritage flips its picture.
- **Fix:** the swizzle is recorded (`OP_VP_SWIZZLE`) and applied at the draw as a viewport flipped about its centre, the same mapping. Facing is decided after the swizzle on the GPU as in Metal, so the winding stays. Other swizzles (axis exchanges, negated x / z / w) give a red line and are drawn unswizzled.
- **Found on:** [Absolum](../../dm/games/0100A83022A22000/README.md) (FNA3D's NVN driver, `FNA3D_Driver_NVN.cpp`).

## Uniforms, copies and ordering

### Depth plane copies between depth formats

- **Symptom:** `[RED] texture→texture copy case not implemented: 1920x1080x1→1920x1080x1 flags 0 format 260→252 3D 0→0`.
- **Cause:** the game copies its depth-stencil target (Metal `Depth32Float_Stencil8`, 260) into a depth-only texture (`Depth32Float`, 252) of the same size. A Metal blit copies only between equal formats, and the draw path does not take depth formats.
- **Fix:** such a copy, either way between the two formats, goes through a staging buffer kept from copy to copy: the 32-bit float depth is copied out of the source with `MTLBlitOptionDepthFromDepthStencil` and into the destination's depth plane the same way (`nvn_mtl.m`, the texture copy).
- **Found on:** [EA SPORTS FC 27](../../dm/games/0100C49025D3E000/README.md) (Frostbite): from the title on.

### Inline uniform updates as ordered GPU copies

- **Cause:** reading the uniform buffer from the CPU at encode time gives the frame's *last* value, not the draw's.
- **Fix:** inline uniform updates (`CommandBufferUpdateUniformBuffer`) are replayed as in-order GPU copies (their order inside one encoder: [Metal 4 does not order operations inside one encoder](#metal-4-does-not-order-operations-inside-one-encoder); inside a pass: [Inline uniform updates inside a render pass](#inline-uniform-updates-inside-a-render-pass)). They are snapshotted at encode time (`mtl_sub_update`): the data is copied into a host-owned ring instead of being read from command memory when the GPU runs.
- **Found on:** [Super Mario Bros. Wonder](../../dm/games/010015100B514000/README.md).

### Metal 4 does not order operations inside one encoder

- **Symptom:** tall blue / textured panels that flickered frame to frame: the fountain's vertex shader pushed the water surface to the top of the screen.
- **Cause:** the host batches consecutive copies, fills and inline uniform updates (`UpdateUniformBuffer`) into one compute encoder, and Metal 4 does not order operations inside one encoder. Mario writes the same uniform slot twice in a row each frame (4 bytes of −1, then 16 bytes of wave coefficients); without an intra-encoder barrier the writes occasionally landed in reverse order, the fountain's GPU wave simulation (a 512×1 RGBA16F texture updated by render → copy back → splash pass every frame) ran with −1 as its self coefficient and diverged to ±65504.
- **Fix:** `blit_buf` now inserts `barrierAfterEncoderStages` when an operation reads or writes a guest range an earlier operation in the same encoder wrote; texture copies always get one. Render passes have their own encoder with full barriers, so they were not affected; compute dispatches share the copy encoder and always get a barrier, as texture copies do (Hyrule Warriors: Age of Calamity, [Compute dispatches share the copy encoder](#compute-dispatches-share-the-copy-encoder)).
- **Check:** `DM_NVN_BLIT_ORDER=0` turns the barriers off to reproduce.
- **Found on:** [Super Mario Bros. Wonder](../../dm/games/010015100B514000/README.md).

### Buffer copies through aliased Metal addresses

- **Symptom:** a buffer copy, inline update or fill completes, but a following copy through another Metal buffer over the same allocation reads stale bytes.
- **Cause:** Metal buffers over one allocation have distinct GPU addresses. Device visibility alone does not flush their alias caches. Sparse virtual pools also give the same physical bytes distinct guest addresses, so the copy encoder's guest-range dependency checks can miss a conflict entirely; barriers at encoder boundaries cannot order copies within that encoder.
- **Fix:** `blit_buf` marks encoders containing buffer copies, updates or fills; their start, intra-encoder and end barriers include `MTL4VisibilityOptionResourceAlias`. Operations touching a sparse virtual range (`nvn_sparse_alias`) receive conservative barriers against prior and subsequent operations, since a mapped run can span unrelated physical allocations. Ordinary buffers retain range-based batching. Texture-only and helper encoders keep their existing visibility options.
- **Check:** `make -C dm/gfx/tests GAME=010015100B514000 check_t_copy_alias` exercises two no-copy buffers over one allocation, physical-to-virtual, virtual-to-physical and virtual-to-virtual sparse aliases, copies, inline updates and both fill paths, within one encoder and across encoder boundaries, with direct and deferred encoding and Metal validation. On an M4 Pro, the original host failed 37 of 101 checks; [PR #200](https://github.com/seedds/nxnative/pull/200) alone left 24 failures from missed intra-encoder sparse dependencies; the complete fix passes all 101 in both encoding modes.
- **Found on:** synthetic regression using the sparse mapping mechanism of [Monster Hunter Rise](../../dm/games/0100B04011742000/README.md); the game and iPhone have not been rerun for this change. The no-copy buffer failure was reported by MacNativeGames (`803128e`) in PR #200 and reproduced here.

### Inline uniform updates inside a render pass

- **Symptom:** many render passes with one draw each and high submit time: Metroid Dread's cutscene frames had about 180 passes with one draw each (about 5 ms of submit time per frame on the Mac).
- **Cause:** the game updates uniforms inline (`CommandBufferUpdateUniformBuffer`) between draws, and every copy or update ended the host's render pass. This was correct but cost submit time.
- **Fix:** an inline uniform update inside a pass no longer ends it: it is deferred to the pass end (`DM_NVN_UB_DEFER=0` restores the old behaviour), and the draws after it read a shadow ([Partial-cover uniform shadows keep passes open](#partial-cover-uniform-shadows-keep-passes-open)); see [development.md, Power](../development.md#power).
- **Found on:** [Metroid Dread](../../dm/games/010093801237C000/README.md).
- **Note:** 04's Metroid Dread section (at `6a06877`) still described the old behaviour ("every copy or update ends the host's render pass"); the deferral came later (development.md's Power section), and it is now the default (`ubd_on` in `nvn_mtl.m`, off with `DM_NVN_UB_DEFER=0` or `DM_NVN_TBDR=1`).

### Partial-cover uniform shadows keep passes open

- **Symptom:** hundreds of render passes a frame and heavy attachment traffic when a game updates a small part of a large uniform block before each draw group.
- **Cause:** a draw whose uniform binding overlaps an update deferred in the open pass reads a shadow; when the deferred updates cover only part of what the shader can read, the rest must come from somewhere, and the pass used to end there (`nvn_mtl.m`, the comment above `ubd_on`).
- **Fix:** the shadows take the rest from memory (`ubp_get`, `DM_NVN_UB_PARTIAL`) and the per-shader read extents of `cb_extent.tsv` (written by a full `dmsh_build.py` run) keep those passes open. `DM_NVN_UBP_CHECK=1` compares every shadow with the GPU's memory.
- **Found on:** [The Legend of Zelda: Breath of the Wild](../../dm/games/01007EF00011E000/README.md) (2026-10-21, the user's Great Plateau save, Mac M4 Pro): a frame had about 386 render passes and loaded and stored about 900 MB of attachments (on an iPhone at 60 fps about 55 GB/s, near the memory's bandwidth); the GPU waits for each pass to finish before the next. 220 of the passes ended only because the game updates the first 64 bytes of a 64 KB vertex uniform block (`0x70c38c0000`) before each draw group while its shaders read up to 544 bytes of it (the terrain pixel shader `eb0afe555b86da79`, which indexes the block with an integer made from an interpolated value, reads the whole block). With the fix: 386 → about 165 passes, GPU p50 about 9.3 → 6.5 ms, submit 5.7 → 4.9 ms; `DM_NVN_UBP_CHECK=1` found every shadow equal to the GPU's memory (968,000 checked).
- **Note:** a storage buffer bound with size 0 once made every partly covered shadow after it in the submission refuse ([A storage buffer bound with size 0 counted as a write anywhere](#a-storage-buffer-bound-with-size-0-counted-as-a-write-anywhere)). What still splits BotW's big passes (a `DM_NVN_PASSDUMP` frame dump): the NintendoWare VFX GPU particles run one compute dispatch per emitter between draws (ten 800x450 half-resolution passes and two G-buffer passes, about 190 MB a frame; the G-buffer ones read the depth being drawn, so they cannot move ahead of the pass), and decals that sample the G-buffer right after the game sets it again. The decals sample targets of their own pass (Metal leaves that undefined; the Mac reads the stored content); `DM_NVN_FB_SNAP=all` would snapshot them at a large cost. Tried and dropped: `DM_NVN_TBDR=1` (10–15% fewer stores, more CPU, red ledger lines, and it turns the deferred uniform updates off), `DM_NVN_BARRIER=game` (no gain), same-target continuation outside TBDR mode (the decals end the pass anyway).

### A storage buffer bound with size 0 counted as a write anywhere

- **Symptom:** a scene runs at 20–27 fps where similar ones hold 60, with the GPU time about three times its usual (draw counts unchanged). The `residency set` line shows `passes ended to land them for a read` in the tens of thousands, every one `refused … other GPU writes`, and about three times the usual `load-all store-all passes`. A burst of 1,200 such refusals at each world load is the short form.
- **Cause:** the partly covered uniform shadows ([Partial-cover uniform shadows keep passes open](#partial-cover-uniform-shadows-keep-passes-open)) refuse while another GPU write of the submission may have touched the block. The writes are kept by 4 KB page (`sbw_note`). A writable storage buffer whose size the host does not know counted as a write anywhere: it set `g_sbw_over`, and every partly covered shadow after it in the submission was refused, each refusal ending the pass. A size of 0 counted as unknown, so did a write over 16 MB. Breath of the Wild's GPU particle dispatch `9f8116baffddaf81` (`cs_effect.bin` variant 3, 16 bytes a particle) binds its three outputs with `nvnCommandBufferBindStorageBuffer(…, address, 0)`, inside a 10 MB memory pool; the uniform block the draws update (`0x70c38c0000`) is in another pool.
- **Fix:** such a binding now counts as the rest of the Metal buffer its address falls in (`sbw_len`): a device pointer that runs past its buffer is out of bounds on Metal, and the host could not give it the Switch's meaning anyway. A write over 64 pages is kept as an interval (up to 64 a submission, overlapping ones merged; the next submissions see them through `gw_commit`), not by page. A write of no known size still stops the tracking.
- **Found on:** [The Legend of Zelda: Breath of the Wild](../../dm/games/01007EF00011E000/README.md) (GitHub issues #534 and #598, shrines, MacBook Air M2 and M3). The Shrine of Resurrection save shows the load burst: the 300 frames around the world load had 1,200 refusals and 107 load-all store-all passes, now 0 and 47; `DM_NVN_UBP_CHECK=1` found 146,000 shadows equal to the GPU's memory, 0 different. The reporter's log shows the same burst at each load, and 240 refusals a frame in its slow stretches.
- **Check:** `make -C dm/gfx/tests GAME=<id> check_t_sbw` (16 checks: the size-0 outputs of that dispatch do not hit the uniform block's pool, a write of no known size still stops the tracking, the interval list's limit, and the next submission's view through `gw_live`).

### An unbound uniform slot reads the zero bank

- **Symptom:** `stage 0 cb5 has no uniform buffer bound` (or another stage and slot, such as `stage 0 cb0`), once per run.
- **Cause:** the argument buffer kept a null pointer for the unbound slot. The game draws with nothing bound there; the host misses no bind. What the Switch reads from an unbound slot is not known.
- **Fix:** the slot now reads the all-zero bank, as an unbound texture slot reads the zero texture.
- **Found on:** [Paper Mario: The Thousand-Year Door](../../dm/games/0100ECD018EBE000/README.md) (at the title); [Batman: Arkham Knight](../../dm/games/0100ACD0163D0000/README.md#files-and-shaders) (`stage 0 cb0`, at boot: the first command buffer draws before the game has bound any uniform buffer).
- **Check:** a pass dump of the frame (`DM_NVN_PASSDUMP=<frame>`, frame 0 for the boot) shows the draw (`j` line) and its stage's `K` line with no `B … cb` line, and the frame's `[nvn]` call counts show whether the game called `CommandBufferBindUniformBuffer` at all.

### Compute dispatches share the copy encoder

- **Symptom:** GPU time per frame doubles with many small dispatches (Age of Calamity: GPU 9 → 18 ms a frame on the Mac; the iPhone's 15 → 51 ms, 17 fps).
- **Cause:** each dispatch had a compute encoder of its own with full queue barriers on both sides, a GPU drain per dispatch: about 10 µs of GPU each on the Mac.
- **Fix:** dispatches now go into the open copy encoder, each after a barrier inside it (as texture copies are, `blit`), with the compute argument table set once per encoder (`dispatch_enc`): about 1.3 µs each.
- **Found on:** [Hyrule Warriors: Age of Calamity](../../dm/games/01002B00111A2000/README.md): after its first cutscene the first battle runs about 900–1,500 small dispatches a frame on the Mac (an iPhone log's call counts suggest more), each after a game barrier, at the same draws and passes; GPU 7.3 → 8.1 ms across the cutscene with the change.
- **Note:** `DM_NVN_DISPATCH_OWN=1` (and `DM_NVN_PASSGPU`, which times each dispatch) gives each dispatch its own encoder again.

### Fragment-ordering barriers between draws that write images

- **Symptom:** dialog boxes with holes the size of their text, and white specks where text faded.
- **Cause:** each UI element is drawn into its own layers and then composited into the window image by one draw per layer, all in one attachment-less pass, each a read-modify-write of the image, with `nvnCommandBufferBarrier(ORDER_FRAGMENTS | INVALIDATE_TEXTURE)` (bits 0x12) between them. The host took a barrier only as an order for the next pass, and Metal orders nothing between draws of one render pass for shader writes: the text element's composite read the window before the parchment had landed and wrote the old pixels back.
- **Fix:** a barrier with `ORDER_FRAGMENTS` or `ORDER_FRAGMENTS_TILED` now ends the open pass when a draw in it wrote an image or a storage buffer (`swrite_note` in `nvn_mtl.m`), so the next draw opens a pass behind the full consumer barrier; reflection marks an image binding written when its type has write access (`nvn_refl.m`, which left `rw` unset for images).
- **Found on:** [FINAL FANTASY TACTICS - The Ivalice Chronicles](../../dm/games/010038B015560000/README.md).

### A segment committed after a buffer → texture copy

- **Symptom:** a texture copied from a staging buffer shows another texture's blocks (Catherine: Full Body's cutscene subtitle band a hard-edged dark box with a magenta stroke through it).
- **Cause:** the GPU copy read the next texture's blocks: the source was right when recorded and when encoded, but the game's resource thread wrote the next texture into the same staging block before that first submission had been committed, because the host spent a long time building pipelines inside it. On the Switch the GPU runs a submission's copies as soon as the submit returns.
- **Fix:** a segment is committed at the first pass boundary after any buffer → texture copy (`g_cut_copy`, `sub_cut` in `nvn_mtl.m`), so the copies run while the host encodes the rest; the `residency set` line counts these cuts (`N after buffer → texture copies`). This cut always happens, whatever `DM_NVN_CUT` says.
- **Found on:** [Catherine: Full Body](../../dm/games/0100BF00112C0000/README.md): the band is a 32x512 BC3 gradient copied with `nvnCommandBufferCopyBufferToTexture` (recorded at the start of a frame, `main+0x305e64`); the resource thread wrote the next texture into the staging block 64 ms later, and the host spent 300 ms building pipelines inside the submission; a few cuts per 300 frames in this game, only while it loads.
- **Check:** found with `DM_NVN_HILITE` on the band's pixel shader, `DM_NVN_TEXRAW` of the texture (decoded: opaque black and magenta blocks, not a fade) and `DM_PROBE_WATCH` on the staging address beside a log of the copy's submission completing.

### Copies a blit cannot do, drawn

- **Symptom:** a scaled texture copy skipped with a red line (Metal blits cannot scale); format-changing, depth-stencil and mirrored copies.
- **Fix:** such copies (a format change, a scaled region or a mirrored one) are drawn (`copy_t2t_draw`), one render pass per layer; a destination made without render-target use is upgraded first ([Render-target use added on demand](#render-target-use-added-on-demand)); depth and stencil are written from a fragment shader, stencil through `[[stencil]]` export from an `X32_Stencil8` view of the source.
- **Found on:** [The Legend of Zelda: Link's Awakening](../../dm/games/01006BB00C6F0000/README.md): RG11B10F → RGBA16F every frame, half-size depth-stencil copies, and a scaled `MIRROR_Y` copy of the frame to 1280×720 RGBA8. [Super Mario 3D World + Bowser's Fury](../../dm/games/010028600EBDA000/README.md): one scaled copy when leaving the title (1920×1080 → 1280×720, RGB10A2, flags `ENGINE_2D`; probably the captured frame for the transition): 04 listed it as open (skipped with a red line); `copy_t2t_draw` now draws scaled copies too (its comment in `nvn_mtl.m` names this one), so it is no longer skipped.

### `Downsample` of a single-sample texture

- **Symptom:** `[RED] Downsample case not implemented: 320x176 1 samples format 70 → 80x48`; a missing bloom.
- **Cause:** the host took `nvnCommandBufferDownsample` only as a multisample resolve and skipped the rest.
- **Fix:** a single-sample source is drawn into the destination as a whole-level scaling copy with bilinear filtering, converting the format (`copy_t2t`, through `copy_t2t_draw`; [Copies a blit cannot do, drawn](#copies-a-blit-cannot-do-drawn)).
- **Found on:** [Bayonetta 2](../../dm/games/01007960049A0000/README.md): its bloom from a 320x176 target into 80x48 and 48x32 textures, and its 1280x720 BGRA8 frame into an RGBA8 texture of the same size.

### Depth-stencil copies carry the stencil

- **Symptom:** no ambient occlusion (Mac); on a device the result depends on whatever that memory holds.
- **Cause:** the depth downsample copy left the stencil as the destination's previous content (at the time, new depth-stencil textures were not zero-filled either).
- **Fix:** the copy now carries the stencil.
- **Found on:** [The Legend of Zelda: Link's Awakening](../../dm/games/01006BB00C6F0000/README.md): the occlusion pass (`aa05724ffa62cb82`, a 480×270 R8 target cleared to 1.0) only writes where stencil bit 1 of the quarter-size depth-stencil copy is clear, so on the Mac the mask kept 1.0 everywhere.

### Periodic GPU profiles close at frame boundaries

- **Symptom:** `DM_NVN_GPUPROF=every:1` prints no per-frame reports and fills its timestamp heap across frames.
- **Cause:** reporting waited for a submission in an unselected frame. Every frame is selected at interval 1, so that condition never holds.
- **Fix:** before the next frame's first encoder, `gp_periodic_finish` snapshots the sampled frame's labels and registers a shared-event notification at its last committed fence. The report resolves the heap after all of that frame's segments complete, without a GPU wait or an extra command buffer. The heap cannot be reused while the report is pending.
- **Found on:** review of the measurement tools for [The Legend of Zelda: Breath of the Wild](../../dm/games/01007EF00011E000/README.md); reproduced with synthetic counters and completion events, without game execution. `t_gpuprof` checks consecutive and sparse frame selection, completion ordering and heap ownership; it runs in CPU CI.

### GPU profiles stamp only the encoder they began

- **Symptom:** with `DM_NVN_GPUPROF`, the host aborts minutes in on `-[AGXG16XFamilyComputeContext_mtlnext writeTimestampWithGranularity:afterStage:intoHeap:atIndex:]: unrecognized selector`, `up_flush` on the stack; or a profiled render pass with a wrong GPU time.
- **Cause:** every encoder end goes through `m4_end`, which called `gp_end` for any encoder, including the upload, diagnostics and present encoders, which are not profiled. `gp_end` closed whichever main-command-buffer encoder `gp_begin` had last opened and sent its end stamp to the encoder it was given. An upload flush inside a profiled draw pass sent the render encoder's timestamp selector to the upload compute encoder (the abort); where the kinds matched, the pass lost its own end stamp.
- **Fix:** `gp_begin` records the encoder it stamped, and `gp_end` ignores any other encoder, so the open pass keeps its label until its own end.
- **Found on:** [The Legend of Zelda: Tears of the Kingdom](../../dm/games/0100F2C0115B6000/README.md) with `DM_NVN_GPUPROF=every:300` on the Mac (issue #531; one run in four, about frame 23,000). `t_gpuprof` ends an upload encoder inside a profiled pass; it runs in CPU CI. Not rerun in the game.

## Conditional rendering and queries

### Conditional rendering evaluated at replay

- **Symptom:** the 3D scene black (targets cleared again before they are read); `[RED] SetRenderEnableConditional: the host draws anyway`; with a game that skips clears under render conditions, scenes black behind the HUD (Mario vs. Donkey Kong's levels, 1.0.1).
- **Cause:** by default the host draws everything a `SetRenderEnableConditional` would skip. A game that wraps clears in `SetRenderEnableConditional(RENDER_IF_NOT_EQUAL, rec)` … `SetRenderEnable(true)`: the condition compares the 64-bit counters at `rec` and `rec + 16`. A timestamp report puts 0 in the counter field (the time goes in the second field). The host ignored the condition and wrote the time into both fields, so every clear ran.
- **Fix:** profile key `render_cond`: `OP_RENDER_COND` is evaluated at replay from the records in memory. A timestamp report replayed earlier in the same submission counts as 0, and a condition on a samples-passed result (an occlusion query, known only when the GPU completes) keeps drawing. A pass dump shows the switches as `E` lines (`conditional render … → not drawn`) and a skipped clear as `c … skipped by conditional rendering`.
- **Found on:**
  - [The Legend of Zelda: Tears of the Kingdom](../../dm/games/0100F2C0115B6000/README.md): TOTK wraps nearly every `ClearColor` / `ClearDepthStencil` this way; each clear is followed by `ReportCounter(TIMESTAMP_TOP, rec)`, the CPU sets `rec` to 1 when a target needs a clear, and `rec + 16` is never written, so after one clear the two are equal and later conditional clears of that target are skipped. The first tile-lighting round, the half-resolution scene depth the light volumes test against (back faces `GREATER` against a buffer just cleared to 1.0 can never pass) and the light accumulation were all cleared before the composite read them.
  - [Mario vs. Donkey Kong](../../dm/games/0100B99019412000/README.md) (it skips clears under render conditions, as Tears of the Kingdom and Animal Crossing: New Horizons do).
  - Drawn unconditionally with no `render_cond`, nothing looked wrong in [Big Brain Academy: Brain vs. Brain](../../dm/games/0100620012D6E000/README.md) (no screen played looked wrong) or [DARK SOULS: REMASTERED](../../dm/games/01004AB00A260000/README.md) (nothing seen).
  - [Portal 2](../../dm/games/0100ABD01785C000/README.md) needs no `render_cond` and must not get it: NVIDIA's occlusion culling in its D3D9 layer (`IDirect3DDevice9::SetOcclusionShape`, `materialsystem.nro+0xc1130`) puts a mesh under `SetRenderEnableConditional(RENDER_IF_NOT_EQUAL, pair)` when its shape has a query, else `SetRenderEnable(true)`, so drawing everything only costs GPU time. With the key on, those conditions read 0 / 0 at replay (no report in the submission writes the pairs; memory later held `0xffff` / 0) and visible furniture vanished. **Open:** who writes those pairs and when.

## Vulkan layer

The Vulkan layer (`dm/gfx/vk/hle_vk.m`) was written for Hades; Super Mario Galaxy needed the additions below, each found from a red line or a screenshot on the route to the Star Festival.

### Vulkan shaders generated at run time

- **Symptom:** no SPIR-V file in the RomFS; SPIRV-Cross refuses a module with "Struct member does not have ArrayStride set".
- **Cause:** Hagi emits SPIR-V for each GX configuration and creates every pipeline of its pipeline database at boot. Its SPIR-V puts `ArrayStride` on the struct member (`OpMemberDecorate`) instead of the array type, which NVIDIA's driver accepts and SPIRV-Cross refuses.
- **Fix:** `DM_VK_CAPTURE=<dir>` writes the modules; `vk_shaders.py` reads capture folders like a RomFS; `fix_strides` copies the stride onto the type before translating.
- **Found on:** [Super Mario Galaxy](../../dm/games/010099C022B96000/README.md) (3,089 modules, 4,535 pipelines).

### Push constants in the next free buffer slot

- **Cause:** SPIRV-Cross binds the push constant block at `buffer(0)`, where the first renumbered uniform buffer goes.
- **Fix:** the translator moves it to the next free buffer slot (`p:0.0=<slot>` in the table) and the replay sets the recorded bytes there (`setVertexBytes` / `setFragmentBytes`, the pipeline layout's range).
- **Found on:** [Super Mario Galaxy](../../dm/games/010099C022B96000/README.md).

### Descriptor arrays bound to consecutive slots

- **Cause:** SPIRV-Cross gives an array of n descriptors n consecutive slots.
- **Fix:** the table says `slot*n` and the replay binds element k at slot + k.
- **Found on:** [Super Mario Galaxy](../../dm/games/010099C022B96000/README.md): the vertex shaders read the Wii's transform memory as arrays of uniform buffers (4 position-matrix blocks, 2 normal, 2 dual-texture) and the fragment shaders 8 combined image samplers.

### Descriptors hold the Metal objects they were written with

- **Symptom:** a crash in `bind_res` reading a freed view's texture (Super Mario Galaxy 2 on an iPhone, element 1 of the 8-texture array, when the ship took off after the first galaxy; GitHub issue 68).
- **Cause:** the replay binds every element of an array the shader takes, and a set may still name an image view the game has destroyed (the hardware reads a descriptor only when a draw samples it). The layer's descriptors were pointers to its own view, sampler and buffer structs.
- **Fix:** a descriptor now holds the texture, sampler state and buffer it was written with (retained), as a hardware descriptor holds a copy of the handle.
- **Found on:** [Super Mario Galaxy 2](../../dm/games/0100FD8022DAA000/README.md) (issue 68). Through the opening and the first storybook stage the game allocates 22,785 descriptor sets and frees none, and destroys only 5 image views (and 1,244 images), so a stale element is rare: a Mac run that kept destroyed objects to catch their binds found none there.

### An unwritten secondary blend source

- **Symptom:** Metal refuses a pipeline with "Fragment shader does not write to render target color(0), index(1) that is required for blending"; the Metal 4 specialization path can instead abort after `MTLCompilerService` crashes in `AGCLLVMStatelessFragmentObject::buildBlendFactor`.
- **Cause:** NVN blend state reads source 1, but the fragment shader's output map writes only colour 0. Passing that state directly to Metal asks its blend compiler to read an absent secondary output.
- **Fix:** for a known output map without colour 1, `pso_desc` chooses zero for the unwritten secondary source, consistently with the translator's dual-source output initialization (`Translator.EmitOutputsInitialization`). Source-1 colour / alpha factors become ZERO, and their complements become ONE. The shader, blend equation, blending enable and write mask remain intact. A written secondary source, an unknown output map or a separately specialized fragment is left alone. `t_missing_src1` compares both Metal pipeline paths against a shader explicitly writing a zero secondary source.
- **Open:** the original GPU's value for an unwritten secondary source has not been measured; zero is the host's defined choice for that missing value.
- **Found on:** [Mario + Rabbids Kingdom Battle](../../dm/games/010067300059A000/README.md).

### A written secondary blend source (NVN dual-source blending)

- **Symptom:** the host aborts on Metal's compiler queue (`findOrCreateComputeFastClearPipeline`, `[AGX] Failed assertion "error == MTLCompilerErrorNoError"`) seconds into the game, with or without the pipeline prebuild, while `MTLCompilerService` crash reports show `EXC_BAD_ACCESS` in `llvm::ExtractElementInst` under `AGCLLVMStatelessFragmentObject::buildBlendFactor` (`AGCLLVMStatelessPSODynamicLibrary::compile`).
- **Cause:** target 0 blends with a `SRC1` factor and the pixel shader writes outputs 0 and 1. NVN, as Maxwell, takes output 1 as target 0's second source; the translator declares it `[[color(1)]]`, and Metal reads a second source only from `[[color(0), index(1)]]`. With no such output, Metal 4's blend compiler crashes building the pipeline's colour state ([An unwritten secondary blend source](#an-unwritten-secondary-blend-source) left a written output 1 alone).
- **Fix:** `dmsh_build.py` `fs_dual` gives a pixel shader listed in the profile's `dual_want.tsv` that writes exactly colours 0 and 1 a second entry point, `main0_d`, the same body with output 1 as `[[color(0), index(1)]]` (`entry_d` in its reflection). `pso_desc` takes it for a pipeline whose output-0 target blends with a `SRC1` factor (`pso_reads_src1`); output 1's attachment, if the pass has one, is then left unwritten, as on Maxwell. A shader without the entry point blends with zero for the second source, as an unwritten one, with a red line naming it, and `DM_NVN_DUAL_WANT=<file>` appends every such key to a file for the profile's list. Only listed shaders get the entry point: 5,474 of Arceus's 6,156 pixel shaders write exactly colours 0 and 1, nearly all for a second render target. `t_missing_src1` checks both Metal pipeline paths with the entry point.
- **Found on:** [Pokémon Legends: Arceus](../../dm/games/01001F5010DFA000/README.md): `f4f36a03b0c6691d` (`system_resource/gfx2/shader/env/system/ha_post_effects.bnsh`, variation 4: RGBA16Float, destination factor `SRC1_ALPHA`) and `ff45da02e225f961`, in the first minute.

### Dual-source blending from output location 1

- **Symptom:** Metal refuses the pipeline: "Fragment shader does not write to render target color(0), index(1)".
- **Cause:** the GX shaders write the second blend source as an ordinary output at location 1 (no `Index` decoration), and pipelines blend with `SRC1` factors; NVIDIA's hardware feeds MRT 1 to source 1.
- **Fix:** `vk_shaders.py` builds a variant `vk_<key>_d` with that output at `[[color(0), index(1)]]`, which the host takes for pipelines whose blend reads source 1.
- **Found on:** [Super Mario Galaxy](../../dm/games/010099C022B96000/README.md).

### Scaled and three-component vertex formats

- **Symptom:** Metal's validation aborts on a buffer layout no mapped attribute uses.
- **Cause:** GX positions and colours arrive as integers read as unnormalized floats (`R16G16B16_SSCALED`, `R8G8B8A8_USCALED`, …) and in three-component formats.
- **Fix:** Metal's integer vertex formats convert to the shader's float type; a buffer layout no mapped attribute uses is left out.
- **Found on:** [Super Mario Galaxy](../../dm/games/010099C022B96000/README.md).

### Viewport and scissor persist across render passes

- **Symptom:** menus 1.5x too big in handheld mode (the file-creation dialog cut off at the right edge).
- **Cause:** Vulkan keeps viewport and scissor across render passes within a command buffer; the layer reset them to the render target at every pass. In handheld mode the game sets a 1280x720 viewport once and draws through several passes into its 1920x1080 swapchain.
- **Fix:** the layer keeps them across passes, as Vulkan says.
- **Found on:** [Super Mario Galaxy](../../dm/games/010099C022B96000/README.md).

### Copies inside a render pass

- **Symptom:** `draw outside a render pass`; the rest of the pass was dropped.
- **Cause:** the game copies from its EFB with `vkCmdCopyImage` between `vkCmdBeginRenderPass` and `vkCmdEndRenderPass`, which NVIDIA's driver runs.
- **Fix:** render passes now start with deferred store actions; a copy stores every attachment and ends the encoder, the next draw resumes the pass with load actions, and the pass's own store actions are set when it really ends.
- **Found on:** [Super Mario Galaxy](../../dm/games/010099C022B96000/README.md).

### Swapchain pre-transform and layer crop

- **Symptom:** an assert (a stripped trap, `main+0x4d26e0`) when the surface does not list `preTransform` INHERIT.
- **Cause:** the game asks for `preTransform` INHERIT. In handheld mode it keeps a 1920x1080 swapchain, draws into the top-left 1280x720 and calls `vi::SetLayerCrop` every frame.
- **Fix:** the surface lists INHERIT; the host keeps the crop (`hle_vi.c`) and the Vulkan present shows only that rectangle.
- **Found on:** [Super Mario Galaxy](../../dm/games/010099C022B96000/README.md).

### Linear images alias their memory

- **Cause:** staging images (`VK_IMAGE_TILING_LINEAR`, filled by the CPU and copied with `vkCmdCopyImage`) and one sampled 4x4 image alias their memory as on the Switch.
- **Fix:** the texture is made over the bound `MTLBuffer` with Metal's linear row alignment, which `vkGetImageSubresourceLayout` reports.
- **Found on:** [Super Mario Galaxy](../../dm/games/010099C022B96000/README.md).

### Timestamp and occlusion queries

- Timestamps are their submit's completion time; occlusion queries count into a per-submit visibility buffer, copied to the pool when the submit completes.
- **Found on:** [Super Mario Galaxy](../../dm/games/010099C022B96000/README.md): two timestamp pools and a 3,072-entry occlusion pool.

### Not translated in the Vulkan layer: geometry shaders

- **Symptom:** GX points and lines drawn as one-pixel points and lines.
- **Cause:** two geometry shaders (GX points and lines expanded to quads) are not translated (Metal has no geometry stage).
- **Found on:** [Super Mario Galaxy](../../dm/games/010099C022B96000/README.md).

## OpenGL layer

Digimon Story Cyber Sleuth: Complete Edition (Media.Vision's MVGL engine, SDK 6.4.0) and Balatro (LÖVE 11.4, "love-nx", with SDL and LuaJIT) render with **NVIDIA's desktop OpenGL 4.5 core profile through EGL**, not NVN. The host implements GL itself on Metal (`dm/gfx/gl/hle_gl.m`), as it does Vulkan for Hades; NVIDIA's GL driver (`subsdk0`) is not loaded. Balatro's graphics module is LÖVE's own OpenGL backend, so its choices follow what the context reports.

### Games that render with desktop OpenGL through EGL

- **Symptom:** `UNIMPL eglGetDisplay`, then `Break` right after `nv::InitializeGraphics` and `vi::OpenDefaultDisplay` (`main+0x5ed9d0`).
- **Cause:** the game renders with NVIDIA's desktop OpenGL through EGL; its NVN device (made just before) serves only a helper beside the movie player.
- **Fix:** the host's GL layer (`dm/gfx/gl/hle_gl.m`) answers the EGL imports and `eglGetProcAddress` (the rest of this section).
- **Found on:** [Digimon Story Cyber Sleuth: Complete Edition](../../dm/games/010014E00DB56000/README.md) (SDK 6.4.0, Media.Vision's MVGL engine; one boot).

### `glFlush` hands the frame so far to the GPU

- **Symptom:** the app closes with no message of its own, `[dm] CRASH sig=11 addr=0 pc=0` and a guest return address inside `main` (Well Dweller: `lr=main+0x3409a78`, the same address every time); `DM_GL_STUBS=1` then names the call: `[RED] glFlush called: not implemented, returns 0`.
- **Cause:** `glFlush` is not one of the layer's names, so `eglGetProcAddress` returns a null pointer, which the game stores in its own function table and calls when it opens a menu. `blr` into address 0 is a signal, not an abort, so nothing else says which function was wanted. A game's loader asks for the whole GL 4.6 name list (Well Dweller: 215 names, mostly 3.3+ features it never calls), so a null pointer by itself is correct; calling one is not.
- **Fix:** `glFlush` flushes pending clears and commits the open command buffer without waiting (`GLB(glFlush, …)` next to `glFinish` in `dm/gfx/gl/hle_gl.m`), and the calls after it start a new command buffer. `DM_GL_STUBS=1` remains the way to name a missing one, and `DM_GL_MISSES=1` prints every name the loader asked for and the layer does not implement.
- **Check:** Well Dweller, the same scripted input that crashed at the pause menu: the OPTIONS, GRAPHICS, STATS and PAGES screens open and the game returns to play (`[gl] frame 15300`, 35 draws per frame).
- **Found on:** [Well Dweller](../../dm/games/0100217023F6C000/README.md).

### Direct GL imports use the same implementations as the loader

- **Symptom:** `UNIMPL glCreateShader` returns 0, followed by `UNIMPL glShaderSource`, `glCompileShader`, `glGetShaderiv` and `glGetShaderInfoLog`; the game crashes in `sdk` with a null shader handle even though EGL initialized.
- **Cause:** the GL implementations were registered only in `__DATA,swgl`, which `eglGetProcAddress` searched. Normal imports search `__DATA,swhle`; a game that imports GL directly never consulted the GL table and got named unimplemented stubs instead.
- **Fix:** `GL` and `GLB` register in `swhle`, and `eglGetProcAddress` searches that same table. Both paths retain `GLB`'s big-stack entry; unsupported loader names still return null by default (`DM_GL_STUBS=1` enables diagnostic stubs). `make -C dm/gfx/tests GAME=010014E00DB56000 gl-imports` exercises the real import resolver and GL registrations, shader creation and source queries, wrapper addresses and missing names in both diagnostic modes, without game files.
- **Found on:** Darkest Dungeon Complete (`01008F1008DA6000`, update v327680, SDK 3.6.0, provisional profile), reported in [issue #228](https://github.com/seedds/nxnative/issues/228). The import failure is reproduced by the regression test; gameplay and run-time shader capture for this title remain unverified.

### Telling a GL game from an NVN or Vulkan one

- **Symptom:** the NSP script's provisional profile said Vulkan, and the capture boot crashed in the GL layer.
- **Cause:** `main` imports `vkGetInstanceProcAddr` for SDL's Vulkan loader, which nothing uses; the game draws with EGL and GL.
- **Fix:** `profile_guess.py` decides `graphics gl` when `main` imports `eglCreateWindowSurface` and names `glShaderSource`, and now leaves `vkGetInstanceProcAddr` out of its Vulkan count.
- **Found on:** [Digimon Story Cyber Sleuth: Complete Edition](../../dm/games/010014E00DB56000/README.md): `main` imports `nvnBootstrapLoader` and 13 EGL functions. Its graphics setup (`main+0x5ed8f0`) makes an NVN device first, which only a helper beside the movie player uses (`main+0x528000`–`+0x52c400`: a memory pool and four textures next to the movie's GL textures). Then `eglGetDisplay`, `eglBindAPI(EGL_OPENGL_API)`, a 4.5 core context, a window surface on `vi::CreateLayer(w, h)` and a glad loader (`main+0x52c460`). Of the 22 games extracted here (at the time), only Digimon matches the rule. [Balatro](../../dm/games/0100CD801CE5E000/README.md) (SDK 18.3.2, LÖVE 11.4 on OpenGL with SDL and LuaJIT; one boot): `main` imports the EGL functions and `vkGetInstanceProcAddr`, SDL's Vulkan loader, which nothing calls (`subsdk1` is NVIDIA's Vulkan driver); Hades and both Galaxies import 99 or 100 Vulkan functions, `vkCreateInstance` among them.
- **Note:** [Absolum](../../dm/games/0100A83022A22000/README.md) imports the same EGL functions (SDL3) but renders with NVN and names no GL function.

### Draws from client memory

- **Symptom:** the game draws thousands of vertices per frame and the window shows text only; a sprite scene is black while its text layer is perfect.
- **Cause:** the draw reads its vertices from a **client-memory array** — `glVertexAttribPointer` with no buffer bound, which desktop GL allows and Metal does not. The layer keeps `a->off = (uintptr_t)ptr; a->buf = S.array_buf;` in `h_glVertexAttribPointer`, so `a->buf == 0` marks client memory, and `draw_setup` used to drop such draws with one `[RED] vertex attribute 0 reads client memory or a buffer with no data (not implemented)` line. GameMaker's runner does exactly this for every sprite, background and screen composite; only its text path uses a real `GL_ARRAY_BUFFER`, which is why the text-only screens looked complete.
- **Fix:** `draw_setup` copies the vertices a draw touches into a transient `MTLBuffer` (`arena_alloc`) and binds that instead. The block keeps vertex *i* at *i* × stride from its start, as the game's array does, so the draw's first vertex, its indices and its base vertex read the same vertices unchanged; only the range *lo*..*hi* is copied: `first`..`first + count` for `glDrawArrays`, the smallest and largest index plus the base vertex for `glDrawElements` (`draw_span`, which reads the indices only when a draw has a client-memory array, so draws from vertex buffers cost nothing more), and elements 0..⌈instances / divisor⌉ for a per-instance attribute. A bound buffer with no data still drops with `[RED] vertex attribute %d reads a buffer with no data (%u)`, and a block over 128 MB is RED as well. Dropped draws are counted by reason in the layer's 300-frame line (`dropped draws since the last record: … no program, … no pass, … no attribute buffer, … no pipeline`).
- **Check:** Well Dweller's dropped-draw counter (`frame … dropped draws since the last record: … no attribute buffer …`) went from 11,885 to 0 and its draws from 274 to 22,577 per 300 frames, and the window then showed the same art as the game's own surface.
- **Found on:** [Well Dweller](../../dm/games/0100217023F6C000/README.md) (GameMaker Studio 2, SDK 22.2.0). Any GameMaker title whose screens are mostly sprites will hit it; Balatro does not, because LÖVE queues every draw with its own buffers.

### NVN in NROs under an SDL main that names GL

- **Symptom:** the NSP script took the game for an OpenGL one (`main imports EGL and names glShaderSource`), the GL shader capture found no shader, and the capture boot stopped with `[nvn-mtl] FATAL cannot read the shader map` from `h_nvnQueueSubmitCommands` called in an NRO (`nro8+0xc10d0`).
- **Cause:** Portal's `main` is SDL with its EGL video backend; it imports 20 EGL functions and names `glShaderSource` twice (SDL's GL renderer), but imports no NVN and draws nothing. The renderer is in the Source engine NROs: `materialsystem.nro` (with the D3D9 layer linked in) and `video_nx.nro` import `nvnBootstrapLoader` and draw with NVN.
- **Fix:** `profile_guess.py` `shader_sources` now reads the imports of the loose NROs in the RomFS (`romfs_nro_imports`): when one imports `nvnBootstrapLoader`, the game is an NVN game whatever `main` imports. Digimon keeps the GL rule: it has no NRO. The survey, which has only a RomFS manifest, called Portal 2 an OpenGL game and left GLSLC out of its modules until `nx_extract --manifest` also wrote the RomFS's NROs (`romfs_nro/`, 60 MB for Portal 2's 21) for it to read the same way.
- **Found on:** [Portal](../../dm/games/01007BB017812000/README.md); [Portal 2](../../dm/games/0100ABD01785C000/README.md) (the survey).

### Which GL functions a game calls

- **Symptom:** a jump to address 0 right after `glGetFloatv(0xb12)` (`lr=main+0x2d58c4`).
- **Cause:** a GL function the layer did not have (here `glVertexAttrib4fv`, LÖVE's default colours). glad asks `eglGetProcAddress` for every name it knows; the functions the game really calls come from a census of the code's loads outside the loader (`dm/tools/loader_census.py`). Every other name gets a null pointer, and a jump to address 0 names nothing.
- **Fix:** `DM_GL_STUBS=1` gives every name the layer lacks a stub of its own that reports its first call instead; `loader_census.py` lists what the code calls before the first boot.
- **Found on:** [Digimon Story Cyber Sleuth: Complete Edition](../../dm/games/010014E00DB56000/README.md): glad asks for 2,956 names and stores each in a global its code reaches through the GOT; a census of the GOT slots the code loads outside the loader gives the 79 functions the game calls: buffers, vertex arrays, textures (2D and cube, S3TC), framebuffers and renderbuffers, programs with plain `glUniform*`, `glDrawElements` / `glDrawArrays`, and three compatibility calls (`glTexEnvi`, `glColorTable`, `glPixelTransferi`). No uniform buffers, instancing or buffer mapping. [Balatro](../../dm/games/0100CD801CE5E000/README.md) (SDK 18.3.2; one boot; the missing `glVertexAttrib4fv` above): LÖVE's glad stores each pointer straight into a global of its own (no GOT slot per name), and the code reaches those globals through GOT entries that hold their addresses, which it often keeps in callee-saved registers across a loop, or picks between with `csel` (`glEnableVertexAttribArray` or `glDisableVertexAttribArray`). `loader_census.py` follows registers in a straight line for that (adrp, add, loads through relocated GOT entries, `mov`, `csel`): 2,133 names asked, about 150 called.

### GLSL source translated offline and found by hash

- Shaders are GLSL source compiled at run time with `glShaderSource` / `glCompileShader`. `gl_shaders.py` translates them offline: glslang (`-V -R`: relaxed Vulkan rules gather the loose uniforms into one `gl_DefaultUniformBlock`, whose member offsets the table lists) → SPIR-V → SPIRV-Cross. The host finds each shader by the hash of its text and its stage. Varyings are matched by name, as GL links them: `[[user(locnN)]]` becomes `[[user(<name>)]]`, so a vertex and a fragment shader translated apart still meet. `--fixup-clipspace` maps GL's clip z to Metal's.
- **Found on:** [Digimon Story Cyber Sleuth: Complete Edition](../../dm/games/010014E00DB56000/README.md): GLSL ES 3.20 source, 1,682 `.shad` files in the MVGL archives (615 distinct) and 37 strings in `main` (post effects, FXAA, shadows, the movie's YUV).

### GLSL that NVIDIA's compiler accepts and glslang does not

- Fix-ups on the preprocessed text: the GLSL ES 1.0 functions `textureCube` / `texture2D` in ES 3.20 code (with `-V` glslang reads `textureCube` as Vulkan's texture type, so a macro cannot rename it), `out vec4 gl_Position` redeclared through a macro, and `textureOffset` with an offset that is not a constant, which becomes a plain sample at P + offset ÷ level 0 size. A string in `main` says nothing of its stage, so it is translated as each stage that compiles.
- **Found on:** [Digimon Story Cyber Sleuth: Complete Edition](../../dm/games/010014E00DB56000/README.md): `textureCube` / `texture2D` in 89 fragment shaders; the redeclared `gl_Position` in the built-in sprite shader; the non-constant `textureOffset` in FXAA; one fragment shader string in `main` defines `vPosition` as `gl_Position`.

### GL shaders put together at run time and captured

- **Symptom:** in a capture run every program links with no uniforms; the game's first `Shader:send` raises a Lua error and, on the Switch, its error handler quits ([Any Lua error quits a LÖVE game](game-state.md#any-lua-error-quits-a-löve-game)).
- LÖVE builds each source in Lua from its header, its built-in code and the game's `.fs` file. The NSP script captures them on the Mac (`gl_capture.tsv`). A capture run has no library.
- **Found on:** [Balatro](../../dm/games/0100CD801CE5E000/README.md): the 35 shaders are all made before the first frame.

### The GL core profile and persistently mapped buffers

- LÖVE reads `GL_CONTEXT_PROFILE_MASK`; on a core profile it streams vertices through persistently mapped buffers (`glBufferStorage` + `glMapBufferRange` of a 3-frame ring, a `glFenceSync` per frame and `glClientWaitSync` three frames later), on a compatibility one from client memory, which Metal cannot draw from. The layer answers core: the mapping is the shared `MTLBuffer`'s memory, a fence is the serial of the command buffer being recorded, and a wait on a fence of that command buffer commits it first. The shaders then come as `#version 330 core`.
- **Found on:** [Balatro](../../dm/games/0100CD801CE5E000/README.md).

### GL uniforms, pipelines and attributes

- Uniforms are CPU copies per stage, set as bytes at a draw after they change; pipelines are cached per program by vertex layout, attachment formats, blend and colour mask; disabled vertex arrays read the attribute's current value (GL's default (0, 0, 0, 1) until `glVertexAttrib4f`) through a constant-step buffer. Without `glBindAttribLocation` the game's attribute index is the Metal one: `glGetAttribLocation` returns the shader's own attribute numbers. With it, the layer maps each Metal input to the game's index at the link.
- A GLSL `bool` is a `uint` in the SPIR-V block; `gl_shaders.py` keeps the declared type, as LÖVE's `Shader:send` takes only a boolean for a bool.
- **Found on:** [Digimon Story Cyber Sleuth: Complete Edition](../../dm/games/010014E00DB56000/README.md) (no `glBindAttribLocation`); [Balatro](../../dm/games/0100CD801CE5E000/README.md): LÖVE binds VertexPosition, VertexTexCoord, VertexColor and ConstantColor to 0–3 with `glBindAttribLocation` before each link, keeps VertexColor and ConstantColor as disabled arrays and sets their values with `glVertexAttrib4f` (the draw colour); it lists uniforms with `glGetActiveUniform` (types as GL enums, arrays as `name[0]`) and reads their initial values back with `glGetUniformfv` / `iv`.

### GL textures, swizzles and uploads

- Textures are made on first use from the levels given so far (Digimon's loader defines them level by level). An upload into a texture a pending command buffer may still read is a blit in command order; any other is a CPU write. Metal reads a channel a format lacks as 0 (alpha 1) as GL does, so only luminance / alpha formats get a swizzle: Metal refuses a swizzle on a texture that can be a render target (`Texture swizzling is not compatable with MTLTextureUsageRenderTarget`, Digimon's first story scene).
- `glTexStorage2D` makes every level up front (mipmaps filled by `glGenerateMipmap` as a blit), `glTexStorage3D` 3D and 2D array textures; the layer's units hold all four targets (96 of them, as `GL_MAX_COMBINED_TEXTURE_IMAGE_UNITS` says). A `GL_TEXTURE_SWIZZLE_*` is applied when the texture is made (a swizzled texture cannot be a render target).
- **Found on:** [Digimon Story Cyber Sleuth: Complete Edition](../../dm/games/010014E00DB56000/README.md); [Balatro](../../dm/games/0100CD801CE5E000/README.md): the game's images are mipmapped; LÖVE makes a 1x1 default texture of each type, 3D and 2D array among them; font glyphs are RG8 with a swizzle of R, R, R, G.

### GL buffers orphaned, clears as load actions

- `glBufferData` on a buffer the GPU may still read gets a new `MTLBuffer`, as GL drivers orphan it. A whole-framebuffer clear becomes the next pass's load action; a scissored or masked one is a quad.
- **Found on:** [Digimon Story Cyber Sleuth: Complete Edition](../../dm/games/010014E00DB56000/README.md).

### GL draws and framebuffers

- Batched quads share one 16-bit index buffer through `glDrawElementsBaseVertex`; canvases bind GL_FRAMEBUFFER (read and draw), check completeness, discard depth and stencil after use (`glInvalidateFramebuffer`) and clear with `glClearBufferfv`. `glBlitFramebuffer` (colour, same size) and `glReadPixels` (RGBA8) are there for multisample resolves and `Canvas:newImageData`, which the game does not use.
- **Found on:** [Balatro](../../dm/games/0100CD801CE5E000/README.md).

### GL orientation through the lower-left origin

- The layer renders as GL does, bottom row first, through the NVN layer's lower-left origin (`mtl_set_origin_lower_left`): flipped viewports, reversed winding, a flipped present. Scissor rectangles and `gl_FragCoord` need no change, and render targets read back with GL's texture coordinates.
- **Found on:** [Digimon Story Cyber Sleuth: Complete Edition](../../dm/games/010014E00DB56000/README.md).

### GL present paced by the swap interval

- Three window textures go through the NVN layer's present path (`mtl_ext_tex`, as the Vulkan swapchain), paced by the swap interval in display-link ticks.
- **Found on:** [Digimon Story Cyber Sleuth: Complete Edition](../../dm/games/010014E00DB56000/README.md): the game sets the interval to 60 ÷ its frame rate before each swap: 1 at the title and in the DigiLab, 2 from the story's opening on.

### GL movies decoded by the SDK's movie library

- **Found on:** [Digimon Story Cyber Sleuth: Complete Edition](../../dm/games/010014E00DB56000/README.md): the USM movies' H.264 is decoded through the SDK's movie library (the host's decoder) into NV12 buffers (3,110,400 bytes a 1920x1080 frame); the game uploads the planes into a `GL_RED` and a `GL_RG` texture (two `glTexSubImage2D` a frame) and converts YUV in its own shader (in `main`, `SamplerY` / `SamplerUV`).

### Unwritten attachment stores without lookahead

- **Symptom:** read-only depth/stencil attachments are written back after every pass, and the periodic unwritten-store savings counter remains zero with the default configuration.
- **Cause:** `udc_note_draw` and `sd_finish` returned early when `DM_NVN_TBDR` was off. This also disabled the local unwritten-attachment proof, although it does not depend on future sampled-texture readers. The broader lookahead remains disabled because it does not understand bindless readers.
- **Fix:** collect per-pass write facts independently of the lookahead switch and omit only stores of attachments that were loaded and provably unchanged. Clears, depth writes, stencil writes and possible writable image/atomic/storage aliases retain their stores. Lookahead, pass merging and cross-submission invalidation remain disabled. `DM_NVN_UNWRITTEN_DC=0` restores store-all behavior.
- **Check:** `make -C dm/gfx/tests GAME=<id> check_t_unwritten_store` performs real GPU readback against a store-all control and literal color/depth/stencil values, with lookahead disabled. It covers read-only depth/stencil, depth writes, stencil writes, pending clears, and writable images (including native image atomics) and both storage-buffer binding forms. `t_unwritten_store --bench` runs a synthetic 32-pass 1080p workload with balanced on/off order; it is not a game FPS measurement.
- **Found on:** [NieR:Automata US 1.0.3](../../dm/games/010056B015FE8000/README.md#factory-combat-capture-and-9s-texture-follow-up), during iPhone factory-combat performance investigation. The change passes the GPU proof and rendering regressions on Mac; iPhone gameplay benefit remains to be measured.
