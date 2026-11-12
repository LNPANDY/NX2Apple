// Writable Mach-O segment snapshot and restore helpers for DmShell (LNPANDY/NX2Apple#451).
// Preserves initial non-zero bytes in __data, __common and __bss (including unaligned head and
// tail bytes in [0..7] around 8-byte aligned interior words) so returning to the library resets
// a game framework's static state cleanly without losing dyld or initializer writes.
#ifndef DM_SHELL_SEG_SNAP_H
#define DM_SHELL_SEG_SNAP_H

#include <mach-o/getsect.h>
#include <mach-o/loader.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

typedef struct {
    uint8_t *data_ptr;
    uint8_t *data_snap;
    size_t data_sz;
    uint8_t *common_ptr;
    uint8_t *common_snap;
    size_t common_sz;
    uint8_t *bss_ptr;
    size_t bss_sz;
    struct { size_t off; uint64_t val; } *bss_nz;
    size_t bss_nnz;
    uint8_t bss_head[7];
    uint8_t bss_head_len;
    uint8_t bss_tail[7];
    uint8_t bss_tail_len;
} DmSegSnap;

static inline __attribute__((unused)) void dm_seg_snap_free(DmSegSnap *s) {
    if (!s) return;
    free(s->data_snap);
    free(s->common_snap);
    free(s->bss_nz);
    memset(s, 0, sizeof *s);
}

static inline __attribute__((unused)) void dm_seg_snap_save_raw(
    DmSegSnap *s,
    uint8_t *data_ptr, size_t data_sz,
    uint8_t *common_ptr, size_t common_sz,
    uint8_t *bss_ptr, size_t bss_sz
) {
    if (!s) return;
    memset(s, 0, sizeof *s);
    s->data_ptr = data_ptr;
    s->data_sz = data_sz;
    s->common_ptr = common_ptr;
    s->common_sz = common_sz;
    s->bss_ptr = bss_ptr;
    s->bss_sz = bss_sz;

    if (s->data_ptr && s->data_sz) {
        s->data_snap = (uint8_t *)malloc(s->data_sz);
        if (s->data_snap) memcpy(s->data_snap, s->data_ptr, s->data_sz);
    }
    if (s->common_ptr && s->common_sz) {
        s->common_snap = (uint8_t *)malloc(s->common_sz);
        if (s->common_snap) memcpy(s->common_snap, s->common_ptr, s->common_sz);
    }
    if (s->bss_ptr && s->bss_sz) {
        uintptr_t b0 = (uintptr_t)s->bss_ptr;
        size_t sz = s->bss_sz;
        if (sz > UINTPTR_MAX - b0) return;
        uintptr_t b1 = b0 + sz;
        size_t pg = (size_t)getpagesize();
        if (pg < 8U || (pg & (pg - 1U)) != 0) pg = 4096U;
        uintptr_t pmask = (uintptr_t)(pg - 1U);
        uintptr_t p0 = b0 & ~pmask;
        size_t b1_rem = (size_t)(b1 & pmask);
        uintptr_t p1 = b1_rem ? (b1 <= UINTPTR_MAX - (pg - b1_rem) ? b1 + (pg - b1_rem) : b1) : b1;
        size_t np = p1 >= p0 ? (size_t)((p1 - p0) / pg) : 0;
        char *vec = np ? (char *)malloc(np) : NULL;
        int mc_ok = vec && np && mincore((const void *)p0, p1 - p0, vec) == 0;

        // Partition [b0, b1) into disjoint [b0, mid0) head (0..7 B), [mid0, mid1) 8-byte aligned
        // interior words, and [mid1, b1) tail (0..7 B). Because page sizes are multiples of 8,
        // neither the head nor the tail ever crosses a page boundary.
        size_t rem0 = (size_t)(b0 & (uintptr_t)7U);
        size_t head_len = rem0 ? (sz < (8U - rem0) ? sz : (8U - rem0)) : 0;
        uintptr_t mid0 = b0 + head_len;
        size_t rem_sz = sz - head_len;
        size_t mid_sz = rem_sz & ~(size_t)7U;
        uintptr_t mid1 = mid0 + mid_sz;
        size_t tail_len = rem_sz & (size_t)7U;

        s->bss_head_len = (uint8_t)head_len;
        if (head_len) {
            if (!mc_ok || (vec[0] & (MINCORE_INCORE | MINCORE_PAGED_OUT))) {
                memcpy(s->bss_head, (const void *)b0, head_len);
            }
        }

        size_t cap = 0;
        if (mid_sz && np) {
            for (size_t p = 0; p < np; p++) {
                if (mc_ok && !(vec[p] & (MINCORE_INCORE | MINCORE_PAGED_OUT))) continue;
                uintptr_t a0 = p0 + p * pg;
                uintptr_t a1 = a0 + pg;
                if (a0 < mid0) a0 = mid0;
                if (a1 > mid1) a1 = mid1;
                for (uintptr_t a = a0; a < a1 && a <= UINTPTR_MAX - 8U && a + 8U <= a1; a += 8U) {
                    uint64_t v = 0;
                    memcpy(&v, (const void *)a, sizeof v);
                    if (!v) continue;
                    if (s->bss_nnz == cap) {
                        if (cap > SIZE_MAX / (2U * sizeof s->bss_nz[0])) break;
                        size_t ncap = cap ? cap * 2U : 64U;
                        void *nb = realloc(s->bss_nz, ncap * sizeof s->bss_nz[0]);
                        if (!nb) break;
                        s->bss_nz = nb;
                        cap = ncap;
                    }
                    s->bss_nz[s->bss_nnz].off = (size_t)(a - b0);
                    s->bss_nz[s->bss_nnz].val = v;
                    s->bss_nnz++;
                }
            }
        }

        s->bss_tail_len = (uint8_t)tail_len;
        if (tail_len) {
            size_t tail_page = (size_t)((mid1 - p0) / pg);
            if (!mc_ok || tail_page >= np || (vec[tail_page] & (MINCORE_INCORE | MINCORE_PAGED_OUT))) {
                memcpy(s->bss_tail, (const void *)mid1, tail_len);
            }
        }

        free(vec);
    }
}

