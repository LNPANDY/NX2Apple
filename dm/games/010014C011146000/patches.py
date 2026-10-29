# Subnautica: Below Zero's own code, keyed by the NSO build ID. SDK cuts live in
# dm/tools/sdk_patches.py; see README.md, Memory, for the measurements.
CUTS = {
    # 1.23.55063: Unity's memory manager setup (main+0x651558) constructs the
    # ALLOC_BUCKET BucketAllocator (constructor main+0x64dcd8: granularity 16,
    # 32 buckets, 4 MB blocks, at most 255 blocks) and its constructor reserves
    # (blocks + 1) x 4 MB at once: one 1 GB address region (main+0x75a6b4), of
    # which the opening commits 80 MB (20 blocks). AddMoreBuckets (main+0x64e1ec)
    # returns false at the block limit and the allocation goes to Unity's other
    # allocators, so the limit sizes only the reservation (a run with a limit of
    # 2 loaded the opening and played it). Platform workaround: 63 blocks (a
    # 256 MB region), as the alias region is 4.375 GB on an iPhone and 64 GB on
    # a Switch.
    '5b050c55b8264040b642a0cdca5ded83': [
        (0x6517f4, 'e51f8052', 'e5078052', 'BucketAllocator ALLOC_BUCKET: at most 255 blocks of 4 MB (a 1 GB address region) → 63 (256 MB)'),
    ],
}

# Whether a general rule could replace these patches (dm/tools/docs_patches.py lists it in docs/agents/game-patches.md)
GENERALIZE = "Maybe: every Unity player constructs ALLOC_BUCKET the same way; a function-matched cut of its block count would need each Unity version's constructor call reviewed"
