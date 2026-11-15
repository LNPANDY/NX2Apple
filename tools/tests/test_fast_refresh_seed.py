#!/usr/bin/env python3
"""Tests for Fast Refresh build seed caching, MSL trailer extraction and prefill.

Validates:
1. romfs_image.extract_msl & CLI --extract-msl on single-program NVN, multi-program,
   trailer missing error handling, and malicious path traversal / colon rejection.
2. build_seed.save_seed and dmsh_mtlcache.py stem filtering interaction (0-byte side-lib
   placeholders *_bx / *_bf exclusion, *_b.metallib payload stripping, and negative proof).
3. Atomic rollback on install failure in build_seed.save_seed (first-time install vs overwrite).
4. build_seed.adopt_legacy_work synthesizing seed from legacy work_dir + romfs trailer + .app.
5. build_seed.prepare_prefill producing aligned prefill_mac and prefill_ios staging.
6. Contract checks on build_ipa_from_nsp.py (--help flags, PREBAKE=True) and build_ipa.sh
   (DM_ROMFS_IDENTITY handling without missing-ROMFS failure).
"""
import io
import json
import os
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
ENGINE = ROOT / 'engine'
DM_TOOLS = ENGINE / 'dm' / 'tools'
DM_GFX_TOOLS = ENGINE / 'dm' / 'gfx' / 'tools'

if str(DM_TOOLS) not in sys.path:
    sys.path.insert(0, str(DM_TOOLS))
if str(DM_GFX_TOOLS) not in sys.path:
    sys.path.insert(0, str(DM_GFX_TOOLS))

import build_seed
import romfs
import romfs_image
import shader_lib


def _write_file(path, data=b''):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, 'wb') as f:
        f.write(data if isinstance(data, bytes) else data.encode('utf-8'))


def _read_bytes(path):
    with open(path, 'rb') as f:
        return f.read()


