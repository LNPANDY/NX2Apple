"""Exercise the rewriter's copied-base and masked-predecessor jump table recognition on real AArch64 instructions, without game files."""
import ast
from pathlib import Path
import re
import struct
import sys
import unittest

from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
from capstone.arm64 import ARM64_OP_IMM

TOOLS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS))
from nso_asm import ADRP, ADDI, ADDR, B, BEQ, BLR, BR, NOP

# patch_nso.py is a command-line program whose top level loads and rewrites an image.
# Compile its actual recognition functions without executing that driver.
tree = ast.parse((TOOLS / 'patch_nso.py').read_text())
IMG = bytearray(0x5000); tabjumps = {}; jumps = {}   # the globals the recognizers read: the module image and the jump tables resolved so far in the function
scope = {'re': re, 'struct': struct, 'ARM64_OP_IMM': ARM64_OP_IMM, 'IMG': IMG, 'tabjumps': tabjumps, 'jumps': jumps}
exec(compile(ast.Module(body=[n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name in ('num', 'copied_base', 'table_base', 'forward_table_base', 'check_before_copy', 'jump_offsets', 'jump_masked_pred', 'jump_masked_not')], type_ignores=[]), str(TOOLS / 'patch_nso.py'), 'exec'), scope)


def mov(dst, src, wide=True): return (0xaa0003e0 if wide else 0x2a0003e0) | src << 16 | dst


class CopiedBase(unittest.TestCase):
    def follow(self, words, reg='x7'):
        md = Cs(CS_ARCH_ARM64, CS_MODE_ARM); md.detail = True
        ins = list(md.disasm(struct.pack('<' + 'I' * len(words), *words), 0))
        self.assertEqual(len(ins), len(words))
        return scope['copied_base'](ins, len(ins), reg)

    def base(self, reg=7): return [ADRP(reg, 0, 0x4000), ADDI(reg, reg, 0x40c)]

    def test_far_copy_through_lr(self):
        self.assertEqual(self.follow(self.base() + [mov(30, 7)] + [NOP] * 688 + [mov(7, 30)]), 0x440c)

    def test_32_bit_writers_destroy_base(self):
        for clobber in (mov(7, 0, False), 0x52800027, ADDI(7, 7, 1) & 0x7fffffff):
            with self.subTest(clobber=hex(clobber)):
                self.assertIsNone(self.follow(self.base() + [clobber, mov(30, 7), mov(7, 30)]))
        self.assertIsNone(self.follow(self.base() + [mov(30, 7), mov(30, 0, False), mov(7, 30)]))

    def test_calls_clobber_volatile_and_link_registers(self):
        for call in (0x94000000, BLR(0)):
            self.assertIsNone(self.follow(self.base() + [call]))
            self.assertIsNone(self.follow(self.base() + [mov(30, 7), call, mov(7, 30)]))
            self.assertEqual(self.follow(self.base(19) + [call, mov(7, 19)]), 0x440c)

    def test_aliases_and_unrelated_writes(self):
        self.assertEqual(self.follow(self.base(29) + [mov(7, 29)]), 0x440c)
        self.assertEqual(self.follow(self.base(30), 'lr'), 0x440c)
        self.assertEqual(self.follow(self.base() + [mov(8, 0, False)]), 0x440c)
        self.assertIsNone(self.follow(self.base() + [mov(7, 0)]))


RET = 0xd65f03c0
AND_X6_X17_7FF = 0x92400000 | 10 << 10 | 17 << 5 | 6      # and x6, x17, #0x7ff
AND_X6_X17_FF = 0x92400000 | 7 << 10 | 17 << 5 | 6        # and x6, x17, #0xff
AND_W18_W17_7FF = 0x12000000 | 10 << 10 | 17 << 5 | 18    # and w18, w17, #0x7ff
UBFX_W18_W17 = 0x53000000 | 11 << 16 | 12 << 10 | 17 << 5 | 18   # ubfx w18, w17, #0xb, #2
CMP_W18_3 = 0x7100001f | 3 << 10 | 18 << 5                # cmp w18, #3
CMP_W18_1 = 0x7100001f | 1 << 10 | 18 << 5                # cmp w18, #1
LDRSW_X18 = 0xb8a07800 | 6 << 16 | 27 << 5 | 18           # ldrsw x18, [x27, x6, lsl #2]


