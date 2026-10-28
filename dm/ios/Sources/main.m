// iOS App entry: set the environment (game files, saves, shader libraries), write the host log to Documents/log.txt, create the window (front_ios.m), then run the host's dm_main on a big-stack thread.
// The game files (RomFS) ship inside the App at <App>/romfs; Documents/romfs.img (one image, scripts/push_romfs.sh) or a Documents/romfs folder is also accepted (lets you swap them without reinstalling).
#import <UIKit/UIKit.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "hle_profile.h"   // the runtime game profile (DM_PROFILE): the RomFS marker path comes from it
#include "front.h"
#include "romfs_image.h"
#include "DataBookmark.h"
#include "romfs_identity.h"
#include "player_env.h"
#ifndef DM_PLAYER_BUILD
#define DM_PLAYER_BUILD 0
#endif

extern char **environ;

int dm_main(int argc, char **argv);   // dm/host/main.c compiled in with -Dmain=dm_main
UIViewController *front_ios_root(void);
void front_ios_focus_event(int ev);

static char *g_argv[4]; static int g_argc;

// Documents/romfs.img, one RomFS image file (dm/tools/romfs_image.py, scripts/push_romfs.sh): only a complete one counts. Its index is written last and ends the file, so a copy cut off partway is skipped
static int romfs_image_complete(NSString *path) {
    romfs_img *m = romfs_image_open(path.fileSystemRepresentation);
    if (!m) {
        if (errno != ENOENT) fprintf(stderr, "[RED] boot: invalid RomFS image %s (errno=%d); trying the folders\n", path.fileSystemRepresentation, errno);
        return 0;
    }
    romfs_image_close(m); return 1;
}
// A build made with DM_COPY_ROMFS=NO carries <App>/romfs.id (dm/host/romfs_identity.h): only a Documents/romfs.img with that identity is used. No romfs.id (the default build): any complete image
static int romfs_identity_accepts(NSString *img) {
    romfs_id want, got;
    int rc = romfs_id_check([NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"romfs.id"].fileSystemRepresentation, img.fileSystemRepresentation, &want, &got);
    if (rc != ROMFS_ID_OK && rc != ROMFS_ID_NONE) fprintf(stderr, "[RED] boot: Documents/romfs.img is not the image this build needs (verdict %d); not used\n", rc);
    return rc == ROMFS_ID_OK || rc == ROMFS_ID_NONE;
}
// A folder holds this game's files if it has a ROMFSARC index or the profile's marker path.
// Shared by romfs_locate and the per-game layout below, so both answer the same question.
static BOOL romfs_dir_ok(NSString *d) {
    NSFileManager *fm = NSFileManager.defaultManager;
    // A ROMFSARC archive: <dir>/romfs.idx next to romfs.NN shards. The host opens it when DM_ROMFS
    // points at the base; the marker check does not apply (there are no directories to walk).
    if ([fm fileExistsAtPath:[d stringByAppendingPathComponent:@"romfs.idx"]]) return YES;
    // A plain directory tree: only one containing the game profile's romfs_marker path counts
    // (Mario: System/Resource, the resource size table). Runtime profile: the marker is a profile
    // value now; the compiled macro is only what dm_profile() falls back to without DM_PROFILE.
    return [fm fileExistsAtPath:[d stringByAppendingPathComponent:@(dm_profile()->romfs_marker)]];
}

// Where one game's data lives under the per-game layout: Documents/games/<title ID>/, holding
//   romfs.img   the whole RomFS as one image file (what scripts/push_romfs.sh sends), or
//   romfs/      a ROMFSARC archive or a plain tree, for copies made before images
//   msl/        this game's Metal shader libraries (optional; the app's own dm/ is used otherwise)
//   save/ temp/ this game's saves and scratch space
// The layout exists so several games can share one installed app and so the game data can sit on
// an external drive the Files app exposes (a folder copied there keeps this shape).
static NSString *game_dir_for(const char *title_id) {
    NSString *doc = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
    return [[doc stringByAppendingPathComponent:@"games"] stringByAppendingPathComponent:@(title_id)];
}

