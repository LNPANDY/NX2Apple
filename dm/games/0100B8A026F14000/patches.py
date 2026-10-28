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

GENERALIZE = 'Yes: as for the JP release, discover Unreal allocator functions by verified engine-version fingerprints and frame cvars by registered names. Until that general mechanism exists, keep this regional constructor cut and host registrations gated by their verified main build ID.'
