"""Offline NRO boot-stub (`nxboot`) decoder for Windows builds.

Games such as *Mario Tennis Fever* (`0400D4201C6EA000`) ship an `ExeFS/main` boot stub (`nxboot`)
whose `.data` segment holds the game's 24.7 MB NRO split across multiple scrambled and LZ-packed
streams. At launch `nnMain` spawns worker threads (`nn::os::CreateThread`) that synchronize on two
`nn::os::BarrierType` barriers:
  1. Each worker unscrambles its stream's 4-byte uncompressed length into `sizes[i]` and waits on
     the first barrier.
  2. Worker 0 sums `sizes[0..n-1]`, allocates the output buffer via
     `nn::mem::StandardAllocator::Allocate`, and all workers wait on the second barrier.
  3. Each worker independently unscrambles and decompresses its stream into its slice
     `out_buf + sum(sizes[0..i-1])`, after which `nnMain` registers the RomFS `.nrr` and passes
     `out_buf` to `nn::ro::LoadModule`.

On macOS upstream boots the rewritten modules in `dmhost` with `DM_NRO_CAPTURE`. On Windows we load
`ExeFS/main` directly into `arm64_emu.Machine` (Unicorn), collect the worker thread entry points
from `nnMain`, run the pre-barrier size pass, and execute the worker streams in parallel across
isolated `Machine` instances to produce the exact NRO image verified against `missing.tsv`.
"""
from __future__ import annotations

import concurrent.futures
import hashlib
import os
import struct
from pathlib import Path
from typing import Callable

from . import arm64_emu as E


class _BootNroMachine(E.Machine):
    """`arm64_emu.Machine` with per-instance `nn::os` / `nn::ro` traps for `nxboot` stubs."""

    def __init__(self, modules, *, heap_size: int = 16 * 1024 * 1024, pre_relocated: dict | None = None):
        self.entries: list[int] = []
        self.stop_at_barrier: bool = False
        self.TRAPS = dict(E.Machine.TRAPS)
        self.TRAPS['_ZN2nn2os13GetSystemTickEv'] = self._noop
        self.TRAPS['_ZN2nn2os17InitializeBarrierEPNS0_11BarrierTypeEi'] = self._noop
        self.TRAPS['_ZN2nn2os15FinalizeBarrierEPNS0_11BarrierTypeE'] = self._noop
        self.TRAPS['_ZN2nn2os12CreateThreadEPNS0_10ThreadTypeEPFvPvES3_S3_mii'] = self._on_create_thread
        self.TRAPS['_ZN2nn2os11StartThreadEPNS0_10ThreadTypeE'] = self._noop
        self.TRAPS['_ZN2nn2fs12SetAllocatorEPFPvmEPFvS1_mE'] = self._noop
        self.TRAPS['_ZN2nn2ro10InitializeEv'] = self._on_stop_main
        self.TRAPS['_ZN2nn2ro18RegisterModuleInfoEPNS0_16RegistrationInfoEPKv'] = self._on_stop_main
        self.TRAPS['_ZN2nn2ro10LoadModuleEPNS0_6ModuleEPKvPvmi'] = self._on_stop_main
        self.TRAPS['_ZN2nn2os12AwaitBarrierEPNS0_11BarrierTypeE'] = self._on_await_barrier
        super().__init__(modules, heap_size=heap_size, pre_relocated=pre_relocated)

    @staticmethod
    def _noop(_m: E.Machine) -> int:
        return 0

    def _on_create_thread(self, _m: E.Machine) -> int:
        func = self.x(1)
        if func:
            self.entries.append(func)
        return 0

    def _on_stop_main(self, _m: E.Machine) -> int:
        self.uc.reg_write(E.UC_ARM64_REG_LR, E.STOP)
        return 0

    def _on_await_barrier(self, _m: E.Machine) -> int:
        if self.stop_at_barrier:
            self.uc.reg_write(E.UC_ARM64_REG_LR, E.STOP)
        return 0


