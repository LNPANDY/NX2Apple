# The Legend of Zelda: Breath of the Wild (01007EF00011E000): the rewriter's patches of this game's own builds. dm/tools/patch_nso.py loads every profile's patches.py and applies those of a module's NSO build ID;
# CUTS, OBS and FRAME_STEP as described there ("Registered patches"). Patches of Nintendo SDK module builds are in dm/tools/sdk_patches.py
import struct
from nso_asm import ADRP, B, LDRX
CUTS = {
  # The Legend of Zelda: Breath of the Wild 1.9.0 (v1114112) main: 60 fps. The main loop of sead::GameFrameworkNx (main+0x112660c) runs a dynamic interval (framework +0x267 = 1):
  # every frame it computes how many vsyncs the last frame needed (rounded up), clamped to [2, max 3] (the max comes from the interval controller +0xc, constructed at main+0x1126c04); it steps up after 3 overrunning frames in a row,
  # steps down one level every 6 frames until 2, and hands the result through setWaitVsyncInterval (vtable +0x130, main+0x11269b8) to presentation (nvnWindowSetPresentInterval).
  # The game logic time step follows it: ksys::VFR is initialized with a base interval of 2 (constant 2 at main+0x127e740 → VFR::init main+0x151d2d0), and every frame VFR::updateInterval (main+0x151d3d0,
  # called at main+0xcf9ad4 / main+0x1281044) takes the framework's current interval (vtable +0x138); the frame ratio = current interval / 2 -- at interval 1 each frame advances half a 30 fps tick and the game speed stays the same;
  # when it struggles and steps back to 2 / 3 the ratio is 1 / 1.5, again at the same speed. So only the floor changes from 2 to 1: the lower bound of the candidate interval (two places), the step-down target recorded when stepping up, max(candidate, 3) - 1 → max(candidate, 2) - 1,
  # and stepping down stops at < 3 → < 2. On hardware the same logic starting from 1 would also be 60 fps; it falls back to 30 by itself only when its input shows a slow frame (the last two cuts make that input include the GPU time).
  # With the frame step (FRAME_STEP below) the host's step replaces the controller's interval, except while the game's own VFR override is set (and at fps_target 0): the framework then keeps the controller's
  'cd57b23fa4bbad65803d9788c01821ee': [
    (0x112670c, '6041201e', '4041201e', 'lower bound of the candidate interval: fmov s0,s11 (2.0) → fmov s0,s10 (1.0)'),
    (0x1126710, '7f0b0071', '7f070071', 'lower bound of the candidate interval: cmp w27,#2 → cmp w27,#1'),
    (0x112665c, '78008052', '58008052', 'step-down target recorded when stepping up, max(candidate, w24) − 1: mov w24,#3 → mov w24,#2'),
    (0x1126748, '1f0d0071', '1f090071', 'step-down target recorded when stepping up: cmp w8,#3 → cmp w8,#2'),
    (0x1126794, '3f0d0071', '3f090071', 'stepping down stops at < 3 → at < 2: cmp w9,#3 → cmp w9,#2'),
    # The controller's input (framework +0x250, controller main+0x1126cec..) is the main thread's CPU span up to the draw step (about 2.7 ms in the first shrine), so GPU-bound frames stayed at interval 1 and the game ran slow
    # (iPhone 16 Pro Max: 25 ms frames, two thirds of the speed). The game has a GPU-time path that uses max(CPU span, GPU time between the frame's two timestamp reports, framework +0x220, read after the fence wait)
    # but takes it only while [main+0x1e3a638]+0x1d2b8 is set (64 of 6,046 shrine frames); both of its checks become branches into it. The GPU time needs the profile's gpu_timestamps segment
    (0x112691c, 'c00000b4', '03000014', 'interval controller always takes the GPU time path (CPU span timing): cbz x0,#0x1126934 → b #0x1126928'),
    (0x1126974, 'c00000b4', '03000014', 'interval controller always takes the GPU time path (takes max(CPU span, GPU time)): cbz x0,#0x112698c → b #0x1126980'),
  ],
}

