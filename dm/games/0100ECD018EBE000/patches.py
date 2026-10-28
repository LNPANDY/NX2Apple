# Paper Mario: The Thousand-Year Door (0100ECD018EBE000): the rewriter's patches of this game's own builds. dm/tools/patch_nso.py loads every profile's patches.py and applies those of a module's NSO build ID;
# CUTS, OBS and FRAME_STEP as described there ("Registered patches"). Patches of Nintendo SDK module builds are in dm/tools/sdk_patches.py
from nso_asm import ADRP, B
CUTS = {
  '0effe4af1dec3a7966b934d4a7c3d2bf': [
    # 60 fps (30 on the Switch). Every frame main+0x2e7750 measures the time since the last one (oe::GetProgramTotalActiveTime), rounds it to 60 Hz vsyncs and clamps it to [2, cap]
    # (a step above cap + 10 counts as 2); the base clock (time object +0x20, main+0x2e753c) then advances by that step, the field and battle clocks by it times their scale, and game
    # seconds by step / 60. Timers, fades, animation and the scripts' frame counts follow the clocks. With the floor at 2 a frame shown every vsync still stepped two vsyncs, and
    # the game ran at double speed; with 1 the step is what really passed: 1 at 60 fps, 2 when a frame takes two vsyncs (and at the game's own 30 fps, as before)
    (0x2e77a4, '49008052', '29008052', 'frame step floor in 60 Hz vsyncs: mov w9,#2 → mov w9,#1 (the game steps by the vsyncs that passed, down to one)'),
  ],
}

# Paper Mario: The Thousand-Year Door 1.0.1: every frame main+0x2e7750 measures the time since the last one, rounds it to 60 Hz vsyncs, clamps it (at least 2 on the Switch, 1 with
# the cut above) and stores it as the base clock's step (time object +0x44, main+0x2e77f8), which the clocks below it follow (main+0x2e753c). Rounding a frame time between one and
# two vsyncs down to 1 ran the game slow whenever 60 did not hold (a run at 44 fps took 10-20% longer for each fade). The stub stores the host's step instead, the vsyncs the frame
# stays on screen, so game time = real time at any rate, and counts the vsyncs stepped. Before the host has decided a step, and at target 0, the game's own. x16 and x17 are dead
# at the site (the bl to the clock update follows)
def frame_step(ctx):
    here, emit, fs_site, fs_put, FS_STATE_OFF = ctx.here, ctx.emit, ctx.site, ctx.put, ctx.state
    fs_site(0x2e77f8, '604600bd')
    start = here(); emit(ADRP(16, here(), FS_STATE_OFF))
    for w in (0xb9400211,   # ldr w17,[x16]          target fps (float bits; 0 = off)
              0x34000111,   # cbz w17,orig (+8)
              0xb9402211,   # ldr w17,[x16,#0x20]    step in vsyncs
              0x340000d1,   # cbz w17,orig (+6)      not decided yet
              0x1e230220,   # ucvtf s0,w17           the base clock's step
              0xf9401a10):  # ldr x16,[x16,#0x30]
        emit(w)
    emit(0x8b110210)                                                 # add x16,x16,x17
    emit(ADRP(17, here(), FS_STATE_OFF)); emit(0xf9001a30)           # str x16,[x17,#0x30]    vsyncs stepped
    emit(0xbd004660); emit(B(here(), 0x2e77fc))                      # orig: str s0,[x19,#0x44]; back
    fs_put(0x2e77f8, [B(0x2e77f8, start)], 'frame step: the base clock steps by the host\'s vsyncs (state page target fps; 0 = the game\'s measured step)')

FRAME_STEP = {'0effe4af1dec3a7966b934d4a7c3d2bf': frame_step}

# Whether a general rule could replace these patches (dm/tools/docs_patches.py lists it in docs/agents/game-patches.md)
GENERALIZE = "No: the game's own clock floor and step"
