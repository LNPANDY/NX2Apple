# FINAL FANTASY RESONANCE, Asian release (0100B8A026F14000): the rewriter's patches of this game's own builds. dm/tools/patch_nso.py loads every profile's patches.py and applies those of a module's NSO build ID;
# CUTS, OBS and FRAME_STEP as described there ("Registered patches"). Patches of Nintendo SDK module builds are in dm/tools/sdk_patches.py
# Same engine and cut as the registered JP/international profile (dm/games/0100606026F12000): the site was verified byte for byte in this build by disassembly
CUTS = {
  # FINAL FANTASY RESONANCE, Asian release 1.0.1 (v65536) main: Unreal Engine 5.6.1 constructs its FMallocBinned3 in place (nninitStartup main+0x137f0 → bl 0xae770, 38 GB of address space).
  # The call is cut; the host puts its allocator's vtable in the object before any guest code runs (hle_uemalloc.c layout UE5_6)
  'b7f965b9d7227db8e29f04e84ea7331b': [
    (0x137f0, 'e06b0294', '1f2003d5', 'nninitStartup: bl 0xae770 (FMallocBinned3 constructor, 38 GB of address space) → nop; the host allocator is in the object already (hle_uemalloc.c)'),
  ],
}

# How general each patch is and could be (dm/tools/docs_patches.py "Binding", listed in docs/agents/game-patches.md): what, its binding now, the loosest it could have (goal),
# purpose, why; blocked or kept: why the gap stays open (cannot close yet, or left open on purpose); checked: what was checked on game files (else a judgement)
BINDING = [
    {'what': 'FMallocBinned3 constructor call cut, with the gate that puts the host allocator in (hle_uemalloc.c)', 'now': 'build', 'goal': 'engine', 'purpose': 'address space',
     'why': 'found without a build ID on the five Unreal games on the game drive (OCTOPATH TRAVELER 0 and II, DRAGON QUEST VII Reimagined, Pikmin 4, FINAL FANTASY RESONANCE; checked '
            '2026-10-29): the "Binned3" name, its getter, the one vtable holding it, the layout from the getter\'s slot, the one function other than slots 0 and 1 that stores the '
            'vtable (the constructor) and its one call site, whose x0 is the object. A rewriter rule must apply RELA relocations and gate at the call; this release is not on the drive'
            ' (the JP release is)'},
]
