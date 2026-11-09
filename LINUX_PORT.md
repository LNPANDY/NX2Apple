# Porting NX2Apple to native Linux

This page is the plan for running the engine of this repository on Linux, written after
reading the engine at the pinned upstream commit `c78d7375bea9` and the 64 patches of
`patches/series` that this fork carries. It says what has to change, where the seams are,
how big each piece is, and what has not been demonstrated yet.

Nothing in this page has been run on a Switch game yet. Every number below is a measurement
of the source tree at that commit, and the commands that produced them are in the last
section.

## Status

**2026-11-08, on Ubuntu 24.04, x86_64.**

- **M0 is done**: this page, the inventory and the blocker list below.
- **M1 is done**: the launcher runs on Linux. `frontend-qt` starts, its dependency panel
  names the Linux tools, and its whole test suite is green: 415 tests, 3 skipped, no
  failures. The new rows are `zstd` (required), `spirv-cross` and `glslangValidator` (the
  two tools of the Vulkan shader chain, optional), and the panel says in its log that the
  iPhone build needs a Mac or the Windows cross toolchain. The regression is
  `frontend-qt/tests/test_linux.py`.

  Three things had to be fixed to get there, and all three were bugs on every platform,
  not only on Linux:

  - **The children now run with the C locale** (`frontend-qt/nspb_qt/platform_util.py`,
    `child_env`, and `tools/patches.py`, `clean_env`). The engine's messages are English
    and the panel's patterns match them, but the system's own text (`strerror`) followed
    the machine's locale, so on a Spanish machine the log said "La operación no está
    soportada" where the pattern looks for "Operation not supported", and the panel lost
    the hint. The same happened with git's "falta información sha1" in the tools.
  - **The ASCII temp folder no longer creates Windows folders on other systems**
    (`frontend-qt/nspb_qt/win/toolchain.py`, `ascii_temp_dir`). On Linux it made a folder
    named `C:\Windows\Temp` inside the working folder, and the test only passed when the
    checkout's path had no spaces.
  - **`tests/test_win.py` does not compile on Python 3.11 and 3.12** ("too many statically
    nested blocks": a `with` statement with nineteen context managers). The CI runs the
    engine's tests on Python 3.14, where the limit is higher, and the build scripts' own
    floor is 3.12 (`MIN_PYTHON` in `platform_util.py`), so the file is broken for a version
    the launcher supports. **Not fixed here**: the file belongs to the upstream fork and the
    fix belongs there.

- **M2 is done**: the host's service layer builds and runs on aarch64 Linux.
- **M3 is done as a dual runtime**: `make -f Makefile.linux ARCH=aarch64` and `ARCH=x86_64`
  both build (static ELFs, 9.4 MB and 5.7 MB), and `./run-linux --mode qemu|native` runs
  them: the qemu mode runs the ARM64 host under `qemu-aarch64-static`, the native mode runs
  the machine's own host with no emulator on the path. Both reach the identical point on
  this machine (743 NVN names, 498 implemented, the same profile, the same stop at the
  game's first file, exit 134), and the x86_64 host says its own frontier: guest execution
  unsupported, exit 86. The compat layer's test passes on both, and the adversarial checks
  (no emulator, wrong ELF, missing binary, missing profile) pass 10 out of 10.
- **M2's stand-in layer** (`dm/host/linux`, 6,900 lines of it):

  | file | what it answers |
  |---|---|
  | `include/mach/*` | the Mach VM and thread interfaces: `vm_read_overwrite` / `vm_write` are `/proc/self/mem`, the mappings are `mmap` / `mprotect`, the regions come from `/proc/self/maps`, the clock is `CLOCK_MONOTONIC` |
  | `include/CoreFoundation`, `CommonCrypto` | the build stamp the packer leaves in the bundle, the NVN layer's dictionary, the SHA-256 the host hashes its modules with |
  | `include/dispatch` + `linux_dispatch.c`, `linux_blocks.c` | GCD over threads (a serial queue that keeps its order, a timeout, a signal source), and the block runtime the blocks take |
  | `linux_compat.c` | the implementations, and `sysctl` over `/proc` and `uname` |
  | `front_linux.c` | the front end: the guest runs on the calling thread, no window |
  | `linux_gfx_stub.c` | the whole Metal seam, answered with nothing: the host runs, nothing is drawn, the first call that would have drawn says so |
  | `linux_media_stub.c` | audio and the movie decoders, missing until their device layer exists |
  | `asm_elf.py` | the Mach-O assembly converted to ELF (`entry.S`, the NVN thunks); the macOS build keeps the files it always had |

  Three of those stand-ins report what they cannot do instead of pretending, and the
  host prints it once:

  - **`vm_remap` maps a copy.** Linux cannot map another mapping's pages at a second
    address, so an alias of a memory pool is a copy (the host's `[RED]` line names it).
    The NVN virtual pools therefore read through the host's page table only.
  - **A thread's registers are not readable from another thread.** The crash dump
    carries the stacks instead, as it does when the register read fails on Apple.
  - **The instruction counters of `thread_selfcounts` read zero**, and the present
    thread's real-time policy is accepted and not enforced (Linux has no computation
    budget per thread).

  The diff to the shared sources is one `#ifdef` per platform boundary: `dm.h`
  (`clock_gettime_nsec_np`, `MAP_JIT`, `dm_stat_mtime`), `hle.h` (the big-stack stub's
  assembly), and the register reads of `crash.c`, `probe.c` and `hle_thread.c`, which
  go through `dm_uc_ss` / `dm_uc_ns` and resolve to Apple's own members there.

- **M2's toolchain**: `zig cc -target aarch64-linux-musl -static` (zig 0.16.0, already
  on the machine). A static binary runs on any aarch64 Linux; a dynamic one needs a cross
  glibc, which is a distro's business. The build needs no Apple SDK, no Xcode and no
  Rosetta. `qemu-user-static` (the Ubuntu package works, extracted anywhere) runs the
  result on an x86_64 machine, which is how the tests above were run.


## What this repository is

Two layers, and the port touches them differently.

- **The launcher** (`frontend/`, `frontend-qt/`, `frontend-ios/`): the app that unpacks a
  dump, runs the build and keeps a library. `frontend-qt/` is already cross-platform
  (Python 3.9+ and PySide6) and runs on Windows and macOS. It is the part that can reach
  Linux with a small patch.
- **The engine** (`engine/`, which is `seedds/nxnative` at the pin plus the patch series):
  the part that actually runs a game. It answers Horizon's system calls, implements NVN,
  Vulkan and desktop OpenGL **on Metal**, and rewrites the game's own module so its code
  runs on the host CPU. It is macOS and iOS only.

The engine is not committed here. `python3 tools/engine.py sync` fetches the pin and applies
the series into `engine/`, which is a real git repository this one ignores.

## The target

"Natively on Linux" can mean three different machines, and the choice changes the size of
the work by an order of magnitude.

| Target | What it means | Verdict |
|---|---|---|
| **aarch64 Linux** (Raspberry Pi 5, an ARM desktop, an ARM server) | the host binary and the game's own arm64 code run on the same CPU, exactly as on Apple silicon | **the recommended target**. The engine's model (the game's code runs on the host) holds as it is |
| **x86_64 Linux** running an aarch64 host under an emulator (qemu-user) | same binary, translated at run time | possible, slow, and it needs an emulator in the loop. A separate build is not needed, the same aarch64 binary runs |
| **x86_64 Linux with an arm64 to x86 JIT** | the game's code is translated to the host ISA | a project of its own, the size of the whole graphics port again. Not for a first version |

The rest of this page assumes the aarch64 target, with qemu-user as the way to try it on an
x86_64 machine.

## What has to change

The engine is about 24,000 lines of C and Objective-C in the host, and about 20,000 lines in
the graphics layer. The measurements below are lines of code.

| Area | Unit | Lines | What it is |
|---|---|---|---|
| Graphics | `dm/gfx/nvn/nvn_mtl.m` | 15,669 | the NVN to Metal replay layer. The bulk of the port |
| Graphics | `dm/gfx/vk/hle_vk.m` | 1,760 | Vulkan on Metal, for the games that render with Vulkan (Hades, Super Mario Galaxy) |
| Graphics | `dm/gfx/gl/hle_gl.m` | 2,068 | desktop OpenGL through EGL on Metal, for the games that use NVIDIA's GL driver |
| Graphics | `dm/gfx/nvn/hle_nvn.c` | 3,116 | the NVN interface layer. Portable C, it does not change |
| Graphics | `dm/gfx/metal/mtl_backend.m`, `dm/gfx/msl/*.metal`, `dm/gfx/tex/nvn_fmt_mtl.c` | about 480 | the offscreen backend example, the host's own Metal shaders, the texture format table |
| Front end | `dm/host/front_mac.m` | 1,478 | the Mac window, the menu, the save prompt, the progress screen |
| Front end | `dm/host/controllers_mac.m` | 1,030 | GameController, the Steam Controller, the Joy-Con pairing |
| Front end | `dm/host/haptics_apple.m`, `dm/host/web_apple.m` | 898 | CoreHaptics, the WebKit view of the web applet |
| Host | the rest of `dm/host/*.c` and `*.h` | about 20,300 | Horizon's services, the file system, the loader, the input layer. About 90 percent of it is portable C |

### The blockers that a Linux compile already shows

Compiling the host's units with clang on Linux, without the Apple headers, fails on these
places only. Each is a small shim.

| Blocker | Where | What Linux uses instead |
|---|---|---|
| `mach-o/getsect.h` | `dm/host/host_image.h` | the host reads its own sections (`__DATA,swforce`). A Linux host is an ELF, so it needs an ELF reader for the same table |
| `mach/mach.h` | `hle_svc.c`, `hle_fs.c`, `hle_thread.c`, `hle_uecvar.c` | Mach ports and threads. Linux has pthreads, futexes and condition variables |
| `mach/mach_time.h`, `clock_gettime_nsec_np` | `hle_os.c`, `hle_time.c` | `clock_gettime(CLOCK_UPTIME_RAW)` |
| `malloc/malloc.h` | `hle_uemalloc.c` | the guest allocator's zones. A glibc allocator behind the same interface |
| `TargetConditionals.h` | `loader.c`, `probe.c`, `crash.c` | a small header with the same macros |
| `CoreFoundation/CoreFoundation.h` | `main.c` | a small shim for the few CF types the bootstrap uses |
| `mergesort` | `hle_hid.c` | `qsort` or a local copy |
| `vm_remap` | `loader.c` | the loader maps the game's code pages. Linux has `mmap` with `MAP_FIXED` over the source pages |
| `MAP_JIT`, `pthread_jit_write_protect_np` | `hle_jit.c` | the run-time code generator's write and execute switch. `mprotect` behind the same lock |
| AudioToolbox, CoreHaptics, GameController, WebKit, ImageIO, UniformTypeIdentifiers | `hle_audio.c`, `haptics_apple.m`, `controllers_mac.m`, `web_apple.m` | PipeWire or ALSA, an SDL or evdev input layer, a web view or none |

### The rewriter's Apple rules

`dm/tools/patch_nso.py` rewrites the game's module so it can run on the host. Three of its
rewrites exist because of Apple's kernel and not because of Horizon.

- The stack pointer is rounded up to 16 bytes. Apple's kernel faults on a misaligned `sp`.
  Linux does not, so this becomes a per-host rule.
- The test and set pairs become `ldaxr` (acquire ordering). Apple cores need it because the
  Switch's Cortex-A57 did not. Linux arm64 has the same weak ordering, so the rule stays.
- `mrs xN, ctr_el0` is replaced. Apple's kernel does not expose the counter to user mode
  and raises SIGILL, Linux does expose it, so this becomes a per-host rule as well.

The rewriter is Python and takes the module as its input, so a per-host rule table is a
small change. The same file also holds the rules that depend on Horizon, and those do not
change.

## The seams

The engine was written with three clean seams, and the port uses them instead of rewriting
the host.

1. **`dm/host/front.h`** is the front end's interface: the window, the progress screen, the
   text input box, the controller prompt, the web view, the save failure notice. The Mac
   front end (`front_mac.m`) and the iOS front end (`dm/ios/`) both implement it. A
   `front_linux.c` implements it with an X11 or Wayland window, a Vulkan surface and a
   Linux input layer. The host calls the front end through this header only.
2. **`dm/gfx/nvn/nvn_mtl.h`** is the graphics backend's interface: about 60 C functions for
   the pools, the submits, the events, the counters, the present and the resource counts.
   The host calls the graphics layer through this header only, so a `nvn_vk.h` with the same
   shape is a drop-in replacement for `nvn_mtl.h`.
3. **The shader chain** (`dm/gfx/tools/dmsh_*`) is offline and driven by a script. Its last
   step is Apple's Metal compiler, and that step is the one that changes.

## The address model, and why it is the hardest part

The Metal backend builds every memory pool as a zero-copy `MTLBuffer` whose GPU address is
the CPU address, so the engine only works on a unified memory device (Apple silicon). A
Linux machine with a discrete GPU has no such device, and Vulkan's device addresses are
never host pointers.

So the Vulkan backend needs an address translation layer that the Metal backend never had:
the guest keeps its own addresses, and the replay layer resolves each one to a buffer and an
offset when it binds. Ryujinx does the same thing on a desktop GPU, and its address manager
is the reference. On a machine with unified memory the translation can be the identity, so
the same code covers the Raspberry Pi and the desktop.

The Metal usage is dominated by textures (371 mentions of `MTLTexture`), buffers (207),
pixel formats (93), functions (65) and the render and compute encoders (89). Their Vulkan
counterparts are `VkImage` plus `VkDeviceMemory`, `VkBuffer`, a format table, one
`VkShaderModule` per stage and `VkCommandBuffer` with render and compute passes. The
argument tables of Metal 4 (`MTL4ArgumentTableDescriptor`) become descriptor sets and push
constants.

## The shader chain on Linux

The chain today is:

```
Switch shader package
  -> tools/dmsh_xlate        the game's Tegra machine code to SPIR-V (a C# tool, Ryujinx's translator)
  -> spirv-cross             SPIR-V to Metal Shading Language
  -> xcrun metal / metallib  MSL to a Metal shader library
```

On Linux the last two steps become:

```
  -> spirv-cross             SPIR-V to GLSL for Vulkan (spirv-cross --vulkan)
  -> glslangValidator        GLSL to SPIR-V for Vulkan
```

The first step does not change (it is the .NET tool `dmsh_xlate`, and .NET runs on Linux).
The chain version `DMSH_CHAIN` is the hash of the chain's files and the tools' fingerprints,
so a Vulkan chain is a different version and the host loads a different directory
(`b-<V>/`). The library ABI (`dm/gfx/nvn/dmsh_abi.h`) is the contract between the libraries
and the replay layer, and it is chain material, so a Vulkan chain needs its own ABI file.

The host's own Metal shaders (`dm/gfx/msl/*.metal`, about 200 lines) are the clear, copy,
deswizzle, geometry pack and present kernels. Their Vulkan equivalents are compute shaders
with the same names.

Two chain tools are Metal-specific and need a Vulkan twin: `dmsh_fetch.py` with its
`dmsh_pull.metal` decoder (the readable tile versions of the fragment shaders) and
`dmsh_build.py`'s call to the Metal compiler. The pipeline archive (`pso_offline.py` with
`metal-tt`) has no Vulkan counterpart, so the pipeline bases are built at run time on Linux
(`DM_PSO_GPUS=none`, the same switch the Windows path already uses).

## The two runtimes: QEMU and native

M3 splits the port into two runtimes, both real:

| mode | what runs it | where it works | what the guest does |
|---|---|---|---|
| **qemu** | the ARM64 host binary, under `qemu-aarch64-static` | any machine: on x86_64 through the emulator, natively on ARM64 | its ARM64 code runs, slowly |
| **native** | the host binary for this machine's own architecture, directly | an ARM64 machine (the guest runs), an x86_64 machine (it cannot) | runs on ARM64, and cannot on x86_64 |

```sh
cd engine/dm/host
make -f Makefile.linux GAME=<id> ARCH=aarch64      # the ARM64 host, static
make -f Makefile.linux GAME=<id> ARCH=x86_64       # the x86_64 host, static
./run-linux --mode qemu    <args>                  # the ARM64 host, under the emulator
./run-linux --mode native  <args>                  # this machine's own host, no emulator
```

Nothing is renamed here: the x86_64 mode does not wrap QEMU in another name. `run-linux`
runs the host's own ELF, checks its architecture against the machine's, and never puts an
emulator in the way (the tests for that are `linux/tests/adversarial_linux.sh`). The x86_64
host loads, relocates and inspects the game's ARM64 modules, answers every Horizon service
that does not need to execute them, and stops at the boundary where the game's code would
start, with exit status 86. There is no instruction-set translation anywhere in the engine,
and none was added.

The frontier is stated by the host itself, in the first line of every run:
`[dm] host <arch> Linux, guest execution supported | unsupported`. On this x86_64 machine:

```
[dm] [nvn] null device: 743 names, 498 implemented (487 semantic + 11 empty, 352 of them on the large host stack), the other 245 go to the red-reporting stub
[dm] host x86_64 Linux, guest execution unsupported (the modules' code is ARM64)
```

The x86_64 build's guest-facing ARM64 assembly (the gate stubs, the NVN counting thunks) is
replaced by `linux/guest_stub_x86_64.c`, whose entries report and stop rather than pretend,
and the NVN name table comes from the thunks file by `asm_elf.py --names`, so the device
resolves its implementations identically on both architectures. The register view of a Linux
signal handler maps the host's own Intel registers (`gregs`): RIP, RSP, RBP and flags, with
no link register and no NEON state, because x86_64 has neither.

**M3 is HOST_NATIVE_READY and not M3-B.** M3-B needs a machine that runs the guest (an
ARM64 host, or a runner with one) and a game's files, neither of which this checkout has.

## The milestones

Each milestone ends with something that can be run and checked. The order matters: the
graphics layer is the biggest piece and the least certain, so it starts early, behind a
headless harness that does not need a window.

| Milestone | What it delivers | How it is checked |
|---|---|---|
| **M0** the plan | this page, the inventory, the blocker list | the page and the measurements in the last section |
| **M1** the launcher on Linux | `frontend-qt` runs on Linux, its dependency panel names the Linux tools, its tests pass | `python3 -m unittest discover frontend-qt/tests` on Linux |
| **M2** the host compiles on Linux | `dm/host` builds for aarch64 Linux with the graphics layer stubbed out | `make -C dm/host` with the Linux makefile, the binary starts and reports its missing pieces. **Done** (see Status) |
| **M3** the two runtimes | the host runs on x86_64 natively and on ARM64 under qemu, selected per run | `run-linux --mode qemu|native`; the compat tests pass on both, the adversarial checks pass. **Done** for the host; the guest's own code still needs an ARM64 machine and a game's files (M3-B) |
| **M4** the Vulkan backend | `nvn_vk.c` replaces `nvn_mtl.m` behind the same header, the NVN tests of `dm/gfx/tests` run on it | the engine's own graphics tests, which run today against Metal |
| **M5** the shader chain | the Vulkan chain produces the libraries, the host loads them | a game reaches its first frame with the right picture |
| **M6** the Linux front end | a window, a Vulkan surface, sound, controllers | a game plays on a Raspberry Pi 5 or an ARM desktop |
| **M7** the launcher drives it | the launcher builds and starts a Linux game the way it starts a Mac one | the launcher starts a game |

M4 is the milestone that carries the risk. Everything before it is mechanical, and M5 and
M6 depend on it.

## The Windows build, WINS and REA

This repository already has a Windows front end (`frontend-qt/nspb_qt/win/`), and there is a
Windows release of the launcher (`NX2Apple.exe`). The engine never runs on Windows: the
Windows path builds an IPA for an iPhone with LLVM-MinGW and Apple's Metal Developer Tools
for Windows, and the game runs on the device.

So the `.exe` holds the launcher and a copy of the engine tree, and nothing of the runtime
that Linux needs. The whole engine is readable as source here, which is why the port does
not need it.

Where the Windows build still helps:

- **An oracle for the build pipeline.** The Windows path reproduces the Mac pipeline step
  by step (the table in `frontend-qt/README.md`). A Linux build path can be checked against
  it.
- **The Metal compiler for Windows** is the only way to get Apple's Metal compiler off a
  Mac. A Linux machine can run it under Wine, so the Linux build path can produce the
  `.metallib` files that the iOS build needs. That is the "build an IPA from Linux" route,
  which is useful and separate from running a game on Linux.
- **REA** on the released `.exe` confirms what the release actually carries (the engine
  tree, its pin, its chain version) and on the Mach-O host binary answers questions the
  source does not. It is a check on the source, not a source of truth for the port.

## Open questions

1. **The first target machine.** A Raspberry Pi 5 (an aarch64 target with a unified memory
   GPU) or an x86_64 desktop with an aarch64 host under qemu-user.
2. **The window system.** X11 first is the smaller job, Wayland needs a different surface
   path.
3. **The sound stack.** PipeWire or ALSA.
4. **The input stack.** SDL (a gamepad database for free) or evdev (a smaller surface).
5. **Whether the Vulkan backend also serves the game's own Vulkan and OpenGL.** On Linux
   the game's Vulkan calls could go to the driver almost unchanged, which would make
   `hle_vk.m` much smaller than a Vulkan on Vulkan layer needs to be.

## The measurements

Every number in this page comes from these commands, run in `engine/` at the pin with the
series applied.

```sh
# the Linux build: the host, static, for aarch64 (zig 0.16, nothing else needed)
cd engine/dm/host && make -f Makefile.linux GAME=010015100B514000
file dmhost_linux     # ARM aarch64, statically linked

# the compatibility layer's own test, cross-built and run under qemu-user
make -f Makefile.linux GAME=<id> test QEMU=/path/to/qemu-aarch64-static

# the Mac build, unchanged
make -C dm/host GAME=<id>

# the sizes in the tables
wc -l dm/gfx/nvn/nvn_mtl.m dm/gfx/vk/hle_vk.m dm/gfx/gl/hle_gl.m dm/gfx/nvn/hle_nvn.c \
      dm/gfx/metal/mtl_backend.m dm/gfx/msl/*.metal dm/gfx/tex/nvn_fmt_mtl.c \
      dm/host/front_mac.m dm/host/controllers_mac.m dm/host/haptics_apple.m dm/host/web_apple.m
cat dm/host/*.c dm/host/*.h | wc -l

# the Metal surface
grep -oE "MTL[A-Za-z0-9_]+" dm/gfx/nvn/nvn_mtl.m | sort | uniq -c | sort -rn | head -40

# the Apple headers in the host
for f in dm/host/*.c dm/host/*.m dm/host/*.h; do
  n=$(grep -cE '#import <(Foundation|AppKit|CoreFoundation|AudioToolbox|CoreHaptics|GameController|Metal|IOKit|CoreAudio|CoreMedia|VideoToolbox|CommonCrypto|os|dispatch)|TargetConditionals\.h|pthread_jit_write_protect_np|MAP_JIT|os_unfair_lock|dispatch_' "$f")
  [ "$n" -gt 0 ] && printf "%5s  %s\n" "$n" "$f"
done | sort -rn

The Linux build no longer shows its blockers one file at a time: `make -f dm/host/Makefile.linux`
builds the whole host and reports what is missing, which is the same information with nothing
guessed. The signals it reported when this page was written (the Apple headers, the Mach
sections of the registry) are gone: the layer under `dm/host/linux` answers them.
```
