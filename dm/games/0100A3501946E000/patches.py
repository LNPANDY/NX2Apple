# OCTOPATH TRAVELER II (0100A3501946E000): the rewriter's patches of this game's own builds. dm/tools/patch_nso.py loads every profile's patches.py and applies those of a module's NSO build ID;
# CUTS, OBS and FRAME_STEP as described there ("Registered patches"). Patches of Nintendo SDK module builds are in dm/tools/sdk_patches.py
CUTS = {
  # OCTOPATH TRAVELER II 1.1.1 (v131072) main: Unreal Engine 4.27's FMallocBinned3 cuts its pools out of the engine's address region, as DRAGON QUEST VII Reimagined's, and is made the same way
  # on the first allocation: GCreateMalloc (main+0xbecbf0) mallocs 0x1c38 bytes and constructs them (main+0xbecc08 → main+0xc4d778, which stores the vtable main+0x64710b0). The constructor
  # call is cut, and observation gate OBS_UE_MALLOC (OBS below) puts the host allocator's vtable into the new object, which is still in x19 (dm/host/hle_uemalloc.c).
  # nninitStartup (main+0xbebd44) reserves the engine region with nn::os::AllocateAddressRegion (main+0xbec3b4): 62 GB unless -SwitchVirtualAddressSpaceSize= (MB) set it, so the profile's
  # game_args caps it
  '0d9649011312f62e93f6a5673a09d7e9': [
    (0xbecc08, 'dc820194', '1f2003d5', 'GCreateMalloc: bl 0xc4d778 (FMallocBinned3 constructor) → nop; the host allocator\'s vtable is put in at the gate after it (hle_uemalloc.c)'),
  ],
}
OBS = {
  # OCTOPATH TRAVELER II 1.1.1 main: right after the cut FMallocBinned3 constructor call (CUTS above), x19 = the new allocator object; the host writes its vtable there (hle_uemalloc.c)
  '0d9649011312f62e93f6a5673a09d7e9': [
    (0xbecc0c, 21, 'aa1303e0', 'GCreateMalloc: the allocator object is in x19, before it is used: the host puts its vtable in; orig mov x0, x19'),
  ],
}

# How general each patch is and could be (dm/tools/docs_patches.py "Binding", listed in docs/agents/game-patches.md): what, its binding now, the loosest it could have (goal),
# purpose, why; blocked or kept: why the gap stays open (cannot close yet, or left open on purpose); checked: what was checked on game files (else a judgement)
BINDING = [
    {'what': 'FMallocBinned3 constructor call cut, with the gate that puts the host allocator in (hle_uemalloc.c)', 'now': 'build', 'goal': 'engine', 'purpose': 'address space',
     'checked': 'the discovery run on this main, 2026-10-29',
     'why': 'found without a build ID on the five Unreal games on the game drive (OCTOPATH TRAVELER 0 and II, DRAGON QUEST VII Reimagined, Pikmin 4, FINAL FANTASY RESONANCE; checked '
            '2026-10-29): the "Binned3" name, its getter, the one vtable holding it, the layout from the getter\'s slot, the one function other than slots 0 and 1 that stores the '
            'vtable (the constructor) and its one call site, whose x0 is the object. A rewriter rule must apply RELA relocations and gate at the call'},
]
