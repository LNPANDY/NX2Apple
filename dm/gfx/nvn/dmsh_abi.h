// The shader library ABI: what the offline build (dm/gfx/tools/dmsh_build.py) and the host (nvn_mtl.m, nvn_refl.m, hle_nvn.c) must agree on, written down once.
// The build reads this file through dm/gfx/tools/dmsh_abi.py, a strict reader of exactly this form: comment lines, #pragma once and "#define DMSH_<NAME> <value>" with a hex or
// decimal integer or a "string" as the value and an optional // comment after it. Anything else stops the build. A value here is part of the translation chain (dmsh_chain.py FILES):
// after changing one, run dmsh_chain.py --header and rebuild the shaders. dm/tools/tests/test_dmsh_abi.py checks the tables fit together, that Program.cs (the translator, which keeps
// its own copy of the c2 layout) agrees, and that the numbers and kind names do not come back as literals in the host or the build.
#pragma once

// The NVN driver's constant segments: one layout in every game (NVN 53 and 55 drivers, SDK 6 to 21: the handles of every shader of every profile fit it). A shader reads them as
// c[0] and c[2]; the build records which rows it reads (drv_reads), and the host fills one DMSH_DRV_SIZE buffer per segment it reads from the current bindings (nvn_mtl.m encode_args).
#define DMSH_DRV_SIZE 0xA00              // bytes of a driver segment buffer the host fills

// c2: the handle tables, one 32-bit handle word every DMSH_C2_ROW bytes
#define DMSH_C2_ROW 8                    // bytes from one slot's handle word to the next
#define DMSH_C2_TEX 0x20                 // combined handles (nvnCommandBufferBindTexture), slot r at 0x20 + 8 r. The driver has 32 such slots, but a game may bind higher ones, whose words lie in the image table (Hades II binds slot 34)
#define DMSH_C2_TEX_SLOTS 41             // combined slots up to the separate texture table: past slot 31 a slot shares its word with an image slot (nvn_mtl.m tex_slot_h)
#define DMSH_C2_IMG 0x120                // images (nvnCommandBufferBindImage), slot r at 0x120 + 8 r
#define DMSH_C2_IMG_SLOTS 8              // image slots in that table
#define DMSH_C2_SEPTEX 0x168             // separate textures (nvnCommandBufferBindSeparateTexture), slot r at 0x168 + 8 r; Unity, Unreal and RE Engine bind these
#define DMSH_C2_SAMP 0x568               // separate samplers (nvnCommandBufferBindSeparateSampler), slot r at 0x568 + 8 r
#define DMSH_C2_SEP_SLOTS 128            // slots of each separate table (textures, samplers)
#define DMSH_SEPTEX_SLOT0 128            // the texture slot the reflection gives separate texture 0: separate texture r is slot 128 + r, where the host binds it (nvn_obj.h NVN_SEPTEX_SLOT0)

// c0: tables of DMSH_C0_ROW-byte entries (address 64 bits, size 32 bits), and a few single words
#define DMSH_C0_ROW 0x10                 // bytes of one table entry
#define DMSH_C0_SSBO_SLOTS 16            // storage buffer slots of a stage's table
#define DMSH_C0_SSBO_VS 0x110            // vertex stage storage buffer table: slot r at 0x110 + 0x10 r
#define DMSH_C0_SSBO_CS 0x310            // compute stage storage buffer table
#define DMSH_C0_SSBO_GS 0x410            // geometry stage storage buffer table (NieR:Automata); the hull and domain stages' bases were never seen
#define DMSH_C0_SSBO_PS 0x510            // pixel stage storage buffer table
#define DMSH_C0_DISPATCH 0x200           // compute: the dispatch's workgroup counts x, y, z (32 bits each; Link's Awakening's light culling)
#define DMSH_C0_CS_UBO 0x210             // compute: uniform slot r's address and size at 0x210 + 0x10 r, read through global memory (the build's ubo_ptr bindings); it ends where the storage buffer table starts
#define DMSH_C0_CS_UBO_SLOTS 16          // uniform slots of that table
#define DMSH_C0_POINT_SIZE 0x610         // graphics stages: the largest point size, to which GLSLC clamps a shader-written gl_PointSize (Super Mario Odyssey's point sprites)
#define DMSH_C0_BASE_INSTANCE 0x644      // graphics stages: the draw's base instance, which GLSLC adds to Maxwell's instance ID (Pokémon Legends: Z-A's occlusion boxes)

