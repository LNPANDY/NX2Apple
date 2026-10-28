# Playing

How to build and install a game: [README](../README.md#how-to-play).

- **Settings:** a screen before the game starts sets frame rate, resolution, docked or handheld mode, language, rumble and more. Tap **Play**; your choices are remembered. What each one does: [Settings](settings.md).
- **Saves and logs** are in the Files app, under the game's name: `save/` and `log.txt` (the previous run is `log.prev.txt`). When something goes wrong, send `log.txt`.
- **Reinstalling:** some sideloading tools give a reinstalled app a new data folder. Copy `save/` and `pso_user.tsv` over from the old one to keep your progress.

## Touch controls

Tap **2D** / **3D** at the top to switch layouts; the app remembers your choice. Wonder, Engage, Dread, 13 Sentinels, Link's Awakening, Ace Attorney Investigations Collection, Unicorn Overlord, Rhythm Heaven Groove, Octopath Traveler 0, Pokémon Legends: Z-A, Cuphead, Absolum, Blasphemous 2, Brain Memory Training Academy, The Great Ace Attorney Chronicles, STEINS;GATE RE:BOOT, Big Brain Academy: Brain vs. Brain, Patrick's Parabox, Celeste, Raging Loop and Mario vs. Donkey Kong start in 2D, the other games in 3D (STEINS;GATE RE:BOOT's quick save is R3, in the 3D layout).

In 3D, the right stick (the camera in most games) is not drawn: swipe on the right third of the screen, starting anywhere off the buttons. In Super Mario Galaxy and Super Mario Galaxy 2, other touches outside the controls move the pointer; in Captain Toad: Treasure Tracker they touch the game's screen (touch blocks, stun enemies), and in Big Brain Academy: Brain vs. Brain too (its menus and activities).

A connected game controller hides the touch controls and keeps every button.

## Rumble

Game vibration uses the iPhone's haptic engine or a compatible connected controller. Controllers with separate left/right haptic outputs keep those effects separate. The settings screen's **Game rumble** and **Rumble strength** control it independently of **Touch feedback**. Phone rumble approximates the Switch's effects; physical feel and controller compatibility still need device testing.

## Motion (gyro)

A controller that supplies gyro data through Apple's controller support (DualSense, DualShock 4) drives the game's motion controls, on the Mac and the iPhone: aiming and tilt puzzles in games that read the controller's motion, such as Breath of the Wild with its Motion Controls option on. A controller without one (Backbone One, Razer Kishi and other controllers the phone mounts in) uses the iPhone's own gyro, as a Switch in handheld. Motion follows the controller in docked mode, the default.

`DM_PHONE_MOTION=0` in `Documents/env.txt` stops the phone's gyro, `DM_MOTION=0` all motion. If motion misbehaves, pack with `--no-motion` (`MOTION = False` in Spyder) for an app without it; `DM_MOTION=1` in `Documents/env.txt` turns it back on.

Switch Pro Controller gyro on the Mac still needs the HID support being developed in [PR #296](https://github.com/seedds/nxnative/pull/296).

**Shaking.** Shake the iPhone to shake the controller, in games that read its motion: Super Mario Odyssey's motion moves (such as the cap throw on a shake) need it, and Odyssey only takes them in its default docked mode. A light bump does not count; a sharp flick of the phone does.

## Game language

English by default. Pick another when packing with `--language` (`-l`), by code or by name: `-l ja`, `-l zh-Hans`, `-l French` (`LANGUAGE` in Spyder). It must be one the game has; the script prints the game's languages and stops on one it lacks. To change it without rebuilding, pick another on the settings screen.

## Settings in a file

Lines like `DM_OPMODE=0` (handheld mode: lower resolution, higher frame rate) in `Documents/env.txt` win over the settings screen, which then shows them greyed out ([the full list](settings.md#settings-in-a-file)). `DM_FPS_TARGET=30` keeps Breath of the Wild, Tears of the Kingdom, Octopath Traveler 0 and Octopath Traveler II at their original 30 fps, which saves battery; `DM_PRESENT_INTERVAL=game` does the same for Monster Train 2. `DM_SHOW_FPS=1` shows the frame rate at the top left (`--show-fps` when packing turns it on from the start). `DM_LAUNCHER=0` skips the settings screen.

## On the Mac

A Mac app shows the game's settings in a window before the game starts ([The Mac settings window](settings.md#the-mac-settings-window)). Its `env.txt` is `~/Library/Application Support/nxnative/<title ID>/env.txt`, and its log is `~/Library/Logs/nxnative/<title ID>.log`. [NX2Apple](https://github.com/LNPANDY/NX2Apple)'s library can also start it with the settings you pick there.

## Shaders on first sight

Short stutters the first time a new scene appears are normal: the app compiles graphics for it once and remembers them for the next launch. What it remembered, and what the game's list names, is built before the game starts, behind "Preparing shaders" and a progress bar when that takes more than half a second.
