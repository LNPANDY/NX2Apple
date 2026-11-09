"""Tests for `nspb_qt.win.glslc_emu` and `driver.capture_glslc` offline compilation."""
from __future__ import annotations

import struct
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from nspb_qt.win import arm64_emu as E
from nspb_qt.win import driver, glslc_emu


def _make_synthetic_nso(exports: dict[str, int], code_words: list[int] | None = None) -> bytes:
    """Build a minimal uncompressed NSO0 binary exporting `exports` (`{name: offset}`)."""
    words = code_words or [0xD2800020, 0xD65F03C0]  # mov w0, #1; ret
    text_prefix = bytearray(0x20)
    text_raw = bytes(text_prefix) + struct.pack(f'<{len(words)}I', *words)
    mod0_off = len(text_raw)
    text_seg = bytearray(text_raw.ljust(0x200, b'\x00'))

    # Build .dynstr and .dynsym inside rodata (at memory offset 0x1000)
    ro_off = 0x1000
    strtab_buf = bytearray(b'\x00')
    sym_entries = [struct.pack('<IBBHQQ', 0, 0, 0, 0, 0, 0)]
    for name, fn_off in exports.items():
        nm_idx = len(strtab_buf)
        strtab_buf.extend(name.encode('ascii') + b'\x00')
        sym_entries.append(struct.pack('<IBBHQQ', nm_idx, 0x12, 0, 1, 0x20 + fn_off, 8))
    while len(strtab_buf) % 8:
        strtab_buf.append(0)
    dynsym_bytes = b''.join(sym_entries)
    symtab_off = ro_off
    strtab_off = ro_off + len(dynsym_bytes)
    ro_seg = (dynsym_bytes + bytes(strtab_buf)).ljust(0x400, b'\x00')

    # Build .dynamic inside data segment (at memory offset 0x2000)
    data_off = 0x2000
    dyn_entries = [
        struct.pack('<qQ', 6, symtab_off),  # DT_SYMTAB
        struct.pack('<qQ', 5, strtab_off),  # DT_STRTAB
        struct.pack('<qQ', 0, 0),           # DT_NULL
    ]
    data_seg = b''.join(dyn_entries).ljust(0x200, b'\x00')

    # Fill MOD0 at `mod0_off` in text_seg
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
    struct.pack_into('<I', hdr, 0x0C, 0)  # uncompressed segments
    f_text = 0x100
    f_ro = f_text + len(text_seg)
    f_data = f_ro + len(ro_seg)
    struct.pack_into('<III', hdr, 0x10, f_text, 0, len(text_seg))
    struct.pack_into('<III', hdr, 0x20, f_ro, ro_off, len(ro_seg))
    struct.pack_into('<III', hdr, 0x30, f_data, data_off, len(data_seg))
    struct.pack_into('<I', hdr, 0x3C, 0x100)  # bss
    struct.pack_into('<III', hdr, 0x60, len(text_seg), len(ro_seg), len(data_seg))
    return bytes(hdr) + bytes(text_seg) + ro_seg + data_seg


def _make_nro_image(payload: bytes) -> bytes:
    """Wrap `payload` in a valid Switch NRO0 header."""
    body = bytearray(0x80) + bytearray(payload)
    while len(body) % 16:
        body.append(0)
    body[0x10:0x14] = b'NRO0'
    struct.pack_into('<I', body, 0x18, len(body))
    return bytes(body)


def _make_glslc_blob(tag: bytes = b'test') -> bytes:
    """Construct a valid GLSLC output blob (`magic=0x19866891`, total size at `+0x44`)."""
    total = 0x80 + len(tag)
    buf = bytearray(total)
    struct.pack_into('<I', buf, 0x00, glslc_emu.GLSLC_MAGIC)
    struct.pack_into('<I', buf, 0x44, total)
    buf[0x80:] = tag
    return bytes(buf)


