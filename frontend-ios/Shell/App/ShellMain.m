// Route C shell (docs/launcher-c-plan.md M2, LNPANDY/NX2Apple#451): the app that hosts several games' frameworks. It starts on the
// library (frontend-ios's ShellHost views, ShellApp.swift) instead of booting a game at launch as dm/ios/Sources/main.m does, and
// when the player presses Play, dm_shell_start_game() sets the log and the environment (EngineLaunchPlan in ShellHost computes it),
// dlopens the chosen game's DmGame<title ID>.framework (which links its own dm/host, front_ios.m and shaders), and calls its
// dm_glue_start_game() entry point (ShellGlue.h, framework/ShellGlue.m). dm_shell_present_game() then hands the window to the
// framework's dm_glue_present_game(), which shows front_ios.m's game view and starts dm_main on the big-stack thread.
// When the player quits from the in-game prompt, dm_shell_return_to_library() restores the framework's writable data segments and returns the window to the library.
#import <UIKit/UIKit.h>
@import GameController;
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#include <os/proc.h>
#endif
#include <arpa/inet.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <mach-o/fat.h>
#include <mach-o/getsect.h>
#include <mach-o/ldsyms.h>
#include <mach-o/loader.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include "SegSnap.h"
#include "ShellEngine.h"
#include "ShellGlue.h"
#include "ShellSnap.h"
#import "DmShell-Swift.h"

_Static_assert(DM_SHELL_GLUE_VERSION == DM_GLUE_VERSION, "DM_SHELL_GLUE_VERSION must match DM_GLUE_VERSION");

extern char **environ;

typedef struct {
    const void *fbase;
    char game_key[128];
    char exe_path[1024];
    time_t mtime;
    DmSegSnap seg[2];
} DmFwSnap;

static dm_glue_present_fn g_present;
static dm_glue_focus_fn g_focus;
static UIViewController *g_library_vc;
static char g_active_exe[1024];
static char g_active_game_id[64];
static const void *g_active_fbase;
static DmFwSnap g_fw_snaps[64];
static int g_nfw_snaps;
static int g_boot_ok;

// Orthogonal foreground/background and Bluetooth controller disconnect auto-pause state (main thread only).
// g_engine_level tracks the exact focus tier already delivered to front_ios.m: 0 = active, 1 = resigned, 2 = suspended.
static int g_app_resigned;
static int g_app_bg;
static int g_engine_level;
static int g_had_pad;
static int g_dc_paused;
static int g_dc_enabled = 1;
static uint64_t g_dc_gen;
static id g_dc_conn_obs;
static id g_dc_disc_obs;
static UIView *g_dc_overlay;

static void shell_sync_focus(void) {
    if (!g_boot_ok || !g_focus) return;
    int want = (g_dc_paused || g_app_bg) ? 2 : (g_app_resigned ? 1 : 0);
    if (g_engine_level < want) {
        if (g_engine_level == 0 && want >= 1) { g_focus(0); g_engine_level = 1; }
        if (g_engine_level == 1 && want >= 2) { g_focus(1); g_engine_level = 2; }
    } else if (g_engine_level > want) {
        if (g_engine_level == 2 && want <= 1) { g_focus(2); g_engine_level = 1; }
        if (g_engine_level == 1 && want <= 0) { g_focus(3); g_engine_level = 0; }
    }
}

static UIWindow *shell_key_window(void) {
    UIWindow *window = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if ([s isKindOfClass:UIWindowScene.class]) {
            for (UIWindow *w in ((UIWindowScene *)s).windows) {
                if (w.isKeyWindow || !window) window = w;
            }
        }
    }
    return window;
}

static int is_physical_pad(GCController *c) {
    return c && (c.extendedGamepad != nil || c.microGamepad != nil);
}

static int active_physical_pad_count(GCController *including, GCController *excluding) {
    int count = 0;
    int saw_including = 0;
    for (GCController *c in GCController.controllers) {
        if (excluding && c == excluding) continue;
        if (is_physical_pad(c)) count++;
        if (including && c == including) saw_including = 1;
    }
    if (including && !saw_including && including != excluding && is_physical_pad(including)) count++;
    return count;
}

