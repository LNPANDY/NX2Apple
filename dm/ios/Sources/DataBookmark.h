// The game data the player picked from the Files app, remembered across launches.
//
// Why this exists: until now the only way to get a game's RomFS onto an iPhone was to copy it into
// the app's Documents through the Files app — which the Files app can do, but only for a folder
// *inside* the app's own container. A player who keeps 16 GB of game data on an external drive or
// in iCloud Drive had to duplicate it into every game's container.
//
// iOS does not allow an app to remember a path outside its sandbox. It allows a *bookmark*: the
// system hands back a token when the player picks a file in the document picker, and the app can
// resolve that token later — even after a relaunch — and keep reading that file. The token is bound
// to the app's signing identity, so a re-signed build (a new sideload, a new team) gets a stale one;
// `stale` below is how that is reported, and the launcher asks the player to pick again rather than
// failing silently.
//
// This file only holds and resolves the bookmark. The picker UI and the call that stores a new one
// are in LauncherSettings.swift, which is where the rest of the player-facing settings live.

#import <Foundation/Foundation.h>

/// The bookmark the player stored, or nil when none was ever picked.
NSData *dm_picked_data_bookmark(void);

/// Resolve the stored bookmark to a path, or nil when there is none or it no longer resolves.
/// `stale` (optional) is set when a bookmark exists but could not be used — the app is not signed
/// the way it was when the player picked, so the picker has to be shown again.
NSString *dm_picked_data_path(BOOL *stale);

/// Store a bookmark for a URL the player just picked. Returns NO when the system refuses to make one.
BOOL dm_store_picked_data(NSURL *url);

/// Forget it (a player who wants the app to go back to its Documents copy).
void dm_clear_picked_data(void);

// Cloud saves (dm/host/save_sync.h): the iCloud Drive folder the player picked in the launcher's
// Cloud saves section, remembered the same way. The host brings the save in from there when the
// game starts and sends it there after each save; the Mac app chooses the same folder in its settings window.

/// The picked folder, or nil; `stale` as for the game data.
NSString *dm_cloud_saves_path(BOOL *stale);

/// Store a bookmark for the folder the player just picked. Returns NO when the system refuses to make one.
BOOL dm_store_cloud_saves(NSURL *url);

/// Forget it: cloud saves off.
void dm_clear_cloud_saves(void);

/// Puts the picked folder into DM_SAVE_SYNC before the game starts (front_ios.m, at Play), its
/// security scope held for the session. A DM_SAVE_SYNC from an env file or the launch environment
/// wins; turning cloud saves off in the launcher clears the one this set.
void dm_cloud_saves_env(void);
