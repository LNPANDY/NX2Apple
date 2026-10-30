// Runtime game profile: see hle_profile.h. One IPA for every game reads its layout, switches and tables from DM_PROFILE
// instead of having them compiled in (game_profile.h stays the fallback, so a build without DM_PROFILE is unchanged).
#include "dm.h"
#include "hle_profile.h"
#include <ctype.h>

static struct dm_profile P;
static int g_loaded;

static void copy_str(char *dst, size_t n, const char *src) {
    if (!n) return;
    size_t i = 0;
    for (; src && src[i] && i + 1 < n; i++) dst[i] = src[i];
    dst[i] = 0;
}
static int truthy(const char *v) {   // "1", "on", "yes", "true" (case-insensitive) = on; "0", "off", "no", "false", "" = off
    if (!v) return 0;
    return !(v[0] == '0' || !strcasecmp(v, "off") || !strcasecmp(v, "no") || !strcasecmp(v, "false") || !v[0]);
}
static uint64_t num(const char *v, uint64_t dflt) {
    if (!v || !*v) return dflt;
    char *e = NULL;
    uint64_t r = strtoull(v, &e, 0);
    return e && e != v ? r : dflt;
}

// ---- defaults: exactly what game_profile.h (generated from game.tsv) compiles in ----
// A profile header may be partial (the unit tests' synthetic one carries only the memory constants, and game.py leaves a macro
// out when game.tsv has no such row), so every macro is guarded on its own: a missing one means "the game does not set this key".
// One shared guard per block was enough while the header defined the whole block, and broke when upstream dropped Wonder's
// feedback_snap row (2026-10-30): the header still defined DM_GAME_PRESENT_DISPLAY, so the block's defaults were skipped and
// DM_GAME_FEEDBACK_SNAP stayed undeclared.
#ifndef DM_GAME_ID
#define DM_GAME_ID ""
#define DM_GAME_NAME ""
#define DM_GAME_ROMFS_MARKER ""
#define DM_GAME_MODULES {0}
#define DM_GAME_NMOD 0
#endif
#ifndef DM_GAME_PROGRAM_ID
#define DM_GAME_PROGRAM_ID 0ull
#endif
#ifndef DM_GAME_MEM_RESERVE
#define DM_GAME_MEM_RESERVE 0ull
#define DM_GAME_MEM_ALIAS 0ull
#define DM_GAME_MEM_STACK 0ull
#define DM_GAME_APP_POOL 0ull
#define DM_GAME_MEM_USED 0x4000000ull
#define DM_GAME_SYS_RESOURCE 0ull
#define DM_GAME_MEM_MAP_LIMIT 0
#endif
#ifndef DM_GAME_DISPLAY_VERSIONS
#define DM_GAME_DISPLAY_VERSIONS {0, 0}
#endif
#ifndef DM_GAME_PRESENT_DISPLAY
#define DM_GAME_PRESENT_DISPLAY 0
#endif
#ifndef DM_GAME_CORE_PREEMPT
#define DM_GAME_CORE_PREEMPT 0
#endif
#ifndef DM_GAME_ALLOC_BIG_ALIGN
#define DM_GAME_ALLOC_BIG_ALIGN 0
#endif
#ifndef DM_GAME_FPS_TARGET
#define DM_GAME_FPS_TARGET 0
#endif
#ifndef DM_GAME_FPS_HOLD
#define DM_GAME_FPS_HOLD 1
#endif
#ifndef DM_GAME_PRESENT_SNAP
#define DM_GAME_PRESENT_SNAP 0
#endif
#ifndef DM_GAME_PSO_MTL4
#define DM_GAME_PSO_MTL4 0
#endif
#ifndef DM_GAME_PAD_LAYOUT
#define DM_GAME_PAD_LAYOUT 0
#endif
#ifndef DM_GAME_OPMODE
#define DM_GAME_OPMODE 1
#endif
#ifndef DM_GAME_PERF_BOOST
#define DM_GAME_PERF_BOOST 0
#endif
#ifndef DM_GAME_FEEDBACK_SNAP
#define DM_GAME_FEEDBACK_SNAP ""
#endif
#ifndef DM_GAME_TEX_FLUSH_UPLOAD
#define DM_GAME_TEX_FLUSH_UPLOAD 0
#endif
#ifndef DM_GAME_RENDER_COND
#define DM_GAME_RENDER_COND 0
#endif
#ifndef DM_GAME_TEX_DIRTY_UPLOAD
#define DM_GAME_TEX_DIRTY_UPLOAD 0
#endif
#ifndef DM_GAME_TEX_DYN_SLOTS
#define DM_GAME_TEX_DYN_SLOTS 0
#endif
#ifndef DM_GAME_GPU_TS_SEGMENT
#define DM_GAME_GPU_TS_SEGMENT 0
#endif
#ifndef DM_GAME_VCONV_RANGE
#define DM_GAME_VCONV_RANGE 0
#endif
#ifndef DM_GAME_ARGS
#define DM_GAME_ARGS ""
#endif
#ifndef DM_GAME_ENV
#define DM_GAME_ENV ""
#endif
static void defaults(void) {
    memset(&P, 0, sizeof P);
    copy_str(P.id, sizeof P.id, DM_GAME_ID);
    copy_str(P.name, sizeof P.name, DM_GAME_NAME);
    copy_str(P.romfs_marker, sizeof P.romfs_marker, DM_GAME_ROMFS_MARKER);
    P.program_id = DM_GAME_PROGRAM_ID;
    { static const char *m[] = DM_GAME_MODULES; int n = DM_GAME_NMOD; if (n > DM_PROF_MAX_MOD) n = DM_PROF_MAX_MOD;
      for (int i = 0; i < n; i++) { copy_str(P.modbuf[i], sizeof P.modbuf[i], m[i]); P.modules[i] = P.modbuf[i]; } P.nmod = n; }
    P.mem_reserve = DM_GAME_MEM_RESERVE; P.mem_alias = DM_GAME_MEM_ALIAS; P.mem_stack = DM_GAME_MEM_STACK;
    P.app_pool = DM_GAME_APP_POOL; P.mem_used = DM_GAME_MEM_USED; P.sys_resource = DM_GAME_SYS_RESOURCE;
    P.mem_map_limit = DM_GAME_MEM_MAP_LIMIT;
    { static const struct { const char *build, *ver; } k[] = {DM_GAME_DISPLAY_VERSIONS};
      int n = (int)(sizeof k / sizeof *k); if (n > DM_PROF_MAX_VER) n = DM_PROF_MAX_VER;
      for (int i = 0; i < n; i++) {
          if (!k[i].build || !k[i].ver) continue;   // the placeholder a partial header falls back to
          copy_str(P.ver[P.nver].build, sizeof P.ver[0].build, k[i].build); copy_str(P.ver[P.nver].ver, sizeof P.ver[0].ver, k[i].ver); P.nver++;
      } }
    P.present_display = DM_GAME_PRESENT_DISPLAY; P.core_preempt = DM_GAME_CORE_PREEMPT; P.alloc_big_align = DM_GAME_ALLOC_BIG_ALIGN;
    P.fps_target = DM_GAME_FPS_TARGET; P.fps_hold = DM_GAME_FPS_HOLD; P.present_snap = DM_GAME_PRESENT_SNAP; P.pso_mtl4 = DM_GAME_PSO_MTL4;
#ifdef DM_GAME_SHARED_FONT_TTF
    P.shared_font_ttf = DM_GAME_SHARED_FONT_TTF;
#else
    P.shared_font_ttf = -1;
#endif
    P.pad_layout = DM_GAME_PAD_LAYOUT; P.opmode = DM_GAME_OPMODE; P.perf_boost = DM_GAME_PERF_BOOST;
    copy_str(P.feedback_snap, sizeof P.feedback_snap, DM_GAME_FEEDBACK_SNAP);
    P.tex_flush_upload = DM_GAME_TEX_FLUSH_UPLOAD; P.render_cond = DM_GAME_RENDER_COND; P.tex_dirty_upload = DM_GAME_TEX_DIRTY_UPLOAD;
    P.tex_dyn_slots = DM_GAME_TEX_DYN_SLOTS; P.gpu_ts_segment = DM_GAME_GPU_TS_SEGMENT; P.vconv_range = DM_GAME_VCONV_RANGE;
#ifdef DM_GAME_NVN_API_MAJOR
    P.nvn_api_major = DM_GAME_NVN_API_MAJOR; P.nvn_api_minor = DM_GAME_NVN_API_MINOR;
#else
    P.nvn_api_major = 0; P.nvn_api_minor = 0;
#endif
    copy_str(P.args, sizeof P.args, DM_GAME_ARGS);
    copy_str(P.genv, sizeof P.genv, DM_GAME_ENV);
    copy_str(P.source, sizeof P.source, "compiled game_profile.h");
}

