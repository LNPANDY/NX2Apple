# Pikmin 4 (0100B7C00933A000): the rewriter's patches of this game's own builds. dm/tools/patch_nso.py loads every profile's patches.py and applies those of a module's NSO build ID;
# CUTS, OBS and FRAME_STEP as described there ("Registered patches"). Patches of Nintendo SDK module builds are in dm/tools/sdk_patches.py
CUTS = {
  # Pikmin 4 1.1.1 (v262144) main: Unreal Engine 4.26.2's FMallocBinned3 cuts its pools out of the engine's address region, as DRAGON QUEST VII Reimagined's (UE 4.27), and is made the same way
  # on the first allocation: GCreateMalloc (main+0x353f770) mallocs 0x1c38 bytes and constructs them (main+0x353f788 → main+0x35ba610, the one store of the vtable main+0x8da4758 outside the
  # two destructors). The constructor call is cut, and observation gate OBS_UE_MALLOC (OBS below) puts the host allocator's vtable into the new object, which is still in x19 (dm/host/hle_uemalloc.c)
  # The engine's address region: nninitStartup (main+0x353f1xx) reads -SwitchVirtualAddressSpaceSize= into main+0x93c2130 (MB up to 4095), but reserves the region only when the argument
  # is absent: ldr x8,[x22,#0x130]; cbnz x8 → past the reservation; else 62 GB (orr #0xf80000000) into the size and nn::os::AllocateAddressRegion(main+0x93c2128, 62 GB). With the argument
  # the base stayed 0, and the first commit, AllocateMemoryPages(0, 2 MB) during the RHI's start-up (main+0x353ff8c), failed with 0xe03 into Unreal's fatal error. So the default is cut
  # to 4064 MB instead (no game_args), in Engage's 5 GB guest block as FINAL FANTASY RESONANCE's region
  '060f827bd2b38703e9ea11e3210d89bc': [
    (0x353f56c, 'e81361b2', '08c0bfd2', 'nninitStartup: the engine region\'s default size orr x8,xzr,#0xf80000000 (62 GB) → mov x8,#0xfe000000 (4064 MB)'),
    (0x353f578, 'e11361b2', '01c0bfd2', 'nninitStartup: AllocateAddressRegion size orr x1,xzr,#0xf80000000 (62 GB) → mov x1,#0xfe000000 (4064 MB)'),
    (0x353f788, 'a2eb0194', '1f2003d5', 'GCreateMalloc: bl 0x35ba610 (FMallocBinned3 constructor) → nop; the host allocator\'s vtable is put in at the gate after it (hle_uemalloc.c)'),
  ],
}
OBS = {
  # Pikmin 4 1.1.1 main: right after the cut FMallocBinned3 constructor call (CUTS above), x19 = the new allocator object; the host writes its vtable there (hle_uemalloc.c)
  '060f827bd2b38703e9ea11e3210d89bc': [
    (0x353f78c, 21, 'a9417bfd', 'GCreateMalloc: the allocator object is in x19, before it is used: the host puts its vtable in; orig ldp x29, x30, [sp, #0x10]'),
  ],
}

# Whether a general rule could replace these patches (dm/tools/docs_patches.py lists it in docs/agents/game-patches.md)
GENERALIZE = 'Yes, as one rule for the six Unreal games here (OCTOPATH TRAVELER 0 and II, FINAL FANTASY RESONANCE, SHIN MEGAMI TENSEI V: Vengeance, DRAGON QUEST VII Reimagined, Pikmin 4): find GCreateMalloc and the FMallocBinned3 constructor by function fingerprint per engine version, and the frame cvars by their registered names at run time, so a new build needs no row in hle_uemalloc.c or hle_fpslock.c'