class GlslcEmuUnitTests(unittest.TestCase):
    def test_fnv1a_and_stage_detection(self) -> None:
        blob = _make_glslc_blob(b'portal_shader')
        h = glslc_emu.fnv1a_64(blob)
        self.assertIsInstance(h, int)
        self.assertEqual(len(f'{h:016x}'), 16)

        vs = b'#version 450\nvoid main() { gl_Position = vec4(0.0); }\x00'
        vs_comment = b'//GLSLvp\n#version 440\nvoid main() {}\x00'
        fs = b'#version 450\nout vec4 c;\nvoid main() { c = vec4(1.0); }\x00'
        cs = b'#version 450\nlayout(local_size_x = 64) in;\nvoid main() {}\x00'
        self.assertEqual(glslc_emu.stage_of(vs), 0)
        self.assertEqual(glslc_emu.stage_of(vs_comment), 0)
        self.assertEqual(glslc_emu.stage_of(fs), 1)
        self.assertEqual(glslc_emu.stage_of(cs), 5)

    def test_extract_glsl_sources_skips_preamble_without_main(self) -> None:
        preamble = b'#version 450\n#define FLOAT float\x00'
        valid_vs = b'//GLSLvp\n#version 440\nvoid main() { gl_Position = vec4(1.0); }\x00'
        valid_fs = b'#version 440 core\nout vec4 col;\nvoid main() { col = vec4(1.0); }\x00'
        img = b'\x00' * 16 + preamble + b'\x00' * 8 + valid_vs + b'\x00' * 8 + valid_fs
        extracted = glslc_emu.extract_glsl_sources(img)
        self.assertEqual(extracted, [valid_vs, valid_fs])

    def test_collect_nro_programs_pairs_vs_with_adjacent_fs_only(self) -> None:
        vs1 = b'#version 440 core\nvoid main() { gl_Position = vec4(0.0); }\x00'
        fs1 = b'#version 440 core\nout vec4 c;\nvoid main() { c = vec4(1.0); }\x00'
        fs2 = b'#version 440 core\nout vec4 c;\nvoid main() { c = vec4(0.5); }\x00'
        vs2 = b'//GLSLvp\n#version 440\nvoid main() { gl_Position = vec4(1.0); }\x00'
        fs3 = b'//GLSLfp\n#version 440\nout vec4 c;\nvoid main() { c = vec4(0.2); }\x00'
        distant_fs = b'//GLSLfp\n#version 440\nout vec4 c;\nvoid main() { c = vec4(0.0); }\x00'

        payload = (
            b'glslcCompile\x00CShaderDeviceMgr\x00'
            + vs1 + b'\x00' * 4 + fs1 + b'\x00' * 4 + fs2 + b'\x00' * 8
            + vs2 + b'\x00' * 4 + fs3
            + b'\x00' * 0x800  # > 0x400 gap: separate translation unit
            + distant_fs
        )
        nro = _make_nro_image(payload)
        jobs = glslc_emu.collect_nro_programs(nro)
        self.assertEqual(len(jobs), 4)
        self.assertEqual(jobs[0], ((vs1, fs1), (0, 1), True))
        self.assertEqual(jobs[1], ((vs1, fs2), (0, 1), True))
        self.assertEqual(jobs[2], ((vs2, fs3), (0, 1), True))
        self.assertEqual(jobs[3], ((distant_fs,), (1,), True))

        # Unpaired VS followed by a distant FS emits both single-stage shaders
        unpaired_payload = (
            b'glslcCompile\x00CShaderDeviceMgr\x00'
            + vs1
            + b'\x00' * 0x800
            + distant_fs
        )
        self.assertEqual(
            glslc_emu.collect_nro_programs(_make_nro_image(unpaired_payload)),
            [((vs1,), (0,), True), ((distant_fs,), (1,), True)],
        )

        # Corrupt / non-NRO or NRO without glslcCompile returns empty
        self.assertEqual(glslc_emu.collect_nro_programs(b'not_an_nro'), [])
        self.assertEqual(glslc_emu.collect_nro_programs(_make_nro_image(vs1 + fs1)), [])

    def test_collect_main_and_romfs_programs(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            tpath = Path(td)
            vs = b'#version 450\nvoid main() { gl_Position = vec4(0.0); }\x00'
            fs = b'#version 450\nout vec4 c;\nvoid main() { c = vec4(1.0); }\x00'
            main_file = tpath / 'main'
            main_file.write_bytes(b'glslcCompile\x00' + vs + b'\x00' * 8 + fs + b'\x00' * 8 + vs)
            jobs = glslc_emu.collect_main_programs(main_file)
            self.assertEqual(jobs, [((vs,), (0,), False), ((fs,), (1,), False)])

            romfs = tpath / 'RomFS' / 'shaders'
            romfs.mkdir(parents=True)
            (romfs / 'test.vert').write_bytes(vs[:-1])
            (romfs / 'encrypted.frag').write_bytes(b'\x01\x02\x03\x00cipher')
            r_jobs = glslc_emu.collect_romfs_glsl_programs(tpath / 'RomFS')
            self.assertEqual(r_jobs, [((vs,), (0,), False)])

    def test_c99_negative_precision_in_format_c(self) -> None:
        class _DummyMachine:
            class _Uc:
                def mem_read(self, addr: int, size: int) -> bytes:
                    s = b'NV_bindless_texture\x00'
                    off = addr - 0x1000
                    return s[off:off + size].ljust(size, b'\x00')
            uc = _Uc()

        class _FakeArgs:
            def __init__(self) -> None:
                self.vals = [0xFFFFFFFF, 0x1000]  # prec = -1 (32-bit), str_ptr = 0x1000

            def next_int(self) -> int:
                return self.vals.pop(0)

            def next_double(self) -> float:
                return 0.0

        res = glslc_emu._format_c(_DummyMachine(), b'-po %0.*s', _FakeArgs())  # type: ignore[arg-type]
        self.assertEqual(res, b'-po NV_bindless_texture')

    def test_find_glslc_nso_in_exefs(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            exefs = Path(td) / 'ExeFS'
            exefs.mkdir()
            (exefs / 'main').write_bytes(_make_synthetic_nso({'nnMain': 0}))
            (exefs / 'subsdk0').write_bytes(_make_synthetic_nso({'movieInit': 0}))
            (exefs / 'subsdk1').write_bytes(
                _make_synthetic_nso({'glslcInitialize': 0, 'glslcCompile': 4})
            )
            found = glslc_emu.find_glslc_nso(exefs)
            self.assertEqual(found, exefs / 'subsdk1')

    def test_driver_capture_glslc_reuses_and_compiles_offline_and_cleans_up_on_failure(self) -> None:
        repo = driver.repo_dir()
        mod = driver.load_upstream(repo)
        driver.patch(mod, repo)

        blob1 = _make_glslc_blob(b'shader_one')
        blob2 = _make_glslc_blob(b'shader_two')
        f1 = f'{glslc_emu.fnv1a_64(blob1):016x}.glslc'
        f2 = f'{glslc_emu.fnv1a_64(blob2):016x}.glslc'

        with tempfile.TemporaryDirectory() as td:
            tpath = Path(td)
            shmap = tpath / 'shader_map.tsv'
            shmap.write_text(
                'package\tindex\tstage\tdm_ctl_sha16\tsource\n'
                f'vs_runtime.bin\t0\tvertex\t0011223344556677\t/glslc_capture/{f1}#GLSLC@0x0\n'
                f'ps_runtime.bin\t0\tpixel\t8899aabbccddeeff\t/glslc_capture/{f2}#GLSLC@0x0\n',
                encoding='utf-8',
            )

            class _FakeProfile:
                def table(self, name: str) -> Path:
                    assert name == 'shader_map.tsv'
                    return shmap

            g = _FakeProfile()
            vdir = tpath / 'v0'
            vdir.mkdir()

            # 1. Incomplete capture & failing offline compile cleans up `.partial` and raises BuildError
            def _fail_compile(ver_dir, out_dir, **kw):
                p = Path(out_dir)
                p.mkdir(parents=True, exist_ok=True)
                (p / f1).write_bytes(blob1)  # only 1 of 2 wanted shaders
                return {f1}

            with mock.patch.object(glslc_emu, 'compile_for_version', side_effect=_fail_compile):
                with self.assertRaises(mod.BuildError):
                    mod.capture_glslc(repo, {'v0': vdir}, 'v0', None, tpath, {}, tpath, g)
            self.assertFalse((vdir / 'glslc_capture.partial').exists())
            self.assertFalse((vdir / 'glslc_capture').exists())

            # 2. Complete offline compile swaps into `vdir / glslc_capture`
            def _ok_compile(ver_dir, out_dir, **kw):
                p = Path(out_dir)
                p.mkdir(parents=True, exist_ok=True)
                (p / f1).write_bytes(blob1)
                (p / f2).write_bytes(blob2)
                return {f1, f2}

            with mock.patch.object(glslc_emu, 'compile_for_version', side_effect=_ok_compile) as m_comp:
                res = mod.capture_glslc(repo, {'v0': vdir}, 'v0', None, tpath, {}, tpath, g)
                self.assertIsNone(res)
                self.assertEqual(m_comp.call_count, 1)
            self.assertEqual(mod.glslc_done(vdir / 'glslc_capture'), {f1, f2})

            # 3. Subsequent call reuses `vdir / glslc_capture` without invoking `compile_for_version`
            with mock.patch.object(glslc_emu, 'compile_for_version') as m_comp2:
                res2 = mod.capture_glslc(repo, {'v0': vdir}, 'v0', None, tpath, {}, tpath, g)
                self.assertIsNone(res2)
                m_comp2.assert_not_called()

    def test_unicorn_end_to_end_synthetic_glslc_nso(self) -> None:
        self.assertTrue(E._HAS_UNICORN, 'unicorn is required for offline GLSLC tests')
        # Assemble a tiny ARM64 NSO implementing:
        #   glslcInitialize (offset 0):
        #     mov w8, #4; str w8, [x0, #0x20]; mov w0, #1; ret
        #   glslcCompile (offset 16):
        #     writes a valid 0x80-byte GLSLC output at [x0 + 0x200], status at [x0 + 0x180],
        #     results pointer at [x0 + 0], incorporating options[x0 + 0x20] and stage[0] into
        #     output + 0x48 so distinct programs produce distinct FNV-1a hashes.
        code = [
            # glslcInitialize @ 0x00:
            0x52800088,  # mov w8, #4
            0xB9002008,  # str w8, [x0, #0x20]
            0x52800020,  # mov w0, #1
            0xD65F03C0,  # ret
            # glslcCompile @ 0x10:
            0x91040009,  # add x9, x0, #0x100   (results struct)
            0x9106000A,  # add x10, x0, #0x180  (status struct)
            0x9108000B,  # add x11, x0, #0x200  (output buffer)
            0xF9000009,  # str x9, [x0]
            0xA9002D2A,  # stp x10, x11, [x9]
            0x5280002C,  # mov w12, #1
            0x3900314C,  # strb w12, [x10, #0xc] (ok_flag = 1)
            0x3900355F,  # strb wzr, [x10, #0xd] (alloc_err = 0)
            0x528D122D,  # mov w13, #0x6891
            0x72A330CD,  # movk w13, #0x1986, lsl #16 (0x19866891)
            0xB900016D,  # str w13, [x11]
            0x5280100E,  # mov w14, #0x80
            0xB900456E,  # str w14, [x11, #0x44] (size = 0x80)
            0xB940200F,  # ldr w15, [x0, #0x20]  (optionFlags)
            0xF9405810,  # ldr x16, [x0, #0xb0]  (stages array ptr)
            0xB9400211,  # ldr w17, [x16]        (stages[0])
            0xA904C56F,  # stp w15, w17, [x11, #0x48]
            0x52800020,  # mov w0, #1
            0xD65F03C0,  # ret
        ]
        nso_bytes = _make_synthetic_nso(
            {'glslcInitialize': 0x00, 'glslcCompile': 0x10},
            code_words=code,
        )
        with tempfile.TemporaryDirectory() as td:
            vdir = Path(td) / 'v0'
            (vdir / 'ExeFS').mkdir(parents=True)
            (vdir / 'ExeFS' / 'subsdk0').write_bytes(nso_bytes)
            vs = b'#version 450\nvoid main() { gl_Position = vec4(0.0); }\x00'
            fs = b'#version 450\nout vec4 c;\nvoid main() { c = vec4(1.0); }\x00'
            (vdir / 'ExeFS' / 'main').write_bytes(b'glslcCompile\x00' + vs + b'\x00' * 8 + fs)
            out_dir = vdir / 'glslc_capture'
            got = glslc_emu.compile_for_version(vdir, out_dir)
            self.assertEqual(len(got), 2)
            for fname in got:
                raw = (out_dir / fname).read_bytes()
                self.assertEqual(len(raw), 0x80)
                self.assertEqual(struct.unpack_from('<I', raw, 0)[0], glslc_emu.GLSLC_MAGIC)
                self.assertEqual(f'{glslc_emu.fnv1a_64(raw):016x}.glslc', fname)

            # Verify a failed first compile does not poison `warm_mark` or leak heap allocations
            comp = glslc_emu.GlslcCompiler(vdir / 'ExeFS' / 'subsdk0')
            self.assertIsNone(comp.warm_mark)
            with mock.patch.object(comp.m, 'call', return_value=0):
                self.assertIsNone(comp.compile_program([vs], [0]))
            self.assertIsNone(comp.warm_mark)
            self.assertEqual(comp.m.heap_mark(), comp.init_mark)
            out_ok = comp.compile_program([vs], [0])
            self.assertIsNotNone(out_ok)
            self.assertIsNotNone(comp.warm_mark)

    def test_arm64_emu_zbic_and_bounds_checks(self) -> None:
        import types
        import zlib

        nso_raw = bytearray(_make_synthetic_nso({'nnMain': 0}))
        f_text, mo_text, sz_text = struct.unpack_from('<III', nso_raw, 0x10)
        f_ro, mo_ro, sz_ro = struct.unpack_from('<III', nso_raw, 0x20)
        f_data, mo_data, sz_data = struct.unpack_from('<III', nso_raw, 0x30)
        text_seg = bytes(nso_raw[f_text:f_text + sz_text])
        ro_seg = bytes(nso_raw[f_ro:f_ro + sz_ro])
        data_seg = bytes(nso_raw[f_data:f_data + sz_data])

        # Compress text segment with ZBIC flag (1 << 7 | 1)
        z_text = zlib.compress(text_seg)
        hdr = bytearray(nso_raw[:0x100])
        struct.pack_into('<I', hdr, 0x0C, (1 << 7) | 1)
        f0 = 0x100
        f1 = f0 + len(z_text)
        f2 = f1 + len(ro_seg)
        struct.pack_into('<III', hdr, 0x10, f0, mo_text, sz_text)
        struct.pack_into('<III', hdr, 0x20, f1, mo_ro, sz_ro)
        struct.pack_into('<III', hdr, 0x30, f2, mo_data, sz_data)
        struct.pack_into('<III', hdr, 0x60, len(z_text), len(ro_seg), len(data_seg))
        zbic_nso = bytes(hdr) + z_text + ro_seg + data_seg

        fake_zbic = types.SimpleNamespace(decompress=zlib.decompress)
        with tempfile.TemporaryDirectory() as td, mock.patch.dict(sys.modules, {'zbic': fake_zbic}):
            p = Path(td) / 'zbic_main'
            p.write_bytes(zbic_nso)
            img = E.nso_load(p)[0]
            self.assertEqual(bytes(img[:sz_text]), text_seg)

            # Corrupt segment offset raises EmuError cleanly
            bad_hdr = bytearray(zbic_nso)
            struct.pack_into('<I', bad_hdr, 0x10, len(bad_hdr) + 0x100)
            p_bad = Path(td) / 'bad_main'
            p_bad.write_bytes(bad_hdr)
            with self.assertRaises(E.EmuError):
                E.nso_load(p_bad)


if __name__ == '__main__':
    unittest.main()
