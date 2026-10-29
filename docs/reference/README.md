# Subsystem references

How the host meets each part of a Switch game, and every failure met so far, one entry per mechanism: symptom, cause, fix (file and function), the games it was found on (linked to their notes in `dm/games/<id>/README.md`). Start from the [symptom index](../agents/symptoms.md) when you have a log line or a visible result; the workflows that lead here are in [docs/agents](../agents/README.md).

| File | Covers |
|---|---|
| [packing.md](packing.md) | NSP script, compressed inputs and build artifacts |
| [rewriter.md](rewriter.md) | The NSO rewriter `patch_nso.py`: jump tables, exclusive windows, patch area reach, cuts and observation gates (and cheats carried across builds with the same matcher), functions without unwind entries, stack and system registers, relocations |
| [memory.md](memory.md) | Guest layout, heap and application pool, virtual address memory and the alias region (the SDK's node area), engine allocators, mapping SVCs, running out of memory |
| [threads.md](threads.md) | Thread creation and cores, address arbitration, yields and spin waits, events |
| [services.md](services.md) | SDK calls and system services: sm connections, names that changed between SDKs, file system and saves, add-on content, input, keyboard and applets, display and operation mode, accounts and network, settings and fonts, C library and time, modules |
| [movies.md](movies.md) | The SDK's movie library: decoder lifecycle, output slots, native-texture output, demuxers and codecs, game movie players |
| [audio.md](audio.md) | The audio renderer and its command lists by SDK, AudioOut and devices, codecs, timing |
| [frame-rate.md](frame-rate.md) | The host's frame step, engine frame limiters, present intervals and display rates, CPU cost |
| [nvn-objects.md](nvn-objects.md) | NVN object sizes, memory pools, command memory, queues and syncs, CPU-written textures, NVN entry points |
| [rendering.md](rendering.md) | The replay on Metal: textures, passes and clears, blend / depth / stencil, vertex input, uniforms and ordering, conditional rendering; the Vulkan and OpenGL layers |
| [shaders.md](shaders.md) | Shader containers by engine, control sections and code, translation, bindings and handles, shaders compiled at run time, pipelines and caches |
| [cheats.md](cheats.md) | How cheats work on a Switch with Atmosphère (dmnt, the file, the VM, its behaviour on failure) and where this host differs |
| [game-state.md](game-state.md) | Saves, scripted state, and game behaviour that looks like a host bug but is not |

A new general finding goes into the file and section it belongs to, in the same form, with a line in the symptom index; a fact about one game goes into that game's note.
