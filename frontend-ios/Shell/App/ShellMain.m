// Route C shell (docs/launcher-c-plan.md M2, LNPANDY/NX2Apple#451): the app that hosts several games' frameworks. It starts on the
// library (frontend-ios's ShellHost views, ShellApp.swift) instead of booting a game at launch as dm/ios/Sources/main.m does, and
// when the player presses Play, dm_shell_start_game() sets the log and the environment (EngineLaunchPlan in ShellHost computes it),
// dlopens the chosen game's DmGame<title ID>.framework (which links its own dm/host, front_ios.m and shaders), and calls its
// dm_glue_start_game() entry point (ShellGlue.h, framework/ShellGlue.m). dm_shell_present_game() then hands the window to the
// framework's dm_glue_present_game(), which shows front_ios.m's game view and starts dm_main on the big-stack thread.
// When the player quits from the in-game prompt, dm_shell_return_to_library() restores the framework's writable data segments and returns the window to the library.
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <mach-o/getsect.h>
#include <mach-o/ldsyms.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include "SegSnap.h"
#include "ShellEngine.h"
#include "ShellGlue.h"
#import "DmShell-Swift.h"

extern char **environ;

typedef struct {
    const void *fbase;
    DmSegSnap seg[2];
} DmFwSnap;

static dm_glue_present_fn g_present;
static dm_glue_focus_fn g_focus;
static UIViewController *g_library_vc;
static char g_active_exe[1024];
static const void *g_active_fbase;
static DmFwSnap g_fw_snaps[64];
static int g_nfw_snaps;
static int g_boot_ok;

static NSString *documents(void) { return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0]; }

static void clear_game_env(void) {
    if (!environ) return;
    char names[256][128];
    int count = 0;
    for (char **ep = environ; *ep && count < 256; ep++) {
        const char *kv = *ep;
        if (strncmp(kv, "DM_", 3) != 0) continue;
        const char *eq = strchr(kv, '=');
        if (!eq) continue;
        size_t len = (size_t)(eq - kv);
        if (len == 0 || len >= sizeof(names[0])) continue;
        if ((len == strlen("DM_HUD_PER_LAYER") && !strncmp(kv, "DM_HUD_PER_LAYER", len)) ||
            (len == strlen("DM_SHELL_PLAY") && !strncmp(kv, "DM_SHELL_PLAY", len))) {
            continue;
        }
        memcpy(names[count], kv, len);
        names[count][len] = '\0';
        count++;
    }
    for (int i = 0; i < count; i++) unsetenv(names[i]);
}

static void save_framework_data(const void *fbase) {
    if (!fbase) return;
    for (int i = 0; i < g_nfw_snaps; i++) if (g_fw_snaps[i].fbase == fbase) return;
    if (g_nfw_snaps >= 64) return;
    const struct mach_header_64 *mh = (const struct mach_header_64 *)fbase;
    DmFwSnap *s = &g_fw_snaps[g_nfw_snaps++];
    memset(s, 0, sizeof *s);
    s->fbase = fbase;
    dm_seg_snap_save(mh, "__DATA", &s->seg[0]);
    dm_seg_snap_save(mh, "__DATA_DIRTY", &s->seg[1]);
    fprintf(stderr, "shell: saved framework state for %p (__data=%#zx, __common=%#zx, __bss=%#zx with %zu initial non-zero words)\n",
            fbase, s->seg[0].data_sz + s->seg[1].data_sz, s->seg[0].common_sz + s->seg[1].common_sz,
            s->seg[0].bss_sz + s->seg[1].bss_sz, s->seg[0].bss_nnz + s->seg[1].bss_nnz);
}

static void restore_framework_data(const void *fbase) {
    if (!fbase) return;
    DmFwSnap *s = NULL;
    for (int i = 0; i < g_nfw_snaps; i++) if (g_fw_snaps[i].fbase == fbase) { s = &g_fw_snaps[i]; break; }
    if (!s) return;
    dm_seg_snap_restore(&s->seg[0]);
    dm_seg_snap_restore(&s->seg[1]);
    fprintf(stderr, "shell: restored framework state for %p\n", fbase);
}

