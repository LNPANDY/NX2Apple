# Rewriter

The NSO rewriter (`dm/tools/patch_nso.py`) and its per-build tables (`dm/tools/sdk_patches.py`, a profile's `patches.py`). Each entry: symptom, cause, fix, the games it was found on. The [symptom index](../agents/symptoms.md) lists every symptom.

## Patches across updates

### Function-matched cuts for unregistered builds

- **Symptom:** an updated game loses a needed cut because its NSO build ID changed, although the relevant code still matches a verified version; the rewriter reports `[RED] function patch ... skipped` when that match cannot be established, and the NSP script ends with `[RED] main: no function patch carries the registered builds' fixes to this build` or `[RED] main: function patches not applied` (Super Smash Bros. Ultimate 13.0.1: a static-initialiser abort in `nninitStartup`, GitHub issue #375).
- **Cause:** fixed-address `CUTS` correctly apply only to their registered builds. Copying an old address, or matching a short instruction sequence, does not identify the updated function.
- **Fix:** a profile can opt individual cuts into `MATCH_CUTS` in its `patches.py`. The shared matcher, `dm/tools/nso_match.py`, selects a unique complete unwind function by length and SHA-256 fingerprint. It retains constants, registers and internal branch destinations; normalizes relocation addresses; and checks the normalized bodies of direct callees or their imported symbol names. Original bytes are checked again before a cut is applied. Missing boundaries, unknown callees, changed code and ambiguous matches produce a red diagnostic and no cut. Overlapping rules stop the rewrite. Every accepted cut is recorded in `<module>.cuts.tsv` with `[function match]` in its reason. Rules with the same `name` are one patch's reviewed implementations, for a function a build changed (another size, or the cut at another offset in it). Exactly one of them must match: the log names the implementation that did, and a red line appears only when none matches or more than one does. Before this, each implementation logged a red line on every build it did not match.
  - **A patch of several functions** (`{'name', 'functions': [{'size', 'fingerprints', 'cuts'}, ...]}`) applies whole or not at all: every function must match exactly once, at distinct places, or none of its cuts applies, and the red line names each function that did not match. Use it when the cuts depend on each other, as a constant used in several functions does (a region size, the place it derives, the bound checks of its end): applying some of them leaves code that disagrees about the layout, which fails later and less clearly than the original abort. Before this, rules were independent, so a constant split over several functions could not be enrolled safely.
  - **What an unregistered build kept:** for a module whose build is not registered, the rewriter writes `<module>.match.tsv`: the cuts of the registered builds of that module (the repository profile's `build` rows) and each patch's result. The NSP script reports it with the build: a red line when registered cuts have no function patch at all, or when a patch did not apply; the build itself goes on, since a derived profile is best-effort.
- **SDK-wide patches:** `dm/tools/sdk_patches.py`'s `MATCH_CUTS` (`{'sdk': [rule, ...]}`) apply to every game's `sdk` of a build with no `CUTS` that the selected profile's `build` rows do not name, so the games' registered builds rewrite as before. A patch that finds no reviewed implementation is logged as a plain line and listed by the NSP script without red, since a module may not need it ([The SDK's address-region node area](memory.md#the-sdks-address-region-node-area)). The NSP script's rewrite step keys its reuse on the profile's `build` rows as well. A callee that is one of the SDK's system call wrappers (`svc #n; ret`, assembly with no unwind entry) is identified by its call number.
- **Scope:** the profile selected by `DM_GAME`, keyed by module name. A derived profile still uses that repository profile's rules, even when the repository has no matching rules or patch file; an external-only provisional profile can supply its own. External files cannot replace or enroll a repository profile's matching rules. Other games' rules never participate. A build with registered `CUTS` uses those instead, including an explicitly empty list. SDK patches, observation gates, frame-step stubs and fixed host addresses retain their existing build-ID gates. The rewrite cache includes the selected profile's patch file even for unknown builds, the selected game ID and the matching tool. Repeated search roots or symlinks to the same patch file are loaded and counted once; distinct files claiming the same build still stop the rewrite.
- **Limits:** this is an opt-in code-identity check, not automatic compatibility for every game update. Direct callee bodies are checked one level deep; their callees, indirect-call targets and external data layouts are not proven unchanged. Enroll only a cut whose assumptions remain valid under those changes. Prefer fixing the general host behavior when possible. A replacement must contain no PC-relative instruction; relocated branch replacements need a different mechanism. Failure leaves the game potentially without its workaround, and stays visible in the rewrite log.
- **Found on:** [Super Mario Bros. Wonder](../../dm/games/010015100B514000/README.md#memory), whose former resource-heap allowance was missing on 1.0.1. The shared matcher remains, but Wonder's allowance and matching rule were later removed after the general command-record fix described in its game note. Same-name implementations: [Taiko Risshiden V DX](../../dm/games/0100346017304000/README.md#frame-rate), whose frame-limiter cut has one implementation for 1.1.1 and one for the base game, where the function is shorter. A patch of several functions: [Super Smash Bros. Ultimate](../../dm/games/01006A800016E000/README.md#memory), whose 11 engine-region cuts lie in four functions. SDK-wide: the AddressRegionManager node area and the 1 GB alignment of large regions, from the SDK builds of 18 games ([The SDK's address-region node area](memory.md#the-sdks-address-region-node-area)).

To enroll a cut for any game's own module:

1. Start from a verified fixed cut and its original NSO. Run `python3 dm/tools/nso_match.py <module.nso> <offset> <old hex> <new hex> <reason>` with the tools' Python environment. It emits a rule containing `name`, `size`, `fingerprints` and function-relative `cuts`, and rejects an ambiguous reference. For cuts that must apply together, `python3 dm/tools/nso_match.py <module.nso> --registered <name>` makes one patch of every cut registered for that NSO's build ID, grouped by function. Keep game files and scratch outputs in the game's NSP work folder.
2. Check the function and callees in another known build using `nso_fnmap.py` and disassembly. Check that the cut still has the same effect. `Image.match_patch(rule)` must resolve the reviewed locations. If a reviewed implementation differs, generate its fingerprint separately; combine fingerprints only when function size and relative cuts agree, and otherwise add the implementation as another rule under the same name. Retain exact `CUTS` for known builds.
3. Add the rule under `MATCH_CUTS = {'main': [rule]}` (or the appropriate non-SDK module) in that game's `patches.py`. Record the evidence and remaining runtime validation in the game's note. Do not transplant a workaround into unrelated games.
4. Verify an unregistered build-ID copy through the rewriter, comparing its output with the known fixed cut, and run `test_nso_match.py`, `test_patches.py` and `test_nro_pack.py`. The matching tests use synthetic modules from two profiles to check relocation, rejection and isolation without game files.

## Jump tables

### Offset jump tables through x18 read at rewrite time

- **Symptom:** `jump table <addr>` assertion in `patch_nso.py`, in a Unity / IL2CPP `main`.
- **Cause:** the compiler used `x18` for jump-table shapes other than the ones the rewriter knew. One of them is an offset table: `ldrsw x18, [xB, x18, lsl #2]; add x18, x18, xB; br x18`. (The same `main` also uses `x18` for an indirect call and an `alloca`: see [Indirect calls through x18](#indirect-calls-through-x18) and [Stack pointer writes through x18](#stack-pointer-writes-through-x18).)
- **Fix:** the rewriter reads the offset table's targets at rewrite time (`site_br_tab` in `patch_nso.py`).
- **Found on:** [Fire Emblem Engage](../../dm/games/0100A6301214E000/README.md) `main`: 7 jump tables (beside 1 call and 1 `sp` write).
- **Check:** [Super Mario Bros. Wonder](../../dm/games/010015100B514000/README.md)'s output stays byte-identical.

### Offset jump tables with the bounds check on another register

- **Symptom:** `jump table <addr>` assertion in `patch_nso.py`, in a `subsdk`.
- **Cause:** the offset-table form `ldrsw x18, [xB, xI, lsl #2]; add x18, x18, xB; br x18` with the bounds check on another register: the index in `w0` (`sub w0, w18, #0xd1; cmp w0, #0x31`), a copy (`cmp w21, #7; …; mov w18, w21`) or a masked copy (`and w16, w18, #0x3f; cmp w16, #0xe; …; and x18, x18, #0x3f`). The entry may also be loaded into another register, with only the `add` writing `x18` (Cuphead, Unity 2017.4: `cmp w17, #7; ldrsw x17, [x15, x17, lsl #2]; add x18, x17, x15`).
- **Fix:** `jump_offsets` follows `mov` copies back to the `cmp` and accepts a check on the same `and` of the same, unchanged source.
- **Found on:** [The Legend of Zelda: Link's Awakening](../../dm/games/01006BB00C6F0000/README.md) (GLSLC and movie modules); [Cuphead](../../dm/games/0100A5C00D162000/README.md) (the entry loaded into another register).
- **Check:** [Fire Emblem Engage](../../dm/games/0100A6301214E000/README.md)'s output stayed byte-identical.

### Index copied before the bounds check

- **Symptom:** `jump table <addr>` assertion where the index is a copy made before the check (`mov w0,w18`, then 41 instructions holding two other jump tables on `x0`, then `cmp w18,#4; b.hi; ldrsw x18,[x11,x0,lsl #2]; add x18,x18,x11; br x18`).
- **Cause:** every other form follows copies made after the bounds check.
- **Fix:** `check_before_copy` accepts the `cmp` and `b.hi` right before the load when a `mov wI, wS` is the last writer of both registers; capstone lists a `cmp`'s first operand as written, which the search skips. The search follows the function boundary rather than an arbitrary instruction count, stopping at undecodable gaps and calls that can clobber either register. It runs only when every other form has failed.
- **Found on:** [DRAGON QUEST XI S: Echoes of an Elusive Age – Definitive Edition](../../dm/games/01006C300E9F0000/README.md) `main+0x2dd8cd0`; [Mario + Rabbids Kingdom Battle](../../dm/games/010067300059A000/README.md) `subsdk0+0x7340b8`, whose copy is 71 instructions before the load, across two switches preserving both registers (beyond the former 64-instruction limit).
- **Note:** before fixing one site, a census of all of them saves a run per site: a copy of `patch_nso.py` whose assert prints and continues found this one alone among the 25,508 `x18` sites. That `main` has no unwind entries for its first 70 MB, so the rewriter disassembles them as one function and takes 6 minutes (see [Long functions analysed in pieces](#long-functions-analysed-in-pieces)).

### 64-bit bounds check of the index

- **Symptom:** `jump table <addr>` assertion in `patch_nso.py` on an offset table whose index is checked with a 64-bit compare (`cmp x22, #0x10; …; b.hi; adrp x18 + add x18; mov x0, x18; ldrsw x18, [x0, x22, lsl #2]; add x18, x18, x0; br x18`).
- **Cause:** `jump_offsets` took only a 32-bit `cmp wI, #N` as the bounds check. A 64-bit compare bounds the index as well (the load uses the whole `xI`); here the table base also reaches the load through a copy, so only the far-base pass reads it.
- **Fix:** in its last pass (`far_base`), `jump_offsets` accepts `cmp xI, #N` on the index too. The earlier passes are unchanged, so modules that rewrote before come out the same.
- **Found on:** [OCTOPATH TRAVELER](../../dm/games/010057D006492000/README.md) `main+0x1676f58` (1.0.5), the only such site in that `main`.

### Index masked in the block that branches to the dispatch

- **Symptom:** `jump table <addr>` assertion in a Unity / IL2CPP `main` whose dispatch checks a fresh mask of another register than the one it indexes with.
- **Cause:** the dispatch block masks the source again for its bounds check, while the index register was masked from the same source in the block that branches to it: `and x6,x17,#0x7ff; ubfx w18,w17,#0xb,#2; cbz w18,L`, then `L: and w18,w17,#0x7ff; cmp w18,#3; b.hi; ldrsw x18,[x27,x6,lsl #2]; add x18,x18,x27; br x18`, with the base `x27` from an `adrp` + `add` about 1,500 instructions back. A sibling builds its base inside the block and moves registers before the `br` (`adrp x24` + `add`, a `mov`, the load and the add, then 10 register moves). No copy links the two registers, so `jump_offsets` and `check_before_copy` find no check.
- **Fix:** `jump_masked_pred` accepts the site when the block (at most 32 instructions) is `and wC,wS,#M; cmp wC,#N; b.hi` followed by straight-line code holding the load and the add; it is entered by branches alone (the instruction before it is `b` / `br` / `ret`, no branch lands inside it after its `and`, no jump table already resolved in the function reaches it); every branch into it follows, on a straight-line path, `and xI,xS,#M` with the check's source and mask; and the index, the base and `x18` are unchanged where the form needs them. The base is found as `far_base` finds it and every target must be an instruction of the function. It runs only after every other form has failed.
- **Guards (resolved):** direct calls and resolved jump tables must not enter between a predecessor's mask and its branch, since that bypasses the index assignment; direct calls into the dispatch are refused too. Undecodable words break either straight-line run, and table targets must be decoded instruction addresses, not just aligned addresses inside the function. The base uses `copied_base`, which follows `adrp` + `add` and register copies while rejecting 32-bit writes that destroy a 64-bit base.
- **Found on:** FINAL FANTASY CRYSTAL CHRONICLES Remastered Edition 1.0.0 (Unity 2018.4.2f1, SDK 8.2.1) `main+0x2d103cc` and `+0x2d10590`, in one function; the same form in its update 1.0.3.
- **Check:** it runs only where the rewriter asserted before, so modules that rewrote before come out the same; other games' modules were not on hand to compare.

### Zero-guarded complemented jump-table index

- **Symptom:** `jump table 6eea88` or `jump table 6eeac0` assertion in `patch_nso.py` on Return of the Obra Dinn 1.0.1.
- **Cause:** Unity's IL2CPP output uses `tst w15,#7; b.eq exit; mvn w15,w15; and x15,x15,#7; ldrsw x15,[xB,x15,lsl #2]; add x18,x15,xB; br x18`. The zero test excludes one masked value before complementing it: the reachable indices are 0–6, so the table holds seven entries. Treating the `tst` immediate as a `cmp` bound reads an eighth word from the next table, introducing a target the guest cannot reach through this dispatch.
- **Fix:** the last fallback, `jump_masked_not`, accepts this contiguous guard / complement / low-bit-mask form, reads exactly the mask's number of entries, follows the table base through `copied_base`, and requires decoded instruction targets in the function. It rejects intervening register writes or control flow, direct branches / calls and already resolved tables entering after the guard, and its own table targets bypassing the guard. Earlier recognizers are unchanged.
- **Found on:** [Return of the Obra Dinn](../../dm/games/010032E00E6E2000/README.md) 1.0.1 (`main` build `9e93a6566aaa27418dd2435d8d5dffe5`), two dispatches in the function at `main+0x6ee8c0`.
- **Check:** `dm/tools/tests/test_jump_copies.py` exercises the exact seven-entry extent with an invalid next word, mismatched guards / masks / sources, register clobbers, incoming edges, undecodable words and invalid targets. The extracted update's two sites resolve to seven targets each; this is static verification, with gameplay validation recorded in the game note.

### Offset table base set far back in the function

- **Symptom:** `jump table <addr>` assertion on an offset table whose base was set far back (`cmp w18,#5; b.hi; ldrsw x18,[x24,x18,lsl #2]; add x18,x18,x24; br x18`).
- **Cause:** the function's first block loads six table bases with `adrp` + `add` into registers that its loop keeps (`x24` 441 instructions before this load), and a later block one more (`x3`, 549 before the load at `+0x6db70c`); `jump_offsets` follows the base's writer chain 256 instructions back. The function-wide search that `jump_adr_offsets` uses for a hoisted base (the one `adrp` + `add` pair that fits) found two for `x3`, the other a local table of a `br x17` further on.
- **Fix:** where nothing writes the base in those 256, its last attempt (`far_base`) follows the chain to the function's start (`table_base` `far`), through no call when the base is caller-saved, and accepts the table only when every target is an instruction of the function. It runs only where every other form has failed.
- **Found on:** ASTRAL CHAIN 1.0.1 (SDK 6) `main+0x6db4a0`: three of that `main`'s five `br x18` sites need it.
- **Check:** modules that rewrote before come out the same (Tears of the Kingdom, Age of Calamity, Cuphead, DARK SOULS: REMASTERED, Luigi's Mansion 3 and Metroid Dread `main`s: byte-identical).

### Far table base passed through other registers

- **Symptom:** `jump table <addr>` assertion on an offset table whose base was set far back and moved through other registers (`ldrb w18,[x14]; sub w18,w18,#1; cmp w18,#6; b.hi; ldrsw x18,[x7,x18,lsl #2]; add x18,x18,x7; br x18`).
- **Cause:** `x7` is built by `adrp` + `add` 688 instructions before, then parked in `x30` around a loop (`mov x30,x7` … `mov x7,x30`), so the far chain meets a `mov` and stops; the function-wide search finds a second `adrp x7` + `add` pair (another table further on) whose seven targets also lie in the function.
- **Fix:** the last attempt now follows register copies back to the `adrp` + `add` (`copied_base`, through no call while the register followed is caller-saved; the same target check). It runs only where the rewriter asserted before.
- **Found on:** [Super Smash Bros. Ultimate](../../dm/games/01006A800016E000/README.md) 13.0.5 (SDK 8.2.1) `main+0x2b74458`: that `main`'s only unhandled site.
- **Check:** [Mario Kart 8 Deluxe](../../dm/games/0100152000022000/README.md)'s three modules and Smash's `sdk` and movie module come out byte-identical.

### Offset table base initialized after the dispatch

- **Symptom:** `jump table ae95f8` assertion in `patch_nso.py` while rewriting Blasphemous 1.0.8.
- **Cause:** the function enters an initialization block later in address order, then branches backward to `cmp w18,#9; b.hi; ldrsw x18,[x17,x18,lsl #2]; add x18,x18,x17; br x18`. The `adrp x17` / `add x17,x17,#lo` pair is after the dispatch, so the backward writer searches find no base.
- **Fix:** a final `jump_offsets` fallback uses `forward_table_base` only when that adjacent full-width pair is the base register's sole initialization in the function. It rejects other writes, calls that can clobber the base, known branches or table targets entering the add without its adrp, out-of-image tables and targets that are not decoded instructions of the function. Earlier recognizers are unchanged.
- **Found on:** [Blasphemous](../../dm/games/0100698009C6E000/README.md), `main+0xae95f8`, ten table-relative targets.
- **Check:** `dm/tools/tests/test_jump_copies.py` covers the exact table extent, base clobbers, incoming edges, undecodable targets and out-of-image tables. The extracted function resolves to the ten targets read directly from its table.

### Offset tables relative to an adr

- **Symptom:** `jump table <addr>` assertion, entries relative to an `adr`.
- **Cause:** `cmp wI, #N; b.hi; …; adr x18, #L; ldrsw xE, [xT, xI, lsl #2]; add x18, x18, xE; br x18`: target = L + entry, not table + entry.
- **Fix:** `jump_adr_offsets`, tried only where the table-relative form is not found. The bounds check can be on a register copied into the index (`mov w16, w15`), and the table base can be built far from the dispatch; then every `adrp` + `add` pair in the function that builds that register is tried, and a table is accepted only if exactly one makes every target an instruction of the function.
- **Found on:** [The Legend of Zelda: Tears of the Kingdom](../../dm/games/0100F2C0115B6000/README.md) `main+0x393bb0` and others.

### Byte tables indexed by x30 (capstone register names)

- **Symptom:** `jump table <addr>` assertion on a byte table indexed by x30 (`adr x18, #L; ldrb w30, [x14, x12]; add x18, x18, x30, lsl #2; br x18`).
- **Cause:** capstone names x30 `lr` (and x29 `fp`), so the index register looked like no register and the `ldrb` never matched.
- **Fix:** the byte / halfword table check maps those names back to 30 / 29.
- **Found on:** [Hyrule Warriors: Age of Calamity](../../dm/games/01002B00111A2000/README.md) `main+0x138216c`.

### Byte tables whose add is far from the br

- **Symptom:** `jump table <addr>` assertion on a byte table whose `add` is far from the `br` (`adr x18,#L; ldrb w0,[x17,x15]; add x18,x18,x0,lsl #2`, then 17 register moves before `br x18`).
- **Cause:** the byte / halfword search looked 16 instructions back.
- **Fix:** `jump_bytes_far` looks 32 back, requires that nothing writes x18 between the `add` and the `br`, and runs only when every other form has failed, so sites that rewrote before come out the same.
- **Found on:** [Octopath Traveler 0](../../dm/games/01005270232F2000/README.md) `main+0x37f9bc8`: one of the 12 `br x18` sites in this `main`.
- **Note:** a census of all the `br x18` sites first (each shape within 16 / 32 / 48 instructions) saves a 12-minute rewrite per site.

### Indirect calls through x18

- **Symptom:** `jump table <addr>` assertion in `patch_nso.py`, in a Unity / IL2CPP `main`, at a `blr x18`.
- **Cause:** the compiler made an indirect call through `x18` (`blr x18`).
- **Fix:** the rewriter calls through `x16` with the original return address, so C++ unwinding still finds its frames (`site_blr`).
- **Found on:** [Fire Emblem Engage](../../dm/games/0100A6301214E000/README.md) `main`: 1 call (beside 7 jump tables and 1 `sp` write).
- **Check:** [Super Mario Bros. Wonder](../../dm/games/010015100B514000/README.md)'s output stays byte-identical.

### Indirect tail calls through x18 in IL2CPP thunks

- **Symptom:** `jump table <addr>` assertion on a `br x18` with no table in front of it.
- **Cause:** not a jump table but an indirect tail call: an IL2CPP thunk loads the method pointer with `ldr x18, [x0, #0x18]`, moves its stack arguments with every other scratch register (`ldr x16, [sp]`, `ldp x17, x15, [sp, #8]`, …) and ends with `br x18`.
- **Fix:** when neither table form is found, the last write of `x18` is a plain load and the `br` ends the function, it becomes `x16 = guest x18; br x16` (`tail_call` / `site_br_call`; at a call `x16` / `x17` are free, as for `blr x18`). It is tried only where the rewriter used to stop.
- **Found on:** [Ace Attorney Investigations Collection](../../dm/games/010005501E68C000/README.md) (Unity 2022.3 IL2CPP): `main+0x1d271bc` and `+0x204ebec`.
- **Check:** every module the rewriter accepted before comes out byte-identical.

### Loaded method-pointer tail call before an error block

- **Symptom:** `jump table 53e9c` while rewriting Warm Snow 2.1.4's Unity IL2CPP `main`.
- **Cause:** a framed thunk loads a method pointer into `x18`, moves arguments, restores its frame and executes `br x18`. A separate null-error call follows it. The terminal-tail recognizer requires the jump to end the function.
- **Fix:** keep the existing terminal-tail rule unchanged. Only for nonterminal jumps, recognize a contiguous decoded thunk with the standard 16-byte FP/LR frame, a single forward `cbz` to the trailing error call, plain argument moves/transfers, one pointer load into `x18`, and the matching frame restore. Reject additional control flow, stack-pointer/frame-register/link-register writes, pointer clobbers and undecoded gaps. Stores must use a fixed offset of at least 16 from the unchanged `sp` or frame pointer, so they write caller stack arguments above the saved FP/LR. Checking register writes alone does not protect that saved pair; stores through other bases or dynamic offsets may alias it and are rejected. An unframed loaded-pointer jump followed by other blocks remains unsupported: ending a basic block alone does not prove a tail call.
- **Found on:** Warm Snow 2.1.4, `main` build `306fc054203275803dcbceba7fb7c392`, at `+0x53e9c`. Its game profile is deliberately outside this change.
- **Check:** `dm/tools/tests/test_tail_call.py` covers acceptance and rejection with synthetic AArch64 instructions, including saved-frame stores, safe caller argument stores, unproven store addresses, 32-bit and 64-bit SP/FP/LR clobbers (including `wsp`), the unframed guarded block and the previously accepted terminal tail with an intervening conditional branch. Actual game rewrite/build results and remaining coverage are recorded in the PR; no game assets are required by the tests.

## Exclusive windows

### Exit stub order in exclusive windows

- **Symptom:** job system hangs; a queue claims thousands of tasks but every slot is empty.
- **Cause:** in an `ldxr … cmp … b.ne out … stxr … cbnz` window, the rewritten stub emitted its exits in the wrong order, so successful stores took the failure path.
- **Fix:** emit the fall-through exit first (`patch_nso.py` `site_window`).
- **Found on:** [Super Mario Bros. Wonder](../../dm/games/010015100B514000/README.md): 82 such windows. D2R had no such windows.

### Out-of-line retry blocks of atomic updates

- **Symptom:** `branch into window <addr>` assertion.
- **Cause:** the compiler moved an atomic update's retry path out of line: the failed `stxr` branches to a block `ldxr; cmp; b.eq <the stxr>` that re-enters the window at its store. That block cannot jump into the window's patch copy (the `x18` stand-in would be loaded between its exclusive load and the store).
- **Fix:** the retry block gets a copy of its own: the retry block and the window's tail from the store on, under one prologue (`retry_block` / `site_retry_window`).
- **Found on:** [The Legend of Zelda: Tears of the Kingdom](../../dm/games/0100F2C0115B6000/README.md) 1.4.3 `main`, 8 sites.

### A window never spans a second exclusive load

- **Symptom:** branches to an `ldxr … stxr` loop's head landed mid-window.
- **Cause:** before this rule, a retry block's `ldxr` opened a window that ran on into the next, unrelated `ldxr … stxr` loop (`main+0x5a4674`).
- **Fix:** a window never spans a second exclusive load.
- **Found on:** [The Legend of Zelda: Tears of the Kingdom](../../dm/games/0100F2C0115B6000/README.md) 1.4.3 `main` (with [Out-of-line retry blocks of atomic updates](#out-of-line-retry-blocks-of-atomic-updates)).

### adrp inside an exclusive window

- **Symptom:** `AssertionError: 0x…` in `site_window` on an `adrp` inside an exclusive window (`ldaxr x9,[x9]; cmp x9,x25; b.ne out; adrp x10 + add x10` (the same address again, for the store); `mov x18,x26; stlxr w9,x8,[x10]`, then loads and `cbnz w9` back).
- **Cause:** a window that uses x18 is copied into the patch area, and an `adrp` there would build another page.
- **Fix:** it is re-encoded for the copy's address with the same target page (x18 as its stand-in), in both window copiers (`window_adrp`).
- **Found on:** [Pikmin 4](../../dm/games/0100B7C00933A000/README.md) 1.1.1 (Unreal Engine 4.26.2) `main+0x43da14c`.
- **Check:** only windows that stopped the rewrite change, so every other module rewrites byte for byte as before.

## Patch area reach

### Halfword jump table landing pads sized to the largest entry

- **Symptom:** `B()` assertion at a spin wait: a branch into the patch area beyond the ±128 MB a `b` reaches.
- **Cause:** each halfword jump table (`ldrh wE, [xT, xI, lsl #1]; …; adr x18, #L; add x18, x18, xE, lsl #2; br x18`) got a landing pad for every one of the 65,536 values an entry can hold (768 KB a table), whatever the switch's size: that `main` has 51 of them, 40 MB, and the spin-wait stubs placed after them were out of reach.
- **Fix:** `half_count` reads the table as `jump_adr_offsets` does (the index's bounds check, following register copies, then the base from `adrp` + `add`, or the one candidate in the function whose every target is an instruction of it) and pads only up to its largest entry; a table it cannot read keeps all 65,536 (7 of the 51). The patch area went from 42 MB to 7.9 MB.
- **Found on:** [Animal Crossing: New Horizons](../../dm/games/01006F8002326000/README.md) 3.0.3 `main`, 63 MB of text.
- **Check:** in the other titles' modules only such tables changed: one in the `sdk` of several SDK 11–20 builds (936 to 1,320 pads), 1 to 6 in some `main`s (Tears of the Kingdom, Breath of the Wild, Silksong, Monster Hunter Rise, Absolum, STEINS;GATE RE:BOOT) and one in some movie and middleware `subsdk`s.

### Patch area before the module base for a large bss

- **Symptom:** `B()` range assertion in `patch_nso.py` (`site_plain`), only for one module.
- **Cause:** its bss is 1.8 GB, the engine's static heap, so a patch area appended after the image starts 1.9 GB from the code and no `B` (±128 MB) reaches it.
- **Fix:** when an appended patch area would start beyond 112 MB, the rewriter puts it 32 MB *before* the module base (negative `PATCH_OFF`). `patched.bin` then holds only text + ro + data (`FILE_IMAGE_LEN`) followed by the patch bytes, and the loader maps the bss and the key page as zero pages (`IMAGE_SIZE`). The Mac loader, the iOS embedding (`gen_embed.py`: no bss in the executable) and `QueryMemory` handle both layouts.
- **Found on:** [Metroid Dread](../../dm/games/010093801237C000/README.md) `main`.
- **Check:** Mario's and Engage's output is byte-identical to before.

### Frame-step state with a front patch area

- **Symptom:** `frame step state page` assertion when a `FRAME_STEP` profile is added to a module with a large BSS.
- **Cause:** frame-state allocation required a patch area after the image, although the stubs can address the state page through ADRP with either layout.
- **Fix:** for a front patch area, reserve a zero-filled 16 KB state page immediately after the key page by extending `IMAGE_SIZE`. The existing Mac and iOS loaders map it with the BSS; no padding is added to the game binary. Ordinary modules retain their existing layout.
- **Found on:** [ASTRAL CHAIN](../../dm/games/01007300020FA000/README.md#frame-rate).

### Patch area right before the base for a long text

- **Symptom:** `B()` range assertion, then `patch area of … bytes does not fit in the … before the base`.
- **Cause:** with the patch area 32 MB before the base, sites near the end of the text are more than 128 MB away.
- **Fix:** when the text ends within 32 MB of the reach (`BIG_TEXT`), the patch area goes right before the base: the stubs follow the sites in address order, so each site's stub is about as far from it as the text is long. The first pass tries the gap that keeps every site in reach (2.6 MB here); when the patch area is larger (3.6 MB, 34,322 sites), the rewriter runs itself again with exactly that size (`DM_PATCH_FRONT`, set only by the rerun) and `B()` checks every branch.
- **Found on:** [Monster Hunter Rise](../../dm/games/0100B04011742000/README.md) `main`: 125.3 MB of text.

## Cuts and observation gates

### Observation gates where x9–x17 are dead

- **Symptom:** `observation gate neither at a function entry nor after a bl`; `observation gate neither at a function entry, after a bl nor before a call` on an epilogue.
- **Cause:** the host may change x9–x17 in a gate, so a gate sat only where they carry nothing (a function entry, after a `bl`).
- **Fix:** a site is also accepted when the straight-line code from it to the next `bl` reads none of x9–x17 before writing it (`scratch_dead`); it is tried only after the other two rules fail. `ret` ends the code ahead as a `bl` does: under AAPCS64 none of x9–x17 carries a result, so the straight-line scan (`scratch_dead`) accepts a `ret` too.
- **Found on:** [DRAGON QUEST VII Reimagined](../../dm/games/0100A9D01C446000/README.md): the gate on `mov x0, x19` at `main+0x32758e4`, after a cut `bl` and an `adrp`. [Pikmin 4](../../dm/games/0100B7C00933A000/README.md): the gate on `ldp x29, x30, [sp, #0x10]` right after the cut allocator constructor call, `main+0x353f78c`; the rule checks the image after the cuts, so the `bl` before it is a `nop` by then (the `ret` case).
- **Note:** the gate table takes the original instruction as a word value (`aa1303e0`), the cut table as bytes (`e00313aa`).

## Functions, unwind entries and data in text

### Code before the first unwind entry is one function

- **Symptom:** `jump table <addr>` assertion on an ordinary byte table near the start of the text (`adr x18; ldrb w0,[x17,x16]; add x18,x18,x0,lsl #2; br x18`).
- **Cause:** the module has no unwind entry before `main+0x6a75d4`, and `func_of` made every site before the first FDE a function of one instruction, so no form saw the `adr` in front of the `br`.
- **Fix:** the text before the first FDE is now one function, from the end of the data block before it (or the text's start), as a gap between two FDEs already was (`func_of`).
- **Found on:** [FINAL FANTASY RESONANCE](../../dm/games/0100606026F12000/README.md) 1.0.1 `main` (Unreal Engine 5.6.1): `main+0x219234`.
- **Check:** of the 120 modules of 33 games on hand, only DRAGON QUEST VII Reimagined's `main` has other `x18` sites there (110 before `+0xb310`, none in a window or a `br x18`), and its rewrite is byte-identical.

### Long functions analysed in pieces

- **Symptom:** the rewrite never finishes, the Mac swaps, the rewriter's footprint reaches 100 GB.
- **Cause:** a stretch without FDEs is one function to `func_of`, and its detailed disassembly costs about 880 bytes an instruction once built (2.6 KB while capstone builds it): 21.6 million instructions. In FINAL FANTASY RESONANCE's `main`, 82 MB at `main+0x6c4f88`–`+0x59220c0` and the 6.65 MB before the first FDE have no unwind entries. Octopath Traveler 0 (71 MB), DRAGON QUEST XI S (68 MB) and DRAGON QUEST VII Reimagined (two of 23 MB) have such stretches too; they got through on a quieter Mac with the compressor and swap.
- **Fix:** a function longer than 256 KB is now analysed in pieces (`pieces` in `patch_nso.py`), cut only right after a `ret` / `br` / `b` where no conditional branch and no `b` within 64 KB crosses, so a window, a jump table's bounds check and table base, and a retry block stay in one piece. After all pieces, every farther `b` / `bl` and every jump table target is checked against the windows and retry blocks of all pieces. Counting `b` up to 1 MB left only 21,385 cut points in the 82 MB (tail calls between neighbours) and pieces of up to 6.5 MB; with 64 KB there are 185,228, and no piece is over 256 KB (the two stretches: 28 and 344 pieces). The rewrite then takes 13 minutes at about 2.7 GB resident on a loaded Mac.
- **Found on:** [FINAL FANTASY RESONANCE](../../dm/games/0100606026F12000/README.md) 1.0.1 `main`; also [Octopath Traveler 0](../../dm/games/01005270232F2000/README.md), [DRAGON QUEST XI S: Echoes of an Elusive Age – Definitive Edition](../../dm/games/01006C300E9F0000/README.md), [DRAGON QUEST VII Reimagined](../../dm/games/0100A9D01C446000/README.md).
- **Check:** DRAGON QUEST VII Reimagined's `main` came out byte-identical to its rewrite by the previous `patch_nso.py`. FINAL FANTASY RESONANCE's came out the same as with `b` counted up to 1 MB (3 and 136 pieces), and DRAGON QUEST XI S's (292 pieces) and Octopath Traveler 0's the same as with 1 MB pieces and `b` within 256 KB (75 pieces for DQ XI S), so the analysis does not depend on where the cuts fall.

### Disassembly goes on after undecodable words

- **Symptom:** `KeyError` at `site_br` for a `br x18` that is an ordinary byte jump table.
- **Cause:** capstone stops at the first word it cannot decode, and the function held a trap word (`0xe7ffdefe`, `main+0x6b34540`) before the jump table, so the table was never analysed.
- **Fix:** function disassembly now goes on after undecodable words (`disasm_fn`).
- **Found on:** [Monster Hunter Rise](../../dm/games/0100B04011742000/README.md) `main+0x6b346d0`.

### Data blocks at the start of the text

- **Symptom:** `RuntimeError: 788 ldr x18, #0xd1eb0` in `patch_nso.py`, or any rewrite site in data.
- **Cause:** the text segment starts with 1.7 MB of data (`main+0x0`–`+0x1b5000`, high-entropy, no FDE covers it, and no `adrp` or relocation points into it): 62% of its words do not decode, and 6,858 of the rest read as instructions that use `x18`, plus three "`svc`" words with numbers such as `#0x91e7`. The linear sweep rewrote them all.
- **Fix:** `dm/tools/nso_code.py` finds such data blocks: a stretch of at least 4 KB between the `.eh_frame` FDE ranges in which more than a quarter of the words do not decode. The sweep skips them (`DATA_BLOCKS`, logged as `data blocks left alone`), and so does `insn_census.py`, whose counts then match the rewriter's again (11,744 `x18` sites in Absolum's `main`). Code without unwind information is still swept: it decodes (Absolum's zlib at `main+0x75261c`, libunwind's register restore at `main+0x28dbd4`).
- **Found on:** [Absolum](../../dm/games/0100A83022A22000/README.md) `main` (.NET NativeAOT).
- **Check:** no module of the 19 other games on hand has a data block, and their rewrites are byte-identical.

### NRO metadata inside the text segment

- **Symptom:** `RuntimeError: 44 ldr x18, #0xfffffffffff40370` while rewriting an NRO.
- **Cause:** an NRO's text segment includes its metadata header. The arbitrary build ID at `+0x40` can decode as instructions; `magic_0898_2015.nro` contains a literal load into `x18` at `+0x44`. The ordinary 4 KB data-gap heuristic cannot exclude this 120-byte header.
- **Fix:** `nso_code.data_blocks` explicitly excludes `+8..+0x80` when the image has the `NRO0` header. The initial entry branch and MOD0 pointer remain intact, and scanning resumes at the first possible function. NSO scanning is unchanged.
- **Found on:** [FINAL FANTASY X/X-2 HD Remaster](../../dm/games/0100BC300CB48000/README.md), 1,432 registered NROs.
- **Check:** `test_nro_header.py` runs the real rewriter on synthetic NROs whose build IDs decode as an `x18` load or `br x18`, checks the header byte-for-byte, and checks that an actual `x18` instruction immediately after it is rewritten. Code before the first unwind entry is covered too: per-function analysis must not reenter the header even when the linear scans exclude it.

## Stack and system registers

### Stack pointer writes through x18

- **Symptom:** `jump table <addr>` assertion in `patch_nso.py`, in a Unity / IL2CPP `main`, at an `alloca` (`mov sp, x18`).
- **Cause:** the compiler wrote `sp` from `x18` for an `alloca` (`mov sp, x18`).
- **Fix:** the rewriter restores its scratch registers relative to the old `sp` (`site_sp`).
- **Found on:** [Fire Emblem Engage](../../dm/games/0100A6301214E000/README.md) `main`: 1 `sp` write (beside 7 jump tables and 1 call).
- **Check:** [Super Mario Bros. Wonder](../../dm/games/010015100B514000/README.md)'s output stays byte-identical.

### Stack arguments reserved with sub sp, sp, xN

- **Symptom:** `CRASH sig=10 addr=0` on an `stp` relative to `sp`, with `sp` not a multiple of 16 (`main+0x2bbba4`, `sub sp, sp, #0xc0` then `stp d15, d14, [sp, #0x60]` with sp ending in `…9dc`).
- **Cause:** Horizon leaves stack alignment checking off for user code; Apple's kernel faults on an sp-based access while sp is misaligned. The game's script engine calls native functions through six hand-written bridges (`main+0x17c140` and five more beside it): each reserves the callee's stack arguments with `sub sp, sp, x19`, x19 being their sizes added up (4 for one int, `[x0 + 0x238]`), and gives them back with `add sp, sp, x19` after the call, so the callee ran with sp 4 bytes off.
- **Fix:** the rewriter now sends every `sub sp, sp, xN` (extended-register form, no shift) through a stub that rounds xN up to 16 first (`site_sp_align`); the `add` then gives back the same amount. Compiled code keeps such sizes 16-aligned, so there it changes nothing. `insn_census.py` counts the sites as `sub sp, sp, xN`.
- **Found on:** [Paper Mario: The Thousand-Year Door](../../dm/games/0100ECD018EBE000/README.md) `main` (its AngelScript call bridges).
- **Check:** of the 22 games' modules on hand only this `main` has the form (6 sites), so every other rewrite is byte-identical.

### System register reads that macOS traps

- **Symptom:** SIGILL / trap on a system register read.
- **Cause:** a newer SDK reads a register macOS traps (`CTR_EL0` in SDK 16's `FlushDataCache`).
- **Fix:** rewrite to a constant (`patch_nso.py`, the `ctr` site kind).

## Relocations and module layout

### Packed relative relocations (DT_RELR)

- **Symptom:** every pointer in `.data` / the GOT is a module offset, crashes everywhere.
- **Cause:** SDK 20 modules pack their relative relocations as `DT_RELR` (tag 36, size tag 35): `main` has 223,994 of them and its `DT_RELA` only symbol relocations. Each 8-byte entry is either an even offset (relocate it, move to the next slot) or an odd bitmap whose bits 1–63 stand for the following 63 slots; the addend is the slot's own value.
- **Fix:** `relr_apply` in `loader.c`; `DM_LOADHASH` and `nvn_slots_got.py` read it too. The loader's log line counts them as `relr=`.
- **Found on:** [The Legend of Zelda: Breath of the Wild](../../dm/games/01007EF00011E000/README.md) 1.9.0 (SDK 20).

### Regression rewrites register copied profiles twice

- **Symptom:** `regress.py check` stops before gameplay with `CUTS of build ... in both ...`, naming a revision profile and its copied harness profile.
- **Cause:** shader builds use a writable profile copy for generated tables. Passing that copy to the rewriter exposes its `patches.py` alongside the revision's original, registering every cut twice.
- **Fix:** registered games rewrite with the revision's original profile; provisional games retain their external profile path. Shader builds continue using their writable copies. The harness regression covers both selections.
- **Found on:** [NieR:Automata geometry review](../../dm/games/010056B015FE8000/README.md#geometry-optimization-review), when comparing rewrites after reconciling PRs #336 and #416.

## Checking a rewriter change

Rewrite every extracted module of every title with the old and the new `patch_nso.py` and compare all outputs; only `build_src.sha256` (the rewriter's own hash) may differ for titles the change is not meant for.
