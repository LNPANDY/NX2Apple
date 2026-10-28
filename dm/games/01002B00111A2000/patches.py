# Hyrule Warriors: Age of Calamity (01002B00111A2000): the rewriter's patches of this game's own builds. dm/tools/patch_nso.py loads every profile's patches.py and applies those of a module's NSO build ID;
# CUTS, OBS and FRAME_STEP as described there ("Registered patches"). Patches of Nintendo SDK module builds are in dm/tools/sdk_patches.py
from nso_asm import ADRP, B
# Hyrule Warriors: Age of Calamity steps its game a fixed amount per update, from two 30 fps values. A KIDS task (main+0x166d980, on a KIDSTaskScheduler thread, once per update)
# waits until 1 / fps has passed since the last update (fps at time +0x30: 30 from a frame-rate object, main+0x166daa4; csinc at main+0x166db80) and then steps the game clock
# (system +0x3348, the step at +0x3350) by that object's step (x23 +0x34: 1/30 s times the game's timescale, a second time at +0x44, fps 30 at +0x48), not by the time that
# passed (the measured path, main+0x166dca8, runs only without the object). The battle itself steps 1 / the game's frame rate per update: a block at main+0x269e150 {fps,
# interval, fps, float fps} = {30, 2, 30, 30.0}, read by the scene update's caller (main+0x8c3610: step = 1.0 / fps) and its jobs (32 reads; the game's own writers at
# main+0x8a35e0 / main+0xfc1618, a run-time interval request at +0x1d58, never ran in a probe). The event scripts step by the KTGL device's frame rate (device +0x32d0, from the
# interval in its config: the third stub). The updates are not held by the presents (a task kept 60 a second while the host held frames 3 vsyncs), so they run at the cap and
# the host's frame step paces only the presents: at main+0x166dab4 (where both fps paths join, before the update's tasks and the wait) the task's fps and the frame-rate block
# become the cap (60, or 30 at a 30 cap), the update's vsyncs (60 / cap) are marked (+0x28) and the device frame rate becomes 59.94 / those vsyncs; at main+0x166dc60 the
# object's steps are scaled by its fps × vsyncs / 60 and the vsyncs are counted. Every step is then per update as on the Switch, so an update rate below the cap slows them all
# together. With only the task's wait at 1/60 s the game clock ran at twice real time; with the clock fixed and the block left at 30, battles still ran at twice (Link covered
# twice the ground in a 3 s stick hold; enemy waves came early). Off (target 0), the device frame rate follows the game's fps (29.97 at 30, as with interval 2) and the steps and
# the block stay the game's. x16, x17, s16–s18 and the flags are dead at both sites; the function uses no x16 / x17
def frame_step(ctx):
    here, emit, fs_site, fs_put, FS_STATE_OFF = ctx.here, ctx.emit, ctx.site, ctx.put, ctx.state
    fs_site(0x166dab4, '68734339'); fs_site(0x166dc60, 'e83640b9'); fs_site(0x8d94b0, '4900c0f2')
    # nnMain builds KTGL's device config on its stack and inits the device once (main+0x8d94c4 → main+0x17c34f0): {1920, 1080, 3, 9, 5, interval 2, 9, …}. The device keeps the
    # interval (main+0x17c4ba8 → device +0x2aa4, passed to every present at main+0x17ced78, which sets it on the window when it changes) and its frame rate, 59.94 / interval
    # (main+0x17c37c8 → device +0x32d0). Interval 1 above a 30 fps cap (the engine's own 60 fps mode), else the game's 2. x16, x17 and the flags are dead up to the init call
    start = here(); emit(ADRP(16, here(), FS_STATE_OFF))
    for w in (0xb9400210,   # ldr w16,[x16]          target fps (float bits)
              0x52a83e11,   # mov w17,#0x41f00000    30.0
              0x6b11021f,   # cmp w16,w17
              0x5400006d,   # b.le two (+3)
              0xf2c00029):  # movk x9,#0x1,lsl #32   interval 1
        emit(w)
    emit(B(here(), 0x8d94b4)); emit(0xf2c00049); emit(B(here(), 0x8d94b4))   # two: movk x9,#0x2,lsl #32 (the original)
    fs_put(0x8d94b0, [B(0x8d94b0, start)], 'KTGL device config present interval: 1 above a 30 fps cap, else the game\'s 2 (state page target fps)')
    start = here(); emit(ADRP(16, here(), FS_STATE_OFF))
    for w in (0xbd400210,   # ldr s16,[x16]          target fps (0 = off)
              0x1e202208,   # fcmp s16,#0.0
              0x540001ad,   # b.le off (+13)
              0x1e380208,   # fcvtzs w8,s16          the cap
              0xb9003268,   # str w8,[x19,#0x30]     the task's fps
              0x52800791,   # mov w17,#60
              0x1ac80a31,   # udiv w17,w17,w8        vsyncs per update
              0xb9002a11):  # str w17,[x16,#0x28]    this update's vsyncs (on)
        emit(w)
    emit(ADRP(16, here(), 0x269e150))
    for w in (0xb9015208,   # str w8,[x16,#0x150]    the game's frame-rate block: fps
              0xb9015611,   # str w17,[x16,#0x154]   interval
              0xb9015a08,   # str w8,[x16,#0x158]    fps
              0x1e220111,   # scvtf s17,w8
              0xbd015e11,   # str s17,[x16,#0x15c]   float fps (the battle's step is 1 / it)
              0x14000007,   # b dev (+7)
              0xb9002a1f,   # off: str wzr,[x16,#0x28]
              0xb9403268,   # ldr w8,[x19,#0x30]     the game's fps
              0x34000188,   # cbz w8,orig (+12)
              0x52800791,   # mov w17,#60
              0x1ac80a31,   # udiv w17,w17,w8        vsyncs per update at that fps
              0x34000131):  # cbz w17,orig (+9)
        emit(w)
    emit(ADRP(16, here(), 0x2bac798))                                # dev:
    for w in (0xf943ce10,   # ldr x16,[x16,#0x798]   the KTGL device
              0xb40000d0):  # cbz x16,orig (+6)
        emit(w)
    emit(ADRP(8, here(), 0x1ef5f3c))
    for w in (0xbd4f3d10,   # ldr s16,[x8,#0xf3c]    59.94
              0x1e230231,   # ucvtf s17,w17
              0x1e311a10,   # fdiv s16,s16,s17
              0xbd32d210,   # str s16,[x16,#0x32d0]  the device frame rate
              0x39437368):  # orig: ldrb w8,[x27,#0xdc]
        emit(w)
    emit(B(here(), 0x166dab8))
    fs_put(0x166dab4, [B(0x166dab4, start)], 'KIDS frame task: fps and the frame-rate block = the cap, vsyncs per update marked; device frame rate 59.94 / vsyncs (state page target fps; 0 = the game\'s 30)')
    start = here(); emit(0xbd4036f0)   # ldr s16,[x23,#0x34]    the frame-rate object's step
    emit(ADRP(16, here(), FS_STATE_OFF))
    for w in (0xb9402a11,   # ldr w17,[x16,#0x28]    vsyncs per update (0 = off)
              0x340001f1,   # cbz w17,off (+15)
              0xf9401a08,   # ldr x8,[x16,#0x30]
              0x8b314108,   # add x8,x8,w17,uxtw
              0xf9001a08,   # str x8,[x16,#0x30]     vsyncs stepped
              0xb9404ae8,   # ldr w8,[x23,#0x48]     the object's fps
              0x34000148,   # cbz w8,off (+10)
              0x1b087e31,   # mul w17,w17,w8
              0x1e230231,   # ucvtf s17,w17
              0x52800788,   # mov w8,#60
              0x1e230112,   # ucvtf s18,w8
              0x1e321a31,   # fdiv s17,s17,s18       its fps × vsyncs / 60
              0xbd4046e0,   # ldr s0,[x23,#0x44]
              0x1e310a10,   # fmul s16,s16,s17
              0x1e310800,   # fmul s0,s0,s17
              0x14000002,   # b out (+2)
              0xbd4046e0,   # off: ldr s0,[x23,#0x44]
              0x1e260208,   # out: fmov w8,s16
              0xb9001a68):  # str w8,[x19,#0x18]     the update's step
        emit(w)
    emit(B(here(), 0x166dc6c))
    fs_put(0x166dc60, [B(0x166dc60, start)], 'KIDS frame task: the frame-rate object\'s steps × its fps × vsyncs per update / 60 (state page target fps; 0 = as the game sets them)')

FRAME_STEP = {'c3cf52bf2b05d7310884971b50bcccb8': frame_step}

# Whether a general rule could replace these patches (dm/tools/docs_patches.py lists it in docs/agents/game-patches.md)
GENERALIZE = "No: the stubs hook the game's own KIDS frame task and frame-rate block; only the host's frame-step state page is shared. Fire Emblem: Three Houses and Taiko Risshiden V DX run on KTGL too, with other frame code"