def cbz_w18(frm, to): return 0x34000000 | (((to - frm) >> 2) & 0x7ffff) << 5 | 18
def bhi(frm, to): return 0x54000008 | (((to - frm) >> 2) & 0x7ffff) << 5


class ForwardBase(unittest.TestCase):
    """Entry jumps over the dispatch to its sole base initialization, then branches backward."""
    TABLE = 0x4040
    TARGETS = [24, 28, 44]

    def setUp(self):
        for i, target in enumerate(self.TARGETS): struct.pack_into('<i', IMG, self.TABLE + 4 * i, target - self.TABLE)
        struct.pack_into('<i', IMG, self.TABLE + 12, 0x1000)   # not a fourth entry
        tabjumps.clear(); jumps.clear()

    def words(self, **over):
        # cmp w18,#2; b.hi; ldrsw x18,[x17,x18,lsl #2]; add x18,x18,x17; br x18.
        words = [B(0, 32), 0x71000a5f, bhi(8, 28), 0xb8b27a32, ADDR(18, 18, 17), BR(18), NOP, RET,
                 ADRP(17, 32, self.TABLE), ADDI(17, 17, self.TABLE & 0xfff), B(40, 4), NOP, RET]
        for k, v in over.items(): words[int(k[1:])] = v
        return words

    def run_site(self, words, forward=True):
        md = Cs(CS_ARCH_ARM64, CS_MODE_ARM); md.detail = True
        ins = [p for i, word in enumerate(words) for p in md.disasm(struct.pack('<I', word), 4 * i)]
        j = next(i for i, p in enumerate(ins) if p.address == 20)
        return scope['jump_offsets'](ins, j, copy_first=True, far_base=True, forward_base=forward)

    def test_later_initialization_and_exact_extent(self):
        self.assertIsNone(self.run_site(self.words(), forward=False))
        self.assertEqual(self.run_site(self.words()), self.TARGETS)

    def test_base_writers_must_be_unique_full_width_and_adjacent(self):
        for slot, word in ((8, NOP), (9, mov(17, 0, False)), (9, ADDI(17, 17, 0x40) & 0x7fffffff),
                           (11, mov(17, 0)), (11, 0x94000000), (11, BLR(0))):
            with self.subTest(slot=slot, word=hex(word)):
                self.assertIsNone(self.run_site(self.words(**{f'w{slot}': word})))
        words = self.words(); words.insert(9, NOP)
        self.assertIsNone(self.run_site(words))

    def test_no_entry_may_bypass_the_page_initialization(self):
        for target in (8, 12, 16, 20, 36):
            self.assertIsNone(self.run_site(self.words(w11=B(44, target))))
        tabjumps[0x1000] = [36]
        self.assertIsNone(self.run_site(self.words()))
        tabjumps.clear(); jumps[0x1000] = (32, 2)
        self.assertIsNone(self.run_site(self.words()))
        jumps.clear()
        struct.pack_into('<i', IMG, self.TABLE, 36 - self.TABLE)
        self.assertIsNone(self.run_site(self.words()))

    def test_guard_must_bound_the_loaded_index(self):
        for word in (BEQ(8, 28), bhi(8, 12), NOP):
            self.assertIsNone(self.run_site(self.words(w2=word)))

    def test_targets_must_be_decoded_instructions_and_table_in_bounds(self):
        self.assertIsNone(self.run_site(self.words(w11=0xe7ffdefe)))
        for target in (25, 0x1000):
            struct.pack_into('<i', IMG, self.TABLE, target - self.TABLE)
            self.assertIsNone(self.run_site(self.words()))
        struct.pack_into('<i', IMG, self.TABLE, self.TARGETS[0] - self.TABLE)
        self.assertIsNone(self.run_site(self.words(w8=ADRP(17, 32, 0x5000))))


