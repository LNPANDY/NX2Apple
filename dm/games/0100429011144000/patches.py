# Subnautica's own code, keyed by the NSO build ID. SDK cuts live in
# dm/tools/sdk_patches.py; see README.md, Memory.
CUTS = {
    # 1.23.83358: the cut of Subnautica: Below Zero (010014C011146000), whose
    # Unity 2019.4 player is the same: its memory manager setup (main+0x60e720)
    # constructs the ALLOC_BUCKET BucketAllocator (constructor main+0x60af48:
    # granularity 16, 32 buckets, 4 MB blocks, at most 255 blocks), which
    # reserves (blocks + 1) x 4 MB at once (main+0x717924). AddMoreBuckets
    # (main+0x60b45c) returns false at the block limit and the allocation goes
    # to Unity's other allocators, so the limit sizes only the reservation.
    # Platform workaround: 63 blocks (a 256 MB region), as the alias region is
    # 4.375 GB on an iPhone and 64 GB on a Switch.
    'b3db5a1edaf8454f8cd52b31dc82fb02': [
        (0x60ea64, 'e51f8052', 'e5078052', 'BucketAllocator ALLOC_BUCKET: at most 255 blocks of 4 MB (a 1 GB address region) → 63 (256 MB)'),
    ],
}

# How general each patch is and could be (dm/tools/docs_patches.py "Binding", listed in docs/agents/game-patches.md): what, its binding now, the loosest it could have (goal),
# purpose, why; blocked or kept: why the gap stays open (cannot close yet, or left open on purpose); checked: what was checked on game files (else a judgement)
BINDING = [
    {'what': 'Unity BucketAllocator ALLOC_BUCKET: 255 blocks of 4 MB → 63', 'now': 'build', 'goal': 'game', 'purpose': 'address space',
     'checked': "the bucket allocator of five Unity 2021 and later mains (not Subnautica's), 2026-10-29",
     'why': "Unity 2019's constructor call takes the block count as a constant; Unity 2021 and later read the bucket sizes from boot.config with a default of one block (Cult of the "
            'Lamb, Monster Train 2, Blasphemous 2, BALL x PIT, Donkey Kong Country Returns HD; checked 2026-10-29) and need no cut, so no Unity rule. A function-matched rule could '
            "carry it over the game's updates",
     'blocked': 'no extracted main of either Subnautica on the game drive to fingerprint'},
]
