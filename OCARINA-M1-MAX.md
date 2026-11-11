# Ocarina of Time on an M1 Max: state of the test work

Status on 2026-11-11. This page describes a private test tree, not the released app. Most of the settings named here are not in this repository's `main` yet. The table in "What the test tree holds" says which.

- Game: The Legend of Zelda: Ocarina of Time, title ID `0400486024DEC000`, update v131072.
- Machine: MacBook Pro with M1 Max, 32 GB, 120 Hz variable refresh screen, macOS 26.6.
- Test conditions from 11 Nov 02:25: power adapter connected, High Power mode, windowed, the same place in the game. Earlier runs were at least partly on battery. Their power state is not known, and that includes the 10 Nov baseline and the logged frame generation run.
- Goal: a steady 60 frames a second, or motion that feels like it.

## Where it stands

| Date | Frame time | Frames a second | Source |
|---|---|---|---|
| 10 Nov, start | 28.0 ms | 35.8 | run log |
| 11 Nov, run B | mean 18.7 ms, blocks of 300 frames from 16.7 to 20.9 ms | 53 | run log |
| 11 Nov, Render scale 0.75 | not logged | 40 to 56 | the tester read the HUD, and the log of that run was lost |

60 frames a second needs 16.7 ms. The game does not hold it yet. Two faults remain:

- Hitches of 95 to 204 ms, a few each minute.
- Uneven motion below 60. The game moves in whole steps of 1/60 s. A late frame is paid back later by a double step. In run B 514 of 1,800 frames took a double step, and each was shown about as long as a single one. The average speed is right (1.000 of real time), but the motion speeds up and slows down. After a hitch the debt is paid as a burst, which looks like fast forward.

## Settings used in the test build

| Setting | Value | Why |
|---|---|---|
| Frame rate | 60 | the game's own target |
| Game's upscaler | MetalFX | replaces a compute chain of the game that cost 3.2 ms a frame |
| Render scale | 0.75 | draws the 3D views smaller. The HUD still says 1440p. The game composes its final picture at 2560 x 1440, and the scale changes only the 3D views |
| Encode thread | On | Encode ahead needs it |
| Encode ahead | On | translates the next frame while the GPU still draws the last one |
| Frame generation | Off | experimental, see below |
| GPU overlap | Off | the picture flashes with it on (see "The model") |

Frame generation is in the test build and is not ready:

- 30 + 30 holds the game at 30 and MetalFX makes one frame between two. On the adapter in High Power the tester called it "amazing". It has no logged numbers. It seems to turn off during talk with a character, and the cause is not known.
- Uncapped, one logged run on 10 Nov at a 1080p output: real frames fell from about 41 to between 32 and 36 a second, 65 to 72 were shown, and MetalFX cost 4.1 ms a frame. The tester saw 70 to 80 on the HUD and said it was not smooth and had some input lag.
- Open faults from the first runs: the picture shakes at the border between the scene and the HUD, and some generated frames show ghosts.
- With frame generation on the encode thread is off, so Encode ahead does nothing there.
- Since 11 Nov the Uncapped mode also holds late frames, so the game steps evenly at 60 or 30. This is not tested yet.

## What the test tree holds

"In main" means this repository's `main` at engine pin `ab41d6a`.

| Change | Source | In main | Measured here |
|---|---|---|---|
| 120 Hz display link (`DM_PRESENT_LINK=2`) | engine switch | yes | part of the gain from 28.0 to 18.7 ms, not separated |
| Shaders read global memory at Metal's own addresses | upstream pull request 1833, open | no | GPU time 22.66 to 20.62 ms a frame, run log |
| MetalFX takes the game's own upscaler | upstream pull request 1951, open | no | removes a 3.2 ms compute chain, run log |
| Render scale for this game | upstream pull request 1903, open | no | 40 to 56 frames a second at 0.75 by the tester, no log |
| Border corrections compiled out of pipelines that do not need them | upstream pull request 1929, closed | no | not measured here. Upstream reports 1.8 ms less on an M4 Air |
| Early depth tests from the shader's own flag | upstream commit `a888e668` | yes | not measured here |
| One command allocator shared by a frame's submissions | upstream commit `fd8188c9` | no | not run yet. It is the candidate fix for the hitches |
| Encode ahead (`DM_NVN_PREENCODE`) | written in the test tree | no | part of the gain from 28.0 to 18.7 ms, not separated |
| Frame generation (`DM_MFX_INTERP`) | adapted from MacNativeGames (MIT license) | no | one logged run of the Uncapped mode, see "Settings used in the test build". Not ready |
| GPU overlap (`DM_NVN_SYNC_LAG`) | written in the test tree, experiment only | no | the game's wait fell from 11.6 ms to between 0.8 and 3.4 ms, and the picture flashed |