class IndexCopiedBeforeCheck(unittest.TestCase):
    def run_site(self, middle):
        table = 0x4040
        words = [ADRP(9, 0, table), ADDI(9, 9, table & 0xfff), mov(18, 17, False)] + middle
        at = len(words) * 4
        words += [0x7100123f, bhi(at + 4, at + 20), 0xb8b27932, ADDR(18, 18, 9), BR(18), RET]
        for i in range(5): struct.pack_into('<i', IMG, table + 4 * i, at + 20 - table)
        md = Cs(CS_ARCH_ARM64, CS_MODE_ARM); md.detail = True
        ins = [p for i, w in enumerate(words) for p in md.disasm(struct.pack('<I', w), 4 * i)]
        j = next(i for i, p in enumerate(ins) if p.mnemonic == 'br')
        return scope['jump_offsets'](ins, j, copy_first=True, far_base=True), [at + 20] * 5

    def test_copy_beyond_old_search_limit(self):
        actual, expected = self.run_site([NOP] * 75)
        self.assertEqual(actual, expected)

    def test_source_and_index_must_remain_unchanged(self):
        for reg in (17, 18):
            with self.subTest(reg=reg):
                self.assertIsNone(self.run_site([NOP] * 65 + [mov(reg, 0, False)])[0])

    def test_calls_and_undecodable_gaps_break_the_chain(self):
        for word in (0x94000000, BLR(0), 0xe7ffdefe):
            with self.subTest(word=hex(word)):
                self.assertIsNone(self.run_site([NOP] * 65 + [word])[0])


