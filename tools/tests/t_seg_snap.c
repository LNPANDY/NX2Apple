// Unit tests for DmSegSnap (frontend-ios/Shell/App/SegSnap.h).
// Exercises empty sections, every start modulo-8 alignment (0..7), page-straddling tiny spans,
// and multi-page (>32 KB) sparse regions across repeated mutations and restores.
#include "SegSnap.h"
#include <assert.h>
#include <stdio.h>

#define GUARD_LEN 32U

static uint8_t guard_byte(size_t idx, uint8_t salt) {
    return (uint8_t)(((idx * 37U) + salt) ^ 0xA5U) | 1U;
}

static uint8_t init_pattern(size_t off, size_t sz) {
    // Always put non-zero bytes at the very start and very end while leaving interior zero runs
    // mixed with non-zero bytes so both bss_nz and zeroed regions are exercised together.
    if (off < 7U || off + 7U >= sz) {
        return (uint8_t)(((off * 53U) + 0x31U) | 1U);
    }
    size_t word_idx = off / 8U;
    if ((word_idx % 3U) == 1U) {
        return 0U;
    }
    return (uint8_t)(((off * 17U) + 0x5DU) & 0xFFU);
}

static void check_guards(const uint8_t *pre, const uint8_t *post, uint8_t salt) {
    for (size_t i = 0; i < GUARD_LEN; i++) {
        assert(pre[i] == guard_byte(i, salt));
        assert(post[i] == guard_byte(i + GUARD_LEN, salt));
    }
}

