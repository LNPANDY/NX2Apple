# Upgrade fixtures

Files an older NX2Apple left on a player's Mac, as they were. `UpgradeFixturesTests` copies them into a temporary home and runs today's code on them. `$HOME` stands for the player's home folder and is replaced by the temporary one.

- `1.0.0-issue-490/env.txt`: the game's env.txt from the Copy diagnostics of #490 (Link's Awakening, launcher 1.0.0). DM_SAVE and DM_SAVE_SYNC point into an old folder in iCloud Drive.
- `icloud-keyword/env.txt`: an env.txt with the keyword `DM_SAVE_SYNC=icloud`, which meant iCloud Drive › NX2Apple Saves before the engine's cloud saves (seedds/nxnative#617).

A new fixture is a folder named after the version and what it holds. Put the files in it as the player had them. Never put keys, game files or a real save here.