static inline __attribute__((unused)) void dm_seg_snap_save(const struct mach_header_64 *mh, const char *segname, DmSegSnap *s) {
    if (!mh || !segname || !s) return;
    unsigned long dsz = 0, csz = 0, bsz = 0;
    uint8_t *dptr = getsectiondata(mh, segname, "__data", &dsz);
    uint8_t *cptr = getsectiondata(mh, segname, "__common", &csz);
    uint8_t *bptr = getsectiondata(mh, segname, "__bss", &bsz);
    dm_seg_snap_save_raw(s, dptr, (size_t)dsz, cptr, (size_t)csz, bptr, (size_t)bsz);
}

static inline __attribute__((unused)) void dm_seg_snap_restore(const DmSegSnap *s) {
    if (!s) return;
    if (s->data_ptr && s->data_snap && s->data_sz) memcpy(s->data_ptr, s->data_snap, s->data_sz);
    if (s->common_ptr && s->common_snap && s->common_sz) memcpy(s->common_ptr, s->common_snap, s->common_sz);
    if (s->bss_ptr && s->bss_sz) {
        uintptr_t b0 = (uintptr_t)s->bss_ptr;
        size_t sz = s->bss_sz;
        if (sz > UINTPTR_MAX - b0) return;
        uintptr_t b1 = b0 + sz;
        size_t pg = (size_t)getpagesize();
        if (pg < 8U || (pg & (pg - 1U)) != 0) pg = 4096U;
        uintptr_t pmask = (uintptr_t)(pg - 1U);
        size_t b0_rem = (size_t)(b0 & pmask);
        uintptr_t p0 = b0_rem ? (b0 <= UINTPTR_MAX - (pg - b0_rem) ? b0 + (pg - b0_rem) : b1) : b0;
        uintptr_t p1 = b1 & ~pmask;
        if (p1 > p0) {
            if (p0 > b0) memset((void *)b0, 0, p0 - b0);
            if (mmap((void *)p0, p1 - p0, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE | MAP_FIXED, -1, 0) == MAP_FAILED)
                memset((void *)p0, 0, p1 - p0);
            if (b1 > p1) memset((void *)p1, 0, b1 - p1);
        } else {
            memset(s->bss_ptr, 0, sz);
        }
        if (s->bss_head_len && s->bss_head_len <= sz) {
            memcpy(s->bss_ptr, s->bss_head, s->bss_head_len);
        }
        for (size_t i = 0; i < s->bss_nnz; i++) {
            if (sz >= sizeof s->bss_nz[i].val && s->bss_nz[i].off <= sz - sizeof s->bss_nz[i].val) {
                memcpy(s->bss_ptr + s->bss_nz[i].off, &s->bss_nz[i].val, sizeof s->bss_nz[i].val);
            }
        }
        if (s->bss_tail_len && s->bss_tail_len <= sz) {
            memcpy(s->bss_ptr + (sz - s->bss_tail_len), s->bss_tail, s->bss_tail_len);
        }
    }
}

#endif