// ---- one key/value: the same key names as game.tsv (so `game.py` can write the file), plus the header's own names ----
static void set_kv(const char *k, const char *v) {
    if (!strcmp(k, "title_id") || !strcmp(k, "id")) copy_str(P.id, sizeof P.id, v);
    else if (!strcmp(k, "name")) copy_str(P.name, sizeof P.name, v);
    else if (!strcmp(k, "romfs_marker")) copy_str(P.romfs_marker, sizeof P.romfs_marker, v);
    else if (!strcmp(k, "program_id")) P.program_id = num(v, P.program_id);
    else if (!strcmp(k, "modules")) {
        P.nmod = 0; const char *p = v;
        while (*p && P.nmod < DM_PROF_MAX_MOD) {
            while (*p == ' ' || *p == '\t' || *p == ',') p++;
            if (!*p) break;
            size_t n = strcspn(p, " \t,");
            if (n >= sizeof P.modbuf[0]) n = sizeof P.modbuf[0] - 1;
            memcpy(P.modbuf[P.nmod], p, n); P.modbuf[P.nmod][n] = 0; P.modules[P.nmod] = P.modbuf[P.nmod];
            P.nmod++; p += n;
        }
    }
    else if (!strcmp(k, "mem_reserve")) P.mem_reserve = num(v, P.mem_reserve);
    else if (!strcmp(k, "mem_alias")) P.mem_alias = num(v, P.mem_alias);
    else if (!strcmp(k, "mem_stack")) P.mem_stack = num(v, P.mem_stack);
    else if (!strcmp(k, "app_pool")) P.app_pool = num(v, P.app_pool);
    else if (!strcmp(k, "mem_used")) P.mem_used = num(v, P.mem_used);
    else if (!strcmp(k, "sys_resource")) P.sys_resource = num(v, P.sys_resource);
    else if (!strcmp(k, "mem_map_limit")) P.mem_map_limit = truthy(v);
    else if (!strcmp(k, "display_version")) {   // build<TAB>version; one row per build (game.tsv's build rows give the same)
        const char *t = strchr(v, '\t'); if (t && P.nver < DM_PROF_MAX_VER) {
            size_t n = (size_t)(t - v); if (n >= sizeof P.ver[0].build) n = sizeof P.ver[0].build - 1;
            memcpy(P.ver[P.nver].build, v, n); P.ver[P.nver].build[n] = 0;
            copy_str(P.ver[P.nver].ver, sizeof P.ver[0].ver, t + 1); P.nver++;
        }
    }
    // Some keys have a word form (game.tsv: display / full / console) and a number form (the header: 1 / 0): both are accepted,
    // because game.py writes the header's spelling and a hand-written profile may use either. Numbers are unambiguous: 0/1 for
    // Booleans, 0/1/2 for pad_layout (simple / full / touch) and 1/0 for the console/handheld mode.
    else if (!strcmp(k, "present_interval")) P.present_display = strchr("dD1", *v) != NULL && (!strcmp(v, "display") || isdigit((unsigned char)*v));
    else if (!strcmp(k, "core_preempt")) P.core_preempt = truthy(v);
    else if (!strcmp(k, "alloc_big_align")) P.alloc_big_align = truthy(v);
    else if (!strcmp(k, "fps_target")) P.fps_target = (int)num(v, (uint64_t)P.fps_target);
    else if (!strcmp(k, "fps_hold")) P.fps_hold = truthy(v);
    else if (!strcmp(k, "present_snap")) P.present_snap = truthy(v);
    else if (!strcmp(k, "pso_mtl4")) P.pso_mtl4 = truthy(v);
    else if (!strcmp(k, "shared_font")) P.shared_font_ttf = !strcmp(v, "ttf") || !strcmp(v, "1");
    else if (!strcmp(k, "pad_layout")) P.pad_layout = !strcmp(v, "full") || !strcmp(v, "1") ? 1 : !strcmp(v, "touch") || !strcmp(v, "2") ? 2 : 0;
    else if (!strcmp(k, "op_mode")) P.opmode = !strcmp(v, "console") ? 1 : !strcmp(v, "handheld") ? 0 : truthy(v);
    else if (!strcmp(k, "perf_mode")) P.perf_boost = !strcmp(v, "boost") ? 1 : !strcmp(v, "follow") ? 0 : truthy(v);
    else if (!strcmp(k, "feedback_snap")) copy_str(P.feedback_snap, sizeof P.feedback_snap, v);
    else if (!strcmp(k, "tex_flush_upload")) P.tex_flush_upload = truthy(v);
    else if (!strcmp(k, "render_cond")) P.render_cond = truthy(v);
    else if (!strcmp(k, "tex_dirty_upload")) P.tex_dirty_upload = truthy(v);
    else if (!strcmp(k, "tex_dyn_slots")) P.tex_dyn_slots = truthy(v);
    else if (!strcmp(k, "gpu_timestamps")) P.gpu_ts_segment = !strcmp(v, "segment") || !strcmp(v, "1");
    else if (!strcmp(k, "vconv_range")) P.vconv_range = truthy(v);
    else if (!strcmp(k, "device_api")) { char *e; P.nvn_api_major = (int)strtol(v, &e, 10); if (e && *e == '.') P.nvn_api_minor = atoi(e + 1); }
    else if (!strcmp(k, "game_args")) copy_str(P.args, sizeof P.args, v);
    else if (!strcmp(k, "game_env")) copy_str(P.genv, sizeof P.genv, v);
    // any other key (ipa, zip_store, shader_*, build, package, ...) is not a host constant: ignored
}