static NSString *romfs_locate(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *doc = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
    // What the player picked in the Files app wins over everything: it is the one path they chose
    // on purpose, possibly on an external drive, and it costs nothing when they never picked one
    // (the bookmark is absent and this falls straight through). An image or a folder both work,
    // and a pick that no longer holds this game's data falls through rather than failing the boot.
    {
        BOOL stale = NO;
        NSString *picked = dm_picked_data_path(&stale);
        if (stale) fprintf(stderr, "boot: the picked game-data location needs to be chosen again (the app is signed differently now)\n");
        if (picked.length) {
            if (romfs_image_complete(picked)) { fprintf(stderr, "boot: game data from the picked image %s\n", picked.UTF8String); return picked; }
            NSString *pimg = [picked stringByAppendingPathComponent:@"romfs.img"];
            if (romfs_image_complete(pimg)) { fprintf(stderr, "boot: game data from the picked folder %s\n", pimg.UTF8String); return pimg; }
            if (romfs_dir_ok(picked)) { fprintf(stderr, "boot: game data from the picked folder %s\n", picked.UTF8String); return picked; }
            fprintf(stderr, "boot: the picked location %s holds no game data for this title; using the app's own\n", picked.UTF8String);
        }
    }
    // Per-game first: Documents/games/<id>/romfs.img (one file, what push_romfs.sh sends) or
    // Documents/games/<id>/romfs/ — the launcher-style layout, and what lets a user keep several
    // games' data side by side or on an external drive. The marker check inside romfs_dir_ok is
    // what keeps a stray folder from being taken for this game.
    NSString *gdir = game_dir_for(dm_profile()->id);
    NSString *gimg = [gdir stringByAppendingPathComponent:@"romfs.img"];
    if (romfs_image_complete(gimg)) return gimg;
    NSString *gfolder = [gdir stringByAppendingPathComponent:@"romfs"];
    if ([fm fileExistsAtPath:gfolder] && romfs_dir_ok(gfolder)) return gfolder;
    NSString *img = [doc stringByAppendingPathComponent:@"romfs.img"];
    if (romfs_image_complete(img) && romfs_identity_accepts(img)) {
        // A folder copy from before images is now dead weight of up to many GB (often cut off partway). Deleting its 300,000 files here took longer than iOS allows an app to start
        // (Tears of the Kingdom: killed on a black screen), so it is moved aside at once and deleted in the background, leftovers of an interrupted delete included
        NSString *old = [doc stringByAppendingPathComponent:@"romfs"], *tmp = NSTemporaryDirectory();
        if ([fm fileExistsAtPath:old] && [fm moveItemAtPath:old toPath:[tmp stringByAppendingPathComponent:[@"romfs-old-" stringByAppendingString:NSUUID.UUID.UUIDString]] error:nil])
            fprintf(stderr, "boot: Documents/romfs moved aside for deletion (Documents/romfs.img replaces it)\n");
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
            NSFileManager *bfm = [NSFileManager new];
            for (NSString *n in [bfm contentsOfDirectoryAtPath:tmp error:nil]) if ([n hasPrefix:@"romfs-old-"]) [bfm removeItemAtPath:[tmp stringByAppendingPathComponent:n] error:nil];
        });
        return img;
    }
    NSString *bundledImage = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"romfs.img"];
    NSString *documentFolder = [doc stringByAppendingPathComponent:@"romfs"];
    if ([fm fileExistsAtPath:[documentFolder stringByAppendingPathComponent:@(dm_profile()->romfs_marker)]]) return documentFolder;
    if (romfs_image_complete(bundledImage)) return bundledImage;
    for (NSString *d in @[[doc stringByAppendingPathComponent:@"romfs"], [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"romfs"]])
        if (romfs_dir_ok(d)) return d;
    return nil;
}

