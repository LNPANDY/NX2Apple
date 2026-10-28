# FINAL FANTASY TACTICS - The Ivalice Chronicles (010038B015560000): the rewriter's patches of this game's own builds. dm/tools/patch_nso.py loads every profile's patches.py and applies those of a module's NSO build ID;
# CUTS, OBS and FRAME_STEP as described there ("Registered patches"). Patches of Nintendo SDK module builds are in dm/tools/sdk_patches.py
CUTS = {
  # FINAL FANTASY TACTICS - The Ivalice Chronicles 1.4.0 (v393216) main: the job system wakes one worker of a pool through the pool's single auto-clear event. A job goes into worker k's
  # own queue (main+0x154c0), and if k's state reads asleep the caller signals the event (main+0x12554, from the per-worker dispatch loops main+0x14000 / main+0x14350 / main+0x17670,
  # the single-job submits main+0x14640 / main+0x14790 / main+0x14dc0 and the shutdown main+0x13df0). The SDK event wakes one condition waiter, by priority then FIFO (matching the host and Horizon); it cannot target k's queue. The woken worker runs only its own queue
  # (worker loop main+0x15ce0) and sleeps again, so with two workers in one pool (threads 0x1006 / 0x1007, later pinned to core 2) the signal went to the wrong one: the main thread waited
  # forever on a dispatch at boot in 4 of 6 Mac runs, and in a run that got through, a job sat in worker 0's queue for 12 s. The wait wrapper (main+0x12500, {event, pending}) already
  # signals the event once more when it takes a nonzero pending word after waking, and nothing in main sets it: the signal now sets it first, so a worker woken in another's place
  # passes the wake on (in a one-worker pool the extra signal costs one empty loop)
  '3cfd457814dd647f4cd0f0ae9f9454d2': [
    (0x12554, '000040f9', '000400f9', 'job pool wake: ldr x0,[x0] → str x0,[x0,#8] (pending = nonzero: the woken worker signals once more)'),
    (0x12558, '36fc1814', 'fdffff17', 'job pool wake: b SignalEvent → b 0x1254c (ldr x0,[x0]; b SignalEvent)'),
  ],
}

# Whether a general rule could replace these patches (dm/tools/docs_patches.py lists it in docs/agents/game-patches.md)
GENERALIZE = "No: a lost wake-up in the game's own job pool, not a host or SDK difference"
