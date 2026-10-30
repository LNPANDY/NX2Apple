# ASTRAL CHAIN 1.0.1, main 4b159f0f7a360669738390ee8657b4f0.
# Host-paced 60 fps gameplay; fixed-step cinematics retain 30 fps for audio sync.
# Target 0 runs the original instructions at every hook. Helpers live in the
# rewriter's patch area, never in upstream's padding / empty-function caves.
# Integer timer and camera helpers adapted from AstralChain-Dynamic-FPS v1.1.1:
# https://github.com/yogesh1239/AstralChain-Dynamic-FPS/tree/79965b4df077f64b27b74456d0db88c6afac5bbe
# Its measured-time core and interval patches are replaced by the host's frame step.
# Every game-code hook is asserted below; the NSO build ID gates the entire set.
#
# MIT License
# Copyright (c) 2026 yogesh1239
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
from nso_asm import ADRP, ADDI, B, STP_PRE, LDP_POST


def signed(n, bits):
    return n - (1 << bits) if n & (1 << (bits - 1)) else n


def width(w):
    # ADR and short conditional branches expand; the other instructions stay one word.
    return 2 if (w & 0x9f000000 == 0x10000000 or w & 0xff000010 == 0x54000000
                 or w & 0x7e000000 in (0x34000000, 0x36000000)) else 1


def relocate(w, old, new, targets):
    def dest(a): return targets.get(a, a)
    if w & 0x7c000000 == 0x14000000:  # B / BL
        return [B(new, dest(old + signed(w & 0x3ffffff, 26) * 4)) | (w & 0x80000000)]
    if w & 0x9f000000 in (0x10000000, 0x90000000):  # ADR / ADRP
        imm = signed(((w >> 5 & 0x7ffff) << 2) | (w >> 29 & 3), 21)
        if w & 0x80000000: return [ADRP(w & 31, new, (old & ~0xfff) + (imm << 12))]
        a = dest(old + imm)
        return [ADRP(w & 31, new, a), ADDI(w & 31, w & 31, a & 0xfff)]
    if w & 0xff000010 == 0x54000000 or w & 0x7e000000 in (0x34000000, 0x36000000):
        bits = 14 if w & 0x7e000000 == 0x36000000 else 19
        mask = ((1 << bits) - 1) << 5
        a = dest(old + signed(w >> 5 & ((1 << bits) - 1), bits) * 4)
        invert = 1 if w & 0xff000010 == 0x54000000 else 0x01000000
        return [((w ^ invert) & ~mask) | (2 << 5), B(new + 4, a)]
    assert w & 0x3b000000 != 0x18000000, 'unexpected literal load in timing helper'
    return [w]


def frame_step(ctx):
    # At main+0x91dc10 x19 is the clock, w21 selects elapsed-time gameplay
    # (0 is fixed-step cinematics), x20 is this frame's timestamp. The ordinary
    # epilogue restores d8/x19/x20/x21. s0/s1/s2 and x8/x16/x17 are scratch here.
    core = ctx.here(); ctx.emit(ADRP(16, core, ctx.state))
    for i, w in enumerate(clock):
        if i == 22: w = B(ctx.here(), 0x8a9570) | 0x80000000  # game's positive speed override
        elif i == len(clock) - 1: w = B(ctx.here(), 0x91dcb4)  # timestamp and epilogue
        ctx.emit(w)
    targets = {0xa0e7d0: core, 0xa0e828: core}
    cursor = ctx.here()
    for old, w in helpers:
        targets[old] = cursor; cursor += width(w) * 4
    for old, w in helpers:
        assert ctx.here() == targets[old]
        for insn in relocate(w, old, ctx.here(), targets): ctx.emit(insn)
    for site, orig, w, reason in sites:
        ctx.site(site, orig)
        start = ctx.here(); nw = width(w)
        # CBZ changes no flags: preserve all original NZCV and scratch registers,
        # including at decrement sites whose caller consumes the resulting flags.
        for insn in (STP_PRE(16, 17, 31, -16), ADRP(16, start + 4, ctx.state),
                     0xb9400210, 0x34000010 | ((3 + nw) << 5), LDP_POST(16, 17, 31, 16)):
            ctx.emit(insn)
        for insn in relocate(w, site, ctx.here(), targets): ctx.emit(insn)
        ctx.emit(B(ctx.here(), site + 4))
        ctx.emit(LDP_POST(16, 17, 31, 16))
        for insn in relocate(int.from_bytes(bytes.fromhex(orig), 'little'), site, ctx.here(), {}): ctx.emit(insn)
        ctx.emit(B(ctx.here(), site + 4))
        ctx.put(site, [B(site, start)], 'frame step (0 = original): ' + reason)


FRAME_STEP = {'4b159f0f7a360669738390ee8657b4f0': frame_step}

# Core: frame-state +4 marks a 30 fps cinematic; +0x24 fixes its step at two
# vsyncs. Gameplay takes the host's step (+0x20), or 60 / target before the first
# present. Game clock +0xd0 is the floating 30 Hz step, +0xd4 retains fractional
# ticks, +0xd8 publishes whole ticks. Integer consumers therefore advance 30
# ticks per second at both 30 and 60 fps instead of truncating every half tick.
clock = (
    0x350000d5,  # cbnz w21, #0x18
    0x52800031,  # mov w17, #1
    0xb9000611,  # str w17, [x16, #4]
    0x52800051,  # mov w17, #2
    0xb9002611,  # str w17, [x16, #0x24]
    0x1400000a,  # b #0x3c
    0xb900061f,  # str wzr, [x16, #4]
    0xb900261f,  # str wzr, [x16, #0x24]
    0xb9402211,  # ldr w17, [x16, #0x20]
    0x350000d1,  # cbnz w17, #0x3c
    0xbd400200,  # ldr s0, [x16]
    0x1e27d001,  # fmov s1, #30.00000000
    0x1e212821,  # fadd s1, s1, s1
    0x1e201820,  # fdiv s0, s1, s0
    0x1e390011,  # fcvtzu w17, s0
    0x1e230228,  # ucvtf s8, w17
    0x1e2c1001,  # fmov s1, #0.50000000
    0x1e210908,  # fmul s8, s8, s1
    0x34000115,  # cbz w21, #0x68
    0xf9401a08,  # ldr x8, [x16, #0x30]
    0x8b314108,  # add x8, x8, w17, uxtw
    0xf9001a08,  # str x8, [x16, #0x30]
    0x94000010,  # bl #0x98
    0x1e202008,  # fcmp s0, #0.0
    0x5400004d,  # b.le #0x68
    0x1e200908,  # fmul s8, s8, s0
    0x1e201001,  # fmov s1, #2.00000000
    0x1e217900,  # fminnm s0, s8, s1
    0xbd00d260,  # str s0, [x19, #0xd0]
    0xbd40d661,  # ldr s1, [x19, #0xd4]
    0x1e202821,  # fadd s1, s1, s0
    0x1e390028,  # fcvtzu w8, s1
    0x1e230102,  # ucvtf s2, w8
    0x1e223821,  # fsub s1, s1, s2
    0xbd00d661,  # str s1, [x19, #0xd4]
    0xb900da68,  # str w8, [x19, #0xd8]
    0xb900e67f,  # str wzr, [x19, #0xe4]
    0x14000001,  # b #0x98
)

