# Movies

The SDK's movie library (`movie::Decoder`, `movie::Extractor`), which the host takes over in `dm/host/hle_movie.c`, and the games' movie players. Each entry: symptom, cause, fix, the games it was found on. The [symptom index](../agents/symptoms.md) lists every symptom.

## Decoder lifecycle

### The SDK's hardware decoder opens nvdrv

- **Symptom:** abort in NVIDIA's video path (`NvRmChannelOpen` → `NvOsDrvOpen`).
- **Cause:** the SDK movie library's hardware decoder opens nvdrv directly.
- **Fix:** the host takes over `movie::Decoder` (`hle_movie.c`, [`movie::Decoder` taken over as a MediaCodec-style protocol](#moviedecoder-taken-over-as-a-mediacodec-style-protocol)); nvdrv opens fail (`hle_nvdrv.c`).

### `movie::Decoder` taken over as a MediaCodec-style protocol

- **Symptom:** the game waits forever at a movie (Engage's 94 s opening `S01F.webm`; frames keep presenting, nothing happens).
- **Cause:** Unity demuxes the WebM itself and feeds VP9 packets to `movie::Decoder`; with no working decoder the movie never ends.
- **Fix:** `movie::Decoder` is a thin wrapper over Android's MediaCodec, and its vtable entries are symbol relocations, so `HLE_FORCE` on each method also catches Unity's virtual calls. The host implements the protocol: four `nn::os` events (`DecoderEvents` = input available, output ready, format changed, error), input indices (`AcquireInputBufferIndex`, none = 0x1011; `GetInputBuffer` fills the client's `movie::Buffer`; `SendInputBufferForDecode(index, offset, size, µs, flags)`), output indices (`AcquireOutputBufferIndex`, none = 0x100e; one NV12 frame per packet copied into the buffer Unity allocated, w × h × 1.5; `ReleaseOutputBufferIndex`). `Buffer`, `MediaData` and events are handled through the SDK's own exported functions (`SetDataAndCapacity`, `SetRange`, `SetInt32`, `SetRect`, `SignalEvent`). Unity reads `width`, `height`, `crop`, `nv12-y-stride`, `nv12-y-offset`, `nv12-uv-offset` and `slice-height`. The guest thread that sends a packet or returns an output index waits for the decode and signals the events itself, because `SignalEvent` is guest code and cannot run on a host thread.
- **Found on:** [Fire Emblem Engage](../../dm/games/0100A6301214E000/README.md): when the movie ends the game continues to its title screen.
- **Note:** output slots, VP9 decoding and the output format keys are in their own entries ([Packets wait while every output slot is taken](#packets-wait-while-every-output-slot-is-taken), [VP9 on host threads with libvpx](#vp9-on-host-threads-with-libvpx), [Output format keys (`md_format`)](#output-format-keys-md_format)).

### Output format keys (`md_format`)

- **Symptom:** a movie in grey with vertical bands of colour, its luma sharp; or a read far outside guest memory at `main+0x344f74` on the first movie picture (CRI Sofdec2's NV12 → RGB conversion).
- **Cause:** the host never set `nv12-uv-stride` in the output format (Unity reads `nv12-uv-offset` only). CRIWARE's Sofdec hands its VP9 video to `movie::Decoder` in mode 1, NV12 into its own buffers, and draws the planes with its shaders; it reads `nv12-uv-stride` from the output format, and the bands were the top row's chroma: every chroma row was read from the first one. Catherine's Sofdec2 sends its H.264 through `movie::Decoder`, mode 1, output format 4; the player reads `nv12-y-stride`, `nv12-y-offset`, `nv12-uv-stride` and `nv12-uv-offset` from the output format and checks none of the results (`main+0x34e694`), so the chroma stride was stack garbage.
- **Fix:** the host now sets everything the SDK's `DecoderImpl::GetOutputBufferFormatFromDecoder` (SDK 19 `subsdk0+0x121f50`) does: also `nv12-uv-stride`, the luma (Y) stride as for any NV12 picture, `nv12-width` and `nv12-height` (`md_format` in `hle_movie.c`).
- **Found on:** [DRAGON QUEST VII Reimagined](../../dm/games/0100A9D01C446000/README.md) (the grey picture); [Catherine: Full Body](../../dm/games/0100BF00112C0000/README.md) (SDK 8.2.1, CRI middleware; one boot: the crash).

### SDK 4's `movie::Decoder` constructor without a priority

- **Symptom:** a call through a null pointer in the host's `movie::Decoder::Configure` right after `nnMain` starts the logos.
- **Cause:** SDK 4's `Decoder` constructor has no priority argument (`_ZN5movie7DecoderC1ENS_11DecoderTypeENS_19DecoderOutputFormatENS_11DecoderModeE`). The host took over only the four-argument one, so the SDK built its own decoder and the host's `Configure` read that object as its own.
- **Fix:** both forms are taken over now (`hle_movie.c`).
- **Found on:** [DARK SOULS: REMASTERED](../../dm/games/01004AB00A260000/README.md) (SDK 4.5.0; one boot).

### The complete-object destructor

- **Cause:** the game calls the complete-object destructor `movie::Decoder::~Decoder` (`D1`); the SDK's own one destroyed the host object as a `DecoderImpl`.
- **Fix:** the host now takes it over too.
- **Found on:** [Metroid Dread](../../dm/games/010093801237C000/README.md).

### Client events read through the registered pointer

- **Symptom:** the first deferred signal crashed in `InternalCriticalSectionImplByHorizon::Enter` (DRAGON QUEST XI S).
- **Cause:** `RegisterClientEvents` copied the four event pointers, because Dread's struct had been overwritten by its second movie. DRAGON QUEST XI S (Unreal's Switch movie player, VP9 with 6-channel Vorbis) does the opposite: it registers its struct right after constructing the decoder (`main+0x39edab0`, through the decoder's vtable) and fills it later, so the copy held leftovers (`0xe00000010`). The SDK keeps only the pointer (`DecoderImpl::RegisterClientEvents` stores it at +0xd0) and reads the entry each time it signals, skipping a null one (`SendOutputBufferEventAvailableToClient` and the others, `subsdk0+0x1feb0`).
- **Fix:** the host now does the same (`md_event` in `hle_movie.c`). When the client's entry is not a readable, 8-byte aligned pointer, it falls back to the entry's value at registration if that was one (Dread's case), and otherwise logs a red line.
- **Found on:** [Metroid Dread](../../dm/games/010093801237C000/README.md); [DRAGON QUEST XI S](../../dm/games/01006C300E9F0000/README.md).

### `Flush`, `Stop` and `Start`

- **Fix:** as with MediaCodec, `Flush` announces nothing, and no input or output index is handed out while the decoder is stopped. The "input available" after `Start` is signalled about 2 ms later from a guest thread, as the SDK's codec thread would. Pending signals are dropped at `Stop`, `Flush` and destruction.
- **Found on:** [Metroid Dread](../../dm/games/010093801237C000/README.md): the game ends a movie with `Flush`, `Flush`, `Stop`, destroy, and calls `Start` after a `Flush` when it loops.

### Input indices returned by a flush while a client holds them

- **Symptom:** the process dies when an activity starts, 2 runs in 5, with no `CRASH` line: the run ends with exit 137 (SIGKILL), and `~/Library/Logs/DiagnosticReports/dmhost-*.ips` has `EXC_BREAKPOINT` in `_os_unfair_lock_corruption_abort` ← `pthread_mutex_destroy` ← `md_free` (the movie decoder's destructor).
- **Cause:** each activity's preview is an H.264 movie (`movie/Movie/*.mp4`) the game loops with Flush and Start, from four threads at once (`DM_MOVIE_TRACE=1` logs every decoder call with its thread). Its event thread acquired an input index while the control thread's Flush waited for the packet being decoded; the flush then returned that index to the free list, it was handed out a second time, two packets shared one buffer (VideoToolbox -12909 on the overwritten one, in exactly the runs that died), and a fifth pending packet wrote past `pend[]` into the decoder's `npend` and `dmu`.
- **Fix** (`hle_movie.c`): a send now claims an index a flush returned, and `pend[]` cannot overflow. Handing such an index out last was not enough (with three hosts running at once one run still sent an index twice): an index the client held across a flush is now withheld for 250 ms unless the client sends it first, and an acquire refused only for that announces input when the first one comes back, so a client that abandons its indices, as MediaCodec's rules expect, loses none.
- **Found on:** [Big Brain Academy: Brain vs. Brain](../../dm/games/0100620012D6E000/README.md) (SDK 11.4.3, its activity previews).

### End of stream is the last input until `Flush` or `Stop`

- **Symptom:** when the prologue movie was skipped, 2.25 GB were mapped within seconds, past the application pool, and the game crashed in its allocator (DRAGON QUEST XI S).
- **Cause:** DRAGON QUEST XI S's movie player sends an end-of-stream packet (length 0, time 0) for every input it gets once its extractor is done, until the game stops the movie. Each one became an end-of-stream output that the player turned into an audio sample.
- **Fix:** also as with MediaCodec, an input marked end-of-stream is the last until `Flush` / `Stop`: no input index is handed out or announced after it (`in_eos` in `hle_movie.c`).
- **Found on:** [Metroid Dread](../../dm/games/010093801237C000/README.md) (movie sub-list); [DRAGON QUEST XI S](../../dm/games/01006C300E9F0000/README.md).

### End-of-stream packets with no data, and deleted decoders

- **Symptom:** decoding the end-of-stream packet gave VideoToolbox −12909 and AudioToolbox −50.
- **Cause:** the game ends a stream with time −1 and the whole 4 MB input buffer as its length: that packet carries no data. It also deletes its decoders (`D0`).
- **Fix:** for `D0` the host frees the object with the game's `operator delete` after its own state.
- **Found on:** [Monster Hunter Rise](../../dm/games/0100B04011742000/README.md).

### H.264 drain at the end of a stream goes on with released slots

- **Symptom:** the game never leaves a movie that has played to its end; the last picture stays on screen.
- **Cause:** `DM_MOVIE_TRACE=1`: the end-of-stream packet came with H.264 pictures still in the reorder queue, its output went out as a black picture without the end-of-stream flag, and the queued pictures were to follow one per free output slot (the drain). Unity held all 16 video slots by then. `ReleaseOutputBufferIndex` decoded again only when packets were queued, and none were, so the drain never went on: no flag, and the game waited for the movie's end for good.
- **Fix:** a released slot now goes on with a drain too, and the end-of-stream packet's own output takes the first queued picture (`jflush`), so no black picture shows before a movie's last frames (`hle_movie.c`).
- **Found on:** [AI: THE SOMNIUM FILES](../../dm/games/010089B00D09C000/README.md) (Unity 2017.4: the 6 s Spike Chunsoft logo `StreamingAssets/Movie/al_titel_cl_sc_1k_30.mp4`, H.264 High, before the title).
- **Note:** the audio decoder was never affected: AAC has no reorder queue.

### No picture carries the end-of-stream flag

- **Symptom:** an anime or story movie ends on a black screen; the pause menu still works and skipping lets the game continue.
- **Cause:** at the end of an H.264 stream the host put the end-of-stream flag on the last picture of its reorder queue. CRI Sofdec2 drops an output flagged end-of-stream without showing it and waits for the picture it counted on: the movie never completes. Catherine's anime intro had 1,140 of its 1,141 pictures delivered, the last only with flag 4. The queue held pictures there for no reason too: `hle_movie_avc.c` held four for every non-Baseline stream, assuming B-frames, but Catherine's High-profile streams use SPS `pic_order_cnt_type = 2`, whose output order is the decode order (H.264 8.2.1.3).
- **Fix:** the drain hands out every queued picture without the flag, then one output without a picture carries it, with the end-of-stream packet's time (`md_pump` in `hle_movie.c`), as VP9 and Baseline streams whose end-of-stream packet has no data already ended. This holds for every H.264 stream, with or without B-frames. Separately, `avc_reorder_depth` reads the SPS through `pic_order_cnt_type` (emulation-prevention bytes removed, the High-profile chroma fields and scaling lists skipped): POC type 2 needs no reorder queue in any profile; other POC types keep a depth of 4 (0 for Baseline), as does an SPS cut short. No timeout or movie skip is involved; the intro delivers all 1,141 pictures and goes on to Golden Playhouse by itself.
- **Found on:** [Catherine: Full Body](../../dm/games/0100BF00112C0000/README.md) (1.0.1a, CRI Sofdec2, H.264 High, NV12).
- **Check:** `t_movie_avc` (`dm/host/tests`) runs the drain through `md_pump` with synthetic pictures, with all output slots free and with two, and checks the SPS reader (POC types, scaling lists, chroma formats, truncated input). The game's `smoke.tsv` lets its intro finish without a skip press. On the Mac from a fresh save, the host before this fix never closed the intro's decoder in 180 s; the drain alone (with the old reorder depth of 4) and the drain with POC type 2's depth of 0 both had all 1,141 pictures out and the decoder closed, and the latter's screenshot shows Golden Playhouse.
- **Open:** CRI hands the decoder zero timestamps, so the reorder queue, sorted by time, cannot reorder a CRI stream that has B-frames; none has been found yet. Catherine's later story movies and its movies on the iPhone have not been checked one by one.

## Output slots

### Output slot counts per decoder kind

A decoder hands out as many outputs as it has slots, and while every slot is taken it takes no input ([Packets wait while every output slot is taken](#packets-wait-while-every-output-slot-is-taken)). The counts now (`hle_movie.c`): `MD_NOUT` 64 for a Vorbis decoder (the most any decoder has), `MD_NOUT_AAC` 32 for AAC and `MD_NOUT_VIDEO` 16 for video; a slot is allocated when first used. Every decoder had 8 at first. The entries below raised them one game at a time, and each gives the counts of its time: audio 32 ([Audio decoders keep more outputs than a pre-decoding player fills](#audio-decoders-keep-more-outputs-than-a-pre-decoding-player-fills)), audio 64 ([Audio output slots for players that hold every output](#audio-output-slots-for-players-that-hold-every-output)), video 16 ([Video output slots: how far the extractor gets ahead](#video-output-slots-how-far-the-extractor-gets-ahead)) and AAC 32 ([AAC decoders offer at most 32 outputs](#aac-decoders-offer-at-most-32-outputs)).

### Packets wait while every output slot is taken

- **Fix:** while every output slot is taken, packets wait and their input indices are not returned, as with MediaCodec; dropping them instead lost frames.
- **Found on:** [Fire Emblem Engage](../../dm/games/0100A6301214E000/README.md).

### Audio decoders keep more outputs than a pre-decoding player fills

- **Symptom:** the opening movie never starts, in about half the boots (DRAGON QUEST XI S: a black screen and no sound from boot on).
- **Cause:** Square Enix's `UMediaPlayer` has two natives of its own, `StartPreDecoding` and `IsPreDecodingCompleted`. The opening's Blueprint polls the second once a frame and only then plays its Matinee, whose event key calls `Play`. Its Switch player (vtable `main+0x77921b8`, `IsPreDecodingCompleted` at `main+0x42d4d20`) is complete when every selected track has at least one decoded output queued. The player starts its clock and its decoders on the first `TickInput` after `StartPreDecoding`. The render thread's first fetch (`main+0x39f07d0`, the `+0x5c7` flag) takes every decoded picture and shows the newest. The host decoded all eight video outputs (to 236 ms) within 36 ms. Each Vorbis decoder's 8 outputs were full by then, because nothing consumes audio before `Play`, so the extractor waited for an audio input and no picture followed the ones the render thread took. The movie started only when the game thread's poll came between the first decoded picture and that fetch.
- **Fix:** audio decoders then kept 32 outputs (`MD_NOUT`) and video decoders 8, so video keeps flowing after the first fetch. Since then audio decoders have 64 (Monster Train 2), AAC ones 32 (`MD_NOUT_AAC`, Mario vs. Donkey Kong) and video ones 16 (`MD_NOUT_VIDEO`, Animal Crossing: New Horizons); see [Output slot counts per decoder kind](#output-slot-counts-per-decoder-kind).
- **Found on:** [DRAGON QUEST XI S](../../dm/games/01006C300E9F0000/README.md): 8 boots out of 8 start; [Monster Train 2](../../dm/games/010051701FB46000/README.md) (64).
- **Note:** to find such a gate: probe the player's `SetRate` (`DM_PROBE=main:<off>`) to see whether the game ever asks to play, then follow the Blueprint native that calls it (the `FNameNativePtrPair` tables give the names).

### Audio output slots for players that hold every output

- **Symptom:** a movie stays black after its first picture, the sound never starts, and the game keeps presenting frames.
- **Cause:** the player takes every output a decoder offers and starts playing only once it holds about half a second of audio. The host then gave each decoder 8 output slots (before DRAGON QUEST XI S's 32 for audio) and takes input only while one is free (as MediaCodec does). `DM_MOVIE_TRACE=1` (each line now names the decoder): Unity held all 8 audio outputs, the audio decoder kept the next 4 packets and handed out no input index, the video packets behind them in the file never came, and the video decoder had given out one picture (the host releases H.264 pictures once more than 4 are queued).
- **Fix:** slot counts per decoder kind, measured: 8 audio / 8 video and 8 audio / 32 video hang; 64 audio / 8 video plays, starting with 27 audio and 8 video outputs held (peak 30 audio). 32 audio slots hold that peak with two to spare, so audio decoders got 64 (`MD_NOUT`; a PCM slot is 128 KB, allocated when first used), and video kept 8 (`MD_NOUT_VIDEO`: a 1080p picture is 3 MB, 8 MB as RGBA).
- **Found on:** [Monster Train 2](../../dm/games/010051701FB46000/README.md) (its 90 s intro, `StreamingAssets/intro_fmv.mp4`: H.264 High with 2 reorder frames and AAC interleaved packet by packet, played by Unity 2022.3's movie player: `movie::Extractor` in `subsdk0` feeds both decoders from one thread in file order). The game's A, B and + do not skip this intro.
- **Note:** later changes: video decoders have 16 slots ([Video output slots: how far the extractor gets ahead](#video-output-slots-how-far-the-extractor-gets-ahead)) and AAC decoders 32 ([AAC decoders offer at most 32 outputs](#aac-decoders-offer-at-most-32-outputs)); Vorbis keeps 64. `hle_movie.c` now has `MD_NOUT` 64, `MD_NOUT_AAC` 32, `MD_NOUT_VIDEO` 16.

### Video output slots: how far the extractor gets ahead

- **Symptom:** a movie shows as a black screen with the loading icon, one picture every few seconds, while its sound decoder keeps up.
- **Cause:** this player also holds every output it is offered (16 of 16 video, 59 of 64 audio), so how far its extractor can get ahead of the picture on screen is the video slots plus the 4 queued packets. With 8 video slots that was 0.4 s, and the audio behind the next video packet, whose clock the player follows, ran dry: 86 pictures in 25 s. With 16 or 32 slots all 1,960 play at 30 fps.
- **Fix:** a video decoder now has 16 (`MD_NOUT_VIDEO`); a slot is allocated when first used, so the 8 more cost 24 MB of NV12 at 1080p only in a player that holds them all.
- **Found on:** [Animal Crossing: New Horizons](../../dm/games/01006F8002326000/README.md) (the in-flight movie `Movie/OpeningMovie.webm`, VP9 1080p and Vorbis through `movie::Extractor`).

### AAC decoders offer at most 32 outputs

- **Symptom:** a crash in the game's heap free (`sead::ExpHeap`) on a movie thread, a second into the first movie, at the same address every boot (`pc=main+0x42f980`, a free-list unlink through a link of 0x3f, `addr=0x47`).
- **Cause:** the game's movie player keeps the outputs it holds in a ring of 32 entries {u32 output index, u32 flags, u64 time} per track (`main+0xe93d4c`: 0x200 bytes) and pushes with no bounds check (`main+0xe94140`), and the host's audio decoder offered 64 outputs, so the 33rd outstanding one, index 63, went past the ring. The console's AAC decoder cannot offer more than 32, or the game would overflow there too.
- **Fix:** AAC decoders now have 32 outputs (`MD_NOUT_AAC`; Monster Train 2 peaked at 30 held), Vorbis keeps 64.
- **Found on:** [Mario vs. Donkey Kong](../../dm/games/0100B99019412000/README.md) (1.0.1, SDK 15.3.0: its opening movie `Movie/Cutscene01.mp4`, H.264 and AAC through `movie::Extractor`).
- **Check:** `DM_PROBE_WATCH` on the link broke the movie's file reads (the page also held a 64 KB read buffer, and `read()` into a protected page fails with EFAULT), so the movie stopped and nothing crashed; `DM_PROBE_POLL=<address>+8=3f` (a snapshot only at the change to that value) showed it being written right after the block was relinked, and the values around it were the ring's pairs.

### AAC output buffer size is one frame

- **Symptom:** the movie then froze on its first second, its sound decoder full and the game taking no more audio.
- **Cause:** the player opens an AudioOut of its own (`main+0xe92c2c`), sizes its buffers by the audio decoder's `GetOutputBufferSize`, decodes straight into them (`SetDataAndCapacity` with that size) and appends each whole, advancing its audio clock by size / 4 samples (`main+0xe92a74`). The host answered 128 KB, a bound for any Vorbis packet, so every 4 KB AAC frame played as 0.68 s and the clock crawled (a temporary log of `AppendAudioOutBuffer` showed 131,072-byte buffers).
- **Fix:** an AAC decoder now reports one frame: 1024 samples per channel, 2048 with SBR (object type 5 or 29 in the AudioSpecificConfig), which is what each output holds; Vorbis keeps the bound, its packets vary in length.
- **Found on:** [Mario vs. Donkey Kong](../../dm/games/0100B99019412000/README.md) (1.0.1, the same movie as in [AAC decoders offer at most 32 outputs](#aac-decoders-offer-at-most-32-outputs)).

## Native-texture output

### Decoding into the client's NVN texture

- **Cause:** the decoder is created with output format 3 and mode 2 (`DecoderMode_NativeTexture`). The client's `movie::Buffer` then carries the `NVNtexture` object itself as its data, 8 bytes of capacity (an `RGBX8_SRGB` texture embedded in the game's texture pool entry, `main+0x226c98`), plus `SetNvnDev` / `SetNvnSync`.
- **Fix:** the host converts the VP9 picture to RGBA (BT.709 / BT.601 and range from the stream) and writes it into the texture's storage like `WriteTexels`, then marks the sync as signalled (`nvn_host_write_texture` / `nvn_host_signal_sync` in `hle_nvn.c`). The host writes the texture's block-linear storage on the CPU and the replay layer re-uploads the dirtied pages, as for `WriteTexels` ([nvn-objects.md](nvn-objects.md)).
- **Found on:** [Metroid Dread](../../dm/games/010093801237C000/README.md).

### SDK 4's `movie::Buffer` has no sync object

- **Symptom:** `FATAL movie: missing SDK symbol _ZNK5movie6Buffer10GetNvnSyncEv` at the first frame of the native-texture movie (H.264 into the game's RGBA texture, as in Monster Hunter Rise).
- **Cause:** SDK 4's `movie::Buffer` carries the texture object but no sync object.
- **Fix:** the lookup is optional now; the game reads the texture once `GetOutputBuffer` returns, which the CPU write satisfies.
- **Found on:** [DARK SOULS: REMASTERED](../../dm/games/01004AB00A260000/README.md) (SDK 4.5.0; one boot).

### Parameter sets in `Configure` made the H.264 decoder without RGBA

- **Symptom:** a native-texture movie shows as a strip of small grey copies at the top of the screen.
- **Cause:** the texture held NV12 bytes. In RGBA8, 405 rows of 1920 pixels are exactly a 1920×1080 NV12 frame, rows 0–270 the luma at video black (16) and rows 270–405 the chroma (128). This game's MP4 demuxer hands the parameter sets to `Configure` (`csd-0` / `csd-1`), which made the H.264 decoder there without switching it to RGBA, and the first packet then found it made.
- **Fix:** both paths now go through `md_avc_open` (`hle_movie.c`).
- **Found on:** [Absolum](../../dm/games/0100A83022A22000/README.md) (H.264 logos, FNA3D's `nx_video_player.cpp`: type 1, output 3, mode 2). Monster Hunter Rise's movies never brought parameter sets to `Configure`.

### Last picture kept across a flush and at end of stream

- **Symptom:** looping movie previews flash black at the end of every loop.
- **Cause:** the game reads the buffers of the end-of-stream output (no picture) and of an output it acquired before the flush, and the host painted its texture black for both.
- **Fix** (`hle_movie.c`): a flush now keeps each slot's last picture, and in native-texture mode an output with no picture leaves the texture as it was, as the SDK's GPU consumer has nothing to draw.
- **Found on:** [Big Brain Academy: Brain vs. Brain](../../dm/games/0100620012D6E000/README.md) (the same looped activity previews, Flush and Start).

### `GetOutputBuffer` returns the output index in native-texture mode

- **Symptom:** a native-texture movie freezes on its 16th picture while the game keeps running; `DM_MOVIE_TRACE=1` shows 16 `AcquireOutputBufferIndex` / `GetOutputBuffer` pairs and no `ReleaseOutputBufferIndex`.
- **Cause:** in native-texture mode (output 3, mode 2) the SDK's `DecoderImpl::GetOutputBuffer` calls `CopyOutputBufferToClientTextureAndRelease`, which renders the picture into the client's texture with MediaCodec's `renderOutputBufferAndRelease`: the index goes back to the decoder there, and a client need not release it. The host kept the slot until a release, so a client that never releases held all 16 video slots and the decoder stopped. A client that releases anyway gets success from the SDK, whose texture-mode `ReleaseOutputBufferIndex` turns MediaCodec's "not owned" (-13) into 0 (SDK 17.5.9 `subsdk0+0x123a0c`).
- **Fix** (`hle_movie.c`): the host tracks which output slots the client holds (taken by `AcquireOutputBufferIndex`, returned by a release or a flush). A texture-mode `GetOutputBuffer` returns its slot after writing the texture, and a release of a slot the client does not hold changes nothing and returns 0. Before, such a second release freed a slot the decoder might have filled again.
- **Found on:** [Super Mario Party Jamboree](../../dm/games/0100965017338000/README.md) (SDK 17.5.9: the opening movie and the mode previews). Metroid Dread (SDK 11.4.3) has the same copy-and-release and still releases each index itself, the case the second rule covers.

## Demuxers and codecs

### `movie::Extractor` runs natively

- **Symptom:** the game crashed on a null right after the failed open.
- **Cause:** `movie::Extractor` (libwebm in `subsdk0`) runs natively. The host used to force `SetDataSource` to fail because Engage's Unity demuxes by itself.
- **Fix:** the host no longer forces `SetDataSource` to fail.
- **Found on:** [Metroid Dread](../../dm/games/010093801237C000/README.md).

### VP9 on host threads with libvpx

- **Fix:** VP9 packets are decoded with libvpx (`dm/third_party/libvpx`) on one host thread per decoder: guest threads run on the stacks the SDK gives them, too small for libvpx. Packets are decoded in arrival order from one queue.
- **Found on:** [Fire Emblem Engage](../../dm/games/0100A6301214E000/README.md).

### VP8 uses the same libvpx worker and output paths

- **Symptom:** VP8 WebM movies play black; `movie::Decoder` is created with decoder type 2.
- **Cause:** the host offered output slots for VP8 without decoding the packets, and its vendored libvpx included only the VP9 decoder.
- **Fix:** the same libvpx revision now includes its VP8 decoder. Type 2 selects `vpx_codec_vp8_dx`, type 3 selects VP9; both use the existing worker, NV12 conversion and native RGBA output. VP8 keyframe dimensions come from its ten-byte uncompressed header. Only decoded pictures and end-of-stream packets make an output ready.
- **Found on:** [Pokémon Brilliant Diamond](../../dm/games/0100000011D90000/README.md): logos and opening WebM movies. Decoding 3,182 packets over 106 seconds averaged about 1 ms per packet; making the picture visible also needed [zero initialization of depth textures](rendering.md#new-textures-start-as-zero). [Silver Pines](../../dm/games/0100D5B026844000/README.md): the Team17 logo and the title screen's animated background, 1920x1080.
- **Check:** `t_movie_vpx` decodes synthetic VP8 and VP9 keyframes through the real decoder, checking NV12 and RGBA pixels and a truncated VP8 header.

### H.264 into an RGBA texture and AAC through AudioToolbox

- H.264 (type 1) into the client's NVN texture (output 3 = RGBA, mode 2), with AAC 5.1 sound (type 4, PCM16). VideoToolbox decodes to BGRA for that mode (`mavc_set_rgba`), and AAC goes through AudioToolbox's converter with an MPEG-4 ES descriptor built from the AudioSpecificConfig in `csd-0` (as FFmpeg's AudioToolbox decoder does). Found on [Monster Hunter Rise](../../dm/games/0100B04011742000/README.md); its end-of-stream packets and decoder deletes are in [End-of-stream packets with no data, and deleted decoders](#end-of-stream-packets-with-no-data-and-deleted-decoders).

### Vorbis movie sound

- Movie sound in [The Legend of Zelda: Link's Awakening](../../dm/games/01006BB00C6F0000/README.md) (SDK 8.2.0): the decoder is asked for type 5 (Vorbis) with output format 1 (PCM16); see the other entries in this file and `hle_movie.c`.

## Movie players

### Unity's video planes and checking the movie path

- Unity's `Hidden/VideoDecode` samples luma as `.w` of an `R8` texture with the swizzle `(0, 0, 0, R)` (Unity's Alpha8) and chroma from an `RG8` texture at half size; both are CPU-written block-linear textures ([nvn-objects.md](nvn-objects.md)).
- **Check:** to check the movie path apart from the decoder, fill the frames with a gradient in `hle_movie.c`; it should appear on screen.
- **Found on:** [Fire Emblem Engage](../../dm/games/0100A6301214E000/README.md).