class MaskedPredecessor(unittest.TestCase):
    """The block `and w18,w17,#M; cmp w18,#3; b.hi; ldrsw x18,[x27,x6,lsl #2]; add; br x18` whose index x6 was masked from x17 in the block that branches to it.
    Word indices of the synthetic function: 0-1 base (adrp + add), 2-4 the predecessor (and x6, ubfx, cbz), 5 filler, 6 ret, 7-15 the dispatch block (and at 7, slots at 10, 12 and 14),
    16 ret, 17-20 the four targets. The table is at 0x4040 in the image."""
    TABLE = 0x4040
    TARGETS = [0x44, 0x48, 0x4c, 0x50]

    def setUp(self):
        for i, t in enumerate(self.TARGETS): struct.pack_into('<i', IMG, self.TABLE + 4 * i, t - self.TABLE)
        tabjumps.clear(); jumps.clear()

    def words(self, **over):
        w = [ADRP(27, 0, self.TABLE), ADDI(27, 27, self.TABLE & 0xfff), AND_X6_X17_7FF, UBFX_W18_W17, cbz_w18(16, 28), NOP, RET,
             AND_W18_W17_7FF, CMP_W18_3, bhi(36, 64), NOP, LDRSW_X18, NOP, ADDR(18, 18, 27), NOP, BR(18), RET, NOP, NOP, NOP, NOP]
        for k, v in over.items(): w[int(k[1:])] = v
        return w

    def run_site(self, words, undecodable=False):
        md = Cs(CS_ARCH_ARM64, CS_MODE_ARM); md.detail = True
        # The driver skips words Capstone cannot decode and resumes at the next word.
        ins = [p for i, word in enumerate(words) for p in md.disasm(struct.pack('<I', word), 4 * i)]
        self.assertEqual(len(ins), len(words) - int(undecodable))
        return scope['jump_masked_pred'](ins, next(i for i, p in enumerate(ins) if p.mnemonic == 'br' and p.op_str == 'x18'))

    def test_recognized(self):
        self.assertEqual(self.run_site(self.words()), self.TARGETS)

    def test_base_can_be_hoisted_far_back_or_built_in_dispatch(self):
        for local in (False, True):
            with self.subTest(local=local):
                words = self.words()
                if local:
                    words[:2] = [NOP, NOP]
                    words[10] = ADRP(27, 40, self.TABLE)
                    words.insert(11, ADDI(27, 27, self.TABLE & 0xfff))
                    words[16:16] = [mov(22, 30)] * 10   # ten register moves after the add
                    shift = 44; words[9] = bhi(36, 64 + shift)
                else:
                    words[2:2] = [NOP] * 300   # base more than 256 instructions before the load
                    shift = 1200
                targets = [t + shift for t in self.TARGETS]
                for i, t in enumerate(targets): struct.pack_into('<i', IMG, self.TABLE + 4 * i, t - self.TABLE)
                self.assertEqual(self.run_site(words), targets)

    def test_compare_in_the_block_does_not_count_as_a_write(self):
        self.assertEqual(self.run_site(self.words(w14=CMP_W18_1)), self.TARGETS)

    def test_predecessor_must_mask_the_same_way(self):
        self.assertIsNone(self.run_site(self.words(w2=AND_X6_X17_FF)))
        self.assertIsNone(self.run_site(self.words(w2=NOP)))
        self.assertIsNone(self.run_site(self.words(w3=0x2a0003f1)))   # mov w17, w0: the source changes between the and and the branch

    def test_block_entered_only_by_branches(self):
        self.assertIsNone(self.run_site(self.words(w6=NOP)))   # falls through into the and
        self.assertIsNone(self.run_site(self.words(w5=cbz_w18(20, 44))))   # another branch lands inside the block, past its and
        tabjumps[0x1000] = {0x20}   # a jump table already resolved in the function lands on the cmp
        self.assertIsNone(self.run_site(self.words()))
        tabjumps.clear(); jumps[0x1004] = (0x20, 4)   # a byte or half-word table that reaches the block
        self.assertIsNone(self.run_site(self.words()))

    def test_registers_unchanged_between_check_and_use(self):
        self.assertIsNone(self.run_site(self.words(w10=mov(6, 0))))   # the index changes after the check
        self.assertIsNone(self.run_site(self.words(w12=mov(27, 0))))   # the base changes between the load and the add
        self.assertIsNone(self.run_site(self.words(w12=mov(18, 0))))   # x18 is rewritten before the add
        self.assertIsNone(self.run_site(self.words(w14=mov(18, 0))))   # x18 is rewritten after the add

    def test_tables_cannot_bypass_predecessor_mask(self):
        for target in (12, 16):   # the ubfx or cbz, after the predecessor's and
            with self.subTest(target=target, table='offset'):
                tabjumps[0x1000] = {target}
                self.assertIsNone(self.run_site(self.words()))
                tabjumps.clear()
            with self.subTest(target=target, table='byte'):
                jumps[0x1004] = (target, 1)
                self.assertIsNone(self.run_site(self.words()))
                jumps.clear()

    def test_table_can_enter_at_predecessor_mask(self):
        tabjumps[0x1000] = {8}; jumps[0x1004] = (8, 1)
        self.assertEqual(self.run_site(self.words()), self.TARGETS)

    def test_calls_cannot_enter_after_a_mask(self):
        for target in (12, 16, 28, 44):   # predecessor, dispatch head or load
            with self.subTest(target=target):
                self.assertIsNone(self.run_site(self.words(w5=B(20, target) | 0x80000000)))

    def test_32_bit_writer_destroys_table_base(self):
        self.assertIsNone(self.run_site(self.words(w5=mov(27, 0, wide=False))))

    def test_undecodable_words_cannot_be_targets_or_hide_writes(self):
        for slot in (3, 10, 17):   # predecessor, dispatch, target
            with self.subTest(slot=slot):
                self.assertIsNone(self.run_site(self.words(**{f'w{slot}': 0xe7ffdefe}), undecodable=True))

    def test_targets_must_be_instructions_of_the_function(self):
        struct.pack_into('<i', IMG, self.TABLE + 12, 0x1000)
        self.assertIsNone(self.run_site(self.words()))

    def test_no_base_no_site(self):
        self.assertIsNone(self.run_site(self.words(w0=NOP, w1=NOP)))


