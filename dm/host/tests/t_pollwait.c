// Short timed waits as polls (poll_wait_begin / poll_wait_end in hle_thread.c), through real thread SVCs on one guest thread:
//   1. a loop of condition variable waits of 500 ns that time out (Hyrule Warriors: Definitive Edition's update thread, main+0x2ad224) backs off after 2 ms;
//   2. so does a loop of 30 ns waits and SleepThread(1 µs) in turn (its main thread, main+0x2acdc0), on WaitSynchronization as well;
//   3. a loop with more than SPIN_GAP_NS of work between its waits never does;
//   4. a lengthened wait still returns as soon as it is signalled.
#include "../hle_thread.c"
#include <assert.h>
#include <unistd.h>

static _Atomic uint32_t mutex_word, condition_key;
static uint32_t me_handle;
static uint64_t backoffs(void) { thr_t *me = pthread_getspecific(g_keythr); return me->nbackoff; }
static void spin_ns(uint64_t ns) { uint64_t t = now_ns(); while (now_ns() - t < ns) {} }
// One condition variable wait as the SDK's TimedWait makes it: take the lock in user mode, wait (the timeout releases it without taking it back)
static int64_t cv_wait(int64_t ns) {
    atomic_store(&mutex_word, me_handle);
    uint64_t r[32] = {(uint64_t)&mutex_word, (uint64_t)&condition_key, me_handle, (uint64_t)ns};
    svc_thread(0x1C, r);
    if (r[0] == 0) { r[0] = (uint64_t)&mutex_word; svc_thread(0x1B, r); }   // signalled: the waiter holds the lock again
    return (int64_t)r[0];
}
static void sleep_svc(int64_t ns) { uint64_t r[32] = {(uint64_t)ns}; svc_thread(0x0B, r); }
// Passes of a poll for ms milliseconds; → the back-off steps taken (yield sleeps and lengthened waits)
static uint64_t poll_for(int ms, int64_t wait_ns, int sleep_too, uint64_t work_ns, uint32_t event) {
    sleep_svc(1000000);   // a real sleep ends the previous case's run
    uint64_t b0 = backoffs(), t0 = now_ns();
    while (now_ns() - t0 < (uint64_t)ms * 1000000) {
        if (event) { uint64_t r[32] = {0, (uint64_t)&event, 1, (uint64_t)wait_ns}; svc_thread(0x18, r); assert(r[0] == R_TIMEOUT); }
        else assert(cv_wait(wait_ns) == R_TIMEOUT);
        if (sleep_too) sleep_svc(1000);
        if (work_ns) spin_ns(work_ns);
    }
    return backoffs() - b0;
}
static _Atomic int woken;
static void *signaller(void *a) {   // signals every 50 µs until the waiter is woken (a signal while it is between two waits wakes nobody)
    usleep(*(unsigned *)a);
    while (!atomic_load(&woken)) { uint64_t r[32] = {(uint64_t)&condition_key, 1}; svc_thread(0x1D, r); usleep(50); }
    return NULL;
}
int main(void) {
    alarm(20);
    me_handle = svc_thread_main_init();
    int ok = 1;
    uint64_t b = poll_for(20, 500, 0, 0, 0);
    printf("%s: 500 ns condition variable waits alone back off after 2 ms (%llu steps in 20 ms)\n", b ? "PASS" : "FAIL", (unsigned long long)b); ok &= b > 0;
    b = poll_for(20, 30, 1, 0, 0);
    printf("%s: 30 ns waits between 1 µs sleeps back off (%llu steps in 20 ms)\n", b ? "PASS" : "FAIL", (unsigned long long)b); ok &= b > 0;
    uint64_t r[32] = {0}; svc_thread(0x45, r); assert(r[0] == 0); uint32_t ev_w = (uint32_t)r[1], ev_r = (uint32_t)r[2];
    b = poll_for(20, 30, 1, 0, ev_r);
    printf("%s: the same with WaitSynchronization (%llu steps in 20 ms)\n", b ? "PASS" : "FAIL", (unsigned long long)b); ok &= b > 0;
    b = poll_for(20, 500, 0, 3 * SPIN_GAP_NS / 2, 0);
    printf("%s: a loop that works %d µs between its waits does not back off (%llu steps)\n", !b ? "PASS" : "FAIL", 3 * SPIN_GAP_NS / 2000, (unsigned long long)b); ok &= !b;
    // a wait lengthened to the back-off's sleep ends at the signal: the poll runs into the back-off, then another thread signals during a wait
    poll_for(5, 500, 0, 0, 0);
    unsigned delay = 100; pthread_t s; pthread_create(&s, NULL, signaller, &delay);
    uint64_t t0 = now_ns(); int64_t res = R_TIMEOUT;
    while (res == R_TIMEOUT && now_ns() - t0 < 50000000) res = cv_wait(500);
    atomic_store(&woken, 1); pthread_join(s, NULL);
    uint64_t dt = now_ns() - t0;
    printf("%s: a lengthened wait returns at the signal (%s after %.0f µs)\n", res == 0 ? "PASS" : "FAIL", res == 0 ? "signalled" : "not signalled", dt / 1e3); ok &= res == 0;
    r[0] = ev_w; svc_thread(0x16, r); r[0] = ev_r; svc_thread(0x16, r);
    return ok ? 0 : 1;
}
