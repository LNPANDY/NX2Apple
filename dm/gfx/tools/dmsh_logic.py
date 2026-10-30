# Logic operations (<key>_bl): NVN's ColorStateSetLogicOp combines the bits a pixel shader writes with the bits already in the target (CLEAR, AND, ..., OR, ..., SET), in place of
# blending; as in OpenGL and Vulkan it applies to integer targets. Metal has none. Xenoblade Chronicles 2 builds its per-pixel light probe lists with OR: each probe's box draws its index
# into the next free byte of an RG32Uint target and every other fragment writes 0, so without the operation every fragment replaced the list and the lighting showed hard-edged dark boxes.
# This variant is the pixel shader with its integer entry points (main0_u, main0_m: dmsh_build.py fs_uint) reading each integer colour output's attachment (framebuffer fetch,
# [[color(n)]]) and combining it with the output by the operation and per-target channel masks at fragment buffer DMSH_LOGIC_BUFFER before each return. An output whose target the pass
# lacks has no attachment to read, and Metal refuses a pipeline that reads one: each read depends on the function constant DMSH_LOGIC_FC + n. The operation is data, not part
# of the code: one pipeline serves every operation. Built offline into a library of its own beside <key>_b, with the same argument buffer and entry point names; the host loads it only
# for pipelines drawn with an operation other than COPY into unsigned integer targets (nvn_mtl.m lo_fn), so other draws keep the base library and read no attachment. The library holds
# only those entry points (the float ones, main0 and main0_d, are left out: the host never takes them from it).
# Usage: variant(msl) → (new MSL, the entry point names) or (None, reason)
import re
import dmsh_abi

HELPER = '''
struct dm_logic_state { uint op; uint pad0, pad1, pad2; uint4 mask[8]; };   // NVN_LOGIC_OP_* and each colour target's channel masks (dmsh_logic.py)
static inline uint4 dm_logic(uint4 s, uint4 d, constant dm_logic_state& l, uint n)
{
    uint4 r;
    switch (l.op)
    {
        case 0u: r = uint4(0u); break;
        case 1u: r = s & d; break;
        case 2u: r = s & ~d; break;
        case 4u: r = ~s & d; break;
        case 5u: r = d; break;
        case 6u: r = s ^ d; break;
        case 7u: r = s | d; break;
        case 8u: r = ~(s | d); break;
        case 9u: r = ~(s ^ d); break;
        case 10u: r = ~d; break;
        case 11u: r = s | ~d; break;
        case 12u: r = ~s; break;
        case 13u: r = ~s | d; break;
        case 14u: r = ~(s & d); break;
        case 15u: r = uint4(~0u); break;
        default: r = s; break;
    }
    return r & l.mask[n];
}
'''
ENTRIES = ('main0_u', 'main0_m')


def _close(src, i, o, c):
    """the index after the bracket closing the one opened just before i"""
    depth = 1
    while depth and i < len(src): depth += (src[i] == o) - (src[i] == c); i += 1
    return i if not depth else -1


def variant(msl):
    if f'[[buffer({dmsh_abi.LOGIC_BUFFER})]]' in msl: return None, f'fragment buffer {dmsh_abi.LOGIC_BUFFER} is taken'
    if re.search(r'\[\[color\(\d+\)\]\]\s*[,)]', msl): return None, 'an entry point already reads an attachment'
    pieces, at, names, targets = [], 0, [], set()
    for m in re.finditer(r'^[^\n]*?\bfragment\s+(main0_out_[um])\s+(main0_[um])\s*\(', msl, re.M):
        struct, name = m.groups()
        st = re.search(r'struct %s\s*\{(.*?)\};' % struct, msl, re.S)
        if not st: return None, f'no struct {struct}'
        ints = [(nm, int(n)) for ty, nm, n in re.findall(r'^\s*(uint[234]?)\s+(\w+)\s*\[\[color\((\d+)\)\]\];', st.group(1), re.M)]
        if not ints: continue
        params_end = _close(msl, m.end(), '(', ')')
        if params_end < 0: return None, 'an unclosed parameter list'
        body_start = msl.find('{', params_end)
        body_end = _close(msl, body_start + 1, '{', '}') if body_start >= 0 else -1
        if body_end < 0: return None, f'no body for {name}'
        empty = not msl[m.end():params_end - 1].strip()
        fetch = ''.join(f'{", " if (i or not empty) else ""}uint4 dm_fb{n} [[color({n}), function_constant(dm_lfb{n})]]' for i, (_, n) in enumerate(ints))
        params = fetch + f', constant dm_logic_state& dm_lop [[buffer({dmsh_abi.LOGIC_BUFFER})]]'
        apply = ' '.join(f'if (dm_lfb{n}) dm_r.{nm} = {ty}(dm_logic(uint4(dm_r.{nm}{pad}), dm_fb{n}, dm_lop, {n}u){sw});'
                         for nm, n in ints
                         for ty in [re.search(r'^\s*(uint[234]?)\s+%s\s*\[\[' % nm, st.group(1), re.M).group(1)]   # pyright: ignore[reportOptionalMemberAccess]  # the field findall just found
                         for pad, sw in [{'uint': (', 0u, 0u, 0u', '.x'), 'uint2': (', 0u, 0u', '.xy'), 'uint3': (', 0u', '.xyz'), 'uint4': ('', '')}[ty]])
        body, n = re.subn(r'\breturn\s+([^;]+);', lambda r: '{ ' + struct + ' dm_r = ' + r.group(1) + '; ' + apply + ' return dm_r; }', msl[body_start:body_end])   # noqa: B023  # subn calls it in this iteration
        if not n: return None, f'no return in {name}'
        pieces += [msl[at:params_end - 1], params, msl[params_end - 1:body_start], body]; at = body_end
        names.append(name); targets.update(n for _, n in ints)
    if not names: return None, 'no integer colour output'
    src = ''.join(pieces) + msl[at:]
    for m in reversed(list(re.finditer(r'^(?:\[\[[^\]]*\]\]\s*)?fragment\s+\w+\s+(\w+)\s*\(', src, re.M))):   # the other entry points: the host takes only these from the library
        if m.group(1) in names: continue
        params_end = _close(src, m.end(), '(', ')'); body_start = src.find('{', params_end) if params_end >= 0 else -1
        body_end = _close(src, body_start + 1, '{', '}') if body_start >= 0 else -1
        if body_end < 0: return None, f'no body for {m.group(1)}'
        src = src[:m.start()] + src[body_end:].lstrip('\n')
    first = re.search(r'^(?:\[\[[^\]]*\]\]\s*)?(?:fragment|vertex|kernel)\s+\w+\s+\w+\s*\(', src, re.M)   # the helper before the first entry point (SPIRV-Cross writes helper functions before them)
    consts = ''.join(f'constant bool dm_lfb{n} [[function_constant({dmsh_abi.LOGIC_FC + n})]];\n' for n in sorted(targets))
    return src[:first.start()] + HELPER + consts + src[first.start():], names   # pyright: ignore[reportOptionalMemberAccess]  # the entry points in names are left