// The file: KEY<TAB>VALUE (game.tsv's form) or KEY VALUE, # starts a comment; blank lines are skipped.
static void read_file(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) { LOG("[RED] DM_PROFILE %s cannot be read; keeping the compiled profile", path); return; }
    char line[4096];
    int rows = 0;
    while (fgets(line, sizeof line, f)) {
        char *s = line; while (*s == ' ' || *s == '\t') s++;
        size_t L = strlen(s); while (L && (s[L-1] == '\n' || s[L-1] == '\r')) s[--L] = 0;
        if (!*s || *s == '#') continue;
        char *sep = strpbrk(s, "\t ");
        if (!sep) continue;
        *sep = 0;
        char *v = sep + 1; while (*v == '\t' || *v == ' ') v++;
        if (!strcmp(s, "build")) {   // build<TAB>version<TAB>display<TAB>main=<build id>...: one display-version row
            char *p = v, *cols[4] = {0}; int nc = 0;
            for (char *t = strtok(p, "\t"); t && nc < 4; t = strtok(NULL, "\t")) cols[nc++] = t;
            if (nc >= 2) { char buf[256]; snprintf(buf, sizeof buf, "%s\t%s", cols[0], cols[1]); set_kv("display_version", buf); }
            continue;
        }
        set_kv(s, v); rows++;
    }
    fclose(f);
    LOG("game profile %s: %d rows", path, rows);
}