class ExtractMSLTests(unittest.TestCase):
    """1. Test romfs_image.extract_msl and CLI --extract-msl."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix='test_extract_msl_')

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_extract_msl_single_program_nvn(self):
        base_dir = os.path.join(self.tmp, 'base_src')
        _write_file(os.path.join(base_dir, 'game_data.bin'), b'GAME_CONTENT_DATA_0123')
        base_img = os.path.join(self.tmp, 'romfs.img')
        romfs_image.pack(base_dir, base_img)

        raw_chain = '0123456789abcdef'
        chain_tag = f'b-{raw_chain}'
        msl_src = os.path.join(self.tmp, 'msl_src')
        lib_data = b'METALLIB_BYTECODE_012345'
        json_meta = b'{"stage": "compute", "chain_metal": "test"}\n'
        tsv_meta = b'inputs\ttest_stamp\n'
        _write_file(os.path.join(msl_src, chain_tag, 'shader.metallib'), lib_data)
        _write_file(os.path.join(msl_src, chain_tag, 'shader.json'), json_meta)
        _write_file(os.path.join(msl_src, chain_tag, 'inputs.tsv'), tsv_meta)

        romfs_image.append_msl(base_img, msl_src, gfx_api='nvn', chain=chain_tag)

        inspect_info = romfs_image.inspect_msl(base_img)
        self.assertTrue(inspect_info['has_trailer'])
        self.assertEqual(inspect_info['chain'], chain_tag)
        self.assertEqual(inspect_info['gfx_api'], 'nvn')
        self.assertFalse(inspect_info['multi_program'])

        # API extraction
        out_api = os.path.join(self.tmp, 'out_api')
        res = romfs_image.extract_msl(base_img, out_api)
        self.assertTrue(res['has_trailer'])
        self.assertEqual(res['chain'], chain_tag)
        self.assertEqual(res['gfx_api'], 'nvn')
        self.assertEqual(res['extracted_files'], 3)
        self.assertEqual(res['out_dir'], os.path.abspath(out_api))

        extracted_lib = os.path.join(out_api, chain_tag, 'shader.metallib')
        extracted_json = os.path.join(out_api, chain_tag, 'shader.json')
        extracted_tsv = os.path.join(out_api, chain_tag, 'inputs.tsv')
        self.assertTrue(os.path.isfile(extracted_lib))
        self.assertEqual(_read_bytes(extracted_lib), lib_data)
        self.assertEqual(_read_bytes(extracted_json), json_meta)
        self.assertEqual(_read_bytes(extracted_tsv), tsv_meta)

        # CLI extraction
        out_cli = os.path.join(self.tmp, 'out_cli')
        cmd = [sys.executable, str(DM_TOOLS / 'romfs_image.py'), '--extract-msl', base_img, out_cli]
        proc = subprocess.run(cmd, capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, f'CLI error: {proc.stderr}')
        self.assertTrue(os.path.isfile(os.path.join(out_cli, chain_tag, 'shader.metallib')))
        self.assertEqual(_read_bytes(os.path.join(out_cli, chain_tag, 'shader.metallib')), lib_data)

    def test_extract_msl_multi_program(self):
        base_dir = os.path.join(self.tmp, 'base_src')
        _write_file(os.path.join(base_dir, 'marker.bin'), b'MARKER')
        base_img = os.path.join(self.tmp, 'multi_romfs.img')
        romfs_image.pack(base_dir, base_img)

        msl_src = os.path.join(self.tmp, 'msl_multi')
        shared_chain_tag = 'b-1111111111111111'
        p0_code = b'P0_METALLIB_BYTES'
        p1_code = b'P1_METALLIB_BYTES'
        _write_file(os.path.join(msl_src, 'p0', shared_chain_tag, 'c0.metallib'), p0_code)
        _write_file(os.path.join(msl_src, 'p0', shared_chain_tag, 'inputs.tsv'), b'inputs\tp0\n')
        _write_file(os.path.join(msl_src, 'p1', shared_chain_tag, 'c1.metallib'), p1_code)
        _write_file(os.path.join(msl_src, 'p1', shared_chain_tag, 'inputs.tsv'), b'inputs\tp1\n')

        romfs_image.append_msl(base_img, msl_src, gfx_api='nvn', chain=shared_chain_tag, multi_program=True)

        out_dir = os.path.join(self.tmp, 'out_multi')
        res = romfs_image.extract_msl(base_img, out_dir)
        self.assertTrue(res['has_trailer'])
        self.assertTrue(res['multi_program'])
        self.assertEqual(res['extracted_files'], 4)
        self.assertEqual(_read_bytes(os.path.join(out_dir, 'p0', shared_chain_tag, 'c0.metallib')), p0_code)
        self.assertEqual(_read_bytes(os.path.join(out_dir, 'p1', shared_chain_tag, 'c1.metallib')), p1_code)

    def test_extract_msl_no_trailer_raises_value_error(self):
        base_dir = os.path.join(self.tmp, 'base_only')
        _write_file(os.path.join(base_dir, 'data.txt'), b'NO_TRAILER')
        base_img = os.path.join(self.tmp, 'notrailer.img')
        romfs_image.pack(base_dir, base_img)

        out_dir = os.path.join(self.tmp, 'out_fail')
        with self.assertRaises(ValueError) as cm:
            romfs_image.extract_msl(base_img, out_dir)
        self.assertIn('no DMMSLTR1 shader trailer', str(cm.exception))

        # CLI also exits non-zero
        proc = subprocess.run(
            [sys.executable, str(DM_TOOLS / 'romfs_image.py'), '--extract-msl', base_img, out_dir],
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn('no DMMSLTR1 shader trailer', proc.stderr + proc.stdout)

    def test_extract_msl_path_traversal_and_malicious_rejections(self):
        label = 'test_slice'
        unsafe_paths = [
            '../escaped.txt',
            '../../etc/passwd',
            '/root/abs.txt',
            '\\windows\\abs.txt',
            'C:/drive/file.txt',
            'D:stream.txt',
            'foo:bar',
            'foo//bar',
            'foo/./bar',
            'foo/../bar',
            'foo\0bar',
            'bad/\ud800surrogate.txt',
        ]
        for bad in unsafe_paths:
            with self.subTest(bad_path=bad):
                with self.assertRaises(ValueError):
                    romfs_image._validate_extract_rel_path(bad, label)


class SaveSeedMtlCacheInteractionTests(unittest.TestCase):
    """2. Test build_seed.save_seed and dmsh_mtlcache.py stem filtering interaction."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix='test_save_seed_mtl_')

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _setup_minimal_work_dir(self, work_dir, tid, chain):
        raw_ch = chain[2:] if chain.startswith('b-') else chain
        # ExeFS
        _write_file(os.path.join(work_dir, 'extract', 'v0', 'ExeFS', 'main'), b'MAIN_BIN')
        _write_file(os.path.join(work_dir, 'control.nacp'), b'\0' * 0x4000)
        _write_file(os.path.join(work_dir, 'icon.jpg'), b'\xff\xd8\xff\xe0' + b'\0' * 32)
        # shader/pkg
        _write_file(os.path.join(work_dir, 'shader', 'pkg', 'split.tsv'), b'split_info\n')
        # shader/tables
        _write_file(
            os.path.join(work_dir, 'shader', 'tables', 'c1_full.tsv'),
            f'# chain {raw_ch} inputs stamp\n'.encode('utf-8'),
        )
        _write_file(
            os.path.join(work_dir, 'shader', 'tables', 'cb_extent.tsv'),
            f'# chain {raw_ch} inputs stamp\n'.encode('utf-8'),
        )
        # shader/ios
        ios_lib = os.path.join(work_dir, 'shader', 'ios', f'b-{raw_ch}.img')
        os.makedirs(os.path.dirname(ios_lib), exist_ok=True)
        shader_lib.write({'ios_stub.metallib': b'IOS_METALLIB_BYTES'}, ios_lib)

    def test_save_seed_metal_sources_and_mtlcache_filtering(self):
        tid = '0100000000000001'
        chain = '0123456789abcdef'
        seed_root = os.path.join(self.tmp, 'seeds')
        work_dir = os.path.join(self.tmp, 'work')
        self._setup_minimal_work_dir(work_dir, tid, chain)

        # 16-hex stems matching dmsh_mtlcache.py OUTPUT regex: r'[0-9a-f]{16}_b\.metal'
        stem1 = '00000000aaaa0001'
        stem2 = '00000000aaaa0002'

        # Pack shader library containing metal, json, tsv, main metallib, and side/tile metallibs
        mac_shader_dir = os.path.join(work_dir, 'shader', 'cache')
        mac_lib_img = os.path.join(mac_shader_dir, f'b-{chain}.img')
        os.makedirs(os.path.dirname(mac_lib_img), exist_ok=True)
        files_to_pack = {
            f'{stem1}_b.metal': b'vertex float4 v1() { return 0; }\n',
            f'{stem1}_b.json': b'{"stage": "vs", "chain_metal": "test"}\n',
            f'{stem1}_b.metallib': b'HEAVY_COMPILED_METALLIB_PAYLOAD_1' * 200,
            f'{stem1}_bx.metallib': b'SIDE_LIBRARY_PAYLOAD_1',
            f'{stem2}_b.metal': b'fragment float4 f2() { return 0; }\n',
            f'{stem2}_b.json': b'{"stage": "fs", "chain_metal": "test"}\n',
            f'{stem2}_b.metallib': b'HEAVY_COMPILED_METALLIB_PAYLOAD_2' * 200,
            f'{stem2}_bf.metallib': b'READABLE_TILE_PAYLOAD_2',
            'inputs.tsv': b'inputs\tstamp123\n',
        }
        shader_lib.write(files_to_pack, mac_lib_img)

        # Call save_seed
        meta = {
            'pkg_ver': 'v0',
            'app_name': 'TestGame',
            'gfx_api': 'nvn',
            'chain': chain,
        }
        res = build_seed.save_seed(
            seed_root=seed_root,
            title_id=tid,
            meta=meta,
            work_dir=work_dir,
            mac_shader_dir=mac_shader_dir,
        )
        self.assertTrue(res['valid'], f'save_seed failed: {res["reason"]}')

        target_seed = os.path.join(seed_root, tid)
        metal_sources_img = os.path.join(target_seed, 'metal-sources', f'b-{chain}.img')
        self.assertTrue(os.path.isfile(metal_sources_img))

        # Verify metal-sources content
        view = shader_lib.view(metal_sources_img)
        ms_names = set(romfs.os.listdir(view))

        # .metal, .json, .tsv must be preserved
        self.assertIn(f'{stem1}_b.metal', ms_names)
        self.assertIn(f'{stem1}_b.json', ms_names)
        self.assertIn(f'{stem2}_b.metal', ms_names)
        self.assertIn(f'{stem2}_b.json', ms_names)
        self.assertIn('inputs.tsv', ms_names)

        # Heavy main metallib payloads must be excluded!
        self.assertNotIn(f'{stem1}_b.metallib', ms_names)
        self.assertNotIn(f'{stem2}_b.metallib', ms_names)

        # 0-byte placeholders for *_bx.metallib and *_bf.metallib must exist
        self.assertIn(f'{stem1}_bx.metallib', ms_names)
        self.assertIn(f'{stem2}_bf.metallib', ms_names)
        self.assertEqual(len((view / f'{stem1}_bx.metallib').read_bytes()), 0)
        self.assertEqual(len((view / f'{stem2}_bf.metallib').read_bytes()), 0)

        # Execute dmsh_mtlcache.py exact stem-filtering regex & list comprehension
        output_re = re.compile(r'[0-9a-f]{16}_b\.metal')
        filtered_stems = sorted(
            n[:-6] for n in ms_names
            if output_re.fullmatch(n) and n[:-6] + 'x.metallib' not in ms_names and n[:-6] + 'f.metallib' not in ms_names
        )
        # Both stems must be skipped because of *_bx.metallib and *_bf.metallib placeholders!
        self.assertEqual(filtered_stems, [])

        # Negative assertion proof:
        # If we remove the placeholder from ms_names, the stem must appear as unexcluded!
        test_names = set(ms_names)
        test_names.remove(f'{stem1}_bx.metallib')
        negative_stems = sorted(
            n[:-6] for n in test_names
            if output_re.fullmatch(n) and n[:-6] + 'x.metallib' not in test_names and n[:-6] + 'f.metallib' not in test_names
        )
        self.assertEqual(negative_stems, [f'{stem1}_b'])


