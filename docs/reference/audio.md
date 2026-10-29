# Audio

The audio renderer (`dm/host/hle_audren.c`), AudioOut, audio devices and codecs. Each entry: symptom, cause, fix, the games it was found on. The [symptom index](../agents/symptoms.md) lists every symptom.

## Audio renderer

### Running the SDK's own renderer on the CPU

Check whether the SDK carries the renderer: list the `sdk` module's exports for `nn::audio::server::` and `nn::audio::dsp::CommandListProcessor`. If they are there ([Super Mario Bros. Wonder](../../dm/games/010015100B514000/README.md), SDK 16), do not write a mixer:

- switch a copy of `AudioRendererParameter` to rendering device = CPU (+0x2c = 1) and execution mode = manual (+0x30 = 1) in `GetAudioRendererWorkBufferSize` and both `OpenAudioRenderer` overloads;
- call the SDK originals (`guest_sym` returns the module's own code even for a forced symbol);
- drive `ExecuteAudioRendererRendering` from a guest thread (`dm_guest_thread_spawn`).

The open then goes through `CreateAudioRendererManagerByDfc`; no IPC.
For a replaced DSP renderer the size query keeps the service's work-buffer contract; a larger local CPU representation is a backend cost. See [A sound engine's heap too small for its renderer and players](#a-sound-engines-heap-too-small-for-its-renderer-and-players).

### SDK 8's longer `AudioRendererParameter`

- **Symptom:** abort with Result 0x499 in `audio::GetAudioRendererWorkBufferSize`.
- **Cause:** SDK 8's `AudioRendererParameter` is one word longer than SDK 16's: its revision sits at +0x38. The host copies the game's parameter before switching it to CPU rendering with manual execution, and copied only 0x38 bytes, so `CheckValidRevision` read garbage.
- **Fix:** it copies 0x40 now.
- **Found on:** [The Legend of Zelda: Link's Awakening](../../dm/games/01006BB00C6F0000/README.md) (SDK 8.2.0).

### A renderer opened without an event

- **Symptom:** the game is silent; only the game's updates render (catch-up frames that nothing plays). The log has `audren: OpenAudioRenderer (no event)` and no `render thread started`.
- **Cause:** the game opens the renderer with `OpenAudioRenderer(handle, parameter, work, size)`, the form with no system event, and paces its own updates, but the renderer must still run every 5 ms. The host used to start its render thread only for the form with an event.
- **Fix:** both forms go through one open that starts the thread (`hle_audren.c` `ar_open`).
- **Found on:** [Balatro](../../dm/games/0100CD801CE5E000/README.md) (SDK 18.3.2, LÖVE's OpenAL Soft; one boot).

### The SDK's open with an event calls the open without one (`t_in_open`)

- **Symptom:** `[RED] audren: a second renderer` right after the first open, with the same work buffer and "original device 1 mode 1".
- **Cause:** not a second renderer: SDK 17.5.3's `OpenAudioRenderer` with an event opens it by calling the form without one through the PLT (`sdk+0x1e489c`), which the loader binds to the host's hook since that form has one ([A renderer opened without an event](#a-renderer-opened-without-an-event)), so `ar_open` ran twice for one renderer. The inner call started the render thread before the outer one had created the event, and the outer call took the renderer for a second one.
- **Fix:** a thread-local flag (`t_in_open`) hands the inner call straight to the SDK with the host's CPU / manual copy of the parameter, and only the outer call starts the thread (`hle_audren.c`).
- **Found on:** [ROMANCE OF THE THREE KINGDOMS 8 REMAKE](../../dm/games/0100C2A01A730000/README.md) (SDK 17.5.3).

### The renderer event as the service gives it: a kernel event

- **Symptom:** the frame loop stops for good as a level loads while audio keeps rendering. The main thread waits in `os::WaitSystemEvent` under `CAudioMemoryPool::Shutdown`, and a sound thread of higher priority waits on the same condition variable.
- **Cause:** with the DSP service (device 0, what the game asks for) `OpenAudioRenderer` attaches the service's renderer event, a kernel readable event (`AttachReadableHandleToSystemEvent`, auto-clear). With CPU rendering and manual execution, which the host switches to ([Running the SDK's own renderer on the CPU](#running-the-sdks-own-renderer-on-the-cpu)), it creates a local one instead (`CreateSystemEvent(event, AutoClear, false)`, SDK 4: `sdk+0x190b6c`). Signalling a local auto-clear event wakes one waiter, the one of highest priority. A kernel event wakes every waiter, and each one tries `ResetSignal`. Donkey Kong Country: Tropical Freeze waits on the event from two threads: its sound thread (priority 29, `main+0x971e8`) every frame, and the main thread while it detaches an audio memory pool (`main+0x6fa8c`: `RequestDetachMemoryPool`, then wait and update until `IsMemoryPoolAttached` is false). The sound thread took every wake, and the main thread never woke again.
- **Fix:** when the game opened the renderer for the service, the host replaces the SDK's local event with an inter-process auto-clear one (`DestroySystemEvent`, then `hle_bind_system_event(event, 1)` in `ar_open`). The SDK's renderer signals through `os::SignalSystemEvent`, which handles either kind. A game that opens a CPU renderer itself keeps the SDK's local event.
- **Found on:** [Donkey Kong Country: Tropical Freeze](../../dm/games/0100C1F0051B6000/README.md) (SDK 4.4.0): the first level's load after the intro cinematic.

### The renderer's update lock (`update_lock`)

- **Symptom:** none of its own; command generation races the game's `Update` on SDKs whose lock is not at SDK 16's offset.
- **Cause:** `AudioRenderSystem::Update` holds a mutex in `AudioRenderSystem`; `GenerateCommand` does not take it, so the host does (the auto-mode system thread does the same in `SendCommandToDsp`). Which mutex depends on the SDK: `nn::os::LockMutex(MutexType *)` at +0x1d0 in SDK 4.4 and at +0x1d8 in 6.4–8.2, `SdkMutexType::Lock` at +0x1d8 in 10.4–11.4, +0x1f0 in 13.3–16.2 and +0x1f8 in 17.5 (the `sdk` builds of 24 games on hand), inlined in 19 and 20 (+0x2d0, the Span layout: [SDK 20's `AudioRenderSystem` layout](#sdk-20s-audiorendersystem-layout)). The host took SDK 16's for every SDK before 20, which wrote a lock word into another field and excluded nothing.
- **Fix:** `update_lock` in `hle_audren.c` reads it off the SDK's own `Update`: the register the prologue adds the offset to and moves into x0 before its first `bl`, whose PLT slot must hold `LockMutex` or `SdkMutexType::Lock`; anything else keeps SDK 16's.
- **Found on:** [Mario Kart 8 Deluxe](../../dm/games/0100152000022000/README.md) (4.4), the first game it was plainly wrong for.
- **Check:** checked with sound on [Big Brain Academy: Brain vs. Brain](../../dm/games/0100620012D6E000/README.md) (11.4, +0x1d8), [DRAGON QUEST XI S](../../dm/games/01006C300E9F0000/README.md) (7.3, `MutexType` +0x1d8) and [Super Mario Odyssey](../../dm/games/0100000000010000/README.md) (7.3, which is silent for its first minute with either lock).

### No `SdkMutexType` in SDK 3

- **Symptom:** `FATAL audren: missing SDK symbol _ZN2nn2os12SdkMutexType4LockEv` right after the renderer's render thread starts.
- **Cause:** the render path looked up `SdkMutexType::Lock` / `Unlock` before reading which lock the SDK's `Update` takes ([The renderer's update lock](#the-renderers-update-lock-update_lock)); SDK 3.5.1's `sdk` has no `SdkMutexType` and takes `nn::os::LockMutex` at +0x1f8.
- **Fix:** `render_once` looks up the `SdkMutexType` functions only when `update_lock` does not find `LockMutex` (`hle_audren.c`).
- **Found on:** [OCTOPATH TRAVELER](../../dm/games/010057D006492000/README.md) (SDK 3.5.1), the first SDK 3 game through the audio renderer (Bayonetta 2's 3.6.0 plays through `AudioOut`).

### The render thread's route through the public `ExecuteAudioRendererRendering` (SDK 20)

- **Symptom:** `CommandListProcessor::Process` crashes now and then (SIGSEGV under `render_main`, once at 60 s and once at 134 s in the shrine); every `RequestUpdate` renders a catch-up frame.
- **Cause:** the public `ExecuteAudioRendererRendering` (`sdk+0x221e90`) reaches `AudioRendererImpl::ExecuteAudioRendererRendering` (`sdk+0x22ca88`, `x0 += 0x60` and a jump through the PLT) through the vtable, so the host's takeover of the `Impl` function was never called. The SDK's own `AudioRenderSystem::ExecuteAudioRendererRendering` ran instead (no update lock), every `RequestUpdate` rendered a catch-up frame because the host's render counter never moved, and the two threads wrote the same command buffer.
- **Fix:** the host also takes over `AudioRenderSystem::ExecuteAudioRendererRendering`, the PLT target (`hle_audren.c`); catch-ups fell from one per update to 3 per run.
- **Found on:** [The Legend of Zelda: Breath of the Wild](../../dm/games/01007EF00011E000/README.md) (SDK 20).
- **Note:** the same SDK's other `AudioRenderSystem` layout is in [SDK 20's `AudioRenderSystem` layout](#sdk-20s-audiorendersystem-layout).

### A renderer below 48 kHz with no upsampler on the CPU

- **Symptom:** SIGSEGV at address 0x18 in `UpsamplerManager::Allocate` on the render thread.
- **Cause:** a DeviceSink below 48 kHz is upsampled by the SDK's upsampler, and `AudioRenderSystem::SetUpRenderResourceSet` allocates the `UpsamplerManager` only for the DSP (`sdk+0x21eb6c`: rate 0x7d00 and rendering device +0x48 == 0); with the host's CPU rendering the manager pointer (`AudioRenderSystem+0x150`, the render context's +0x20) is null.
- **Fix:** the host answers `Allocate` on a null manager with no upsampler, so the generator skips the upsample command (`sdk+0x225b40`), and resamples the DeviceSink's stereo downmix 3:2 itself (a 16-tap windowed sinc in three phases, `up_3_2` in `hle_audren.c`), 240 samples per 5 ms frame for the 48 kHz output.
- **Found on:** [DRAGON QUEST VII Reimagined](../../dm/games/0100A9D01C446000/README.md): rate 32000, 160 samples per frame, `GenerateSinkCommands` `sdk+0x225a80`.
- **Note:** until then the output code assumed an upsampled buffer at 32 kHz that no game had produced.

### A sound engine's heap too small for its renderer and players

- **Symptom:** the main thread spins at start-up in a resource wait (a `YieldThread` loop, no crash), right after `OpenAudioRenderer`.
- **Cause:** the DSP service and an application's local SDK server use different command/state representations. The host forwarded the local CPU server's work-buffer requirement as the guest's DSP-service requirement. Larger local command structures could then exhaust a fixed sound heap that fits the service's budget. Changing only the device / execution fields in the local sizing routine does not reveal this difference: it still sizes the same compiled structures. The game note records the comparison against Horizon's actual sizing code and the resulting allocation failure.
- **Fix:** `ar_service_work_size` in `hle_audren.c` computes the Horizon service budget through renderer revision 15, with revision gates for graph/splitter storage, effect states, performance frames and command storage. A DSP caller receives that size. On open the host independently asks the SDK for its CPU/manual requirement and supplies a page-aligned, zeroed backend buffer if it exceeds the caller's capacity; a buffer below the declared service requirement is rejected. Both open forms share the allocation, including a nested no-event open. Failed opens free it; close joins the render thread, closes the SDK renderer, then frees it. Explicit CPU renderers keep their SDK contract. A sufficient caller buffer is reused; revisions beyond the verified service model retain the SDK size. No firmware is loaded or distributed at runtime, and no game's heap constants change.
- **Found on:** [Hyrule Warriors: Age of Calamity](../../dm/games/01002B00111A2000/README.md).
- **Check:** `make -C dm/host/tests GAME=<id> audren-work` checks independently obtained Horizon sizing fixtures, both public parameter layouts, uninitialized padding, unsupported revisions, nested opens, undersized buffers, failure cleanup, caller-owned storage and close lifetime. The sizing implementation also matched 360 seeded parameter sets executed through Horizon's original machine code across REV1–REV15. The game note records the original-heap reproduction and audio check.

## Command lists by SDK

### Incomplete startup lists must not select the command layout

- **Symptom:** no sound after boot; `audren: no DeviceSink (ID 0x13) in the command list` and a malformed-command error persist even when later command lists are valid.
- **Cause:** the host's render thread can generate commands before the game's first `RequestUpdate`. Mario Kart 8 Deluxe's first list ended in a zeroed third command, so none of the supported header layouts could walk it. `capture` nevertheless latched the default layout and consumed the one-time sink scan. Later SDK 6 headers were read as SDK 8–20 headers, and SDK 4's DeviceSink was never found. Retrying only header detection still leaves the sink scan consumed.
- **Fix:** select the header only when the whole list walks in a supported layout. Until then, return a silent frame before the sink scan; the first valid list can select both the header and its sink. `t_audren_layout` reproduces the failure and checks stereo PCM for SDK 4, 6, 16 and 21, with valid-first, empty and incomplete startup lists and SDK 21's short first list.
- **Found on:** [Mario Kart 8 Deluxe](../../dm/games/0100152000022000/README.md) (SDK 4.4.0; [PR #331](https://github.com/seedds/nxnative/pull/331)).

### The final mix is taken from the DeviceSink's mix buffers

- **Symptom:** the CPU processor drops the final mix.
- **Cause:** `dsp::SendCommandBuffer`, `dsp::Wait` and `dsp::Signal` are stubs in the application build, and DeviceSink (command 0x13) is a no-op in `CommandListProcessor::Process`.
- **Fix:** take the output after `Process` from the mix buffers the DeviceSink command names (layout in `hle_audren.c`).

### SDK 4: DeviceSink is command 0xf of 0x130 bytes

- **Symptom:** no sound: `[RED] audren: no DeviceSink (ID 0x10) in the command list, 0 commands of 0x148 bytes`.
- **Cause:** SDK 4's command list has SDK 6's header, but its DeviceSink (`CommandBuffer::GenerateDeviceSinkCommand`, `sdk+0x19e690`) is ID 0xf and 0x130 bytes: device name +0x14, upsample buffer +0x118, input count +0x120, input indices as bytes from +0x124.
- **Fix:** `capture` takes the one 0x130-byte command with 1 to 6 inputs when there is no 0x148-byte one (`g_sink4` in `hle_audren.c`).
- **Found on:** [Mario Kart 8 Deluxe](../../dm/games/0100152000022000/README.md) (4.0.0, SDK 4.4.0; one boot).
- **Note:** its `AudioRenderSystem::Update` (`sdk+0x19b77c`) locks an `nn::os::MutexType` at +0x1d0, not SDK 16's `SdkMutexType` at +0x1f0; see [The renderer's update lock (`update_lock`)](#the-renderers-update-lock-update_lock).

### SDK 6: the DSP command header layout

- **Symptom:** no sound; red `audren: command 1 in the command list is malformed (magic 0 size 0)`.
- **Cause:** SDK 6's DSP command header is +0x04 size (s16), +0x06 command ID (s16), +0x10 enabled, where SDK 8–20 have +0x04 enabled, +0x05 ID, +0x06 size (`CommandListProcessor::Process`, `sdk+0xaaa00`); its DeviceSink is ID 0x10.
- **Fix:** `capture` in `hle_audren.c` takes the layout whose walk finds the 0xcafebabe magic on every command of the first valid list; [incomplete startup lists](#incomplete-startup-lists-must-not-select-the-command-layout) leave detection open.
- **Found on:** [Fire Emblem: Three Houses](../../dm/games/010055D009F78000/README.md) (SDK 6.5.0).

### SDK 5: a startup list that walks in two layouts, and a 0x138-byte DeviceSink

- **Symptom:** no sound: `[RED] audren: no DeviceSink (ID 0x13) in the command list, 0 commands of 0x148 bytes` and `[RED] audren: command 2 in the command list is malformed (offset 0x3e, …)`, with `first-frame commands 13, by command ID:  0×2`.
- **Cause:** SDK 5.4.0's command list has SDK 6's header. Its first list holds two commands, the first of ID 0x14 and 0x14 bytes, so it walks in the SDK 8–20 layout as well (the ID read as the size), and that layout was taken because it is tried first. Its DeviceSink (`CommandBuffer::GenerateDeviceSinkCommand`, `sdk+0x233890`) is SDK 4's (ID 0xf, device name +0x14, upsample buffer +0x118, input count +0x120) but 0x138 bytes, with the input indices as s16 from +0x124.
- **Fix:** `capture` in `hle_audren.c` takes a header layout only from a list that walks in exactly one; a list that walks in none or in several is a silent frame. The sink scan takes the one 0x130-byte (s8 indices) or 0x138-byte (s16 indices, `g_sink5`) command with 1 to 6 inputs. `t_audren_layout` covers SDK 5 and Bastion's first list.
- **Found on:** [Bastion](../../dm/games/010038600B27E000/README.md) (1.0.0, SDK 5.4.0).

### Unaligned command headers during layout probing

- **Symptom:** UBSan reports a misaligned `uint32_t` load in `cmd_ok` while `t_audren_layout` probes SDK 4/6 lists (issue #409).
- **Cause:** interpreting the command ID as another layout's size can advance the candidate pointer off word alignment. Typed header loads then have undefined C behavior even though arm64 supports the machine load. A wrong size could also take the next header outside the generated list.
- **Fix:** `cmd_size`, `cmd_id` and the magic check decode multibyte wire fields with `memcpy`. `cmd_ok` verifies that the complete header and command fit before consuming them; malformed-command diagnostics do not dereference a rejected header. All supported SDK layouts use the same readers, with no game gate.
- **Check:** `t_audren_layout` checks deliberately unaligned headers, every truncated header/body length, invalid signed sizes and stereo PCM for SDK 4/6/16/21, including recovery from incomplete startup lists. The shipped SDK 6 processor reads the enabled byte at +0x10 before dispatching any command, confirming the 0x11-byte minimum used by the parser. Its UBSan alignment suppression was removed.
- **Found on:** the sanitizer audit's SDK 4/6 fixtures, representing [Mario Kart 8 Deluxe](../../dm/games/0100152000022000/README.md) and [Fire Emblem: Three Houses](../../dm/games/010055D009F78000/README.md); no game crash was attributed to this undefined load.

### SDK 8: command IDs numbered differently

- **Symptom:** no music and no sound effects, only the movies' sound (the log repeats `audren: first-frame commands …` every frame and never prints `DeviceSink inputs`).
- **Cause:** SDK 8 numbers the DSP commands differently: its command list goes 4×6, 7×24, 11×2, 16×1, 21×1 where SDK 20's goes 7×6, 11×24, 15×2, 20×1, 25×1, and the output command (DeviceSink, the same 0x148-byte layout with device name `MainAudioOut`, six inputs) is 0x10, not SDK 16's 0x13. The host never found it and played silence.
- **Fix:** when the expected ID is missing from the first full command list, `capture` in `hle_audren.c` now takes the one 0x148-byte command with 1 to 6 inputs as the sink and logs the ID it adopted.
- **Found on:** [The Legend of Zelda: Link's Awakening](../../dm/games/01006BB00C6F0000/README.md) (SDK 8.2.0).

### SDK 20's `AudioRenderSystem` layout

- **Cause:** in SDK 20 the getters the host used (`GetExecutionMode`, `GetRenderingDevice`, `GetCommandBufferWorkBufferSize`) are inlined away, `GenerateCommand` takes and returns a `Span<std::byte>` (the generated list comes back in x0 / x1), the device and mode are words at +0x48 / +0x4c, the command buffer is at +0xf8 / +0x100, and `UpdateImpl` locks the mutex at +0x2d0 instead of +0x1f0. The DeviceSink command became ID 0x14 (SDK 20 inserted a command before it) with the same layout.
- **Fix:** `render_once` picks the layout by whether the Span version of `GenerateCommand` exists (`hle_audren.c`).
- **Found on:** [The Legend of Zelda: Breath of the Wild](../../dm/games/01007EF00011E000/README.md).
- **Note:** the render thread's call takes another route in this SDK too: see [The render thread's route through the public `ExecuteAudioRendererRendering` (SDK 20)](#the-render-threads-route-through-the-public-executeaudiorendererrendering-sdk-20); the update lock at +0x2d0 is in [The renderer's update lock (`update_lock`)](#the-renderers-update-lock-update_lock).

### SDK 21 DSP command header without a magic

- **Symptom:** no sound; red `audren: command 0 in the command list is malformed (first word 0x181901 size 0)`.
- **Cause:** SDK 21's DSP command header has no magic: +0x00 enabled (bit 0), +0x01 command ID, +0x02 size (s16), +0x04 estimated time, +0x08 node ID (`CommandListProcessor::Process`, `sdk+0x24fd50`), and every command body moved 8 bytes forward. DeviceSink is still ID 0x14 but 0x140 bytes: input count +0x128, input indices +0x12c, upsample buffer +0x120 (written at `sdk+0x23a7b0`). `AudioRenderSystem` keeps SDK 20's offsets (update lock +0x2d0).
- **Fix:** `capture` (`hle_audren.c`) tries this layout when neither magic walk works, bounded by the generated list's length. Its first lists hold 4 commands or fewer, so the layout is now chosen on the first non-empty list.
- **Found on:** [Rhythm Heaven Groove](../../dm/games/0100D9F01D474000/README.md) (SDK 21.4.0, one boot).

## AudioOut and devices

### Stopping an AudioOut releases its pending buffers

- **Symptom:** FMOD waits for buffer release after stopping an AudioOut, hanging the game during a scene transition.
- **Cause:** the host stopped its backend but left unplayed and partially played buffers in the pending queue, so no callback could release them.
- **Fix:** after stopping a started backend, `au_release_pending` moves the pending buffers to the released queue in order, resets the partial-buffer position and signals the client's release event and the host waiter. Calling Stop on an already stopped output preserves buffers queued for its next Start.
- **Found on:** [Pokémon Brilliant Diamond](../../dm/games/0100000011D90000/README.md): reported on 1.0.0 in [PR #190](https://github.com/seedds/nxnative/pull/190); the 1.3.0 bring-up passed that transition before this fix.
- **Check:** `t_audio_spsc` covers a partially consumed buffer, queue wraparound, release notification, repeated Stop and buffers queued before Start, then runs its 100,000-buffer producer/consumer stress test.

### RemoteIO's default I/O buffer duration

- **Symptom:** crackling on iOS only.
- **Cause:** RemoteIO asks for as many frames per callback as the audio session's I/O buffer duration, about 21 ms by default (1024 frames at 48 kHz), while the renderer keeps 4 blocks × 5 ms = 20 ms in flight. Every callback came up 1.3 ms short and was padded with zeros, about 47 gaps per second. Reproduced on the Mac by forcing 1024-frame callbacks (`DM_DBG_AU_FRAMES=1024` with `DM_AUDIO=1`: 1999 underruns in 2000 callbacks).
- **Fix:** `AVAudioSession` `setPreferredIOBufferDuration:0.005` (and 48 kHz) before the game opens audio and again on return to the foreground (`front_ios_audio_session` in `front_ios.m`); the device then calls back with 240 frames and nothing underruns.
- **Check:** when checking a new device, read the host's `audio #N device callbacks` line, logged every 2000 callbacks: frames per callback, queued blocks, underruns.

### The Mac's default I/O buffer

- **Symptom:** clicks and dropouts on the Mac, heard as clipping; the log's `audio #N device callbacks` lines show hundreds of underruns per 2000 callbacks. Closing an output can also log `[RED] audio device buffer: ... (status 560947818)` (`!obj`).
- **Cause:** the Mac's default output asks for 512 device frames per callback (10.7 ms at 48 kHz; 557 frames of the 48 kHz stream when the device runs at 44.1 kHz), more than a game that keeps only a few small blocks queued has ready every time. Unicorn Overlord on a MacBook Pro's speakers: 250–290 underruns in every 2000 callbacks at 48 kHz (0.1–0.2 s of zeros), about 1,000 at 44.1 kHz. Whether a game underruns depends on how much it queues: 13 Sentinels (2.8 blocks queued, like Unicorn Overlord's 3.0, but larger ones) had none at 512 frames.
- **Fix:** like iOS's session buffer, the Mac sets its output unit's device buffer to about 5 ms of device frames (`kAudioDevicePropertyBufferFrameSize`, 240 at 48 kHz, 221 at 44.1 kHz), within the device's supported range (`au_buffer` in `hle_audio.c`). It reapplies this when the default output changes and when the same device's output sample rate changes; `CurrentDevice` alone does not notify a rate change. An unchanged buffer is not written again, since a write can itself notify the format listener. Both listeners are removed before uninitializing or disposing the unit, including a failed open: disposal otherwise calls the listener after the device has gone (`!obj`). The log reads back the actual frame count. `DM_DBG_AU_FRAMES=N` asks N frames instead.
- **Found on:** [Unicorn Overlord](../../dm/games/010069401ADB8000/README.md) (Asian release 1.05 on the Mac).
- **Check:** [PR #262](https://github.com/seedds/nxnative/pull/262) reports Unicorn Overlord at 240 frames: 0 underruns in 10,000 callbacks; 13 Sentinels stays at 0. A silent Core Audio probe on a Mac mini reproduced the disposal error and the stale buffer after a rate change, then verified the fixes: default output switched between USB at 48 kHz and speakers at 44.1 kHz with callbacks continuing, and the same speakers at 44.1 / 96 / 48 kHz used 221 / 480 / 240 frames. The original default output and device rates were restored. `make -C dm/host/tests GAME=<id> audio-device` checks setup, device and rate notifications, scope filtering, buffer limits, synchronous notifications, the diagnostic override, absent devices, close and failed-open listener cleanup without audio hardware.
- **Open:** the listed HDMI output was not retained as the system default during the probe, so switching to it remains unvalidated. The probe verifies silent host playback; gameplay listening after these listener changes has not been repeated.

### The ring / silent switch muted the game on iOS

- **Symptom:** a game is silent on an iPhone whose ring / silent switch is set to silent, though the volume is up; a game or video app plays through the switch.
- **Cause:** the audio session's category was `AVAudioSessionCategorySoloAmbient`, which iOS silences with the switch.
- **Fix:** `front_ios_audio_session` in `front_ios.m` sets `AVAudioSessionCategoryPlayback`: the switch no longer mutes the game, and it still interrupts other apps' audio, as `SoloAmbient` did. The host still suspends its output when the app goes to the background (no background audio mode is declared).
- **Found on:** [The Legend of Zelda: Breath of the Wild](../../dm/games/01007EF00011E000/README.md) (iPhone: reported by the player); also [issue #155](https://github.com/seedds/nxnative/issues/155), whose commenter has to toggle the switch to hear any game.
- **Check:** open question, not run on a device: with the switch on silent, the game's sound should play; the log's `audio session:` line shows the session came up.

### Interruptions that stop RemoteIO callbacks

- **Symptom:** sound stays silent after Siri, an alarm, a call or another app's audio; a game whose audio thread waits for its buffers back (Wwise's poll-only output, FMOD) then waits forever.
- **Cause:** iOS stops calling the RemoteIO unit back without stopping it, so the host still thinks the output plays.
- **Fix:** three layers handle it:
  - `front_ios.m` observes `AVAudioSessionInterruptionNotification` (began → the silent sink stands in, ended → session up again and resume; becoming active also ends an interruption whose "ended" never came);
  - `front_ios.m` also observes `AVAudioSessionMediaServicesWereResetNotification` (`dm_audio_reset` recreates every AudioUnit);
  - a watchdog in `hle_audio.c` switches any started output whose device has not called back for 200 ms in focus to the silent sink, retrying the AudioUnit after 1, 2, 4, 8 s. A start that fails (session still held by a call) falls back the same way instead of aborting.
- **Check:** the log shows `audio session: interrupted`, `the device has not called back for N ms` and `AudioUnit restarted`. `tests/t_audio.c` (in `dm/host`) scenario 3 stops a playing AudioUnit behind the host's back.

### AudioUnit construction before output publication

- **Symptom:** TSan reports `au_create` writing `a->au` while `au_watchdog` reads it under `g_aos_lock` when a second real output opens (issue #410).
- **Cause:** `au_open_at` put the output into the lifecycle/watchdog registry before joining its AudioUnit construction helper. The registry lock did not order the helper's writes.
- **Fix:** construct and join while the output is private, then publish it under `g_aos_lock`. Suspend, resume, reset and watchdog readers only discover the completed output. Construction remains outside that lock because joining the helper can yield the guest core.
- **Check:** `t_audio_device` asserts from inside AudioUnit creation that the pending output is absent from the registry; it failed before the fix. `t_audio` exercises real output lifetimes and watchdog recovery under TSan with the `au_create` suppression removed.
- **Found on:** host unit tests; no particular game's failure was attributed to this race.

### Audio across a background round trip on the Mac

`DM_AUDIO=1 DM_AUDIO_MUTE=1` takes the real Core Audio path with the output silenced, and `DM_OE_SCRIPT="bg=1@60,bg=0@66"` runs the same sequence as the iOS lifecycle callbacks (focus, audio take-over, guest clock freeze, graphics suspend). Send `dmhost` `SIGSTOP` / `SIGCONT` between the two to imitate iOS suspending the process. The silent sink that stands in while in the background does not make up the time the process was suspended (it used to pull seconds' worth at once and log hundreds of underruns).

### Several outputs at once (`audio #N`)

- **Symptom:** combined numbers mislead: one fully fed output plus one fed by nobody look like "every other callback underruns, 2.0 blocks queued".
- **Cause:** a game may open several outputs. Engage opens one AudioOut from Wwise (`main+0x177d924`, no release event, the game polls); on the phone it opened a second one later, and the Mac runs never did. Unity's FMOD also has an output (`main+0x4aec0c` / `0x4aec4c`).
- **Fix:** the host logs each output as `audio #N`: the open with its call site, Start / Stop / Close (the first 32 per output), and the callback line every 2000 of that output's callbacks.
- **Found on:** [Fire Emblem Engage](../../dm/games/0100A6301214E000/README.md).

### Checking audio without listening

`DM_AUDIO_DUMP=file` writes the PCM the host plays (16-bit, 48 kHz, stereo). RMS per second, clipping share, spectral flatness (music ≈ 0.1–0.5, white noise ≈ 0.85) and the strongest FFT peaks (they should land on musical notes) tell real music from noise or silence.

### AudioOut volume kept per output

- **Symptom:** a null read at `sdk+0x1f2314` as the first movie starts (the title menu's background, right after the first press), in `nn::audio::SetAudioOutVolume`, called from `main+0x1c4fbc`.
- **Cause:** the call is on the AudioOut the game opens for the movie's AAC sound (`OpenDefaultAudioOut` without an event, `main+0x1c48c0`). The SDK's version calls the audout session's virtual method, and the host never made the session. The game sets the volume every frame while a movie plays.
- **Fix:** the host keeps the volume per output and scales the PCM16 it plays, saturating; `GetAudioOutVolume` reads it back (`hle_audio.c`).
- **Found on:** [STEINS;GATE RE:BOOT](../../dm/games/01008BC024FDE000/README.md) (SDK 20.5.17, M2's ADV engine; the one call it needed).

### AudioOut buffer count from the host queue

- **Symptom:** a null read in `audio::GetAudioOutBufferCount` on Wwise's sink wakeup thread (`sdk+0x1e7ed0`, from `main+0x30faae8`).
- **Cause:** after every release event Wwise asks how many buffers are still queued and marks the sink starved at 0; the SDK's version read the audout session the host never made.
- **Fix:** it answers from the host queue: appended and not yet played to the end (`hle_audio.c`).
- **Found on:** [Pokémon Legends: Z-A](../../dm/games/0100F43008C44000/README.md) (19.3.11; one boot).

### Audio device output volume and names

- **Symptom:** an abort in `sm::Initialize` under `audio::GetAudioDeviceOutputVolume` (the game thread, `main+0xee8edc`).
- **Fix:** the volume `SetAudioDeviceOutputVolume` sets is now kept and read back (`hle_audren.c`). `audio::GetAudioOutName` is hooked too.
- **Found on:** [DRAGON QUEST VII Reimagined](../../dm/games/0100A9D01C446000/README.md) (SDK 19.3.1, Unreal Engine 4.27: `GetAudioDeviceOutputVolume`); [13 Sentinels: Aegis Rim](../../dm/games/01003FC01670C000/README.md) (SDK 11: `GetAudioOutName`).
- **Note:** older SDKs name some device calls differently (`ListAudioDeviceName` / `GetActiveAudioDeviceName`, `OpenDefaultAudioOut` in SDK 12; [Older SDK names for the same calls](services.md#older-sdk-names-for-the-same-calls)), and [Super Mario Odyssey](../../dm/games/0100000000010000/README.md) (SDK 7) aborted in `audio::AcquireAudioDeviceSwitchNotification` ([SDK calls that open a system service through sm](services.md#sdk-calls-that-open-a-system-service-through-sm)).

### No audio input devices

- **Symptom:** SDL3's audio driver lists the input devices (AudioIn) when its audio starts.
- **Cause:** the host has no microphone.
- **Fix:** `ListAudioIns` reports none, both opens fail, and the calls that need an open AudioIn answer without touching the game's object (`hle_audio.c`).
- **Found on:** [Absolum](../../dm/games/0100A83022A22000/README.md) (SDK 18.3.2, FNA on .NET NativeAOT with SDL3; one boot each).

## Codecs

### Hardware Opus decoders built on the SDK's software decoders

- **Symptom:** an abort in `sm::Initialize` under the hardware Opus decoder's C interface; for the multi-stream one, under `nn::codec::GetHardwareOpusMultiStreamDecoderWorkBufferSize(int, int, int, int, int)` (at `nnMain`, CRI's Opus streams). An abort in `sf::hipc::InitializeHipcServiceResolution` under `codec::GetHardwareOpusDecoderWorkBufferSize(int, int)` (`main+0x31f8e8`, early in `nnMain`). A game that builds `HardwareOpusMultiStreamDecoder` with the imported constructor and then calls it through its vtable.
- **Cause:** the hardware decoders are a service. The `HardwareOpusMultiStreamDecoder` class's 12 vtable slots match the SDK's software `OpusMultiStreamDecoder` one by one. SDK 11 has a work buffer size form without the option argument; the host had only the three-argument one.
- **Fix** (`hle_codec.c`):
  - the classes: the constructor hook builds the software decoder in place (0x38 of the 0x48 bytes), as for the single-stream `HardwareOpusDecoder`; `GetHardwareOpusMultiStreamDecoderWorkBufferSize` returns the software size. Both destructors are a bare `ret`.
  - the single-stream C interface (`GetHardwareOpusDecoderWorkBufferSize`, `InitializeHardwareOpusDecoder`, `DecodeOpusInterleavedWithHardware`, …) is forwarded to the `sdk`'s software `OpusDecoder` C interface with a host-held decoder state per game object.
  - the multi-stream C interface, including the SDK 12+ overload with an option argument, goes to the `sdk`'s software `OpusMultiStreamDecoder` C interface, with a host-held state per game object as for the single-stream decoder. `GetHardwareOpusMultiStreamDecoderProcessingTime` reports 0.
  - the two-argument `GetHardwareOpusDecoderWorkBufferSize` is hooked beside the three-argument one.
- **Found on:** [Hyrule Warriors: Age of Calamity](../../dm/games/01002B00111A2000/README.md) (SDK 9.6: only the `HardwareOpusMultiStreamDecoder` class and the four-argument size); [The Legend of Zelda: Tears of the Kingdom](../../dm/games/0100F2C0115B6000/README.md) (1.4.3, the single-stream C interface); [Big Brain Academy: Brain vs. Brain](../../dm/games/0100620012D6E000/README.md) (SDK 11.4.3, the two-argument size); [Unicorn Overlord](../../dm/games/010069401ADB8000/README.md) (SDK 16.2.4, the multi-stream C interface; one boot).

## Timing and catch-up

### At least one rendered frame between two updates

- **Symptom:** the light limiter crashed on a null state pointer (`ApplyLightLimiterEffect`, `sdk+0x228494`).
- **Cause:** an effect's "needs init" parameter state is set only in the update where the game flags it new; the next update copies the game's value over it. Mario updates twice in a row at start-up; with a real audio device the first frame came after both.
- **Fix:** the `AudioRenderSystem::Update` hook renders a catch-up frame first when nothing was rendered since the last update.
- **Found on:** [Super Mario Bros. Wonder](../../dm/games/010015100B514000/README.md).
- **Check:** `DM_AUDREN_TRACE=1` logs every update with the number of frames rendered since the previous one.

### A sound driver that never waits on the renderer event

- **Symptom:** the sound runs about 50 times faster than the output; the loop runs 11,000 updates a second on one core.
- **Cause:** Square Enix's `SQEX::Sd::Driver::Core::CoreAudioOut` (its loop at `main+0x442c5c0`) appends a wave buffer, mixes the next block on the same thread, calls `RequestUpdate` and takes the next released buffer. It waits on the renderer event only when no buffer is released. Every update there finds no frame rendered since the last one and renders a catch-up frame, which releases the buffer just appended, so the loop never waits. When a full catch-up queue discarded the frame, the loop ran unchecked.
- **Fix:** an update with a full queue waits (at most 50 ms) for the render thread to play one queued frame, so catch-up frames keep real time (`hle_audren.c`). The render thread then only plays queued frames, and the driver's updates render every frame. A queued frame does not signal the renderer event (the SDK signals it in each render): signalled, an ordinary game woke, updated with nothing rendered since and rendered the next catch-up frame, so every frame became one ([Big Brain Academy: Brain vs. Brain](../../dm/games/0100620012D6E000/README.md), about 38,000 catch-up renders instead of 37).
- **Found on:** [DRAGON QUEST XI S: Echoes of an Elusive Age – Definitive Edition](../../dm/games/01006C300E9F0000/README.md).
- **Check:** `audren: rendered 12000 frames, N of them not silent` shows whether a game's sound reaches the output.
