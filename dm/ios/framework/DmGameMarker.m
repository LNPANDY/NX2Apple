// The DmGame framework's only symbol. The framework carries the game's rewritten modules in Mach-O sections (Gen/embed.S,
// the same file the default build compiles into the executable) and no host code; dlopen()ing it maps and signs those
// sections, and dm/ios/Sources/FrameworkBootstrap.m finds this marker with dlsym() and reports the framework's mach header
// through dladdr(). The loader (dm/host/loader.c, loader_image.h) then reads the module sections from it.
// Its value is not read: the symbol's address alone names the image, so it must stay externally visible (default visibility,
// not static) and survive the linker.
#include <stdint.h>

__attribute__((used, visibility("default")))
const char dmgame_image_marker[] = "DmGame";
