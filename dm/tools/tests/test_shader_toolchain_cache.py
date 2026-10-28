"""Compiler changes must invalidate every cache that can restore compiled shader libraries.
Exercise the builder's real key/restore functions without game files or Xcode.
"""
import ast
import collections
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import types
from typing import Any
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[3]
TOOLS = REPO / 'dm/gfx/tools'
sys.path.insert(0, str(TOOLS))
import dmsh_chain  # noqa: E402
import dmsh_mtlcache  # noqa: E402

spec = importlib.util.spec_from_file_location('nsp_toolchain_cache', REPO / 'scripts/build_ipa_from_nsp.py')
assert spec and spec.loader
nsp = importlib.util.module_from_spec(spec); spec.loader.exec_module(nsp)


class ShaderCache(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.ns: dict[str, Any] = dict(hashlib=hashlib, os=os, json=json, re=re, threading=threading,
                       subprocess=subprocess, dmsh_chain=dmsh_chain, SPIRV_CROSS='converter',
                       XC=['--msl'], MAC_RECORD='mac flags', IOSOUT=None, TARGETS={'mac'},
                       ios_metal=types.SimpleNamespace(RECORD='ios flags'), METAL_FP='tested Metal and SDK',
                       FACTS={}, MAP_ROWS={}, MAP_CONFLICT_ROWS={}, CODE_FP='source', PROFILE_ROWS=b'', PAIRS={},
                       BF_WANT=set(), BF_STATS=collections.Counter(), CAS=str(root / 'cas'), out=str(root / 'out'),
                       CHAIN='test-chain', clone=shutil.copyfile, shader_rule_source=lambda name: b'')
        (root / 'out').mkdir()
        names = {'tool_fingerprint', 'shader_key', 'cache_path', 'cache_outputs', 'restore_cache', 'publish_cache', 'atomic_json', 'cache_meta_path',
                 'bf_digest', 'bf_cache_root', 'bf_cache_restore'}
        tree = ast.parse((TOOLS / 'dmsh_build.py').read_text())
        nodes: list[ast.stmt] = [n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name in names]
        self.assertEqual({n.name for n in nodes if isinstance(n, ast.FunctionDef)}, names)
        exec(compile(ast.Module(body=nodes, type_ignores=[]), str(TOOLS / 'dmsh_build.py'), 'exec'), self.ns)

    def digest(self):
        with mock.patch.object(subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, 'same revision', '')):
            self.ns['TOOL_FP'] = self.ns['tool_fingerprint']().encode()
        return self.ns['shader_key']('key', 'shader', b'original shader')

    def test_return_to_tested_compiler_does_not_restore_override_libraries(self):
        for ios in (False, True):
            with self.subTest(ios=ios):
                ios_dir = Path(self.tmp.name) / 'ios'
                self.ns['IOSOUT'] = str(ios_dir) if ios else None
                self.ns['TARGETS'] = {'mac', 'ios'} if ios else {'mac'}
                if ios: ios_dir.mkdir(exist_ok=True)
                self.ns['METAL_FP'] = 'override Metal and SDK'
                old = self.digest()
                for target in ('mac', 'ios') if ios else ('mac',):
                    d = Path(self.ns['cache_path'](old)) / target; d.mkdir(parents=True, exist_ok=True)
                    (d / 'key_b.metallib').write_bytes(b'untested compiled library')
                    (d / 'key_b.json').write_text('{}')
                    if target == 'mac': (d / 'key_b.metal').write_text('MSL')
                self.assertTrue(self.ns['restore_cache']('key', old))
                self.ns['METAL_FP'] = 'tested Metal and SDK'
                self.assertFalse(self.ns['restore_cache']('key', self.digest()))

    def test_fetch_variants_do_not_restore_override_libraries(self):
        self.ns['METAL_FP'] = 'override Metal and SDK'
        old = self.ns['bf_digest']('same fetch MSL', 'key')
        d = Path(self.ns['bf_cache_root'](old)); d.mkdir(parents=True)
        (d / 'metal').write_text('same fetch MSL'); (d / 'mac.metallib').write_bytes(b'untested variant')
        self.ns['METAL_FP'] = 'tested Metal and SDK'
        current = self.ns['bf_digest']('same fetch MSL', 'key')
        self.assertFalse(self.ns['bf_cache_restore']('key', current, {}, str(Path(self.tmp.name) / 'fetch.metal')))

    def test_unchanged_compiler_reuses_key(self):
        self.assertEqual(self.digest(), self.digest())

    def test_ios_cache_restores_analysis_files_and_geometry_without_mac_libraries(self):
        self.ns.update(TARGETS={'ios'}, IOSOUT=str(Path(self.tmp.name) / 'ios'))
        mac, ios = Path(self.ns['out']), Path(self.ns['IOSOUT']); ios.mkdir()
        # Geometry's side outputs are restored; vertex and fragment side libraries are regenerated from the base MSL.
        expected = {}
        for suffix in ('_b', '_bg0', '_bg1', '_bg2', '_bg3', '_bg4', '_bgv', '_bl0', '_bl1', '_bl3'):
            for d, extensions in ((mac, ('.metal', '.json')), (ios, ('.metallib', '.json'))):
                for ext in extensions:
                    p = d / ('key' + suffix + ext)
                    p.write_text(json.dumps({'chain': 'test-chain', 'stage': 'gs'}, indent=1) if ext == '.json' else suffix + ext)
                    expected[p] = p.read_bytes()
        self.ns['publish_cache']('key', 'digest', 'rule', 'source')
        for p in expected: p.unlink()
        self.assertTrue(self.ns['restore_cache']('key', 'digest'))
        self.assertEqual({p: p.read_bytes() for p in expected}, expected)
        self.assertEqual(list(mac.glob('*.metallib')), [])
        # A later dual-target run needs the missing Mac libraries, rather than accepting analysis files as a Mac hit.
        self.ns['TARGETS'] = {'mac', 'ios'}
        self.assertFalse(self.ns['restore_cache']('key', 'digest'))

    def test_cache_without_analysis_source_is_a_miss(self):
        self.ns.update(TARGETS={'ios'}, IOSOUT=str(Path(self.tmp.name) / 'ios'))
        root = Path(self.ns['cache_path']('digest'))
        for label in ('mac', 'ios'):
            (root / label).mkdir(parents=True)
            (root / label / 'key_b.json').write_text('{}')
        (root / 'ios/key_b.metallib').write_bytes(b'library')
        self.assertFalse(self.ns['restore_cache']('key', 'digest'))

    def test_dual_target_cache_restores_only_requested_ios_libraries(self):
        root = Path(self.ns['cache_path']('digest'))
        for label in ('mac', 'ios'):
            (root / label).mkdir(parents=True)
            (root / label / 'key_b.json').write_text('{}')
            (root / label / 'key_b.metallib').write_bytes(label.encode())
        (root / 'mac/key_b.metal').write_text('MSL')
        self.ns.update(TARGETS={'ios'}, IOSOUT=str(Path(self.tmp.name) / 'ios'))
        Path(self.ns['IOSOUT']).mkdir()
        self.assertTrue(self.ns['restore_cache']('key', 'digest'))
        self.assertEqual((Path(self.ns['out']) / 'key_b.metal').read_text(), 'MSL')
        self.assertFalse((Path(self.ns['out']) / 'key_b.metallib').exists())


