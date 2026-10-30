// Route C (docs/launcher-c-plan.md M1): the game's modules are in DmIOS.app/Frameworks/DmGame.framework, not in the
// executable, so the loader needs that image's mach header before it runs. dm_open_game_framework() dlopen()s the framework
// from the app bundle, finds its marker symbol, takes the image base with dladdr() and hands it to the loader
// (dm_set_game_image_header, dm/host/loader_image.h). A failure is logged as a [RED] line with the dlerror text and the boot
// stops: without the framework's sections there are no modules to run.
// Compiled only into a DM_FRAMEWORK_BUILD app (project-framework.yml). The default build calls none of this.
#pragma once

// M1 ships one game per app, so the framework has fixed names (build_ipa.sh DM_FRAMEWORK=1, project-framework.yml).
// M2's shell picks them from game.manifest.json instead (framework / framework_executable / image_marker).
#define DM_FRAMEWORK_DIRECTORY "DmGame.framework"
#define DM_FRAMEWORK_EXECUTABLE "DmGame"
#define DM_FRAMEWORK_MARKER "dmgame_image_marker"

#ifdef __cplusplus
extern "C" {
#endif

// dir: the framework's directory inside the app bundle, e.g. <App>/Frameworks/DmGame.framework.
// 1 when the image header was set, 0 after the [RED] line that says which step failed.
int dm_open_game_framework(const char *dir);

#ifdef __cplusplus
}
#endif