__attribute__((used, visibility("default")))
void dm_shell_return_to_library(void) {
    dispatch_block_t work = ^{
        char finished_exe[1024];
        strlcpy(finished_exe, g_active_exe, sizeof finished_exe);
        const void *fbase = g_active_fbase;
        g_active_fbase = NULL;
        g_active_exe[0] = '\0';
        g_focus = NULL;
        g_present = NULL;
        g_boot_ok = 0;
        if (fbase) restore_framework_data(fbase);
        UIWindow *window = nil;
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
            if ([s isKindOfClass:UIWindowScene.class]) for (UIWindow *w in ((UIWindowScene *)s).windows) if (w.isKeyWindow || !window) window = w;
        if (window && g_library_vc) {
            window.traitOverrides.preferredContentSizeCategory = UIContentSizeCategoryUnspecified;
            window.rootViewController = g_library_vc;
            [g_library_vc setNeedsUpdateOfSupportedInterfaceOrientations];
            if (@available(iOS 16.0, *)) {
                [window.windowScene requestGeometryUpdateWithPreferences:[[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:UIInterfaceOrientationMaskAllButUpsideDown] errorHandler:nil];
            }
        }
        NSString *slog = [documents() stringByAppendingPathComponent:@"shell-log.txt"];
        fflush(stderr);
        if (freopen(slog.fileSystemRepresentation, "a", stderr)) setvbuf(stderr, NULL, _IOLBF, 0);
        fprintf(stderr, "shell: returned to library from %s\n", finished_exe);
    };
    if ([NSThread isMainThread]) work();
    else dispatch_async(dispatch_get_main_queue(), work);
}

// One log file per run, the previous one kept beside it (<name>.prev.txt): the shell's own lines go to Documents/shell-log.txt until a
// game starts, the game's (the host's stderr) to Documents/log.txt, the file the per-game app writes and the issue forms ask for.
static void log_to(NSString *log) {
    NSString *prev = [[log stringByDeletingPathExtension] stringByAppendingString:@".prev.txt"];
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm removeItemAtPath:prev error:nil]; [fm moveItemAtPath:log toPath:prev error:nil];
    fflush(stderr);
    if (freopen(log.fileSystemRepresentation, "w", stderr)) setvbuf(stderr, NULL, _IOLBF, 0);
    NSString *fork_patches = [NSBundle.mainBundle objectForInfoDictionaryKey:@"DMForkPatches"];
    fprintf(stderr, "fork patches: %s\n", [fork_patches isKindOfClass:NSString.class] && fork_patches.length ? fork_patches.UTF8String : "none");
}

const char *dm_shell_start_game(const char *const *keys, const char *const *values, int n, const char *const *argv, int argc,
                                const char *executable, const char *marker, const char *log_path, const char *cwd) {
    static char err[512];
    if (g_boot_ok) return "A game is already running.";
    if (argc < 2 || !executable) return "The game's start arguments are incomplete.";
    clear_game_env();
    log_to(@(log_path));
    fprintf(stderr, "shell: starting %s (%s)\n", argv[1], executable);
    for (int i = 0; i < n; i++) {
        setenv(keys[i], values[i], 1);
        fprintf(stderr, "boot: %s=%s\n", keys[i], values[i]);   // every one: a report then shows which of the game's settings reached the engine
    }
    if (cwd && *cwd) chdir(cwd);
    // dlopen + dlsym + dladdr verify the framework's image and find its own host's entry points (ShellGlue.h, framework/ShellGlue.m),
    // after the environment is set and before the framework's host starts loading.
    void *h = dlopen(executable, RTLD_LAZY | RTLD_LOCAL);
    if (!h) {
        snprintf(err, sizeof err, "The game's code could not be loaded: %s", dlerror() ?: "no reason given");
        fprintf(stderr, "[RED] boot: dlopen %s failed: %s\n", executable, err);
        return err;
    }
    dlerror();
    void *sym = dlsym(h, marker);
    Dl_info info;
    if (!sym || !dladdr(sym, &info) || !info.dli_fbase) {
        snprintf(err, sizeof err, "The game's code is damaged (no %s symbol). Install the game again.", marker);
        fprintf(stderr, "[RED] boot: %s: %s\n", executable, err);
        return err;
    }
    const int *ver = dlsym(h, "dm_glue_version");
    dm_glue_start_fn start = (dm_glue_start_fn)dlsym(h, "dm_glue_start_game");
    dm_glue_present_fn present = (dm_glue_present_fn)dlsym(h, "dm_glue_present_game");
    dm_glue_focus_fn focus = (dm_glue_focus_fn)dlsym(h, "dm_glue_focus_event");
    if (!ver || *ver != DM_GLUE_VERSION || !start || !present || !focus) {
        snprintf(err, sizeof err, "This game's framework was built without its host (glue version %d, expected %d). Rebuild the game in the launcher.",
                 ver ? *ver : 0, DM_GLUE_VERSION);
        fprintf(stderr, "[RED] boot: %s: %s\n", executable, err);
        return err;
    }
    fprintf(stderr, "boot: game framework %s (handle %p, image base %p, glue v%d)\n", executable, h, info.dli_fbase, *ver);
    save_framework_data(info.dli_fbase);
    const char *why = start(argv, argc, info.dli_fbase);
    if (why) {
        snprintf(err, sizeof err, "%s", why);
        fprintf(stderr, "[RED] boot: %s: %s\n", executable, err);
        restore_framework_data(info.dli_fbase);
        return err;
    }
    strlcpy(g_active_exe, executable, sizeof g_active_exe);
    g_active_fbase = info.dli_fbase;
    g_present = present;
    g_focus = focus;
    g_boot_ok = 1;
    return NULL;
}

