// Unreal console variables found by name (dm_ue_cvar) and the texture pool raise (dm_ue_cvar_tick) against a synthetic main: a static constructor's registration sequence, a lookup
// that only reads the name, UTF-16 and UTF-32 names, a name registered twice, and the values the host raises, keeps and leaves
#include "../hle_uecvar.c"
#include <assert.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>

static module_t test_modules[1];
module_t *g_mod = test_modules;
int g_nmod;
static int writes;
void dm_guest_write_prepare(void *p, size_t n) { (void)p; assert(n == 4); writes++; }

enum { TEXT_END = 0x10000, RO = 0x10000, DATA = 0x20000, SIZE = 0x30000 };
static uint32_t adrp(unsigned rd, uint64_t at, uint64_t to) {
    int64_t imm = (int64_t)(to & ~0xfffull) / 0x1000 - (int64_t)(at & ~0xfffull) / 0x1000;
    return 0x90000000u | (uint32_t)(imm & 3) << 29 | (uint32_t)((imm >> 2) & 0x7ffff) << 5 | rd;
}
static uint32_t add(unsigned rd, unsigned rn, uint64_t to) { return 0x91000000u | (uint32_t)(to & 0xfff) << 10 | rn << 5 | rd; }
// A static constructor at word w registering the name at `name` as the object at `obj` (DRAGON QUEST VII Reimagined's main+0x4a1c630, shortened); with store 0, a lookup
// (FindConsoleVariable, then a call on the result) that never stores a value pointer
static unsigned emit(uint32_t *t, unsigned w, uint64_t name, uint64_t obj, int store) {
    t[w] = adrp(1, w * 4, name); w++; t[w] = add(1, 1, name); w++;
    t[w++] = 0xf9400008;                                   // ldr x8, [x0]
    t[w++] = 0x52800022;                                   // mov w2, #1
    t[w++] = 0xd63f0100;                                   // blr x8
    if (store) {
        t[w] = adrp(19, w * 4, obj); w++; t[w] = add(19, 19, obj); w++;
        t[w++] = 0xa9000277;                               // stp x23, x0, [x19]
        t[w++] = 0xf9400008; t[w++] = 0xd63f0100;          // ldr x8, [x0]; blr x8 (AsVariableInt)
        t[w++] = 0xf9000a60;                               // str x0, [x19, #0x10]
    } else t[w++] = 0xb9000260;                            // str w0, [x19] (a 32-bit store of the value read)
    t[w++] = 0xd65f03c0;                                   // ret
    return w;
}
static void put_name(uint8_t *at, const char *s, int z) { for (size_t c = 0; c <= strlen(s); c++) { memset(at + c * z, 0, z); at[c * z] = (uint8_t)s[c]; } }

static void check(int which) {
    uint8_t *base = mmap(NULL, SIZE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0); assert(base != MAP_FAILED);
    g_nmod = 1; strcpy(g_mod[0].name, "main"); g_mod[0].base = base; g_mod[0].size = SIZE;
    g_mod[0].text_end = TEXT_END; g_mod[0].ro_off = RO; g_mod[0].data_off = DATA;
    uint32_t *t = (uint32_t *)base; unsigned w = 0x100;
    uint64_t name = RO + 0x2a0, obj = DATA + 0x5c8, other = DATA + 0x700;
    put_name(base + RO + 0x40, "r.Streaming.PoolSizeForMeshes", 2);   // a longer name that starts the same is another variable
    put_name(base + name, "r.Streaming.PoolSize", which == 1 ? 4 : 2);
    w = emit(t, w, name, 0, 0);                                        // a lookup before the registration
    w = emit(t, w, name, obj, 1);
    if (which == 2) emit(t, w, name, other, 1);                        // registered twice: no single object
    int32_t vals[2] = {200, 200};
    *(uintptr_t *)(base + obj + 0x10) = (uintptr_t)vals;
    setenv("DM_UE_TEXTURE_POOL", which == 3 ? "0" : "1000", 1);
    if (which == 2) { assert(!dm_ue_cvar("r.Streaming.PoolSize")); dm_ue_cvar_tick(); assert(vals[0] == 200 && writes == 0); return; }
    if (which == 3) { dm_ue_cvar_tick(); assert(vals[0] == 200 && vals[1] == 200 && writes == 0); return; }
    assert(dm_ue_cvar("r.Streaming.PoolSize") == obj);
    assert(!dm_ue_cvar("r.Streaming.LimitPoolSizeToVRAM"));            // not in main
    dm_ue_cvar_tick(); assert(vals[0] == 1000 && vals[1] == 1000 && writes == 2);
    dm_ue_cvar_tick(); assert(writes == 2);                            // already raised
    vals[0] = vals[1] = 200; dm_ue_cvar_tick(); assert(vals[0] == 1000 && writes == 4);   // the game set its device profile again
    vals[0] = 2000; vals[1] = -1; dm_ue_cvar_tick(); assert(vals[0] == 2000 && vals[1] == -1 && writes == 4);   // a larger pool and no pool size stay
    munmap(base, SIZE);
}

int main(void) {
    // Each process starts the one-time search with fresh state
    for (int i = 0; i < 4; i++) {
        pid_t p = fork(); assert(p >= 0);
        if (!p) { check(i); _exit(0); }
        int status; assert(waitpid(p, &status, 0) == p); assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    }
    puts("Unreal console variables: found by UTF-16 and UTF-32 name, lookups and double registrations skipped, the texture pool raised, kept and left as set");
}