What did not help, each measured: fewer or merged submissions, the encode thread on or off, and the GPU clock held at its top frequency.

## The model

1. The frame is a serial chain. The game builds a frame. A host thread translates it (7 to 9.5 ms of CPU). The GPU runs it (15.4 to 20.4 ms from the first start to the last end). The game then waits until the GPU is done before it lets the next frame's commands run. In run B that wait took 3.7 to 11.5 ms a frame.
2. The GPU is not saturated. Holding its clock at the top did not change the time. The cost is latency in series: 111 to 115 render passes and 28 to 37 submissions a frame, and about 71 of the passes load and store whole attachments. A tile-based GPU pays at each pass boundary.
3. The wait in point 1 is the game's own code. Each frame it submits with a fence, acquires the next window texture, waits on that fence with no timeout, and only then signals the event that the next frame's commands wait on. The game never lets one frame start while the GPU holds the frame before it. So nothing in the game promises that a frame's memory stays untouched while the next one is built. The likely cause of the flashing with GPU overlap follows from this: the host lets the game run ahead, and the game rewrites memory that the GPU still reads. Which memory that is has not been measured yet.
4. The hitches fall in the blocks of run B where the host's pool of 32 command allocators ran out. This is a candidate cause, not a proven one.

## Next steps

1. Run the new test build with the settings above and read the log: hitches, allocator waits, frame time.
2. Run it once more with GPU overlap on, and ignore the flashing. The plan is to stop the overlap work if the frame time does not fall by 1.5 ms or more. A smaller result is inside the noise of single runs.
3. If it does fall: copy the bytes the GPU will read at the moment the game submits, so the game can run one frame ahead without flashing. MacNativeGames does this for Tears of the Kingdom.
4. Even motion below 60: a steady 40 frames a second on the 120 Hz screen (each frame shown for three refreshes), or frame generation.
5. Bring the changes of the table into this repository as patches, each with its measurement. Until then, of the settings in the table "Settings used in the test build", the released app shows only Frame rate and Encode thread for this game. Its Upscaling row is a different setting from Game's upscaler.

## Plan for reverse engineering

The game's code is read with REA, an MCP server that drives Ghidra.

Rule: measure with a run first. Read the game's code only when a log cannot answer the question and the answer changes what gets built.

What works:

- The whole game module is too large for the tool's start limit. One function at a time works and takes seconds.
- So each question is narrowed first with small scans (a table of the game's NVN function pointers, then the call sites of one function), and only the functions that the scans name are decompiled.

Done so far: point 3 of the model. It confirmed a measurement, named its parts, and showed that the game has no usable switch that removes the wait. The one mode that skips it also skips the window.

Planned, in this order, each behind its own gate:

| Question | Gate that must pass first | Why the game's code is needed |
|---|---|---|
| Which memory does the game rewrite in place each frame? | step 2 above shows a gain | a host diagnostic names the ranges first. The code is read only to explain a range the diagnostic names |
| Where is the frame step computed and used, and does the game accept a step of 1.5? | a decision to build the 40 frames a second step | the step lives in game code and no log shows where |
| Where do the 28 to 37 submissions a frame come from? | a GPU trace shows that pass boundaries are the cost | only the game's code shows why it flushes |

Not planned: analysis of the whole module, more tooling, or reading code to confirm what a run already measured.

Handling: decompiled code stays on the test machine. Only findings about behaviour are written down. No game file, key or extracted data is committed.