static void test_empty_and_null(size_t pg) {
    dm_seg_snap_save_raw(NULL, NULL, 0, NULL, 0, NULL, 0);
    dm_seg_snap_restore(NULL);
    dm_seg_snap_free(NULL);

    uint8_t *buf = (uint8_t *)mmap(NULL, pg, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    assert(buf != MAP_FAILED);
    for (size_t i = 0; i < 64U; i++) buf[i] = guard_byte(i, 0x11U);

    DmSegSnap snap;
    memset(&snap, 0x7F, sizeof snap);
    dm_seg_snap_save_raw(&snap, buf + 16U, 0, buf + 24U, 0, buf + 32U, 0);
    assert(snap.bss_head_len == 0);
    assert(snap.bss_tail_len == 0);
    assert(snap.bss_nnz == 0);
    dm_seg_snap_restore(&snap);
    for (size_t i = 0; i < 64U; i++) assert(buf[i] == guard_byte(i, 0x11U));
    dm_seg_snap_free(&snap);

    assert(munmap(buf, pg) == 0);
}

static void run_one_span(uint8_t *ptr, size_t sz, uint8_t salt) {
    uint8_t *pre = ptr - GUARD_LEN;
    uint8_t *post = ptr + sz;
    uint8_t *expected = (uint8_t *)malloc(sz);
    assert(expected != NULL);

    uint8_t data_buf[13];
    uint8_t data_exp[13];
    uint8_t common_buf[7];
    uint8_t common_exp[7];
    for (size_t i = 0; i < sizeof data_buf; i++) {
        data_buf[i] = (uint8_t)(0x40U + i + salt);
        data_exp[i] = data_buf[i];
    }
    for (size_t i = 0; i < sizeof common_buf; i++) {
        common_buf[i] = (uint8_t)(0x80U + i + salt);
        common_exp[i] = common_buf[i];
    }

    for (size_t i = 0; i < GUARD_LEN; i++) {
        pre[i] = guard_byte(i, salt);
        post[i] = guard_byte(i + GUARD_LEN, salt);
    }
    for (size_t i = 0; i < sz; i++) {
        uint8_t v = init_pattern(i, sz);
        ptr[i] = v;
        expected[i] = v;
    }

    DmSegSnap snap;
    dm_seg_snap_save_raw(&snap, data_buf, sizeof data_buf, common_buf, sizeof common_buf, ptr, sz);

    // First mutation: clobber head and tail to zero and interior to non-zero garbage.
    memset(data_buf, 0xEE, sizeof data_buf);
    memset(common_buf, 0xDD, sizeof common_buf);
    for (size_t i = 0; i < sz; i++) {
        ptr[i] = (i < 8U || i + 8U >= sz) ? 0U : (uint8_t)(0xAAU ^ (i & 0xFFU));
    }
    dm_seg_snap_restore(&snap);
    check_guards(pre, post, salt);
    assert(memcmp(data_buf, data_exp, sizeof data_buf) == 0);
    assert(memcmp(common_buf, common_exp, sizeof common_buf) == 0);
    assert(memcmp(ptr, expected, sz) == 0);

    // Second mutation: flip every byte and restore a second time to verify idempotence.
    memset(data_buf, 0x00, sizeof data_buf);
    memset(common_buf, 0xFF, sizeof common_buf);
    for (size_t i = 0; i < sz; i++) {
        ptr[i] = (uint8_t)(~expected[i]);
    }
    dm_seg_snap_restore(&snap);
    check_guards(pre, post, salt);
    assert(memcmp(data_buf, data_exp, sizeof data_buf) == 0);
    assert(memcmp(common_buf, common_exp, sizeof common_buf) == 0);
    assert(memcmp(ptr, expected, sz) == 0);

    dm_seg_snap_free(&snap);
    free(expected);
}

static void test_small_alignments_and_page_seams(size_t pg) {
    size_t map_sz = pg * 3U;
    uint8_t *region = (uint8_t *)mmap(NULL, map_sz, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    assert(region != MAP_FAILED);

    // Every start alignment b0 % 8 in 0..7 and every length 1..35 inside page 0.
    for (size_t rem = 0; rem < 8U; rem++) {
        for (size_t sz = 1U; sz <= 35U; sz++) {
            uint8_t *ptr = region + 64U + rem;
            run_one_span(ptr, sz, (uint8_t)(rem * 41U + sz));
        }
    }

    // Spans starting 1..15 bytes before the end of page 0 and crossing into page 1.
    for (size_t back = 1U; back <= 15U; back++) {
        for (size_t sz = 1U; sz <= 35U; sz++) {
            uint8_t *ptr = region + pg - back;
            run_one_span(ptr, sz, (uint8_t)(back * 29U + sz));
        }
    }

    assert(munmap(region, map_sz) == 0);
}

static void test_multipage_sparse_and_unaligned(size_t pg) {
    const size_t lengths[] = { 32771U, (pg * 3U) + 5U };
    for (size_t li = 0; li < sizeof lengths / sizeof lengths[0]; li++) {
        size_t sz = lengths[li];
        for (size_t rem = 0; rem < 8U; rem++) {
            size_t map_sz = sz + (pg * 2U);
            map_sz = (map_sz + pg - 1U) & ~(pg - 1U);
            uint8_t *region = (uint8_t *)mmap(NULL, map_sz, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
            assert(region != MAP_FAILED);

            uint8_t *ptr = region + 64U + rem;
            uint8_t *pre = ptr - GUARD_LEN;
            uint8_t *post = ptr + sz;
            uint8_t salt = (uint8_t)(0x20U + rem + li * 9U);

            uint8_t *expected = (uint8_t *)calloc(sz, 1U);
            assert(expected != NULL);

            for (size_t i = 0; i < GUARD_LEN; i++) {
                pre[i] = guard_byte(i, salt);
                post[i] = guard_byte(i + GUARD_LEN, salt);
            }

            // Touch only the first 24 bytes and the last 24 bytes (including unaligned head and
            // tail bytes) while leaving interior whole pages untouched so mincore sees zero pages.
            for (size_t i = 0; i < 24U && i < sz; i++) {
                uint8_t v = (uint8_t)((0xC1U + i * 3U + rem) | 1U);
                ptr[i] = v;
                expected[i] = v;
            }
            for (size_t i = (sz > 24U ? sz - 24U : 0U); i < sz; i++) {
                uint8_t v = (uint8_t)((0x91U + (sz - i) * 5U + rem) | 1U);
                ptr[i] = v;
                expected[i] = v;
            }

            DmSegSnap snap;
            dm_seg_snap_save_raw(&snap, NULL, 0, NULL, 0, ptr, sz);

            // Dirty every page in [ptr, ptr + sz), zeroing the head and tail to catch missed bytes.
            memset(ptr, 0x5A, sz);
            memset(ptr, 0x00, 16U);
            memset(ptr + sz - 16U, 0x00, 16U);

            dm_seg_snap_restore(&snap);
            check_guards(pre, post, salt);
            assert(memcmp(ptr, expected, sz) == 0);

            // Dirty a second time after MAP_FIXED replacement and restore again.
            memset(ptr, 0x33, sz);
            dm_seg_snap_restore(&snap);
            check_guards(pre, post, salt);
            assert(memcmp(ptr, expected, sz) == 0);

            dm_seg_snap_free(&snap);
            free(expected);
            assert(munmap(region, map_sz) == 0);
        }
    }
}

int main(void) {
    size_t pg = (size_t)getpagesize();
    test_empty_and_null(pg);
    test_small_alignments_and_page_seams(pg);
    test_multipage_sparse_and_unaligned(pg);
    printf("t_seg_snap: ok (page=%zu)\n", pg);
    return 0;
}
