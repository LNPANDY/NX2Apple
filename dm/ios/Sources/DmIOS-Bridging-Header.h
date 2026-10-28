// What Swift sees of the app's Objective-C: the data bookmark the Files app hands out (see
// DataBookmark.h). project.yml points SWIFT_OBJC_BRIDGING_HEADER here.
#import "DataBookmark.h"

// main.m: set when the game data found is an old shard archive (romfs.idx), which is no longer read. The sentence names the
// action (re-send the game data as romfs.img from the launcher), or NULL. The launcher's Game data section shows it.
const char *dm_old_archive_message(void);
