# OCTOPATH TRAVELER 0 (01005270232F2000): the rewriter's patches of this game's own builds. dm/tools/patch_nso.py loads every profile's patches.py and applies those of a module's NSO build ID;
# CUTS, OBS and FRAME_STEP as described there ("Registered patches"). Patches of Nintendo SDK module builds are in dm/tools/sdk_patches.py
CUTS = {
  # Octopath Traveler 0 1.0.5 (v327680) main: Unreal's nninitStartup (main+0x12d74) constructs the engine allocator, an FMallocBinned3, in place at main+0x68022c8 (main+0x12e40 → constructor
  # main+0x9f480). Its constructor reserves 37 GB of address space (main+0x9f748: 74 pools of 512 MB, pool index = offset >> 29), which only the Mac can give: an iPhone has about 5 GB without the
  # extended virtual addressing entitlement, and the pools are too uneven to shrink (at character creation the largest holds 68 MB, the 74 together 732 MB). The constructor is not called;
  # the host puts its own allocator's vtable in the object instead (dm/host/hle_uemalloc.c: Malloc, Realloc, Free and the size queries on a host malloc zone), and every allocation goes through it
  # (FMemory reaches the object through FPlatformMemory::BaseAllocator, main+0x132b4, and the thread-local storage allocator nninitStartup registers, main+0x12e80 / main+0x12ec0, through its vtable)
  '9fe60a212cff9b9a3656ab63d4f882e5': [
    (0x12e40, '90310294', '1f2003d5', 'nninitStartup: bl 0x9f480 (FMallocBinned3 constructor, 37 GB of address space) → nop; the host allocator is in the object already (hle_uemalloc.c)'),
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