// DM_ROMFS plus the save/temp folders that follow its location (the per-game layout only when the
// files came from Documents/games/<id>/). Returns NO when there is no game data yet — not fatal:
// the launcher comes up all the same and its Game data section is where a location gets picked
// (a transfer skipped on the Mac, or data on an external drive), and dm_locate_game_data() asks
// again when the player presses Play. `force` lets the Play-time re-location override what boot
// set: a location picked in the launcher this session must win, while an env file's DM_ROMFS /
// DM_SAVE / DM_TEMP (set before this runs, kept only when absent) keeps winning at boot.
static int set_data_env(NSString *romfs, BOOL force) {
    if (!romfs) return 0;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *doc = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
    fprintf(stderr, "boot: game files %s\n", romfs.fileSystemRepresentation);
    setenv("DM_ROMFS", romfs.fileSystemRepresentation, force);
    // Saves and scratch space: Documents/games/<id>/{save,temp} when the per-game layout is in use
    // (so two games in one app never share a save folder), else the old Documents/{save,temp}. An
    // env file still wins at boot — DM_SAVE/DM_TEMP set there are already in the environment and
    // setenv(..., 0) leaves them alone.
    NSString *gdir = game_dir_for(dm_profile()->id);
    // Tie the data folder to where the game files actually came from: if romfs_locate fell back to
    // Documents/romfs, the saves must stay beside it (a game folder without romfs is not in use).
    BOOL per_game = [romfs hasPrefix:gdir];
    NSString *save_dir = per_game ? [gdir stringByAppendingPathComponent:@"save"] : [doc stringByAppendingPathComponent:@"save"];
    NSString *temp_dir = per_game ? [gdir stringByAppendingPathComponent:@"temp"] : [doc stringByAppendingPathComponent:@"temp"];
    for (NSString *d in @[save_dir, temp_dir]) [fm createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    setenv("DM_SAVE", save_dir.fileSystemRepresentation, force);
    setenv("DM_TEMP", temp_dir.fileSystemRepresentation, force);
    if (per_game) fprintf(stderr, "boot: per-game data folder %s\n", gdir.fileSystemRepresentation);
    return 1;
}

// front_ios.m calls this from the launcher's Play: (re)decide where the game data is — a location
// picked in the launcher this session takes effect at once — and NO when there still is none, so
// the launcher comes back instead of the game failing inside the host.
int dm_locate_game_data(void) { return set_data_env(romfs_locate(), YES); }

// Boot prerequisites (done before UIApplicationMain): directories / environment variables / log -- the host's early load reads these
// Why a slim build found no usable game files: the verdict on Documents/romfs.img, in the log and for the screen (front_ios_boot_message). NULL when the build has no romfs.id
static char g_boot_message[640];
const char *front_ios_boot_message(void) { return g_boot_message[0] ? g_boot_message : NULL; }
static void romfs_identity_report(NSString *doc) {
    romfs_id want, got;
    int rc = romfs_id_check([NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"romfs.id"].fileSystemRepresentation,
                            [doc stringByAppendingPathComponent:@"romfs.img"].fileSystemRepresentation, &want, &got);
    if (rc == ROMFS_ID_OK || rc == ROMFS_ID_NONE) return;
    romfs_id_message(rc, &want, &got, NSBundle.mainBundle.bundleIdentifier.UTF8String ?: "<bundle ID>", g_boot_message, sizeof g_boot_message);
    fprintf(stderr, "[RED] boot: %s\n", g_boot_message);
}

static int boot_env(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *doc = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
    NSString *res = NSBundle.mainBundle.resourcePath;
    for (NSString *d in @[@"save", @"temp"]) [fm createDirectoryAtPath:[doc stringByAppendingPathComponent:d] withIntermediateDirectories:YES attributes:nil error:nil];
    // Keep game files and scratch data out of device backups (Documents is backed up by default; a RomFS placed there is many GB). Saves, logs and the pipeline list stay in the backup
    for (NSString *d in @[@"romfs", @"romfs.img", @"temp"]) {
        NSURL *u = [NSURL fileURLWithPath:[doc stringByAppendingPathComponent:d]]; NSError *e = nil;
        if ([fm fileExistsAtPath:u.path] && ![u setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:&e]) fprintf(stderr, "boot: %s could not be excluded from backup: %s\n", d.UTF8String, e.localizedDescription.UTF8String);
    }
    // Log: the host only writes to stderr; redirect it to Documents/log.txt (the previous one is kept as log.prev.txt), retrieve it from the Files app when something goes wrong
    NSString *log = [doc stringByAppendingPathComponent:@"log.txt"], *prev = [doc stringByAppendingPathComponent:@"log.prev.txt"];
    [fm removeItemAtPath:prev error:nil]; [fm moveItemAtPath:log toPath:prev error:nil];
    if (freopen(log.fileSystemRepresentation, "w", stderr)) setvbuf(stderr, NULL, _IOLBF, 0);
    // First line of the log: the fork's patches this build carries (Info.plist DMForkPatches), so a report says whether it comes from a build beyond upstream's support
    NSString *fork_patches = [NSBundle.mainBundle objectForInfoDictionaryKey:@"DMForkPatches"];
    fprintf(stderr, "fork patches: %s\n", [fork_patches isKindOfClass:NSString.class] && fork_patches.length ? fork_patches.UTF8String : "none");
    // Environment switch files (for on-device diagnostics: a sideloaded app cannot be given environment variables from outside): one KEY=VALUE per line, # starts a comment; Documents/env.txt takes precedence over dm/env.txt in the bundle (put there by build_ipa.sh's DM_ENV_FILE)
    NSMutableArray<NSString *> *from_file = [NSMutableArray array], *from_launch = [NSMutableArray array];
    for (char **e = environ; *e; e++) {   // set at launch (Xcode, devicectl): before the env files, and the launcher keeps them
        const char *eq = strchr(*e, '='); NSString *k = eq && !strncmp(*e, "DM_", 3) ? [[NSString alloc] initWithBytes:*e length:(NSUInteger)(eq - *e) encoding:NSUTF8StringEncoding] : nil;
        if (k) [from_launch addObject:k];
    }
#if DM_PLAYER_BUILD
    // Player-facing choices belong to the launcher, including saved choices.
    // Neither old diagnostic files nor bundled defaults may lock those rows.
    NSMutableSet<NSString *> *launcher_keys = [NSMutableSet set];
    NSData *settings_data = [NSData dataWithContentsOfFile:[res stringByAppendingPathComponent:@"dm/launcher.json"]];
    NSDictionary *settings_file = settings_data ? [NSJSONSerialization JSONObjectWithData:settings_data options:0 error:nil] : nil;
    for (NSDictionary *row in settings_file[@"settings"]) if ([row[@"env"] isKindOfClass:NSString.class]) [launcher_keys addObject:row[@"env"]];
#endif
    for (NSString *ef in @[[doc stringByAppendingPathComponent:@"env.txt"], [[res stringByAppendingPathComponent:@"dm"] stringByAppendingPathComponent:@"env.txt"]]) {
        NSString *txt = [NSString stringWithContentsOfFile:ef encoding:NSUTF8StringEncoding error:nil];
        for (NSString *raw in [txt componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
            NSString *ln = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]; NSRange eq = [ln rangeOfString:@"="];
            if (!ln.length || [ln hasPrefix:@"#"] || eq.location == NSNotFound || !eq.location) continue;
            NSString *k = [ln substringToIndex:eq.location], *v = [ln substringFromIndex:eq.location + 1];
#if DM_PLAYER_BUILD
            if (dm_player_diagnostic_key(k.UTF8String) || [launcher_keys containsObject:k] ||
                ([launcher_keys containsObject:@"DM_METAL_HUD"] && [k isEqualToString:@"MTL_HUD_ENABLED"])) continue;
#endif
            if (!getenv(k.UTF8String)) { setenv(k.UTF8String, v.UTF8String, 0); [from_file addObject:k]; fprintf(stderr, "boot: env %s=%s (%s)\n", k.UTF8String, v.UTF8String, ef.lastPathComponent.UTF8String); }
        }
    }
    setenv("DM_ENV_FILE_KEYS", [from_file componentsJoinedByString:@" "].UTF8String, 1);   // the launcher keeps what an env file set (LauncherSettings.swift)
    setenv("DM_ENV_LAUNCH_KEYS", [from_launch componentsJoinedByString:@" "].UTF8String, 1);   // and what the launch environment set (docs/frontends.md, Saved choices)
    front_hud_env();   // before the early loading below can make a device
    // Game language (nn::oe::GetDesiredLanguage, hle_oe.c): the one the IPA was packed with (the NSP script's LANGUAGE / --language → DMLanguage in Info.plist), unless an env file sets DM_LANG
    // (or the launcher, which replaces this default before the game starts)
    NSString *lang = [NSBundle.mainBundle objectForInfoDictionaryKey:@"DMLanguage"];
    if (!getenv("DM_LANG") && [lang isKindOfClass:NSString.class] && lang.length) setenv("DM_LANG", lang.UTF8String, 0);
    fprintf(stderr, "boot: game language %s\n", getenv("DM_LANG") ?: "en-US");
    // No game data yet is not fatal: the launcher comes up all the same, and its Game data section
    // is where a location gets picked; dm_locate_game_data() looks again when Play is pressed.
    NSString *gdir = game_dir_for(dm_profile()->id);
    NSString *romfs = romfs_locate();
    BOOL per_game = [romfs hasPrefix:gdir];   // messaging nil is NO here: no data means the shared layout
    if (!set_data_env(romfs, NO)) { if (!romfs) romfs_identity_report(doc);   // a slim build says why its romfs.img was not used
        fprintf(stderr, "boot: no game data yet (Documents/romfs.img, Documents/romfs or <App>/romfs); the launcher asks for it\n"); }
    NSString *dm = [res stringByAppendingPathComponent:@"dm"];
    setenv("DM_NVN_SHMAP", [dm stringByAppendingPathComponent:@"shader_map.tsv"].fileSystemRepresentation, 0);
    // Shader libraries: a game's own <gdir>/msl first (a per-game layout may carry its own), else
    // the app's shared <App>/msl.
    NSString *per_game_msl = [gdir stringByAppendingPathComponent:@"msl"];
    NSString *msl = (per_game && [fm fileExistsAtPath:per_game_msl]) ? per_game_msl : [res stringByAppendingPathComponent:@"msl"];
    setenv("DM_MSL_DIR", msl.fileSystemRepresentation, 0);
    setenv("DM_FONT_DIR", [dm stringByAppendingPathComponent:@"font"].fileSystemRepresentation, 0);   // Shared-font stand-ins (standard.ttf / nintendo_ext.ttf): iOS lacks the macOS font path
    NSString *aoc = [res stringByAppendingPathComponent:@"aoc"];   // add-on content: build_ipa.sh puts the RomFS extracted from the player's DLC NSPs at <App>/aoc/<index>/
    if ([fm fileExistsAtPath:aoc]) setenv("DM_AOC_DIR", aoc.fileSystemRepresentation, 0);
    NSString *pso = [res stringByAppendingPathComponent:@"pso"];   // the pipeline archive made offline (build_ipa.sh, dm/gfx/tools/pso_offline.py): the shader pairs' bases, which the device then does not build
    if ([fm fileExistsAtPath:pso]) setenv("DM_PSO_BUNDLE", pso.fileSystemRepresentation, 0);
    chdir(doc.fileSystemRepresentation);
    g_argv[0] = strdup("dmhost"); g_argv[1] = strdup(dm.fileSystemRepresentation); g_argc = 2;
    dm_host_preload_start(g_argc, g_argv);   // Module tables / relocation / takeover run early in the background, in parallel with UIKit startup (and the launcher: the settings it sets are read when the game starts)
    return 1;
}
static int g_boot_ok;

static void *boot_thread(void *p) {
    (void)p;
    static char alt[65536]; stack_t ss = {.ss_sp = alt, .ss_size = sizeof alt}; sigaltstack(&ss, 0);   // crash printing must work on the host thread too
    int rc = dm_main(g_argc, g_argv);
    fprintf(stderr, "boot: dm_main returned %d\n", rc);
    return NULL;
}
void front_ios_boot(void) {   // Called by front_ios.m once the window and Metal view exist
    static int once; if (once++ || !g_boot_ok) return;
    void front_ios_audio_session(void); front_ios_audio_session();   // set a short I/O buffer before the game opens audio output (front_ios.m)
    pthread_attr_t a; pthread_attr_init(&a); pthread_attr_setstacksize(&a, 64u << 20);   // the Switch main thread stack is set by npdm; the host gives plenty
    pthread_t t; pthread_create(&t, &a, boot_thread, NULL); pthread_detach(t);
}
int front_ios_boot_ok(void) { return g_boot_ok; }

@interface App : UIResponder <UIApplicationDelegate>
@end
@implementation App
- (UISceneConfiguration *)application:(UIApplication *)a configurationForConnectingSceneSession:(UISceneSession *)s options:(UISceneConnectionOptions *)o {
    return [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:s.role];
}
@end

// Scene lifecycle: create the window + hand focus events to front_ios.m
@interface SceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (strong, nonatomic) UIWindow *window;
@end
@implementation SceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)o {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = front_ios_root();
    [self.window makeKeyAndVisible];
}
- (void)sceneWillResignActive:(UIScene *)s { front_ios_focus_event(0); }
- (void)sceneDidEnterBackground:(UIScene *)s { front_ios_focus_event(1); }
- (void)sceneWillEnterForeground:(UIScene *)s { front_ios_focus_event(2); }
- (void)sceneDidBecomeActive:(UIScene *)s { front_ios_focus_event(3); }
@end

int main(int argc, char **argv) {
    @autoreleasepool { g_boot_ok = boot_env(); }
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(App.class)); }
}
