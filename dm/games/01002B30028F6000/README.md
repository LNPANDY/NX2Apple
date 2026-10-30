# Celeste (`01002B30028F6000`)

Update 1.4.1.1 (v589824; the title shows v.1.4.1.0), SDK 15.3.2. MonoGame for the Switch: MonoGame's and the game's C# compiled to C++ by Sickhead's BRUTE into `main` (78 MB with its bss), FMOD Studio sound (its banks in `Content/FMOD/Desktop`) through AudioOut, on NVN. Modules `main` and `sdk` only; `sdk` is the same build as Paper Mario: The Thousand-Year Door 1.0.1's ([0100ECD018EBE000](../0100ECD018EBE000/README.md)). Brought up with no host change; plays on the iPhone.

On the Mac: the logos, the title, a new file and the prologue (walking, jumping, the camera following Madeline), at 60 fps with music and sound, no red line; about 1.6–1.7 GB resident, flat over five minutes.

## What it needs

The provisional profile's guesses held: no key needed changing.

| Setting | Where | Why |
|---|---|---|
| `sys_resource 0x0` | [`game.tsv`](game.tsv) | the NPDM declares no system resource, so `IsVirtualAddressMemoryEnabled` is false, as on Horizon: no virtual address memory. The game sets a 3.11 GB heap (pool − used memory) |
| 4 GB layout: `mem_reserve 0x100000000`, `mem_alias 0x10000000`, `mem_stack 0x10000000`, `app_pool 0xCD500000` | `game.tsv` | 256 MB in front + 256 MB alias region + 256 MB stack region + 3.25 GB heap region |
| `mem_used 0x6400000` (100 MB) | `game.tsv` | the rewritten modules are larger than the default 64 MB of used memory (BRUTE's `main` alone is 78 MB with its bss), so the heap request plus the modules would exceed the pool |
| Node area cut and 4 MB / 32 MB / 1 GB → 2 MB region alignment (SDK 20's) | `dm/tools/sdk_patches.py` SDK-wide rules, `sdk` build `8618895246b4…` | Absolum's cuts, from the SDK-wide rules on this build (Paper Mario's); Celeste has no virtual address memory and never makes an address region |
| `shader_groups /Content/=content` | `game.tsv` | the MonoGame effects; see [Shaders](#shaders) |

No `pad_layout`: the virtual gamepad starts in the 2D layout (the default).

## Shaders

- **Current:** 26 (20 pixel, 6 vertex) in MonoGame effects (MGFX version 8): the 13 XNB files in `Content/Effects` and SpriteBatch's built-in effect in `main`, read by `shader_split.py` (`mgfx_effect`). No other file and no GLSLC output holds shaders. Every binding decodes, with Mario's binding layout.
- The XNB files are platform `S`, uncompressed, read by `EffectReader`; each holds one MGFX effect. In `main`, four bytes `MGFX` count only when version 8 and a control section follow.
- 10 of the 13 effects have no vertex shader: SpriteBatch binds its own and the effect's pass only replaces the pixel shader. Vertex and pixel shaders therefore combine across effects, and they are paired as single-stage programs.
- **Resolved (PR #275 review):** all 26 shaders produce byte-identical Mac and iOS metallibs with target selection and with the preceding dual-target builder. Sources, reflection (apart from the chain version), `c1_full.tsv` and `cb_extent.tsv` agree too. Repeated builds of either target and returning to iOS after Mac restore all 26 shaders without new Metal compiles; dual-target builds and iOS cache reuse after them preserve the same outputs.

## Input

- Controller only. The game maps its buttons by position, so B and X jump.

## Mac routes

- A fresh save reaches the prologue with `DM_KEYS="f1850:A,f2200:A,f2600:A,f3000:A"` (the title, Climb, a new file, Begin; control of Madeline from about frame 5,000); then `f5100:LRight~1.0,f5400:LRight+X~0.3` walks to the first ledge and jumps onto it.

## Found on this game

General host changes first needed here; each applies to every game:

- **MonoGame effects** (MGFX) in XNB files and in `main` (`mgfx_effect` in `shader_split.py`): [MGFX effects in MonoGame XNB files](../../../docs/reference/shaders.md#mgfx-effects-in-monogame-xnb-files).
- **Capstone 5 pinned:** packing with Capstone 6 installed stopped in `patch_nso.py` with `CS_ARCH_ARM64` undefined: [Capstone API version](../../../docs/reference/rewriter.md#capstone-api-version).
- **Resolved:** iOS-only shader cache hits must also restore Mac analysis files: [Target selection keeps the shader analysis files in the cache](../../../docs/reference/shaders.md#target-selection-keeps-the-shader-analysis-files-in-the-cache).

## Open

- Only the merged 1.4.1.1 copy is extracted; the base game v0 is not.
