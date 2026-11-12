// Route C shell: the engine side of Play (ShellMain.m), called by ShellApp.swift's EngineGameLauncher. See ShellMain.m.
#pragma once

// Sets the log, the environment (keys[i]=values[i], overwriting) and the working folder, dlopens the game's framework, hands its mach
// header to the loader and starts the host's early loading with argv. NULL on success, else a message for the player (the log has
// the details). Once per process.
const char *dm_shell_start_game(const char *const *keys, const char *const *values, int n, const char *const *argv, int argc,
                                const char *executable, const char *marker, const char *log_path, const char *cwd);
// After a successful start: the window shows front_ios.m's game view, which starts the game.
void dm_shell_present_game(void);