static void dc_remove_overlay(void) {
    if (!g_dc_overlay) return;
    UIView *overlay = g_dc_overlay;
    g_dc_overlay = nil;
    [overlay removeFromSuperview];
}

static void dc_resume_game(const char *why) {
    if (!g_dc_paused) return;
    g_dc_paused = 0;
    g_dc_gen++;
    dc_remove_overlay();
    fprintf(stderr, "shell: controller disconnect pause ended (%s)\n", why);
    shell_sync_focus();
}

static void dc_show_overlay(void) {
    dc_remove_overlay();
    UIWindow *window = shell_key_window();
    if (!window) return;

    UIView *scrim = [[UIView alloc] initWithFrame:window.bounds];
    scrim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    scrim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.62];
    scrim.alpha = 0;

    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark];
    UIVisualEffectView *card = [[UIVisualEffectView alloc] initWithEffect:blur];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.layer.cornerRadius = 24;
    card.layer.masksToBounds = YES;
    card.layer.borderWidth = 1;
    card.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.14].CGColor;

    UIImageSymbolConfiguration *iconCfg = [UIImageSymbolConfiguration configurationWithPointSize:34 weight:UIImageSymbolWeightMedium];
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"gamecontroller.fill" withConfiguration:iconCfg]];
    icon.tintColor = [UIColor colorWithWhite:1 alpha:0.92];
    icon.contentMode = UIViewContentModeScaleAspectFit;

    UILabel *title = [UILabel new];
    title.text = [ShellRuntimeBridge controllerDisconnectTitle];
    title.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
    title.textColor = UIColor.whiteColor;
    title.textAlignment = NSTextAlignmentCenter;
    title.numberOfLines = 2;

    UILabel *message = [UILabel new];
    message.text = [ShellRuntimeBridge controllerDisconnectMessage];
    message.font = [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
    message.textColor = [UIColor colorWithWhite:1 alpha:0.78];
    message.textAlignment = NSTextAlignmentCenter;
    message.numberOfLines = 0;

    UIButtonConfiguration *btnCfg = [UIButtonConfiguration filledButtonConfiguration];
    btnCfg.title = [ShellRuntimeBridge controllerDisconnectResumeTitle];
    btnCfg.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    btnCfg.baseBackgroundColor = [UIColor colorWithRed:0.96 green:0.93 blue:0.86 alpha:1.0];
    btnCfg.baseForegroundColor = [UIColor colorWithWhite:0.08 alpha:1.0];
    btnCfg.contentInsets = NSDirectionalEdgeInsetsMake(12, 28, 12, 28);
    UIButton *resumeBtn = [UIButton buttonWithConfiguration:btnCfg primaryAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
        (void)action;
        dc_resume_game("Resume tapped");
    }]];
    resumeBtn.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[icon, title, message, resumeBtn]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 12;
    [stack setCustomSpacing:18 afterView:message];
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    [card.contentView addSubview:stack];
    [scrim addSubview:card];
    [window addSubview:scrim];

    [NSLayoutConstraint activateConstraints:@[
        [card.centerXAnchor constraintEqualToAnchor:scrim.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:scrim.centerYAnchor],
        [card.widthAnchor constraintLessThanOrEqualToConstant:360],
        [card.leadingAnchor constraintGreaterThanOrEqualToAnchor:scrim.safeAreaLayoutGuide.leadingAnchor constant:24],
        [card.trailingAnchor constraintLessThanOrEqualToAnchor:scrim.safeAreaLayoutGuide.trailingAnchor constant:-24],
        [stack.topAnchor constraintEqualToAnchor:card.contentView.topAnchor constant:24],
        [stack.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor constant:-24],
        [stack.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor constant:-24],
        [resumeBtn.widthAnchor constraintGreaterThanOrEqualToConstant:160],
    ]];

    g_dc_overlay = scrim;
    [UIView animateWithDuration:0.18 animations:^{ scrim.alpha = 1; }];
}

