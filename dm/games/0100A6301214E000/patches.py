# Fire Emblem Engage (0100A6301214E000): the rewriter's patches of this game's own builds. dm/tools/patch_nso.py loads every profile's patches.py and applies those of a module's NSO build ID;
# CUTS, OBS and FRAME_STEP as described there ("Registered patches"). Patches of Nintendo SDK module builds are in dm/tools/sdk_patches.py
CUTS = {
  # Fire Emblem Engage 2.0.0 (v327680) main: run the game's own 60 fps path (vertical sync count always 1).
  # The game's time class App.GameTime picks a vertical sync count per scene (Slow = 2, i.e. 30 fps: system, movies, demos, combat cutscenes, the hub; Normal is 1 only when GameConfig.IsPerformance)
  # and hands it to Unity through GameTime.SetVsyncCount(int) (QualitySettings.vSyncCount → NVN present interval). About 96 pieces of per-frame logic (cameras, map cursor, unit actors, menu scrolling and cursors, hub camera, minigames)
  # step by GameTime.VsyncFixedCount (= vSyncCount, how many 60 Hz ticks each frame advances): with a count of 2 and 60 frames on screen they all run twice as fast, with a count of 1 at 60 fps they are right.
  # The real-time VsyncDeltaCount / VsyncDeltaTime (hub character movement, fishing, dragon ride and so on, about 120 places) do not depend on the frame rate.
  # The cut is in Unity's managed wrapper QualitySettings.set_vSyncCount (main+0x32f92c0): both paths use w19 as the argument, mov w19,w0 → mov w19,#1,
  # so every caller (GameTime, QualitySettingsStack.PopImpl, XRSystem) can only set 1; the read side (get_vSyncCount) follows at 1 and the game stays consistent. No code calls SetQualityLevel.
  '8c08b9719e085f91847b5e0f935d9488': [
    (0x32f92d4, 'f303002a', '33008052', 'QualitySettings.set_vSyncCount wrapper: argument mov w19,w0 → mov w19,#1 (the 60 fps path of the game itself)'),
  ],
}

# How general each patch is and could be (dm/tools/docs_patches.py "Binding", listed in docs/agents/game-patches.md): what, its binding now, the loosest it could have (goal),
# purpose, why; blocked or kept: why the gap stays open (cannot close yet, or left open on purpose); checked: what was checked on game files (else a judgement)
BINDING = [
    {'what': 'Unity QualitySettings.vSyncCount held at 1', 'now': 'build', 'goal': 'engine', 'purpose': 'frame rate',
     'why': "an IL2CPP player registers the setter by its icall name, so the place can be found in any Unity game; holding it at 1 stays this profile's choice (its logic steps by the "
            'count)'},
]
