# Threads

Guest threads, their synchronization and how the host schedules them. Each entry: symptom, cause, fix, the games it was found on. The [symptom index](../agents/symptoms.md) lists every symptom.

## Thread creation and cores

### Publishing a new thread's scheduler fields

- **Symptom:** TSan reports `thread_main` writing `host_work` while `thr_runnable` reads it during a same-core yield (`t_notify_sched`, issue #411).
- **Cause:** `CreateThread` had already linked the object into `g_all`, but its pthread initialized `host_work`, the Mach port and QoS without the scheduler lock `G`. `StartThread` could make the object runnable before those writes completed.
- **Fix:** initialize those shared fields and read the starting priority under `G`. `CreateThread` publishes the pthread handle and registry link together after `pthread_create` returns, rather than letting that call write a published field. The initial main thread obtains its QoS before publication; the priority getter/setter and deferred QoS updates also hold `G`. Readers keep the same lock, with no added startup wait, timeout or game rule.
- **Check:** the real start/exit and native-wait paths in `t_notify_sched`, both preemption modes, run under TSan with the `thr_runnable` suppression removed. The unsuppressed original reported the startup race. Changing priority before start and consuming the deferred update at a real gate also exposed the unlocked priority setter; the extended test covers that path with `DM_QOS_MAP=1`.
- **Found on:** host unit tests; no particular game's hang was attributed to this race.

### Starting a higher-priority thread on the caller's core

- **Symptom:** a parent returns from `StartThread` before a newly runnable higher-priority child pinned to its core finishes its work (deterministic regression, not attributed to a game failure).
- **Cause:** `StartThread` signalled the child's pthread but did not request the priority handoff already used when waking a waiter. Atmosphère's [`KThread::Run`](https://github.com/Atmosphere-NX/Atmosphere/blob/master/libraries/libmesosphere/source/kern_k_thread.cpp) makes the child runnable; scheduler priority rules then apply. It does not promise that an equal-priority or other-core child has entered its function before the call returns.
- **Fix:** `note_runnable` records the same handoff for starts and wakes (`hle_thread.c`). No unconditional child-entry handshake or timeout.
- **Check:** `make -C dm/host/tests GAME=010038B015560000 preempt` delays the child's host dispatch by 1 ms and 20 ms. With `DM_PREEMPT=0`, both delayed starts failed before the fix. Afterward both `DM_PREEMPT=0` and `1` pass; the broader mode already supplied the handoff before this correction. Equal-priority, other-core, migratable, host-helper, suspended and host-GPU-work children do not hold up the caller.
- **Found on:** the threading audit of [FINAL FANTASY TACTICS](../../dm/games/010038B015560000/README.md#threads); its affected workers are lower priority and initially migratable, so this correction does not remove its local wake cut.

### Core mask changes move the ideal core into the new mask

- **Symptom:** per-core job queues never drained.
- **Cause:** a `SetThreadCoreMask` that pins a thread to other cores (ideal core −3 = keep) left the ideal core outside the new mask, so `GetCurrentProcessorNumber` reported a core the thread cannot run on.
- **Fix:** the host moves the ideal core into the new mask, as Horizon does, so `GetCurrentProcessorNumber` reports a core the thread can run on.

### Ideal core −2 resolves to the process default core

- **Symptom:** crash indexing a per-core table with a huge offset (index −2).
- **Cause:** threads created with ideal core −2 (*use process default*) were recorded as core −2, and `GetCurrentProcessorNumber` returned −2.
- **Fix:** −2 resolves to the process default core (0), and a negative core is never returned (`hle_thread.c`).
- **Found on:** [Super Mario Bros. Wonder](../../dm/games/010015100B514000/README.md), in its font engine (`main+0x107dbc0`).

### Free thread count (`svcGetInfo` type 24)

- **Symptom:** the main thread waits forever on an event right after `nnMain` starts, with only three or four threads created; `DM_THR=1` shows no `CreateThread` for the thread it waits on.
- **Cause:** Unity's thread start (`main+0x3e1a50`) creates a thread only when `nn::os::GetFreeThreadCount()` is at least 1. That is `svcGetInfo` type 24 (FreeThreadCount, Horizon 11 and later), which the host answered 0 like every type it did not know, so the thread was never asked for. The kernel answers the thread resource limit less the threads alive (Atmosphère `kern_svc_info.cpp`); `pm` gives an application 96 threads (`pm_spec.cpp`, 256 with a boost).
- **Fix:** the host answers 96 less the game's threads that have not exited (`thr_limit_used`; guest threads the host spawns for itself are left out).
- **Found on:** [Monster Train 2](../../dm/games/010051701FB46000/README.md) (Unity 2022.3.54f1 on SDK 18.3.5: `main+0x3e7288` starts a thread and waits for it to signal `main+0x539cf80`). With the fix the game creates 40 threads and reaches its title.
- **Note:** of the 20 games extracted on this machine, only this `main` imports the function.

### Pausing threads and reading their context for garbage collectors

- **Symptom:** in garbage-collected titles (Unity / IL2CPP), live objects freed, with their finalizers releasing native resources.
- **Cause:** the Boehm collector pauses each thread, reads its registers for roots and scans its stack. `SetThreadActivity` (0x32) and `GetThreadContext3` (0x33) were placeholders that only reported success: threads kept running and the context was empty, so roots held only in registers were missed.
- **Fix:** both really pause and report registers (`hle_thread.c`). A thread inside an SVC counts as paused at once, with the gate frame as its context (`thr_svc_enter` / `thr_svc_leave` around every gate SVC; it waits at the SVC exit while paused). A thread in guest code gets SIGUSR2, and the handler saves the ucontext and waits there. A thread in host code is retried every 100 µs. The context is Horizon's 0x320-byte `ThreadContext`.
- **Found on:** Unity / IL2CPP titles in general.

### Same-core wake handoffs

- **Symptom:** crashes around movie changes in the game's own player threads, about one run in two: `SignalEvent` → `MultiWaitImpl::NotifyAndWakeupThread` on a null MultiWait at address 0x20; `WaitAny` walking freed holders; a worker reading a freed object at `main+0x225338`. The other way round, a handoff that waits too widely: a black screen at boot that never loads a texture (`packaged textures: first uploads 0`), or a load that never ends behind an animated loading screen, with the thread dump's `same-core handoffs N, total T ms` larger than the run itself.
- **Cause:** Horizon schedules the highest-priority runnable thread on a core ([Mesosphere's scheduler](https://github.com/Atmosphere-NX/Atmosphere/blob/master/libraries/libmesosphere/source/kern_k_scheduler.cpp)). A lower-priority thread that wakes a higher-priority thread pinned to its core cannot continue until that work blocks. The host's pthreads run in parallel. The earlier approximation also confused host dispatch state with guest readiness: `wake()` cleared the guest wait before the pthread resumed, but `thread_info` could still report that pthread waiting. The caller then continued too soon. Its 5 ms timeout opened the same hole under a longer host delay; the recorded `yield_pending` flag was unused unless the profile enabled checks after every thread SVC. The first unbounded handoff then waited for every runnable higher-priority thread pinned to the caller's core, not only the ones its wake made runnable. The host runs a lower-priority thread beside such threads at all other times, and a core's busy loaders, job workers and pollers are seldom all blocked at the same moment, so a wake could hold its caller for minutes.
- **Fix:** every game's thread SVC honours `yield_pending`. Before returning, it waits for the threads its wakes made runnable that are higher priority and pinned to the caller's core, and for those such a thread makes runnable in turn while the handoff lasts (Dread's dispatcher wakes the worker), until each blocks, sleeps, yields to any thread (`SleepThread(-2)`, which takes it off its core so that lower-priority threads run there), exits, is suspended, or enters explicit host GPU work (`svc_thread` / `dm_yield_to_core_peers` in `hle_thread.c`). A wake records the thread in the waker's current handoff and in those the waker belongs to (`note_runnable`, at most four); blocking ends that (`hand_leave`), and a handoff ends when its caller's thread SVC returns (`hand_epoch`). Guest runnable state is authoritative, including the wake-to-pthread-resume interval; a host dispatch snapshot cannot release the handoff, and there is no timeout that lets unfinished work through. A higher-priority peer the wake did not make runnable does not hold the caller, as at every other point on the host. Host-created helpers and threads that can run on another core are excluded.
- **Check:** `make -C dm/host/tests GAME=010093801237C000 preempt` delays a woken pthread's dispatch by 1 ms and 20 ms through real event, mutex and condition-variable SVCs. The worker's payload and exit must precede the signaller's return. The original implementation failed both delays; changing readiness alone fixed 1 ms but still failed 20 ms. Equal-priority, other-core, migratable, host-helper, suspended and host-GPU-work peers do not block the caller. Its handoff-scope cases add a busy higher-priority peer that nobody woke: the woken worker must still finish first and the signaller must return (the whole-core wait never returns), a worker woken by the woken dispatcher must finish before the signaller returns (fails without the recorded chain), and a woken thread that yields to any thread releases the signaller (never returns without that rule). The native-mutex case wakes a higher-priority pinned peer while holding the mutex it needs; the signal must return at that native block, and the peer finishes after unlock (hangs without the wait annotation).
- **Found on:** [Metroid Dread](../../dm/games/010093801237C000/README.md), whose per-build movie request-ring gates and `core_preempt on` setting are now removed; the whole-core wait on [The Legend of Zelda: Tears of the Kingdom](../../dm/games/0100F2C0115B6000/README.md) ([issue #247](https://github.com/seedds/nxnative/issues/247)) and Donkey Kong Country: Tropical Freeze ([issue #259](https://github.com/seedds/nxnative/issues/259), section 6; no profile here).
- **Native helper joins:** `dm_host_thread_join` also releases the guest core
  during a native helper's lifetime, preserving an enclosing host-work scope.
  [Xenoblade Chronicles 3](../../dm/games/010074F013262000/README.md) exposed an
  audio-unit setup join in `AKEventManager` during a later stall. That sample
  establishes the missing scheduler annotation, but does not establish an
  unbounded Apple audio-unit construction deadlock. The preemption regression
  gates a native helper, verifies that a same-core signaller returns while the
  peer joins it, then checks completion, the join result and nested host work.
- **Scope:** these are cooperative thread-SVC handoffs, not a complete asynchronous guest scheduler. The optional `core_preempt` profile key (`DM_PREEMPT=0` / `1` overrides it) additionally checks already-runnable peers after every thread SVC; it defaults off. Historically that broader policy moved [Super Mario Bros. Wonder](../../dm/games/010015100B514000/README.md)'s first frame from 0.6 s to 2.9 s by waiting for busy decompression threads. Wake-triggered handoffs apply with either setting.

### A host lock held across a same-core handoff

- **Symptom:** the game freezes when a movie starts playing beside the game (a guide movie in a corner of the screen): the last frame stays, the process idles at a few percent of a core, and the thread dump shows a lower-priority job thread `running/not waiting` with its backtrace in the movie player (`ReleaseOutputBufferIndex`), the main thread waiting for it, and the movie's input thread `running/not waiting` too. A `sample` of the process shows the job thread in `md_pump` → `md_event` → `dm_yield_to_core_peers`, and the input thread in `h_movie_SendIn` → `md_pump` waiting for a pthread mutex.
- **Cause:** the host's movie decoder holds its decode lock (`dmu`) across guest code: the "input available" and "output ready" events are signalled with the SDK's `SignalEvent` from inside `md_pump`. The signal woke the movie's higher-priority threads pinned to the signaller's core, so the signaller's [same-core wake handoff](#same-core-wake-handoffs) waited for them to block before its SVC returned. One of them, the input thread, had called `SendInputBufferForDecode` and was waiting for `dmu` in host code. A thread waiting for a host lock still counted as runnable, so the handoff never ended and the lock was never released. On Horizon that lock is guest-visible (the SDK's decoder holds an `nn::os` mutex there), and a thread waiting for it is blocked.
- **Fix:** `dm_host_lock` (`hle_thread.c`) takes a host lock that HLE code holds while it runs guest code. A guest thread that has to wait for it is in a [native HLE wait](#native-hle-waits-release-the-guest-core) (`dm_thread_native_wait`) while it waits: blocked for `thr_runnable`, and out of the handoff that made it runnable, so the handoff does not wait for it. The movie decoder takes `dmu` and the deferred-event lock `g_dfmu` with it (`hle_movie.c`). Releasing `dmu` before signalling instead would let a signal land after `Stop` has returned, on events the game is tearing down (the reason `md_defer_body` signals under its lock).
- **Check:** `make -C dm/host/tests GAME=010093801237C000 preempt`, handoff scope "woken thread waiting for the signaller's host lock": the signaller holds a host lock across its signal and the woken higher-priority worker waits for it with `dm_host_lock`. The signaller must return before the worker finishes; without the native wait around the lock the test never returns.
- **Found on:** [Kirby and the Forgotten Land](../../dm/games/01004D300C5AE000/README.md): the first guide movie ("A Jump", 480×270 VP9) froze the game on the first walk from the beach, every time. The job worker (priority 46) and the movie threads (priority 44) are all pinned to core 0.
- **Found on:** [Xenoblade Chronicles 3](../../dm/games/010074F013262000/README.md), whose 140-second opening VP9 movie stopped at its first output release. A live stack sample identified the input thread in `md_pump` waiting on `dmu`, and the output thread holding it inside `SignalEvent` → `dm_yield_to_core_peers`.

### Simultaneous crashes of several threads

- **Symptom:** several threads crash at once and the dumps interleave, then the process hangs instead of exiting.
- **Cause:** Unity's job threads tend to crash together.
- **Fix:** `crash.c` lets only the first crashing thread print (`crash_gate`); the others stop in `pause()`, and a 15 s alarm ends the process if the dump itself stalls.
- **Found on:** Unity titles in general.

## Synchronization and address arbitration

### `SignalToAddress` type 2 with count ≤ 0

- **Symptom:** none seen; found while investigating [Fire Emblem Engage](../../dm/games/0100A6301214E000/README.md)'s demo crash, which it did not change (that was the address-space shortage, [Size-aligned regions exhaust the alias address space](memory.md#size-aligned-regions-exhaust-the-alias-address-space)).
- **Cause:** for `SignalToAddress` type 2 (`SignalAndModifyByWaitingCountIfEqual`) with count ≤ 0 and waiters present, the new value is `value − 2`, not `value − 1` (mesosphere `KAddressArbiter`; Ryujinx and yuzu agree). The host had −1.
- **Fix:** the host writes `value − 2`, the specified behaviour.

### `WaitForAddress` type 3: 64-bit wait if equal

- **Symptom:** a 64-bit wait could return at once or block when it should not (not met in a game).
- **Cause:** Horizon 18 added a 64-bit "wait if equal" arbitration type, which SDK 19 exports as `nn::os::WaitForAddress(const long*, long)`; the host used to fall into its 32-bit "wait if less than" test.
- **Fix:** type 3 compares the 64-bit value (`hle_thread.c`).
- **Found on:** [Pokémon Legends: Z-A](../../dm/games/0100F43008C44000/README.md) (SDK 19.3.11): Z-A does not call it, but the SDK has it.

### Unity's stream buffer handshake loses a wake-up on Apple cores

- **Symptom:** boot stops before or soon after the first frame with the CPU at 0% and every guest thread waiting on a condition variable: the main thread in `nn::os::AcquireSemaphore` after posting a command to `UnityGfxDeviceWorker`, the worker in `AcquireSemaphore` too, one condition wait after it (`wait #` one higher); 3 of 5 Mac runs, at random points.
- **Cause:** a memory-order race in the game's code, not a host bug. Unity 2018.4's `ThreadedStreamBuffer` (the ring buffer every Unity worker thread is fed through) wakes a sleeping side with a Dekker handshake: the reader that finds nothing sets "reader sleeping" with a store-release and loads the write position again before sleeping on its semaphore; a writer stores the write position with a store-release and then checks that flag (and the mirror pair for a writer short of space). The second access of each side is a plain `ldr`, and AArch64 lets a plain load complete before an earlier store-release is visible, so both sides can read the old value and neither signals. The Switch's Cortex-A57 allows it too, but Apple cores hit it within seconds.
- **Fix:** a per-build cut turns each of those loads into a load-acquire (`ldar`), which a store-release before it orders after the store (eight sites in that build's `patches.py`); 14 of 14 runs boot and keep presenting.
- **Found on:** [FINAL FANTASY CRYSTAL CHRONICLES Remastered Edition](../../dm/games/0100CE4010AAC000/README.md) 1.0.0 and 1.0.3 (Unity 2018.4.2f1, SDK 8.2.1; its `patches.py`: 1.0.0 `main+0x1e425b0` and the stream functions after it, the same sites +0x25380 in 1.0.3).
- **Check:** another Unity title that stops this way: look for `stlr` followed by a plain `ldr` of the other word in its `ThreadedStreamBuffer` (the functions around the `AcquireSemaphore` the worker waits in).

### Late PhysX task destructor after the unlock

- **Symptom:** a PhysX worker crashes in a task's `removeReference` with a null task manager, right as the game switches to 30 fps (`pc=main+0x10ccf28`, `lr=main+0x13c236c`); on the iPhone and in 2 of 5 Mac runs, in every Mac run with 12 busy loops loading the CPU.
- **Cause:** the game publishes completion before task teardown ends, then reuses the same task. Its main thread rebuilds each world's completion task before `simulate`; the worker sets done, notifies and unlocks inside `run`, then calls `release`, whose destructor clears `mTm`. Another core may rebuild it in between. This is a guest lifetime race: an unlock cannot protect subsequent destructor writes. PhysX's [task contract](https://github.com/NVIDIAGameWorks/PhysX-3.4/blob/master/PxShared/include/task/PxTask.h) places recycling in `release`, after `run`, and its `PxLightCpuTask` destructor clears `mTm`. There is no measured Switch timing guarantee that makes the ordering safe. The game's offsets, affinities and replay evidence are in its note.
- **Fix:** a per-build cut makes that one `release` a `ret` (its `patches.py`); the destructor frees nothing and the step rewrites every field.
- **Check:** `dm/tools/check_thread_cuts.py` replays the original construction, release and `removeReference` instructions with a forced late release: the original faults at the recorded null-manager load; normal release-before-rebuild succeeds; the registered cut preserves the new task. This controlled replay has no host mutex or graphics implementation in its failure path.
- **Found on:** [The Legend of Zelda: Link's Awakening](../../dm/games/01006BB00C6F0000/README.md). How it was found is in [05](../agents/05-debugging.md#racy-crashes-load-trace-gates).

## Yields and spin waits

The yield back-off (`DM_YIELD_BACKOFF`) and the rewriter's spin waits (`patch_nso.py` "Spin waits", `dm_spin_wait` in `hle_thread.c`), with their measurements, are in [development.md](../development.md#power) ("Yield loops", "Spin loops").

### Timer slack in guest sleeps (`sleep_precise`)

- **Symptom:** a 30 Hz game thread runs at 27 Hz, and whatever it paces comes out slow (cutscenes at 36 ms per frame instead of 33.3; gameplay was fine at 60).
- **Cause:** macOS timer slack: `nanosleep` and `mach_wait_until` overshoot by about 10% at any QoS (measured: 33 ms → 36.4 ms, 5 ms → 6.1 ms, 1 ms → 1.26 ms). Dread's sound thread (`main+0xf95b0`) reads a millisecond clock, updates, then sleeps "33 ms minus this round's work", so on the host its period was 36.9 ms. The cutscene loop renders a frame whenever the audio play position, which that thread refreshes, moves (`main+0x119a3d0`; the position is played samples ÷ sample rate of the cutscene's stream), so cutscenes ran at about 27 fps.
- **Fix:** `SleepThread` sleeps three quarters of the remaining time per step until within 20 µs (`sleep_precise` in `hle_thread.c`).
- **Found on:** [Metroid Dread](../../dm/games/010093801237C000/README.md): cutscenes at 33.3 ms, the sound thread at 33.2 ms. [Super Mario Bros. Wonder](../../dm/games/010015100B514000/README.md)'s frame-time p95 also went from 19.7 to 18.4 ms.
- **Note:** timed waits (`WaitSynchronization`, condition variables) still use the host's own timeouts.

### Sleeps under 20 µs take the yield path

- **Symptom:** a guest thread keeps a core at 100% with billions of `SleepThread` calls.
- **Cause:** `sleep_precise` returns at once for anything under 20 µs (its nanosleep would overshoot), so a loop of such sleeps never sleeps.
- **Fix:** sleeps under 20 µs take the yield path and its back-off (plain yields for the first 2 ms of a run, then short sleeps).
- **Found on:** [Super Mario Galaxy](../../dm/games/010099C022B96000/README.md): Hagi polls with `SleepThread(100 ns)` (`main+0x517c`), 1.4 billion calls in 200 s, and the render thread nearly as busy. The two threads went from 199 s and 171 s of CPU per 200 s to 5 s and 19 s per 120 s, at the same frame rate.

### Yields that make progress return at once (`thr_yield`)

- **Symptom:** a loading screen sits for a minute with the CPU nearly idle; one thread yields thousands of times a second, every yield a back-off sleep (the power line's top yielder, with as many back-off sleeps).
- **Cause:** the thread was working, not waiting: its loop calls `nn::os::YieldThread` once per item, and the back-off made each yield a 250 µs sleep.
- **Fix:** a yield whose caller's x19–x28 changed since the last one is progress (`thr_yield` in `hle_thread.c`; the SDK reaches the SVC through tail branches, so those registers are the loop's own): it returns at once with no host call, and the run starts again. Polls keep those registers (Three Houses' limiter, Galaxy 2's Hagi sleep poll at `main+0x11ec`); counters move them.
- **Found on:** [Animal Crossing: New Horizons](../../dm/games/01006F8002326000/README.md): a black screen with the plane icon for 77 s after the opening movie, `SaveProc` at about 2,600 yields a second, its grid walks over the new island (`main+0x157d020`) yielding once per cell; also about 40 s of the same at boot. The island now shows about 10 s after the movie, as with `DM_YIELD_BACKOFF=0`. Polls that keep their registers: [Fire Emblem: Three Houses](../../dm/games/010055D009F78000/README.md), [Super Mario Galaxy 2](../../dm/games/0100FD8022DAA000/README.md).
- **Check:** check such a change on [The Legend of Zelda: Breath of the Wild](../../dm/games/01007EF00011E000/README.md) outdoors: its `PlacementMgr` and `RadarMgr` turned out to yield per item too, and a `sched_yield` on each of their 200,000 yields a second cost a third of a core more than the back-off had; with no host call, CPU energy fell instead (numbers in [development.md](../development.md) "Yield loops").
- **Note:** a temporary log of which of x19–x28 move at each yield, per thread, is what told the two kinds apart.

### A wait at two yields is not progress

- **Symptom:** one guest thread keeps a host core at 100% with about a billion yields a minute (`SVC 0xb` in `DM_HLECOUNT`), none of them a back-off sleep, while the game itself plays normally.
- **Cause:** the loop waits at two yields whose callee-saved registers differ, so each yield looked as if the loop had moved on since the last one, and returned at once. Hades' `NetworkPollThread` (`main+0x27aaa0`) yields between its passes with w23 = 0, and in each pass yields while the nifm request is on hold with w23 = 2,000, its retry count.
- **Fix:** a yield is progress only when x19–x28 differ from both of the last two yields (`thr_yield` in `hle_thread.c`): a loop that comes back to the registers of the yield before last is waiting, and the run goes on to the back-off. Counters and cursors (Animal Crossing's grid walk, Breath of the Wild's batches) never come back, so they still return at once.
- **Found on:** [Hades](../../dm/games/0100535012974000/README.md), with [Network requests stay on hold before they settle](services.md#network-requests-stay-on-hold-before-they-settle). Neither change alone was enough: in 60 s of its smoke route the process used 117 s of CPU on `main`, 119 s with only the nifm change (627 million submits, a pass now ended at the second query) and 122 s with only this one (1.38 billion queries, the 50 ms hold still timed out). With both it used 62 s, as with the poll thread's yields turned into sleeps: 216,000 yields, most of them back-off sleeps.
- **Check:** a temporary per-thread count of the yields only this rule keeps in a run, and of the back-off sleeps those runs then took, on boots and play of other games: Tears of the Kingdom's main thread and ModuleSystem workers about 0.1% of their yields (761 of 926,116 on the main thread in 120 s) and no back-off sleep; Breath of the Wild outdoors at most 7 per thread in 150 s, no back-off sleep; Three Houses up to 95 per thread, Donkey Kong Country: Tropical Freeze about 1,000 on the main thread, neither with a back-off sleep from them; Kirby at most 1; Celeste, BALL x PIT, Bayonetta and Ghost Trick none. Their frame rates matched `main` in runs that kept the window's focus (a run whose window loses focus to another app drops to about 30 fps, on `main` as well).

## Events and notifications

### Service-event producers follow the binding lifetime

- **Symptom:** a host helper thread aborts when signalling a destroyed `SystemEvent`; repeated `vi::GetDisplayVsyncEvent` calls double the event's tick rate. Rapid replacement can abort with `too many vsync events`, or a retired vsync worker can signal another service's event at reused storage.
- **Cause:** lazy binding calls the SDK's `CreateSystemEvent`, which requires a guest thread. Checking only the guest address also mistakes a replacement binding for the original event, even if its kernel handle number is checked: both can be reused before the next tick. An eight-slot worker table counts destroyed events until their workers next run.
- **Fix:** `hle_signal_system_event` retains lazy binding on guest threads; host threads skip an unbound event and log once. Each service-event binding gets a monotonically increasing identity. `hle_signal_system_event_binding` matches that identity and signals under the same lock as `CloseHandle`, so a stale producer cannot signal a replacement. The vi registry keeps one worker per binding identity in an allocated list; a worker whose binding closed removes only its own entry and exits. A new vi binding at reused storage gets its own worker, while repeated requests for a live binding share the existing one.
- **Found on:** synthetic host regression cases in [`t_system_event.c`](../../dm/host/tests/t_system_event.c), using real binding and event SVCs with worker startup held until after destruction and handle reuse; no game failure is claimed.
- **Check:** duplicate vi registration, nine rapid replacements before the first tick, storage and handle reuse by a different service, vi rebinding at reused storage, host signalling after destruction, and guest lazy binding. The capacity and unrelated-service cases fail on the original PR #202 and pass with lifetime identities and the allocated registry.

### One auto-clear event shared by a pool's workers

- **Symptom:** the main thread waits forever on a job's done event at boot while every worker sleeps, two of them on one event (`main+0x1426c` waiting on `Job::m_doneEvent`); 4 of 6 Mac runs.
- **Cause:** the engine puts a job in worker k's private queue but signals one shared SDK auto-clear event. Its condition wake chooses by priority, then FIFO; it has no target-worker identity. The wrong worker checks only its own queue and sleeps again. This is a guest assumption about waiter order, exposed by host timing. Host `pick` / `wseq` agrees with Atmosphère's [condition-tree comparator](https://github.com/Atmosphere-NX/Atmosphere/blob/master/libraries/libmesosphere/include/mesosphere/kern_k_thread.hpp) and [`Signal`](https://github.com/Atmosphere-NX/Atmosphere/blob/master/libraries/libmesosphere/source/kern_k_condition_variable.cpp), including the historic 0.19.0 implementation. This describes the SDK's condition-based auto-clear event; kernel readable events instead notify all synchronization waiters. Game offsets and observations belong in its note.
- **Fix:** the game's own wait wrapper (`main+0x12500`, `{event, pending}`) signals the event once more when it takes a nonzero pending word after waking, and nothing set it: a build cut makes the signal set it first (its `patches.py`), so a worker woken in another's place passes the wake on; 6 of 6 runs boot.
- **Found on:** [FINAL FANTASY TACTICS - The Ivalice Chronicles](../../dm/games/010038B015560000/README.md).
- **Check:** `t_preempt` checks priority/FIFO selection and mutex reacquisition through real condition SVCs. `dm/tools/check_thread_cuts.py` runs the game's actual signal and wait wrappers with both worker arrival orders: only the original wrong-worker cases strand a job. The game's note records the Mac boot comparison with the corrected host.
- **Note:** an unconditional `StartThread` child-entry handshake changed the timing but did not eliminate the hang and is not a kernel guarantee. The separate [same-core start handoff](#starting-a-higher-priority-thread-on-the-callers-core) applies only when priority and affinity require it.

### The oe notification event and its queue

- **Symptom:** abort in `os::WaitSystemEvent` under `oe::PopNotificationMessage` (The Legend of Zelda: Link's Awakening); one guest thread at about 1000 ms/s on the iPhone only, the phone hot, CPU energy 5–7 W (Monster Hunter Rise's `MessageSuperviseThread`, priority 32, in the `[nvn] threads` lines).
- **Cause:** the host keeps the notifications in a queue of its own. The blocking pop waits on the system event `oe::Initialize` would have created, and the host's `Initialize` is a no-op. Monster Hunter Rise's thread waits on `oe::GetNotificationMessageEvent()` with `os::WaitAny`, which does not clear an event, then pops notifications until the queue is empty. The host only ever signalled its notification event, so after the first focus change (iOS changes focus at launch; the Mac does not) it stayed set and the loop never blocked again.
- **Fix:** the host now implements the blocking pop on its notification queue (a condition variable, then the `TryPop` path), and the event follows the queue as the am service's does: set while a notification is queued, cleared when the last one is popped (`hle_oe.c` `mq_ev_sync`, `hle_clear_system_event`).
- **Found on:** [The Legend of Zelda: Link's Awakening](../../dm/games/01006BB00C6F0000/README.md) (SDK 8.2.0, the blocking pop); [Monster Hunter Rise](../../dm/games/0100B04011742000/README.md) (the event).
- **Check:** Mac repro `DM_OE_SCRIPT=focus=2@5,focus=1@6` (the script also starts at the game's first `GetNotificationMessageEvent`, since such a game pops only once the event fires): before 995 ms/s, CPU 109%, 6.97 W; after, the thread is idle and CPU energy is 0.05 W.

### Native HLE waits release the guest core

- **Symptom:** Paper Mario: The Thousand-Year Door 1.0.1 stays black before its first frame. The main thread stops at `main+0x32796c`, after starting `SYS_Notification`; the priority-28 notifier is in `oe::PopNotificationMessage`, while the priority-44 main thread waits for its same-core wake handoff.
- **Cause:** the notification HLE blocks in a host `pthread_cond_wait`, outside the guest kernel's wait bookkeeping. The notifier remains classified as runnable and retains its inherited handoff, so its lower-priority waker cannot continue even though the notifier has no work.
- **Fix:** `dm_thread_native_wait` marks the blocked native-wait interval under the scheduler lock and drops the inherited handoff. `PopNotificationMessage` enters that state while holding the queue mutex, waits, and restores runnable state after reacquiring the mutex. Ordinary native execution is still runnable.
- **Found on:** [Paper Mario: The Thousand-Year Door](../../dm/games/0100ECD018EBE000/README.md#startup).
- **Check:** the original PR #291 reproducer on upstream `1402ded2` blocks until its watchdog exits with code 99. `make -C dm/host/tests GAME=0100ECD018EBE000 notify-scheduler` now uses real `CreateThread`, `StartThread`, wait-for-exit and close SVCs; only the assembly transition to a guest stack is replaced by a C test entry. The original notification HLE strands `StartThread` until the watchdog exits with code 99. The fixed HLE passes 100 runs in each scheduling mode, including a wake without a queued message, runnable-state restoration and delivery of focus notification 15. The full host test suite (`make -C dm/host/tests GAME=0100ECD018EBE000 run`) also passes with CoreAudio access. The game's note records its separate Mac startup comparison and iPhone report.