class TargetSelection(unittest.TestCase):
    def test_mesh_compiles_only_requested_targets(self):
        tree = ast.parse((TOOLS / 'dmsh_build.py').read_text())
        function = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == 'mesh_finish')
        with tempfile.TemporaryDirectory() as td:
            root = Path(td); ios = root / 'ios'; ios.mkdir()
            (root / 'vertex_b.metal').write_text('vertex source')
            (root / 'geometry_bl3.metal').write_text('geometry source')
            (root / 'geometry_bl3.json').write_text(json.dumps({'geometry': {'capture_reads': [36]}}))
            for targets in ({'mac'}, {'ios'}, {'mac', 'ios'}):
                with self.subTest(targets=targets):
                    compile_target = mock.Mock()
                    compose = mock.Mock(return_value='mesh source')
                    ns: dict[str, Any] = dict(os=os, json=json, subprocess=subprocess, out=td, w=td, TARGETS=targets,
                              IOSOUT=str(ios) if 'ios' in targets else None, MESH_STATS=collections.Counter(),
                              MTL=types.SimpleNamespace(compile=compile_target), dmsh_mesh=types.SimpleNamespace(compose=compose))
                    exec(compile(ast.Module(body=[function], type_ignores=[]), '<mesh targets>', 'exec'), ns)
                    ns['mesh_finish'](('vertex', 'geometry'))
                    compose.assert_called_once_with('vertex source', 'geometry source', [36])
                    self.assertEqual([call.args[0] for call in compile_target.call_args_list], [t for t in ('mac', 'ios') if t in targets])
                    self.assertEqual(ns['MESH_STATS']['built'], 1)

    def selection(self, env):
        tree = ast.parse((TOOLS / 'dmsh_build.py').read_text())
        start = next(i for i, n in enumerate(tree.body) if isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'IOSOUT' for t in n.targets))
        end = next(i for i, n in enumerate(tree.body) if i > start and isinstance(n, ast.If) and isinstance(n.test, ast.Name) and n.test.id == 'IOSOUT')
        ns = dict(os=os, sys=sys)
        with mock.patch.dict(os.environ, env, clear=True):
            exec(compile(ast.Module(body=tree.body[start:end], type_ignores=[]), '<target selection>', 'exec'), ns)
        return ns['TARGETS'], ns['IOSOUT']

    def test_defaults_and_explicit_targets(self):
        for env, targets, ios in (({}, {'mac'}, None), ({'IOSOUT': 'phone'}, {'mac', 'ios'}, 'phone'),
                                  ({'DMSH_TARGETS': 'mac', 'IOSOUT': 'phone'}, {'mac'}, None),
                                  ({'DMSH_TARGETS': 'ios', 'IOSOUT': 'phone'}, {'ios'}, 'phone')):
            with self.subTest(env=env): self.assertEqual(self.selection(env), (targets, ios))

    def test_invalid_targets(self):
        for env in ({'DMSH_TARGETS': 'ios'}, {'DMSH_TARGETS': 'other'}, {'DMSH_TARGETS': ', '}):
            with self.subTest(env=env), self.assertRaises(SystemExit): self.selection(env)


