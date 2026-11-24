#pragma once
#include <stdbool.h>
#include <string.h>

enum {
    DM_SHELL_ORIENT_PORTRAIT = 1u << 1,
    DM_SHELL_ORIENT_PORTRAIT_UPSIDE_DOWN = 1u << 2,
    DM_SHELL_ORIENT_LANDSCAPE_RIGHT = 1u << 3,
    DM_SHELL_ORIENT_LANDSCAPE_LEFT = 1u << 4,
    DM_SHELL_ORIENT_LANDSCAPE = DM_SHELL_ORIENT_LANDSCAPE_LEFT | DM_SHELL_ORIENT_LANDSCAPE_RIGHT,
    DM_SHELL_ORIENT_ALL_BUT_UPSIDE_DOWN = DM_SHELL_ORIENT_PORTRAIT | DM_SHELL_ORIENT_LANDSCAPE,
    DM_SHELL_ORIENT_ALL = DM_SHELL_ORIENT_ALL_BUT_UPSIDE_DOWN | DM_SHELL_ORIENT_PORTRAIT_UPSIDE_DOWN,
};

// Supported orientations for the shared shell window: browsing and Automatic follow the device
// (all except upside down on iPhone, all four on iPad); explicit landscape/portrait lock gameplay.
static inline unsigned dm_shell_orientation_mask(bool boot_ok, const char *rot, bool is_phone) {
    if (boot_ok && rot) {
        if (strcmp(rot, "portrait") == 0) {
            return is_phone
                ? DM_SHELL_ORIENT_PORTRAIT
                : (DM_SHELL_ORIENT_PORTRAIT | DM_SHELL_ORIENT_PORTRAIT_UPSIDE_DOWN);
        }
        if (strcmp(rot, "landscape") == 0) return DM_SHELL_ORIENT_LANDSCAPE;
    }
    return is_phone ? DM_SHELL_ORIENT_ALL_BUT_UPSIDE_DOWN : DM_SHELL_ORIENT_ALL;
}

static inline unsigned dm_shell_library_orientation_mask(bool is_phone) {
    return is_phone ? DM_SHELL_ORIENT_ALL_BUT_UPSIDE_DOWN : DM_SHELL_ORIENT_ALL;
}