class MaskedComplement(unittest.TestCase):
    TABLE = 0x4040
    TARGETS = [0x30 + i * 4 for i in range(7)]

    def setUp(self):
        tabjumps.clear(); jumps.clear()
        for i, t in enumerate(self.TARGETS): struct.pack_into('<i', IMG, self.TABLE + 4 * i, t - self.TABLE)
        # The next table's first word is deliberately not a target of this function.
        struct.pack_into('<i', IMG, self.TABLE + 28, 0x1000)

    def words(self, **over):
        w = [ADRP(11, 0, self.TABLE), ADDI(11, 11, self.TABLE & 0xfff),
             0x720009ff, BEQ(12, 44), 0x2a2f03ef, 0x924009ef, NOP,
             0xb8af796f, ADDR(18, 15, 11), mov(15, 16, False), BR(18), RET] + [NOP] * 7
        for k, v in over.items(): w[int(k[1:])] = v
        return w

    def run_site(self, words):
        md = Cs(CS_ARCH_ARM64, CS_MODE_ARM); md.detail = True
        ins = [p for i, word in enumerate(words) for p in md.disasm(struct.pack('<I', word), 4 * i)]
        return scope['jump_masked_not'](ins, next(i for i, p in enumerate(ins) if p.mnemonic == 'br' and p.op_str == 'x18'))

    def test_reads_exactly_seven_entries(self):
        self.assertEqual(self.run_site(self.words()), self.TARGETS)

    def test_guard_source_mask_and_complement_must_agree(self):
        for slot, word in ((2, 0x720009df), (2, 0x72000dff), (3, BEQ(12, 44) | 1), (3, BEQ(12, 20)),
                           (4, NOP), (4, 0x2a2e03ef), (5, 0x92400def)):
            with self.subTest(slot=slot, word=hex(word)):
                self.assertIsNone(self.run_site(self.words(**{f'w{slot}': word})))

    def test_intervening_writes_control_flow_and_undecodable_words(self):
        for slot, word in ((6, mov(15, 0)), (6, mov(11, 0, False)), (6, BLR(0)), (6, B(24, 28)), (6, 0xe7ffdefe), (9, mov(18, 0))):
            with self.subTest(slot=slot, word=hex(word)):
                self.assertIsNone(self.run_site(self.words(**{f'w{slot}': word})))

    def test_incoming_edges_cannot_bypass_the_guard(self):
        for target in (12, 16, 20, 24, 28, 32, 36, 40):
            with self.subTest(target=target):
                self.assertIsNone(self.run_site(self.words(w11=B(44, target))))
        tabjumps[0x1000] = [20]
        self.assertIsNone(self.run_site(self.words()))
        tabjumps.clear(); jumps[0x1004] = (0, 8)
        self.assertIsNone(self.run_site(self.words()))
        jumps.clear()
        self.assertEqual(self.run_site(self.words(w11=B(44, 8))), self.TARGETS)

    def test_base_and_targets_must_be_valid(self):
        self.assertIsNone(self.run_site(self.words(w0=NOP)))
        self.assertIsNone(self.run_site(self.words(w1=mov(11, 0, False))))
        self.assertIsNone(self.run_site(self.words(w12=0xe7ffdefe)))
        struct.pack_into('<i', IMG, self.TABLE + 24, 0x1000)
        self.assertIsNone(self.run_site(self.words()))

    def test_this_tables_targets_cannot_bypass_the_guard(self):
        for target in (12, 16, 20, 28, 40):
            with self.subTest(target=target):
                struct.pack_into('<i', IMG, self.TABLE, target - self.TABLE)
                self.assertIsNone(self.run_site(self.words()))
        struct.pack_into('<i', IMG, self.TABLE, 8 - self.TABLE)
        self.assertEqual(self.run_site(self.words()), [8] + self.TARGETS[1:])


if __name__ == '__main__': unittest.main()
