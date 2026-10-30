// Unreal console variables found by their registered names, and the texture streaming pool the profile's ue_texture_pool raises.
// A TAutoConsoleVariable is a global in main's data: its static constructor loads the name (adrp + add), registers it through IConsoleManager (a blr), takes the object's address
// (adrp + add) and stores the variable's value pointer at +0x10 (str x0, [xN, #0x10]); the value holds the game thread's copy, then the render thread's. The same sequence registers every
// variable in the Unreal games here: OCTOPATH TRAVELER and Yoshi's Crafted World (UE 4.1x, UTF-32 names), Pikmin 4 (4.26), OCTOPATH TRAVELER II and DRAGON QUEST VII Reimagined (4.27, UTF-16)
// and Octopath Traveler 0 (UE 5, a base constructor called between the address and the store), and it gives the addresses hle_fpslock.c's rows were found at by hand. Called on every present
// (hle_nvn.c); the search runs once, on the first.
#include "hle.h"
#include <mach/mach.h>
#include <TargetConditionals.h>

static int rd(uint64_t a, void *out, size_t n) { vm_size_t got = 0; return a >= 0x1000 && vm_read_overwrite(mach_task_self(), (vm_address_t)a, n, (vm_address_t)out, &got) == KERN_SUCCESS && got == n; }

static int64_t adrp_page(const uint32_t *w, uint64_t i) {   // the page an adrp at word i loads, relative to the module's base
    uint32_t v = w[i]; int64_t imm = (int64_t)(((v >> 29) & 3) | (((v >> 5) & 0x7ffff) << 2));
    if (imm & (1 << 20)) imm -= 1 << 21;
    return (int64_t)((i * 4) & ~0xfffull) + imm * 0x1000;
}
static int add_imm(uint32_t u, unsigned *rd_, unsigned *rn, uint32_t *imm) {   // add Xd, Xn, #imm (64-bit, optionally shifted by 12)
    if ((u & 0xff800000) != 0x91000000) return 0;
    *rd_ = u & 31; *rn = (u >> 5) & 31; *imm = ((u >> 10) & 0xfff) << (12 * ((u >> 22) & 1)); return 1;
}
static int is_adrp(uint32_t u) { return (u & 0x9f000000) == 0x90000000; }

// The object registered under `name` at a reference to its name string (word j): the register call, then the store of the value pointer into an address made by adrp + add; 0 if not one
static uint64_t registered_at(const uint32_t *w, uint64_t n, uint64_t j) {
    int called = 0, have[32] = {0}; int64_t val[32];
    for (uint64_t t = j + 1; t < n && t < j + 40; t++) {
        uint32_t u = w[t]; unsigned d, s; uint32_t imm;
        if ((u & 0xfffffc1f) == 0xd63f0000) { called = 1; continue; }                                  // blr
        if (is_adrp(u)) { have[u & 31] = 1; val[u & 31] = adrp_page(w, t); continue; }
        if (add_imm(u, &d, &s, &imm)) { if (have[s]) { have[d] = 1; val[d] = val[s] + imm; } else have[d] = 0; continue; }
        if (called && (u & 0xffc0001f) == 0xf9000000 && ((u >> 10) & 0xfff) == 2 && have[(u >> 5) & 31])   // str x0, [xN, #0x10]
            return (uint64_t)val[(u >> 5) & 31];
        if ((u & 0xfc000000) == 0x14000000 || u == 0xd65f03c0) break;                                  // b, ret: the constructor ended
    }
    return 0;
}