def decode_boot_nro(
    main_path: str | Path,
    *,
    max_workers: int | None = None,
) -> bytes:
    """Decode an embedded NRO image from an `nxboot` `ExeFS/main` module in Unicorn."""
    p = Path(main_path)
    if not p.is_file():
        raise E.EmuError(f'{p}: main NSO not found')

    m0 = _BootNroMachine([('main', p)], heap_size=16 * 1024 * 1024)
    mod0 = m0.mods[0]
    nn_main_off = mod0.exports.get('nnMain')
    if nn_main_off is None:
        raise E.EmuError(f'{p}: nnMain export not found')
    sym_names = {nm for nm, _, _ in mod0.syms}
    if (
        '_ZN2nn2os12CreateThreadEPNS0_10ThreadTypeEPFvPvES3_S3_mii' not in sym_names
        or '_ZN2nn2os12AwaitBarrierEPNS0_11BarrierTypeE' not in sym_names
        or not (
            '_ZN2nn2ro10InitializeEv' in sym_names
            or '_ZN2nn2ro10LoadModuleEPNS0_6ModuleEPKvPvmi' in sym_names
        )
    ):
        raise E.EmuError(f'{p}: not an nxboot NRO loader stub')

    m0.call(mod0.base + nn_main_off, max_insns=10_000_000)
    entries = list(m0.entries)
    n_threads = len(entries)
    if n_threads == 0 or n_threads > 32:
        raise E.EmuError(f'{p}: expected 1..32 nxboot worker threads, found {n_threads}')

    out_buf_ptr = m0.malloc(8)
    sizes_arr = m0.malloc(n_threads * 8)
    sizes_holder = m0.malloc(8)
    barrier_holder = m0.malloc(8)
    barrier_dummy = m0.malloc(64)
    m0.uc.mem_write(sizes_holder, struct.pack('<Q', sizes_arr))
    m0.uc.mem_write(barrier_holder, struct.pack('<Q', barrier_dummy))
    arg0 = m0.malloc(24)
    m0.uc.mem_write(arg0, struct.pack('<3Q', out_buf_ptr, sizes_holder, barrier_holder))

    m0.stop_at_barrier = True
    for entry in entries:
        m0.call(entry, arg0, max_insns=500_000_000)

    sizes = struct.unpack(f'<{n_threads}I', m0.uc.mem_read(sizes_arr, n_threads * 4))
    total_size = sum(sizes)
    if any(s == 0 for s in sizes) or total_size <= 0x80 or total_size > (256 << 20):
        raise E.EmuError(f'{p}: invalid nxboot stream sizes {sizes} (total {total_size})')

    snapshot = m0.export_snapshot()

    def _decode_chunk(idx: int) -> bytes:
        chunk_sz = sizes[idx]
        heap_bytes = E.up(chunk_sz + (4 << 20), 2 << 20)
        mi = _BootNroMachine([], heap_size=heap_bytes, pre_relocated=snapshot)
        mi.stop_at_barrier = False
        ob_ptr = mi.malloc(8)
        sz_arr = mi.malloc(n_threads * 8)
        sz_holder = mi.malloc(8)
        br_holder = mi.malloc(8)
        br_dummy = mi.malloc(64)
        local_sizes = [0] * n_threads
        local_sizes[idx] = chunk_sz
        mi.uc.mem_write(sz_arr, struct.pack(f'<{n_threads}I', *local_sizes))
        mi.uc.mem_write(sz_holder, struct.pack('<Q', sz_arr))
        mi.uc.mem_write(br_holder, struct.pack('<Q', br_dummy))
        if idx != 0:
            chunk_buf = mi.malloc(chunk_sz + 0x1000)
            mi.uc.mem_write(ob_ptr, struct.pack('<Q', chunk_buf))
        arg_i = mi.malloc(24)
        mi.uc.mem_write(arg_i, struct.pack('<3Q', ob_ptr, sz_holder, br_holder))
        mi.call(entries[idx], arg_i, max_insns=500_000_000)
        chunk_buf = struct.unpack('<Q', mi.uc.mem_read(ob_ptr, 8))[0]
        if chunk_buf == 0:
            raise E.EmuError(f'{p}: worker {idx} did not allocate output buffer')
        return bytes(mi.uc.mem_read(chunk_buf, chunk_sz))

    workers = max_workers if max_workers is not None else min(n_threads, os.cpu_count() or 4)
    if workers <= 1 or n_threads == 1:
        chunks = [_decode_chunk(i) for i in range(n_threads)]
    else:
        with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
            chunks = list(pool.map(_decode_chunk, range(n_threads)))

    nro = b''.join(chunks)
    if len(nro) < 0x80 or nro[0x10:0x14] != b'NRO0':
        raise E.EmuError(f'{p}: decoded payload is not an NRO0 image')
    hdr_size = struct.unpack_from('<I', nro, 0x18)[0]
    if hdr_size <= 0 or hdr_size > len(nro):
        raise E.EmuError(f'{p}: NRO0 header size {hdr_size} out of bounds ({len(nro)})')
    return nro[:hdr_size]


def capture_missing_nros(
    exe_dir: str | Path,
    nro_dir: str | Path,
    *,
    say: Callable[[str], None] | None = None,
) -> list[tuple[str, str, int]]:
    """Decode missing runtime NROs listed in `nro_dir/missing.tsv` from `exe_dir/main`.

    Updates `nro.tsv` and `missing.tsv` in `nro_dir` using the exact manifest format written by
    upstream's `capture_nro`, and returns `[(name, sha256, size_bytes), ...]`.
    """
    nd = Path(nro_dir)
    missing = nd / 'missing.tsv'
    if not missing.is_file():
        return []
    want = dict(
        line.split('\t', 1)
        for line in missing.read_text(encoding='utf-8', errors='replace').splitlines()
        if line and '\t' in line
    )
    if not want:
        return []

    main_path = Path(exe_dir) / 'main'
    if say is not None:
        say(
            f'{len(want)} registered NRO(s) in no file: decoding runtime NRO offline from '
            f'{main_path}'
        )
    nro_bytes = decode_boot_nro(main_path)
    sha = hashlib.sha256(nro_bytes).hexdigest()
    if sha not in want:
        raise E.EmuError(
            f'decoded NRO SHA-256 {sha} is not in {missing} (expected {next(iter(want))})'
        )

    manifest = nd / 'nro.tsv'
    rows = (
        [
            line
            for line in manifest.read_text(encoding='utf-8', errors='replace').splitlines()
            if line
        ]
        if manifest.is_file()
        else ['# name\tsha256\tsize\tnrr\twhere']
    )
    name = f'nro{sum(1 for line in rows if not line.startswith(("#", "refused")))}'
    final_nro = nd / f'{name}.nro'
    tmp_nro = nd / f'{name}.nro.partial'
    try:
        tmp_nro.write_bytes(nro_bytes)
        os.replace(tmp_nro, final_nro)
    except BaseException:
        if tmp_nro.exists():
            tmp_nro.unlink(missing_ok=True)
        raise

    nrr_name = want.pop(sha)
    rows.append(f'{name}\t{sha}\t{len(nro_bytes)}\t{nrr_name}\tcapture')
    manifest.write_text('\n'.join(rows) + '\n', encoding='utf-8')
    missing.write_text(''.join(f'{h}\t{n}\n' for h, n in want.items()), encoding='utf-8')
    return [(name, sha, len(nro_bytes))]
