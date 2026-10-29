// See DataBookmark.h for why this exists.

#import "DataBookmark.h"

static NSString *const kPickedData = @"pickedDataBookmark", *const kCloudSaves = @"cloudSavesBookmark";

// The one security scope the game data lives under, held from the first resolve on: the host reads
// the image for the whole session, and a scope released after each read would break the game half
// way through. Never stopped on purpose — the process exits when the game does. The cloud-save
// folder's is held the same way: the host writes there after every save.
static NSURL *openedPick = nil, *openedCloud = nil;

NSData *dm_picked_data_bookmark(void) {
    return [NSUserDefaults.standardUserDefaults dataForKey:kPickedData];
}

static NSData *fresh_bookmark(NSURL *url) {
    // The picker grants a security scope that lasts while it is held: the bookmark is written with
    // the scope on. One written without it (or after the grant expired) reads back on this run and
    // resolves to nothing from the next launch on — every pick then looks "signed differently".
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSData *bookmark = [url bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil relativeToURL:nil error:nil];
    if (scoped) [url stopAccessingSecurityScopedResource];
    return bookmark;
}

// One remembered pick: the bookmark under `key` resolved to a path, its scope held in `opened`.
// `what` names it in the log ("game-data", "cloud-save folder").
static NSString *resolve(NSString *key, NSURL *__strong *opened, const char *what, BOOL *stale) {
    if (stale) *stale = NO;
    NSData *bookmark = [NSUserDefaults.standardUserDefaults dataForKey:key];
    if (bookmark.length == 0) return nil;
    BOOL isStale = NO;
    NSError *error = nil;
    NSURL *url = [NSURL URLByResolvingBookmarkData:bookmark
                                           options:0
                                     relativeToURL:nil
                               bookmarkDataIsStale:&isStale
                                             error:&error];
    if (!url) {
        // A re-signed build gets a bookmark the system will not resolve for it. Keep the data —
        // the player may install the same signature again — and let the caller ask for a new pick.
        fprintf(stderr, "boot: the picked %s bookmark does not resolve (%s)\n", what,
                error.localizedDescription.UTF8String ?: "no reason given");
        if (stale) *stale = YES;
        return nil;
    }
    if (*opened && ![(*opened).path isEqualToString:url.path]) *opened = nil;
    if (!*opened) [url startAccessingSecurityScopedResource];   // held for the session (see openedPick)
    *opened = url;
    if (isStale) {
        // The system still resolves it but asks for a rewrite (its own wording: stale). Same
        // signature, so a fresh bookmark sticks: self-heal instead of making the player pick again.
        NSData *again = fresh_bookmark(url);
        if (again) [NSUserDefaults.standardUserDefaults setObject:again forKey:key];
        if (stale) *stale = YES;
    }
    // The picker can hand back a file that was moved or deleted since. The caller checks what it
    // needs (an image, a folder with the marker) and falls through if this path no longer holds it.
    return url.path;
}

NSString *dm_picked_data_path(BOOL *stale) { return resolve(kPickedData, &openedPick, "game-data", stale); }

static BOOL store(NSString *key, NSURL *url, const char *what) {
    NSData *bookmark = fresh_bookmark(url);
    NSError *error = nil;
    NSURL *back = nil;
    if (bookmark) back = [NSURL URLByResolvingBookmarkData:bookmark options:0 relativeToURL:nil bookmarkDataIsStale:nil error:&error];
    if (!bookmark || !back) {
        // A bookmark that cannot come back must not be saved as if it were good: the launcher would
        // greet every start with "the location you picked before is no longer readable".
        fprintf(stderr, "[RED] could not bookmark %s: %s\n", url.path.UTF8String ?: "?",
                error.localizedDescription.UTF8String ?: (bookmark ? "the bookmark does not resolve again" : "no bookmark data"));
        return NO;
    }
    [NSUserDefaults.standardUserDefaults setObject:bookmark forKey:key];
    fprintf(stderr, "launcher: %s set to %s\n", what, url.path.UTF8String ?: "?");
    return YES;
}

BOOL dm_store_picked_data(NSURL *url) { return store(kPickedData, url, "game data"); }

void dm_clear_picked_data(void) {
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kPickedData];
}

NSString *dm_cloud_saves_path(BOOL *stale) { return resolve(kCloudSaves, &openedCloud, "cloud-save folder", stale); }

BOOL dm_store_cloud_saves(NSURL *url) { return store(kCloudSaves, url, "cloud-save folder"); }

void dm_clear_cloud_saves(void) {
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kCloudSaves];
}

void dm_cloud_saves_env(void) {
    static BOOL fromPick;   // DM_SAVE_SYNC is the one this set, not an env file's
    if (getenv("DM_SAVE_SYNC") && !fromPick) return;
    BOOL stale = NO;
    NSString *folder = dm_cloud_saves_path(&stale);
    if (stale && !folder) fprintf(stderr, "boot: the cloud-save folder needs to be chosen again (the app is signed differently now); cloud saves are off\n");
    if (folder.length) {
        setenv("DM_SAVE_SYNC", folder.fileSystemRepresentation, 1); fromPick = YES;
        fprintf(stderr, "boot: cloud saves through %s\n", folder.fileSystemRepresentation);
    } else if (fromPick) { unsetenv("DM_SAVE_SYNC"); fromPick = NO; }
}