// main's offset of the TAutoConsoleVariable registered under `name` (UTF-16 or UTF-32 in main's read-only data), 0 if none is found or the name is registered twice
uint64_t dm_ue_cvar(const char *name) {
    module_t *m = NULL;
    for (int i = 0; i < g_nmod; i++) if (!strcmp(g_mod[i].name, "main")) m = &g_mod[i];
    if (!m || !m->text_end || m->ro_off >= m->data_off) return 0;
    size_t len = strlen(name); uint64_t found = 0; int hits = 0;
    for (int z = 2; z <= 4; z += 2) {   // TCHAR: UTF-16 (UE 4.2x and 5), UTF-32 (older Switch builds)
        uint8_t pat[256] = {0}; size_t pl = (len + 1) * (size_t)z;
        if (pl > sizeof pat) return 0;
        for (size_t c = 0; c < len; c++) pat[c * (size_t)z] = (uint8_t)name[c];
        const uint8_t *ro = m->base + m->ro_off, *end = m->base + m->data_off;
        for (const uint8_t *p = ro; (p = memmem(p, (size_t)(end - p), pat, pl)); p += z) {
            if ((p - m->base) % z) continue;   // characters are aligned to their size
            uint64_t s = (uint64_t)(p - m->base); const uint32_t *w = (const uint32_t *)m->base; uint64_t n = m->text_end / 4;
            for (uint64_t i = 0; i < n; i++) {
                if (!is_adrp(w[i]) || adrp_page(w, i) != (int64_t)(s & ~0xfffull)) continue;
                for (uint64_t j = i + 1; j < n && j < i + 6; j++) {
                    unsigned d, r; uint32_t imm;
                    if (!add_imm(w[j], &d, &r, &imm) || r != (w[i] & 31) || imm != (s & 0xfff)) continue;
                    uint64_t o = registered_at(w, n, j);
                    if (o && o != found) { found = o; hits++; }
                    break;
                }
            }
        }
    }
    return hits == 1 ? found : 0;
}

// ue_texture_pool: r.Streaming.PoolSize, the megabytes Unreal's texture streamer keeps resident; past it the streamer drops the top mips of the textures in view. The game's
// device profile sets it (DRAGON QUEST VII Reimagined: 200 on the Switch, 1000 on Windows) and the streaming manager reads it again whenever it changes. The host raises a smaller
// value the game sets to the target, whenever the game sets it back; a larger one, or -1 (no pool size: the engine sizes its pool otherwise), stays. The profile key applies on the
// Mac; on iOS only DM_UE_TEXTURE_POOL turns it on (Documents/env.txt), until an iPhone run shows the memory fits. DM_UE_TEXTURE_POOL=0 leaves the game's value
void dm_ue_cvar_tick(void) {
    static int state = -1, target, nlog; static uint64_t obj_off; static const char *src;
    if (!state) return;
    if (state < 0) {
        state = 0;
        const char *e = getenv("DM_UE_TEXTURE_POOL");
        target = e ? atoi(e) : TARGET_OS_IPHONE ? 0 : DM_GAME_UE_TEXTURE_POOL; src = e ? "DM_UE_TEXTURE_POOL" : "game profile ue_texture_pool";
        if (target <= 0) { if (DM_GAME_UE_TEXTURE_POOL) LOG("main: Unreal r.Streaming.PoolSize left as the game sets it (%s)", e ? src : "iOS without DM_UE_TEXTURE_POOL"); return; }
        struct timespec t0, t1; clock_gettime(CLOCK_MONOTONIC, &t0);
        obj_off = dm_ue_cvar("r.Streaming.PoolSize");
        clock_gettime(CLOCK_MONOTONIC, &t1); double ms = (double)(t1.tv_sec - t0.tv_sec) * 1e3 + (double)(t1.tv_nsec - t0.tv_nsec) / 1e6;
        if (!obj_off) { LOG("[RED] main: Unreal r.Streaming.PoolSize not found in main (%s %d MB not applied; searched in %.1f ms)", src, target, ms); return; }
        LOG("main: Unreal r.Streaming.PoolSize at main+%#llx (found in %.1f ms), raised to %d MB (%s)", (unsigned long long)obj_off, ms, target, src);
        state = 1;
    }
    uint8_t *base = NULL;
    for (int i = 0; i < g_nmod; i++) if (!strcmp(g_mod[i].name, "main")) base = g_mod[i].base;
    uint64_t val;
    if (!base || !rd((uint64_t)(uintptr_t)(base + obj_off + 0x10), &val, sizeof val) || !val) return;   // not created yet
    for (int c = 0; c < 2; c++) {
        int32_t cur, *p = (int32_t *)(uintptr_t)(val + 4 * (uint64_t)c);
        if (!rd((uint64_t)(uintptr_t)p, &cur, sizeof cur) || cur <= 0 || cur >= target) continue;
        dm_guest_write_prepare(p, sizeof *p); __atomic_store_n(p, target, __ATOMIC_RELAXED);
        if (nlog < 8) { nlog++; LOG("main: Unreal r.Streaming.PoolSize (%s thread) %d → %d MB (%s)", c ? "render" : "game", cur, target, src); }
    }
}
