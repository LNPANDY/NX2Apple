# NieR:Automata, Asian release (0100B8E016F76000): patches of this release's own main build, keyed by NSO build ID.
# The rewriter asserts each original byte sequence before applying a CUTS entry. What each cut does: the global profile's patches.py.
CUTS = {
  # 1.0.3 main: the dynamic-resolution function of the global build (010056B015FE8000/patches.py), 0x13c0 further on. Each original sequence
  # matches once in this build, at the global build's address + 0x13c0, and the function reads the same fields and constants
  # (disassembled 2026-10-27). The two frame-interval defaults are single instructions, matched by what the code does instead: 0x591198 loads the
  # mode right before calling the mode setter (the global build's, 0x13c0 on), and 0x9bc128 is the interval the present-interval function stores
  # at the device's +0x9c160, both as in the global build.
  '98397a10419894652f372d4dc1b6fc2c': [
    (0x9c07f4, '8c46a8528301271e', '8c36a8528301271e', 'dynamic resolution: bad frame cost 45 -> 22.5 ms at 60 fps'),
    (0x9c0844, 'ac4781520c40a872', 'ac4781520c30a872', 'dynamic resolution: optimal frame cost 32.01 -> 16.005 ms at 60 fps (first load)'),
    (0x9c0894, 'ac4781520c40a87283cc201e8001271e', 'ac4781520c30a87283cc201e8001271e', 'dynamic resolution: optimal frame cost 32.01 -> 16.005 ms at 60 fps (second load)'),
    (0x9c08b8, '00d0271e', '00d0251e', 'dynamic resolution: good frame cost 30 -> 15 ms at 60 fps'),
    (0x591198, '20008052', '00008052', 'NieR 1.0.3 frame interval default: 30 -> 60 fps (the mode the setter main+0x9c0590 stores at display +0x504)'),
    (0x9bc128, '41008052', '21008052', 'NieR 1.0.3 NVN present interval default: 30 -> 60 fps (stored at the device\'s +0x9c160)'),
    (0x9c08e8, 'ac9999528cd9a772', '0c0080520cf0a772', 'dynamic resolution lower bound follows the selected preset'),
    (0x9c08f4, 'cc648a52aceaa772', '0c0080520cf0a772', 'dynamic resolution lower bound follows the selected preset'),
  ],
}

# The dynamic-resolution control (DM_DYNAMIC_RESOLUTION, hle_fpslock.c k_nier_dr): the native scale/UV path and both preset bounds verified for this build.
CAPABILITIES = {'98397a10419894652f372d4dc1b6fc2c': ('DYNAMIC_RESOLUTION',)}

# How general each patch is and could be (dm/tools/docs_patches.py "Binding", listed in docs/agents/game-patches.md): what, its binding now, the loosest it could have (goal),
# purpose, why; blocked or kept: why the gap stays open (cannot close yet, or left open on purpose); checked: what was checked on game files (else a judgement)
BINDING = [
    {'what': '60 fps intervals and dynamic-resolution constants', 'now': 'build', 'goal': 'game', 'purpose': 'frame rate',
     'checked': "both releases' mains, where the host's rows for them were found",
     'why': "the game's own constants; the Asian release's function is the global one's 0x13c0 further on, so one function-matched rule could serve both releases"},
]