class SaveSeedRollbackTests(unittest.TestCase):
    """3. Test atomic rollback on install failure in build_seed.save_seed."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix='test_rollback_')
        self.seed_root = os.path.join(self.tmp, 'seeds')
        self.work_dir = os.path.join(self.tmp, 'work')
        self.tid = '0100000000000002'
        self.chain = '2222333344445555'

        # Minimal valid work_dir
        _write_file(os.path.join(self.work_dir, 'extract', 'v0', 'ExeFS', 'main'), b'EXEFS_DATA')
        _write_file(os.path.join(self.work_dir, 'control.nacp'), b'\0' * 0x4000)
        _write_file(os.path.join(self.work_dir, 'shader', 'pkg', 'split.tsv'), b'STAMP\n')
        _write_file(os.path.join(self.work_dir, 'shader', 'tables', 'c1_full.tsv'), f'# chain {self.chain} inputs\n')
        _write_file(os.path.join(self.work_dir, 'shader', 'tables', 'cb_extent.tsv'), f'# chain {self.chain} inputs\n')
        ios_lib = os.path.join(self.work_dir, 'shader', 'ios', f'b-{self.chain}.img')
        os.makedirs(os.path.dirname(ios_lib), exist_ok=True)
        shader_lib.write({'test.metallib': b'IOS_LIB'}, ios_lib)

        mac_cache = os.path.join(self.work_dir, 'shader', 'cache', f'b-{self.chain}.img')
        os.makedirs(os.path.dirname(mac_cache), exist_ok=True)
        shader_lib.write({'test_b.metal': b'void main() {}\n', 'inputs.tsv': b'inputs\n'}, mac_cache)
        self.mac_cache_dir = os.path.join(self.work_dir, 'shader', 'cache')

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_first_time_install_failure_leaves_no_target_dir(self):
        target_dir = os.path.join(self.seed_root, self.tid)
        self.assertFalse(os.path.exists(target_dir))

        meta = {'pkg_ver': 'v0', 'app_name': 'FirstInstall', 'gfx_api': 'nvn', 'chain': self.chain}

        orig_replace = os.replace
        def mock_replace(src, dst):
            if dst == target_dir:
                os.makedirs(dst, exist_ok=True)
                _write_file(os.path.join(dst, 'corrupted_partial.bin'), b'PARTIAL')
                raise OSError('Simulated disk failure during first publish')
            return orig_replace(src, dst)

        with patch('os.replace', side_effect=mock_replace):
            with self.assertRaises(OSError):
                build_seed.save_seed(
                    self.seed_root, self.tid, meta, self.work_dir, mac_shader_dir=self.mac_cache_dir
                )

        # Verification: target directory must NOT exist half-written!
        self.assertFalse(os.path.exists(target_dir), 'target directory was left half-written after first install failure!')
        stales = [n for n in os.listdir(self.seed_root) if f'.{self.tid}.staging' in n or f'.{self.tid}.old' in n]
        self.assertEqual(stales, [])

    def test_overwrite_install_failure_restores_prior_seed_intact(self):
        target_dir = os.path.join(self.seed_root, self.tid)

        # First install successfully (v1.0)
        meta_v1 = {'pkg_ver': 'v1.0.0', 'app_name': 'OriginalSeed', 'gfx_api': 'nvn', 'chain': self.chain}
        res1 = build_seed.save_seed(
            self.seed_root, self.tid, meta_v1, self.work_dir, mac_shader_dir=self.mac_cache_dir
        )
        self.assertTrue(res1['valid'])
        seed_json_path = os.path.join(target_dir, 'seed.json')
        self.assertTrue(os.path.isfile(seed_json_path))
        with open(seed_json_path, 'r', encoding='utf-8') as f:
            v1_data = json.load(f)
        self.assertEqual(v1_data['pkg_ver'], 'v1.0.0')

        # Now attempt overwrite with v2.0, but simulate exception during publish
        meta_v2 = {'pkg_ver': 'v2.0.0', 'app_name': 'NewCorruptedSeed', 'gfx_api': 'nvn', 'chain': self.chain}
        orig_replace = os.replace

        def mock_replace(src, dst):
            if dst == target_dir:
                os.makedirs(dst, exist_ok=True)
                _write_file(os.path.join(dst, 'half_baked.bin'), b'GARBAGE')
                raise OSError('Simulated disk full during overwrite publish')
            return orig_replace(src, dst)

        with patch('os.replace', side_effect=mock_replace):
            with self.assertRaises(OSError):
                build_seed.save_seed(
                    self.seed_root, self.tid, meta_v2, self.work_dir, mac_shader_dir=self.mac_cache_dir
                )

        # Verification: target directory must exist and be restored to prior seed intact!
        self.assertTrue(os.path.isdir(target_dir))
        self.assertFalse(os.path.exists(os.path.join(target_dir, 'half_baked.bin')), 'half-baked file was not cleaned!')
        with open(seed_json_path, 'r', encoding='utf-8') as f:
            restored_data = json.load(f)
        self.assertEqual(restored_data['pkg_ver'], 'v1.0.0')
        self.assertEqual(restored_data['app_name'], 'OriginalSeed')

        # Verification: inspect_seed still reports valid on the restored target
        inspect_res = build_seed.inspect_seed(self.seed_root, title_id=self.tid)
        self.assertTrue(inspect_res['valid'])


class AdoptLegacyWorkTests(unittest.TestCase):
    """4. Test build_seed.adopt_legacy_work synthesizing seed from legacy work_dir + romfs trailer + .app."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix='test_adopt_')
        self.seed_root = os.path.join(self.tmp, 'seeds')
        self.work_dir = os.path.join(self.tmp, 'legacy_build')
        self.tid = '0100123400000000'
        self.chain = '3333444455556666'

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_adopt_legacy_work_synthesizes_valid_seed(self):
        # 1. Legacy work_dir without shader/ios
        _write_file(os.path.join(self.work_dir, 'extract', 'v0', 'ExeFS', 'main'), b'LEGACY_MAIN')
        _write_file(os.path.join(self.work_dir, 'control.nacp'), b'\0' * 0x4000)
        _write_file(os.path.join(self.work_dir, 'icon.jpg'), b'\xff\xd8\xff\xe0' + b'\0' * 32)
        _write_file(os.path.join(self.work_dir, 'shader', 'pkg', 'split.tsv'), b'LEGACY_SPLIT\n')
        _write_file(
            os.path.join(self.work_dir, 'shader', 'tables', 'c1_full.tsv'),
            f'# chain {self.chain} inputs legacy\n'.encode('utf-8'),
        )
        _write_file(
            os.path.join(self.work_dir, 'shader', 'tables', 'cb_extent.tsv'),
            f'# chain {self.chain} inputs legacy\n'.encode('utf-8'),
        )

        # 2. RomFS image with DMMSLTR1 trailer (providing shader/ios)
        base_dir = os.path.join(self.tmp, 'base_src')
        _write_file(os.path.join(base_dir, 'data.bin'), b'ROMFS_DATA')
        romfs_img = os.path.join(self.tmp, 'romfs.img')
        romfs_image.pack(base_dir, romfs_img)

        msl_ios = os.path.join(self.tmp, 'trailer_msl')
        _write_file(
            os.path.join(msl_ios, f'b-{self.chain}', '0000000011112222_b.metallib'),
            b'IOS_METALLIB_PAYLOAD',
        )
        _write_file(
            os.path.join(msl_ios, f'b-{self.chain}', 'inputs.tsv'),
            b'inputs\tstamp_ios\n',
        )
        romfs_image.append_msl(romfs_img, msl_ios, gfx_api='nvn', chain=f'b-{self.chain}')

        # 3. Mac .app bundle with Contents/Resources/msl/b-<chain>.img
        app_dir = os.path.join(self.tmp, 'LegacyApp.app')
        plist_data = {
            'CFBundleName': 'Adopted Legacy Game',
            'DMTitleID': self.tid,
            'DMDisplayVersion': '1.2.0',
            'DMPackageVersion': 'v131072',
            'CFBundleIdentifier': f'org.nxnative.{self.tid.lower()}',
            'DMLanguage': 'en',
        }
        _write_file(os.path.join(app_dir, 'Contents', 'Info.plist'), plistlib.dumps(plist_data))
        _write_file(
            os.path.join(app_dir, 'Contents', 'Resources', 'dm', 'launcher.json'),
            json.dumps({'gfx_api': 'nvn', 'chain': self.chain}),
        )

        app_msl_img = os.path.join(app_dir, 'Contents', 'Resources', 'msl', f'b-{self.chain}.img')
        os.makedirs(os.path.dirname(app_msl_img), exist_ok=True)
        shader_lib.write(
            {
                '0000000011112222_b.metal': b'vertex float4 v() { return 0; }\n',
                '0000000011112222_b.json': b'{"stage": "vs"}\n',
                'inputs.tsv': b'inputs\tstamp_app\n',
            },
            app_msl_img,
        )

        # Call adopt_legacy_work
        res = build_seed.adopt_legacy_work(
            seed_root=self.seed_root,
            title_id=self.tid,
            work_dir=self.work_dir,
            app_path=app_dir,
            img_path=romfs_img,
        )

        self.assertTrue(res['valid'], f'adopt_legacy_work failed: {res["reason"]}')
        seed_record = res['seed']
        self.assertEqual(seed_record['title_id'], self.tid)
        self.assertEqual(seed_record['app_name'], 'Adopted Legacy Game')
        self.assertEqual(seed_record['app_version'], '1.2.0')
        self.assertEqual(seed_record['pkg_ver'], 'v131072')
        self.assertEqual(seed_record['gfx_api'], 'nvn')
        self.assertEqual(seed_record['chain'], self.chain)
        self.assertIsNotNone(seed_record['romfs_identity'])
        self.assertTrue(seed_record['romfs_identity'].startswith('DMROMFSID1 '))

        # Check synthesized folders in seed
        seed_dir = os.path.join(self.seed_root, self.tid)
        self.assertTrue(os.path.isdir(os.path.join(seed_dir, 'ExeFS')))
        self.assertTrue(os.path.isdir(os.path.join(seed_dir, 'shader', 'pkg')))
        self.assertTrue(os.path.isdir(os.path.join(seed_dir, 'shader', 'tables')))
        self.assertTrue(os.path.isdir(os.path.join(seed_dir, 'shader', 'ios')))
        self.assertTrue(os.path.isfile(os.path.join(seed_dir, 'metal-sources', f'b-{self.chain}.img')))


