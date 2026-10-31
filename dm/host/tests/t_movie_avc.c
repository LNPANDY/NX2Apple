// Synthetic SPS prefixes and pixel buffers, no game files. Exercise the real
// parameter-set selection, output queue and end-of-stream drain without requiring a hardware codec.
// Include the real decoder, without registering unrelated SDK hooks in this test.
#include "../hle.h"
#undef HLE_FORCE
#define HLE_FORCE(mangled, why, ret, cname, ...) static ret cname(__VA_ARGS__)
#include "../hle_movie.c"
#include "../hle_movie_avc.c"
#include <assert.h>

uint64_t now_ns(void) { return 1; }
__thread _Atomic int dm_host_work;   // hle_thread.c
void dm_host_lock(pthread_mutex_t *m) { pthread_mutex_lock(m); }
void dm_host_helper_qos(qos_class_t q) { (void)q; }

typedef struct { uint8_t p[512]; unsigned bit; } writer;
static void put(writer *w, unsigned v, unsigned n) {
    while (n--) { w->p[w->bit / 8] |= ((v >> n) & 1) << (7 - w->bit % 8); w->bit++; }
}
static void ue(writer *w, unsigned v) {
    unsigned n = 0, x = ++v;
    while (x >>= 1) n++;
    put(w, 0, n); put(w, v, n + 1);
}
static size_t sps(writer *w, unsigned profile, unsigned poc, unsigned chroma, int scaling) {
    *w = (writer){0}; put(w, 0x67, 8); put(w, profile, 8); put(w, 0, 8); put(w, 41, 8); ue(w, 0);
    if (profile == 100 || profile == 244) {
        ue(w, chroma); if (chroma == 3) put(w, 0, 1);
        ue(w, 0); ue(w, 0); put(w, 0, 1); put(w, scaling, 1);
        if (scaling) for (unsigned i = 0; i < (chroma == 3 ? 12u : 8u); i++) {
            put(w, i == 0, 1);
            if (!i) ue(w, 16); // delta_scale = -8, nextScale = 0: default matrix
        }
    }
    ue(w, 0); ue(w, poc); put(w, 1, 1); // prefix ends here; rbsp stop bit
    return (w->bit + 7) / 8;
}
static void queue_picture(mavc *a) {
    CVPixelBufferRef pb = NULL;
    assert(!CVPixelBufferCreate(NULL, 16, 16, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, NULL, &pb));
    CVPixelBufferLockBaseAddress(pb, 0);
    for (int i = 0; i < 2; i++) memset(CVPixelBufferGetBaseAddressOfPlane(pb, i), i ? 128 : 16,
                                      CVPixelBufferGetBytesPerRowOfPlane(pb, i) * CVPixelBufferGetHeightOfPlane(pb, i));
    CVPixelBufferUnlockBaseAddress(pb, 0);
    on_frame(a, NULL, 0, 0, pb, CMTimeMake(0, 1000000), kCMTimeInvalid);
    CVPixelBufferRelease(pb);
}
// End of stream with three pictures held for reordering (POC type 0): an end-of-stream packet without data, nout output slots of which the client
// returns each one it takes. Every picture comes out without the end-of-stream flag, then one output without a picture carries it with the packet's time
static void drain(int nout) {
    static mdec_t d; d = (mdec_t){ .type = MD_TYPE_AVC, .fmt = MD_FMT_NV12, .nout = nout, .started = 1, .w = 16, .h = 16 };
    pthread_mutex_init(&d.mu, NULL); pthread_mutex_init(&d.dmu, NULL); pthread_mutex_init(&d.wmu, NULL); pthread_cond_init(&d.wcv, NULL);
    assert(!pthread_create(&d.wk, NULL, md_worker, &d));
    md_avc_open(&d); writer w; size_t n = sps(&w, 100, 0, 1, 0); keep_ps(d.avc, w.p, n);
    for (int i = 0; i < 3; i++) queue_picture(d.avc);
    d.pend[0].in = 0; d.pend[0].pts = 777; d.pend[0].flags = 4; d.npend = 1; d.ninfree = MD_NIN - 1;
    md_pump(&d);
    void *self[2] = { NULL, &d }; int got = 0, idx, left; int64_t pts; uint32_t flags;
    for (;;) {   // the client returns each output it takes, so the next one is always ready
        assert(!h_movie_AcqOut(self, &idx, &pts, &flags, &left));
        if (++got < 4) assert(d.out[idx].pic && pts == 0 && !(flags & 4));
        else { assert(!d.out[idx].pic && pts == 777 && flags == 4 && !d.avc_drain && !mavc_queued(d.avc) && !left); break; }
        assert(md_rel(&d, idx));
    }
    md_job(&d, MDJ_QUIT); pthread_join(d.wk, NULL);
    for (int i = 0; i < MD_NOUT; i++) free(d.out[i].frm);
}
// Native-texture slots (md_rendered): one written into the client's texture stays taken, so no packet is decoded into it before the client's own release can come (GitHub
// issue #700). A client that releases what it rendered keeps every slot until its release; one that has not yet gets the earlier slot back at its next GetOutputBuffer
static void take(mdec_t *d, int i) { d->out[i].used = d->out[i].cli = 1; }
static int rendered(mdec_t *d, int i) { pthread_mutex_lock(&d->mu); int n = md_rendered(d, i); pthread_mutex_unlock(&d->mu); return n; }
static void tex_slots(void) {
    static mdec_t d; d = (mdec_t){ .type = MD_TYPE_AVC, .mode = MD_MODE_TEX, .nout = 4, .started = 1 };
    pthread_mutex_init(&d.mu, NULL); pthread_mutex_init(&d.dmu, NULL);
    take(&d, 0); assert(!rendered(&d, 0) && d.out[0].used && d.out[0].rnd);
    take(&d, 1); assert(rendered(&d, 1) == 1 && !d.out[0].used && !d.out[0].cli && d.out[1].rnd);   // never released: slot 0 returns at the next GetOutputBuffer
    assert(md_rel(&d, 1) && d.tex_rel && !d.out[1].used);   // the client releases a rendered slot itself
    take(&d, 2); assert(!rendered(&d, 2));
    take(&d, 3); assert(!rendered(&d, 3) && d.out[2].used && d.out[2].rnd);   // now its slots wait for its release
    take(&d, 0); assert(md_rel(&d, 0) && d.tex_rel && !d.out[0].used);   // a frame dropped without GetOutputBuffer
    assert(md_rel(&d, 2) && md_rel(&d, 3) && !md_rel(&d, 3));   // a second release changes nothing
    take(&d, 1); md_reset(&d, 0); assert(!d.out[1].used && !d.out[1].rnd && d.tex_rel);
}
int main(void) {
    tex_slots();
    puts("native texture: a rendered slot waits for the client's release, or for its next GetOutputBuffer while it has never released one");
    writer w;
    for (unsigned profile = 100; profile <= 244; profile += 144) for (unsigned chroma = 0; chroma <= 3; chroma++) {
        for (int scaling = 0; scaling < 2; scaling++) {
            size_t n = sps(&w, profile, 2, chroma, scaling);
            assert(avc_reorder_depth(w.p, n) == 0);
            for (size_t cut = 0; cut < n; cut++) assert(avc_reorder_depth(w.p, cut) == 4);
        }
    }
    for (unsigned poc = 0; poc <= 1; poc++) {
        size_t n = sps(&w, 100, poc, 1, 0);
        assert(avc_reorder_depth(w.p, n) == 4);
    }
    size_t n = sps(&w, 66, 0, 1, 0); assert(avc_reorder_depth(w.p, n) == 0);
    memset(w.p, 0, sizeof w.p); w.p[0] = 0x67; w.p[1] = 100;
    assert(avc_reorder_depth(w.p, sizeof w.p) == 4); // unterminated Exp-Golomb code
    assert(avc_reorder_depth(w.p, sizeof w.p + 1) == 4);

    mavc *a = mavc_new(); uint8_t out[16 * 16 * 3 / 2]; int64_t pts = -1;
    n = sps(&w, 100, 2, 1, 0); keep_ps(a, w.p, n); queue_picture(a);
    assert(a->depth == 0 && mavc_take(a, 0, out, 16, 16, &pts) == 1 && pts == 0 && !mavc_queued(a));
    assert(out[0] == 16 && out[256] == 128);
    n = sps(&w, 100, 0, 1, 0); keep_ps(a, w.p, n); queue_picture(a);
    assert(a->depth == 4 && !mavc_take(a, 0, out, 16, 16, &pts) && mavc_queued(a) == 1);
    assert(mavc_take(a, 1, out, 16, 16, &pts) == 1 && !mavc_queued(a));
    mavc_free(a);
    puts("AVC: POC type 2 returns the final picture without EOS; other POC modes retain reordering and EOS drain");
    drain(MD_NOUT_VIDEO); drain(2);
    puts("AVC end of stream: every queued picture leaves without the flag, then an output without a picture carries it, also when the client holds the slots");
}
