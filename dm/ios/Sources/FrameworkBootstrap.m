// Route C (docs/launcher-c-plan.md M1): load the game framework and give the loader its image header. See
// FrameworkBootstrap.h for the contract; main.m calls this before dm_host_preload_start().
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdio.h>
#include "FrameworkBootstrap.h"
#include "loader_image.h"

#ifndef DM_FRAMEWORK_BUILD
#define DM_FRAMEWORK_BUILD 0
#endif

#if DM_FRAMEWORK_BUILD
int dm_open_game_framework(const char *dir) {
    NSString *exe = [@(dir) stringByAppendingPathComponent:@DM_FRAMEWORK_EXECUTABLE];
    const char *path = exe.fileSystemRepresentation;
    // RTLD_LAZY, as the dlopen probe (docs/probe-dlopen.md) and the design use: only the framework's own sections and the
    // marker are needed, and its initializers must not run anything (DmGameMarker.m has none).
    void *h = dlopen(path, RTLD_LAZY);
    if (!h) {
        // The dlerror text names the refusal verbatim (code signature, architecture, missing file); the log is the only
        // channel a sideloaded build has.
        fprintf(stderr, "[RED] boot: dlopen %s failed: %s\n", path, dlerror() ?: "(no dlerror text)");
        return 0;
    }
    dlerror();   // clear any stale text before dlsym, so a missing marker reports its own dlerror
    void *marker = dlsym(h, DM_FRAMEWORK_MARKER);
    if (!marker) {
        fprintf(stderr, "[RED] boot: %s has no %s symbol: %s\n", path, DM_FRAMEWORK_MARKER, dlerror() ?: "(no dlerror text)");
        return 0;
    }
    Dl_info info;
    if (!dladdr(marker, &info) || !info.dli_fbase) {
        fprintf(stderr, "[RED] boot: dladdr(%s) in %s did not name the image\n", DM_FRAMEWORK_MARKER, path);
        return 0;
    }
    // The header stays valid for the process's life: the framework is never dlclose()d (the loader holds its sections)
    dm_set_game_image_header(info.dli_fbase);
    fprintf(stderr, "boot: game framework %s (handle %p, image base %p)\n", path, h, info.dli_fbase);
    return 1;
}
#else
int dm_open_game_framework(const char *dir) {
    (void)dir;
    return 0;
}
#endif
