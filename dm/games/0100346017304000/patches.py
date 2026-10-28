# Taiko Risshiden V DX (0100346017304000): the rewriter's patches of this game's own builds. dm/tools/patch_nso.py loads every profile's patches.py and applies those of a module's NSO build ID;
# CUTS, OBS and FRAME_STEP as described there ("Registered patches"). Patches of Nintendo SDK module builds are in dm/tools/sdk_patches.py
CUTS = {
  # Taiko Risshiden V DX 1.1.1 (v131072) main: KTGL's frame end (main+0x443e8c: the present wrapper, which presents and acquires the next texture, then the wait) waits until
  # N / 60 s have passed since the frame's start tick, polling nn::os::GetSystemTick and sleeping 2 ms per round (main+0x4c9f24, SleepThread). The start tick is read at
  # main+0x443d44, after the scene's update (the frame object's vtable +0x10, main+0x443cec), so every frame takes N / 60 s plus the time from the last poll to the next start,
  # rounded up to the 2 ms rounds: never one vsync, on any hardware (the Switch's double-buffered acquire only moves where the rounds start; a model of both gives 54 fps). That
  # is the game's own code, not the host: SleepThread and the tick are exact there. The Mac ran 55 fps in the menus and the town (frame time p5 18.15 / p50 18.28 ms), every 11th
  # frame on screen for two vsyncs. N, the int at GOT 0xa1c088 (data 0x9ec764), is the game's vsyncs per frame: 1, and 2 in CPrivateBattleWindow / CPrivateBattleTutorialWindow
  # (main+0xf02d0, main+0xec4cc; back to 1 at main+0xf04f4), whose code counts 60 / N frames a second. The game presents at interval 1 in both, so with N = 1 the host's present
  # pacing (the acquire waits) holds the frame to one vsync, and the wait's threshold becomes 0 (the loop returns after its first tick, which it still stores at +0x38). With N = 2
  # nothing else holds the frame two vsyncs, so the wait stays the game's (N forced to 2 at the title: 28.9 fps, as without a cut; the earlier cut, b.hs → b at main+0x443fd4,
  # presented 60). In the town then: 60.0 fps, frame time p50 16.66 / p95 17.08 ms; the main thread waits in the acquire instead of nine sleeps a frame (wakeups 2,050 → 300
  # a second). The opening movie, paced by its own player, was at 60 before
  'f5ab74b9d45f955de2dc91da8e039c57': [
    (0x443fac, '087c149be9e301b2291191f2087dc99b14fd45d3', '087c149b890780520809c99a9f060071f403889a',
     'frame limiter threshold: N × tick frequency / 60 (umulh by 1/60 → udiv by 60), then 0 when N = 1 (cmp w20, #1; csel x20, xzr, x8, eq): one vsync a frame is the present pacing\'s; N = 2 keeps the 2 ms rounds'),
  ],
}
# The same cut for builds without registered CUTS (dm/tools/nso_match.py; one patch, two reviewed implementations of the frame end, exactly one of which must match). Each is
# found by its fingerprint and its direct callees' (the present wrapper, GetSystemTick / GetSystemTickFrequency, SleepThread). The function reads N through its GOT entry, so the
# cut's assumption (N = 1 is held by the present pacing, N = 2 by the wait) moves with the code.
#   1.1.1: main+0x443e8c, 364 bytes, the cut at +288 (the CUTS above).
#   The base game (v0, main 47d7baf6…): main+0x43e140, 172 bytes (1.1.1 added the frame-skip branch at main+0x443ed4), the same 20 bytes at +104 (main+0x43e1a8) with N in w20
#   (GOT 0xa1be28, data 0x9ec55c, 1; 2 in the same two windows, main+0xefe90 / main+0xec0bc) and the start tick read after the update (main+0x43e128). Found by disassembly
#   (nso_fnmap.py: the 1.1.1 function has no exact match in v0); not run
limiter = 'frame limiter threshold: 0 when N = 1'
MATCH_CUTS = {'main': [
    {'name': limiter, 'size': 364, 'fingerprints': ['3191958fa93fa496f5b57c61cf4a08fd6154d947f0b16f481d119ba38c28c48d'],
     'cuts': [(288, '087c149be9e301b2291191f2087dc99b14fd45d3', '087c149b890780520809c99a9f060071f403889a', limiter + ' (as 1.1.1 main+0x443fac)')]},
    {'name': limiter, 'size': 172, 'fingerprints': ['8fda590c2f6df29ae21230a600452979e26c0972dcb738cec24130239aef1346'],
     'cuts': [(104, '087c149be9e301b2291191f2087dc99b14fd45d3', '087c149b890780520809c99a9f060071f403889a', limiter + ' (as v0 main+0x43e1a8)')]},
]}

# Whether a general rule could replace these patches (dm/tools/docs_patches.py lists it in docs/agents/game-patches.md)
GENERALIZE = "Already function-matched over its two builds (MATCH_CUTS). The limiter is KTGL's frame end; other KTGL games' frame ends are not checked for the same code"
