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

# How general each patch is and could be (dm/tools/docs_patches.py "Binding", listed in docs/agents/game-patches.md): what, its binding now, the loosest it could have (goal),
# purpose, why; blocked or kept: why the gap stays open (cannot close yet, or left open on purpose); checked: what was checked on game files (else a judgement)
BINDING = [
    {'what': 'FMallocBinned3 constructor call cut, with the gate that puts the host allocator in (hle_uemalloc.c)', 'now': 'build', 'goal': 'engine', 'purpose': 'address space',
     'why': 'found without a build ID on the five Unreal games on the game drive (OCTOPATH TRAVELER 0 and II, DRAGON QUEST VII Reimagined, Pikmin 4, FINAL FANTASY RESONANCE; checked '
            '2026-10-29): the "Binned3" name, its getter, the one vtable holding it, the layout from the getter\'s slot, the one function other than slots 0 and 1 that stores the '
            'vtable (the constructor) and its one call site, whose x0 is the object. A rewriter rule must apply RELA relocations and gate at the call; this game is not on the drive'},
]
