"""Regression tests for dynamic heap growth in `nspb_qt.win.arm64_emu` and `oodle_emu` (#1472)."""
from __future__ import annotations

import struct
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from nspb_qt.win import arm64_emu as E
from nspb_qt.win import oodle_emu as OE


def _make_minimal_nso(
    exports: dict[str, int] | None = None,
    code_words: list[int] | None = None,
    rodata_extra: bytes = b'',
) -> bytes:
    """Build a minimal uncompressed NSO0 binary for Unicorn heap tests."""
    words = code_words or [0xD2800000, 0xD65F03C0]  # mov x0, #0 / ret
    text_prefix = bytearray(0x20)
    text_raw = bytes(text_prefix) + struct.pack(f'<{len(words)}I', *words)
    mod0_off = len(text_raw)
    text_seg = bytearray(text_raw.ljust(0x200, b'\x00'))

    ro_off = 0x1000
    strtab_buf = bytearray(b'\x00')
    sym_entries = [struct.pack('<IBBHQQ', 0, 0, 0, 0, 0, 0)]
    for name, fn_off in (exports or {}).items():
        nm_idx = len(strtab_buf)
        strtab_buf.extend(name.encode('ascii') + b'\x00')
        sym_entries.append(struct.pack('<IBBHQQ', nm_idx, 0x12, 0, 1, 0x20 + fn_off, 8))
    while len(strtab_buf) % 8:
        strtab_buf.append(0)
    dynsym_bytes = b''.join(sym_entries)
    symtab_off = ro_off
    strtab_off = ro_off + len(dynsym_bytes)
    ro_body = dynsym_bytes + bytes(strtab_buf) + rodata_extra
    ro_seg = ro_body.ljust(max(0x400, E.up(len(ro_body), 0x100)), b'\x00')

    data_off = ro_off + E.up(len(ro_seg), 0x1000)
    dyn_entries = [
        struct.pack('<qQ', 6, symtab_off),  # DT_SYMTAB
        struct.pack('<qQ', 5, strtab_off),  # DT_STRTAB
        struct.pack('<qQ', 0, 0),           # DT_NULL
    ]
    data_seg = b''.join(dyn_entries).ljust(0x200, b'\x00')

    struct.pack_into('<I', text_seg, 4, mod0_off)
    struct.pack_into(
        '<4siiiiii',
        text_seg,
        mod0_off,
        b'MOD0',
        data_off - mod0_off,
        data_off + len(data_seg) - mod0_off,
        data_off + len(data_seg) - mod0_off,
        0,
        0,
        0,
    )

    hdr = bytearray(0x100)
    hdr[:4] = b'NSO0'
    f_text = 0x100
    f_ro = f_text + len(text_seg)
    f_data = f_ro + len(ro_seg)
    struct.pack_into('<III', hdr, 0x10, f_text, 0, len(text_seg))
    struct.pack_into('<III', hdr, 0x20, f_ro, ro_off, len(ro_seg))
    struct.pack_into('<III', hdr, 0x30, f_data, data_off, len(data_seg))
    struct.pack_into('<I', hdr, 0x3C, 0x100)
    struct.pack_into('<III', hdr, 0x60, len(text_seg), len(ro_seg), len(data_seg))
    return bytes(hdr) + bytes(text_seg) + ro_seg + data_seg


def _vm_heap_limit(m: E.Machine) -> int:
    return struct.unpack('<Q', m.uc.mem_read(E.HEAP_CTL_ADDR + 8, 8))[0]


