// Route C shell (LNPANDY/NX2Apple#451): the entry points each game's DmGame<title ID>.framework exports for ShellMain.m to
// look up with dlsym on the handle it dlopens at Play. Each game framework links its own dm/host, front_ios.m and shaders, so an
// engine update never invalidates the games already in the shell.
#pragma once

// Bumped only when a signature below changes: a shell refuses a framework whose dm_glue_version does not match.
#define DM_GLUE_VERSION 1

typedef const char *(*dm_glue_start_fn)(const char *const *argv, int argc, const void *game_image);
typedef void (*dm_glue_present_fn)(void *window);
typedef void (*dm_glue_focus_fn)(int ev);
