# Kingdom Battle 1.9.589692: platform-limit cuts for Snowdrop's three-pool
# allocator. Its unchecked 12 GB reservation cannot fit the iPhone guest
# block; the first 64 KB page then writes to NULL + 0x20000ffff (+0xea25b8).
# Reserve 3 GB: 2 GB large allocations and 512 MB per slab class. Keep the
# large allocator's independent page-count limit consistent with its range.
# The metadata reserve (+0xea60c4, 1 MB) remains sufficient for fewer pages.
# +0xf59fc8 discards incoming x1/x2, allowing the large size field override
# before its reserve. SDK node-area and alignment cuts are in sdk_patches.py.
# Later pool-capacity validation remains open; original growth fallbacks stay.
CUTS = {
    '3b39e0c06b8841f1baf0ea4d54286bfe': [
        (0xea2190, 'e80360b2', '0800a4d2', 'Snowdrop pool sizes: initialize each range to 512 MB'),
        (0xea21c0, 'f60760b2', '1600b8d2', 'Snowdrop combined range end: 12 GB to 3 GB'),
        (0xea21c4, 'e1031f2a', '0100b0d2', 'Prepare the large range size of 2 GB; reserve wrapper discards incoming x1'),
        (0xea21cc, 'e00760b2', '0000b8d2', 'Snowdrop combined reservation: 12 GB to 3 GB'),
        (0xea21d0, 'e2031faa', '615200f9', 'Override the large range size field to 2 GB; reserve wrapper discards incoming x2'),
        (0xea21f4, 'e5031032', '05009052', 'Large allocator maximum 64 KB page count: 65536 to 32768, matching its 2 GB range'),
    ],
}

# How general each patch is and could be (dm/tools/docs_patches.py "Binding", listed in docs/agents/game-patches.md): what, its binding now, the loosest it could have (goal),
# purpose, why; blocked or kept: why the gap stays open (cannot close yet, or left open on purpose); checked: what was checked on game files (else a judgement)
BINDING = [
    {'what': 'Snowdrop three-pool allocator: 12 GB of ranges → 3 GB', 'now': 'build', 'goal': 'game', 'purpose': 'address space',
     'checked': "both games' functions compared by fingerprint and disassembly, 2026-10-29",
     'why': 'Mario + Rabbids Kingdom Battle and Sparks of Hope build the same source routine differently: 44% of the instructions alike, fields 8 bytes apart, every callee different, '
            "other cut offsets and bytes (checked 2026-10-29), so no Snowdrop rule; a function-matched rule could carry it over the game's updates. The cause, an iPhone's address "
            'space, is a platform limit'},
]
