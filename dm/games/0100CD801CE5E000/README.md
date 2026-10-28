# Balatro (`0100CD801CE5E000`)

Update 1.1.3 (v851968), SDK 18.3.2. LÖVE 11.4 ("Mysterious Mysteries", love-nx) with LuaJIT 2.1.0-beta3 in its interpreter and SDL: the game is Lua source in the RomFS (`main.lua`, `game.lua`, `engine/`, `functions/`), its pictures PNG, its sound Ogg Vorbis through OpenAL Soft on the audio renderer. It renders with **OpenGL**, not NVN: NVIDIA's desktop GL 4.5 through EGL, which the host implements on Metal (`dm/gfx/gl/hle_gl.m`) on the core profile's paths. Modules `main` and `sdk`; `sdk` is the same build as Absolum's ([0100A83022A22000](../0100A83022A22000/README.md)). `subsdk0` (NVIDIA's OpenGL driver) and `subsdk1` (NVIDIA's Vulkan driver) are never loaded. Plays on the iPhone (IPA about 82 MB), by touch in handheld mode.

On the Mac: the intro, the title, a new run by touch and the tutorial's first steps, at 60 fps with sound; about 0.65 GB resident and 0.2 GB of Metal allocations, flat over three minutes in a run.

## What it needs

| Setting | Where | Why |
|---|---|---|
| `op_mode handheld` | [`game.tsv`](game.tsv) | the Switch build plays by touch there (SDL turns the touch screen into LÖVE touches and mouse presses: tap a card, drag it): on the iPhone the touches outside the gamepad controls, on the Mac the mouse. Docked it reads only the pads. Its window is then the 1280x720 handheld display |
| `pad_layout touch` | `game.tsv` | the virtual gamepad starts in its Tap layout (only the layout button; every touch goes to the game), since the 2D layout's corners cover Run Info, Options and the deck; the layout button brings back 2D and 3D |
| [`gl_capture.tsv`](gl_capture.tsv) | profile | the 35 shaders LÖVE puts together at run time, which no game file holds; the NSP script captures them on the Mac; see [Shaders](#shaders) |
| `modules main sdk` | `game.tsv` | `subsdk0` / `subsdk1` are NVIDIA's OpenGL and Vulkan drivers, which program the GPU through NvRm: never loaded, the GL layer answers `main`'s EGL imports |
| `sys_resource 0x0`; `mem_reserve 0xf0000000`, `mem_alias 0x10000000`, `mem_stack 0x10000000`, `app_pool 0xCD500000` | `game.tsv` | no system resource, so no virtual address memory: `nninitStartup` gives its malloc a heap of the pool − used memory, which it maps only as it touches it; `main`'s 264 MB bss counts as used memory |
| Node area cut and 1 GB → 32 MB region alignment | `dm/tools/sdk_patches.py`, `sdk` build `f118ae1c…` | registered for Absolum, whose `sdk` build this is; the entry does not name Balatro |
| No NVN shader tables | `game.tsv` `shader_note` | no NVN shaders: `gl_shaders.py` writes the GL library and its table, not the profile |

## Rendering (OpenGL)

LÖVE's graphics module is its own OpenGL backend, so its choices follow what the context reports.

- **Telling the API apart:** `main` imports the EGL functions and `vkGetInstanceProcAddr`, SDL's Vulkan loader, which nothing calls. **Resolved:** the NSP script's provisional profile said Vulkan, and the capture boot crashed in the GL layer; `profile_guess.py` now leaves `vkGetInstanceProcAddr` out of its Vulkan count (Hades and both Galaxies import 99 or 100 Vulkan functions, `vkCreateInstance` among them).
- **Which GL functions:** LÖVE's glad loader asks for 2,133 GL names and stores each pointer straight into a global of its own (no GOT slot per name). The code reaches those globals through GOT entries that hold their addresses, which it often keeps in callee-saved registers across a loop, or picks between with `csel` (`glEnableVertexAttribArray` or `glDisableVertexAttribArray`). `loader_census.py` follows registers in a straight line for that (adrp, add, loads through relocated GOT entries, `mov`, `csel`): about 150 called.
- **Resolved: a jump to address 0 right after `glGetFloatv(0xb12)`** (`lr=main+0x2d58c4`): a GL function the layer did not have (here `glVertexAttrib4fv`, LÖVE's default colours). `DM_GL_STUBS=1` gives every name the layer lacks a stub of its own that reports its first call instead of a null pointer (a jump to address 0 names nothing); `loader_census.py` lists what the code calls before the first boot.
- **Core profile:** LÖVE reads `GL_CONTEXT_PROFILE_MASK`, which the layer now answers as core. On a core profile it streams vertices through persistently mapped buffers (`glBufferStorage` + `glMapBufferRange` of a 3-frame ring, a `glFenceSync` per frame and `glClientWaitSync` three frames later); on a compatibility one it would draw from client memory, which Metal cannot draw from. In the layer the mapping is the shared `MTLBuffer`'s memory, a fence is the serial of the command buffer being recorded, and a wait on a fence of that command buffer commits it first. The shaders then come as `#version 330 core`.
- **Attributes:** LÖVE binds VertexPosition, VertexTexCoord, VertexColor and ConstantColor to 0–3 with `glBindAttribLocation` before each link, keeps VertexColor and ConstantColor as disabled arrays and sets their values with `glVertexAttrib4f` (the draw colour); the layer maps each Metal input to the game's index at the link.
- **Uniforms:** LÖVE lists them with `glGetActiveUniform` (types as GL enums, arrays as `name[0]`) and reads their initial values back with `glGetUniformfv` / `iv`; every `glUniform*` form.
- **Textures:** made with `glTexStorage2D` (every level up front: the game's images are mipmapped, filled by `glGenerateMipmap` as a blit) or `glTexStorage3D`: LÖVE makes a 1x1 default texture of each type, 3D and 2D array among them, and the layer's units hold all four targets (96 of them, as `GL_MAX_COMBINED_TEXTURE_IMAGE_UNITS` says). Font glyphs are RG8 with a `GL_TEXTURE_SWIZZLE_*` of R, R, R, G, applied when the texture is made (a swizzled texture cannot be a render target).
- **Draws and framebuffers:** batched quads share one 16-bit index buffer through `glDrawElementsBaseVertex`; instanced draws; canvases bind GL_FRAMEBUFFER (read and draw), check completeness, discard depth and stencil after use (`glInvalidateFramebuffer`) and clear with `glClearBufferfv`. Separate read and draw framebuffers, `glBlitFramebuffer` (colour, same size) and `glReadPixels` (RGBA8) are there for multisample resolves and `Canvas:newImageData`, which the game does not use.

## Shaders

- **Current:** LÖVE puts each shader's GLSL together at run time, in Lua, from its own header and built-in code and the game's 19 `resources/shaders/*.fs`: 35 sources (`#version 330 core`), all made by `Game:start_up` before the first frame. No game file holds them, so the NSP script captures them on the Mac (`DM_GL_CAPTURE` at `<id>_build/extract/<version>/gl_capture` until every file in `gl_capture.tsv` is there) and `gl_shaders.py` translates them; the host finds each by the hash of its text.
- **Resolved:** a GLSL `bool` uniform is a `uint` in SPIR-V; `gl_shaders.py` now reports the declared type, since LÖVE's `Shader:send` takes only a boolean for a bool (the game stopped at its first card otherwise).
- A capture run has no shader library: every program then links with no uniforms, and the game's first `Shader:send` raises a Lua error, which quits (below), after every shader is captured.

## Audio

- **Resolved: silent.** The game opens the audio renderer without an event (`OpenAudioRenderer(handle, parameter, work, size)`, from LÖVE's OpenAL Soft) and paces its own updates; the renderer must still run every 5 ms. The host started its render thread only for the form with an event, so only the game's own updates rendered (catch-up frames that nothing played). Both forms now go through one open that starts the thread (`hle_audren.c` `ar_open`). The log showed `audren: OpenAudioRenderer (no event)` and no `render thread started`.

## When the game stops

- On the Switch, Balatro's `love.errhand` returns at once, so any Lua error quits. love-nx's video worker is then deleted twice (`love::video::theora::Video` → `~Worker`: its thread releases the worker that the closing video module also deletes), which crashes in `main+0x339c00` a second or two into the title. A run that reaches this has hit a Lua error first: look for it.
- How it was found: a `print` at the top of `love.errhand` in `main.lua`, in a copy of the RomFS (`DM_ROMFS=<copy>`), gave the errors: `Shader uniform 'distortion_fac' does not exist` (the capture run had no shader library, so every program linked with no uniforms), then `bad argument #2 to 'send' (number expected, got boolean)` (a `bool` uniform reported as `GL_UNSIGNED_INT`). Probing the destructors (`DM_PROBE`) and logging every object the Lua GC released (`DM_PROBE=main:0x18b920@x0+0`: the module proxies all at once) showed it was a shutdown, not a premature collection.

## Rewriter

- The spin-wait search through stores found 12 loops in `main` instead of 9; one is a parser state that leaves on the next pass (`main+0x1f4600`) ([development.md, Power](../../../docs/development.md#power)).

## Mac routes

- In handheld mode, `DM_KEYS="f1300:T0.35x0.86,f1700:T0.35x0.86,f2100:T0.5x0.68"` taps Play at the title, Play in the run setup and the tutorial's Next.

## Found on this game

General host changes first needed here; each applies to every game:

- **Resolved: Homebrew .NET runtime discovery** for the first extraction and shader tools: [Homebrew .NET is on PATH but apphosts cannot find the runtime](../../../docs/reference/packing.md#homebrew-net-is-on-path-but-apphosts-cannot-find-the-runtime).
- **The GL layer's core-profile paths** (`GL_CONTEXT_PROFILE_MASK`, persistently mapped buffers and fences, attribute bindings and current values, uniform queries, texture storage, 3D and array textures, swizzles, mipmaps, base-vertex and instanced draws, blits) in `hle_gl.m`, and **`DM_GL_STUBS=1`**: [The GL core profile and persistently mapped buffers](../../../docs/reference/rendering.md#the-gl-core-profile-and-persistently-mapped-buffers), [GL uniforms, pipelines and attributes](../../../docs/reference/rendering.md#gl-uniforms-pipelines-and-attributes), [GL textures, swizzles and uploads](../../../docs/reference/rendering.md#gl-textures-swizzles-and-uploads), [GL draws and framebuffers](../../../docs/reference/rendering.md#gl-draws-and-framebuffers), [Which GL functions a game calls](../../../docs/reference/rendering.md#which-gl-functions-a-game-calls).
- **`loader_census.py` following registers** (LÖVE's glad), and `vkGetInstanceProcAddr` left out of `profile_guess.py`'s Vulkan count: same section.
- **GL shaders captured at run time** (`DM_GL_CAPTURE`, `gl_capture.tsv`, the NSP script's `capture_shaders`): [development.md, The packing script in detail](../../../docs/development.md#the-packing-script-in-detail).
- **A renderer opened without an event** starts the render thread (`ar_open`): [A renderer opened without an event](../../../docs/reference/audio.md#a-renderer-opened-without-an-event).
- **The Tap pad layout** (`pad_layout touch`, `DmGamepad.m`): [dm/games/README.md](../README.md).

## Open

- The player-facing [README](../../../README.md) says the games outside its 2D list start in the 3D layout; Balatro starts in Tap (its gallery entry says "played by touch").