# Upstream helper addresses are relocation labels only. No original cave is overwritten.
helpers = [
    (0x5763e4, 0x1e2a5800),  # fmin s0,s0,s10: entry1 (eye): a = min(w*rate, 1)
    (0x5763e8, 0x140ee8d5),  # b 0x93073C [relocated]
    (0x5763ec, 0x1e2a5820),  # fmin s0,s1,s10: entry2 (look-at): a = min(w*rate, 1)
    (0x5763f0, 0x140ee8d3),  # b 0x93073C [relocated]
    (0x5763f4, 0xa9bf7bfd),  # stp x29,x30,[sp,#-0x10]!: entry3 (up + scalar blend)
    (0x5763f8, 0x910003fd),  # mov x29,sp
    (0x5763fc, 0x1e204120),  # fmov s0,s9
    (0x576400, 0x940ee8cf),  # bl 0x93073C [relocated]
    (0x576404, 0x1e204109),  # fmov s9,s8: w for +0x100/+0x108 blend (0x3A2E04/0x3A2E0C)
    (0x576408, 0xbd421660),  # ldr s0,[x19,0x214]: re-test [cam+0x214] > 0
    (0x57640c, 0x1e202008),  # fcmp s0,#0.0
    (0x576410, 0x1e29cd48),  # fcsel s8,s10,s9,gt
    (0x576414, 0xa8c17bfd),  # ldp x29,x30,[sp],0x10
    (0x576418, 0xd65f03c0),  # ret
    (0x93073c, 0x1e204008),  # fmov s8,s0: common: s8 = 1-powf(1-a, clamp(step,0,4))
    (0x930740, 0xa9bd7bfd),  # stp x29,x30,[sp,#-0x30]!
    (0x930744, 0x910003fd),  # mov x29,sp
    (0x930748, 0xa90107e0),  # stp x0,x1,[sp,0x10]
    (0x93074c, 0xf90013e2),  # str x2,[sp,0x20]
    (0x930750, 0x90002450),  # adrp x16,0xdb8000: timer object via GOT 0xDB89A0 [relocated]
    (0x930754, 0xf944d210),  # ldr x16,[x16,0x9a0]
    (0x930758, 0xb4000230),  # cbz x16,0x93079c
    (0x93075c, 0xbd40d201),  # ldr s1,[x16,0xd0]: v2 step [timer+0xD0]
    (0x930760, 0x1e2e1002),  # fmov s2,#1.00000000
    (0x930764, 0x1e222020),  # fcmp s1,s2
    (0x930768, 0x540001a0),  # b.eq 0x93079c: step == 1.0: exact passthrough
    (0x93076c, 0x1e202008),  # fcmp s0,#0.0
    (0x930770, 0x5400016d),  # b.le 0x93079c: a <= 0 or NaN: passthrough
    (0x930774, 0x1e222000),  # fcmp s0,s2
    (0x930778, 0x5400012a),  # b.ge 0x93079c: a >= 1: passthrough
    (0x93077c, 0x2f00e403),  # movi d3,#0000000000000000
    (0x930780, 0x1e236821),  # fmaxnm s1,s1,s3
    (0x930784, 0x1e221003),  # fmov s3,#4.00000000
    (0x930788, 0x1e237821),  # fminnm s1,s1,s3
    (0x93078c, 0x1e203840),  # fsub s0,s2,s0
    (0x930790, 0x940373a0),  # bl 0xa0d610: powf PLT [relocated]
    (0x930794, 0x1e2e1002),  # fmov s2,#1.00000000
    (0x930798, 0x1e203848),  # fsub s8,s2,s0
    (0x93079c, 0xa94107e0),  # ldp x0,x1,[sp,0x10]
    (0x9307a0, 0xf94013e2),  # ldr x2,[sp,0x20]
    (0x9307a4, 0xa8c37bfd),  # ldp x29,x30,[sp],0x30
    (0x9307a8, 0xd65f03c0),  # ret
    (0xa0e830, 0xd0001d49),  # r2 cave 0x308a9c: adrp x9, #0xdb8000
    (0xa0e834, 0xf944d129),  # r2 cave 0x308a9c: ldr x9, [x9, #0x9a0]
    (0xa0e838, 0xb940d929),  # r2 cave 0x308a9c: ldr w9, [x9, #0xd8]
    (0xa0e83c, 0x340000c9),  # r2 cave 0x308a9c: cbz w9, #0xa0e854
    (0xa0e840, 0x7100051f),  # r2 cave 0x308a9c: cmp w8, #1
    (0xa0e844, 0x7a49a100),  # r2 cave 0x308a9c: ccmp w8, w9, #0, ge
    (0xa0e848, 0x1a89b109),  # r2 cave 0x308a9c: csel w9, w8, w9, lt
    (0xa0e84c, 0x6b090108),  # r2 cave 0x308a9c: subs w8, w8, w9
    (0xa0e850, 0x17e3e894),  # r2 cave 0x308a9c: b #0x308aa0
    (0xa0e854, 0x7100011f),  # r2 cave 0x308a9c: cmp w8, #0
    (0xa0e858, 0x7a40c908),  # r2 cave 0x308a9c: ccmp w8, #0, #8, gt
    (0xa0e85c, 0x17e3e891),  # r2 cave 0x308a9c: b #0x308aa0
    (0xa0e860, 0xd0001d4a),  # r2 cave 0xf8720: adrp x10, #0xdb8000
    (0xa0e864, 0xf944d14a),  # r2 cave 0xf8720: ldr x10, [x10, #0x9a0]
    (0xa0e868, 0xb940d94a),  # r2 cave 0xf8720: ldr w10, [x10, #0xd8]
    (0xa0e86c, 0x340000ca),  # r2 cave 0xf8720: cbz w10, #0xa0e884
    (0xa0e870, 0x7100051f),  # r2 cave 0xf8720: cmp w8, #1
    (0xa0e874, 0x7a4aa100),  # r2 cave 0xf8720: ccmp w8, w10, #0, ge
    (0xa0e878, 0x1a8ab10a),  # r2 cave 0xf8720: csel w10, w8, w10, lt
    (0xa0e87c, 0x6b0a0108),  # r2 cave 0xf8720: subs w8, w8, w10
    (0xa0e880, 0x17dba7a9),  # r2 cave 0xf8720: b #0xf8724
    (0xa0e884, 0x7100011f),  # r2 cave 0xf8720: cmp w8, #0
    (0xa0e888, 0x7a40c908),  # r2 cave 0xf8720: ccmp w8, #0, #8, gt
    (0xa0e88c, 0x17dba7a6),  # r2 cave 0xf8720: b #0xf8724
    (0xa0e890, 0xd0001d4a),  # r2 cave 0xe7f64: adrp x10, #0xdb8000
    (0xa0e894, 0xf944d14a),  # r2 cave 0xe7f64: ldr x10, [x10, #0x9a0]
    (0xa0e898, 0xb940d94a),  # r2 cave 0xe7f64: ldr w10, [x10, #0xd8]
    (0xa0e89c, 0x340000ca),  # r2 cave 0xe7f64: cbz w10, #0xa0e8b4
    (0xa0e8a0, 0x7100051f),  # r2 cave 0xe7f64: cmp w8, #1
    (0xa0e8a4, 0x7a4aa100),  # r2 cave 0xe7f64: ccmp w8, w10, #0, ge
    (0xa0e8a8, 0x1a8ab10a),  # r2 cave 0xe7f64: csel w10, w8, w10, lt
    (0xa0e8ac, 0x6b0a0108),  # r2 cave 0xe7f64: subs w8, w8, w10
    (0xa0e8b0, 0x17db65ae),  # r2 cave 0xe7f64: b #0xe7f68
    (0xa0e8b4, 0x7100011f),  # r2 cave 0xe7f64: cmp w8, #0
    (0xa0e8b8, 0x7a40c908),  # r2 cave 0xe7f64: ccmp w8, #0, #8, gt
    (0xa0e8bc, 0x17db65ab),  # r2 cave 0xe7f64: b #0xe7f68
    (0xa0e8c0, 0xd0001d49),  # r2 cave 0xf7ce8: adrp x9, #0xdb8000
    (0xa0e8c4, 0xf944d129),  # r2 cave 0xf7ce8: ldr x9, [x9, #0x9a0]
    (0xa0e8c8, 0xb940d929),  # r2 cave 0xf7ce8: ldr w9, [x9, #0xd8]
    (0xa0e8cc, 0x340000c9),  # r2 cave 0xf7ce8: cbz w9, #0xa0e8e4
    (0xa0e8d0, 0x7100051f),  # r2 cave 0xf7ce8: cmp w8, #1
    (0xa0e8d4, 0x7a49a100),  # r2 cave 0xf7ce8: ccmp w8, w9, #0, ge
    (0xa0e8d8, 0x1a89b109),  # r2 cave 0xf7ce8: csel w9, w8, w9, lt
    (0xa0e8dc, 0x6b090108),  # r2 cave 0xf7ce8: subs w8, w8, w9
    (0xa0e8e0, 0x17dba503),  # r2 cave 0xf7ce8: b #0xf7cec
    (0xa0e8e4, 0x7100011f),  # r2 cave 0xf7ce8: cmp w8, #0
    (0xa0e8e8, 0x7a40c908),  # r2 cave 0xf7ce8: ccmp w8, #0, #8, gt
    (0xa0e8ec, 0x17dba500),  # r2 cave 0xf7ce8: b #0xf7cec
    (0xa0e8f0, 0xd0001d4a),  # r2 cave 0xd5e28: adrp x10, #0xdb8000
    (0xa0e8f4, 0xf944d14a),  # r2 cave 0xd5e28: ldr x10, [x10, #0x9a0]
    (0xa0e8f8, 0xb940d94a),  # r2 cave 0xd5e28: ldr w10, [x10, #0xd8]
    (0xa0e8fc, 0x340000ca),  # r2 cave 0xd5e28: cbz w10, #0xa0e914
    (0xa0e900, 0x7100051f),  # r2 cave 0xd5e28: cmp w8, #1
    (0xa0e904, 0x7a4aa100),  # r2 cave 0xd5e28: ccmp w8, w10, #0, ge
    (0xa0e908, 0x1a8ab10a),  # r2 cave 0xd5e28: csel w10, w8, w10, lt
    (0xa0e90c, 0x6b0a0108),  # r2 cave 0xd5e28: subs w8, w8, w10
    (0xa0e910, 0x17db1d47),  # r2 cave 0xd5e28: b #0xd5e2c
    (0xa0e914, 0x7100011f),  # r2 cave 0xd5e28: cmp w8, #0
    (0xa0e918, 0x7a40c908),  # r2 cave 0xd5e28: ccmp w8, #0, #8, gt
    (0xa0e91c, 0x17db1d44),  # r2 cave 0xd5e28: b #0xd5e2c
    (0xa0e920, 0xd0001d4a),  # r2 cave 0x2828ac: adrp x10, #0xdb8000
    (0xa0e924, 0xf944d14a),  # r2 cave 0x2828ac: ldr x10, [x10, #0x9a0]
    (0xa0e928, 0xb940d94a),  # r2 cave 0x2828ac: ldr w10, [x10, #0xd8]
    (0xa0e92c, 0x340000ca),  # r2 cave 0x2828ac: cbz w10, #0xa0e944
    (0xa0e930, 0x7100051f),  # r2 cave 0x2828ac: cmp w8, #1
    (0xa0e934, 0x7a4aa100),  # r2 cave 0x2828ac: ccmp w8, w10, #0, ge
    (0xa0e938, 0x1a8ab10a),  # r2 cave 0x2828ac: csel w10, w8, w10, lt
    (0xa0e93c, 0x6b0a0108),  # r2 cave 0x2828ac: subs w8, w8, w10
    (0xa0e940, 0x17e1cfdc),  # r2 cave 0x2828ac: b #0x2828b0
    (0xa0e944, 0x7100011f),  # r2 cave 0x2828ac: cmp w8, #0
    (0xa0e948, 0x7a40c908),  # r2 cave 0x2828ac: ccmp w8, #0, #8, gt
    (0xa0e94c, 0x17e1cfd9),  # r2 cave 0x2828ac: b #0x2828b0
    (0xa0e950, 0xd0001d4a),  # r2 cave 0x283100: adrp x10, #0xdb8000
    (0xa0e954, 0xf944d14a),  # r2 cave 0x283100: ldr x10, [x10, #0x9a0]
    (0xa0e958, 0xb940d94a),  # r2 cave 0x283100: ldr w10, [x10, #0xd8]
    (0xa0e95c, 0x340000ca),  # r2 cave 0x283100: cbz w10, #0xa0e974
    (0xa0e960, 0x7100051f),  # r2 cave 0x283100: cmp w8, #1
    (0xa0e964, 0x7a4aa100),  # r2 cave 0x283100: ccmp w8, w10, #0, ge
    (0xa0e968, 0x1a8ab10a),  # r2 cave 0x283100: csel w10, w8, w10, lt
    (0xa0e96c, 0x6b0a0108),  # r2 cave 0x283100: subs w8, w8, w10
    (0xa0e970, 0x17e1d1e5),  # r2 cave 0x283100: b #0x283104
    (0xa0e974, 0x7100011f),  # r2 cave 0x283100: cmp w8, #0
    (0xa0e978, 0x7a40c908),  # r2 cave 0x283100: ccmp w8, #0, #8, gt
    (0xa0e97c, 0x17e1d1e2),  # r2 cave 0x283100: b #0x283104
    (0xa0e980, 0xd0001d4a),  # r2 cave 0x28311c: adrp x10, #0xdb8000
    (0xa0e984, 0xf944d14a),  # r2 cave 0x28311c: ldr x10, [x10, #0x9a0]
    (0xa0e988, 0xb940d94a),  # r2 cave 0x28311c: ldr w10, [x10, #0xd8]
    (0xa0e98c, 0x340000ca),  # r2 cave 0x28311c: cbz w10, #0xa0e9a4
    (0xa0e990, 0x7100051f),  # r2 cave 0x28311c: cmp w8, #1
    (0xa0e994, 0x7a4aa100),  # r2 cave 0x28311c: ccmp w8, w10, #0, ge
    (0xa0e998, 0x1a8ab10a),  # r2 cave 0x28311c: csel w10, w8, w10, lt
    (0xa0e99c, 0x6b0a0108),  # r2 cave 0x28311c: subs w8, w8, w10
    (0xa0e9a0, 0x17e1d1e0),  # r2 cave 0x28311c: b #0x283120
    (0xa0e9a4, 0x7100011f),  # r2 cave 0x28311c: cmp w8, #0
    (0xa0e9a8, 0x7a40c908),  # r2 cave 0x28311c: ccmp w8, #0, #8, gt
    (0xa0e9ac, 0x17e1d1dd),  # r2 cave 0x28311c: b #0x283120
    (0xa0e9b0, 0xd0001d4a),  # r2 cave 0x28759c: adrp x10, #0xdb8000
    (0xa0e9b4, 0xf944d14a),  # r2 cave 0x28759c: ldr x10, [x10, #0x9a0]
    (0xa0e9b8, 0xb940d94a),  # r2 cave 0x28759c: ldr w10, [x10, #0xd8]
    (0xa0e9bc, 0x340000ca),  # r2 cave 0x28759c: cbz w10, #0xa0e9d4
    (0xa0e9c0, 0x7100051f),  # r2 cave 0x28759c: cmp w8, #1
    (0xa0e9c4, 0x7a4aa100),  # r2 cave 0x28759c: ccmp w8, w10, #0, ge
    (0xa0e9c8, 0x1a8ab10a),  # r2 cave 0x28759c: csel w10, w8, w10, lt
    (0xa0e9cc, 0x6b0a0108),  # r2 cave 0x28759c: subs w8, w8, w10
    (0xa0e9d0, 0x17e1e2f4),  # r2 cave 0x28759c: b #0x2875a0
    (0xa0e9d4, 0x7100011f),  # r2 cave 0x28759c: cmp w8, #0
    (0xa0e9d8, 0x7a40c908),  # r2 cave 0x28759c: ccmp w8, #0, #8, gt
    (0xa0e9dc, 0x17e1e2f1),  # r2 cave 0x28759c: b #0x2875a0
    (0xa0e9e0, 0xd0001d4a),  # r2 cave 0x2875ac: adrp x10, #0xdb8000
    (0xa0e9e4, 0xf944d14a),  # r2 cave 0x2875ac: ldr x10, [x10, #0x9a0]
    (0xa0e9e8, 0xb940d94a),  # r2 cave 0x2875ac: ldr w10, [x10, #0xd8]
    (0xa0e9ec, 0x340000ca),  # r2 cave 0x2875ac: cbz w10, #0xa0ea04
    (0xa0e9f0, 0x7100051f),  # r2 cave 0x2875ac: cmp w8, #1
    (0xa0e9f4, 0x7a4aa100),  # r2 cave 0x2875ac: ccmp w8, w10, #0, ge
    (0xa0e9f8, 0x1a8ab10a),  # r2 cave 0x2875ac: csel w10, w8, w10, lt
    (0xa0e9fc, 0x6b0a0108),  # r2 cave 0x2875ac: subs w8, w8, w10
    (0xa0ea00, 0x17e1e2ec),  # r2 cave 0x2875ac: b #0x2875b0
    (0xa0ea04, 0x7100011f),  # r2 cave 0x2875ac: cmp w8, #0
    (0xa0ea08, 0x7a40c908),  # r2 cave 0x2875ac: ccmp w8, #0, #8, gt
    (0xa0ea0c, 0x17e1e2e9),  # r2 cave 0x2875ac: b #0x2875b0
    (0xa0ea10, 0xd0001d4a),  # r2 cave 0x2875bc: adrp x10, #0xdb8000
    (0xa0ea14, 0xf944d14a),  # r2 cave 0x2875bc: ldr x10, [x10, #0x9a0]
    (0xa0ea18, 0xb940d94a),  # r2 cave 0x2875bc: ldr w10, [x10, #0xd8]
    (0xa0ea1c, 0x340000ca),  # r2 cave 0x2875bc: cbz w10, #0xa0ea34
    (0xa0ea20, 0x7100051f),  # r2 cave 0x2875bc: cmp w8, #1
    (0xa0ea24, 0x7a4aa100),  # r2 cave 0x2875bc: ccmp w8, w10, #0, ge
    (0xa0ea28, 0x1a8ab10a),  # r2 cave 0x2875bc: csel w10, w8, w10, lt
    (0xa0ea2c, 0x6b0a0108),  # r2 cave 0x2875bc: subs w8, w8, w10
    (0xa0ea30, 0x17e1e2e4),  # r2 cave 0x2875bc: b #0x2875c0
    (0xa0ea34, 0x7100011f),  # r2 cave 0x2875bc: cmp w8, #0
    (0xa0ea38, 0x7a40c908),  # r2 cave 0x2875bc: ccmp w8, #0, #8, gt
    (0xa0ea3c, 0x17e1e2e1),  # r2 cave 0x2875bc: b #0x2875c0
    (0xa0ea40, 0xd0001d4a),  # r2 cave 0x2875cc: adrp x10, #0xdb8000
    (0xa0ea44, 0xf944d14a),  # r2 cave 0x2875cc: ldr x10, [x10, #0x9a0]
    (0xa0ea48, 0xb940d94a),  # r2 cave 0x2875cc: ldr w10, [x10, #0xd8]
    (0xa0ea4c, 0x340000ca),  # r2 cave 0x2875cc: cbz w10, #0xa0ea64
    (0xa0ea50, 0x7100051f),  # r2 cave 0x2875cc: cmp w8, #1
    (0xa0ea54, 0x7a4aa100),  # r2 cave 0x2875cc: ccmp w8, w10, #0, ge
    (0xa0ea58, 0x1a8ab10a),  # r2 cave 0x2875cc: csel w10, w8, w10, lt
    (0xa0ea5c, 0x6b0a0108),  # r2 cave 0x2875cc: subs w8, w8, w10
    (0xa0ea60, 0x17e1e2dc),  # r2 cave 0x2875cc: b #0x2875d0
    (0xa0ea64, 0x7100011f),  # r2 cave 0x2875cc: cmp w8, #0
    (0xa0ea68, 0x7a40c908),  # r2 cave 0x2875cc: ccmp w8, #0, #8, gt
    (0xa0ea6c, 0x17e1e2d9),  # r2 cave 0x2875cc: b #0x2875d0
    (0xa0ea70, 0xd0001d4a),  # r2 cave 0x2875dc: adrp x10, #0xdb8000
    (0xa0ea74, 0xf944d14a),  # r2 cave 0x2875dc: ldr x10, [x10, #0x9a0]
    (0xa0ea78, 0xb940d94a),  # r2 cave 0x2875dc: ldr w10, [x10, #0xd8]
    (0xa0ea7c, 0x340000ca),  # r2 cave 0x2875dc: cbz w10, #0xa0ea94
    (0xa0ea80, 0x7100051f),  # r2 cave 0x2875dc: cmp w8, #1
    (0xa0ea84, 0x7a4aa100),  # r2 cave 0x2875dc: ccmp w8, w10, #0, ge
    (0xa0ea88, 0x1a8ab10a),  # r2 cave 0x2875dc: csel w10, w8, w10, lt
    (0xa0ea8c, 0x6b0a0108),  # r2 cave 0x2875dc: subs w8, w8, w10
    (0xa0ea90, 0x17e1e2d4),  # r2 cave 0x2875dc: b #0x2875e0
    (0xa0ea94, 0x7100011f),  # r2 cave 0x2875dc: cmp w8, #0
    (0xa0ea98, 0x7a40c908),  # r2 cave 0x2875dc: ccmp w8, #0, #8, gt
    (0xa0ea9c, 0x17e1e2d1),  # r2 cave 0x2875dc: b #0x2875e0
    (0xa0eaa0, 0xd0001d4b),  # r2 cave 0x283044: adrp x11, #0xdb8000
    (0xa0eaa4, 0xf944d16b),  # r2 cave 0x283044: ldr x11, [x11, #0x9a0]
    (0xa0eaa8, 0xb940d96b),  # r2 cave 0x283044: ldr w11, [x11, #0xd8]
    (0xa0eaac, 0x6b0b010b),  # r2 cave 0x283044: subs w11, w8, w11
    (0xa0eab0, 0x1a9f816b),  # r2 cave 0x283044: csel w11, w11, wzr, hi
    (0xa0eab4, 0x7100011f),  # r2 cave 0x283044: cmp w8, #0
    (0xa0eab8, 0x1a88c168),  # r2 cave 0x283044: csel w8, w11, w8, gt
    (0xa0eabc, 0x17e1d163),  # r2 cave 0x283044: b #0x283048
    (0xa0eac0, 0xd0001d4b),  # r2 cave 0x283054: adrp x11, #0xdb8000
    (0xa0eac4, 0xf944d16b),  # r2 cave 0x283054: ldr x11, [x11, #0x9a0]
    (0xa0eac8, 0xb940d96b),  # r2 cave 0x283054: ldr w11, [x11, #0xd8]
    (0xa0eacc, 0x6b0b010b),  # r2 cave 0x283054: subs w11, w8, w11
    (0xa0ead0, 0x1a9f816b),  # r2 cave 0x283054: csel w11, w11, wzr, hi
    (0xa0ead4, 0x7100011f),  # r2 cave 0x283054: cmp w8, #0
    (0xa0ead8, 0x1a88c168),  # r2 cave 0x283054: csel w8, w11, w8, gt
    (0xa0eadc, 0x17e1d15f),  # r2 cave 0x283054: b #0x283058
    (0xa0eae0, 0xd0001d4b),  # r2 cave 0x283064: adrp x11, #0xdb8000
    (0xa0eae4, 0xf944d16b),  # r2 cave 0x283064: ldr x11, [x11, #0x9a0]
    (0xa0eae8, 0xb940d96b),  # r2 cave 0x283064: ldr w11, [x11, #0xd8]
    (0xa0eaec, 0x6b0b010b),  # r2 cave 0x283064: subs w11, w8, w11
    (0xa0eaf0, 0x1a9f816b),  # r2 cave 0x283064: csel w11, w11, wzr, hi
    (0xa0eaf4, 0x7100011f),  # r2 cave 0x283064: cmp w8, #0
    (0xa0eaf8, 0x1a88c168),  # r2 cave 0x283064: csel w8, w11, w8, gt
    (0xa0eafc, 0x17e1d15b),  # r2 cave 0x283064: b #0x283068
    (0xa0eb00, 0xd0001d4b),  # r2 cave 0x283074: adrp x11, #0xdb8000
    (0xa0eb04, 0xf944d16b),  # r2 cave 0x283074: ldr x11, [x11, #0x9a0]
    (0xa0eb08, 0xb940d96b),  # r2 cave 0x283074: ldr w11, [x11, #0xd8]
    (0xa0eb0c, 0x6b0b010b),  # r2 cave 0x283074: subs w11, w8, w11
    (0xa0eb10, 0x1a9f816b),  # r2 cave 0x283074: csel w11, w11, wzr, hi
    (0xa0eb14, 0x7100011f),  # r2 cave 0x283074: cmp w8, #0
    (0xa0eb18, 0x1a88c168),  # r2 cave 0x283074: csel w8, w11, w8, gt
    (0xa0eb1c, 0x17e1d157),  # r2 cave 0x283074: b #0x283078
    (0xa0eb20, 0xd0001d4b),  # r2 cave 0x283084: adrp x11, #0xdb8000
    (0xa0eb24, 0xf944d16b),  # r2 cave 0x283084: ldr x11, [x11, #0x9a0]
    (0xa0eb28, 0xb940d96b),  # r2 cave 0x283084: ldr w11, [x11, #0xd8]
    (0xa0eb2c, 0x6b0b010b),  # r2 cave 0x283084: subs w11, w8, w11
    (0xa0eb30, 0x1a9f816b),  # r2 cave 0x283084: csel w11, w11, wzr, hi
    (0xa0eb34, 0x7100011f),  # r2 cave 0x283084: cmp w8, #0
    (0xa0eb38, 0x1a88c168),  # r2 cave 0x283084: csel w8, w11, w8, gt
    (0xa0eb3c, 0x17e1d153),  # r2 cave 0x283084: b #0x283088
    (0xa0eb40, 0xd0001d4b),  # r2 cave 0x283094: adrp x11, #0xdb8000
    (0xa0eb44, 0xf944d16b),  # r2 cave 0x283094: ldr x11, [x11, #0x9a0]
    (0xa0eb48, 0xb940d96b),  # r2 cave 0x283094: ldr w11, [x11, #0xd8]
    (0xa0eb4c, 0x6b0b010b),  # r2 cave 0x283094: subs w11, w8, w11
    (0xa0eb50, 0x1a9f816b),  # r2 cave 0x283094: csel w11, w11, wzr, hi
    (0xa0eb54, 0x7100011f),  # r2 cave 0x283094: cmp w8, #0
    (0xa0eb58, 0x1a88c168),  # r2 cave 0x283094: csel w8, w11, w8, gt
    (0xa0eb5c, 0x17e1d14f),  # r2 cave 0x283094: b #0x283098
    (0xa0eb60, 0xd0001d4b),  # r2 cave 0x2830a4: adrp x11, #0xdb8000
    (0xa0eb64, 0xf944d16b),  # r2 cave 0x2830a4: ldr x11, [x11, #0x9a0]
    (0xa0eb68, 0xb940d96b),  # r2 cave 0x2830a4: ldr w11, [x11, #0xd8]
    (0xa0eb6c, 0x6b0b010b),  # r2 cave 0x2830a4: subs w11, w8, w11
    (0xa0eb70, 0x1a9f816b),  # r2 cave 0x2830a4: csel w11, w11, wzr, hi
    (0xa0eb74, 0x7100011f),  # r2 cave 0x2830a4: cmp w8, #0
    (0xa0eb78, 0x1a88c168),  # r2 cave 0x2830a4: csel w8, w11, w8, gt
    (0xa0eb7c, 0x17e1d14b),  # r2 cave 0x2830a4: b #0x2830a8
    (0xa0eb80, 0xd0001d4b),  # r2 cave 0x2830b4: adrp x11, #0xdb8000
    (0xa0eb84, 0xf944d16b),  # r2 cave 0x2830b4: ldr x11, [x11, #0x9a0]
    (0xa0eb88, 0xb940d96b),  # r2 cave 0x2830b4: ldr w11, [x11, #0xd8]
    (0xa0eb8c, 0x6b0b010b),  # r2 cave 0x2830b4: subs w11, w8, w11
    (0xa0eb90, 0x1a9f816b),  # r2 cave 0x2830b4: csel w11, w11, wzr, hi
    (0xa0eb94, 0x7100011f),  # r2 cave 0x2830b4: cmp w8, #0
    (0xa0eb98, 0x1a88c168),  # r2 cave 0x2830b4: csel w8, w11, w8, gt
    (0xa0eb9c, 0x17e1d147),  # r2 cave 0x2830b4: b #0x2830b8
    (0xa0eba0, 0xd0001d4b),  # r2 cave 0x2830c4: adrp x11, #0xdb8000
    (0xa0eba4, 0xf944d16b),  # r2 cave 0x2830c4: ldr x11, [x11, #0x9a0]
    (0xa0eba8, 0xb940d96b),  # r2 cave 0x2830c4: ldr w11, [x11, #0xd8]
    (0xa0ebac, 0x6b0b010b),  # r2 cave 0x2830c4: subs w11, w8, w11
    (0xa0ebb0, 0x1a9f816b),  # r2 cave 0x2830c4: csel w11, w11, wzr, hi
    (0xa0ebb4, 0x7100011f),  # r2 cave 0x2830c4: cmp w8, #0
    (0xa0ebb8, 0x1a88c168),  # r2 cave 0x2830c4: csel w8, w11, w8, gt
    (0xa0ebbc, 0x17e1d143),  # r2 cave 0x2830c4: b #0x2830c8
    (0xa0ebc0, 0xd0001d4b),  # r2 cave 0x2830d4: adrp x11, #0xdb8000
    (0xa0ebc4, 0xf944d16b),  # r2 cave 0x2830d4: ldr x11, [x11, #0x9a0]
    (0xa0ebc8, 0xb940d96b),  # r2 cave 0x2830d4: ldr w11, [x11, #0xd8]
    (0xa0ebcc, 0x6b0b010b),  # r2 cave 0x2830d4: subs w11, w8, w11
    (0xa0ebd0, 0x1a9f816b),  # r2 cave 0x2830d4: csel w11, w11, wzr, hi
    (0xa0ebd4, 0x7100011f),  # r2 cave 0x2830d4: cmp w8, #0
    (0xa0ebd8, 0x1a88c168),  # r2 cave 0x2830d4: csel w8, w11, w8, gt
    (0xa0ebdc, 0x17e1d13f),  # r2 cave 0x2830d4: b #0x2830d8
    (0xa0ebe0, 0xd0001d4b),  # r2 cave 0x2830e4: adrp x11, #0xdb8000
    (0xa0ebe4, 0xf944d16b),  # r2 cave 0x2830e4: ldr x11, [x11, #0x9a0]
    (0xa0ebe8, 0xb940d96b),  # r2 cave 0x2830e4: ldr w11, [x11, #0xd8]
    (0xa0ebec, 0x6b0b010b),  # r2 cave 0x2830e4: subs w11, w8, w11
    (0xa0ebf0, 0x1a9f816b),  # r2 cave 0x2830e4: csel w11, w11, wzr, hi
    (0xa0ebf4, 0x7100011f),  # r2 cave 0x2830e4: cmp w8, #0
    (0xa0ebf8, 0x1a88c168),  # r2 cave 0x2830e4: csel w8, w11, w8, gt
    (0xa0ebfc, 0x17e1d13b),  # r2 cave 0x2830e4: b #0x2830e8
    (0xa0ec00, 0xd0001d4b),  # r2 cave 0x2830f4: adrp x11, #0xdb8000
    (0xa0ec04, 0xf944d16b),  # r2 cave 0x2830f4: ldr x11, [x11, #0x9a0]
    (0xa0ec08, 0xb940d96b),  # r2 cave 0x2830f4: ldr w11, [x11, #0xd8]
    (0xa0ec0c, 0x6b0b010b),  # r2 cave 0x2830f4: subs w11, w8, w11
    (0xa0ec10, 0x1a9f816b),  # r2 cave 0x2830f4: csel w11, w11, wzr, hi
    (0xa0ec14, 0x7100011f),  # r2 cave 0x2830f4: cmp w8, #0
    (0xa0ec18, 0x1a88c168),  # r2 cave 0x2830f4: csel w8, w11, w8, gt
    (0xa0ec1c, 0x17e1d137),  # r2 cave 0x2830f4: b #0x2830f8
    (0xa0ec20, 0xd0001d4b),  # r2 cave 0x283138: adrp x11, #0xdb8000
    (0xa0ec24, 0xf944d16b),  # r2 cave 0x283138: ldr x11, [x11, #0x9a0]
    (0xa0ec28, 0xb940d96b),  # r2 cave 0x283138: ldr w11, [x11, #0xd8]
    (0xa0ec2c, 0x6b0b010b),  # r2 cave 0x283138: subs w11, w8, w11
    (0xa0ec30, 0x1a9f816b),  # r2 cave 0x283138: csel w11, w11, wzr, hi
    (0xa0ec34, 0x7100011f),  # r2 cave 0x283138: cmp w8, #0
    (0xa0ec38, 0x1a88c168),  # r2 cave 0x283138: csel w8, w11, w8, gt
    (0xa0ec3c, 0x17e1d140),  # r2 cave 0x283138: b #0x28313c
    (0xa0ec40, 0xd0001d4b),  # r2 cave 0x283148: adrp x11, #0xdb8000
    (0xa0ec44, 0xf944d16b),  # r2 cave 0x283148: ldr x11, [x11, #0x9a0]
    (0xa0ec48, 0xb940d96b),  # r2 cave 0x283148: ldr w11, [x11, #0xd8]
    (0xa0ec4c, 0x6b0b010b),  # r2 cave 0x283148: subs w11, w8, w11
    (0xa0ec50, 0x1a9f816b),  # r2 cave 0x283148: csel w11, w11, wzr, hi
    (0xa0ec54, 0x7100011f),  # r2 cave 0x283148: cmp w8, #0
    (0xa0ec58, 0x1a88c168),  # r2 cave 0x283148: csel w8, w11, w8, gt
    (0xa0ec5c, 0x17e1d13c),  # r2 cave 0x283148: b #0x28314c
    (0xa0ec60, 0xd0001d4b),  # r2 cave 0x283158: adrp x11, #0xdb8000
    (0xa0ec64, 0xf944d16b),  # r2 cave 0x283158: ldr x11, [x11, #0x9a0]
    (0xa0ec68, 0xb940d96b),  # r2 cave 0x283158: ldr w11, [x11, #0xd8]
    (0xa0ec6c, 0x6b0b010b),  # r2 cave 0x283158: subs w11, w8, w11
    (0xa0ec70, 0x1a9f816b),  # r2 cave 0x283158: csel w11, w11, wzr, hi
    (0xa0ec74, 0x7100011f),  # r2 cave 0x283158: cmp w8, #0
    (0xa0ec78, 0x1a88c168),  # r2 cave 0x283158: csel w8, w11, w8, gt
    (0xa0ec7c, 0x17e1d138),  # r2 cave 0x283158: b #0x28315c
    (0xa0ec80, 0xd0001d4b),  # r2 cave 0x283168: adrp x11, #0xdb8000
    (0xa0ec84, 0xf944d16b),  # r2 cave 0x283168: ldr x11, [x11, #0x9a0]
    (0xa0ec88, 0xb940d96b),  # r2 cave 0x283168: ldr w11, [x11, #0xd8]
    (0xa0ec8c, 0x6b0b010b),  # r2 cave 0x283168: subs w11, w8, w11
    (0xa0ec90, 0x1a9f816b),  # r2 cave 0x283168: csel w11, w11, wzr, hi
    (0xa0ec94, 0x7100011f),  # r2 cave 0x283168: cmp w8, #0
    (0xa0ec98, 0x1a88c168),  # r2 cave 0x283168: csel w8, w11, w8, gt
    (0xa0ec9c, 0x17e1d134),  # r2 cave 0x283168: b #0x28316c
    (0xa0eca0, 0xd0001d4b),  # r2 cave 0x283178: adrp x11, #0xdb8000
    (0xa0eca4, 0xf944d16b),  # r2 cave 0x283178: ldr x11, [x11, #0x9a0]
    (0xa0eca8, 0xb940d96b),  # r2 cave 0x283178: ldr w11, [x11, #0xd8]
    (0xa0ecac, 0x6b0b010b),  # r2 cave 0x283178: subs w11, w8, w11
    (0xa0ecb0, 0x1a9f816b),  # r2 cave 0x283178: csel w11, w11, wzr, hi
    (0xa0ecb4, 0x7100011f),  # r2 cave 0x283178: cmp w8, #0
    (0xa0ecb8, 0x1a88c168),  # r2 cave 0x283178: csel w8, w11, w8, gt
    (0xa0ecbc, 0x17e1d130),  # r2 cave 0x283178: b #0x28317c
    (0xa0ecc0, 0xd0001d4b),  # r2 cave 0x283188: adrp x11, #0xdb8000
    (0xa0ecc4, 0xf944d16b),  # r2 cave 0x283188: ldr x11, [x11, #0x9a0]
    (0xa0ecc8, 0xb940d96b),  # r2 cave 0x283188: ldr w11, [x11, #0xd8]
    (0xa0eccc, 0x6b0b010b),  # r2 cave 0x283188: subs w11, w8, w11
    (0xa0ecd0, 0x1a9f816b),  # r2 cave 0x283188: csel w11, w11, wzr, hi
    (0xa0ecd4, 0x7100011f),  # r2 cave 0x283188: cmp w8, #0
    (0xa0ecd8, 0x1a88c168),  # r2 cave 0x283188: csel w8, w11, w8, gt
    (0xa0ecdc, 0x17e1d12c),  # r2 cave 0x283188: b #0x28318c
    (0xa0ece0, 0xd0001d4b),  # r2 cave 0x283198: adrp x11, #0xdb8000
    (0xa0ece4, 0xf944d16b),  # r2 cave 0x283198: ldr x11, [x11, #0x9a0]
    (0xa0ece8, 0xb940d96b),  # r2 cave 0x283198: ldr w11, [x11, #0xd8]
    (0xa0ecec, 0x6b0b010b),  # r2 cave 0x283198: subs w11, w8, w11
    (0xa0ecf0, 0x1a9f816b),  # r2 cave 0x283198: csel w11, w11, wzr, hi
    (0xa0ecf4, 0x7100011f),  # r2 cave 0x283198: cmp w8, #0
    (0xa0ecf8, 0x1a88c168),  # r2 cave 0x283198: csel w8, w11, w8, gt
    (0xa0ecfc, 0x17e1d128),  # r2 cave 0x283198: b #0x28319c
    (0xa0ed00, 0xd0001d4b),  # r2 cave 0x2831a8: adrp x11, #0xdb8000
    (0xa0ed04, 0xf944d16b),  # r2 cave 0x2831a8: ldr x11, [x11, #0x9a0]
    (0xa0ed08, 0xb940d96b),  # r2 cave 0x2831a8: ldr w11, [x11, #0xd8]
    (0xa0ed0c, 0x6b0b010b),  # r2 cave 0x2831a8: subs w11, w8, w11
    (0xa0ed10, 0x1a9f816b),  # r2 cave 0x2831a8: csel w11, w11, wzr, hi
    (0xa0ed14, 0x7100011f),  # r2 cave 0x2831a8: cmp w8, #0
    (0xa0ed18, 0x1a88c168),  # r2 cave 0x2831a8: csel w8, w11, w8, gt
    (0xa0ed1c, 0x17e1d124),  # r2 cave 0x2831a8: b #0x2831ac
    (0xa0ed20, 0xd0001d4b),  # r2 cave 0x2831b8: adrp x11, #0xdb8000
    (0xa0ed24, 0xf944d16b),  # r2 cave 0x2831b8: ldr x11, [x11, #0x9a0]
    (0xa0ed28, 0xb940d96b),  # r2 cave 0x2831b8: ldr w11, [x11, #0xd8]
    (0xa0ed2c, 0x6b0b010b),  # r2 cave 0x2831b8: subs w11, w8, w11
    (0xa0ed30, 0x1a9f816b),  # r2 cave 0x2831b8: csel w11, w11, wzr, hi
    (0xa0ed34, 0x7100011f),  # r2 cave 0x2831b8: cmp w8, #0
    (0xa0ed38, 0x1a88c168),  # r2 cave 0x2831b8: csel w8, w11, w8, gt
    (0xa0ed3c, 0x17e1d120),  # r2 cave 0x2831b8: b #0x2831bc
    (0xa0ed40, 0xd0001d4b),  # r2 cave 0x2831c8: adrp x11, #0xdb8000
    (0xa0ed44, 0xf944d16b),  # r2 cave 0x2831c8: ldr x11, [x11, #0x9a0]
    (0xa0ed48, 0xb940d96b),  # r2 cave 0x2831c8: ldr w11, [x11, #0xd8]
    (0xa0ed4c, 0x6b0b010b),  # r2 cave 0x2831c8: subs w11, w8, w11
    (0xa0ed50, 0x1a9f816b),  # r2 cave 0x2831c8: csel w11, w11, wzr, hi
    (0xa0ed54, 0x7100011f),  # r2 cave 0x2831c8: cmp w8, #0
    (0xa0ed58, 0x1a88c168),  # r2 cave 0x2831c8: csel w8, w11, w8, gt
    (0xa0ed5c, 0x17e1d11c),  # r2 cave 0x2831c8: b #0x2831cc
    (0xa0ed60, 0xd0001d4b),  # r2 cave 0x2831dc: adrp x11, #0xdb8000
    (0xa0ed64, 0xf944d16b),  # r2 cave 0x2831dc: ldr x11, [x11, #0x9a0]
    (0xa0ed68, 0xb940d96b),  # r2 cave 0x2831dc: ldr w11, [x11, #0xd8]
    (0xa0ed6c, 0x6b0b010b),  # r2 cave 0x2831dc: subs w11, w8, w11
    (0xa0ed70, 0x1a9f816b),  # r2 cave 0x2831dc: csel w11, w11, wzr, hi
    (0xa0ed74, 0x7100011f),  # r2 cave 0x2831dc: cmp w8, #0
    (0xa0ed78, 0x1a88c168),  # r2 cave 0x2831dc: csel w8, w11, w8, gt
    (0xa0ed7c, 0x17e1d119),  # r2 cave 0x2831dc: b #0x2831e0
    (0xa0ed80, 0xf81f0fe9),  # r3 hs_w8: str x9, [sp, #-0x10]!
    (0xa0ed84, 0xd0001d49),  # r3 hs_w8: adrp x9, #0xdb8000
    (0xa0ed88, 0xf944d129),  # r3 hs_w8: ldr x9, [x9, #0x9a0]
    (0xa0ed8c, 0xb940d929),  # r3 hs_w8: ldr w9, [x9, #0xd8]
    (0xa0ed90, 0x340000e9),  # r3 hs_w8: cbz w9, #0xa0edac
    (0xa0ed94, 0x7100051f),  # r3 hs_w8: cmp w8, #1
    (0xa0ed98, 0x7a49a100),  # r3 hs_w8: ccmp w8, w9, #0, ge
    (0xa0ed9c, 0x1a89b109),  # r3 hs_w8: csel w9, w8, w9, lt
    (0xa0eda0, 0x6b090108),  # r3 hs_w8: subs w8, w8, w9
    (0xa0eda4, 0xf84107e9),  # r3 hs_w8: ldr x9, [sp], #0x10
    (0xa0eda8, 0xd65f03c0),  # r3 hs_w8: ret 
    (0xa0edac, 0x7100011f),  # r3 hs_w8: cmp w8, #0
    (0xa0edb0, 0x7a40c908),  # r3 hs_w8: ccmp w8, #0, #8, gt
    (0xa0edb4, 0xf84107e9),  # r3 hs_w8: ldr x9, [sp], #0x10
    (0xa0edb8, 0xd65f03c0),  # r3 hs_w8: ret 
    (0xa0edbc, 0xf81f0fea),  # r3 hs_w9: str x10, [sp, #-0x10]!
    (0xa0edc0, 0xd0001d4a),  # r3 hs_w9: adrp x10, #0xdb8000
    (0xa0edc4, 0xf944d14a),  # r3 hs_w9: ldr x10, [x10, #0x9a0]
    (0xa0edc8, 0xb940d94a),  # r3 hs_w9: ldr w10, [x10, #0xd8]
    (0xa0edcc, 0x340000ea),  # r3 hs_w9: cbz w10, #0xa0ede8
    (0xa0edd0, 0x7100053f),  # r3 hs_w9: cmp w9, #1
    (0xa0edd4, 0x7a4aa120),  # r3 hs_w9: ccmp w9, w10, #0, ge
    (0xa0edd8, 0x1a8ab12a),  # r3 hs_w9: csel w10, w9, w10, lt
    (0xa0eddc, 0x6b0a0129),  # r3 hs_w9: subs w9, w9, w10
    (0xa0ede0, 0xf84107ea),  # r3 hs_w9: ldr x10, [sp], #0x10
    (0xa0ede4, 0xd65f03c0),  # r3 hs_w9: ret 
    (0xa0ede8, 0x7100013f),  # r3 hs_w9: cmp w9, #0
    (0xa0edec, 0x7a40c928),  # r3 hs_w9: ccmp w9, #0, #8, gt
    (0xa0edf0, 0xf84107ea),  # r3 hs_w9: ldr x10, [sp], #0x10
    (0xa0edf4, 0xd65f03c0),  # r3 hs_w9: ret 
    (0xa0edf8, 0xd0001d4c),  # r3 rh_w8: adrp x12, #0xdb8000
    (0xa0edfc, 0xf944d18c),  # r3 rh_w8: ldr x12, [x12, #0x9a0]
    (0xa0ee00, 0xb940d98c),  # r3 rh_w8: ldr w12, [x12, #0xd8]
    (0xa0ee04, 0x7100051f),  # r3 rh_w8: cmp w8, #1
    (0xa0ee08, 0x1a9f158c),  # r3 rh_w8: csinc w12, w12, wzr, ne
    (0xa0ee0c, 0x340000cc),  # r3 rh_w8: cbz w12, #0xa0ee24
    (0xa0ee10, 0x7100051f),  # r3 rh_w8: cmp w8, #1
    (0xa0ee14, 0x7a4ca100),  # r3 rh_w8: ccmp w8, w12, #0, ge
    (0xa0ee18, 0x1a8cb10c),  # r3 rh_w8: csel w12, w8, w12, lt
    (0xa0ee1c, 0x6b0c0109),  # r3 rh_w8: subs w9, w8, w12
    (0xa0ee20, 0xd61f0160),  # r3 rh_w8: br x11
    (0xa0ee24, 0x2a0803e9),  # r3 rh_w8: mov w9, w8
    (0xa0ee28, 0x7100011f),  # r3 rh_w8: cmp w8, #0
    (0xa0ee2c, 0x7a40c908),  # r3 rh_w8: ccmp w8, #0, #8, gt
    (0xa0ee30, 0xd61f0160),  # r3 rh_w8: br x11
    (0xa0ee34, 0xd0001d4c),  # r3 rh_w9: adrp x12, #0xdb8000
    (0xa0ee38, 0xf944d18c),  # r3 rh_w9: ldr x12, [x12, #0x9a0]
    (0xa0ee3c, 0xb940d98c),  # r3 rh_w9: ldr w12, [x12, #0xd8]
    (0xa0ee40, 0x7100053f),  # r3 rh_w9: cmp w9, #1
    (0xa0ee44, 0x1a9f158c),  # r3 rh_w9: csinc w12, w12, wzr, ne
    (0xa0ee48, 0x340000cc),  # r3 rh_w9: cbz w12, #0xa0ee60
    (0xa0ee4c, 0x7100053f),  # r3 rh_w9: cmp w9, #1
    (0xa0ee50, 0x7a4ca120),  # r3 rh_w9: ccmp w9, w12, #0, ge
    (0xa0ee54, 0x1a8cb12c),  # r3 rh_w9: csel w12, w9, w12, lt
    (0xa0ee58, 0x6b0c012a),  # r3 rh_w9: subs w10, w9, w12
    (0xa0ee5c, 0xd61f0160),  # r3 rh_w9: br x11
    (0xa0ee60, 0x2a0903ea),  # r3 rh_w9: mov w10, w9
    (0xa0ee64, 0x7100013f),  # r3 rh_w9: cmp w9, #0
    (0xa0ee68, 0x7a40c928),  # r3 rh_w9: ccmp w9, #0, #8, gt
    (0xa0ee6c, 0xd61f0160),  # r3 rh_w9: br x11
    (0xa0ee70, 0xd0001d4a),  # r3 cave_4f4010: adrp x10, #0xdb8000
    (0xa0ee74, 0xf944d14a),  # r3 cave_4f4010: ldr x10, [x10, #0x9a0]
    (0xa0ee78, 0xb940d94a),  # r3 cave_4f4010: ldr w10, [x10, #0xd8]
    (0xa0ee7c, 0x4b0a0129),  # r3 cave_4f4010: sub w9, w9, w10
    (0xa0ee80, 0x7100053f),  # r3 cave_4f4010: cmp w9, #1
    (0xa0ee84, 0x1a9fa529),  # r3 cave_4f4010: csinc w9, w9, wzr, ge
    (0xa0ee88, 0x17eb9463),  # r3 cave_4f4010: b #0x4f4014
    (0xa0ee8c, 0xd0001d49),  # r3 cave_4f4018: adrp x9, #0xdb8000
    (0xa0ee90, 0xf944d129),  # r3 cave_4f4018: ldr x9, [x9, #0x9a0]
    (0xa0ee94, 0xb940d929),  # r3 cave_4f4018: ldr w9, [x9, #0xd8]
    (0xa0ee98, 0x0b090108),  # r3 cave_4f4018: add w8, w8, w9
    (0xa0ee9c, 0x17eb9460),  # r3 cave_4f4018: b #0x4f401c
    (0xa0eea0, 0xd0001d4b),  # r3 cave_283a94: adrp x11, #0xdb8000
    (0xa0eea4, 0xf944d16b),  # r3 cave_283a94: ldr x11, [x11, #0x9a0]
    (0xa0eea8, 0xb940d96b),  # r3 cave_283a94: ldr w11, [x11, #0xd8]
    (0xa0eeac, 0x340000cb),  # r3 cave_283a94: cbz w11, #0xa0eec4
    (0xa0eeb0, 0x7100055f),  # r3 cave_283a94: cmp w10, #1
    (0xa0eeb4, 0x7a4ba140),  # r3 cave_283a94: ccmp w10, w11, #0, ge
    (0xa0eeb8, 0x1a8bb14b),  # r3 cave_283a94: csel w11, w10, w11, lt
    (0xa0eebc, 0x6b0b014a),  # r3 cave_283a94: subs w10, w10, w11
    (0xa0eec0, 0x17e1d2f6),  # r3 cave_283a94: b #0x283a98
    (0xa0eec4, 0x7100015f),  # r3 cave_283a94: cmp w10, #0
    (0xa0eec8, 0x7a40c948),  # r3 cave_283a94: ccmp w10, #0, #8, gt
    (0xa0eecc, 0x17e1d2f3),  # r3 cave_283a94: b #0x283a98
    (0xa0eed0, 0xd0001d4a),  # r3 cave_2846f0: adrp x10, #0xdb8000
    (0xa0eed4, 0xf944d14a),  # r3 cave_2846f0: ldr x10, [x10, #0x9a0]
    (0xa0eed8, 0xb940d94a),  # r3 cave_2846f0: ldr w10, [x10, #0xd8]
    (0xa0eedc, 0x0b0a012a),  # r3 cave_2846f0: add w10, w9, w10
    (0xa0eee0, 0x17e1d605),  # r3 cave_2846f0: b #0x2846f4
    (0xa0eee4, 0xd0001d4a),  # r3 cave_286c2c: adrp x10, #0xdb8000
    (0xa0eee8, 0xf944d14a),  # r3 cave_286c2c: ldr x10, [x10, #0x9a0]
    (0xa0eeec, 0xb940d94a),  # r3 cave_286c2c: ldr w10, [x10, #0xd8]
    (0xa0eef0, 0x7100013f),  # r3 cave_286c2c: cmp w9, #0
    (0xa0eef4, 0x7a400940),  # r3 cave_286c2c: ccmp w10, #0, #0, eq
    (0xa0eef8, 0x1a9f154a),  # r3 cave_286c2c: csinc w10, w10, wzr, ne
    (0xa0eefc, 0x0b0a0129),  # r3 cave_286c2c: add w9, w9, w10
    (0xa0ef00, 0x17e1df4c),  # r3 cave_286c2c: b #0x286c30
    (0xa0ef04, 0xd0001d51),  # r3 cave_91de50: adrp x17, #0xdb8000
    (0xa0ef08, 0xf944d231),  # r3 cave_91de50: ldr x17, [x17, #0x9a0]
    (0xa0ef0c, 0xb940da31),  # r3 cave_91de50: ldr w17, [x17, #0xd8]
    (0xa0ef10, 0x340000d1),  # r3 cave_91de50: cbz w17, #0xa0ef28
    (0xa0ef14, 0x7100061f),  # r3 cave_91de50: cmp w16, #1
    (0xa0ef18, 0x7a51a200),  # r3 cave_91de50: ccmp w16, w17, #0, ge
    (0xa0ef1c, 0x1a91b211),  # r3 cave_91de50: csel w17, w16, w17, lt
    (0xa0ef20, 0x6b110210),  # r3 cave_91de50: subs w16, w16, w17
    (0xa0ef24, 0x17fc3bcc),  # r3 cave_91de50: b #0x91de54
    (0xa0ef28, 0x7100021f),  # r3 cave_91de50: cmp w16, #0
    (0xa0ef2c, 0x7a40ca08),  # r3 cave_91de50: ccmp w16, #0, #8, gt
    (0xa0ef30, 0x17fc3bc9),  # r3 cave_91de50: b #0x91de54
    (0xa0ef34, 0xd0001d51),  # r3 cave_91dee8: adrp x17, #0xdb8000
    (0xa0ef38, 0xf944d231),  # r3 cave_91dee8: ldr x17, [x17, #0x9a0]
    (0xa0ef3c, 0xb940da31),  # r3 cave_91dee8: ldr w17, [x17, #0xd8]
    (0xa0ef40, 0x6b110210),  # r3 cave_91dee8: subs w16, w16, w17
    (0xa0ef44, 0x17fc3bea),  # r3 cave_91dee8: b #0x91deec
    (0xa0ef48, 0xd0001d4b),  # r3 cave_9abf40: adrp x11, #0xdb8000
    (0xa0ef4c, 0xf944d16b),  # r3 cave_9abf40: ldr x11, [x11, #0x9a0]
    (0xa0ef50, 0xb940d96b),  # r3 cave_9abf40: ldr w11, [x11, #0xd8]
    (0xa0ef54, 0x0b0b0129),  # r3 cave_9abf40: add w9, w9, w11
    (0xa0ef58, 0x17fe73fb),  # r3 cave_9abf40: b #0x9abf44
    (0xa0ef5c, 0x10ce688b),  # r3 stub_9abc68: adr x11, #0x9abc6c
    (0xa0ef60, 0x17ffffa6),  # r3 stub_9abc68: b #0xa0edf8
    (0xa0ef64, 0x10ce68eb),  # r3 stub_9abc7c: adr x11, #0x9abc80
    (0xa0ef68, 0x17ffffb3),  # r3 stub_9abc7c: b #0xa0ee34
    (0xa0ef6c, 0x10ce6acb),  # r3 stub_9abcc0: adr x11, #0x9abcc4
    (0xa0ef70, 0x17ffffb1),  # r3 stub_9abcc0: b #0xa0ee34
    (0xa0ef74, 0x10ce6e2b),  # r3 stub_9abd34: adr x11, #0x9abd38
    (0xa0ef78, 0x17ffffaf),  # r3 stub_9abd34: b #0xa0ee34
    (0xa0ef7c, 0x10ce6b2b),  # r3 stub_9abcdc: adr x11, #0x9abce0
    (0xa0ef80, 0x17ffffad),  # r3 stub_9abcdc: b #0xa0ee34
    (0xa0ef84, 0x10ce6e8b),  # r3 stub_9abd50: adr x11, #0x9abd54
    (0xa0ef88, 0x17ffffab),  # r3 stub_9abd50: b #0xa0ee34
    (0xa0ef8c, 0x10ce724b),  # r3 stub_9abdd0: adr x11, #0x9abdd4
    (0xa0ef90, 0x17ffffa9),  # r3 stub_9abdd0: b #0xa0ee34
    (0xa0ef94, 0x10ce6eeb),  # r3 stub_9abd6c: adr x11, #0x9abd70
    (0xa0ef98, 0x17ffffa7),  # r3 stub_9abd6c: b #0xa0ee34
    (0xa0ef9c, 0x10ce72ab),  # r3 stub_9abdec: adr x11, #0x9abdf0
    (0xa0efa0, 0x17ffffa5),  # r3 stub_9abdec: b #0xa0ee34
    (0xa0efa4, 0x10ce776b),  # r3 stub_9abe8c: adr x11, #0x9abe90
    (0xa0efa8, 0x17ffffa3),  # r3 stub_9abe8c: b #0xa0ee34
    (0xa0efac, 0xbd4e1d00),  # r4 cave_4f406c: ldr s0, [x8, #0xe1c]
    (0xa0efb0, 0xd0001d48),  # r4 cave_4f406c: adrp x8, #0xdb8000
    (0xa0efb4, 0xf944d108),  # r4 cave_4f406c: ldr x8, [x8, #0x9a0]
    (0xa0efb8, 0xb940d908),  # r4 cave_4f406c: ldr w8, [x8, #0xd8]
    (0xa0efbc, 0x1e220101),  # r4 cave_4f406c: scvtf s1, w8
    (0xa0efc0, 0x1e210801),  # r4 cave_4f406c: fmul s1, s0, s1
    (0xa0efc4, 0xbd407e60),  # r4 cave_4f406c: ldr s0, [x19, #0x7c]
    (0xa0efc8, 0x17eb942b),  # r4 cave_4f406c: b #0x4f4074
    (0xa0efcc, 0x2a0a03e9),  # r5 stub_w10w9: mov w9, w10
    (0xa0efd0, 0x17ffff7b),  # r5 stub_w10w9: b #0xa0edbc
]

