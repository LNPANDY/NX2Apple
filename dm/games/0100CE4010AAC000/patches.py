# FINAL FANTASY CRYSTAL CHRONICLES Remastered Edition (0100CE4010AAC000): the rewriter's patches of this game's own builds. dm/tools/patch_nso.py loads every profile's patches.py
# and applies those of a module's NSO build ID; CUTS as described there ("Registered patches"). Only the registered build (1.0.3) is here; the 1.0.0 sites are listed in README.md
CUTS = {
  # 1.0.3 (v196608) main (the sites of 1.0.0 + 0x25380, see README.md): Unity 2018.4's ThreadedStreamBuffer, the ring buffer every Unity worker thread is fed through (UnityGfxDeviceWorker, BatchDeleteObjects, ...), wakes a sleeping
  # side with a Dekker handshake on two words. The reader that finds nothing to read sets its "reader sleeping" flag (+0x118) with a store-release and loads the write position
  # (+0x80) again before sleeping on its semaphore (main+0x1e67a48 / main+0x1e67a50, in main+0x1e67930); a writer stores the write position with a store-release and then checks
  # that flag (main+0x1e685e0, or a plain load at main+0x1e683a8 / main+0x1e68498 / main+0x1e6851c). The mirror pair: a writer short of space sets "writer sleeping" (+0xd8) and
  # loads the read position (+0x40) again (main+0x1e687c0 / main+0x1e687c8), and the reader stores the read position and checks that flag (main+0x1e6805c / main+0x1e68154 /
  # main+0x1e681d8). The second access of each side is a plain ldr, and AArch64 lets a plain load complete before an earlier store-release is visible (store → load order needs
  # a load-acquire or a barrier), so both sides can read the old value and neither wakes the other. On Apple cores this happened within seconds in 3 of 5 Mac runs: the main
  # thread posts a command to UnityGfxDeviceWorker and waits on that command's semaphore (1.0.0 main+0x2250dd0, AcquireSemaphore), while the worker sleeps on its own (main+0x1e67ad4)
  # with the command in the buffer; every other thread then waits on the main thread and the game never presents a frame (1.0.0 thread dump: main waits at main+0x2250dd4, the worker
  # at main+0x1e42758 one wait later). Each of those plain loads becomes a load-acquire (ldar), which a store-release before it orders after the store: 14 of 14 runs boot and keep presenting
  'e1d8b399b787ae4186bc974403a82d97': [
    (0x1e67a50, '080140b9', '08fddf88', 'stream reader going to sleep: ldr w8,[x8] → ldar (write position after the store-release of "reader sleeping")'),
    (0x1e683a8, '080140b9', '08fddf88', 'stream writer: ldr w8,[x8] → ldar ("reader sleeping" after the store-release of the write position)'),
    (0x1e68498, '080140b9', '08fddf88', 'stream writer: ldr w8,[x8] → ldar ("reader sleeping" after the store-release of the write position)'),
    (0x1e6851c, '080140b9', '08fddf88', 'stream writer: ldr w8,[x8] → ldar ("reader sleeping" after the store-release of the write position)'),
    (0x1e687c8, '290140b9', '29fddf88', 'stream writer going to sleep: ldr w9,[x9] → ldar (read position after the store-release of "writer sleeping")'),
    (0x1e6805c, '080140b9', '08fddf88', 'stream reader: ldr w8,[x8] → ldar ("writer sleeping" after the store-release of the read position)'),
    (0x1e68154, '080140b9', '08fddf88', 'stream reader: ldr w8,[x8] → ldar ("writer sleeping" after the store-release of the read position)'),
    (0x1e681d8, '080140b9', '08fddf88', 'stream reader: ldr w8,[x8] → ldar ("writer sleeping" after the store-release of the read position)'),
  ],
}

# How general each patch is and could be (dm/tools/docs_patches.py "Binding", listed in docs/agents/game-patches.md): what, its binding now, the loosest it could have (goal),
# purpose, why; blocked or kept: why the gap stays open (cannot close yet, or left open on purpose); checked: what was checked on game files (else a judgement)
BINDING = [
    {'what': 'ThreadedStreamBuffer load-acquires', 'now': 'build', 'goal': 'engine', 'purpose': 'race',
     'why': "the race is in Unity 2018.4's ThreadedStreamBuffer, engine code other Unity games of that era ship (Cuphead, AI: THE SOMNIUM FILES, Raging Loop): a function-matched rule "
            'per Unity version',
     'blocked': 'no game files of those games on the drive to compare'},
]
