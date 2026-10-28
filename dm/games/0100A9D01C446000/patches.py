# DRAGON QUEST VII Reimagined (0100A9D01C446000): the rewriter's patches of this game's own builds. dm/tools/patch_nso.py loads every profile's patches.py and applies those of a module's NSO build ID;
# CUTS, OBS and FRAME_STEP as described there ("Registered patches"). Patches of Nintendo SDK module builds are in dm/tools/sdk_patches.py
CUTS = {
  # DRAGON QUEST VII Reimagined 1.2.0 (v131072) main: Unreal Engine 4.27's FMallocBinned3 likewise takes 37 GB of the engine's address region (nninitStartup reserves 62 GB at main+0xe8a2c0
  # unless -SwitchVirtualAddressSpaceSize= caps it; the allocator's pools are cut out of that region, so a capped region would starve them). Here the allocator is made on the first allocation,
  # during the static constructors: GCreateMalloc (main+0x32758b0) mallocs 0x1c38 bytes, constructs them (main+0x32758dc → main+0x291714) and stores GMalloc (main+0x77767e0). The constructor
  # call is cut, and observation gate OBS_UE_MALLOC (OBS below) puts the host allocator's vtable into the new object, which is still in x19 (dm/host/hle_uemalloc.c). No code outside the
  # allocator's own reads its pools (the pool base main+0x7744770 is read only there) or calls its methods directly: every FMemory call goes through the vtable
  'f7ec03e4cb9de3bd8319d4e899d2e9cc': [
    (0x32758dc, '8e6f4097', '1f2003d5', 'GCreateMalloc: bl 0x291714 (FMallocBinned3 constructor, 37 GB of address space) → nop; the host allocator\'s vtable is put in at the gate after it (hle_uemalloc.c)'),
  ],
}
OBS = {
  # DRAGON QUEST VII Reimagined 1.2.0 main: right after the cut FMallocBinned3 constructor call (CUTS above), x19 = the new allocator object; the host writes its vtable there (hle_uemalloc.c)
  'f7ec03e4cb9de3bd8319d4e899d2e9cc': [
    (0x32758e4, 21, 'aa1303e0','GCreateMalloc: the allocator object is in x19, before it is used: the host puts its vtable in; orig mov x0, x19'),
  ],
}

# Whether a general rule could replace these patches (dm/tools/docs_patches.py lists it in docs/agents/game-patches.md)
GENERALIZE = 'Yes, as one rule for the six Unreal games here (OCTOPATH TRAVELER 0 and II, FINAL FANTASY RESONANCE, SHIN MEGAMI TENSEI V: Vengeance, DRAGON QUEST VII Reimagined, Pikmin 4): find GCreateMalloc and the FMallocBinned3 constructor by function fingerprint per engine version, and the frame cvars by their registered names at run time, so a new build needs no row in hle_uemalloc.c or hle_fpslock.c'