static void dc_teardown(void) {
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    if (g_dc_conn_obs) { [nc removeObserver:g_dc_conn_obs]; g_dc_conn_obs = nil; }
    if (g_dc_disc_obs) { [nc removeObserver:g_dc_disc_obs]; g_dc_disc_obs = nil; }
    g_dc_gen++;
    g_dc_paused = 0;
    g_had_pad = 0;
    dc_remove_overlay();
}

static void dc_arm_observers(void) {
    dc_teardown();
    const char *env = getenv("DM_DISCONNECT_PAUSE");
    g_dc_enabled = !(env && !strcmp(env, "0"));
    if (!g_dc_enabled) {
        fprintf(stderr, "shell: controller disconnect auto-pause disabled (DM_DISCONNECT_PAUSE=0)\n");
        return;
    }
    g_had_pad = active_physical_pad_count(nil, nil) > 0 ? 1 : 0;
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    g_dc_conn_obs = [nc addObserverForName:GCControllerDidConnectNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        if (!g_boot_ok) return;
        GCController *joined = [n.object isKindOfClass:GCController.class] ? (GCController *)n.object : nil;
        if (active_physical_pad_count(joined, nil) <= 0) return;
        g_had_pad = 1;
        g_dc_gen++;
        if (g_dc_paused) dc_resume_game("controller reconnected");
    }];
    g_dc_disc_obs = [nc addObserverForName:GCControllerDidDisconnectNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        if (!g_boot_ok || !g_dc_enabled || !g_had_pad || g_dc_paused) return;
        GCController *gone = [n.object isKindOfClass:GCController.class] ? (GCController *)n.object : nil;
        if (active_physical_pad_count(nil, gone) > 0) return;
        uint64_t gen = ++g_dc_gen;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (gen != g_dc_gen || !g_boot_ok || g_app_bg || g_app_resigned || g_dc_paused) return;
            if (active_physical_pad_count(nil, nil) > 0) return;
            g_dc_paused = 1;
            fprintf(stderr, "shell: all physical controllers disconnected for 3 s, pausing game\n");
            shell_sync_focus();
            dc_show_overlay();
        });
    }];
}