// Environment: DM_PROF_<KEY> with the game.tsv key upper-cased (DM_PROF_MEM_RESERVE=0x140000000).
static void read_env(void) {
    static const char *keys[] = {"TITLE_ID","NAME","ROMFS_MARKER","PROGRAM_ID","MODULES","MEM_RESERVE","MEM_ALIAS","MEM_STACK","APP_POOL",
        "MEM_USED","SYS_RESOURCE","MEM_MAP_LIMIT","PRESENT_INTERVAL","CORE_PREEMPT","ALLOC_BIG_ALIGN","FPS_TARGET","FPS_HOLD","PRESENT_SNAP",
        "PSO_MTL4","SHARED_FONT","PAD_LAYOUT","OP_MODE","PERF_MODE","FEEDBACK_SNAP","TEX_FLUSH_UPLOAD","RENDER_COND","TEX_DIRTY_UPLOAD",
        "TEX_DYN_SLOTS","GPU_TIMESTAMPS","VCONV_RANGE","DEVICE_API","GAME_ARGS","GAME_ENV", NULL};
    char k[64], name[96];
    for (int i = 0; keys[i]; i++) {
        snprintf(k, sizeof k, "%s", keys[i]);
        for (char *p = k; *p; p++) *p = (char)tolower((unsigned char)*p);
        snprintf(name, sizeof name, "DM_PROF_%s", keys[i]);
        const char *v = getenv(name);
        if (v) set_kv(k, v);
    }
}

