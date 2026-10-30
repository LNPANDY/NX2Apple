# Xenoblade Chronicles 3: changes to its own modules, checked by NSO build ID.
# Nintendo SDK module changes belong to dm/tools/sdk_patches.py.
CUTS = {
    # 2.2.1: nninitStartup reserves 60 GB for Monolith's allocator. Its first
    # arena reserves 4 GB + 128 KB, maps the first 128 KB for bookkeeping, and
    # takes additional pages on demand. iOS cannot reserve that address space.
    # The original arena commits 203 MB at the title and 225 MB in the opening
    # battle. A 1 GB first arena inside a 4 GB container leaves too little room
    # for the battle's 390 MB core buffer: its 512 MB virtual window ends
    # 70.75 MB past the container (12429a4, before any physical mapping).
    # Reserve 512 MB for the first arena and 4 GB for the container, changing
    # the bump increment, subtraction and stored capacity together. This is
    # an address-space adaptation; physical limits still follow the Switch
    # pool. Later-game allocation peaks remain to test.
    '82d187fe9ef9be921b8e1b1cddf7bd28': [
        (0x128e58c, 'e001c0d2', '2000c0d2', 'malloc address region: 60 GB to 4 GB'),
        (0x1241870, 'e98340b2', 'e9ff9fd2', 'first arena bump size, low part: mov x9,#0xffff'),
        (0x1241880, '4900a0f2', '4900a4f2', 'first arena bump size: 512 MB + 128 KB + 64 KB - 1'),
        (0x12418d8, 'e97b5fb2', 'e98361b2', 'first arena subtraction, sign extension'),
        (0x12418dc, 'c9ffbff2', 'c9ffbbf2', 'first arena subtraction: -(512 MB + 128 KB)'),
        (0x12418e8, '2800c0f2', '4800a4f2', 'first arena stored capacity: 512 MB + 128 KB'),
    ],
}

# How general each patch is and could be (dm/tools/docs_patches.py "Binding", listed in docs/agents/game-patches.md): what, its binding now, the loosest it could have (goal),
# purpose, why; blocked or kept: why the gap stays open (cannot close yet, or left open on purpose); checked: what was checked on game files (else a judgement)
BINDING = [
    {'what': 'malloc region 60 GB → 4 GB and its first arena', 'now': 'build', 'goal': 'game', 'purpose': 'address space',
     'why': "Monolith's own allocator; its constants span two functions (a multi-function rule). The cause, an iPhone's address space, is a platform limit"},
]
