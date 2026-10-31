# Cheats on a Switch

How cheat codes work on a Switch running Atmosphère, read from Atmosphère's own source and documentation (tag 1.12.1, commit `6b0c077b`; [Sources](#sources)), so that the host's engine (`dm/host/hle_cheats.c`, described in [docs/development.md, Cheats](../development.md#cheats)) can be held to it. In the quotes below, `vm.cpp` is `stratosphere/dmnt/source/cheat/impl/dmnt_cheat_vm.cpp` and `api.cpp` is `dmnt_cheat_api.cpp` beside it. `main+X` and `heap+X` mean memory type 0 or 1 with offset X.

## How cheats work on a Switch with Atmosphère

### The pieces

- **dmnt** (Atmosphère's debug monitor system module) holds the cheat manager. It hooks the creation of every application process (`pm::dmnt::HookToCreateApplicationProcess`), so it looks at the game before its first instruction runs, and attaches as a kernel debugger (`svc::DebugActiveProcess`) when the game has a cheat file. It then starts the process.
- **The cheat file**, text on the SD card, parsed once at attach into up to 0x80 entries.
- **The VM thread** runs every enabled cheat as one program, then writes the frozen addresses, then sleeps 1/12 s, forever.
- **Overlays and homebrew** (EdiZon SE, Breeze, Tesla overlays) talk to dmnt through the `dmnt:cht` service: list, toggle, add and remove cheats, read and write the game's memory, read and write static registers, freeze addresses. dmnt itself has no on-screen menu.

### When dmnt attaches

At each application launch (`AttachToApplicationProcess(true)`, `api.cpp`):

1. The loader's override status must say cheats are enabled. The key is `cheat_enable_key`, default `!L`: cheats load **unless L is held** at launch (`g_default_cheat_enable_key = { HidNpadButton_L, override_by_default = true }`; `IsOverrideMatch` is `override_by_default ^ (keys_held & key) != 0`). It is set globally in `/atmosphere/config/override_config.ini` (`[default_config]`) and per title in `/atmosphere/contents/<program id>/config.ini` (`[override_config]`). Never for the Homebrew Loader.
2. The process must have two modules (rtld and main); main is the second.
3. `/atmosphere/contents/<program id>/cheats/<build id>.txt` must open and parse, where `<program id>` is 16 hex digits and `<build id>` is the first 8 bytes of main's build ID as 16 hex digits (both printed lowercase, `%016lx` and `%02x`). The file must be under 64 KiB (`file_size >= sizeof(g_text_file_buffer)` fails).
4. `toggles.txt` in the same folder, if present, must parse.

Any failure in 3 or 4 means dmnt does not attach: **no cheat of that file runs**, not even the valid ones. Homebrew can still force an attach (`ForceOpenCheatProcess`) or detach (`ForceCloseCheatProcess`).

There is **no in-game button combination** that toggles cheats in dmnt. The only buttons dmnt reads are the launch-time key above and the key-press opcodes 8 and C4 inside cheats. Toggling at run time is the overlays' `ToggleCheat`.

### The file

`ParseCheats` (`api.cpp`) reads the text left to right:

- Whitespace is skipped.
- `[Name]` opens a toggleable cheat in the first free entry (1…0x7F; free means no opcodes). An entry with no opcodes stays free, so the next `[Name]` reuses it: empty entries (labels, EdiZon's section markers) vanish.
- `{Name}` opens the **master** cheat, entry 0. A second `{…}` with opcodes already in entry 0 fails the file.
- A hex digit starts one opcode word: exactly 8 hex digits (`strtoul` base 16). A longer run of hex digits is split into 8-digit words. A word before any `[` or `{` fails the file.
- **Anything else fails the file**: there is no comment syntax, and `0x`, prose lines or a stray `]` all fail.
- Names are copied up to 0x40 bytes (`readable_name[0x40]`; the terminator is then written one past the copy, so names should stay under 64 characters).
- More than 0x100 words in one cheat, or no free entry left (127 toggleable cheats + 1 master), fails the file.

Then the master is enabled and every other parsed entry is set to `dmnt_cheats_enabled_by_default` (system setting `atmosphere!dmnt_cheats_enabled_by_default`, `u8`, default 1: **all cheats on**). `toggles.txt` then overrides by name: `[Name]` followed by one token, `1`/`true`/`on` or `0`/`false`/`off` (case-insensitive); unknown names and unknown tokens are ignored, a token of 8 characters or more fails the file. The master cannot be toggled (`ResultCheatCannotDisable`).

### What persists

- Toggles persist **per program ID** (not per build) in `toggles.txt`, written at detach (`SaveCheatToggles`: `[Name]` then `true`/`false` per non-master cheat) only if `toggles.txt` existed and parsed at attach, or the setting `atmosphere!dmnt_always_save_cheat_toggles` (default 0) is set.
- Cheat entries, frozen addresses and static registers are cleared at detach (`CloseActiveCheatProcess` → `ResetAllCheatEntries` → `ResetStaticRegisters`). Nothing else carries over between launches.

### Memory regions

At attach dmnt records the process's regions (`svc::GetInfo`) in its metadata; a memory-type nybble selects the base (`GetCheatProcessAddress`, `vm.cpp`):

| M | Name | Base |
|---|---|---|
| 0 | Main NSO | main module's load address (the loader's module info) |
| 1 | Heap | `InfoType_HeapRegionAddress`: the heap region's start. `svcSetHeapSize` maps the heap from that start upward (`KPageTableBase::SetHeapSize`), so `heap+0` is the first heap byte |
| 2 | Alias | `InfoType_AliasRegionAddress` |
| 3 | Aslr | `InfoType_AslrRegionAddress` |
| 4 | Non-relative | 0: the offset is an absolute address |
| 5–F | | main (the `default:` case shares main's) |

The bases are fixed for the life of the attach. Games with virtual address memory map their memory with `svcMapPhysicalMemory`, which the kernel accepts only inside the alias region (`R_UNLESS(page_table.IsInAliasRegion(address, size), ...)`, `kern_svc_physical_memory.cpp`), so their objects are found through type 2 or through pointers, not through `heap+` ([memory.md, the alias region](memory.md#virtual-address-memory-and-the-alias-region)). There is no stack selector: a stack is reached by an absolute address or a register.

What a read or write can reach is the kernel's rule, not the region (`KPageTableBase::ReadDebugMemory` / `WriteDebugMemory`, `CanReadWriteDebugMemory`): a **read** succeeds on any mapped, user-readable page anywhere in the process; a **write** on any mapped user-read-write page, or on debuggable memory that is user-readable, which includes main's code and read-only data (so code patches work without changing protection). Unmapped pages fail. A region's size is never checked by the VM.

### Cadence

`VirtualMachineThread` (`api.cpp`), each iteration under the cheat lock: reload the program if a cheat was toggled, added or removed; execute it if it has words; write each frozen address; then

```cpp
constexpr s64 TimesPerSecond   = 12;
constexpr s64 DelayNanoSeconds = TimeSpan::FromSeconds(1).GetNanoSeconds() / TimesPerSecond;
os::SleepThread(Delay);
```

So **about 12 passes per second**, not tied to the game's frames (a pass plus 83 ms of sleep). The game is not stopped during a pass: dmnt continues every debug event (`ContinueFlag_ContinueAll`), and the VM reads and writes while the game's threads run, except between opcodes FF0 and FF1.

### Frozen addresses

Beside the VM, `dmnt:cht` keeps up to 0x80 frozen addresses (`EnableFrozenAddress(address, width)`): dmnt reads the current value once (the call fails if that read fails) and writes it back after every VM pass with the raw write SVC. A VM write that covers a frozen address updates the frozen value (`WriteCheatProcessMemoryUnsafe`), but only when the write succeeded. This is what overlays' "freeze" uses; it is not part of the cheat file.

## The VM, as the reference implements it

State (`dmnt_cheat_vm.hpp`): 16 registers of 64 bits, 16 saved values, 16 loop tops, a condition depth, a program of at most `MaximumProgramOpcodeCount = 0x400` words, and 0x100 static registers.

### One program per pass

`LoadProgram` concatenates the words of every enabled entry in entry order: the master (entry 0) first, then the toggleable cheats in file order.

```cpp
for (size_t i = 0; i < num_cheats; i++) {
    if (cheats[i].enabled) {
        if (cheats[i].definition.num_opcodes + m_num_opcodes > MaximumProgramOpcodeCount) {
            m_num_opcodes = 0;
            return false;
        }
        ...
```

`Execute` reads the buttons once, then resets the state **once per pass over that whole program**:

```cpp
R_DISCARD(hid::GetKeysHeld(std::addressof(kHeld)));
...
this->ResetState();   /* registers, saved values, loop tops = 0; ip = 0; depth = 0; decode_success = true */
while (this->DecodeNextOpcode(std::addressof(cur_opcode))) { ... }
s_keyold = kHeld;
```

So registers, saved values, loop tops and the condition depth carry from one cheat into the next within a pass, and a block left open by one cheat contains the following cheats. Static registers are not reset by a pass.

### Decoding

The opcode is the top nybble; C, D, E, F take the next nybble (`0xC0`…), and `0xF0`… takes a third (`0xFF0`…). Valid opcodes: 0–A, C0–C4, FF0, FF1, FFF. Anything else (B, C5–CF, D0–EF, F00–FEF, FF2–FFE) fails decoding. A width T outside 1, 2, 4, 8 is decoded but makes the access or comparison a no-op (`GetVmInt` returns 0, the read or write `switch` has no case for it). Immediate offsets are 40 bits in opcodes 0, 1 and 5 (`AA AAAAAAAA`) and 36 bits in A, C0 and FFF (`a aaaaaaaa`).

### 0: store static

`0TMR00AA AAAAAAAA V…`: writes the low T bytes of V (one word, two for T = 8) to `base(M) + A + reg[R]`. **Register R is always added**; there is no enable flag (with R = 0, register 0 is added).

### 1: memory conditional

`1TMCXrAA AAAAAAAA V…`: reads T bytes at `base(M) + A`, plus `reg[r]` when X ≠ 0, into a zeroed value and compares it, unsigned, with V: C = 1 `>`, 2 `>=`, 3 `<`, 4 `<=`, 5 `==`, 6 `!=` (any other C is never met). Not met: skip to the matching else or end.

### 2: end / else

`20000000` ends a block: depth − 1, and **at depth 0 a no-op** ("We will assume, graciously, that mismatched conditional block ends are a nop"). `21000000` (else), reached while executing, skips to the matching end. Any other X is an end.

### 3: loop

`300R0000 N`: `reg[R] = N`, loop top = the next word. `310R0000`: `reg[R]--`; if it is not 0, jump to the loop top. The body runs N times for N ≥ 1, at least once in every case (the test is at the end). Loops are tracked per register, so loops nest only with different registers.

### 4, 5: load register

`400R0000 VVVVVVVV VVVVVVVV`: `reg[R] = V` (64 bits).

`5TMRI0AA AAAAAAAA` reads T bytes **directly into `reg[R]`'s storage**:

| I | Address |
|---|---|
| 1 | `reg[R] + A` (M ignored) |
| 2 | `reg[S] + A`, S in the nybble after I |
| 3 | `base(M) + reg[S] + A` |
| 0 or 4–F | `base(M) + A` |

The read copies only T bytes into the 64-bit register (`ReadCheatProcessMemoryUnsafe(src_address, std::addressof(m_registers[...]), bit_width)`): on the Switch's little-endian core **a T < 8 load replaces the low T bytes and keeps the register's upper bytes**. It does not zero-extend.

### 6: store static to a register address

`6T0RIor0 VVVVVVVV VVVVVVVV`: writes the low T bytes of the 64-bit V to `reg[R]` (+ `reg[r]` when o ≠ 0), an absolute address with no region base; then `reg[R] += T` when I ≠ 0.

### 7 and 9: arithmetic

- **7** (legacy) `7T0RC000 VVVVVVVV`: `reg[R] op= V`, V a 32-bit value zero-extended, C = 0 add, 1 sub, 2 mul, 3 shl, 4 shr. Other C: no operation. Then `reg[R]` is truncated to T bytes in place (T outside 1/2/4/8: not truncated).
- **9** `9TCRS0s0` (register operand) or `9TCRS100 V…` (immediate of T bytes, two words for T = 8): `reg[R] = reg[S] op operand`, C = 0 add, 1 sub, 2 mul, 3 shl, 4 shr, 5 and, 6 or, 7 not (`~reg[S]`), 8 xor, 9 move, 10–13 float add / sub / mul / div (T = 4 single, T = 8 double; any other T gives 0). The result is truncated to T bytes. An unknown C stores 0. Shifts are C++ shifts of a 64-bit value; amounts of 64 or more are undefined in C++, so the source does not define them.

### 8 and C4: key-press conditionals

`kHeld` is `hid::GetKeysHeld`: the **held** buttons (not newly pressed, whatever the format doc's "hidKeysDown()" says), OR-ed over handheld and players 1–8, from the system-extended npad state, read once at the start of the pass (0 if the read fails).

- **8** `8kkkkkkk`: a 28-bit mask; met when every bit of the mask is held (`(mask & kHeld) == mask`). Other buttons may be held too; a mask of 0 is always met. Bits 24–27 are SL / SR of the Joy-Cons.
- **C4** `C4r00000 kkkkkkkk kkkkkkkk`: a 64-bit mask. r ≠ 0 (auto-repeat): as 8. r = 0: met only on the pass where the mask is fully held and **was not fully held on the previous pass** (`s_keyold`, one static for every C4 in the program, updated at the end of each executed pass).

### A: store register

`ATSRIOxa (aaaaaaaa)`: writes the low T bytes of `reg[S]`. Address by O: 0 `reg[R]`; 1 `reg[R] + reg[x]`; 2 `reg[R] + a`; 3 `base(x) + reg[R]`; 4 `base(x) + a` (R ignored); 5 `base(x) + reg[R] + a`; any other O is treated as 0. Then `reg[R] += T` when I ≠ 0 (for every O).

### C0: register conditional

`C0TcSX…`: compares the low T bytes of `reg[S]` with an operand, unsigned, with the conditions of opcode 1. X: 0 memory at `base(M) + a`; 1 memory at `base(M) + reg[r]` (no immediate); 2 memory at `reg[R] + a`; 3 memory at `reg[R] + reg[r]`; 4 a static value of T bytes; 5 the low T bytes of `reg[X]`. Memory operands are read into a zeroed value.

### C1, C2: save and restore

`C10D0Sx0`: x = 0 `reg[D] = saved[S]`, 1 `saved[D] = reg[S]`, 2 `saved[D] = 0`, 3 `reg[D] = 0` (other x: restore). `C2x0MMMM`: the same per bit of a 16-bit mask, `reg[i]` ↔ `saved[i]`. Saved values are zeroed every pass.

### C3: static registers

`C3000XXx`: XX < 0x80 loads `reg[x] = static[XX]`; XX ≥ 0x80 stores `static[XX] = reg[x]`. A cheat can only read 0x00–0x7F (homebrew writes them through `WriteStaticRegister`) and only write 0x80–0xFF (homebrew reads them). They keep their values across passes and toggles, until detach or a homebrew `ResetStaticRegisters`.

### FF0, FF1, FFF

- **FF0** breaks the game process (`svc::BreakDebugProcess`); **FF1** continues it. The break lasts across passes until an FF1 runs.
- **FFF** `FFFTIX…` appends one line, `%016lx\n`, to `/atmosphere/cheat_vm_logs/<I as %08x>.log` on every pass it runs. X: 0 memory at `base(M) + a`, 1 `base(M) + reg[r]`, 2 `reg[R] + a`, 3 `reg[R] + reg[r]`, 4 the low T bytes of `reg[X]`.

### Behaviour on failure

| Case | What the reference does |
|---|---|
| A read fails (unmapped address, wrong permission) | The result is discarded (`R_DISCARD`). The destination keeps what it had: opcode 5 leaves the register unchanged (0 if nothing set it earlier in the pass); opcodes 1 and C0 compare against 0; FFF logs 0. **The cheat stays enabled and the pass goes on.** It is retried on the next pass. |
| A read crosses a block boundary and only the second block fails | `KDebugBase::ReadMemory` copies block by block, so the first bytes may already be in the destination. Only an unaligned access can do this. |
| A write fails | Discarded; nothing written, the frozen value is not updated, the cheat stays enabled, the pass goes on. |
| `20000000` at depth 0 | No-op. |
| `21000000` (else) at depth 0 | `SkipConditionalBlock` reaches `R_ABORT_UNLESS(ResultVirtualMachineInvalidConditionDepth())`: **dmnt aborts**. What the player then sees is not in the files read. |
| A block whose end is missing | If the condition is not met, skipping runs to the end of the program: the rest of the pass, every later cheat included, is skipped. If met, the depth simply stays raised. |
| An unknown opcode | Decoding fails and the failure is sticky for the pass (`m_decode_success &= valid`): **the pass stops there**. Earlier words (the master, earlier cheats) ran; that cheat's remaining words and every later enabled cheat do not, on every pass. Nothing is marked or disabled, and no opcode is validated at load. Inside a skipped block an unknown opcode stops the pass the same way. |
| Running past the end | Reading a word past the program fails decoding: the pass ends. An instruction whose last words are missing is not executed. |
| Loop with N = 0 | The body runs, the counter goes from 0 to 2^64 − 1: the loop practically never ends. |
| `310R0000` without its start | Loop top is 0: if `reg[R] − 1 ≠ 0` it jumps to the first word of the whole program (the master's). |
| A pass that never ends | There is no instruction budget. The VM thread keeps the cheat lock, so later passes, frozen addresses and every `dmnt:cht` call that takes the lock wait. |
| Nesting | Condition depth is a `size_t`: no limit. One active loop per register. |
| Program size | 0x100 words per cheat (more fails the file). 0x400 words for all enabled cheats together: past that `LoadProgram` returns false with an empty program, so **no cheat runs, the master included**, and the load is retried each pass until toggles bring it under. 0x80 entries. |

## What this host does differently

The host side is what [docs/development.md, Cheats](../development.md#cheats) states, each row checked against `hle_cheats.c` and `dm/host/tests/t_cheats.c` on 2026-10-26.

| Point | Switch (Atmosphère 1.12.1) | Host (development.md) | | Consequence for a player |
|---|---|---|---|---|
| File name and place | `/atmosphere/contents/<program id>/cheats/<build id>.txt` | same name, in a flat folder or the Atmosphère tree | same | Files from cheat sites drop in unchanged. |
| A file with prose, comments or a bad word | whole file rejected, nothing runs; a run of hex digits is cut into 8-digit words wherever whitespace falls | glued words are cut the same way; a line of prose (a token with a non-hex character, no words) is dropped, labels kept; a line mixing code and a non-code token, or holding hex digits that are not whole words (`0400000`, `dead beef`), turns only its cheat off (`malformed line N`) | different | A file that runs here can do nothing on a Switch; glued words run on both. |
| Limits 0x80 / 0x100 / 0x400 | file rejected / nothing runs | reported, not enforced | different | Long cheat sets run here and not on a Switch. |
| Enabled at load | master on; every cheat on (`dmnt_cheats_enabled_by_default`, default 1) | master on; others from `<build id>.enabled` and `DM_CHEATS_ON`; the default for a new file is not stated | different (as implied) | A new file starts with fewer cheats on than on a Switch. |
| Launch gate | holding L at launch loads no cheats | `.cheats-off-<title ID>` and safe mode | different | No button skips cheats here. |
| Toggles saved | `toggles.txt` per program ID, only if it exists or `dmnt_always_save_cheat_toggles` | `<build id>.enabled` per build, always | different | Toggle files do not carry between the two. |
| One program per pass | all enabled cheats concatenated, master first; registers, saved values, depth and loops reset once per pass and shared between cheats; the keys read once per pass | masters first, then the enabled cheats in file order; registers and saved values reset once per pass and shared, the keys read once per pass; each cheat is its own program, so the condition depth and the loop tops (word indexes into the cheat's own program) start fresh for each, and a loop end without its start jumps to the first word of its own cheat | same, except open blocks and stray loop ends | A block left open by one cheat does not contain the later cheats here; a stray loop end never jumps into another cheat's words. |
| Cadence | about 12 passes per second, game running | once per presented frame, ~60 Hz when not presenting | different | Per-pass effects (adding to a value) happen about 5 times as often; a C4 edge still fires once per press. |
| A failed read | ignored; register unchanged, compare with 0; cheat stays on and retries | same; the first failure of a cheat logs one `[RED]` line, every one is counted into a note on its row (` (no effect: N accesses out of mapped memory)`, gone after a pass without one) | same | A pointer cheat enabled while its pointer is still null starts working once the pointer is set, as on a Switch. |
| A failed write | ignored; cheat stays on | same, counted as above; a write into main past the game's own image (the host's key page, frame step page and patch areas) or a code write refused below turns the cheat off | same | |
| Reachable memory | any mapped user-readable page (read), user-writable or code / read-only data (write); all five memory types | a read: any page the guest block (stacks, the alias region, MapMemory'd pages) or a module (NSO, NRO) maps; a write: main (code included, through its alias), the opened heap, another module's data and bss, any other mapped guest page; never another module's code or read-only data, never the host's own memory | same for the game's memory | A write into another module's code, which the debug SVC allows, fails here (counted). |
| Heap before `SetHeapSize` | heap base known at attach; accesses fail silently until mapped | the cheat waits until the heap opens | different | None visible. |
| Memory types 2, 3, 4, 5–F | alias, ASLR, absolute, main | the same, from the host's layout (`region_base`: the alias region is checked against the block's partition, else refused with `[RED]`) | same | |
| Else at depth 0 | dmnt aborts | that cheat is turned off for the session (`mismatched else`), the others run | lenient | A file that would crash dmnt runs here without that cheat. |
| End at depth 0 | no-op | no-op | same | |
| Unknown opcode | the pass stops at it; later cheats do not run; nothing marked | the cheat is marked unsupported and never runs; others run | different | One bad cheat does not stop the others here. |
| Opcodes 9, C1, C2 | implemented: all math types, the float ones at T = 4 / 8; saved values zeroed per pass | implemented the same (`t_cheats.c` holds every math type and width, the shifts, save / restore across cheats and their reset) | same | |
| Opcode 9 shift count ≥ 64 | undefined in C++; the Switch's core (LSLV / LSRV) takes it modulo 64 | taken modulo 64, as opcode 7's | same as the hardware | |
| Opcode 9 unknown math type (14, 15) | stores 0 | stores 0 | same | |
| Opcode C4 | 64-bit mask; `r = 0` met on the pass where the mask became held, against `s_keyold`, one static for every C4, set at the end of each executed pass | the same, against one value set at the end of each pass that ran a VM cheat (a pass of only never-decrease cheats leaves it); a dry run never changes it; bits above 23 are never held (as for 8) | same | A one-shot C4 cheat fires once per press here too. |
| Opcodes FF0, FF1, FFF | implemented | cheat marked unsupported, never runs | different | Cheats that pause the game or log stay off here. |
| Opcode 8 mask | 28 bits, held keys of every controller; bits 24–27 SL / SR | 28 bits, the keys held on any input source (`dm_cheats_keys`), read once per pass; bits 24–27 are never held, no input source reports SL / SR | same, but SL / SR | Cheats bound to SL / SR never trigger. |
| Opcode 5 with T < 8 | upper register bytes kept | upper register bytes kept | same | |
| Opcode 0 offset register | always added | always added | same | |
| Running past the end, truncated words | pass ends, partial instruction not run | the cheat is marked `(truncated)` at load and never runs; its whole words do not run either | different | A cheat cut short does nothing here; on a Switch its first instructions run. |
| Loop with N = 0, endless loop | effectively endless; VM thread blocked | a step cap (4,000,000 instructions in one pass) turns that cheat off with `[RED]`; the frame goes on | different | A file that would hang dmnt runs here without that cheat. |
| Nesting | unlimited depth; one loop per register | unlimited depth; one loop per register | same | |
| Static registers | persist across passes; cleared at detach; homebrew fills 0x00–0x7F | persist; cleared when a file loads; nothing fills them (cheats read 0) | same, no writer | Cheats driven by an overlay's static registers do nothing here. |
| Frozen addresses | `dmnt:cht` list, written after each pass | no such list; `freeze` is compiled into cheats, plus host-only never-decrease | different | Overlay freezes have no equivalent; compiled freezes behave like cheats. |
| Writes into main's code | allowed by the debug write SVC | on the Mac, through a writable alias of the image, with an icache flush, except into a word the rewriter changed or moved (`main.changed.tsv`: its sites, cuts, lock acquires, and the windows and spin waits that run from copies), which turns the cheat off with the reason; refused whole without that list (modules from an older rewriter). On the iPhone never: its code pages are the app's signed pages | different | Most code patches apply on the Mac. One that writes over a rewritten word, often the off half of a pair putting the Switch's original instruction back over the rewriter's branch, would undo the site (an SVC or TLS read running natively) or never run, so it stays off. On the iPhone only data cheats run. |

## Sources

All read on 2026-10-26 at Atmosphère commit [`6b0c077b4c608a3a2ee712b8dc35fee87ceb62e8`](https://github.com/Atmosphere-NX/Atmosphere/tree/6b0c077b4c608a3a2ee712b8dc35fee87ceb62e8) (2026-10-15), identical to tag 1.12.1 and to `master` that day. Files under `https://raw.githubusercontent.com/Atmosphere-NX/Atmosphere/6b0c077b4c608a3a2ee712b8dc35fee87ceb62e8/`:

- `docs/features/cheats.md`: loading, the format, opcode encodings.
- `docs/components/modules/dmnt.md`: the `dmnt:cht` interface.
- `docs/features/configurations.md`, `config_templates/override_config.ini`, `config_templates/system_settings.ini`: `cheat_enable_key`, `dmnt_cheats_enabled_by_default`, `dmnt_always_save_cheat_toggles`.
- `stratosphere/dmnt/source/cheat/impl/dmnt_cheat_vm.hpp`, `dmnt_cheat_vm.cpp`: `DecodeNextOpcode`, `SkipConditionalBlock`, `GetCheatProcessAddress`, `ResetState`, `LoadProgram`, `Execute`, `DebugLog`.
- `stratosphere/dmnt/source/cheat/impl/dmnt_cheat_api.cpp`, `.hpp`: `CheatProcessManager` (`AttachToApplicationProcess`, `VirtualMachineThread`, `ParseCheats`, `ParseCheatToggles`, `LoadCheats`, `LoadCheatToggles`, `SaveCheatToggles`, `CloseActiveCheatProcess`, frozen addresses).
- `stratosphere/dmnt/source/cheat/impl/dmnt_cheat_debug_events_manager.cpp`, `dmnt_cheat_service.cpp`: debug event continuation, the service.
- `libraries/libstratosphere/include/stratosphere/dmnt/dmnt_cheat_types.hpp`: `CheatProcessMetadata`, `CheatDefinition`, `CheatEntry`.
- `libraries/libstratosphere/source/cfg/cfg_override.board.nintendo_nx.inc`: `CaptureOverrideStatus`, `IsOverrideMatch`, the default cheat key.
- `libraries/libstratosphere/source/hid/hid_api.cpp`: `GetKeysHeld`.
- `libraries/libmesosphere/source/kern_k_debug_base.cpp` (`ReadMemory`, `WriteMemory`), `kern_k_page_table_base.cpp` (`CanReadWriteDebugMemory`, `ReadDebugMemory`, `WriteDebugMemory`, `SetHeapSize`), `svc/kern_svc_debug.cpp`, `svc/kern_svc_physical_memory.cpp` (`MapPhysicalMemory`): which pages a debugger reaches, where the heap and virtual address memory live.

No secondary source was needed. The host column comes from [docs/development.md, Cheats](../development.md#cheats) and `dm/host/hle_cheats.c` as of 2026-10-26 (the engine was brought to this table's reference semantics that day: failed accesses, reachable memory, the per-pass register reset).