class StageCache(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def key(self, env, version='tested Metal', sdk='SDK build'):
        def run(cmd, **kwargs):
            text = version if 'metal' in cmd else sdk if '--show-sdk-build-version' in cmd else 'unchanged tool'
            return subprocess.CompletedProcess(cmd, 0, text, '')
        with mock.patch.object(nsp.subprocess, 'run', side_effect=run), mock.patch.dict(os.environ, env, clear=True):
            return nsp.fingerprint(*nsp.toolchain(REPO), env=env)

    def test_selected_converter_content_invalidates_reuse(self):
        converter = self.root / 'spirv-cross'; converter.write_bytes(b'converter A'); converter.chmod(0o755)
        env = dict(os.environ, SPIRV_CROSS=str(converter))
        before = self.key(env)
        converter.write_bytes(b'converter B')
        self.assertNotEqual(before, self.key(env))

    def test_actual_metal_or_sdk_change_invalidates_reuse(self):
        env = dict(os.environ)
        before = self.key(env)
        self.assertNotEqual(before, self.key(env, version='override Metal'))
        self.assertNotEqual(before, self.key(env, sdk='different SDK build'))


class MetalPrefill(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name); self.old = self.root / 'b-old'; self.old.mkdir()
        def compile_current(msl, air, lib): Path(lib).write_bytes(b'TESTED ' + Path(msl).read_bytes())
        with mock.patch.object(dmsh_mtlcache, 'compiler_id', return_value='tested compiler and SDK'):
            self.cache = dmsh_mtlcache.Cache(str(self.root / 'cas'), {'mac': ('macosx', 'flags', compile_current)}, str(self.root))

    def earlier_libraries(self, third_identity):
        for i in range(3):
            stem = f'key{i}_b'; src = f'MSL {i}'.encode()
            (self.old / (stem + '.metal')).write_bytes(src)
            (self.old / (stem + '.metallib')).write_bytes(b'TESTED ' + src if i < 2 else b'WRONG OVERRIDE LIBRARY')
            meta = {'chain_metal': 'flags', 'stage': 'ps', 'chain_compiler': self.cache.ident['mac'].hex()}
            if i == 2:
                if third_identity is None: meta.pop('chain_compiler')
                else: meta['chain_compiler'] = third_identity
            (self.old / (stem + '.json')).write_text(json.dumps(meta))

    def test_every_prefilled_library_requires_matching_compiler_identity(self):
        for identity in (None, 'other compiler'):
            with self.subTest(identity=identity):
                if (self.root / 'cas').exists(): shutil.rmtree(self.root / 'cas')
                self.earlier_libraries(identity)
                self.cache.fill(str(self.old))
                result = self.root / 'result.metallib'
                self.cache.compile('mac', str(self.old / 'key2_b.metal'), str(result))
                self.assertEqual(result.read_bytes(), b'TESTED MSL 2')

    def test_matching_compiler_libraries_still_prefill(self):
        self.earlier_libraries(self.cache.ident['mac'].hex())
        (self.old / 'key2_b.metallib').write_bytes(b'TESTED MSL 2')
        self.cache.fill(str(self.old))
        self.assertEqual(self.cache.stats['mac', 'filled'], 3)

    def test_unrequested_target_is_not_sample_compiled(self):
        self.earlier_libraries(self.cache.ident['mac'].hex())
        with mock.patch.object(self.cache, '_compile') as compile_sample:
            self.cache.fill(str(self.old), targets={'ios'})
        compile_sample.assert_not_called()
        self.assertEqual(self.cache.stats['mac', 'filled'], 0)

    def test_legacy_cache_entries_cannot_restore_misclassified_libraries(self):
        src = b'MSL'; msl = self.root / 'shader.metal'; msl.write_bytes(src)
        old_ident = hashlib.sha256(b'dmsh_mtlcache 1\0flags\0tested compiler and SDK').digest()
        digest = hashlib.sha256(old_ident + b'\0' + src).hexdigest()
        old_path = self.root / 'cas/mac' / digest[:2] / (digest + '.metallib')
        old_path.parent.mkdir(parents=True); old_path.write_bytes(b'WRONG OVERRIDE LIBRARY')
        result = self.root / 'result.metallib'; self.cache.compile('mac', str(msl), str(result))
        self.assertEqual(result.read_bytes(), b'TESTED MSL')


if __name__ == '__main__':
    unittest.main()