static void load(void) {
    defaults();
    const char *path = getenv("DM_PROFILE");
    if (path && *path) { copy_str(P.source, sizeof P.source, path); read_file(path); }
    read_env();   // DM_PROF_* overrides apply on top of the file or of the compiled profile
    if (P.nmod <= 0) {   // a profile file that names no modules: the compiled list, which is the one the executable embeds
        static const char *m[] = DM_GAME_MODULES; int n = DM_GAME_NMOD; if (n > DM_PROF_MAX_MOD) n = DM_PROF_MAX_MOD;
        for (int i = 0; i < n; i++) { copy_str(P.modbuf[i], sizeof P.modbuf[i], m[i]); P.modules[i] = P.modbuf[i]; } P.nmod = n;
    }
    g_loaded = 1;
}

const struct dm_profile *dm_profile(void) {
    if (!g_loaded) load();
    return &P;
}

void dm_profile_log(void) {
    const struct dm_profile *p = dm_profile();
    LOG("game profile: %s (%s) from %s", p->id, p->name, p->source);
    LOG("  modules %d%s%s%s  program %016llx  reserve %#llx alias %#llx stack %#llx pool %#llx used %#llx sysres %#llx map_limit %d",
        p->nmod, p->nmod > 0 ? ":" : "", p->nmod > 0 ? p->modules[0] : "", p->nmod > 1 ? " ..." : "",
        (unsigned long long)p->program_id, (unsigned long long)p->mem_reserve, (unsigned long long)p->mem_alias,
        (unsigned long long)p->mem_stack, (unsigned long long)p->app_pool, (unsigned long long)p->mem_used,
        (unsigned long long)p->sys_resource, p->mem_map_limit);
    LOG("  switches present_display %d core_preempt %d big_align %d fps %d hold %d snap %d pso4 %d font_ttf %d pad %d opmode %d boost %d",
        p->present_display, p->core_preempt, p->alloc_big_align, p->fps_target, p->fps_hold, p->present_snap, p->pso_mtl4,
        p->shared_font_ttf, p->pad_layout, p->opmode, p->perf_boost);
    LOG("  graphics flush %d dirty %d rcond %d dynslots %d gputs %d vconv %d nvn_api %d.%d  versions %d",
        p->tex_flush_upload, p->tex_dirty_upload, p->render_cond, p->tex_dyn_slots, p->gpu_ts_segment, p->vconv_range,
        p->nvn_api_major, p->nvn_api_minor, p->nver);
}