void dm_shell_purge_memory(int limit_mb) {
#if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
    if (limit_mb <= 0) return;
    const size_t reserve_bytes = 1200ULL * 1024ULL * 1024ULL;
    const size_t chunk_bytes = 64ULL * 1024ULL * 1024ULL;
    const size_t max_chunks = 128;
    size_t want_chunks = ((size_t)limit_mb * 1024ULL * 1024ULL) / chunk_bytes;
    if (want_chunks > max_chunks) want_chunks = max_chunks;
    if (want_chunks == 0) return;

    size_t before = os_proc_available_memory();
    if (before <= reserve_bytes + chunk_bytes) {
        fprintf(stderr, "shell: memory purge skipped (available %zu MB <= 1264 MB headroom)\n", before >> 20);
        return;
    }

    void *chunks[128];
    size_t nchunks = 0;
    uint64_t seed = 0x9e3779b97f4a7c15ULL ^ (uint64_t)before ^ (uint64_t)(uintptr_t)&chunks;
    while (nchunks < want_chunks) {
        size_t avail = os_proc_available_memory();
        if (avail <= reserve_bytes + chunk_bytes) break;
        void *p = mmap(NULL, chunk_bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
        if (p == MAP_FAILED) break;
        uint64_t *w = (uint64_t *)p;
        size_t nwords = chunk_bytes / sizeof(uint64_t);
        for (size_t i = 0; i < nwords; i++) {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            w[i] = seed;
        }
        chunks[nchunks++] = p;
        if (os_proc_available_memory() <= reserve_bytes) break;
    }
    for (size_t i = 0; i < nchunks; i++) munmap(chunks[i], chunk_bytes);
    size_t after = os_proc_available_memory();
    fprintf(stderr, "shell: memory purge reclaimed with %zu MB touched (%zu chunks), available %zu MB -> %zu MB\n",
            (nchunks * chunk_bytes) >> 20, nchunks, before >> 20, after >> 20);
#else
    (void)limit_mb;
#endif
}

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

static void save_framework_data(const void *fbase, const char *game_key, const char *executable, time_t mtime) {
    if (!fbase) return;
    for (int i = 0; i < g_nfw_snaps; i++) if (g_fw_snaps[i].fbase == fbase) return;
    if (g_nfw_snaps >= 64) return;
    const struct mach_header_64 *mh = (const struct mach_header_64 *)fbase;
    DmFwSnap *s = &g_fw_snaps[g_nfw_snaps++];
    memset(s, 0, sizeof *s);
    s->fbase = fbase;
    if (game_key) strlcpy(s->game_key, game_key, sizeof s->game_key);
    if (executable) strlcpy(s->exe_path, executable, sizeof s->exe_path);
    s->mtime = mtime;
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
        dc_teardown();
        [ShellRuntimeBridge didReturnToLibrary];
        char finished_exe[1024];
        strlcpy(finished_exe, g_active_exe, sizeof finished_exe);
        const void *fbase = g_active_fbase;
        g_active_fbase = NULL;
        g_active_exe[0] = '\0';
        g_active_game_id[0] = '\0';
        g_focus = NULL;
        g_present = NULL;
        g_boot_ok = 0;
        g_engine_level = 0;
        if (fbase) restore_framework_data(fbase);
        [ShellLibrary gameDidEnd];
        UIWindow *window = shell_key_window();
        if (window && g_library_vc) {
            window.traitOverrides.preferredContentSizeCategory = UIContentSizeCategoryUnspecified;
            window.rootViewController = g_library_vc;
            [g_library_vc setNeedsUpdateOfSupportedInterfaceOrientations];
            if (@available(iOS 16.0, *)) {
                [window.windowScene requestGeometryUpdateWithPreferences:[[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:UIInterfaceOrientationMaskAllButUpsideDown] errorHandler:nil];
            }
        }
        [NSNotificationCenter.defaultCenter postNotificationName:@"DMShellDidReturnToLibrary" object:nil];
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

#if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
static const char *register_external_signature(const char *executable) {
    NSString *bundlePrefix = [[NSBundle.mainBundle.bundlePath stringByStandardizingPath] stringByAppendingString:@"/"];
    NSString *exeStd = [@(executable) stringByStandardizingPath];
    if ([exeStd hasPrefix:bundlePrefix]) return NULL;

    int fd = open(executable, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return "The game's framework executable could not be opened.";
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_size < (off_t)sizeof(struct mach_header_64)) {
        close(fd);
        return "The game's framework executable is missing or incomplete.";
    }
    uint64_t fsize = (uint64_t)st.st_size;
    uint8_t head[544];
    ssize_t nhead = pread(fd, head, sizeof head < fsize ? sizeof head : (size_t)fsize, 0);
    if (nhead < 32) { close(fd); return "The game's framework executable could not be read."; }

    uint64_t slice_off = 0, slice_sz = fsize;
    uint32_t magic_be = 0;
    memcpy(&magic_be, head, 4);
    magic_be = ntohl(magic_be);
    if (magic_be == FAT_MAGIC || magic_be == FAT_MAGIC_64) {
        uint32_t nfat = 0;
        memcpy(&nfat, head + 4, 4);
        nfat = ntohl(nfat);
        size_t stride = (magic_be == FAT_MAGIC_64) ? 32 : 20;
        if (nfat == 0 || nfat > 16 || (size_t)nhead < 8 + (size_t)nfat * stride) {
            close(fd);
            return "The game's universal framework header is damaged.";
        }
        int found = 0;
        for (uint32_t i = 0; i < nfat; i++) {
            const uint8_t *p = head + 8 + (size_t)i * stride;
            uint32_t cputype = 0;
            memcpy(&cputype, p, 4);
            cputype = ntohl(cputype);
            uint64_t off = 0, sz = 0;
            if (magic_be == FAT_MAGIC_64) {
                uint32_t hi = 0, lo = 0;
                memcpy(&hi, p + 8, 4); memcpy(&lo, p + 12, 4);
                off = ((uint64_t)ntohl(hi) << 32) | ntohl(lo);
                memcpy(&hi, p + 16, 4); memcpy(&lo, p + 20, 4);
                sz = ((uint64_t)ntohl(hi) << 32) | ntohl(lo);
            } else {
                uint32_t o32 = 0, s32 = 0;
                memcpy(&o32, p + 8, 4); memcpy(&s32, p + 12, 4);
                off = ntohl(o32); sz = ntohl(s32);
            }
            if (off <= fsize && sz >= sizeof(struct mach_header_64) && sz <= fsize - off &&
                (cputype == CPU_TYPE_ARM64 || !found)) {
                slice_off = off; slice_sz = sz; found = 1;
                if (cputype == CPU_TYPE_ARM64) break;
            }
        }
        if (!found) { close(fd); return "The game's framework has no usable arm64 slice."; }
    }

    struct mach_header_64 mh;
    if (pread(fd, &mh, sizeof mh, (off_t)slice_off) != (ssize_t)sizeof mh || mh.magic != MH_MAGIC_64 ||
        mh.ncmds > 4096 || mh.sizeofcmds > slice_sz - sizeof mh || mh.sizeofcmds > 4 * 1024 * 1024) {
        close(fd);
        return "The game's framework is not a valid 64-bit Mach-O image.";
    }
    uint8_t *cmds = malloc(mh.sizeofcmds);
    if (!cmds) { close(fd); return "Out of memory checking framework signature."; }
    if (pread(fd, cmds, mh.sizeofcmds, (off_t)(slice_off + sizeof mh)) != (ssize_t)mh.sizeofcmds) {
        free(cmds); close(fd);
        return "The game's Mach-O load commands could not be read.";
    }
    uint32_t sig_off = 0, sig_sz = 0;
    size_t cur = 0;
    for (uint32_t i = 0; i < mh.ncmds && cur + sizeof(struct load_command) <= mh.sizeofcmds; i++) {
        const struct load_command *lc = (const struct load_command *)(cmds + cur);
        if (lc->cmdsize < sizeof(struct load_command) || lc->cmdsize > mh.sizeofcmds - cur) break;
        if (lc->cmd == LC_CODE_SIGNATURE && lc->cmdsize >= sizeof(struct linkedit_data_command)) {
            const struct linkedit_data_command *cs = (const struct linkedit_data_command *)lc;
            sig_off = cs->dataoff;
            sig_sz = cs->datasize;
            break;
        }
        cur += lc->cmdsize;
    }
    free(cmds);
    if (sig_off == 0 || sig_sz < 12 || sig_off > slice_sz || sig_sz > slice_sz - sig_off || sig_sz > 16 * 1024 * 1024) {
        close(fd);
        return "This game's framework in Documents/Frameworks is unsigned. Install the game again from NX2Apple.";
    }
    fsignatures_t fsig;
    memset(&fsig, 0, sizeof fsig);
    fsig.fs_file_start = (off_t)slice_off;
    fsig.fs_blob_start = (void *)(uintptr_t)sig_off;   // slice-relative file offset expected by XNU
    fsig.fs_blob_size = sig_sz;
    int rc = fcntl(fd, F_ADDFILESIGS_RETURN, &fsig);
    int saved_errno = errno;
    if (rc < 0 && saved_errno != EEXIST) {
        close(fd);
        fprintf(stderr, "[RED] boot: F_ADDFILESIGS_RETURN failed for %s: errno=%d (%s)\n",
                executable, saved_errno, strerror(saved_errno));
        return "iOS refused the code signature of this game's framework. Install the game again from NX2Apple.";
    }
    char lv_msg[256];
    lv_msg[0] = '\0';
    fchecklv_t lv;
    memset(&lv, 0, sizeof lv);
    lv.lv_file_start = (off_t)slice_off;
    lv.lv_error_message_size = sizeof lv_msg;
    lv.lv_error_message = lv_msg;
    int lv_rc = fcntl(fd, F_CHECK_LV, &lv);
    int lv_errno = errno;
    close(fd);
    if (lv_rc < 0) {
        fprintf(stderr, "[RED] boot: F_CHECK_LV failed for %s: errno=%d (%s) %s\n",
                executable, lv_errno, strerror(lv_errno), lv_msg);
        return "iOS refused the code signature of this game's framework. Install the game again from NX2Apple.";
    }
    return NULL;
}
#endif

const char *dm_shell_start_game(const char *const *keys, const char *const *values, int n, const char *const *argv, int argc,
                                const char *executable, const char *marker, const char *log_path, const char *cwd,
                                const char *game_id) {
    static char err[512];
    if (g_boot_ok) return "A game is already running.";
    if (argc < 2 || !executable || !marker) return "The game's start arguments are incomplete.";
    char game_key[128];
    dm_snap_key(game_id, executable, game_key, sizeof game_key);
    struct stat exe_st;
    memset(&exe_st, 0, sizeof exe_st);
    if (stat(executable, &exe_st) == 0) {
        for (int i = 0; i < g_nfw_snaps; i++) {
            if (dm_snap_conflicts(g_fw_snaps[i].game_key, g_fw_snaps[i].exe_path, g_fw_snaps[i].mtime,
                                  game_key, executable, exe_st.st_mtime)) {
                return "This game was updated while the app was open. Close and reopen the app to load the new build.";
            }
        }
    }
    clear_game_env();
    log_to(@(log_path));
    fprintf(stderr, "shell: starting %s (%s)\n", argv[1], executable);
    for (int i = 0; i < n; i++) {
        setenv(keys[i], values[i], 1);
        fprintf(stderr, "boot: %s=%s\n", keys[i], values[i]);   // every one: a report then shows which of the game's settings reached the engine
    }
    if (cwd && *cwd) chdir(cwd);
#if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
    const char *sig_err = register_external_signature(executable);
    if (sig_err) {
        snprintf(err, sizeof err, "%s", sig_err);
        fprintf(stderr, "[RED] boot: %s: %s\n", executable, err);
        return err;
    }
#endif
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
    save_framework_data(info.dli_fbase, game_key, executable, exe_st.st_mtime);
    const char *why = start(argv, argc, info.dli_fbase);
    if (why) {
        snprintf(err, sizeof err, "%s", why);
        fprintf(stderr, "[RED] boot: %s: %s\n", executable, err);
        restore_framework_data(info.dli_fbase);
        return err;
    }
    strlcpy(g_active_exe, executable, sizeof g_active_exe);
    if (game_id) strlcpy(g_active_game_id, game_id, sizeof g_active_game_id);
    else g_active_game_id[0] = '\0';
    g_active_fbase = info.dli_fbase;
    g_present = present;
    g_focus = focus;
    g_boot_ok = 1;
    return NULL;
}

void dm_shell_present_game(void) {
    UIWindow *window = shell_key_window();
    if (!window || !g_present) { fprintf(stderr, "[RED] shell: no window for the game view\n"); return; }
    g_engine_level = 0;
    g_present((__bridge void *)window);
    dc_arm_observers();
    shell_sync_focus();
}

const char *dm_shell_active_game_id(void) {
    return (g_boot_ok && g_active_game_id[0]) ? g_active_game_id : NULL;
}

void dm_shell_request_stop_game(void) {
    if (g_boot_ok && g_focus) {
        g_focus(DM_GLUE_FOCUS_REQUEST_QUIT);
    }
}

@interface App : UIResponder <UIApplicationDelegate>
@end
// Browsing may be portrait. Phone gameplay honors DM_ROTATION (defaulting to landscape). UIKit manages unrestricted rotation on the Duo inner display.
static UIInterfaceOrientationMask shell_orientations(UITraitCollection *traits) {
    BOOL isPhone = (traits && traits.userInterfaceIdiom != UIUserInterfaceIdiomUnspecified)
        ? (traits.userInterfaceIdiom == UIUserInterfaceIdiomPhone)
        : (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone);
    if (g_boot_ok) {
        const char *rot = getenv("DM_ROTATION");
        if (rot && strcmp(rot, "portrait") == 0) {
            return isPhone
                ? UIInterfaceOrientationMaskPortrait
                : (UIInterfaceOrientationMaskPortrait | UIInterfaceOrientationMaskPortraitUpsideDown);
        }
        if (rot && strcmp(rot, "landscape") == 0) return UIInterfaceOrientationMaskLandscape;
    }
    if (!isPhone) return UIInterfaceOrientationMaskAll;
    return g_boot_ok ? UIInterfaceOrientationMaskLandscape : UIInterfaceOrientationMaskAllButUpsideDown;
}
@implementation App
- (UIInterfaceOrientationMask)application:(UIApplication *)application supportedInterfaceOrientationsForWindow:(UIWindow *)window {
    return shell_orientations(window.traitCollection);   // iOS 26
}
- (UISceneConfiguration *)application:(UIApplication *)a configurationForConnectingSceneSession:(UISceneSession *)s options:(UISceneConnectionOptions *)o {
    return [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:s.role];
}
- (BOOL)application:(UIApplication *)application openURL:(NSURL *)url options:(NSDictionary<UIApplicationOpenURLOptionsKey,id> *)options {
    (void)application; (void)options;
    return [ShellLibrary handleOpenURL:url];
}
@end

@interface SceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (strong, nonatomic) UIWindow *window;
@end
static NSURL *shell_pick_launch_url(NSSet<UIOpenURLContext *> *contexts) {
    NSURL *fallback = nil;
    for (UIOpenURLContext *ctx in contexts) {
        if (!ctx.URL) continue;
        if ([ctx.URL.scheme.lowercaseString isEqualToString:@"nx2apple"]) return ctx.URL;
        if (!fallback) fallback = ctx.URL;
    }
    return fallback;
}

@implementation SceneDelegate
- (UIInterfaceOrientationMask)supportedInterfaceOrientationsForWindowScene:(UIWindowScene *)windowScene {
    return shell_orientations(windowScene.traitCollection);   // iOS 27 and later
}
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)o {
    (void)session;
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.backgroundColor = UIColor.blackColor;
    NSURL *initialURL = shell_pick_launch_url(o.URLContexts);
    g_library_vc = [ShellLibrary makeControllerWithInitialURL:initialURL];
    self.window.rootViewController = g_library_vc;
    [self.window makeKeyAndVisible];
}
- (void)scene:(UIScene *)scene openURLContexts:(NSSet<UIOpenURLContext *> *)URLContexts {
    (void)scene;
    for (UIOpenURLContext *ctx in URLContexts) {
        if (ctx.URL && [ctx.URL.scheme.lowercaseString isEqualToString:@"nx2apple"] && [ShellLibrary handleOpenURL:ctx.URL]) return;
    }
    for (UIOpenURLContext *ctx in URLContexts) {
        if (ctx.URL && [ShellLibrary handleOpenURL:ctx.URL]) break;
    }
}
// Forwarded to the running game framework's front_ios.m once a game has started; orthogonal to controller-disconnect pause.
- (void)sceneWillResignActive:(UIScene *)s { (void)s; g_app_resigned = 1; if (g_boot_ok) [ShellLibrary gameWillPause]; shell_sync_focus(); }
- (void)sceneDidEnterBackground:(UIScene *)s { (void)s; g_app_bg = 1; if (g_boot_ok) [ShellLibrary gameDidCheckpoint]; shell_sync_focus(); }
- (void)sceneWillEnterForeground:(UIScene *)s { (void)s; g_app_bg = 0; shell_sync_focus(); }
- (void)sceneDidBecomeActive:(UIScene *)s { (void)s; g_app_resigned = 0; if (g_boot_ok) [ShellLibrary gameDidResume]; shell_sync_focus(); }
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
        NSString *hotPath = [documents() stringByAppendingPathComponent:@"Frameworks"];
        for (NSString *fw in [NSFileManager.defaultManager contentsOfDirectoryAtPath:hotPath error:nil])
            if ([fw hasSuffix:@".framework"]) fprintf(stderr, "shell: hot-framework %s\n", fw.UTF8String);
        metal_hud_per_layer();
    }
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(App.class)); }
}