class PreparePrefillTests(unittest.TestCase):
    """5. Test build_seed.prepare_prefill producing aligned prefill_mac and prefill_ios."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix='test_prefill_')
        self.seed_dir = os.path.join(self.tmp, 'seed')
        self.old_chain = '4444555566667777'

        # Seed with metal-sources
        ms_img = os.path.join(self.seed_dir, 'metal-sources', f'b-{self.old_chain}.img')
        os.makedirs(os.path.dirname(ms_img), exist_ok=True)
        shader_lib.write(
            {
                '0000000033334444_b.metal': b'#include <metal_stdlib>\nvoid test() {}\n',
                '0000000033334444_b.json': b'{"stage": "vs"}\n',
                'inputs.tsv': b'inputs\told_stamp\n',
            },
            ms_img,
        )

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_prepare_prefill_aligned_mac_and_ios_from_trailer(self):
        # External source: a romfs.img with DMMSLTR1 trailer for the old chain
        base_dir = os.path.join(self.tmp, 'base_src')
        _write_file(os.path.join(base_dir, 'rom.bin'), b'ROM')
        romfs_img = os.path.join(self.tmp, 'game.img')
        romfs_image.pack(base_dir, romfs_img)

        trailer_msl = os.path.join(self.tmp, 'trailer_msl')
        ios_lib_bytes = b'IOS_COMPILED_METALLIB_PAYLOAD_9999'
        _write_file(
            os.path.join(trailer_msl, f'b-{self.old_chain}', '0000000033334444_b.metallib'),
            ios_lib_bytes,
        )
        _write_file(os.path.join(trailer_msl, f'b-{self.old_chain}', 'inputs.tsv'), b'inputs\ttrailer\n')
        romfs_image.append_msl(romfs_img, trailer_msl, gfx_api='nvn', chain=f'b-{self.old_chain}')

        tmp_staging = os.path.join(self.tmp, 'prefill_staging')
        env_val, summary = build_seed.prepare_prefill(
            seed_dir=self.seed_dir,
            prefill_sources=[romfs_img],
            tmp_dir=tmp_staging,
            gfx_api='nvn',
            target_chain='88889999aaaabbbb',   # different from old_chain
        )

        self.assertEqual(summary['chains'], [f'b-{self.old_chain}'])
        self.assertIsNotNone(summary['prefill_mac'])
        self.assertIsNotNone(summary['prefill_ios'])

        expected_env = f"{summary['prefill_mac']}={summary['prefill_ios']}"
        self.assertEqual(env_val, expected_env)

        # Check prefill_mac holds b-<old_chain>.img
        mac_img = os.path.join(summary['prefill_mac'], f'b-{self.old_chain}.img')
        self.assertTrue(os.path.isfile(mac_img))
        mac_view = shader_lib.view(mac_img)
        self.assertIn('0000000033334444_b.metal', romfs.os.listdir(mac_view))

        # Check prefill_ios holds folder b-<old_chain> with metallib
        ios_dir = os.path.join(summary['prefill_ios'], f'b-{self.old_chain}')
        self.assertTrue(os.path.isdir(ios_dir))
        self.assertTrue(os.path.isfile(os.path.join(ios_dir, '0000000033334444_b.metallib')))
        self.assertEqual(
            _read_bytes(os.path.join(ios_dir, '0000000033334444_b.metallib')),
            ios_lib_bytes,
        )


class ContractChecksTests(unittest.TestCase):
    """6. Contract checks on build_ipa_from_nsp.py and build_ipa.sh."""

    def test_build_ipa_from_nsp_prebake_default_remains_true(self):
        script_path = ENGINE / 'scripts' / 'build_ipa_from_nsp.py'
        self.assertTrue(script_path.is_file(), f'missing {script_path}')
        content = script_path.read_text(encoding='utf-8')

        match = re.search(r'^\s*PREBAKE\s*=\s*(True|False)', content, re.MULTILINE)
        self.assertIsNotNone(match, 'PREBAKE setting definition not found in build_ipa_from_nsp.py')
        self.assertEqual(match.group(1), 'True', 'PREBAKE default must remain True in build_ipa_from_nsp.py!')

    def test_build_ipa_from_nsp_help_exposes_seed_flags(self):
        script_path = ENGINE / 'scripts' / 'build_ipa_from_nsp.py'
        proc = subprocess.run(
            [sys.executable, str(script_path), '--help'],
            capture_output=True,
            text=True,
        )
        self.assertEqual(proc.returncode, 0, f'--help failed: {proc.stderr}')
        help_text = proc.stdout
        self.assertIn('--from-seed', help_text)
        self.assertIn('--seed-cache-dir', help_text)
        self.assertIn('--prefill-msl', help_text)

    def test_build_ipa_sh_dm_romfs_identity_handling_contract(self):
        sh_path = ENGINE / 'dm' / 'ios' / 'tools' / 'build_ipa.sh'
        self.assertTrue(sh_path.is_file(), f'missing {sh_path}')
        content = sh_path.read_text(encoding='utf-8')

        # 1. Supports DM_ROMFS_IDENTITY
        self.assertIn('ROMFS_IDENTITY=${DM_ROMFS_IDENTITY:-}', content)
        self.assertIn('valid_romfs_identity', content)

        # 2. check_program: accepts missing ROMFS when DM_COPY_ROMFS=NO and DM_ROMFS_IDENTITY present
        self.assertIn('if [ "$SLIM_CHECK" = YES ] && [ ! -e "$ROMFS" ] && [ -n "$ROMFS_IDENTITY" ]; then', content)
        self.assertIn('valid_romfs_identity "$ROMFS_IDENTITY"', content)

        # 3. Writes $O/romfs.id and populates MAPS without requiring physical $ROMFS
        self.assertIn('elif [ -n "$ROMFS_IDENTITY" ]; then', content)
        self.assertIn('printf \'%s\\n\' "$ROMFS_IDENTITY" > "$O/romfs.id"', content)

    def test_save_seed_preserves_metal_sources_and_ios_on_same_version_refresh(self):
        tmp = tempfile.mkdtemp(prefix='test_preserve_seed_')
        try:
            seed_root = os.path.join(tmp, 'seeds')
            work1 = os.path.join(tmp, 'w1')
            os.makedirs(os.path.join(work1, 'extract', 'v0', 'ExeFS'), exist_ok=True)
            _write_file(os.path.join(work1, 'extract', 'v0', 'ExeFS', 'main'), b'MAIN_V0')
            _write_file(os.path.join(work1, 'extract', 'v0', 'ExeFS', 'main.npdm'), b'META_V0')
            os.makedirs(os.path.join(work1, 'shader', 'pkg'), exist_ok=True)
            _write_file(os.path.join(work1, 'shader', 'pkg', 'p.bin'), b'PKG')
            os.makedirs(os.path.join(work1, 'shader', 'tables'), exist_ok=True)
            _write_file(os.path.join(work1, 'shader', 'tables', 'c1_full.tsv'), b'# c1\n')
            _write_file(os.path.join(work1, 'shader', 'tables', 'cb_extent.tsv'), b'# cb\n')

            chain = '1122334455667788'
            os.makedirs(os.path.join(work1, 'shader', 'ios'), exist_ok=True)
            shader_lib.write(
                {'0000000000000001_b.metallib': b'IOSLIB', 'inputs.tsv': b'inputs\tst\n'},
                os.path.join(work1, 'shader', 'ios', f'b-{chain}.img'),
            )
            os.makedirs(os.path.join(work1, 'shader', 'cache'), exist_ok=True)
            shader_lib.write(
                {
                    '0000000000000001_b.metal': b'void x() {}\n',
                    '0000000000000001_b.json': b'{}\n',
                    '0000000000000001_bx.metallib': b'SIDE_BIN',
                    'inputs.tsv': b'inputs\tst\n',
                },
                os.path.join(work1, 'shader', 'cache', f'b-{chain}.img'),
            )

            tid = '0100112233445000'
            base_rom = os.path.join(tmp, 'rom_src')
            _write_file(os.path.join(base_rom, 'boot.dat'), b'ROM_PAYLOAD')
            sample_img = os.path.join(tmp, 'sample.img')
            romfs_image.pack(base_rom, sample_img)
            rid = romfs_image.identity(sample_img, 'demo_profile', '1.0', 'v0')
            build_seed.save_seed(
                seed_root,
                tid,
                {'pkg_ver': 'v0', 'gfx_api': 'nvn', 'chain': chain, 'romfs_identity': rid},
                work1,
            )

            # Second save from iOS fast-refresh workspace that lacks sh/cache and local RomFS.img
            work2 = os.path.join(tmp, 'w2')
            build_seed.stage_seed_to_work(os.path.join(seed_root, tid), work2)
            # Clear empty/non-existent sh/cache and verify metal-sources + romfs_identity survive
            res = build_seed.save_seed(
                seed_root,
                tid,
                {'pkg_ver': 'v0', 'gfx_api': 'nvn', 'chain': chain},
                work2,
                mac_shader_dir=os.path.join(work2, 'shader', 'cache'),
            )
            self.assertTrue(res['valid'])
            self.assertTrue(res['has_metal_sources'])
            self.assertTrue(res['has_shader_ios'])
            self.assertEqual(res['seed']['romfs_identity'], rid)
            self.assertTrue(os.path.isfile(os.path.join(seed_root, tid, 'metal-sources', f'b-{chain}.img')))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_build_ipa_from_nsp_from_seed_cli_guards(self):
        script_path = ENGINE / 'scripts' / 'build_ipa_from_nsp.py'
        for extra in (['--from-seed', '--survey-only'], ['--from-seed', '--prepare-xcode'], ['--from-seed', '--progress', 'json']):
            proc = subprocess.run(
                [sys.executable, str(script_path)] + extra,
                capture_output=True,
                text=True,
                stdin=subprocess.DEVNULL,
            )
            self.assertEqual(proc.returncode, 1, f'expected failure for {extra}: out={proc.stdout} err={proc.stderr}')

    def test_build_ipa_from_nsp_prepare_and_persist_seed_roundtrip(self):
        import importlib.util
        script_path = ENGINE / 'scripts' / 'build_ipa_from_nsp.py'
        spec = importlib.util.spec_from_file_location('test_build_ipa_mod', script_path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)

        tmp = tempfile.mkdtemp(prefix='test_pipe_seed_')
        saved_env = dict(os.environ)
        try:
            seed_root = Path(tmp) / 'seeds'
            src_work = Path(tmp) / 'legacy_01007ef00011e000_build'
            prof_dir = src_work / 'profile' / 'botw_demo'
            prof_dir.mkdir(parents=True)
            _write_file(prof_dir / 'game.tsv', b'# Provisional game profile\ntitle_id\t01007EF00011E000\nname\tDemo Game\n')
            _write_file(src_work / 'extract' / 'v0' / 'ExeFS' / 'main', b'MAIN')
            _write_file(src_work / 'extract' / 'v0' / 'ExeFS' / 'main.npdm', b'META')
            _write_file(src_work / 'shader' / 'pkg' / 'p.bin', b'PKG')
            _write_file(src_work / 'shader' / 'tables' / 'c1_full.tsv', b'# c1\n')
            _write_file(src_work / 'shader' / 'tables' / 'cb_extent.tsv', b'# cb\n')
            chain = mod.chain_of(ENGINE) or '1111222233334444'
            _write_file(src_work / 'shader' / 'ios' / f'b-{chain}' / '0000000000000001_b.metallib', b'LIB')
            _write_file(src_work / 'shader' / 'ios' / f'b-{chain}' / 'inputs.tsv', b'inputs\tst\n')

            rom_src_dir = Path(tmp) / 'rom_src'
            _write_file(rom_src_dir / 'data.bin', b'GAME_DATA')
            sample_img = Path(tmp) / 'sample.img'
            romfs_image.pack(str(rom_src_dir), str(sample_img))
            real_rid = romfs_image.identity(str(sample_img), 'botw_demo', '1.0.0', 'v0')

            sys.path.insert(0, str(ENGINE / 'dm/games'))
            import game as gamemod
            sys.path.insert(0, str(ENGINE / 'dm/tools'))
            mod.nacp = __import__('nacp')

            args = mod.parse_args(['--from-seed', '--title-id', '01007EF00011E000', '--seed-cache-dir', str(seed_root), '--work-dir', str(src_work)])
            env = {}
            prep = mod._prepare_from_seed(args, 'auto', seed_root, [], gamemod, env, False)
            self.assertEqual(prep['app'], 0x01007EF00011E000)
            self.assertEqual(prep['pkg_ver'], 'v0')
            self.assertTrue((prep['game'] / 'ExeFS' / 'main').is_file())

            # Test _persist_build_seed roundtrip with fallback romfs_id
            mod._persist_build_seed(
                seed_root,
                prep['app'],
                prep['g'],
                prep['provisional'],
                prep['derived'],
                prep['pkg_ver'],
                'Demo Game',
                '1.0.0',
                'org.nxnative.01007ef00011e000',
                'en-US',
                ['en-US'],
                'nvn',
                ENGINE,
                prep['work'],
                prep['game'],
                prep['work'] / 'shader',
                None,
                False,
                None,
                None,
                None,
                fallback_romfs_id=real_rid,
            )
            insp = build_seed.inspect_seed(seed_root, title_id='01007EF00011E000')
            self.assertTrue(insp['valid'])
            self.assertEqual(insp['seed']['app_name'], 'Demo Game')
            self.assertEqual(insp['seed']['romfs_identity'], real_rid)
        finally:
            os.environ.clear()
            os.environ.update(saved_env)
            shutil.rmtree(tmp, ignore_errors=True)

    def test_prepare_prefill_multi_program_p_subdirs(self):
        tmp = tempfile.mkdtemp(prefix='test_prefill_mp_')
        try:
            seed_dir = Path(tmp) / 'seed'
            old_chain = '1122334455667788'
            for prog, tag in (('p0', b'PROG0'), ('p1', b'PROG1')):
                ms_p = seed_dir / 'metal-sources' / prog
                ms_p.mkdir(parents=True, exist_ok=True)
                shader_lib.write(
                    {
                        f'000000000000000{prog[1:]}_b.metal': b'void main() {}\n',
                        'inputs.tsv': b'inputs\tst\n',
                    },
                    str(ms_p / f'b-{old_chain}.img'),
                )
                ios_p = seed_dir / 'shader' / 'ios' / prog
                ios_p.mkdir(parents=True, exist_ok=True)
                shader_lib.write(
                    {
                        f'000000000000000{prog[1:]}_b.metallib': b'IOS_' + tag,
                    },
                    str(ios_p / f'b-{old_chain}.img'),
                )

            out_tmp = Path(tmp) / 'out'
            env_val, summary = build_seed.prepare_prefill(
                str(seed_dir),
                [],
                str(out_tmp),
                gfx_api='nvn',
                target_chain='9999aaaabbbbcccc',
            )
            self.assertTrue(env_val)
            specs = env_val.split(os.pathsep)
            self.assertEqual(len(specs), 2)
            self.assertIn('prefill_mac_p0', specs[0])
            self.assertIn('prefill_ios_p0', specs[0])
            self.assertIn('prefill_mac_p1', specs[1])
            self.assertIn('prefill_ios_p1', specs[1])
            self.assertEqual(summary['chains'], [f'b-{old_chain}'])
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_build_ipa_from_nsp_multi_program_from_seed_isolation(self):
        import importlib.util
        script_path = ENGINE / 'scripts' / 'build_ipa_from_nsp.py'
        spec = importlib.util.spec_from_file_location('test_build_ipa_mp_mod', script_path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)

        tmp = tempfile.mkdtemp(prefix='test_pipe_mp_')
        saved_env = dict(os.environ)
        saved_prog_idx = mod.PROGRAM_INDEX
        try:
            seed_root = Path(tmp) / 'seeds'
            work_root = Path(tmp) / 'sm_build'
            prof0 = Path(tmp) / 'prof0' / '01007EF00011E000'
            prof0.mkdir(parents=True)
            _write_file(prof0 / 'game.tsv', b'# p0\ntitle_id\t01007EF00011E000\nname\tProg Zero\n')
            w0 = Path(tmp) / 'w0'
            _write_file(w0 / 'extract' / 'v0' / 'ExeFS' / 'main', b'MAIN0')
            _write_file(w0 / 'extract' / 'v0' / 'ExeFS' / 'main.npdm', b'META0')
            _write_file(w0 / 'shader' / 'pkg' / 'p.bin', b'PKG0')
            _write_file(w0 / 'shader' / 'tables' / 'c1_full.tsv', b'# c1\n')
            _write_file(w0 / 'shader' / 'tables' / 'cb_extent.tsv', b'# cb\n')
            chain = mod.chain_of(ENGINE) or '1111222233334444'
            _write_file(w0 / 'shader' / 'ios' / f'b-{chain}' / '0000000000000001_b.metallib', b'LIB0')
            _write_file(w0 / 'shader' / 'ios' / f'b-{chain}' / 'inputs.tsv', b'inputs\tst\n')
            build_seed.save_seed(
                seed_root,
                '01007EF00011E000',
                {'base_title_id': '01007EF00011E000', 'pkg_ver': 'v0', 'gfx_api': 'nvn', 'chain': chain, 'profile_id': '01007EF00011E000', 'profile_kind': 'provisional'},
                w0,
                profile_dir=prof0,
            )

            sys.path.insert(0, str(ENGINE / 'dm/games'))
            import game as gamemod
            sys.path.insert(0, str(ENGINE / 'dm/tools'))
            mod.nacp = __import__('nacp')

            # Sub-program 1 missing its own seed must raise BuildError rather than overwrite with program 0 seed
            args = mod.parse_args(['--from-seed', '--title-id', '01007EF00011E000', '--seed-cache-dir', str(seed_root), '--work-dir', str(work_root)])
            args.in_programs = {}
            mod.PROGRAM_INDEX = 1
            with self.assertRaises(mod.BuildError):
                mod._prepare_from_seed(args, 'auto', seed_root, [], gamemod, {}, False)

            # Save independent seed for sub-program 1 and verify isolation
            prof1 = Path(tmp) / 'prof1' / '01007EF00011E001'
            prof1.mkdir(parents=True)
            _write_file(prof1 / 'game.tsv', b'# p1\ntitle_id\t01007EF00011E001\nname\tProg One\n')
            w1 = Path(tmp) / 'w1'
            _write_file(w1 / 'extract' / 'v0' / 'ExeFS' / 'main', b'MAIN1')
            _write_file(w1 / 'extract' / 'v0' / 'ExeFS' / 'main.npdm', b'META1')
            _write_file(w1 / 'shader' / 'pkg' / 'p.bin', b'PKG1')
            _write_file(w1 / 'shader' / 'tables' / 'c1_full.tsv', b'# c1\n')
            _write_file(w1 / 'shader' / 'tables' / 'cb_extent.tsv', b'# cb\n')
            _write_file(w1 / 'shader' / 'ios' / f'b-{chain}' / '0000000000000002_b.metallib', b'LIB1')
            _write_file(w1 / 'shader' / 'ios' / f'b-{chain}' / 'inputs.tsv', b'inputs\tst\n')
            build_seed.save_seed(
                seed_root,
                '01007EF00011E001',
                {'base_title_id': '01007EF00011E000', 'pkg_ver': 'v0', 'gfx_api': 'nvn', 'chain': chain, 'profile_id': '01007EF00011E001', 'profile_kind': 'provisional'},
                w1,
                profile_dir=prof1,
            )

            prep1 = mod._prepare_from_seed(args, 'auto', seed_root, [], gamemod, {}, False)
            self.assertEqual(prep1['app'], 0x01007EF00011E001)
            self.assertEqual((prep1['game'] / 'ExeFS' / 'main').read_bytes(), b'MAIN1')
            self.assertEqual(prep1['work'], work_root.resolve() / 'programs' / '01007EF00011E001_build')
        finally:
            mod.PROGRAM_INDEX = saved_prog_idx
            os.environ.clear()
            os.environ.update(saved_env)
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == '__main__':
    unittest.main()