// Binding kinds: the "kind" of each binding in a shader's <key>_b.json, as the build writes it and the host reads it (nvn_refl.m turns each into an NVN_RB_* code, nvn_refl.h)
#define DMSH_KIND_CBUF "cbuf"            // uniform buffer slot reg (c[3 + reg])
#define DMSH_KIND_C1 "c1"                // the shader's own constant segment c[1] (its bytes are the json's c1)
#define DMSH_KIND_DRVCB "drvcb"          // a driver segment, c[bank] (bank 0 or 2): NVN_RB_DRV0 / NVN_RB_DRV2
#define DMSH_KIND_SUPPORT "support"      // the translator's support buffer
#define DMSH_KIND_GEOMETRY "geometry"    // one of the geometry lowering's helper buffers, reg = its index (dmsh_geometry.py HELPERS)
#define DMSH_KIND_SBUF "sbuf"            // storage buffer slot reg, its address in the stage's c0 table; rw = the shader writes it
#define DMSH_KIND_SBUF_UBO "sbuf_ubo"    // a storage buffer whose address the game keeps in its own uniform slot reg at byte off
#define DMSH_KIND_UBO_PTR "ubo_ptr"      // compute: uniform slot reg read through its address in c0 (DMSH_C0_CS_UBO)
#define DMSH_KIND_TEX "tex"              // texture slot reg (combined, or DMSH_SEPTEX_SLOT0 + r for a separate texture)
#define DMSH_KIND_TBUF "tbuf"            // a buffer texture in texture slot reg
#define DMSH_KIND_IMG "img"              // image slot reg; atomic = the shader runs image atomics on it
#define DMSH_KIND_SAMP "samp"            // separate sampler slot reg
#define DMSH_KIND_SAMP_TEX "samp_tex"    // the sampler of the combined handle in texture slot reg
#define DMSH_KIND_SAMP_ID "samp_id"      // a sampler ID that is a constant in the shader (reg = the ID)
#define DMSH_KIND_TEX_UBO "tex_ubo"      // bindless: the texture handle is in uniform slot reg at byte off
#define DMSH_KIND_SAMP_UBO "samp_ubo"    // bindless: the sampler handle is in uniform slot reg at byte off
#define DMSH_KIND_TEX_C2A "tex_c2a"      // an array of c2 handles the shader indexes at run time: element k = the texture whose c2 word lies at off + 8 k
#define DMSH_KIND_SAMP_C2A "samp_c2a"    // the same for samplers
#define DMSH_KIND_TEX_POOL "tex_pool"    // the game's texture pool, indexed by the handle's texture ID (a handle traced to no slot; dmsh_build.py pool_arrays): elem = the element type
#define DMSH_KIND_SAMP_POOL "samp_pool"  // the sampler pool, indexed by the handle's sampler ID
#define DMSH_KIND_BORDER "border"        // the shader's border colour block (dmsh_build.py border_emu): a mask of the samplers to correct, then each one's factors

// A pool binding points at a buffer the host keeps (nvn_mtl.m pool_gpu): a 32-bit bound n (the highest index the shader may read), then from DMSH_POOL_HEAD one 8-byte resource ID per ID
#define DMSH_POOL_HEAD 8                 // bytes before element 0 of a pool buffer
#define DMSH_KIND_UNKNOWN "?"            // a binding the build could not place: the host refuses the shader

// The alpha test's state (dm/gfx/tools/dmsh_alpha.py, the <key>_ba libraries): uint function (NVN_ALPHA_FUNC_*), float reference, at this fragment buffer index (nvn_mtl.m at_bind)
#define DMSH_ALPHA_BUFFER 30             // the fragment argument table's last binding; translated shaders use only buffer 0 there

// Border colours Metal has no sampler state for (it has transparent black, opaque black and opaque white): the build gives each sampler member a shader samples through a twin,
// <member>_w, and the shader a block it reads per sample, r + (twin sample - r) * k when the sampler's bit is set (dmsh_build.py border_emu, nvn_border.h)
#define DMSH_BORDER_SAMPLERS 32          // sampler members one shader corrects (the bits of the block's mask word at byte 0; members past these keep Metal's nearest colour)
#define DMSH_BORDER_K 0x10               // byte offset of sampler bit i's factors k (a float4) in the block: DMSH_BORDER_K + 16 i
#define DMSH_BORDER_TWIN "_w"            // the suffix of a twin sampler member's name
#define DMSH_BORDER_MEMBER "dm_border"   // the name of the block's member in the argument buffer
// The logic operation's state (dm/gfx/tools/dmsh_logic.py, the <key>_bl libraries): uint operation (NVN_LOGIC_OP_*), 12 bytes of padding, a uint4 channel mask per colour target, at this fragment buffer index (nvn_mtl.m lo_bind)
#define DMSH_LOGIC_BUFFER 29
// Its function constants: bool, colour target n is attached (the variant reads it only then), at this index + n (nvn_mtl.m lo_fn specializes the entry point per pass's targets)
#define DMSH_LOGIC_FC 200