# Breath of the Wild: the framework's interval controller (the 60 fps cuts above) hands its interval to setWaitVsyncInterval (main+0x11269b8), which the main loop calls once a frame
# (main+0x11267c0); the framework keeps it at fw+0x244 (getter vtable +0x138, read by both callers of VFR::updateInterval and directly in 43 places) and passes it on to
# nvnWindowSetPresentInterval. The stub at the setter's entry replaces it with the host's step, read once a frame: ksys::VFR::updateInterval (main+0x151d3d0, x0 = the VFR at
# [main+0x1e93890]; called from GameScene::calc and the per-frame delegate main+0x1280f80) takes the framework's interval in the next frame (ratio = step / 2, base interval 2, and the
# int interval that 16 pieces of logic read), so the time step and everything else that reads the interval agree. The step is not written into the VFR call itself: the game presents
# on its own thread, so the host's step can change between the two VFR calls of a frame. The VFR's own override (+0x29 flag, +0x2c interval: 2 at main+0xc3b588 and main+0xc5ebf8,
# 1 at main+0xc609d8, set and cleared by game scenes) wins in the VFR:
# a stub there publishes it at state +0x24 so the host holds frames that long, and the setter stub leaves the framework's interval to the game while it is set. x16 / x17 are free
# at both entries
def frame_step(ctx):
    here, emit, fs_site, fs_put, FS_STATE_OFF = ctx.here, ctx.emit, ctx.site, ctx.put, ctx.state
    fs_site(0x11269b8, 'fd7bbea9'); fs_site(0x151d3d0, 'fd7bbea9')
    start = here(); emit(ADRP(16, here(), FS_STATE_OFF))
    for w in (0xb9400211,   # ldr w17,[x16]          target fps (0 = off)
              0x34000191):  # cbz w17,orig (+12)
        emit(w)
    emit(ADRP(17, here(), 0x1e93890)); emit(LDRX(17, 17, 0x890 // 8))   # the VFR
    for w in (0xb4000131,   # cbz x17,orig (+9)
              0x3940a631,   # ldrb w17,[x17,#0x29]   the VFR's override
              0x350000f1,   # cbnz w17,orig (+7)     the framework keeps the game's interval
              0xb9402211,   # ldr w17,[x16,#0x20]    step in vsyncs
              0x340000b1,   # cbz w17,orig (+5)      not decided yet
              0x2a1103e1,   # mov w1,w17
              0xf9401a11,   # ldr x17,[x16,#0x30]
              0x8b214231,   # add x17,x17,w1,uxtw
              0xf9001a11,   # str x17,[x16,#0x30]    vsyncs stepped
              0xa9be7bfd):  # orig: stp x29,x30,[sp,#-0x20]!
        emit(w)
    emit(B(here(), 0x11269bc))
    fs_put(0x11269b8, [B(0x11269b8, start)], 'setWaitVsyncInterval: the host\'s step unless the VFR override is set (state page target fps; 0 = the game\'s interval)')
    start = here(); emit(ADRP(16, here(), FS_STATE_OFF))
    for w in (0xb9400211,   # ldr w17,[x16]          target fps (0 = off)
              0x340000b1,   # cbz w17,orig (+5)
              0x3940a411,   # ldrb w17,[x0,#0x29]    the VFR's override
              0x34000051,   # cbz w17,pub (+2)       none: 0
              0xb9402c11,   # ldr w17,[x0,#0x2c]
              0xb9002611,   # pub: str w17,[x16,#0x24]  the game's own step: the host holds frames that long
              0xa9be7bfd):  # orig: stp x29,x30,[sp,#-0x20]!
        emit(w)
    emit(B(here(), 0x151d3d4))
    fs_put(0x151d3d0, [B(0x151d3d0, start)], 'VFR::updateInterval: its own override published for the host (state page target fps; 0 = original)')
    # Held buttons: sead::ControllerBase::updateDerivativeParams_ (main+0xeb0ef0) adds s8 to each held button's count, a constant 1.0 (main+0xeb0f78..88), and raises the repeat bit
    # when fmod(count - delay, pulse) < s8: delays and pulses are counted in frames, so at 60 fps menus repeated twice as fast as at 30 (MacNativeGames 866beb9). s8 is now the VFR's
    # ratio (+0x3c: interval / base interval 2), 0.5 at a one-vsync step, 1.0 at two as shipped; the constant stays when there is no VFR yet or the ratio is not positive.
    # x8 is loaded again after the site, s0 before its first read
    fs_site(0xeb0f80, '08f144f9'); fs_site(0xeb0f88, '080140bd')
    start = here(); emit(0xbd400108)   # ldr s8,[x8]            the constant 1.0
    emit(ADRP(8, here(), 0x1e93890)); emit(LDRX(8, 8, 0x890 // 8))   # the VFR
    for w in (0xb40000a8,   # cbz x8,back (+5)
              0xbd403d00,   # ldr s0,[x8,#0x3c]      its ratio
              0x1e202008,   # fcmp s0,#0.0
              0x5400004d,   # b.le back (+2)
              0x1e204008):  # fmov s8,s0
        emit(w)
    emit(B(here(), 0xeb0f8c))   # back
    fs_put(0xeb0f88, [B(0xeb0f88, start)], 'held-button counts step by the VFR ratio (menu repeat in game time at any frame step)')
    # Render scale (state +0x10, float written by the loader: DM_RENDER_SCALE, 1.0 by default; independent of the frame step). The dynamic-resolution method (main+0x12666e4) keeps a
    # scale in 0.8–1.0 rounded to 0.05 steps (+0x1218, main+0x1266818), or the game's forced 0.75 / 0.5 (+0x284 & 0x1800), in s8; from main+0x1266880 it applies s8: each view's
    # scale (+0x28a0 / +0x28a4 = s8 × base width (+0x1214: 1600 docked, 1280 handheld) / output width), from which the scene buffers are sized each frame (main+0x106340c), the
    # shader ratio uking_dynamic_resolution_ratio and the other readers (main+0xc3c3f4, an LOD check at main+0x14126b4). Setting s8 there keeps them all consistent (a multiply in the
    # size function, TOTK's way, would leave the ratio and those readers at the old scale). The apply block runs only when the dynamic path has just recomputed the scale (+0x280 bit 4,
    # set at main+0x1266830) or in a forced mode, else main+0x126686c skips it; with a factor it is taken every frame, as in the dynamic mode, so the factor holds with dynamic
    # resolution off too. Factors above 1.0 are refused by the loader: the per-frame texture pool's size is unknown. x8, s0, s1 and the flags are dead at both sites
    fs_site(0x1266880, '88ae40f9'); fs_site(0x126686c, struct.pack('<I', B(0x126686c, 0x1266950)).hex())
    apply = here(); emit(ADRP(8, here(), FS_STATE_OFF))
    for w in (0xbd401100,   # ldr s0,[x8,#0x10]      render scale
              0x1e202008,   # fcmp s0,#0.0
              0x540000ad,   # b.le orig (+5)         not set
              0x1e2e1001,   # fmov s1,#1.0
              0x1e212000,   # fcmp s0,s1
              0x54000040,   # b.eq orig (+2)         1.0: the game's own scale
              0x1e204008,   # fmov s8,s0             the host's scale
              0xf940ae88):  # orig: ldr x8,[x20,#0x158]
        emit(w)
    emit(B(here(), 0x1266884))
    fs_put(0x1266880, [B(0x1266880, apply)], '3D view scale = the host render scale (1.0 = the game\'s dynamic resolution)'); ctx.render_scale = 1
    start = here(); emit(ADRP(8, here(), FS_STATE_OFF))
    for w in (0xb9401108,   # ldr w8,[x8,#0x10]      render scale (float bits)
              0x34000088,   # cbz w8,skip (+4)       not set
              0x52091908,   # eor w8,w8,#0x3f800000
              0x34000048):  # cbz w8,skip (+2)       1.0
        emit(w)
    emit(B(here(), 0x1266880)); emit(B(here(), 0x1266950))   # apply the host's scale; skip: the original branch
    fs_put(0x126686c, [B(0x126686c, start)], 'scale apply block taken every frame when the host render scale is not 1.0')

FRAME_STEP = {'cd57b23fa4bbad65803d9788c01821ee': frame_step}

# How general each patch is and could be (dm/tools/docs_patches.py "Binding", listed in docs/agents/game-patches.md): what, its binding now, the loosest it could have (goal),
# purpose, why; blocked or kept: why the gap stays open (cannot close yet, or left open on purpose); checked: what was checked on game files (else a judgement)
BINDING = [
    {'what': 'interval controller: the lower bound and the GPU-time path', 'now': 'build', 'goal': 'game', 'purpose': 'frame rate',
     'why': "sead::GameFrameworkNx's interval controller in this build; Tears of the Kingdom shares sead but not this code"},
    {'what': '60 fps frame step and render scale (ksys::VFR)', 'now': 'build', 'goal': 'game', 'purpose': 'frame rate',
     'why': "the game's own frame code; the frame-step state page is general",
     'blocked': 'frame-step stubs have no function-matched form yet'},
]
