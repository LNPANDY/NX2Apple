// See DataBookmark.h for why this exists.

#import "DataBookmark.h"

static NSString *const kPickedData = @"pickedDataBookmark";

// The one security scope the game data lives under, held from the first resolve on: the host reads
// the image for the whole session, and a scope released after each read would break the game half
// way through. Never stopped on purpose — the process exits when the game does.
static NSURL *openedPick = nil;

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

NSString *dm_picked_data_path(BOOL *stale) {
    if (stale) *stale = NO;
    NSData *bookmark = dm_picked_data_bookmark();
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
        fprintf(stderr, "boot: the picked game-data bookmark does not resolve (%s)\n",
                error.localizedDescription.UTF8String ?: "no reason given");
        if (stale) *stale = YES;
        return nil;
    }
    if (openedPick && ![openedPick.path isEqualToString:url.path]) openedPick = nil;
    if (!openedPick) [url startAccessingSecurityScopedResource];   // held for the session (see openedPick)
    openedPick = url;
    if (isStale) {
        // The system still resolves it but asks for a rewrite (its own wording: stale). Same
        // signature, so a fresh bookmark sticks: self-heal instead of making the player pick again.
        NSData *again = fresh_bookmark(url);
        if (again) [NSUserDefaults.standardUserDefaults setObject:again forKey:kPickedData];
        if (stale) *stale = YES;
    }
    // The picker can hand back a file that was moved or deleted since. The caller checks what it
    // needs (an image, a folder with the marker) and falls through if this path no longer holds it.
    return url.path;
}

BOOL dm_store_picked_data(NSURL *url) {
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
    [NSUserDefaults.standardUserDefaults setObject:bookmark forKey:kPickedData];
    fprintf(stderr, "launcher: game data set to %s\n", url.path.UTF8String ?: "?");
    return YES;
}

void dm_clear_picked_data(void) {
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kPickedData];
}