void dm_shell_present_game(void) {
    UIWindow *window = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
        if ([s isKindOfClass:UIWindowScene.class]) for (UIWindow *w in ((UIWindowScene *)s).windows) if (w.isKeyWindow || !window) window = w;
    if (!window || !g_present) { fprintf(stderr, "[RED] shell: no window for the game view\n"); return; }
    g_present((__bridge void *)window);
}

@interface App : UIResponder <UIApplicationDelegate>
@end
// Browsing may be portrait; phone gameplay stays landscape. UIKit manages unrestricted rotation on the Duo inner display.
static UIInterfaceOrientationMask shell_orientations(UITraitCollection *traits) {
    if (traits.userInterfaceIdiom != UIUserInterfaceIdiomPhone) return UIInterfaceOrientationMaskAll;
    return g_boot_ok ? UIInterfaceOrientationMaskLandscape : UIInterfaceOrientationMaskAllButUpsideDown;
}
@implementation App
- (UIInterfaceOrientationMask)application:(UIApplication *)application supportedInterfaceOrientationsForWindow:(UIWindow *)window {
    return shell_orientations(window.traitCollection);   // iOS 26
}
- (UISceneConfiguration *)application:(UIApplication *)a configurationForConnectingSceneSession:(UISceneSession *)s options:(UISceneConnectionOptions *)o {
    return [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:s.role];
}
@end

@interface SceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (strong, nonatomic) UIWindow *window;
@end
@implementation SceneDelegate
- (UIInterfaceOrientationMask)supportedInterfaceOrientationsForWindowScene:(UIWindowScene *)windowScene {
    return shell_orientations(windowScene.traitCollection);   // iOS 27 and later
}
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)o {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    g_library_vc = [ShellLibrary makeController];
    self.window.rootViewController = g_library_vc;
    [self.window makeKeyAndVisible];
}
// Forwarded to the running game framework's front_ios.m once a game has started
- (void)sceneWillResignActive:(UIScene *)s { (void)s; if (g_focus) g_focus(0); }
- (void)sceneDidEnterBackground:(UIScene *)s { (void)s; if (g_focus) g_focus(1); }
- (void)sceneWillEnterForeground:(UIScene *)s { (void)s; if (g_focus) g_focus(2); }
- (void)sceneDidBecomeActive:(UIScene *)s { (void)s; if (g_focus) g_focus(3); }
@end

// The performance HUD (the per-game setting DM_METAL_HUD) needs MTL_HUD_ENABLED in the environment before Metal starts in this
// process, and the library's views start it long before Play: set at Play it comes too late and the HUD stays off. So the shell turns
// Metal's HUD on for every start, here before UIApplicationMain, and the game's own setting decides at Play: front_ios.m sets the game
// layer's developerHUDProperties mode to default, or with DM_HUD_PER_LAYER to disabled. A change of the setting in the library applies
// at the next Play, as every other setting does (verified on an iPhone 2026-10-30: on and off in one start each, no HUD over the
// library). MTL_HUD_HIDE_METALFX_METRICS stays unset, so the HUD shows MetalFX's rows (input and output size) while the Upscaling
// setting MetalFX scales the picture.
static void metal_hud_per_layer(void) {
    if (getenv("MTL_HUD_ENABLED")) { fprintf(stderr, "shell: MTL_HUD_ENABLED given at launch, the HUD follows it\n"); return; }   // Xcode, devicectl: it wins
    setenv("MTL_HUD_ENABLED", "1", 1);
    setenv("DM_HUD_PER_LAYER", "1", 1);
    fprintf(stderr, "shell: Metal's HUD is ready, each game's Performance HUD setting turns it on at Play\n");
}

int main(int argc, char **argv) {
    @autoreleasepool {
        log_to([documents() stringByAppendingPathComponent:@"shell-log.txt"]);
        NSDictionary *info = NSBundle.mainBundle.infoDictionary;
        fprintf(stderr, "shell: %s %s, commit %s, shader chain %s, iOS %s\n", [info[@"CFBundleIdentifier"] UTF8String], [info[@"CFBundleShortVersionString"] UTF8String] ?: "?",
                [info[@"DMCommit"] UTF8String] ?: "not recorded", [info[@"DMChain"] UTF8String] ?: "?", UIDevice.currentDevice.systemVersion.UTF8String);
        // Free space where the game data goes: the Mac launcher reads this line before it copies a game's data (many GB)
        NSNumber *avail = [[NSURL fileURLWithPath:documents()] resourceValuesForKeys:@[NSURLVolumeAvailableCapacityForImportantUsageKey] error:nil][NSURLVolumeAvailableCapacityForImportantUsageKey];
        fprintf(stderr, "shell: free space %lld bytes\n", avail ? avail.longLongValue : -1LL);
        for (NSString *fw in [NSFileManager.defaultManager contentsOfDirectoryAtPath:NSBundle.mainBundle.privateFrameworksPath error:nil])
            fprintf(stderr, "shell: framework %s\n", fw.UTF8String);
        metal_hud_per_layer();
    }
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(App.class)); }
}
