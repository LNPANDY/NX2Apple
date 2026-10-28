# DARK SOULS: REMASTERED (01004AB00A260000): the rewriter's patches of this game's own builds. dm/tools/patch_nso.py loads every profile's patches.py and applies those of a module's NSO build ID;
# CUTS, OBS and FRAME_STEP as described there ("Registered patches"). Patches of Nintendo SDK module builds are in dm/tools/sdk_patches.py
CUTS = {
  # Dark Souls Remastered 1.0.3 (v196608) main: 60 fps (30 on the Switch). The game presents at interval 1; its render thread (HGCommandDispatcher, main+0x8a4b28) ends each frame in a CPU limiter,
  # main+0x707090(this, fps): 1000 / fps ms less the time since its last call (nn::os::GetSystemTick), slept out when more than 2 ms are left; the main thread waits for the render thread.
  # The 30 is a constant at the only call (main+0x706fa4). The game does not step by the time that passed: the main thread's frame update (main+0x6a337c, on the manager at GOT 0x2287be0)
  # takes a fixed step, the float 1/30 at main+0x167a6ec loaded at main+0x667904, so at 60 fps everything ran twice as fast (on the iPhone). The step loads the 1/60 that rodata holds at
  # main+0x167a834 instead (as the community's 60 fps cheat for this build does). Climbing ladders still misplays at 60 (known with that cheat too). The limiter's frame-skip mode only starts
  # above 36.4 ms a frame, so 60 does not reach it
  'df3766a2bb651a3e822828abf10b6f7b': [
    (0x706fa4, 'e10f1f32', '81078052', 'frame limiter target: mov w1,#30 → mov w1,#60 (main+0x707090 sleeps out 1000 / fps ms since the last frame)'),
    (0x667904, '08ed46bd', '083548bd', 'frame update step: ldr s8,[x8,#0x6ec] (1/30) → ldr s8,[x8,#0x834] (1/60), passed to main+0x6a337c'),
  ],
}

# Whether a general rule could replace these patches (dm/tools/docs_patches.py lists it in docs/agents/game-patches.md)
GENERALIZE = "No: the game's own limiter constant and fixed step"
