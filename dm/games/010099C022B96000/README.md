# Super Mario Galaxy (`010099C022B96000`)

Update 1.3.1 (v327680) over the base game, SDK 18.3.5. The Wii game (codename Comet) on NERD's Hagi layer, on **Vulkan**. The PowerPC code is statically recompiled into `main` (`hagi.config`: `Cpu` `Jit false`, `Statifier true`), so there is no JIT. Hagi stands in for the Wii hardware: GX on Vulkan, the DSP with its ROMs in `data/dsp`, the disc from the RomFS, HD texture packs in `data/texture_replace` and `data/ondemand_texture_replace`. Modules `main`, `subsdk0` (NintendoSDK_movie, for the WebM movies in `data/video_replace`) and `sdk`; `subsdk1` (GLSLC), `subsdk2` (`nn::pcm`) and `subsdk3` / `subsdk4` (NVIDIA's OpenGL and Vulkan drivers) are not loaded. Its `subsdk0` and `sdk` builds are also Super Mario Galaxy 2's ([0100FD8022DAA000](../0100FD8022DAA000/README.md)) and Monster Train 2's ([010051701FB46000](../010051701FB46000/README.md)). Plays on the iPhone.

## What it needs

| Setting | Where | Why |
|---|---|---|
| `op_mode handheld` | [`game.tsv`](game.tsv) | the pointer (star bits, menus, the file select) is the touch screen in handheld mode; docked it uses the controller gyro. See [Input](#input) |
| `pad_layout full` | `game.tsv` | the 3D gamepad layout |
| `modules main subsdk0 sdk` | `game.tsv` | `subsdk1`–`subsdk4` are replaced by the host's Vulkan layer |
| 1 GB block: `mem_reserve 0x40000000`, `mem_alias 0x10000000`, `mem_stack 0x10000000`, `app_pool 0xCD500000` | `game.tsv` | the game never calls `SetHeapSize`; its memory is `main`'s bss. See [Memory](#memory) |
| `vk_capture.tsv` | profile | the keys of the SPIR-V modules Hagi generates at run time, which the NSP script captures; see [Shaders](#shaders) |
| Node area cut 1 GB → 62 MB | `dm/tools/sdk_patches.py`, `sdk` build `6075151627016eef…` | needed by Galaxy 2's movie allocator on the same `sdk` build; the cut applies to every module of that build |

## Memory

- `main`'s bss is about 2.9 GB (`0xb964d0e8`, the emulated memory). The NPDM declares 8 MB of system resource.
- Measured (`DM_SVC=1`, Mac, to the Star Festival): no `SetHeapSize`, one alias page mapped during SDK initialization; the game's memory is `main`'s bss (charged 443 MB), not the block (7 MB charged). So the block is 1 GB = 256 MB in front + 256 MB alias region + 256 MB stack region + 256 MB heap region; with `main`'s 3 GB image that is about 4 GB of address space.
- Footprint on the Mac 1.9 GB, 1.1 GB of it Metal.
- Galaxy allocates the movie player's block from its main allocator first; Galaxy 2, on the same SDK, initializes that allocator with virtual address memory and aborted at boot without the node area cut.
- The provisional-profile guesser gives a game whose `main` never sets a heap this 1 GB block, and the Hagi preset (`hagi.config`) gets `op_mode handheld` and `pad_layout full` ([dm/games/README.md, Adding a game](../README.md#adding-a-game)).

## Vulkan

99 `vk*` imports through Hades' layer (`hle_vk.m`, [0100535012974000](../0100535012974000/README.md)), which Galaxy extended. Each addition was found from a red line or a screenshot on the route to the Star Festival:

- **Push constants:** SPIRV-Cross binds the block at `buffer(0)`, where the first renumbered uniform buffer goes; the translator moves it to the next free buffer slot (`p:0.0=<slot>` in the table) and the replay sets the recorded bytes there (`setVertexBytes` / `setFragmentBytes`, the pipeline layout's range).
- **Descriptor arrays:** the vertex shaders read the Wii's transform memory as arrays of uniform buffers (4 position-matrix blocks, 2 normal, 2 dual-texture) and the fragment shaders 8 combined image samplers. SPIRV-Cross gives an array n consecutive slots, so the table says `slot*n` and the replay binds element k at slot + k.
- **Dual-source blending from location 1:** the GX shaders write the second blend source as an ordinary output at location 1 (no `Index` decoration), and pipelines blend with `SRC1` factors; NVIDIA's hardware feeds MRT 1 to source 1. Metal refuses the pipeline ("Fragment shader does not write to render target color(0), index(1)"). `vk_shaders.py` builds a variant `vk_<key>_d` with that output at `[[color(0), index(1)]]`, which the host takes for pipelines whose blend reads source 1.
- **GX vertex formats:** positions and colours arrive as integers read as unnormalized floats (`R16G16B16_SSCALED`, `R8G8B8A8_USCALED`, …) and in three-component formats; Metal's integer vertex formats convert to the shader's float type. A buffer layout no mapped attribute uses is left out: Metal's validation aborts on it.
- **Viewport and scissor persist across render passes** within a command buffer, as Vulkan says; the layer used to reset them at every pass. In handheld mode the game sets a 1280x720 viewport once and draws through several passes into its 1920x1080 swapchain, so its menus came out 1.5x too big (the file-creation dialog cut off at the right edge).
- **Copies inside a render pass:** the game copies from its EFB with `vkCmdCopyImage` between `vkCmdBeginRenderPass` and `vkCmdEndRenderPass`, which NVIDIA's driver runs. Render passes now start with deferred store actions; a copy stores every attachment and ends the encoder, the next draw resumes the pass with load actions, and the pass's own store actions are set when it really ends. Before, the rest of the pass was dropped (`draw outside a render pass`).
- **Swapchain:** the game asks for `preTransform` INHERIT and asserts (a stripped trap, `main+0x4d26e0`) when the surface does not list it. In handheld mode it keeps a 1920x1080 swapchain, draws into the top-left 1280x720 and calls `vi::SetLayerCrop` every frame; the host keeps that crop (`hle_vi.c`) and the Vulkan present shows only that rectangle.
- **Linear images:** staging images (`VK_IMAGE_TILING_LINEAR`, filled by the CPU and copied with `vkCmdCopyImage`) and one sampled 4x4 image alias their memory as on the Switch: the texture is made over the bound `MTLBuffer` with Metal's linear row alignment, which `vkGetImageSubresourceLayout` reports.
- **Queries:** two timestamp pools and a 3,072-entry occlusion pool. Timestamps are their submit's completion time; occlusion queries count into a per-submit visibility buffer, copied to the pool when the submit completes.
- Also added for Galaxy: pipeline caches, `vkCmdDraw`, image copies and read-backs.
- **Not translated:** two geometry shaders (GX points and lines expanded to quads); those draws come out as one-pixel points and lines. GX's sampler LOD bias goes to Metal's sampler bias ([Sampler LOD bias](../../../docs/reference/rendering.md#sampler-lod-bias), resolved).

## Shaders

- Hagi generates its GX shaders as SPIR-V at run time. While it shows "Initializing system..." it creates 3,089 modules (the 56 built into `main` among them) and 4,535 pipelines from `data/database/pip/pipelineDB.pip`, the same on every boot (about 15 s on the Mac).
- The RomFS has no SPIR-V file, so the NSP script's `Vulkan shader capture` stage, with the profile's key list `vk_capture.tsv`, boots the game in the Mac host with `DM_VK_CAPTURE=<version dir>/vk_capture` until every listed key is there (under a minute; it gives up after 120 s), then `vk_shaders.py` translates the RomFS and the capture (it reads capture folders like a RomFS).
- Its SPIR-V puts `ArrayStride` on the struct member (`OpMemberDecorate`) instead of the array type, which NVIDIA's driver accepts and SPIRV-Cross refuses ("Struct member does not have ArrayStride set"): `fix_strides` copies it onto the type before translating.
- `romfs_marker` is `hagi.config`.

## CPU

- **Resolved: a core at 100% in `SleepThread`.** Hagi polls with `SleepThread(100 ns)` (`main+0x517c`): 1.4 billion calls in 200 s, and the render thread nearly as busy. `sleep_precise` returned at once for anything under 20 µs (its nanosleep would overshoot), so such a loop never slept. Sleeps under 20 µs now take the yield path and its back-off (plain yields for the first 2 ms of a run, then short sleeps): the two threads went from 199 s and 171 s of CPU per 200 s to 5 s and 19 s per 120 s, at the same frame rate.

## Input

- Docked, Galaxy's pointer uses the controller gyro; handheld, it is the touch screen. `op_mode handheld` starts it in handheld mode (720p). `DM_OPMODE=1` selects docked mode for gyro input.
- **Reported working, original PR #296:** JustWoody tested 1.3.1's docked pointer with a genuine Pro Controller over Bluetooth on an M3 Pro, macOS 27, using passive HID reports; GameController's motion was all zero. The reader now feeds the shared motion core ([Pro Controller fallback](../../../docs/reference/services.md#switch-pro-controller-advertises-motion-but-sends-zeroes)); that rework has automated tests only, with live sensitivity, axes, sample order and reconnect testing still open. The profile keeps its handheld default.
- On the iPhone, touches no gamepad control takes go to the game's touch screen: in the 3D layout, those outside the right third of the screen, which is the right stick; all of them while a controller is connected. On the Mac the mouse is a finger, and `DM_KEYS` taps with `T<x>x<y>` (normalized picture coordinates).

## Services

- **Resolved: `sm::Initialize` aborted right after `ConnectToNamedPort` (SVC 0x1F) and `SendSyncRequest` (0x21).** An SDK call the host did not hook opened its service: `nn::hid::InitializeTouchScreen(int, int)`, the SDK 18 overload of the hooked `InitializeTouchScreen()`.
- Focus handling mode 3 (no focus notifications; the system suspends the game out of focus). The host queues message 15 only under modes 1 and 2 ([Focus handling mode decides whether focus changes are notified](../../../docs/reference/services.md#focus-handling-mode-decides-whether-focus-changes-are-notified)).

## Damaged NSP

- The base NSP in hand was damaged: its program NCA hashed differently from its name, with 12 MB runs of zeros near its end (147 MB of damaged RomFS: the two WebM prologue movies, which the storybook prologue does not use), while its update and the small NCAs matched their names. It was packed with `--allow-damaged` ([01, NSP → NCA → ExeFS / RomFS](../../../docs/agents/01-extract.md#nsp--nca--exefs--romfs)).

## Mac routes

- From a fresh save, `DM_KEYS="f1500:A,f1950:T0.373x0.70,f2300:A,f2700:A,f3200:A,f3600:LRight,f3800:A,f4200:T0.247x0.426,f4500:A,f4800:LRight,f5000:A,f5400:T0.659x0.366,f5800:A,f6200:LRight,f6400:A,f7000:A,f8000:A,f9000:A,f10000:A,f11000:A"` creates file 1 (Mario icon, Regular Mode) and plays the storybook prologue into the Star Festival (about frame 12,000).
- Screenshots of the handheld picture need `DM_NVN_SHOT_OUT=1280x720` (the raw swapchain image is 1920x1080 with the picture in its top-left 1280x720).

## Found on this game

General host changes first needed here; each applies to every game:

- **Vulkan layer additions** (push constants, descriptor arrays, dual-source blending `vk_<key>_d`, GX vertex formats, viewport and scissor across passes, copies inside a pass, INHERIT transform and the vi layer crop, linear images, queries, `fix_strides`): [Push constants in the next free buffer slot](../../../docs/reference/rendering.md#push-constants-in-the-next-free-buffer-slot), [Descriptor arrays bound to consecutive slots](../../../docs/reference/rendering.md#descriptor-arrays-bound-to-consecutive-slots), [Dual-source blending from output location 1](../../../docs/reference/rendering.md#dual-source-blending-from-output-location-1), [Scaled and three-component vertex formats](../../../docs/reference/rendering.md#scaled-and-three-component-vertex-formats), [Viewport and scissor persist across render passes](../../../docs/reference/rendering.md#viewport-and-scissor-persist-across-render-passes), [Copies inside a render pass](../../../docs/reference/rendering.md#copies-inside-a-render-pass), [Swapchain pre-transform and layer crop](../../../docs/reference/rendering.md#swapchain-pre-transform-and-layer-crop), [Linear images alias their memory](../../../docs/reference/rendering.md#linear-images-alias-their-memory), [Timestamp and occlusion queries](../../../docs/reference/rendering.md#timestamp-and-occlusion-queries), [Vulkan shaders generated at run time](../../../docs/reference/rendering.md#vulkan-shaders-generated-at-run-time).
- **SPIR-V captured at run time** (`DM_VK_CAPTURE`, `vk_capture.tsv`, the NSP script's capture stage): [development.md, The packing script in detail](../../../docs/development.md#the-packing-script-in-detail) and [dm/games/README.md](../README.md#what-the-game-files-decide-at-every-build).
- **Sleeps under 20 µs take the yield back-off** (`sleep_precise`, `hle_thread.c`): [Sleeps under 20 µs take the yield path](../../../docs/reference/threads.md#sleeps-under-20-µs-take-the-yield-path).
- **SDK 18's `InitializeTouchScreen(int, int)`** hooked: [SDK calls that open a system service through sm](../../../docs/reference/services.md#sdk-calls-that-open-a-system-service-through-sm).
- **`op_mode`** (the operation mode at start, `DM_OPMODE`): [dm/games/README.md, Keys](../README.md#keys).
- **Sampler LOD bias** given to Metal (NVN and Vulkan): [Sampler LOD bias](../../../docs/reference/rendering.md#sampler-lod-bias).
- **Pro Controller motion absent from GameController on the Mac:** [Switch Pro Controller advertises motion but sends zeroes](../../../docs/reference/services.md#switch-pro-controller-advertises-motion-but-sends-zeroes).

## Open

- GX points and lines (the geometry shaders) are not done. The player README lists it as a known issue: effects drawn as points or lines come out one pixel wide.
- The capture timing differs between sources: the game notes say the modules are created in about 15 s on the Mac (the capture "under a minute"); [development.md, The packing script in detail](../../../docs/development.md#the-packing-script-in-detail) says 3,089 keys about 7 s after launch.
- The `min` / `max` / `clamp` NaN fix (`precise::`, GitHub issue 72) was found on Galaxy 2's GX lighting; its notes have the detail ([0100FD8022DAA000](../0100FD8022DAA000/README.md)). Not stated whether this game showed it.
- `game.tsv` says values marked "Mario's" are not measured for this game; none of its rows is marked so.
