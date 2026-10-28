# Front ends

A graphical app that packs games, keeps a library of them or starts them is a project of its own that builds on nxnative. [NX2Apple](https://github.com/LNPANDY/NX2Apple), [NX Play](https://github.com/varyform/nx-native-wrapper) and [NxNative Launcher](https://github.com/rennan101/nxnative_Launcher) are such apps. This page lists what such an app can rely on: how it runs a build and follows it, what a built app says about its game's settings, and how it starts a game with them. None of it needs a change to nxnative; when a front end needs more, the piece it needs is an issue or a small PR here.

- [Building: the NSP script](#building-the-nsp-script)
- [The settings list](#the-settings-list)
- [Starting a game](#starting-a-game)
- [What a front end cannot see yet](#what-a-front-end-cannot-see-yet)

## Building: the NSP script

`scripts/build_ipa_from_nsp.py <NSP folder>` builds one game: an IPA by default, a Mac app with `--platform mac-app`, at the path `-o` names. Its options are in [The packing script in detail](development.md#the-packing-script-in-detail) and `--help`.

With `--progress json` it asks nothing and writes one JSON object per line on stdout. Every object has `ev` (the event) and `t` (Unix time, seconds):

| `ev` | Fields | When |
|---|---|---|
| `stage` | `k`, `n` (stage k of n), `name`, `step` | a stage starts; `n` can grow during the build (a provisional profile's heap check) |
| `step` | `k`, `name`, `step` | a new step within the stage; its count starts again |
| `progress` | `k`, `name`, `step`, `done`, `total`, `unit` (`''`, `'B'` for bytes, `'files'`, …), `est` (the total is an estimate), `note`, `frac` (0 to 0.99, or `null` when the work cannot be counted), `eta` (seconds or `null`), `elapsed` | the count changes; at most every 0.5 s while only the count moves |
| `stage_end` | `k`, `name`, `ok`, `summary`, `elapsed` | a stage ends |
| `say` | `msg` | a message; one starting with `[RED] ` is an error |

The exit code is 0 for a finished build, 1 for a build that stopped on an error (its last `say` says why, starting with `[RED] `; an unexpected error also prints its traceback on stderr), 2 for invalid command-line arguments, and 130 when interrupted. Argument parsing happens before JSON mode starts: an argument error writes its usage and error to stderr and emits no JSON events. A front end must check the process's exit status and capture stderr as well as the JSON stream. Each tool's full output goes to `<NSP folder>/<title ID>_build/logs/`, not to stdout. The build folder `<title ID>_build/` keeps what the next build can reuse, so a second build after a change takes a fraction of the first.

## The settings list

A built app carries the settings its game supports, as the iPhone app's settings screen shows them ([Settings](settings.md)): `dm/launcher.json` in the app inside an IPA, `Contents/Resources/dm/launcher.json` in a Mac app. The Mac app's list leaves out the settings only the iPhone app reads (the frame-rate counter, touch feedback). `dm/games/settings.py` writes it from `dm/games/settings.tsv`, whose header describes the rows. Breath of the Wild's Mac list, shortened:

```json
{"schema": 1, "game": "01007EF00011E000", "settings": [
 {"env": "DM_FPS_TARGET", "kind": "choice", "section": "Game", "label": "Frame rate", "note": "…", "default": "60",
  "options": [["30", "30 fps"], ["60", "60 fps"]], "level": "basic"},
 {"env": "DM_RENDER_SCALE", "kind": "range", "section": "Game", "label": "Render scale", "note": "…", "default": "1.0", "min": 0.5, "max": 1.0, "step": 0.05},
 {"env": "DM_FPS_HOLD", "kind": "toggle", "section": "Performance", "label": "Hold frames when late", "note": "…", "default": "on", "on": "on", "off": "off"}
]}
```

- `env`: the environment switch the setting sets. `kind`: `choice` (one of `options`, each `[value, label]`), `range` (a number from `min` to `max` in `step`s) or `toggle` (`on` or `off`, the values the switch takes).
- `section`: the heading the row goes under, today `Game`, `Controls` or `Performance`. Sections come in the order of their first rows, and rows in the order to show them. A new section may appear in schema 1: a reader draws a section it does not know like the others, under its name, as the iPhone app does.
- `default`: the value for this app's platform ([Tested defaults](settings.md#tested-defaults)), with profile defaults resolved for its game. A front end that keeps only the choices that differ from it lets a newer build's tested defaults reach the player, as the iPhone app does.
- `base` (optional, render scale only): `{"docked": [w, h], "handheld": [w, h]}`, the 3D views' size that the scale multiplies, so a front end can show 0.75 as 1200×675 docked. It comes from the game's profile (`render_base`), and only some games have it.
- `level` (optional): `basic` marks a setting to show first, for a front end that shows a short list and puts the rest behind a second step. Without it, the front end decides.
- `needs` (optional): `<VAR>=<value>` makes the row a sub-setting of the row that sets `<VAR>`, drawn only while that row has that value (Rumble strength only while rumble is on). A row naming a variable the list does not have stays drawn.
- An app without the file has no settings to offer: start it as it is.

**Compatibility.** [launcher.schema.json](launcher.schema.json) describes the file as a JSON Schema, so a front end can check it and generate its types from it. `schema` is 1, and schema 1 grows only by optional fields: a reader ignores fields it does not know, draws sections it does not know, and a field never changes its meaning. A new `kind` would be schema 2, since a reader cannot draw a kind it does not know. A list written before the field existed has no `schema` and is 1. In `settings.tsv`, the optional fields come from the last column, `meta` (`key=value` pairs separated by `;`); a new key is added in `settings.py`'s `META`, here and in the schema together, and `test_launcher_settings.py` fails when the three disagree.

## Starting a game

**A Mac app** is started like any app, or by running its `Contents/MacOS/nxnative` with the chosen settings in its environment (`DM_FPS_TARGET=30`, …). The launcher there runs the host as a child, forwards SIGTERM, SIGINT and SIGHUP to it and exits with its exit code. A variable already in the environment wins; then come `~/Library/Application Support/nxnative/<title ID>/env.txt` and the bundle's `dm/env.txt`, one `KEY=VALUE` per line ([A Mac app](development.md#a-mac-app)). The save is in `save/` in that Application Support folder; the log is `~/Library/Logs/nxnative/<title ID>.log`, the previous run's `<title ID>.prev.log`. The title ID is `DMTitleID` in the app's `Info.plist`.

A Mac app shows its own settings window before the game, drawn from its `launcher.json` and keeping its choices in the same store ([Saved choices](#saved-choices), [The Mac settings window](settings.md#the-mac-settings-window)). It shows a variable the launch environment or an `env.txt` sets as fixed. A front end that draws the settings itself starts the app with `DM_LAUNCHER=0` in its environment (or `--no-launcher` on its command line) to skip the window. The saved choices still apply, so a front end that writes them gets the same game as the window would.

Settings a player chose in a front end and wants kept, also for a start from Finder or the Dock, go in the app's saved choices ([Saved choices](#saved-choices)), not in its environment.

**An IPA** is installed by the player (sideloading); its own settings screen starts the game. Lines in the app's `Documents/env.txt` win over that screen ([Settings in a file](settings.md#settings-in-a-file)). The save and `log.txt` are in the app's Documents folder.

## Saved choices

Each app keeps the player's choices in its own preferences domain, its bundle ID (`CFBundleIdentifier` in `Info.plist`, `org.nxnative.<title ID>` unless the app was packed with another): one string per setting, under the key `launcher.<env>` (`launcher.DM_FPS_TARGET` = `"30"`). The iPhone app's settings screen keeps them there, and a Mac app's launcher (`dm/mac/launcher.c`) reads them at every start, so a start from Finder or the Dock has them too. A front end writes the same keys (`CFPreferencesSetAppValue` with the app's bundle ID, or `defaults write org.nxnative.<title ID> launcher.DM_FPS_TARGET -string 30`), and a settings window inside the app would too: there is one set of choices, and every view of it agrees.

- **Only choices that differ from the tested default are kept.** A setting the player left at its default follows the defaults of a later build. Remove a key when the player picks the default again. For "Reset to tested defaults", remove the keys of the settings the player can change; the app's own screen does that when Play applies the defaults, and keeps the saved choice of a setting fixed for this start.
- **Checked when read.** The launcher uses a saved value only when this build still offers it: one of a `choice`'s options, a `toggle`'s `on` or `off`, or a number from a `range`'s `min` to `max`. It checks against the app's own list, which the packer copies into `Info.plist` as `DMSettings`. Any other value, a value that is not a string, or a key no setting has is ignored; it stays saved until the settings screen's Play replaces it with the player's choice. So a rebuild that stops offering a value falls back to its tested default.
- **The order**, the first that sets a variable wins:
  1. the launch environment (a front end's launch overrides, a terminal);
  2. the player's `env.txt` (`~/Library/Application Support/nxnative/<title ID>/env.txt`; on the iPhone, `Documents/env.txt`);
  3. the bundle's `dm/env.txt`;
  4. saved choices;
  5. the tested defaults (the host's own, from the game's profile).
- **Launch overrides are temporary.** A front end that starts the game with a variable in its environment overrides the saved choice for that start only. It writes the store only when the player means to keep the choice.
- **`DM_SAVED_CHOICES=0`** (in the environment or an `env.txt`) starts with the tested defaults and leaves the saved choices as they are. **`DM_LAUNCHER=0`** only skips the settings screen (the iPhone's, or a Mac app's window): the saved choices still apply.
- **A sandboxed front end** cannot write another app's preferences domain; this store is for front ends outside the App Sandbox, as NX2Apple is.

## What a front end cannot see yet

While a game runs, the host says what happens only in its log, as text meant for people: a controller that connects or goes away, the preparing of shaders before the first frame, a red line. A front end that reads the log to show these would break when a line's wording changes. Events a program can read (one JSON object per line, as the NSP script's) would be the next piece of this interface; until then, treat log lines as diagnostics, not as an interface.
