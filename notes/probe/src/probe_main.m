// probe_main.m: the shell of the dlopen probe (docs/probe-dlopen.md). Answers one question for the
// launcher architecture C (docs/ROADMAP.md section 6): can a sideloaded IPA dlopen a dynamic
// framework that ships inside its own bundle (DmProbe.app/Frameworks/Probe.framework) and call a
// function in it, on a stock device, outside the jailbreak and the App Store review?
// At launch it appends every step to Documents/probe-log.txt (visible in the Files app:
// UIFileSharingEnabled in Info.plist), shows the verdict on screen, and stays open. The last log
// line is the verdict: "RESULT: FEASIBLE ..." or "RESULT: BLOCKED ...".
// Built with plain clang and a hand-written Info.plist by build_probe.sh, no Xcode project.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#include <stdarg.h>
#include <stdio.h>
#include <sys/stat.h>

static FILE *g_log;      // Documents/probe-log.txt, opened at the top of main
static NSMutableString *g_screen;   // the verdict, also shown on the app's screen

static void logf_(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void logf_(const char *fmt, ...) {
    if (!g_log) return;
    va_list ap;
    va_start(ap, fmt);
    vfprintf(g_log, fmt, ap);
    va_end(ap);
    fputc('\n', g_log);
    fflush(g_log);   // every line survives even if the process dies later
}

// One dlopen attempt: logs the form and dlerror()'s verbatim text, returns the handle (NULL on failure)
static void *try_open(const char *form) {
    logf_("dlopen(\"%s\", RTLD_NOW)", form);
    dlerror();   // clear stale state so the next dlerror is this attempt's
    void *h = dlopen(form, RTLD_NOW);
    if (h) logf_("  -> handle %p", h);
    else {
        const char *e = dlerror();
        logf_("  -> NULL, dlerror: %s", e ? e : "(no dlerror text)");
    }
    return h;
}

static NSMutableString *run_probe(void) {
    NSBundle *bundle = [NSBundle mainBundle];
    NSString *bundlePath = bundle.bundlePath ?: @"?";
    NSString *execPath = bundle.executablePath ?: @"?";
    logf_("bundle:      %s", bundlePath.fileSystemRepresentation ?: "?");
    logf_("executable:  %s", execPath.fileSystemRepresentation ?: "?");
    logf_("iOS:         %s (%s)", [UIDevice currentDevice].systemVersion.UTF8String ?: "?",
          [UIDevice currentDevice].model.UTF8String ?: "?");

    NSMutableString *screen = [NSMutableString stringWithFormat:@"DmProbe dlopen probe (iOS %@)\n\n",
                               [UIDevice currentDevice].systemVersion];

    // The framework must physically be in the bundle, beside the executable's Frameworks/ folder
    NSString *fwPath = [bundlePath stringByAppendingPathComponent:@"Frameworks/Probe.framework/Probe"];
    struct stat st = {0};
    BOOL present = stat(fwPath.fileSystemRepresentation, &st) == 0;
    logf_("framework file %s: %s", fwPath.fileSystemRepresentation, present ? "present" : "MISSING");
    [screen appendFormat:@"framework file: %@\n\n", present ? @"present" : @"MISSING"];

    // The forms to try, in order. The first two are the ones a launcher would use; the rest narrow
    // down the failure if both are refused (absolute sandbox path, cwd-relative, bare name)
    NSArray<NSString *> *forms = @[
        @"@executable_path/Frameworks/Probe.framework/Probe",
        @"@rpath/Probe.framework/Probe",
        fwPath,                       // the absolute sandbox path of the same file
        @"Probe.framework/Probe",     // relative: dyld resolves it from the current directory (/)
        @"Probe",                     // bare name: dyld's fallback search paths only
    ];
    void *handle = NULL;
    NSString *okForm = nil;
    for (NSString *form in forms) {
        void *h = try_open(form.UTF8String);
        if (h) { handle = h; okForm = form; break; }
    }
    if (!handle) {
        logf_("RESULT: BLOCKED - every dlopen form failed (see the dlerror lines above)");
        [screen appendString:@"every dlopen form failed\n\nRESULT: BLOCKED\n(see Documents/probe-log.txt for the dlerror texts)"];
        return screen;
    }

    // The framework loaded: take the C function out of it and call it
    logf_("dlsym(handle, \"probe_answer\")");
    dlerror();
    void *sym = dlsym(handle, "probe_answer");
    const char *se = dlerror();
    if (se || !sym) {
        logf_("  -> failed: %s", se ? se : "NULL result");
        logf_("RESULT: BLOCKED - the framework loaded (dlopen \"%s\") but dlsym failed: %s",
              okForm.UTF8String, se ? se : "NULL result");
        [screen appendFormat:@"dlopen OK via %@\ndlsym failed: %s\n\nRESULT: BLOCKED", okForm, se ? se : "NULL result"];
        return screen;
    }
    int (*fn)(void) = (int (*)(void))sym;
    int answer = fn();
    Dl_info info = {0};
    const char *from = dladdr(sym, &info) && info.dli_fname ? info.dli_fname : "(dladdr found no image)";
    logf_("  -> probe_answer at %p in %s (image base %p)", sym, from, info.dli_fbase);
    logf_("  -> probe_answer() = %d", answer);
    if (answer == 42) {
        logf_("RESULT: FEASIBLE - dlopen(\"%s\") succeeded and probe_answer() = 42: a sideloaded app can load and call code in a framework inside its own bundle (route C is viable)",
              okForm.UTF8String);
        [screen appendFormat:@"dlopen OK via %@\nprobe_answer() = 42\n\nRESULT: FEASIBLE\n\nfull log: Documents/probe-log.txt", okForm];
    } else {
        logf_("RESULT: BLOCKED - dlopen and dlsym succeeded but probe_answer() returned %d, not 42", answer);
        [screen appendFormat:@"dlopen OK via %@, but probe_answer() = %d (wanted 42)\n\nRESULT: BLOCKED", okForm, answer];
    }
    return screen;
}

@interface ProbeDelegate : NSObject <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation ProbeDelegate
// The probe keeps the legacy UIApplication lifecycle (no scene manifest, no scene delegate): a
// deprecated-but-supported path, which keeps this file one screen long. The deprecations it pulls
// in (mainScreen, initWithFrame:) are silenced here on purpose.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    UIWindow *w = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    UILabel *l = [[UILabel alloc] initWithFrame:w.bounds];
    l.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    l.numberOfLines = 0;
    l.font = [UIFont fontWithName:@"Menlo" size:14] ?: [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
    l.text = g_screen ?: @"DmProbe";
    l.textAlignment = NSTextAlignmentCenter;
    l.backgroundColor = UIColor.systemBackgroundColor;
    w.backgroundColor = UIColor.systemBackgroundColor;
    w.rootViewController = [[UIViewController alloc] init];
    w.rootViewController.view.backgroundColor = UIColor.systemBackgroundColor;
    [w.rootViewController.view addSubview:l];
    [w makeKeyAndVisible];
    self.window = w;
    return YES;
}
#pragma clang diagnostic pop
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        // Documents/probe-log.txt: the Files app shows this folder (UIFileSharingEnabled), so the
        // user can read and share the log without a computer. Appended, so past runs stay.
        NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        NSString *logPath = [docs stringByAppendingPathComponent:@"probe-log.txt"];
        g_log = fopen(logPath.fileSystemRepresentation, "a");
        if (g_log)
            fprintf(g_log, "\n---- DmProbe run %s (probe built %s %s) ----\n",
                    [[NSDate date] description].UTF8String, __DATE__, __TIME__);
        g_screen = run_probe();
        if (!g_log) { g_screen = [g_screen mutableCopy]; [g_screen appendString:@"\n\n(the log file could not be opened)"]; }
        if (g_log) { fclose(g_log); g_log = NULL; }
        // Stay open on the verdict: a probe that exits at once looks like a crash on the phone
        UIApplicationMain(argc, argv, nil, NSStringFromClass([ProbeDelegate class]));
    }
    return 0;
}