class Arm64HeapGrowthTests(unittest.TestCase):
    """Verify on-demand heap expansion, shrink-on-reset, overflow guards, and Oodle timeout scaling."""

    def setUp(self) -> None:
        self._td = tempfile.TemporaryDirectory()
        self.mod_path = Path(self._td.name) / 'main'
        self.mod_path.write_bytes(_make_minimal_nso({'dummy': 0}))

    def tearDown(self) -> None:
        self._td.cleanup()

    def test_large_oodle_request_grows_past_96mb_and_shrinks_on_reset(self) -> None:
        """Reproduce #1472: 40 MiB permanent buffers + 21 MB input + 70.8 MB output (> 96 MiB)."""
        self.assertTrue(E._HAS_UNICORN and E.Uc is not None, 'unicorn is required')
        m = E.Machine([('main', self.mod_path)], use_fast_stubs=True)
        init_size = m.heap_size
        self.assertEqual(init_size, 96 << 20)
        init_limit = E.HEAP_BASE + init_size
        self.assertEqual(m.heap_limit, init_limit)
        self.assertEqual(_vm_heap_limit(m), init_limit)

        # Mirror Decoder._alloc_buffers permanent allocations (~40 MiB + 80 B)
        m.malloc(16 << 20)
        m.malloc(8 << 20)
        m.malloc(16 << 20)
        m.malloc(16)
        mark = m.heap_mark()

        # Request #9895 from issue #1472: 21,009,849 B compressed -> 70,786,896 B raw (+ 64 KiB slack)
        comp_len = 21_009_849
        raw_len = 70_786_896
        c_ptr = m.malloc(comp_len)
        r_ptr = m.malloc(raw_len + 0x10000)

        self.assertGreater(m.heap_size, init_size)
        self.assertEqual(m.heap_limit, E.HEAP_BASE + m.heap_size)
        self.assertEqual(_vm_heap_limit(m), m.heap_limit)
        self.assertLessEqual(r_ptr + raw_len + 0x10000, m.heap_limit)

        # Verify contiguous read/write across the original 96 MiB boundary
        boundary_off = init_limit - r_ptr - 8
        self.assertGreaterEqual(boundary_off, 0)
        sentinel = b'CROSS_96MB_BOUND'
        m.write(r_ptr + boundary_off, sentinel)
        self.assertEqual(m.read(r_ptr + boundary_off, len(sentinel)), sentinel)
        m.write(c_ptr, b'IN_HEAD')
        self.assertEqual(m.read(c_ptr, 7), b'IN_HEAD')

        # Reset back to permanent mark must unmap extra segments and restore VM limit
        m.heap_reset(mark)
        self.assertEqual(m.heap_size, init_size)
        self.assertEqual(m.heap_limit, init_limit)
        self.assertEqual(_vm_heap_limit(m), init_limit)

        # Subsequent large allocation must be able to grow again cleanly
        r_ptr2 = m.malloc(raw_len + 0x10000)
        self.assertGreater(m.heap_size, init_size)
        m.write(r_ptr2 + raw_len - 8, b'REMAP_OK')
        self.assertEqual(m.read(r_ptr2 + raw_len - 8, 8), b'REMAP_OK')

    def test_in_vm_fast_stub_malloc_syncs_limit_and_stays_on_fast_path(self) -> None:
        """Guest malloc overflowing initial heap grows via slow trap and updates HEAP_CTL_ADDR + 8."""
        self.assertTrue(E._HAS_UNICORN and E.Uc is not None, 'unicorn is required')
        with mock.patch.object(E, 'HEAP_GROW_STEP', 2 << 20):
            m = E.Machine(
                [('main', self.mod_path)],
                heap_size=2 << 20,
                max_heap_size=16 << 20,
                use_fast_stubs=True,
            )
            slow_calls = 0
            orig_malloc = E._DEFAULT_TRAPS['malloc']

            def counting_malloc(mach: E.Machine) -> int:
                nonlocal slow_calls
                slow_calls += 1
                return orig_malloc(mach)  # type: ignore[operator]

            m.TRAPS = dict(E.Machine.TRAPS)
            m.TRAPS['malloc'] = counting_malloc

            # Fill most of the initial 2 MiB heap
            m.malloc((2 << 20) - 0x4000)
            init_limit = m.heap_limit

            # Guest fast stub malloc crosses 2 MiB -> traps once into slow_malloc and grows
            p1 = m.call_fast(E.FAST_STUB_ADDRS['malloc'], 0x10000)
            self.assertEqual(slow_calls, 1)
            self.assertGreater(m.heap_limit, init_limit)
            self.assertEqual(_vm_heap_limit(m), m.heap_limit)

            # Guest writes across the original 2 MiB boundary via fast memset/memcmp
            cross_addr = init_limit - 16
            self.assertGreaterEqual(cross_addr, p1)
            m.call_fast(E.FAST_STUB_ADDRS['memset'], cross_addr, 0x5A, 64)
            self.assertEqual(m.read(cross_addr, 64), b'\x5A' * 64)

            # Next guest malloc fits inside the newly grown region and must stay on fast path
            p2 = m.call_fast(E.FAST_STUB_ADDRS['malloc'], 0x2000)
            self.assertEqual(slow_calls, 1, 'second malloc should use updated HEAP_CTL_ADDR + 8 without trapping')
            self.assertGreaterEqual(p2, p1 + 0x10000)

            # Slow-path calloc crossing another boundary must grow and zero memory
            p3 = m.call_fast(E.FAST_STUB_ADDRS['calloc'], 1, 2 << 20)
            self.assertGreaterEqual(m.heap_size, 6 << 20)
            self.assertEqual(m.read(p3, 32), b'\x00' * 32)
            self.assertEqual(m.read(p3 + (2 << 20) - 32, 32), b'\x00' * 32)

    def test_validation_overflow_and_trap_error_handling(self) -> None:
        """Negative sizes, non-power-of-two aligns, max_heap_size cap, and calloc overflow fail cleanly."""
        self.assertTrue(E._HAS_UNICORN and E.Uc is not None, 'unicorn is required')
        with mock.patch.object(E, 'HEAP_GROW_STEP', 2 << 20):
            m = E.Machine(
                [('main', self.mod_path)],
                heap_size=2 << 20,
                max_heap_size=4 << 20,
                use_fast_stubs=True,
            )
            limit_before = m.heap_limit
            top_before = m.heap_mark()

            # Negative size and non-power-of-two alignments (both < 16 and > 16)
            with self.assertRaises(E.EmuError):
                m.malloc(-1)
            for bad_align in (-16, 0, 3, 6, 12, 24, 48):
                with self.assertRaises(E.EmuError, msg=f'align={bad_align} must be rejected'):
                    m.malloc(64, align=bad_align)

            # Valid power-of-two alignments (< 16 promoted to 16, > 16 honored)
            for ok_align in (1, 2, 4, 8, 16, 4096):
                ptr = m.malloc(32, align=ok_align)
                self.assertEqual(ptr % max(ok_align, 16), 0)

            # Exceeding max_heap_size or passing huge 64-bit size must not mutate limit
            limit_snap = m.heap_limit
            top_snap = m.heap_mark()
            for huge in (5 << 20, (1 << 63) - 1, (1 << 64) - 1):
                with self.assertRaises(E.EmuError):
                    m.malloc(huge)
            self.assertEqual(m.heap_limit, limit_snap)
            self.assertEqual(_vm_heap_limit(m), limit_snap)
            self.assertEqual(m.heap_mark(), top_snap)

            # Guest-triggered trap failures must be captured cleanly via _on_trap -> m.fault
            with self.assertRaises(E.EmuError) as ctx_oom:
                m.call_fast(E.FAST_STUB_ADDRS['malloc'], 8 << 20)
            self.assertIn('heap full', str(ctx_oom.exception).lower())

            with self.assertRaises(E.EmuError) as ctx_ovf:
                m.call_fast(E.FAST_STUB_ADDRS['calloc'], 1 << 40, 1 << 30)
            self.assertIn('overflow', str(ctx_ovf.exception).lower())

            aligned_trap = m.trap('aligned_alloc')
            with self.assertRaises(E.EmuError) as ctx_align:
                m.call_fast(aligned_trap, 3, 64)
            self.assertIn('alignment', str(ctx_align.exception).lower())

            self.assertEqual(m.heap_limit, limit_before)
            self.assertEqual(_vm_heap_limit(m), limit_before)
            self.assertGreaterEqual(m.heap_mark(), top_before)

            # Invalid Machine heap_size / max_heap_size arguments fail cleanly
            for kw in (
                {'heap_size': 0},
                {'heap_size': -4096},
                {'max_heap_size': 0},
                {'max_heap_size': -4096},
                {'max_heap_size': (E.STACK_TOP - E.STACK_SIZE) - E.HEAP_BASE + E.PAGE},
            ):
                with self.assertRaises(E.EmuError, msg=f'expected EmuError for {kw}'):
                    E.Machine([('main', self.mod_path)], **kw)  # type: ignore[arg-type]

            # realloc across the initial heap boundary preserves existing bytes
            p_old = m.malloc(128)
            payload = bytes(range(128))
            m.write(p_old, payload)
            realloc_trap = m.trap('realloc')
            p_new = m.call_fast(realloc_trap, p_old, 3 << 20)
            self.assertEqual(m.heap_size, 4 << 20)
            self.assertEqual(m.read(p_new, 128), payload)

    def test_heap_reset_partial_shrink_preserves_mark_and_rejects_out_of_bounds(self) -> None:
        """Resetting to a mark inside an expanded segment unmaps only higher segments."""
        self.assertTrue(E._HAS_UNICORN and E.Uc is not None, 'unicorn is required')
        with mock.patch.object(E, 'HEAP_GROW_STEP', 2 << 20):
            m = E.Machine(
                [('main', self.mod_path)],
                heap_size=2 << 20,
                max_heap_size=16 << 20,
                use_fast_stubs=True,
            )
            # Out-of-bounds reset marks are rejected
            with self.assertRaises(E.EmuError):
                m.heap_reset(E.HEAP_BASE - 16)
            with self.assertRaises(E.EmuError):
                m.heap_reset(m.heap_limit + 16)

            # Grow to 4 MiB, write persistent data, take warm_mark inside the 2..4 MiB segment
            p_warm = m.malloc(3 << 20)
            self.assertEqual(m.heap_size, 4 << 20)
            m.write(p_warm + (3 << 20) - 8, b'WARM_OK!')
            warm_mark = m.heap_mark()

            # Grow further to 8 MiB
            m.malloc(3 << 20)
            self.assertEqual(m.heap_size, 8 << 20)

            # Reset to warm_mark must keep the 2..4 MiB segment intact while unmapping 4..8 MiB
            m.heap_reset(warm_mark)
            self.assertEqual(m.heap_size, 4 << 20)
            self.assertEqual(_vm_heap_limit(m), E.HEAP_BASE + (4 << 20))
            self.assertEqual(m.read(p_warm + (3 << 20) - 8, 8), b'WARM_OK!')

    def test_heap_reset_tolerates_mock_uc_without_mem_unmap(self) -> None:
        """Mock Uc backends lacking mem_unmap (CI fallback stubs) still grow and reset safely."""
        class _NoUnmapUc:
            def __init__(self, _arch: int, _mode: int) -> None:
                self.segs: list[tuple[int, bytearray]] = []
                self.regs: dict[int, int] = {}

            def mem_map(self, addr: int, size: int, _prot: int = 7) -> None:
                self.segs.append((addr, bytearray(size)))

            def mem_write(self, addr: int, data: bytes) -> None:
                rem = memoryview(data)
                cur = addr
                while rem:
                    for base, buf in self.segs:
                        if base <= cur < base + len(buf):
                            off = cur - base
                            take = min(len(rem), len(buf) - off)
                            buf[off:off + take] = rem[:take]
                            rem = rem[take:]
                            cur += take
                            break
                    else:
                        raise RuntimeError(f'unmapped {cur:#x}')

            def mem_read(self, addr: int, size: int) -> bytearray:
                out = bytearray()
                cur = addr
                left = size
                while left:
                    for base, buf in self.segs:
                        if base <= cur < base + len(buf):
                            off = cur - base
                            take = min(left, len(buf) - off)
                            out.extend(buf[off:off + take])
                            cur += take
                            left -= take
                            break
                    else:
                        raise RuntimeError(f'unmapped {cur:#x}')
                return out

            def reg_write(self, reg: int, val: int) -> None:
                self.regs[reg] = val & 0xFFFFFFFFFFFFFFFF

            def reg_read(self, reg: int) -> int:
                return self.regs.get(reg, 0)

            def hook_add(self, *_a, **_kw) -> int:
                return 1

        with mock.patch.object(E, '_HAS_UNICORN', True), \
                mock.patch.object(E, 'Uc', _NoUnmapUc), \
                mock.patch.object(E, 'HEAP_GROW_STEP', 2 << 20):
            m = E.Machine([('main', self.mod_path)], heap_size=2 << 20, max_heap_size=8 << 20)
            mark = m.heap_mark()
            ptr = m.malloc(3 << 20)
            self.assertEqual(m.heap_size, 4 << 20)
            m.write(ptr + (3 << 20) - 4, b'MOCK')
            self.assertEqual(m.read(ptr + (3 << 20) - 4, 4), b'MOCK')
            # Without mem_unmap, heap_reset resets top cleanly without failing
            m.heap_reset(mark)
            self.assertEqual(m.heap_mark(), mark)
            self.assertEqual(m.heap_size, 4 << 20)

    def test_oodle_timeout_scales_with_output_size_and_decoder_shrinks_after_large_run(self) -> None:
        """Large Oodle requests scale timeout_us and shrink the emulator heap right after completion."""
        self.assertEqual(OE._call_timeout_us(0), E.DEFAULT_CALL_TIMEOUT_US)
        self.assertEqual(OE._call_timeout_us(512 << 10), E.DEFAULT_CALL_TIMEOUT_US)
        self.assertGreater(OE._call_timeout_us(70_786_896), E.DEFAULT_CALL_TIMEOUT_US)
        self.assertEqual(OE._call_timeout_us(70_786_896), (30 + (70_786_896 >> 20)) * 1_000_000)
        self.assertEqual(OE._call_timeout_us(1 << 30), OE._MAX_CALL_TIMEOUT_US)

        # Verify Decoder.run passes scaled timeout_us and shrinks heap in finally
        self.assertTrue(E._HAS_UNICORN and E.Uc is not None, 'unicorn is required')
        with mock.patch.object(E, 'HEAP_GROW_STEP', 2 << 20):
            dec = object.__new__(OE.Decoder)
            dec.native_dll = None
            dec.kind = 'OodleLZ_Decompress'
            dec.fn = 0x0800_0020
            dec.lzd = None
            dec.m = E.Machine([('main', self.mod_path)], heap_size=2 << 20, max_heap_size=16 << 20)
            dec.scratch_n = 0x10000
            dec.scratch = dec.m.malloc(dec.scratch_n)
            dec.in_cap = 0x10000
            dec.in_buf = dec.m.malloc(dec.in_cap)
            dec.out_cap = 0x10000
            dec.out_buf = dec.m.malloc(dec.out_cap)
            dec.lzd_out = dec.m.malloc(16)
            dec.mark = dec.m.heap_mark()
            dec._oodle_stack = struct.pack('<6Q', 0, 0, 0, dec.scratch, dec.scratch_n, 3)

            seen_timeouts: list[int] = []
            peak_heap_sizes: list[int] = []

            def fake_call_fast(_fn, _c, _cl, r, rl, *_args, timeout_us=E.DEFAULT_CALL_TIMEOUT_US, **_kw):
                seen_timeouts.append(timeout_us)
                peak_heap_sizes.append(dec.m.heap_size)
                dec.m.write(r, b'X' * rl)
                return rl

            rl = 3 << 20
            with mock.patch.object(dec.m, 'call_fast', side_effect=fake_call_fast):
                out = dec.run(b'COMP' * 1024, rl)

            self.assertEqual(out, b'X' * rl)
            self.assertEqual(seen_timeouts, [OE._call_timeout_us(rl)])
            self.assertGreater(peak_heap_sizes[0], 2 << 20)
            # Heap shrunk back to initial 2 MiB immediately after Decoder.run finished
            self.assertEqual(dec.m.heap_size, 2 << 20)
            self.assertEqual(_vm_heap_limit(dec.m), E.HEAP_BASE + (2 << 20))

            # Even when emulation raises EmuError after growing, finally must still shrink back
            with mock.patch.object(dec.m, 'call_fast', side_effect=E.EmuError('boom')):
                with self.assertRaises(E.EmuError):
                    dec.run(b'COMP' * 1024, rl)
            self.assertEqual(dec.m.heap_size, 2 << 20)
            self.assertEqual(_vm_heap_limit(dec.m), E.HEAP_BASE + (2 << 20))

            # Streaming lzd_run also receives scaled timeout_us and can grow scratch beyond initial heap
            dec.kind = 'OodleLZDecoder_DecodeSome'
            dec.lzd = (0x1000, 0x2000, 0x3000, 0x4000)
            lzd_timeouts: list[int] = []

            def fake_lzd_call(fn, *args, timeout_us=E.DEFAULT_CALL_TIMEOUT_US, **_kw):
                if fn == 0x1000:  # size
                    return 3 << 20
                if fn == 0x2000:  # create
                    return args[2]
                if fn == 0x4000:  # some
                    lzd_timeouts.append(timeout_us)
                    out_ptr = args[1]
                    r_ptr = args[2]
                    want_rl = args[4]
                    dec.m.write(r_ptr, b'Z' * want_rl)
                    dec.m.write(out_ptr, struct.pack('<ii', want_rl, 4))
                    return 1
                return 0

            with mock.patch.object(dec.m, 'call_fast', side_effect=fake_lzd_call):
                lzd_out = dec.run(b'\x8C\x06\x00\x00', 2 << 20)
            self.assertEqual(lzd_out, b'Z' * (2 << 20))
            self.assertEqual(lzd_timeouts, [OE._call_timeout_us(2 << 20)])
            self.assertEqual(dec.m.heap_size, 2 << 20)
            self.assertEqual(_vm_heap_limit(dec.m), E.HEAP_BASE + (2 << 20))


if __name__ == '__main__':
    unittest.main()