# Site, expected original bytes, upstream instruction to relocate, purpose.
sites = [
    (0xd5dd4, '08050071', 0x9424e3eb, '[hs] +0x2024 sibling path: bl hs_w8 0xa0ed80 (was subs w8, w8, #1)'),
    (0xd5e28, '08050071', 0x1424e2b2, 'S3 +0x2024 exact-zero (D1 handler 0xD3380) +0x2024: b 0xa0e8f0 (was subs w8,w8,#1)'),
    (0xe7f64, '08050071', 0x14249a4b, '15-count (v1 site 3) +0x2020: b 0xa0e890 (was subs w8,w8,#1)'),
    (0xf7ce8, '08050071', 0x14245af6, 'chain bind (v1 site 4) +0x2024: b 0xa0e8c0 (was subs w8,w8,#1)'),
    (0xf8720, '08050071', 0x14245850, 'S3 15-count in site-4 routine +0x2020: b 0xa0e860 (was subs w8,w8,#1)'),
    (0x2828ac, '08050071', 0x141e301d, '+0xF64 short latch +0xf64: b 0xa0e920 (was subs w8,w8,#1)'),
    (0x283044, '08050051', 0x141e2e97, 'bank +0x1364 buffer +0x1364: b 0xa0eaa0 (was sub w8,w8,#1)'),
    (0x283054, '08050051', 0x141e2e9b, 'bank +0x1368 buffer +0x1368: b 0xa0eac0 (was sub w8,w8,#1)'),
    (0x283064, '08050051', 0x141e2e9f, 'bank +0x136c buffer +0x136c: b 0xa0eae0 (was sub w8,w8,#1)'),
    (0x283074, '08050051', 0x141e2ea3, 'bank +0x138c buffer +0x138c: b 0xa0eb00 (was sub w8,w8,#1)'),
    (0x283084, '08050051', 0x141e2ea7, 'bank +0x1378 buffer +0x1378: b 0xa0eb20 (was sub w8,w8,#1)'),
    (0x283094, '08050051', 0x141e2eab, 'bank +0x137c buffer +0x137c: b 0xa0eb40 (was sub w8,w8,#1)'),
    (0x2830a4, '08050051', 0x141e2eaf, 'bank +0x1390 buffer +0x1390: b 0xa0eb60 (was sub w8,w8,#1)'),
    (0x2830b4, '08050051', 0x141e2eb3, 'bank +0x1370 buffer +0x1370: b 0xa0eb80 (was sub w8,w8,#1)'),
    (0x2830c4, '08050051', 0x141e2eb7, 'bank +0x1374 buffer +0x1374: b 0xa0eba0 (was sub w8,w8,#1)'),
    (0x2830d4, '08050051', 0x141e2ebb, 'bank +0x13a4 buffer +0x13a4: b 0xa0ebc0 (was sub w8,w8,#1)'),
    (0x2830e4, '08050051', 0x141e2ebf, 'bank +0x13a8 buffer +0x13a8: b 0xa0ebe0 (was sub w8,w8,#1)'),
    (0x2830f4, '08050051', 0x141e2ec3, 'bank +0x13cc buffer +0x13cc: b 0xa0ec00 (was sub w8,w8,#1)'),
    (0x283100, '08050071', 0x141e2e14, '+0x14B8 buffer +0x14b8: b 0xa0e950 (was subs w8,w8,#1)'),
    (0x28311c, '08050071', 0x141e2e19, '+0x46AEF0 tap buffer +0x46aef0: b 0xa0e980 (was subs w8,w8,#1)'),
    (0x283138, '08050051', 0x141e2eba, 'bank +0x1470 buffer +0x1470: b 0xa0ec20 (was sub w8,w8,#1)'),
    (0x283148, '08050051', 0x141e2ebe, 'bank +0x1474 buffer +0x1474: b 0xa0ec40 (was sub w8,w8,#1)'),
    (0x283158, '08050051', 0x141e2ec2, 'bank +0x1478 buffer +0x1478: b 0xa0ec60 (was sub w8,w8,#1)'),
    (0x283168, '08050051', 0x141e2ec6, 'bank +0x147c buffer +0x147c: b 0xa0ec80 (was sub w8,w8,#1)'),
    (0x283178, '08050051', 0x141e2eca, 'bank +0x1480 buffer +0x1480: b 0xa0eca0 (was sub w8,w8,#1)'),
    (0x283188, '08050051', 0x141e2ece, 'bank +0x1484 buffer +0x1484: b 0xa0ecc0 (was sub w8,w8,#1)'),
    (0x283198, '08050051', 0x141e2ed2, 'bank +0x1488 buffer +0x1488: b 0xa0ece0 (was sub w8,w8,#1)'),
    (0x2831a8, '08050051', 0x141e2ed6, 'bank +0x148c buffer +0x148c: b 0xa0ed00 (was sub w8,w8,#1)'),
    (0x2831b8, '08050051', 0x141e2eda, 'bank +0x1490 buffer +0x1490: b 0xa0ed20 (was sub w8,w8,#1)'),
    (0x2831c8, '08050051', 0x141e2ede, 'bank +0x1450 buffer +0x1450: b 0xa0ed40 (was sub w8,w8,#1)'),
    (0x2831dc, '08050051', 0x141e2ee1, 'bank +0x1454 buffer +0x1454: b 0xa0ed60 (was sub w8,w8,#1)'),
    (0x283294, '29050071', 0x941e2eca, '[hs] +0x46AE28 window: bl hs_w9 0xa0edbc (was subs w9, w9, #1)'),
    (0x283360, '08050071', 0x941e2e88, '[hs] +0x46ADAC exact-zero: bl hs_w8 0xa0ed80 (was subs w8, w8, #1)'),
    (0x283a94, '4a050071', 0x141e2d03, '[isubs] +0x46B4C4 lockout: b cave 0xa0eea0 (was subs w10, w10, #1)'),
    (0x2846f0, '2a050011', 0x141e29f8, '[up] +0x46B62C up-counter: b cave 0xa0eed0 (was add w10, w9, #1)'),
    (0x284ad4, '08050071', 0x941e28ab, '[hs] +0x14E0 window: bl hs_w8 0xa0ed80 (was subs w8, w8, #1)'),
    (0x284af0, '08050071', 0x941e28a4, '[hs] +0x46AEF8 window: bl hs_w8 0xa0ed80 (was subs w8, w8, #1)'),
    (0x284b00, '08050071', 0x941e28a0, '[hs] +0xDA4 window (set 15 at 0x325300; next to r3 0x284AD4/0x284AF0): bl hs_w8 0xa0ed80 (was subs w8, w8, #1)'),
    (0x284bb8, '08050071', 0x941e2872, '[hs] +0x46AF00 window: bl hs_w8 0xa0ed80 (was subs w8, w8, #1)'),
    (0x284bf4, '08050071', 0x941e2863, '[hs] +0x46AF04 window: bl hs_w8 0xa0ed80 (was subs w8, w8, #1)'),
    (0x285464, '08050071', 0x941e2647, '[hs] +0x46AE10 queue window: bl hs_w8 0xa0ed80 (was subs w8, w8, #1)'),
    (0x2856f8, '29050071', 0x941e25b1, '[hs] +0x46AE14 re-injected press window: bl hs_w9 0xa0edbc (was subs w9, w9, #1)'),
    (0x286c2c, '29050011', 0x141e20ae, '[upmin1] +0xC50 tap/hold count-up: b cave 0xa0eee4 (was add w9, w9, #1)'),
    (0x286e38, '08050071', 0x941e1fd2, '[hs] +0x14E0 window: bl hs_w8 0xa0ed80 (was subs w8, w8, #1)'),
    (0x286f98, '08050071', 0x941e1f7a, '[hs] +0x14E0 window: bl hs_w8 0xa0ed80 (was subs w8, w8, #1)'),
    (0x287044, '08050071', 0x941e1f4f, '[hs] +0x14E0 window: bl hs_w8 0xa0ed80 (was subs w8, w8, #1)'),
    (0x28759c, '08050071', 0x141e1d05, '+0x14D4 buffer +0x14d4: b 0xa0e9b0 (was subs w8,w8,#1)'),
    (0x2875ac, '08050071', 0x141e1d0d, '+0x14D8 buffer +0x14d8: b 0xa0e9e0 (was subs w8,w8,#1)'),
    (0x2875bc, '08050071', 0x141e1d15, '+0x1414 buffer +0x1414: b 0xa0ea10 (was subs w8,w8,#1)'),
    (0x2875cc, '08050071', 0x141e1d1d, '+0x149C buffer +0x149c: b 0xa0ea40 (was subs w8,w8,#1)'),
    (0x2875dc, '08050071', 0x141e1d25, '+0x14DC buffer +0x14dc: b 0xa0ea70 (was subs w8,w8,#1)'),
    (0x287694, '49050071', 0x941e1e4e, '[hs] +0x13A0 second-tap window, path A (b.ge -> 0x28772C mov w10,w9; str): bl stub_w10w9 0xa0efcc (was subs w9, w10, #1)'),
    (0x2876d4, '08050071', 0x941e1dab, '[hs] +0x14D4 r2-sibling path (shares store 0x2875A4 with r2 0x28759C): bl hs_w8 0xa0ed80 (was subs w8, w8, #1)'),
    (0x287724, '49050071', 0x941e1e2a, '[hs] +0x13A0 second-tap window, path B (b.lt -> 0x287734): bl stub_w10w9 0xa0efcc (was subs w9, w10, #1)'),
    (0x287738, '29050071', 0x941e1da1, '[hs] +0x139C window (set 15 with bank +0x137C at 0x287764/0x287790): bl hs_w9 0xa0edbc (was subs w9, w9, #1)'),
    (0x28783c, '29050071', 0x941e1d60, '[hs] +0x13B0 window (set 15 at 0x287830 next to bank +0x13A8 = 15): bl hs_w9 0xa0edbc (was subs w9, w9, #1)'),
    (0x288f40, '29050071', 0x941e179f, '[hs] lockout bank +0x46a8b0: bl hs_w9 0xa0edbc (was subs w9, w9, #1)'),
    (0x288f5c, '29050071', 0x941e1798, '[hs] lockout bank +0x46a8c4: bl hs_w9 0xa0edbc (was subs w9, w9, #1)'),
    (0x288f78, '29050071', 0x941e1791, '[hs] lockout bank +0x46b3a8: bl hs_w9 0xa0edbc (was subs w9, w9, #1)'),
    (0x288f94, '29050071', 0x941e178a, '[hs] lockout bank +0x46b3ac: bl hs_w9 0xa0edbc (was subs w9, w9, #1)'),
    (0x288fb0, '29050071', 0x941e1783, '[hs] lockout bank +0x46b460: bl hs_w9 0xa0edbc (was subs w9, w9, #1)'),
    (0x288fcc, '29050071', 0x941e177c, '[hs] lockout bank +0x46b464: bl hs_w9 0xa0edbc (was subs w9, w9, #1)'),
    (0x288fe8, '29050071', 0x941e1775, '[hs] lockout bank +0x46b490: bl hs_w9 0xa0edbc (was subs w9, w9, #1)'),
    (0x289004, '29050071', 0x941e176e, '[hs] lockout bank +0x46b49c: bl hs_w9 0xa0edbc (was subs w9, w9, #1)'),
    (0x289020, '29050071', 0x941e1767, '[hs] lockout bank +0x46b638: bl hs_w9 0xa0edbc (was subs w9, w9, #1)'),
    (0x28903c, '29050071', 0x941e1760, '[hs] lockout bank +0x46b640: bl hs_w9 0xa0edbc (was subs w9, w9, #1)'),
    (0x289244, '29050071', 0x941e16de, '[hs] lockout bank +0x46b658: bl hs_w9 0xa0edbc (was subs w9, w9, #1)'),
    (0x289260, '29050071', 0x941e16d7, '[hs] lockout bank +0x46b664: bl hs_w9 0xa0edbc (was subs w9, w9, #1)'),
    (0x28927c, '29050071', 0x941e16d0, '[hs] lockout bank +0x46b66c: bl hs_w9 0xa0edbc (was subs w9, w9, #1)'),
    (0x289298, '29050071', 0x941e16c9, '[hs] lockout bank +0x46b39c: bl hs_w9 0xa0edbc (was subs w9, w9, #1)'),
    (0x308a9c, '08050071', 0x141c1765, 'combo cue (v1 site 1) +0x1290: b 0xa0e830 (was subs w8,w8,#1)'),
    (0x32cac8, '29050071', 0x941b88bd, '[hs] player deferred hitstop delay +0x7e88; exact-zero -> 0x91D6A0(w2=0): bl hs_w9 0xa0edbc (was subs w9, w9, #1)'),
    (0x32cdc0, '29050071', 0x941b87ff, '[hs] player deferred hitstop delay +0x7e94; exact-zero -> 0x91D6A0(w2=0): bl hs_w9 0xa0edbc (was subs w9, w9, #1)'),
    (0x32d0b8, '29050071', 0x941b8741, '[hs] player deferred hitstop delay +0x7e80; exact-zero -> 0x91D6A0(w2=0): bl hs_w9 0xa0edbc (was subs w9, w9, #1)'),
    (0x3a2d40, '08582a1e', 0x94074da9, 'was fmin s8,s0,s10 -> bl 0x5763E4'),
    (0x3a2d80, '28582a1e', 0x94074d9b, 'was fmin s8,s1,s10 -> bl 0x5763EC'),
    (0x3a2dc0, '48cd291e', 0x94074d8d, 'was fcsel s8,s10,s9,gt -> bl 0x5763F4'),
    (0x48be14, '0800381e', 0xb940d908, 'Replace FCVTZS: ldr w8,[x8,#0xD8]'),
    (0x4f3d30, '08050071', 0x94146c14, '[hs] +0x38 delay set by 0x4F27A0(w3); exact-zero -> 0x4F27A0(+0x3C,+0x40) issues the scale: bl hs_w8 0xa0ed80 (was subs w8, w8, #1)'),
    (0x4f3d5c, '08050071', 0x94146c09, '[hs] +0x34 duration of scale +0x30; exact-zero -> sound 0x8DD890 + 0x923B90(+0xE8); expiry -> +0x30=1.0: bl hs_w8 0xa0ed80 (was subs w8, w8, #1)'),
    (0x4f3d98, '08050071', 0x94146bfa, '[hs] +0x48 duration of scale +0x44; exact-zero -> +0x14=0; expiry -> +0x44=1.0: bl hs_w8 0xa0ed80 (was subs w8, w8, #1)'),
    (0x4f3db0, '08050071', 0x94146bf4, '[hs] +0x74 duration of scale +0x70; exact-zero -> +0x10=0, 0x923B90(+0x100); expiry -> +0x70=1.0: bl hs_w8 0xa0ed80 (was subs w8, w8, #1)'),
    (0x4f3e4c, '08050071', 0x94146bcd, '[hs] +0xA8 request suppression window: bl hs_w8 0xa0ed80 (was subs w8, w8, #1)'),
    (0x4f3e64, '08050071', 0x94146bc7, '[hs] +0x48 sibling path after +0x34 expiry: bl hs_w8 0xa0ed80 (was subs w8, w8, #1)'),
    (0x4f3e78, '08050071', 0x94146bc2, '[hs] +0x74 sibling path after +0x48 expiry: bl hs_w8 0xa0ed80 (was subs w8, w8, #1)'),
    (0x4f3f04, '08050071', 0x94146b9f, '[hs] +0xA8 request suppression window, b.lt path: bl hs_w8 0xa0ed80 (was subs w8, w8, #1)'),
    (0x4f3f14, '08050071', 0x94146b9b, '[hs] +0xA4 duration of scale +0xA0: bl hs_w8 0xa0ed80 (was subs w8, w8, #1)'),
    (0x4f3f3c, '08050071', 0x94146b91, '[hs] +0x54 duration of scale +0x50: bl hs_w8 0xa0ed80 (was subs w8, w8, #1)'),
    (0x4f3f54, '08050071', 0x94146b8b, '[hs] +0x80 hold-request delay: bl hs_w8 0xa0ed80 (was subs w8, w8, #1)'),
    (0x4f3f88, '08050071', 0x94146b7e, '[hs] +0x54 sibling path after +0xA4 expiry: bl hs_w8 0xa0ed80 (was subs w8, w8, #1)'),
    (0x4f3fb0, '08050071', 0x94146b74, '[hs] +0x8C cue delay after request release; exact-zero -> sound 0x8DD890: bl hs_w8 0xa0ed80 (was subs w8, w8, #1)'),
    (0x4f4010, '29050051', 0x14146b98, '[clamp1] +0x8C clamped decrement: b cave 0xa0ee70 (was sub w9, w9, #1)'),
    (0x4f4018, '08050011', 0x14146b9d, '[up] +0x84 freeze-phase count-up: b cave 0xa0ee8c (was add w8, w8, #1)'),
    (0x4f406c, '607e40bd', 0x14146bd0, '[ramp] manager +0x7C ramp step c*T: b cave 0xa0efac (was ldr s0, [x19, #0x7c]; 0x4F4070 now skipped)'),
    (0x4f41b0, '08050071', 0x94146af4, '[hs] +0xB4 window; expiry -> +0xAC=0: bl hs_w8 0xa0ed80 (was subs w8, w8, #1)'),
    (0x57e7dc, '00d340bd', 0xb940db08, 'Load whole ticks: ldr w8,[x24,#0xD8]'),
    (0x57e7e0, '0800391e', 0x34000188, 'Zero ticks: cbz w8,0x57E810'),
    (0x91dbdc, 'c80600b4', 0xb4786268, 'First sample: cbz x8,0xA0E828'),
    (0x91dc10, 'd5010034', 0x1403c2f0, 'Measured sample: b 0xA0E7D0'),
    (0x91de50, '10060071', 0x1403c42d, '[isubs] clock +0x34 delay: b cave 0xa0ef04 (was subs w16, w16, #1)'),
    (0x91dee8, '10060071', 0x1403c413, '[naive] clock +0x30 duration: b cave 0xa0ef34 (was subs w16, w16, #1)'),
    (0x9abc68, '09050071', 0x14018cbd, '[rumble] rumble channel 0 count +0x48: b stub 0xa0ef5c -> rh_w8 (was subs w9, w8, #1)'),
    (0x9abc7c, '2a050071', 0x14018cba, '[rumble] rumble channel count +0x60: b stub 0xa0ef64 -> rh_w9 (was subs w10, w9, #1)'),
    (0x9abcc0, '2a050071', 0x14018cab, '[rumble] rumble channel count +0x60: b stub 0xa0ef6c -> rh_w9 (was subs w10, w9, #1)'),
    (0x9abcdc, '2a050071', 0x14018ca8, '[rumble] rumble channel count +0x78: b stub 0xa0ef7c -> rh_w9 (was subs w10, w9, #1)'),
    (0x9abd34, '2a050071', 0x14018c90, '[rumble] rumble channel count +0x60: b stub 0xa0ef74 -> rh_w9 (was subs w10, w9, #1)'),
    (0x9abd50, '2a050071', 0x14018c8d, '[rumble] rumble channel count +0x78: b stub 0xa0ef84 -> rh_w9 (was subs w10, w9, #1)'),
    (0x9abd6c, '2a050071', 0x14018c8a, '[rumble] rumble channel count +0x90: b stub 0xa0ef94 -> rh_w9 (was subs w10, w9, #1)'),
    (0x9abdd0, '2a050071', 0x14018c6f, '[rumble] rumble channel count +0x78: b stub 0xa0ef8c -> rh_w9 (was subs w10, w9, #1)'),
    (0x9abdec, '2a050071', 0x14018c6c, '[rumble] rumble channel count +0x90: b stub 0xa0ef9c -> rh_w9 (was subs w10, w9, #1)'),
    (0x9abe8c, '2a050071', 0x14018c46, '[rumble] rumble channel count +0x90: b stub 0xa0efa4 -> rh_w9 (was subs w10, w9, #1)'),
    (0x9abf40, '29050011', 0x14018c02, '[up] pad auto-repeat count +0x30: b cave 0xa0ef48 (was add w9, w9, #1)'),
]

# How general each patch is and could be (dm/tools/docs_patches.py "Binding", listed in docs/agents/game-patches.md): what, its binding now, the loosest it could have (goal),
# purpose, why; blocked or kept: why the gap stays open (cannot close yet, or left open on purpose); checked: what was checked on game files (else a judgement)
BINDING = [
    {'what': '60 fps frame step (112 sites)', 'now': 'build', 'goal': 'game', 'purpose': 'frame rate',
     'why': "the game's own clock and timers (a community 60 fps mod on the host's frame step)",
     'blocked': 'frame-step stubs have no function-matched form yet'},
]
