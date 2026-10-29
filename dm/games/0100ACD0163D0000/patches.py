# Batman: Arkham Knight (0100ACD0163D0000): the rewriter's patches of this game's own builds. dm/tools/patch_nso.py loads every profile's patches.py and applies those of a module's NSO build ID;
# CUTS, OBS and FRAME_STEP as described there ("Registered patches"). Patches of Nintendo SDK module builds are in dm/tools/sdk_patches.py
CUTS = {
  # Batman: Arkham Knight 1.0.5 (v327680) main: the engine (Unreal Engine 3 with a backported binned allocator) makes its allocator once, under a static guard, in place in the bss
  # (main+0x51818c0, vtable main+0x329a408, 25 slots, UE3's 32-bit sizes) in the function behind GMalloc (main+0x192eb30, called by malloc main+0xb2e3d0 and free main+0xb2e388 while GMalloc,
  # main+0x483f770, is null). The constructor is inlined there (main+0x192ec14 to main+0x192fea0): it reserves 1 GB for its tables (main+0x192eee8) and 37 GB for its pools (main+0x192fe50:
  # 0x940000000, pool index = offset >> 30 up to 0x24), which only the Mac can give. Its globals (pool base main+0x3fd1088, page-size flag main+0x3fd1080, table regions main+0x51834b8 / main+0x51834d0)
  # are read only by the allocator's own code (main+0xb2b37c to main+0xb2e388) and the constructor. The cut branches from the guard's acquisition straight to its release, past the construction
  # and its __cxa_atexit destructor; the host has put its own allocator's vtable in the object before any guest code runs (hle_uemalloc.c layout UE3), and the code after the release
  # stores the object in GMalloc and asks slot 14 (IsInternallyThreadSafe, 1) whether to wrap it in a thread-safe proxy, as on hardware
  'feae83dc9e9fb34c77d0a62f1fa9ae9f': [
    (0x192ec14, '68cb0090', 'a4040014', 'GMalloc setup: adrp x8 (first instruction of the inlined allocator constructor, 1 GB + 37 GB of address space) → b 0x192fea4 (__cxa_guard_release); the host allocator is in the object already (hle_uemalloc.c)'),
    # The task queue's ring (push main+0xc5adbc, pop main+0xc5ab30: items at [q], tail at +0x18, head at +0x1c, 16-bit indices) publishes with plain stores: the push stores the item, then the
    # new tail, and takes no lock when +0x10 is set; the pop (under the queue's mutex) reads the tail, then the item, with no barrier between. Apple's cores make the stores visible, and satisfy
    # the loads, out of order where the Switch's Cortex-A57 practically never does, so a worker can see the new tail with the slot's old null and drop the item: the task never runs and its waiter
    # waits for good. Found by pull request #340 (freezes at the menus, in the opening and in Pauli's Diner, 2 of 3 runs); the words are its, checked against this build's disassembly. A store
    # barrier between the push's two stores and a load barrier between the pop's two loads, in the place of the reloads of the tail and the head (the values come from registers instead)
    (0xc5ae24, '4a3d4092', '4b3d4092', 'queue push: and x10, x10, #0xffff → and x11, x10, #0xffff (w10 keeps the tail)'),
    (0xc5ae28, '28792af8', '28792bf8', 'queue push: str x8, [x9, x10, lsl #3] → str x8, [x9, x11, lsl #3] (the item)'),
    (0xc5ae2c, '681a40b9', 'bf3a03d5', 'queue push: ldr w8, [x19, #0x18] (the tail again) → dmb ishst'),
    (0xc5ae30, '08050011', '48050011', 'queue push: add w8, w8, #1 → add w8, w10, #1 (then str w8, [x19, #0x18]: the new tail)'),
    (0xc5ab8c, '680240f9', 'bf3903d5', 'queue pop: ldr x8, [x19] → dmb ishld (after the tail load; w8 = head)'),
    (0xc5ab94, '691e40b9', '093d4092', 'queue pop: ldr w9, [x19, #0x1c] (the head again) → and x9, x8, #0xffff'),
    (0xc5ab98, '293d4092', '680240f9', 'queue pop: and x9, x9, #0xffff → ldr x8, [x19] (the ring; then ldr x8, [x8, x9, lsl #3]: the item)'),
  ],
}

# Whether a general rule could replace these patches (dm/tools/docs_patches.py lists it in docs/agents/game-patches.md)
GENERALIZE = 'No for the queue barriers (a data race in the game\'s own task ring). Partly for the allocator: the Unreal 4/5 games find their allocator by function fingerprint per engine version (see OCTOPATH TRAVELER 0); this UE3 build inlines its constructor into the GMalloc setup, so a fingerprint would match that whole function, and the vtable layout (25 slots, 32-bit sizes) is its own'
