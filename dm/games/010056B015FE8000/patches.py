# NieR:Automata (010056B015FE8000): patches of this game's own builds, keyed by NSO build ID.
# The rewriter asserts each original byte sequence before applying a CUTS entry.
CUTS = {
  # 1.0.3 (v131072) main: dynamic resolution compares measured frame cost with 45 / 32.01 / 30 ms thresholds for the Switch's 30 fps target.
  # At 60 fps use 1.35 / 0.9603 / 0.9 times 1000/60 ms: 22.5 / 16.005 / 15 ms. These are the four sites verified by FPSLocker Warehouse:
  # https://github.com/masagrator/FPSLocker-Warehouse/blob/v4/SaltySD/plugins/FPSLocker/patches/010056B015FE8000/3C10EC35C5EF4C36.yaml
  # Keep the instruction sequence and replace its constants directly; the profile's present_interval display supplies the 60 Hz presentation target.
  # The game clock already measures elapsed time at 60 ticks per second (main+0x8fc7a8); it needs no frame-step rewrite.
  '3c10ec35c5ef4c3686b4053afb0e58e7': [
    (0x591198, '20008052', '00008052', '60 FPS present interval mode: 1 -> 0'),
    (0x9bad68, '41008052', '21008052', '60 FPS NVN present interval: 2 -> 1'),
    (0x9bf528, 'ac9999528cd9a772', '0c0080520cf0a772', 'handheld lower bound follows preset minimum'),
    (0x9bf534, 'cc648a52aceaa772', '0c0080520cf0a772', 'docked lower bound follows preset minimum'),
    (0x9bf434, '8c46a8528301271e', '8c36a8528301271e', 'dynamic resolution: bad frame cost 45 -> 22.5 ms at 60 fps'),
    (0x9bf484, 'ac4781520c40a872', 'ac4781520c30a872', 'dynamic resolution: optimal frame cost 32.01 -> 16.005 ms at 60 fps (first load)'),
    (0x9bf4d4, 'ac4781520c40a87283cc201e8001271e', 'ac4781520c30a87283cc201e8001271e', 'dynamic resolution: optimal frame cost 32.01 -> 16.005 ms at 60 fps (second load)'),
    (0x9bf4f8, '00d0271e', '00d0251e', 'dynamic resolution: good frame cost 30 -> 15 ms at 60 fps'),
  ],
}

# Offered only for the verified rewrite with native scale/UV publication intact.
CAPABILITIES = {"3c10ec35c5ef4c3686b4053afb0e58e7": ("DYNAMIC_RESOLUTION",)}

# Whether a general rule could replace these patches (dm/tools/docs_patches.py lists it in docs/agents/game-patches.md)
GENERALIZE = "No: the game's own dynamic-resolution constants. The Asian build's cuts are the global build's 0x13c0 further on, so one function-matched rule could serve both releases"
