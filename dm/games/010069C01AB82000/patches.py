# SHIN MEGAMI TENSEI V: Vengeance: build-specific changes to the game's own module.
# Nintendo SDK changes stay in dm/tools/sdk_patches.py.
CUTS = {
    # 1.0.3: GCreateMalloc allocates 0x1c38 bytes, constructs FMallocBinned3 at
    # main+0x1578bc0 (vtable main+0x5a7f0a8), then stores GMalloc at +0x72c1b10.
    # Its constructor reserves 0x940000000 bytes (37 GB) at +0x15790b0, which
    # cannot fit the iPhone's address space. Replace it with the host allocator;
    # the gate below installs its vtable before any allocator method is called.
    '0a4f14a5c12f470a4d3168a8f2ae6005': [
        (0x1f2f63c, '6125d997', '1f2003d5', 'GCreateMalloc: bl FMallocBinned3 constructor -> nop; host malloc zone installed at OBS_UE_MALLOC'),
    ],
}

OBS = {
    '0a4f14a5c12f470a4d3168a8f2ae6005': [
        (0x1f2f644, 21, 'aa1303e0', 'GCreateMalloc: x19 is the allocator object; install the host vtable before use; orig mov x0, x19'),
    ],
}

# Whether a general rule could replace these patches (dm/tools/docs_patches.py lists it in docs/agents/game-patches.md)
GENERALIZE = 'Yes, as one rule for the six Unreal games here (OCTOPATH TRAVELER 0 and II, FINAL FANTASY RESONANCE, SHIN MEGAMI TENSEI V: Vengeance, DRAGON QUEST VII Reimagined, Pikmin 4): find GCreateMalloc and the FMallocBinned3 constructor by function fingerprint per engine version, and the frame cvars by their registered names at run time, so a new build needs no row in hle_uemalloc.c or hle_fpslock.c'
