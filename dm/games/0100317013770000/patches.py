# Mario + Rabbids Sparks of Hope 1.6.2225577: Snowdrop's page allocator reserves
# three adjacent 4 GB address ranges (large allocations, 512 KB pages, 64 KB
# pages). Only committed pages consume the application pool, but the 12 GB
# reservation cannot fit an iPhone's guest block. The failed reservation is
# unchecked and the first 64 KB page writes to NULL + 0x20000ffff.
# These platform-limit cuts reserve 3 GB: 2 GB for large allocations, 512 MB for
# 512 KB pages and 512 MB for 64 KB pages. The large allocator has a separate
# maximum page count (w5 at +0x164338, stored at +8 by +0x168310), which must
# shrink with its range: otherwise its original 65536-page capacity allocates
# across the class boundary, and free interprets compressed file data as a
# slab-owner pointer (+0x1668dc while loading the first campaign).
# Initialize's metadata reserve is a fixed 1 MB (+0x168308), sufficient for the
# original 4 GB / 64 KB * 16-byte nodes and thus for the reduced 2 GB range.
# The two incoming arguments repurposed at +0x164300 / +0x16430c are discarded
# by +0x122ff0, which overwrites x1 with the size in x0 and never reads x2.
# Per-pool high-water validation remains open until gameplay passes; the slab
# allocators keep the game's shortage reporting and original reserve fallback.
# The memory system's startup (+0x94260) also builds a pool of 4,194,304 272-byte
# slots (+0x94364 -> +0x123484), 1.06 GB of address space, which no code in this
# build allocates from: only that startup and its teardown (+0x94214) name the
# pool or the default-pool slot it fills (0x7dd1260), and the opening quest,
# with the overalls found, commits none of it. With it, the regions reach the end of the
# 4.375 GB alias region in the opening quest; each UI node context
# (Moria::Services::UI::Shared::Nodes::Context, +0x2c4a228) reserves 576 KB and
# 256 KB more, unchecked, and the first entry pushed onto a context without its
# range writes to NULL + 0x78 (+0x2c534a8; shaking the overalls bush, GitHub
# issue #483). 65,536 slots keep the pool as built, in 17 MB.
CUTS = {
    '5b76a43b231e0640521ac66203f7c178': [
        (0x1642c8, '2800c0d2', '0800a4d2', 'Snowdrop allocator: initialize the three range-size fields to 512 MB (mov x8,#0x20000000); the large range is overridden to 2 GB below'),
        (0x1642fc, '7600c0d2', '1600b8d2', 'Snowdrop allocator: combined virtual range end uses 3 GB instead of 12 GB (mov x22,#0xc0000000)'),
        (0x164300, 'e1031f2a', '0100b0d2', 'Snowdrop allocator: prepare 2 GB for the large range (mov x1,#0x80000000); AllocateAddressRegion wrapper discards incoming x1'),
        (0x164308, '6000c0d2', '0000b8d2', 'Snowdrop allocator: reserve 3 GB instead of 12 GB (mov x0,#0xc0000000)'),
        (0x16430c, 'e2031faa', '615600f9', 'Snowdrop allocator: override the large range-size field to 2 GB (str x1,[x19,#0xa8]); AllocateAddressRegion wrapper never reads x2'),
        (0x164338, '2500a052', '05009052', 'Snowdrop large allocator: maximum 64 KB page count 65536 -> 32768, matching its 2 GB range (mov w5,#0x8000)'),
        (0x94354, '0108a052', '2100a052', 'Unused 272-byte slot pool: 4,194,304 -> 65,536 slots, 1.06 GB -> 17 MB of address space (mov w1,#0x10000)'),
    ],
}

# Whether a general rule could replace these patches (dm/tools/docs_patches.py lists it in docs/agents/game-patches.md)
GENERALIZE = "Partly: Mario + Rabbids Kingdom Battle and Sparks of Hope cut the same Snowdrop three-pool allocator; one function-matched rule could serve both only if their code matches (not checked). The unused 272-byte slot pool is Sparks of Hope's alone (Kingdom Battle's main and subsdk0 have no such init). The cause, an iPhone's address space, cannot be fixed in the host"
