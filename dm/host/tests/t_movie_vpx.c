// Synthetic 16x16 red key frames encoded with ffmpeg's libvpx encoders; no game data.
// Include the real decoder, without registering unrelated SDK hooks in this test.
#include "../hle.h"
#undef HLE_FORCE
#define HLE_FORCE(mangled, why, ret, cname, ...) static ret cname(__VA_ARGS__)
#include "../hle_movie.c"
#include <assert.h>

static const uint8_t vp8[] = {
    0xf0,0x02,0x00,0x9d,0x01,0x2a,0x10,0x00,0x10,0x00,0x00,0x47,0x08,0x85,0x85,0x88,
    0x85,0x84,0x88,0x02,0x02,0x02,0x75,0xaa,0x03,0xf8,0x03,0xfa,0x02,0x0d,0x4d,0x18,
    0x00,0xfe,0xfd,0x6e,0xf3,0xff,0xe3,0x99,0x37,0x30,0xc4,0xff,0x8e,0x6d,0xff,0xf1,
    0x61,0x3c,0x0e,0x28,0xc8,0xff,0xf1,0x51,0x00,
};
static const uint8_t vp9[] = {
    0x82,0x49,0x83,0x42,0x00,0x00,0xf0,0x00,0xf6,0x00,0x38,0x24,0x1c,0x18,0x4a,0x00,
    0x00,0x30,0x60,0x00,0x00,0x10,0xbf,0xff,0xf7,0x1d,0xaf,0xff,0xff,0xff,0x5f,0xdf,
    0xff,0xff,0xff,0xf2,0x2a,0xc0,0x00,
};
static void decode(int type, int format, const uint8_t *packet, int size) {
    mdec_t d = { .type = type, .fmt = format, .w = 16, .h = 16 };
    assert(md_vpx(&d, packet, size, 0) == 1);
    const uint8_t *p = d.out[0].frm;
    if (format == MD_FMT_NV12) {
        assert(d.out[0].cap == 16 * 16 * 3 / 2);
        for (int i = 0; i < 256; i++) assert(abs(p[i] - 81) <= 3);
        for (int i = 256; i < 384; i += 2) { assert(abs(p[i] - 90) <= 3); assert(abs(p[i+1] - 240) <= 3); }
    } else {
        assert(d.out[0].cap == 16 * 16 * 4);
        for (int i = 0; i < 1024; i += 4) assert(p[i] >= 250 && p[i+1] <= 5 && p[i+2] <= 5 && p[i+3] == 255);
    }
    vpx_codec_destroy(&d.vpx);
    free(d.out[0].frm);
}
// The frame step's movie signal (dm_movie_playing): a video picture handed out raises it for MD_PLAYING_NS; an audio output does not
static uint64_t test_now = 1000000000ull;
uint64_t now_ns(void) { return test_now; }
__thread _Atomic int dm_host_work;   // hle_thread.c
static void playing(void) {
    static mdec_t video = { .type = MD_TYPE_VP9, .nout = MD_NOUT_VIDEO, .started = 1 }, audio = { .type = MD_TYPE_VORBIS, .nout = MD_NOUT, .started = 1 };
    pthread_mutex_init(&video.mu, NULL); pthread_mutex_init(&audio.mu, NULL);
    void *vs[2] = { NULL, &video }, *as[2] = { NULL, &audio };
    int idx, left; int64_t pts; uint32_t flags;
    assert(!dm_movie_playing());
    audio.outq[0] = 0; audio.noutq = 1;
    assert(!h_movie_AcqOut(as, &idx, &pts, &flags, &left) && idx == 0 && !dm_movie_playing());
    video.outq[0] = 3; video.noutq = 1;
    assert(!h_movie_AcqOut(vs, &idx, &pts, &flags, &left) && idx == 3 && dm_movie_playing());
    test_now += MD_PLAYING_NS - 1; assert(dm_movie_playing());
    assert(h_movie_AcqOut(vs, &idx, &pts, &flags, &left) == MD_NO_OUTPUT && dm_movie_playing());   // no picture ready: nothing handed out, the signal is not renewed
    test_now += 1; assert(!dm_movie_playing());
    puts("movie signal: a video picture raises it for half a second, audio outputs do not");
}
int main(void) {
    playing();
    int w = 0, h = 0;
    assert(!vp8_size(vp8, 9, &w, &h));
    assert(vp8_size(vp8, sizeof vp8, &w, &h) && w == 16 && h == 16);
    for (int format = MD_FMT_ABGR; format <= MD_FMT_NV12; format++) {
        decode(3, format, vp9, sizeof vp9);
        decode(2, format, vp8, sizeof vp8);
    }
    puts("VP8 and VP9 key frames: NV12 and RGBA pixels match");
}
