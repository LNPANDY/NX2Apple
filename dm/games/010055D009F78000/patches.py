# Fire Emblem: Three Houses (010055D009F78000): the rewriter's patches of this game's own builds. dm/tools/patch_nso.py loads every profile's patches.py and applies those of a module's NSO build ID;
# CUTS, OBS and FRAME_STEP as described there ("Registered patches"). Patches of Nintendo SDK module builds are in dm/tools/sdk_patches.py
CUTS = {
  # Fire Emblem: Three Houses 1.2.0 (v327680) main: 60 fps. KTGL runs the game on the main thread at 60 updates a second whatever it shows: each update steps by
  # 1/fps with fps = 60.0 (main+0x1a38f08, set at main+0x50e114; dt at main+0x510010), and the frame end (main+0x50f680) waits out 60/fps ticks of 1/59.94 s in a yield loop
  # (main+0x5be430). The render thread (main+0x50f8c0) draws the latest update and presents with the interval of the render mode (frame +0xbb84, set at main+0x50f3d0:
  # 0 = 1080p docked, 2 = 720p handheld; 3 / 5 their two-view variants; 1 and 4 are 720p / 1080p modes at interval 1 that nothing selects). Measured on the Mac: 59.2 updates
  # and 29.8 presents a second. The per-mode interval table (int at main+0xd13de0, read by main+0x4b0420 for the present and by the 6-tick fade counter in main+0x4b7530;
  # float at main+0xd13e40, the per-frame scroll step in main+0x4c2b30) becomes 1 for every mode, as in modes 1 and 4: every update is shown and the render thread's
  # own steps stay at the same speed. Resolutions stay per mode
  '89048449ba238c8cf565518b83bf02d3': [
    (0xd13de0, '020000000100000002000000020000000100000002000000', '010000000100000001000000010000000100000001000000', 'per-render-mode present interval table {2,1,2,2,1,2} → all 1 (60 fps; the game logic already runs at 60 updates a second)'),
    (0xd13e40, '000000400000803f00000040000000400000803f00000040', '0000803f0000803f0000803f0000803f0000803f0000803f', 'per-render-mode interval as float {2.0,1.0,2.0,2.0,1.0,2.0} → all 1.0 (render-thread per-frame steps)'),
    # The render thread still presents with interval 2 while either of two flags is set: main+0x21c9a03, a full-screen image drawn before the frame (main+0x4b4908: the opening movie),
    # and frame +0xc55f / +0xc560 (from the object at app +0x40: the character creation screen after the movie, and so on). In the engine's own 60 fps modes this traded 60 fps for
    # resolution in those scenes (main+0x50f7d0 drops 720p mode 1 to 1080p mode 0); here it would show them at 30 with the render thread's own steps at half speed. Both are ignored
    (0x50fb7c, '2801082a', 'e8031f2a', 'render thread forced interval 2: orr w8,w9,w8 (either flag) → mov w8,wzr (the mode\'s interval, 1)'),
    # The frame limiter's wait (main+0x5be430: yield, read the tick, until 60/fps ticks of 1/59.94 s have passed since the last frame end; x8 = time passed and x23 = target, in 100 ns)
    # is a busy loop on the host: the yield back-off spins its first 2 ms on a performance core and then oversleeps by up to 250 µs, so frames took 16.8 ms (59.5 fps, a repeated
    # display frame every 2 s) and CPU energy went from 0.16 W at 30 fps to 1.5 W on the Mac. The yield becomes nn::os::SleepThread of 96% of the time left, and the loop goes back to
    # the limiter's own tick read and comparison at main+0x5be44c (the instructions after the b are no longer reached); the host's sleep never oversleeps, so the frames take 16.68 ms
    (0x5be4c0, '20fa1494', 'e00208cb', 'frame limiter wait: bl YieldThread → sub x0,x23,x8 (time left, 100 ns units)'),
    (0x5be4c4, 'bbf71494', '01e87bd3', 'frame limiter wait: bl GetSystemTick → lsl x1,x0,#5'),
    (0x5be4c8, '680240f9', '2018008b', 'frame limiter wait: ldr x8,[x19] → add x0,x1,x0,lsl #6 (96 ns per 100 ns left)'),
    (0x5be4cc, '080008cb', '8df71494', 'frame limiter wait: sub x8,x0,x8 → bl nn::os::SleepThread (PLT main+0xafc300)'),
    (0x5be4d0, '087d149b', 'dfffff17', 'frame limiter wait: mul x8,x8,x20 → b main+0x5be44c (read the tick and compare again)'),
    # The render thread waits for the next update with KTGL's event wait (main+0xaa90e0, timeout in µs: × 1000 → nn::os::TimedWaitEvent) and passes 1/fps × 1000 = 16, one frame in ms,
    # so it polls every 16 µs: at 60 fps it draws in about 3 ms and then polled for the rest of the frame (42,000–53,000 wakeups a second on the Mac, against 1,200 at 30 fps, where
    # it waited in the present instead). The other four callers wait without a timeout. The timeout becomes 1000/fps × 1000 = 16,666 µs (s8 = 1000.0, loaded first)
    (0x50f8e8, '01102e1e', '483d0090', 'render thread wait timeout: fmov s1,#1.0 → adrp x8,#0xcb7000'),
    (0x50f8ec, '2018201e', '08514bbd', 'render thread wait timeout: fdiv s0,s1,s0 → ldr s8,[x8,#0xb50] (1000.0)'),
    (0x50f8f0, '483d0090', '0019201e', 'render thread wait timeout: adrp x8,#0xcb7000 → fdiv s0,s8,s0 (1000/fps; the fmul by s8 that follows makes it µs)'),
    (0x50f8f4, '08514bbd', '1f2003d5', 'render thread wait timeout: ldr s8,[x8,#0xb50] → nop (moved up)'),
  ],
}

# Whether a general rule could replace these patches (dm/tools/docs_patches.py lists it in docs/agents/game-patches.md)
GENERALIZE = "Partly: the interval tables, the flag and the render-wait timeout are the game's own. The frame-limiter wait (YieldThread until the tick passes) could become a general rewriter rule beside the spin-wait rewrite: a loop of yields and tick reads slept out to its deadline"
