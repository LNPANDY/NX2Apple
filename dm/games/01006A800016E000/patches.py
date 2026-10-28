# Super Smash Bros. Ultimate (01006A800016E000): the rewriter's patches of this game's own builds. dm/tools/patch_nso.py loads every profile's patches.py and applies those of a module's NSO build ID;
# CUTS, OBS and FRAME_STEP as described there ("Registered patches"). Patches of Nintendo SDK module builds are in dm/tools/sdk_patches.py
CUTS = {
  # Super Smash Bros. Ultimate 13.0.5 (v2031616) main: the engine's memory (the nu:: allocator, set up by a static constructor at main+0x37c9a20) reserves 62 GB of address space with
  # nn::os::AllocateAddressRegion(0xf80000000) and hands it out in 64 KB units: a number line of free ranges, first [0, 0xf7f20) units from the region's start (main+0x37c9b98, given to
  # main+0x37c9c00), and the top 14 MB (region + 0xf7f200000) as the pool of its range nodes, committed 64 KB at a time up to the region's end (the bound checks at main+0x37c9a9c, +0x37c9c50,
  # +0x37ca3cc and +0x37caf68). The Switch's 64 GB alias region holds it; an iPhone's single 6 GB reservation cannot, and the abort at main+0x37c9bd0 followed. Booted on the Mac with a
  # 64 GB alias region, the game commits from the region's start upward (1.73 GB contiguous from it at the title, 75 s in) and the node pool's first 64 KB at the top, so the region is
  # cut to 4 GB (the application pool, 3.2 GB, bounds what it can commit), every constant derived from its size with it: the node pool at 4 GB − 14 MB, the first free range 0xff20 units
  '21450c647b8c5940ed5b68218ea128fd': [
    (0x37c9a5c, 'e11361b2', '2100c0d2', 'AllocateAddressRegion size mov x1,#0xf80000000 → mov x1,#0x100000000 (62 GB → 4 GB)'),
    (0x37c9a6c, 'e97f7cb2', '09fe9fd2', 'node pool top check, low part mov x9,#0xffffffff0 → mov x9,#0xfff0'),
    (0x37c9a70, '0be4afd2', '0be4bfd2', 'node pool start mov x11,#0x7f200000 → mov x11,#0xff200000'),
    (0x37c9a74, '09e4aff2', '09e4bff2', 'node pool top check movk x9,#0x7f20,lsl #16 → movk x9,#0xff20,lsl #16 (0xff20fff0)'),
    (0x37c9a78, 'eb01c0f2', '0b00c0f2', 'node pool start movk x11,#0xf,lsl #32 → movk x11,#0,lsl #32 (0xff200000 = 4 GB − 14 MB)'),
    (0x37c9a9c, 'e91361b2', '2900c0d2', 'node pool bound: region end mov x9,#0xf80000000 → mov x9,#0x100000000'),
    (0x37c9b98, '01e48f52', '01e49f52', 'first free range in 64 KB units mov w1,#0x7f20 → mov w1,#0xff20'),
    (0x37c9b9c, 'e101a072', '0100a072', 'first free range movk w1,#0xf,lsl #16 → movk w1,#0,lsl #16 (0xff20 units = 4 GB − 14 MB)'),
    (0x37c9c50, 'e91361b2', '2900c0d2', 'node pool bound: region end mov x9,#0xf80000000 → mov x9,#0x100000000'),
    (0x37ca3cc, 'e81361b2', '2800c0d2', 'node pool bound: region end mov x8,#0xf80000000 → mov x8,#0x100000000'),
    (0x37caf68, 'e91361b2', '2900c0d2', 'node pool bound: region end mov x9,#0xf80000000 → mov x9,#0x100000000'),
  ],
}
# The same 11 cuts for builds without registered CUTS (dm/tools/nso_match.py), as one patch of the four functions they lie in, which applies whole or not at all: a region cut in
# some of them and not the others would put the node pool outside the region or let the bound checks pass it. Each function is found by its fingerprint and its direct callees':
# the constructor (main+0x37c9a20, 472 bytes: the size, the node pool's place and top check, the first bound and the first free range) and the three functions with a region-end
# bound (main+0x37c9c00, 536 bytes; main+0x37ca180, 1,328 bytes; main+0x37caf10, 788 bytes). The base game 1.0.0 (v0, main fd471eb4…) has the same allocator, its 62 GB constant
# at five of these sites (main+0x27f869c, +0x27f86d4, +0x27f8868, +0x27f9108, +0x27f9c80), but none of the four functions is the same code (GitHub issue #375: 13.0.1 not checked)
region = 'engine region 62 GB → 4 GB (11 instructions in four functions)'
def _function(start, size, fingerprint):
    return {'size': size, 'fingerprints': [fingerprint], 'cuts': [(off - start, old, new, f'{why} (as 13.0.5 main+{off:#x})')
                                                                  for off, old, new, why in CUTS['21450c647b8c5940ed5b68218ea128fd'] if start <= off < start + size]}
MATCH_CUTS = {'main': [{'name': region, 'functions': [
    _function(0x37c9a20, 472, '96d9585e1be0b5ad1a975ae94df0b9e5540467bbd4f646fe7b4eb7abb6ba89fc'),
    _function(0x37c9c00, 536, '6a1ad9e4dcca89cdb736dddc23b8cb7640ce06dce95ce497362749cb75b43e61'),
    _function(0x37ca180, 1328, '6248aa2f59006b37f9af1690691000914210a3482e3a0defef56460c042cc43f'),
    _function(0x37caf10, 788, '846ba936f6b9870853808ed82d482ce0e104aa7ef300c692d79ca7d4837dd07b'),
]}]}

# Whether a general rule could replace these patches (dm/tools/docs_patches.py lists it in docs/agents/game-patches.md)
GENERALIZE = "Already function-matched for builds of the same code (MATCH_CUTS); the 62 GB region is the engine's own, so no general rule"
