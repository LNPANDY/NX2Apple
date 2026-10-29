"""Production reflection conversion with synthetic translator descriptors."""
import ast
from pathlib import Path
import re
import sys
import unittest

TOOLS = Path(__file__).resolve().parents[1] / 'tools'
sys.path.insert(0, str(TOOLS))
import dmsh_abi
import dmsh_geometry


def builder_reflection():
    # Isolate pure reflection code from the builder's CLI/profile initialization.
    tree = ast.parse((TOOLS / 'dmsh_build.py').read_text())
    names = {'reflect', 'decode_tex', 'decode_ubo_tex', 'const_sampler', 'c2_array'}
    selected = [n for n in tree.body if (isinstance(n, ast.FunctionDef) and n.name in names)
                or (isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'SSBO' for t in n.targets))
                or (isinstance(n, ast.Assign) and any(isinstance(t, ast.Tuple) and any(isinstance(e, ast.Name) and e.id == 'TEX_BASE' for e in t.elts) for t in n.targets))]
    ns = {'re': re, 'dmsh_geometry': dmsh_geometry, 'abi': dmsh_abi}
    exec(compile(ast.Module(body=selected, type_ignores=[]), str(TOOLS / 'dmsh_build.py'), 'exec'), ns)
    return ns['reflect']


REFLECT = builder_reflection()


def bindings(stage, offsets, flags, cb_slot=0):
    source = 'struct spvDescriptorSetBuffer0\n{\n' + ''.join(
        f'    device uint* gp_s{i} [[id({i})]];\n' for i in range(len(offsets))) + '};\n'
    res = {'sbufs': [{'binding': 40 + i, 'slot': i, 'cb_slot': cb_slot,
                      'cb_offset': off // 4, 'flags': flag}
                     for i, (off, flag) in enumerate(zip(offsets, flags))]}
    return REFLECT('synthetic', stage, source, res)


class StorageBuffers(unittest.TestCase):
    def test_geometry_driver_table_offsets(self):
        got = bindings('gs', [0x410, 0x430], [1, 1])
        self.assertEqual([(b['kind'], b['reg']) for b in got], [('sbuf', 0), ('sbuf', 2)])

    def test_write_flag_from_translator_json(self):
        # BufferUsageFlags.Write = 1 << 0; Program.cs serializes it unchanged.
        got = bindings('cs', [0x310, 0x320], [1, 0])
        self.assertEqual([b['rw'] for b in got], [True, False])

    def test_write_flag_for_address_in_guest_uniform(self):
        got = bindings('gs', [0x38], [1], cb_slot=3)
        self.assertEqual((got[0]['kind'], got[0]['reg'], got[0]['off'], got[0]['rw']),
                         ('sbuf_ubo', 0, 0x38, True))

    def test_existing_stage_tables(self):
        for stage, base in [('vs', 0x110), ('cs', 0x310), ('ps', 0x510)]:
            with self.subTest(stage=stage):
                got = bindings(stage, [base, base + 15 * 16], [0, 0])
                self.assertEqual([b['reg'] for b in got], [0, 15])

    def test_unknown_or_unaligned_offsets_stay_unresolved(self):
        self.assertIsNone(bindings('gs', [0x414], [1])[0]['reg'])
        self.assertIsNone(bindings('hs', [0x410], [1])[0]['reg'])


class DriverTableArrays(unittest.TestCase):
    def reflect(self, members):
        source = 'struct spvDescriptorSetBuffer0\n{\n' + ''.join(f'    {t} {n} [[id({i})]];\n' for t, n, i in members) + '};\n'
        return REFLECT('synthetic', 'ps', source, {'sbufs': []})

    def test_combined_handles(self):   # Luigi's Mansion 3's shadow cascades: element k = the handle at c2 byte 8k
        got = self.reflect([('array<texture2d_array<float>, 301>', 'fp_t2das_cb2_0', 0), ('array<sampler, 301>', 'fp_t2das_cb2_0Smplr', 301)])
        self.assertEqual([(b['kind'], b['off'], b.get('soff')) for b in got], [('tex_c2a', 0, None), ('samp_c2a', 0, None)])

    def test_one_separate_sampler_word(self):   # EA SPORTS FC 27's lights: texture words from c2 byte 0, the sampler word at c2 byte 0x570 ORed into each
        got = self.reflect([('array<texture2d<float>, 301>', 'fp_t2d_cb196610_10570000', 0), ('array<sampler, 301>', 'fp_t2d_cb196610_10570000Smplr', 301)])
        self.assertEqual([(b['kind'], b['off'], b.get('soff')) for b in got], [('tex_c2a', 0, 0x570), ('samp_c2a', 0, 0x570)])

    def test_sampler_word_in_another_buffer_is_not_a_driver_table_array(self):   # the sampler word in c3 (slots 0x40002): not this form
        got = self.reflect([('array<texture2d<float>, 301>', 'fp_t2d_cb262146_10570000', 0)])
        self.assertNotEqual(got[0]['kind'], 'tex_c2a')


def builder_unfillable():
    tree = ast.parse((TOOLS / 'dmsh_build.py').read_text())
    keep = lambda n: (isinstance(n, ast.FunctionDef) and n.name in ('drv_reads', 'unfillable')) or (isinstance(n, ast.Assign) and any(
        (isinstance(t, ast.Name) and t.id in ('SSBO', 'DRV_FILL')) or (isinstance(t, ast.Tuple) and any(isinstance(e, ast.Name) and e.id == 'TEX_BASE' for e in t.elts)) for t in n.targets))
    ns = {'re': re, 'abi': dmsh_abi}
    exec(compile(ast.Module(body=[n for n in tree.body if keep(n)], type_ignores=[]), str(TOOLS / 'dmsh_build.py'), 'exec'), ns)
    return lambda src: ns['unfillable'](ns['drv_reads'](src))


UNFILLABLE = builder_unfillable()


class DriverReads(unittest.TestCase):
    def test_computed_c2_index_reads_the_filled_tables(self):   # EA SPORTS FC 27's lights: (*spvDescriptorSet0.fp_c2)._m0[int(_237)][_239]
        self.assertEqual(UNFILLABLE('float _241 = (*spvDescriptorSet0.fp_c2)._m0[int(_237)][_239];'), [])

    def test_computed_c0_index_is_refused(self):
        self.assertEqual(UNFILLABLE('float x = (*spvDescriptorSet0.fp_c0)._m0[int(_5)].x;'), ['c0 dynamic index'])

    def test_c2_word_outside_the_tables_is_refused(self):
        self.assertEqual(UNFILLABLE('float x = (*spvDescriptorSet0.fp_c2)._m0[0].x;'), ['c2+0x0'])


if __name__ == '__main__':
    unittest.main()
