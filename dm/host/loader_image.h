// The mach header the iOS loader reads the game's embedded module sections from (loader.c: map_image, nro_pieces).
// The default build compiles those sections into the executable itself and reads &_mh_execute_header. A framework
// build (DM_FRAMEWORK=1) compiles them into DmIOS.app/Frameworks/DmGame.framework instead:
// iOS may not map new executable code from disk, so the framework is dlopen()ed from the signed bundle and its
// header, taken from dladdr of a marker the framework exports, is handed here before dm_host_preload_start() runs.
// Horizon's own rtld has no such indirection; it exists only because the image that carries the code is chosen at
// build time (the executable) or at launch (the framework).
// Set once, before loading starts: the loader reads it on the preload thread and every later module (NRO) load.
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

void dm_set_game_image_header(const void *mh);

#ifdef __cplusplus
}
#endif
