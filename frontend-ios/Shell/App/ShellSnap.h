#pragma once
#include <stddef.h>
#include <string.h>
#include <time.h>

// Derives a per-game snapshot key so different game frameworks sharing a generic image marker
// never trigger false "updated while the app was open" errors when switching games.
static inline void dm_snap_key(const char *game_id, const char *executable, char *out, size_t cap) {
    if (!out || cap == 0) return;
    out[0] = '\0';
    if (game_id && *game_id) {
        size_t len = strlen(game_id);
        if (len >= cap) len = cap - 1;
        memcpy(out, game_id, len);
        out[len] = '\0';
        return;
    }
    if (!executable || !*executable) return;
    const char *fw = strstr(executable, ".framework/");
    if (fw) {
        const char *start = fw;
        while (start > executable && start[-1] != '/') start--;
        size_t len = (size_t)((fw + strlen(".framework")) - start);
        if (len > 0) {
            if (len >= cap) len = cap - 1;
            memcpy(out, start, len);
            out[len] = '\0';
            return;
        }
    }
    size_t len = strlen(executable);
    if (len >= cap) len = cap - 1;
    memcpy(out, executable, len);
    out[len] = '\0';
}

static inline int dm_snap_conflicts(const char *snap_key, const char *snap_exe, time_t snap_mtime,
                                    const char *req_key, const char *req_exe, time_t req_mtime) {
    if (!snap_key || !req_key || !*snap_key || !*req_key) return 0;
    if (strcmp(snap_key, req_key) != 0) return 0;
    const char *a = snap_exe ? snap_exe : "";
    const char *b = req_exe ? req_exe : "";
    return (strcmp(a, b) != 0 || snap_mtime != req_mtime) ? 1 : 0;
}
