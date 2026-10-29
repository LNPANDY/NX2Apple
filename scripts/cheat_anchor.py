#!/usr/bin/env python3
# Cheats that survive game updates: anchor the addresses of Atmosphère cheat codes to the game's own code, then compile
# them into the plain Atmosphère file (<build ID>.txt) of any build of the game.
#
# An Atmosphère cheat names fixed offsets into the main NSO ("main+0x5607AAE"), valid for one build: every update moves
# them. The source file this tool writes (<game>.cheats.toml) describes each address by what the game's code does instead:
#   - data:  the address that adrp + add / ldr / str pairs in identified functions compute, plus a field offset;
#            optionally through a relocated .data pointer slot ("deref");
#   - code:  the instructions at an offset of an identified function, with their original words;
#   - cave:  the zero padding between the end of the code and the read-only data, where ASM cheats put their own code.
# A function is found first the way the rewriter carries cuts across builds (dm/tools/nso_match.py: a unique function of
# the same length and SHA-256 fingerprint, its body and its direct callees), then by this tool's two fallbacks: the same
# body digest alone (a callee changed), then a window of relocation-masked instructions that occurs once in the whole
# text. No approximate similarity is used, and the original words of a code site are checked however it was found.
# The compiled file is plain Atmosphère text, so every engine runs it: nxnative's host, a Switch, Ryujinx, yuzu forks.
# The source format and the commands are described in docs/development.md, "Cheats that survive game updates".
#
# Usage:
#   cheat_anchor.py import  <cheats.txt> --nso <ExeFS/main of the file's build> -o <game>.cheats.toml
#   cheat_anchor.py compile <game>.cheats.toml --nso <ExeFS/main of the target build> -o <cheats folder> [--plain] [--replace]
#   cheat_anchor.py check   <game>.cheats.toml --nso <ExeFS/main of the target build>
# Needs Python 3.11+ (tomllib) and the README's packages (lz4, capstone). Exit status: 0 everything resolved, 2 some cheats
# were skipped or kept bound to one build (the file is still written; the report says why), 1 an error (nothing written).
import argparse, bisect, datetime, hashlib, re, struct, sys, tomllib
from pathlib import Path

TOOLS = Path(__file__).resolve().parent.parent / 'dm' / 'tools'   # the repository's tools, found from this script's place
sys.path.insert(0, str(TOOLS))
import nso_match                     # function boundaries and fingerprints: the rewriter's cross-build matcher
from nso_syms import load as load_nso
import nacp                          # the display version of a build, from the control.nacp beside its ExeFS

FORMAT = 1                           # the source format version this tool reads and writes
MAX_FIELD = 0x10000                  # a data target may lie this far past the address the code references (a field of a large object)
MAX_REFS = 4                         # code references kept per data anchor (each one is resolved independently)
REFS_TRIED = 12                      # functions examined per data anchor to find MAX_REFS references in functions unique in the build
WINDOW_HALVES = (4, 8, 16)           # instructions kept on each side of a code site for the window search, smallest unique first
KEYS_COUNTED = 4                     # window words whose frequency is counted to pick the rarest one as the search key
LOOKBACK = 8                         # an add / ldr / str up to 8 instructions after an adrp takes the page's low bits (nso_match's rule)
BASES_TRIED = 6                      # nearest referenced addresses (and pointer targets) below a data target considered at import
ATMOSPHERE_WORDS = 0x100             # code words Atmosphère's dmnt accepts per cheat (its program of all enabled cheats: 0x400)
REGION_BITS = 40                     # a region-relative address of opcodes 0 / 1 / 5 has 40 bits
R_AARCH64_RELATIVE = 1027
DATA_KINDS = ('ro', 'data', 'bss')   # Build.where's segments that hold data: the ones a data anchor may describe
TODAY = datetime.date.today().isoformat()


class AnchorError(Exception):
    """A cheat or an anchor that cannot be resolved (the message is the reason the report and the meta file show)."""


def hexu(n):
    """An offset as the report and the anchor names print it: 0x upper-case hex."""
    return f'0x{n:X}'


# ---------- AArch64 words: the PC-relative forms and their relocation masks ----------

def _signed(n, bits):
    """The two's-complement value of the low bits of n (an instruction's signed immediate field)."""
    return n - (1 << bits) if n & (1 << (bits - 1)) else n


def branch_target(w, pc):
    """Target of a B / BL at pc, or None for any other word (the only PC-relative forms the tool re-encodes)."""
    if w & 0x7c000000 == 0x14000000: return pc + _signed(w & 0x3ffffff, 26) * 4
    return None


def pc_relative_target(w, pc):
    """Target of any PC-relative word (B / BL, B.cond, CBZ / CBNZ, TBZ / TBNZ, ADR, ADRP's page, literal load), else None."""
    t = branch_target(w, pc)
    if t is not None: return t
    if w & 0xff000010 == 0x54000000 or w & 0x7e000000 == 0x34000000: return pc + _signed((w >> 5) & 0x7ffff, 19) * 4
    if w & 0x7e000000 == 0x36000000: return pc + _signed((w >> 5) & 0x3fff, 14) * 4
    if w & 0x1f000000 == 0x10000000:
        imm = _signed(((w >> 29) & 3) | ((w >> 5) & 0x7ffff) << 2, 21)
        return (pc & ~0xfff) + (imm << 12) if w & 0x80000000 else pc + imm
    if w & 0x3b000000 == 0x18000000: return pc + _signed((w >> 5) & 0x7ffff, 19) * 4
    return None


def encode_branch(link, pc, target):
    """A B (link False) or BL (link True) from pc to target; refused when out of the +-128 MB range or unaligned."""
    d = target - pc
    if d % 4 or not -(1 << 27) <= d < (1 << 27): raise AnchorError(f'branch from {hexu(pc)} to {hexu(target)} is out of range')
    return (0x94000000 if link else 0x14000000) | ((d >> 2) & 0x3ffffff)


def mask_word(w):
    """One word with its relocation-dependent immediates cleared (nso_fnmap's masks): what stays equal when the same
    instruction moves to another address. The low page bits after an adrp are cleared separately (Build._masked)."""
    for msk, val, keep in ((0x7c000000, 0x14000000, 0xfc000000),   # b / bl
                           (0xff000010, 0x54000000, 0xff00001f),   # b.cond
                           (0x7e000000, 0x34000000, 0xff00001f),   # cbz / cbnz
                           (0x7e000000, 0x36000000, 0xfff8001f),   # tbz / tbnz
                           (0x1f000000, 0x10000000, 0x9f00001f),   # adr / adrp
                           (0x3b000000, 0x18000000, 0xff00001f)):  # literal ldr
        if w & msk == val: return w & keep
    return w


# Encodings that cannot hold an address or a PC-relative offset: (mask, value) per ARMv8 encoding class. Anything not
# listed carries address bits as far as this tool knows (B / BL / B.cond / CBZ / TBZ, ADR / ADRP, literal loads, loads
# and stores with an immediate offset, ADD / SUB immediate, unknown words). The list only widens what may be written
# over a relocated instruction, so it holds only forms whose every field is a register, a condition or a constant.
NO_ADDRESS_FORMS = (
    (0xfffff01f, 0xd503201f),   # HINT (NOP, YIELD, WFE, BTI, ...): System, CRn = 0010, Rt = 11111
    (0x1f800000, 0x12800000),   # Move wide (immediate): MOVN / MOVZ / MOVK (opc 01 is unallocated: carries_address_bits)
    (0x1f000000, 0x0a000000),   # Logical (shifted register): AND, BIC, ORR (MOV register), ORN (MVN), EOR, EON, ANDS, BICS
    (0x1f000000, 0x0b000000),   # Add/subtract (shifted and extended register): ADD, ADDS (CMN), SUB (NEG), SUBS (CMP)
    (0x1fe00000, 0x1a000000),   # Add/subtract (with carry): ADC, ADCS, SBC (NGC), SBCS
    (0x1fe00000, 0x1a800000),   # Conditional select: CSEL, CSINC (CSET), CSINV, CSNEG
    (0x5fe00000, 0x1ac00000),   # Data-processing (2 source): UDIV, SDIV, LSLV, LSRV, ASRV, RORV
    (0x5fe00000, 0x5ac00000),   # Data-processing (1 source): RBIT, REV, CLZ, CLS
    (0x1f000000, 0x1b000000),   # Data-processing (3 source): MADD (MUL), MSUB (MNEG), SMADDL, UMULH, ...
    (0xfffffc1f, 0xd65f0000),   # RET (Unconditional branch, register): the target is a register
    (0xff3ffc00, 0x1e204000),   # FMOV (register): Floating-point data-processing (1 source), opcode 000000
    (0xff201fe0, 0x1e201000),   # FMOV (scalar, immediate): Floating-point immediate, imm5 = 00000
)


def carries_address_bits(w):
    """False only when w is one of NO_ADDRESS_FORMS: a word that means the same at any address, so a cheat may write it
    over an instruction that moved with its function (NOP a moved BL, a MOV over a moved adrp's user). True for every
    other word, unknown ones included: there a word of the old build would keep the old build's address bits."""
    if w & 0x1f800000 == 0x12800000 and (w >> 29) & 3 == 1: return True   # opc 01 of move wide: unallocated, not a MOV
    return not any(w & m == v for m, v in NO_ADDRESS_FORMS)


def is_conditional_branch(w):
    """True for B.cond, CBZ / CBNZ and TBZ / TBNZ: the PC-relative branches a cheat flips without re-encoding."""
    return w & 0xff000010 == 0x54000000 or w & 0x7e000000 in (0x34000000, 0x36000000)


def carry_write(authored, here, new, a, width):
    """The value (width bytes) a store at a writes on this build, or None when it must be refused. authored and here
    are the aligned words that hold a on the authored build and on this one. Equal words: new as written. Different
    words mean the instruction moved (a branch, an adrp, the low page bits after one), so new was meant for the old
    address: a restore of the authored bytes writes this build's own bytes instead, and any other value is kept only
    when the word it makes here is the word it made on the authored build (the bytes it leaves are equal) and that
    word carries no address bits. The one rule patches and code templates share."""
    if authored == here: return new
    sh, mask = 8 * (a & 3), (1 << 8 * width) - 1
    if new == (authored >> sh) & mask: return (here >> sh) & mask   # the restore: this build's own bytes
    made_here = here & ~(mask << sh) | new << sh
    made_there = authored & ~(mask << sh) | new << sh
    return new if made_here == made_there and not carries_address_bits(made_here) else None


def adrp_user_lo(u, rd):
    """The low page offset an add (64-bit immediate) or a ldr / str (unsigned offset) with base register rd adds to an
    adrp's page, or None when u is not such an instruction (the pairing rule of nso_match and nso_fnmap)."""
    if (u >> 5) & 31 != rd: return None
    if u & 0xff800000 == 0x91000000: return (u >> 10) & 0xfff
    if u & 0x3b000000 == 0x39000000:
        sh = 4 if u & 0x04800000 == 0x04800000 else u >> 30   # 128-bit SIMD / FP registers scale by 16
        return ((u >> 10) & 0xfff) << sh
    return None


def ends_pairing(u, rd):
    """True when u ends the search for an adrp's user: any branch, or an instruction that writes rd other than a store.
    Conservative on purpose: a missed pair only costs one reference, a wrong pair would anchor a wrong address."""
    if u & 0x7c000000 == 0x14000000 or u & 0xff000010 == 0x54000000 or u & 0x7e000000 in (0x34000000, 0x36000000): return True
    if u & 0xfffffc1f in (0xd61f0000, 0xd63f0000, 0xd65f0000): return True    # br / blr / ret
    is_store = u & 0x3b000000 == 0x39000000 and not (u >> 22) & 1             # str (unsigned offset): Rt is read, not written
    return u & 31 == rd and not is_store


# ---------- one build of the game ----------

class Build:
    """One NSO build: its memory image, segments, build ID, unwind functions and lazy indexes (fingerprints by size, adrp
    pairs, relocations), and the rewriter's output for it when the NSP script's layout has one. Only reads files."""

    def __init__(self, path):
        """Load the NSO at path (AnchorError when it cannot be read or holds no unwind table)."""
        self.path = Path(path)
        try:
            with open(self.path, 'rb') as f: hdr = f.read(0x100)
        except OSError as e: raise AnchorError(f'{self.path.resolve()}: {e.strerror}') from e
        if hdr[:4] != b'NSO0': raise AnchorError(f'{self.path.resolve()}: not an NSO file')
        self.img = bytes(load_nso(str(self.path)))   # the whole memory image, text at 0, bss included
        segs = [struct.unpack_from('<III', hdr, 0x10 + i * 0x10) for i in range(3)]   # file offset, memory offset, size
        self.text_end, self.ro_start = segs[0][2], segs[1][1]
        # .data from its memory offset; .bss right after it up to the image's end (nso_syms.load sizes the image to
        # data offset + data size + the bss size at 0x3C). where() keeps a data anchor inside its target's segment
        self.data_start, self.bss_start = segs[2][1], segs[2][1] + segs[2][2]
        self.build_id = hdr[0x40:0x48].hex().upper()   # the first 8 bytes, as cheat files are named
        nacp_path = self.path.parent.parent / 'control.nacp'   # nx_extract writes it beside ExeFS
        self.version = nacp.version(nacp_path) if nacp_path.is_file() else ''
        self.title = self._title()
        # The rewriter's output of this build, where the NSP script puts it: <id>_build/extract/v<N>/ExeFS/main ->
        # <id>_build/patched_v<N>/main.patched.bin (a flat image, same layout). Used only to warn about rewritten words
        p = self.path.resolve()
        rw = p.parents[3] / f'patched_{p.parents[1].name}' / f'{p.name}.patched.bin' if len(p.parents) > 3 else None
        self.patched = rw if rw is not None and rw.is_file() else None
        try: self.mod = nso_match.Image(self.img, self.text_end)
        except nso_match.MatchError as e: raise AnchorError(f'{self.path.resolve()}: {e}') from e
        self.starts = sorted(self.mod.functions)
        self.by_size = {}
        for s in self.starts: self.by_size.setdefault(self.mod.functions[s] - s, []).append(s)
        self._pairs = self._keys = self._relocs = self._ptrs = None

    def _title(self):
        """The program ID from main.npdm beside the NSO (its ACI0 section), '' when it cannot be read."""
        try:
            d = (self.path.parent / 'main.npdm').read_bytes()
            aci = struct.unpack_from('<I', d, 0x70)[0]
            return f'{struct.unpack_from("<Q", d, aci + 0x10)[0]:016X}' if d[aci:aci + 4] == b'ACI0' else ''
        except (OSError, struct.error): return ''

    def word(self, off):
        """The little-endian word at image offset off."""
        return struct.unpack_from('<I', self.img, off)[0]

    def words(self, off, n):
        """The n little-endian words from image offset off."""
        return list(struct.unpack_from(f'<{n}I', self.img, off))

    def rewritten(self, off, n):
        """The n bytes at off in the rewriter's output of this build, or None when there is none beside the NSO."""
        if self.patched is None: return None
        with open(self.patched, 'rb') as f:
            f.seek(off); return f.read(n)

    def func_at(self, off, n=4):
        """Start of the unwind function that holds [off, off + n), or None."""
        i = bisect.bisect_right(self.starts, off) - 1
        if i < 0: return None
        s = self.starts[i]
        return s if off + n <= self.mod.functions[s] else None

    def digest(self, start, kind):
        """The full fingerprint ('fp': body and direct callees) or the body digest alone ('body') of a function, or None
        when nso_match cannot compute it (an undecodable word, a callee without a boundary)."""
        try: return self.mod.fingerprint(start) if kind == 'fp' else self.mod._body(start)[0]   # _body: nso_match's own body digest
        except nso_match.MatchError: return None

    def same(self, size, key, kind):
        """The functions of this size whose digest of this kind is key, in address order (digests are cached by nso_match)."""
        return [s for s in self.by_size.get(size, ()) if self.digest(s, kind) == key]

    def _masked(self, start, n):
        """(the relocation-masked words of [start, start + 4n), the indexes of words whose low page bits were cleared
        because an adrp up to LOOKBACK words before them set their base), or None when the range leaves the text."""
        if start < 0 or start % 4 or start + 4 * n > self.text_end: return None
        lo = max(0, start - 4 * LOOKBACK)
        raw = self.words(lo, (start + 4 * n - lo) // 4)
        out, users = [mask_word(w) for w in raw], set()
        for i, w in enumerate(raw):
            if w & 0x9f000000 != 0x90000000: continue
            rd = w & 31
            for j in range(i + 1, min(i + 1 + LOOKBACK, len(raw))):
                if adrp_user_lo(raw[j], rd) is not None: out[j] &= ~0x3ffc00; users.add(j); break
                if ends_pairing(raw[j], rd): break
        k = (start - lo) // 4
        return out[k:], {j - k for j in users if j >= k}

    def masked(self, start, n):
        """The relocation-masked words of [start, start + 4n), or None outside the text."""
        r = self._masked(start, n)
        return r and r[0]

    def window_find(self, window, key):
        """Every start where the masked words equal window. key indexes a word that masking leaves unchanged: its raw bytes
        are searched (fast), and the whole masked window compared at each hit."""
        needle, hits = struct.pack('<I', window[key]), []
        p = self.img.find(needle, 0, self.text_end)
        while p >= 0:
            if p % 4 == 0 and self.masked(p - 4 * key, len(window)) == window: hits.append(p - 4 * key)
            p = self.img.find(needle, p + 1, self.text_end)
        return hits

    def pairs(self):
        """{computed address: [(adrp offset, user offset)]} for every adrp in the text and its first user."""
        if self._pairs is None:
            self._pairs = {}
            text = self.img[:self.text_end]
            for m in re.finditer(rb'[\x90\xb0\xd0\xf0]', text):   # an adrp's top byte: bit 31 set, bits 28..24 = 1 0000
                p = m.start() - 3
                if p % 4: continue
                w = struct.unpack_from('<I', text, p)[0]
                if w & 0x9f000000 != 0x90000000: continue
                rd, page = w & 31, pc_relative_target(w, p)
                if page is None: continue   # cannot happen for an adrp (checked above); narrows the type
                for j in range(p + 4, min(p + 4 * (LOOKBACK + 1), self.text_end), 4):
                    u = struct.unpack_from('<I', text, j)[0]
                    lo = adrp_user_lo(u, rd)
                    if lo is not None: self._pairs.setdefault(page + lo, []).append((p, j)); break
                    if ends_pairing(u, rd): break
            self._keys = sorted(self._pairs)
        return self._pairs

    def pair_at(self, a, b):
        """The address the adrp at a and its user at b compute, or None when they are not such a pair."""
        if not (0 <= a < b <= self.text_end - 4): return None
        w, u = self.word(a), self.word(b)
        if w & 0x9f000000 != 0x90000000: return None
        lo = adrp_user_lo(u, w & 31); page = pc_relative_target(w, a)
        return None if lo is None or page is None else page + lo

    def relocs(self):
        """{slot offset: pointer offset} of the image's relative relocations (DT_RELA R_AARCH64_RELATIVE and DT_RELR)."""
        if self._relocs is None:
            self._relocs = {}
            img = self.img
            try:
                mod = struct.unpack_from('<I', img, 4)[0]
                dyn = mod + struct.unpack_from('<i', img, mod + 4)[0]
                tags = {}
                for pos in range(dyn, min(len(img) - 15, dyn + 4096 * 16), 16):
                    tag, value = struct.unpack_from('<qQ', img, pos)
                    if tag == 0: break
                    tags[tag] = value
                if 7 in tags:   # DT_RELA, DT_RELASZ (8); entries of 24 bytes: offset, info, addend
                    for slot, info, addend in struct.iter_unpack('<QQq', img[tags[7]:tags[7] + tags.get(8, 0)]):
                        if info & 0xffffffff == R_AARCH64_RELATIVE: self._relocs[slot] = addend
                if 36 in tags:   # DT_RELR, DT_RELRSZ (35): addresses and bitmaps, the addends in place
                    base = 0
                    for (e,) in struct.iter_unpack('<Q', img[tags[36]:tags[36] + tags.get(35, 0)]):
                        if not e & 1:
                            self._relocs[e] = struct.unpack_from('<Q', img, e)[0]; base = e + 8
                        else:
                            for i in range(63):
                                if e >> (i + 1) & 1:
                                    s = base + 8 * i; self._relocs[s] = struct.unpack_from('<Q', img, s)[0]
                            base += 63 * 8
            except (struct.error, IndexError): self._relocs = {}
        return self._relocs

    def slots_of(self, ptr):
        """The relocated slots whose pointer is ptr."""
        if self._ptrs is None:
            self._ptrs = {}
            for slot, p in self.relocs().items(): self._ptrs.setdefault(p, []).append(slot)
            self._ptr_keys = sorted(self._ptrs)
        return self._ptrs.get(ptr, [])

    def _below(self, keys, target):
        """The nearest BASES_TRIED values of the sorted keys at or below target, within MAX_FIELD of it and in its
        segment. A base in another segment is never an object the target is a field of, and segments move apart
        across builds (a grown .rodata shifts .data), so such a base would resolve to a wrong address."""
        seg, i, out = self.where(target), bisect.bisect_right(keys, target), []
        while i > 0 and len(out) < BASES_TRIED:
            i -= 1
            if target - keys[i] > MAX_FIELD or self.where(keys[i]) != seg: break   # segments are contiguous: all lower keys are out too
            out.append(keys[i])
        return out

    def referenced_below(self, target):
        """The distinct addresses the code computes at or below target and within MAX_FIELD of it, nearest first."""
        self.pairs()
        return self._below(self._keys, target)

    def pointers_below(self, target):
        """The distinct relocated pointers at or below target and within MAX_FIELD of it, nearest first."""
        self.slots_of(0)
        return self._below(self._ptr_keys, target)

    def where(self, off, n=1):
        """The segment of [off, off + n) of the image: 'text', 'pad' (the zero padding after the text), 'ro' (.rodata, up
        to .data), 'data', 'bss' (DATA_KINDS are the last three), or None outside the image or across a boundary."""
        if off < 0 or off + n > len(self.img): return None
        for kind, lo, hi in (('text', 0, self.text_end), ('pad', self.text_end, self.ro_start), ('ro', self.ro_start, self.data_start),
                             ('data', self.data_start, self.bss_start), ('bss', self.bss_start, len(self.img))):
            if lo <= off and off + n <= hi: return kind
        return None


# ---------- authoring anchors (import) ----------

def locator(build, site, n):
    """The ways to find the n bytes at code offset site again in another build: the containing function's fingerprint and
    body digest (with [index, count] among identical copies when there are several), the site's offset in it, its
    original words and a masked window around it ('wunique' when it occurs once in this build). Raises AnchorError when
    nothing describes the site."""
    words = (n + 3) // 4
    loc: dict[str, object] = {'old': ' '.join(f'{w:08X}' for w in build.words(site, words))}
    f = build.func_at(site, 4 * words)
    if f is not None:
        size = build.mod.functions[f] - f
        loc.update(size=size, at=site - f)
        for kind in ('fp', 'body'):
            key = build.digest(f, kind)
            if key is None: continue
            same = build.same(size, key, kind)
            loc[kind] = key
            if len(same) > 1: loc[kind + '_copy'] = [same.index(f), len(same)]
    for h in WINDOW_HALVES:
        r = build._masked(site - 4 * h, words + 2 * h)
        if r is None: continue
        win, users = r
        raw = build.words(site - 4 * h, len(win))
        # search keys: words masking leaves unchanged, that are not PC-relative and not an adrp's user (their raw bits
        # may differ in another build even when the masked ones agree); the rarest of a few is searched
        keys = [i for i, (m, w) in enumerate(zip(win, raw)) if m == w and i not in users and pc_relative_target(w, 0) is None]
        if not keys: continue
        keys = sorted(keys, key=lambda i: (raw[i] in (0xd503201f, 0xd65f03c0), abs(i - h)))[:KEYS_COUNTED]   # nop / ret last
        key = min(keys, key=lambda i: build.img.count(struct.pack('<I', raw[i]), 0, build.text_end))
        loc.update(window=' '.join(f'{w:08X}' for w in win), wat=h, wkey=key)
        if build.window_find(win, key) == [site - 4 * h]: loc['wunique'] = True; break
    if 'fp' not in loc and 'body' not in loc and not loc.get('wunique'):
        raise AnchorError(f'code at {hexu(site)}: no function boundary and no unique instruction window describe it')
    return loc


class Authoring:
    """The anchors an import creates, by name, on the build the cheats were written for, and notes for the report."""

    def __init__(self, build):
        """Start with no anchors; the cave's base is set by set_cave when the file touches the padding."""
        self.b, self.anchors, self.cave_base, self.notes = build, {}, None, []

    def site(self, off, n):
        """The anchor of code [off, off + n) (off aligned): one per distinct offset and length, named s_<offset>[_<n>]."""
        name = f's_{off:X}' + (f'_{n}' if n != 4 else '')
        if name not in self.anchors: self.anchors[name] = {'code': locator(self.b, off, n), 'authored': hexu(off)}
        return name

    def set_cave(self, lowest):
        """The cave's base: the lowest padding address the imported file touches, as a distance before the read-only data."""
        self.cave_base = lowest & ~3
        self.anchors['cave'] = {'pad': self.b.ro_start - self.cave_base, 'authored': hexu(self.cave_base)}

    def cave(self, off):
        """The expression of an address in the padding after the text: cave[+offset]."""
        if self.cave_base is None or off < self.cave_base: raise AnchorError(f'padding address {hexu(off)} below the cave')
        return 'cave' if off == self.cave_base else f'cave+{hexu(off - self.cave_base)}'

    def data(self, target):
        """The expression of a data address: <anchor>[+field offset]. The anchor is the nearest address at or below target
        that the code references (directly, or as the target of a relocated slot the code references; direct first at
        the same distance) and whose references can be described; the nearest keeps the field offset from crossing into
        an unrelated variable. An anchor with a single reference is noted as weak."""
        cands = sorted([(target - p, 0, p) for p in self.b.referenced_below(target)] +
                       [(target - p, 1, p) for p in self.b.pointers_below(target)])
        for _, deref, base in cands:
            name = f'{"p" if deref else "d"}_{base:X}'
            if name not in self.anchors:
                refs = self._refs(self._sites(base, deref))
                if not refs: continue
                self.anchors[name] = dict({'data': refs, 'authored': hexu(base)}, **({'deref': True} if deref else {}))
                self.notes.append(f'anchor {name}: {len(refs)} code reference{"s" if len(refs) > 1 else ", weak"} to '
                                  + (f'the pointer slots of {hexu(base)}' if deref else hexu(base)))
            return name if target == base else f'{name}+{hexu(target - base)}'
        raise AnchorError(f'data at {hexu(target)}: no describable code reference within {hexu(MAX_FIELD)} below it')

    def _sites(self, base, deref):
        """The (adrp, user) pairs that compute base, or one of the relocated slots that point to base (deref)."""
        pairs = self.b.pairs()
        if deref: return sorted(p for slot in self.b.slots_of(base) for p in pairs.get(slot, ()))
        return sorted(pairs.get(base, ()))

    def _refs(self, sites):
        """Locators of up to MAX_REFS of the pairs, one per function, those in functions unique in this build first."""
        unique, other, seen = [], [], set()
        for a, u in sites:
            f = self.b.func_at(a, u + 4 - a)
            if f is None or f in seen: continue
            seen.add(f)
            try: loc = locator(self.b, a, 4)
            except AnchorError: continue
            loc['use'] = u - a
            (unique if 'fp' in loc and 'fp_copy' not in loc else other).append(loc)
            if len(unique) >= MAX_REFS or len(seen) >= REFS_TRIED: break
        return (unique + other)[:MAX_REFS]


# ---------- Atmosphère text and its instructions ----------

# A header, a master header, a run of whole 8-digit words (Atmosphère reads 8 digits at a time, so "0400000000123456" is
# two words), or any other token; the last stops before a bracket so that "junk[Next]" still starts the next cheat.
TOKEN = re.compile(r'\[([^\]\n]*)\]|\{([^}\n]*)\}|((?:[0-9A-Fa-f]{8})+)(?![0-9A-Fa-f])|([^\s\[{]+|\S)')


def parse_atmosphere(text):
    """[(name, master, [words], [(word index, line, token)]), ...] and [warnings] of an Atmosphère cheat file. Lenient
    like the host's loader where nothing is lost: prose before the first header is ignored; a header glued to the
    previous code word ("00000008[Next]") still starts a new cheat; words glued together are split; a line with no code
    word at all is prose (a credits or author line) and is ignored with a warning, as the host's loader ignores it. A
    token of hex digits only counts as a (botched) code word: "2000000" alone on a line is a cut end-of-block, not prose.
    A stray token on a line that also holds code words makes the cheat malformed: it is listed with its line and the
    place it stood, never dropped, because a shortened program can change meaning (a lost end-of-block word lets an
    open conditional swallow the next cheats)."""
    entries, warns, cur = [], [], None
    pending, has_word, cur_line = [], False, 0   # the stray tokens of the current line, and whether it holds a code word

    def flush():
        """Settle the current line's stray tokens: malformed when the line holds code words, prose otherwise."""
        for entry, index, ln, tok in pending:
            if has_word: entry[3].append((index, ln, tok))
            else: warns.append(f'line {ln}: "{tok}" in "{entry[0]}" is not a code word, ignored (no code word on the line)')
        pending.clear()
    for m in TOKEN.finditer(text):
        line = text.count('\n', 0, m.start()) + 1
        if line != cur_line: flush(); cur_line, has_word = line, False
        if m.group(1) is not None or m.group(2) is not None:
            flush(); has_word = False   # tokens before a header glued on the same line belong to the previous cheat
            cur = [(m.group(1) if m.group(1) is not None else m.group(2)).strip(), m.group(2) is not None, [], []]
            entries.append(cur)
        elif m.group(3):
            if cur is None: warns.append(f'line {line}: code word before any [name], ignored')
            else: cur[2] += [int(m.group(3)[k:k + 8], 16) for k in range(0, len(m.group(3)), 8)]; has_word = True
        elif cur is not None:
            pending.append((cur, len(cur[2]), line, m.group(4)))
            if re.fullmatch(r'[0-9A-Fa-f]+', m.group(4)): has_word = True   # a code word of the wrong length
    flush()
    return [tuple(e) for e in entries], warns


def malformed_code(words, bad):
    """A malformed cheat's program for the source: its words with each stray token back where it stood, four per line.
    The compiler refuses the stray token ("not a code word"), so the cheat is never run shortened."""
    toks = []
    for i in range(len(words) + 1):
        toks += [t for j, _, t in bad if j == i]
        if i < len(words): toks.append(f'{words[i]:08X}')
    return ''.join(' '.join(toks[k:k + 4]) + '\n' for k in range(0, len(toks), 4))


def decode(words, i):
    """One instruction at words[i]: a dict with op (the extended opcode: 0x9, 0xC0, 0xFF0, ...), n (its length in words),
    its address field when it has a region-relative one ('rel', 'bits' 40 or 36, 'mem' the region), and for an opcode 0
    store 'width', 'reg' and 'value'. 'regs' is True when it can change a VM register (loads, arithmetic, loops, the
    incrementing forms of 6 and A). Raises AnchorError on an unknown or truncated form. The layouts are the ones of
    Atmosphère's own docs/features/cheats.md (dmnt), as dm/host/hle_cheats.c decodes opcodes 0-8."""
    w = words[i]; op = w >> 28
    if op >= 0xC: op = op << 4 | (w >> 24) & 0xF
    if op >= 0xF0: op = op << 4 | (w >> 20) & 0xF
    d = {'op': op, 'n': 1, 'regs': op in (3, 4, 5, 6, 7, 9, 0xA, 0xC1, 0xC2, 0xC3)}

    def wid(t):
        """A width nibble, which must be 1, 2, 4 or 8."""
        if t not in (1, 2, 4, 8): raise AnchorError(f'word {i}: width {t} in {w:08X}')
        return t
    if op in (0, 1):   # 0TMR00AA / 1TMCXrAA AAAAAAAA VVVVVVVV (VVVVVVVV)
        d.update(n=4 if wid((w >> 24) & 0xF) == 8 else 3, mem=(w >> 20) & 0xF, bits=REGION_BITS)
        if op == 0: d.update(width=(w >> 24) & 0xF, reg=(w >> 16) & 0xF)
    elif op in (2, 8, 0xC1, 0xC2, 0xC3, 0xFF0, 0xFF1): pass   # one word each
    elif op == 3: d['n'] = 1 if (w >> 24) & 0xF else 2         # 300R0000 VVVVVVVV / 310R0000
    elif op in (4, 6): d['n'] = 3                               # 400R0000 / 6T0RIor0 + a 64-bit value
    elif op == 5:                                               # 5TMRI0AA AAAAAAAA: I = 0 / 3 are region-relative
        d['n'] = 2
        if (w >> 12) & 0xF in (0, 3): d.update(mem=(w >> 20) & 0xF, bits=REGION_BITS)
    elif op == 7: d['n'] = 2                                    # 7T0RC000 VVVVVVVV
    elif op == 9: d['n'] = 1 + ((2 if wid((w >> 24) & 0xF) == 8 else 1) if (w >> 8) & 0xF else 0)   # 9TCRSIs0 (value)
    elif op == 0xA:                                             # ATSRIOxa (aaaaaaaa): O = 4 / 5 are region-relative
        o = (w >> 8) & 0xF
        d['n'] = 2 if o in (2, 4, 5) else 1
        if o in (4, 5): d.update(mem=(w >> 4) & 0xF, bits=36)
    elif op == 0xC0:                                            # C0TcSX..: X = 0 is region-relative, 4 a static value
        x = (w >> 8) & 0xF
        d['n'] = 1 + (2 if wid((w >> 20) & 0xF) == 8 else 1) if x == 4 else 2 if x in (0, 2) else 1
        if x == 0: d.update(mem=(w >> 4) & 0xF, bits=36)
    elif op == 0xC4: d['n'] = 3                                 # C4r00000 + a 64-bit key mask
    elif op == 0xFFF:                                           # FFFTIX..: X = 0 is region-relative
        x = (w >> 8) & 0xF
        d['n'] = 2 if x in (0, 2) else 1
        if x == 0: d.update(mem=(w >> 4) & 0xF, bits=36)
    else: raise AnchorError(f'word {i}: unknown opcode in {w:08X}')
    if i + d['n'] > len(words): raise AnchorError(f'word {i}: {w:08X} is cut short')
    if 'bits' in d: d['rel'] = ((w & (0xFF if d['bits'] == 40 else 0xF)) << 32) | words[i + 1]
    if op == 0: d['value'] = (words[i + 2] << 32 | words[i + 3]) if d['width'] == 8 else words[i + 2]
    return d


def decode_all(words):
    """[(word index, instruction)] of a whole program (AnchorError on the first bad one)."""
    out, i = [], 0
    while i < len(words):
        d = decode(words, i); out.append((i, d)); i += d['n']
    return out


def mem_words(width, value):
    """An opcode 0 value as it lies in memory: 4-byte words, low word first (an 8-byte store is two words)."""
    return [value & 0xffffffff, value >> 32] if width == 8 else [value]


def value_index(i, width, k):
    """The index in the program of the k-th memory word (mem_words order) of the opcode 0 store at word i: an 8-byte value
    is written high word first (word i + 2 is the high word, at the store's address + 4)."""
    return i + 2 + (1 - k if width == 8 else k)


def runs(ranges):
    """Merged [start, end) runs of byte ranges (the contiguous areas one cheat writes)."""
    out = []
    for s, e in sorted(ranges):
        if out and s <= out[-1][1]: out[-1][1] = max(out[-1][1], e)
        else: out.append([s, e])
    return out


def format_words(words, ins=None, tokens=None):
    """Atmosphère words, one instruction per line when the instructions are known; tokens replaces words by index."""
    tokens = tokens or {}

    def word(i):
        """Word i as text, or its token."""
        return tokens.get(i, f'{words[i]:08X}')
    if not ins: return ''.join(' '.join(word(i) for i in range(k, min(k + 4, len(words)))) + '\n' for k in range(0, len(words), 4))
    return ''.join(' '.join(word(k) for k in range(i, i + d['n'])) + '\n' for i, d in ins)


# ---------- import: an Atmosphère file into anchored cheats ----------

ON_OFF = re.compile(r'^(.*?)(?:\s*[-:_]\s*|\s+|\s*[(\[]\s*)(on|off)\s*[)\]]?$', re.I)


def import_file(txt, build, assume_build=False):
    """(the anchored source as a dict for write_toml, the report lines, the number of cheats kept bound to one build) of
    the Atmosphère file txt, written for build. Every main-relative address is anchored; a cheat that cannot be fully
    anchored keeps its words, bound to the file's own build."""
    text = Path(txt).read_text(encoding='utf-8', errors='replace')
    entries, warns = parse_atmosphere(text)
    report = [f'warning: {w}' for w in warns]
    stem, own_build = Path(txt).name[:16], build.build_id
    # a file named after the title ID (as some sites name them) names no build: it is taken as this build's
    if re.fullmatch(r'[0-9A-Fa-f]{16}', stem) and stem.upper() not in (build.build_id, build.title):
        if not assume_build:
            raise AnchorError(f'{Path(txt).name} names build {stem.upper()}, the NSO is build {build.build_id}; '
                              '--assume-build anchors it on this build anyway (only if both builds share the layout)')
        own_build = stem.upper()   # cheats left unanchored keep the addresses of the file's own build
        report.append(f'[RED] {Path(txt).name} is for build {own_build}: anchored with the code of build {build.build_id} (--assume-build)')
    auth = Authoring(build)
    decoded = []
    malformed = {}   # entry index -> the stray tokens of a malformed cheat (parse_atmosphere)
    for name, master, words, bad in entries:   # first pass: decode everything, to place the cave before any anchor names it
        if bad:
            malformed[len(decoded)] = bad
            decoded.append((name, master, words, None, 'malformed: ' + ', '.join(f'line {ln}: "{t}" is not a code word' for _, ln, t in bad)))
            continue
        try: decoded.append((name, master, words, decode_all(words), None))
        except AnchorError as e: decoded.append((name, master, words, None, str(e)))
    pad = []   # every padding address the file touches: addresses, and B / BL targets of the words it writes
    for _, _, _, ins, _ in decoded:
        for _, d in ins or ():
            if d.get('mem') != 0 or 'rel' not in d: continue
            if build.where(d['rel'], 1) == 'pad': pad.append(d['rel'])
            if d['op'] == 0 and d['width'] >= 4 and build.where(d['rel'], d['width']) in ('text', 'pad'):
                for k, w in enumerate(mem_words(d['width'], d['value'])):
                    t = branch_target(w, d['rel'] + 4 * k)
                    if t is not None and build.where(t, 4) == 'pad': pad.append(t)
    if pad: auth.set_cave(min(pad))
    cheats, bound = [], 0
    for n, (name, master, words, ins, err) in enumerate(decoded):
        c = {'name': name}
        if master: c['master'] = True
        if not words and n not in malformed: c['label'] = True; cheats.append(c); continue
        try:
            if err: raise AnchorError(err)
            c.update(convert(auth, words, ins))
        except AnchorError as e:
            c['code'] = malformed_code(words, malformed[n]) if n in malformed else format_words(words, ins)
            c['builds'] = [own_build]; bound += 1
            report.append(f'[RED] "{name}": kept for build {own_build} only: {e}')
        cheats.append(c)
    # evidence the file is for this build: writes into the code (not the zero cave) of the words already there, as the
    # "off" / restore entries of ASM cheats do; counted before pair_on_off merges those entries away
    code = [w for c in cheats for w in c.get('patch', ()) if not w['at'].startswith('cave')]
    same = sum(1 for w in code if w.get('same'))
    if code: report.append(f'{same} of {len(code)} writes into the code put back the word already there in build {build.build_id}'
                           + (' (restore entries: evidence the file is for this build)' if same else ''))
    cheats = pair_on_off(cheats)
    for c in cheats:
        for w in c.get('patch', ()): w.pop('same', None)
    report += auth.notes
    src = {'format': FORMAT, 'title': build.title, 'authored': build.build_id,
           'builds': {build.build_id: build.version} if build.version else {}, 'cheats': cheats, 'anchors': auth.anchors}
    report.append(f'{len(cheats)} cheats, {len(auth.anchors)} anchors on build {build.build_id}' + (f' ({build.version})' if build.version else '')
                  + (f', {bound} kept for build {own_build} only' if bound else ''))
    return src, report, bound


def convert(auth, words, ins):
    """One cheat's anchored form: a patch (only opcode 0 stores into the code and the cave), a data freeze (a single
    store into data), or code (any other program) whose address words became {anchor} tokens. The code words one cheat
    writes contiguously form one run and share one anchor, so they move together. Raises AnchorError when an address or
    a PC-relative word cannot be carried to another build."""
    b = auth.b
    stores = [d for _, d in ins if d['op'] == 0 and d['mem'] == 0]
    regs = any(d['regs'] for _, d in ins)
    own = runs((d['rel'], d['rel'] + d['width']) for d in stores)

    def run_of(rel, n):
        """The word-aligned text run of this cheat's stores that holds [rel, rel + n), or None."""
        for s, e in own:
            s4, e4 = s & ~3, (e + 3) & ~3
            if s <= rel and rel + n <= e and e4 <= b.text_end: return s4, e4
        return None

    def addr_expr(rel, n, store=False):
        """An anchor expression for [rel, rel + n) of main; a store into the code is anchored by its whole run."""
        kind = b.where(rel, n)
        if kind == 'text':
            start, end = (run_of(rel, n) if store else None) or (rel & ~3, (rel + n + 3) & ~3)
            return auth.site(start, end - start) + (f'+{hexu(rel - start)}' if rel != start else '')
        if kind == 'pad': return auth.cave(rel)
        if kind in DATA_KINDS: return auth.data(rel)
        raise AnchorError(f'address {hexu(rel)} is outside the main NSO image or crosses a segment')

    def keeps(w, a, t):
        """True when the PC-relative word w at a, aimed at t, stays right as written: t in the run w is written in, or
        a conditional branch inside the site's own function (same_function_branch)."""
        return any(s <= a < e and s <= t < e for s, e in own) or same_function_branch(b, w, a, t)

    def value_tokens(d):
        """The stored memory words; a B / BL to outside the run the word is written in becomes a relocatable token.
        Every word a store makes, a 1- or 2-byte store's whole word included, must be carried as written: a
        PC-relative word only when keeps() holds, and never a new adrp user (adrp_paired: its low page bits are this
        build's, and the data can move inside its page while the code does not)."""
        out = []
        for k, w in enumerate(mem_words(d['width'], d['value'])):
            a = d['rel'] + 4 * k
            a4, here = a & ~3, b.word(a & ~3)
            sh, mask = 8 * (a & 3), (1 << 8 * min(d['width'], 4)) - 1
            made = here & ~(mask << sh) | w << sh   # the whole word this store leaves in memory
            if made != here and b.where(a4, 4) == 'text' and adrp_paired(b.word, a4, made) is not None:
                raise AnchorError(f'the word {made:08X} written at {hexu(a4)} takes the page of the adrp at {hexu(adrp_paired(b.word, a4, made))}: '
                                  'its low page bits hold for this build only')
            if d['width'] < 4:
                t = pc_relative_target(made, a4) if made != here else None
                if t is not None and not keeps(made, a, t):
                    raise AnchorError(f'the {d["width"]}-byte write at {hexu(a)} makes {made:08X}, PC-relative to {hexu(t)}, outside what the cheat writes')
                out.append(f'{w:0{2 * d["width"]}X}'); continue
            t = pc_relative_target(w, a)
            if t is None or keeps(w, a, t): out.append(f'{w:08X}'); continue
            if branch_target(w, a) is None: raise AnchorError(f'the word {w:08X} written at {hexu(a)} is PC-relative to {hexu(t)}, outside what the cheat writes')
            out.append(('bl:' if w & 0x80000000 else 'b:') + addr_expr(t, 4))
        return out

    simple = not regs and all(d['op'] == 0 and d['mem'] == 0 for _, d in ins)
    if simple and all(b.where(d['rel'], d['width']) in ('text', 'pad') for d in stores):
        patch = []
        for d in stores:
            vals = value_tokens(d)
            item = {'at': addr_expr(d['rel'], d['width'], store=True), 'new': ' '.join(vals)}
            if d['width'] < 4: item['width'] = d['width']
            if b.img[d['rel']:d['rel'] + d['width']] == d['value'].to_bytes(d['width'], 'little'):
                item['same'] = True   # writes the word already there: a restore (pair_on_off and the import report use it)
            patch.append(item)
        return {'patch': patch}
    if simple and len(stores) == 1 and b.where(stores[0]['rel'], stores[0]['width']) in DATA_KINDS:
        d = stores[0]
        return {'target': addr_expr(d['rel'], d['width']), 'type': f'u{8 * d["width"]}', 'action': 'freeze', 'value': d['value']}
    words, tokens, written = list(words), {}, registers_written(words, ins)
    for i, d in ins:
        if 'rel' not in d: continue
        if d['mem'] != 0: raise AnchorError(f'an address in memory region {d["mem"]} (not the main NSO) cannot be anchored')
        if d['op'] == 0xA and b.where(d['rel'], 1) in ('text', 'pad'):   # only opcode 0 literals pass value_tokens / carry_write
            raise AnchorError(f'a store of a register into the code at {hexu(d["rel"])}: its value is not a word the compiler can check')
        # a store at base + a register the cheat sets: only the base is anchored. The VM always adds the offset
        # register, r0 included, so r0 counts once the cheat writes it; another register counts whenever the cheat
        # changes any (all enabled cheats run as one program, so another cheat may have set it)
        indexed = d['op'] == 0 and ((d['reg'] and regs) or (d['reg'] == 0 and 0 in written))
        if indexed and b.where(d['rel'], 1) not in DATA_KINDS: raise AnchorError(f'a store into code at {hexu(d["rel"])} indexed by register {d["reg"]}')
        store = d['op'] == 0 and not indexed
        tokens[i + 1] = '{' + addr_expr(d['rel'], d['width'] if store else 1, store=store) + '}'
        words[i] &= ~(0xFF if d['bits'] == 40 else 0xF)   # the template keeps the address bits of the first word zero
        if store and b.where(d['rel'], d['width']) in ('text', 'pad'):
            for k, v in enumerate(value_tokens(d)):
                if ':' in v: tokens[value_index(i, d['width'], k)] = '{' + v + '}'
    return {'code': format_words(words, ins, tokens)}


def adrp_paired(word_at, a, w):
    """The offset of an adrp up to LOOKBACK words before text offset a whose page the word w written at a would use
    (an add / ldr / str with the adrp's register as base, nothing between them writing that register or branching),
    or None. Such a w holds the low 12 bits of a data address on the build it was written for; the data can move inside
    its page while the code around it does not, so w is never carried as written. word_at(off) reads the build."""
    for p in range(max(0, a - 4 * LOOKBACK), a, 4):
        u = word_at(p)
        if u & 0x9f000000 != 0x90000000 or adrp_user_lo(w, u & 31) is None: continue
        if not any(ends_pairing(word_at(j), u & 31) for j in range(p + 4, a, 4)): return p
    return None


def registers_written(words, ins):
    """The VM registers a program may write: the R field (bits 16-19) of opcodes 3 (loop counter), 4, 5, 7, 9 and of
    6 / A (their incrementing forms), and every register for C1-C3 (save, restore, static registers)."""
    out = set()
    for i, d in ins:
        if d['op'] in (3, 4, 5, 6, 7, 9, 0xA): out.add((words[i] >> 16) & 0xF)
        elif d['op'] in (0xC1, 0xC2, 0xC3): out.update(range(16))
    return out


def same_function_branch(build, w, a, t):
    """True when w, written at text offset a, is a conditional branch (B.cond, CBZ / CBNZ, TBZ / TBNZ: no token form)
    whose target t lies in the unwind function that holds a, and that function has a fingerprint or a body digest.
    A match by either implies the same layout, so the offset stays right wherever the function moves; compile writes
    it only when the site's function was found that way, not by its window (Compiler._check_pc_relative)."""
    if not is_conditional_branch(w): return False
    f = build.func_at(a)
    if f is None or not f <= t < build.mod.functions[f]: return False
    return build.digest(f, 'fp') is not None or build.digest(f, 'body') is not None


def pair_on_off(cheats):
    """Merge "<name> - on" / "<name> - off" patches into one patch cheat when the off entry puts back exactly the original
    words of the code sites the on entry changes (its cave writes need no restore). The merged cheat keeps both names
    (on_name / off_name) and their order (off_first), so the compiled file has the same two entries in the same order and
    the saved toggles stay valid, and each entry's master flag ({name}: always on): master, off_master."""
    by = {}
    for i, c in enumerate(cheats):
        m = ON_OFF.match(c['name'])
        if m and 'patch' in c: by.setdefault(m.group(1).strip().lower(), {})[m.group(2).lower()] = i
    drop = set()
    for two in by.values():
        if set(two) != {'on', 'off'}: continue
        on, off = cheats[two['on']], cheats[two['off']]
        changed = {w['at'] for w in on['patch'] if not w['at'].startswith('cave') and not w.get('same')}
        if not changed or {w['at'] for w in off['patch']} != changed or not all(w.get('same') for w in off['patch']): continue
        m = ON_OFF.match(on['name']); assert m   # matched when `by` was built
        merged = {'name': m.group(1).strip(), 'on_name': on['name'], 'off_name': off['name']}
        if on.get('master'): merged['master'] = True
        if off.get('master'): merged['off_master'] = True   # an optional key: the off entry keeps its own flag
        if two['off'] < two['on']: merged['off_first'] = True
        merged['patch'] = on['patch']
        first, second = sorted((two['on'], two['off']))
        cheats[first] = merged; drop.add(second)
    return [c for i, c in enumerate(cheats) if i not in drop]


# ---------- the source file (TOML) ----------

def toml_str(s):
    """A TOML basic string; control characters (which TOML forbids raw) as \\uXXXX escapes."""
    s = s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n').replace('\t', '\\t')
    return '"' + re.sub(r'[\x00-\x1f\x7f]', lambda m: f'\\u{ord(m.group()):04X}', s) + '"'


def toml_key(k):
    """A TOML key: bare when it can be, quoted otherwise."""
    return k if re.fullmatch(r'[A-Za-z0-9_-]+', k) else toml_str(k)


def toml_value(v, key=''):
    """A TOML value: offsets and sizes in hex (keys at, use, size, pad), code as a multi-line string."""
    if isinstance(v, bool): return 'true' if v else 'false'
    if isinstance(v, int): return hexu(v) if key in ('at', 'use', 'size', 'pad') else str(v)
    if isinstance(v, float): return repr(v)
    if isinstance(v, str):
        if '\n' in v and not re.search(r'[\x00-\x09\x0b-\x1f\x7f]', v):   # code: hex words, tokens and newlines only
            # every quote escaped: escaping only '"""' leaves a run of four or more (or one before the closing
            # delimiter) that TOML reads as the end of the string; a malformed cheat's stray token can hold any
            return '"""\n' + v.replace('\\', '\\\\').replace('"', '\\"') + '"""'
        return toml_str(v)
    if isinstance(v, list):
        if v and all(isinstance(x, dict) for x in v): return '[\n' + ''.join(f'  {toml_value(x)},\n' for x in v) + ']'
        return '[' + ', '.join(toml_value(x) for x in v) + ']'
    if isinstance(v, dict): return '{ ' + ', '.join(f'{toml_key(k)} = {toml_value(x, k)}' for k, x in v.items()) + ' }'
    raise TypeError(v)


def write_toml(src, path, origin):
    """Write the anchored source: a header comment, the top keys, the cheats in file order, then the anchors."""
    out = [f'# Version-independent cheats for nxnative (scripts/cheat_anchor.py, format {FORMAT}).',
           f'# Imported from {origin} on {TODAY} with the code of build {src["authored"]}. Compile it for a build with',
           '#   cheat_anchor.py compile <this file> --nso <that build\'s ExeFS/main> -o <cheats folder>',
           '# The anchors at the end are the tool\'s; the cheats can be edited (names, sections, notes, values, "ask").', '']
    for k in ('format', 'title', 'authored'):
        if src.get(k, '') != '': out.append(f'{k} = {toml_value(src[k])}')
    if src.get('builds'):
        out += ['', '[builds]'] + [f'{toml_key(k)} = {toml_value(v)}' for k, v in src['builds'].items()]
    for c in src['cheats']:
        out += ['', '[[cheats]]'] + [f'{toml_key(k)} = {toml_value(v, k)}' for k, v in c.items()]
    for name, a in src['anchors'].items():
        out += ['', f'[anchors.{toml_key(name)}]'] + [f'{toml_key(k)} = {toml_value(v, k)}' for k, v in a.items()]
    Path(path).write_text('\n'.join(out) + '\n', encoding='utf-8')


# ---------- compile: resolving anchors on a target build ----------

class Resolver:
    """The anchors of a source resolved on one build: name -> (main offset, how), cached, failures cached too."""

    def __init__(self, anchors, build):
        """Resolve the anchors table of a source on build, lazily."""
        self.a, self.b, self.done = anchors, build, {}

    def resolve(self, name):
        """(main offset, how) of the named anchor; AnchorError (naming the anchor) when it cannot be resolved."""
        if name not in self.done:
            try: self.done[name] = self._resolve(name)
            except AnchorError as e: self.done[name] = AnchorError(f'anchor {name}: {e}')
            except (KeyError, ValueError, TypeError) as e: self.done[name] = AnchorError(f'anchor {name}: malformed in the source ({e!r})')
        r = self.done[name]
        if isinstance(r, AnchorError): raise r
        return r

    def _resolve(self, name):
        """One anchor by its kind: code, data or the cave."""
        a = self.a.get(name)
        if a is None: raise AnchorError('not defined in the source')
        if 'code' in a: return self.code(a['code'])
        if 'data' in a: return self.data(a)
        if 'pad' in a:
            base = self.b.ro_start - a['pad']
            if base < self.b.text_end or base % 4: raise AnchorError(f'the cave ({hexu(a["pad"])} bytes before the read-only data) does not fit in the padding after the text')
            return base, 'cave'
        raise AnchorError('has no code, data or pad key')

    def _window_sites(self, loc):
        """The sites the locator's window finds in this build, or None when the window was not unique on its own build."""
        if not loc.get('wunique'): return None
        return [h + 4 * loc['wat'] for h in self.b.window_find([int(x, 16) for x in loc['window'].split()], loc['wkey'])]

    def code(self, loc, verify=True):
        """The site of a code locator and how it was found. By function fingerprint, then body digest, then the unique
        window; the first way that finds candidates of the right count decides (a word mismatch there is an error,
        never a reason to try the next way). Among identical copies the one at the same position in address order is
        taken: confirmed when the window finds it too, an error when the window finds another one, otherwise reported as
        weak. verify checks the original words (_check_words)."""
        b, old = self.b, [int(x, 16) for x in loc['old'].split()]
        for kind in ('fp', 'body'):
            if kind not in loc: continue
            idx, cnt = loc.get(kind + '_copy', [0, 1])
            same = b.same(loc['size'], loc[kind], kind)
            if len(same) != cnt: continue
            site, how = same[idx] + loc['at'], 'exact' if kind == 'fp' else 'body'
            if cnt > 1:
                w = self._window_sites(loc)
                if w is not None and len(w) == 1 and w[0] != site:
                    raise AnchorError(f'identical copies: copy {idx + 1} of {cnt} by order is {hexu(site)}, its window says {hexu(w[0])}')
                how += f', copy {idx + 1} of {cnt} ' + ('confirmed by its window' if w is not None and len(w) == 1 else 'by order: weak')
            if verify: self._check_words(loc, site, old)
            return site, how
        w = self._window_sites(loc)
        if w is not None:
            if len(w) == 1:
                if verify: self._check_words(loc, w[0], old)
                return w[0], 'window'
            raise AnchorError(f'its function is not in this build and {len(w)} places match its instruction window (need exactly one)')
        raise AnchorError('its function is not in this build and it has no unique instruction window')

    def _check_words(self, loc, site, old):
        """The site must hold the authored original words: raw, or, when only relocation bits differ (an instruction that
        moved with its function: a branch, an adrp, the low page bits after one), the same masked words as the authored
        window. What may then be written over such a relocated word is decided by carry_write (Compiler.site_word)."""
        b = self.b
        if site < 0 or site + 4 * len(old) > b.text_end: raise AnchorError(f'code site {hexu(site)} is outside the text')
        now = b.words(site, len(old))
        if now == old: return
        win, h = [int(x, 16) for x in loc.get('window', '').split()], loc.get('wat', 0)
        if win and b.masked(site, len(old)) == win[h:h + len(old)]: return
        raise AnchorError(f'code site {hexu(site)}: the original words differ ({" ".join(f"{w:08X}" for w in now)}, expected {loc["old"]})')

    def data(self, a):
        """A data anchor: each reference resolved alone (each site counted once) and decoded as an adrp pair; with deref,
        each slot it computes followed through its relative relocation. At least two results must agree (one when the
        anchor has one reference) and none may disagree. A reference found among identical copies by order alone
        counts for the address, but when fewer than that many strong references agree the anchor is marked weak."""
        got, seen, slots, weak = {}, set(), set(), {}
        for loc in a['data']:
            try: site, tier = self.code(loc, verify=False)
            except AnchorError: continue
            if site in seen: continue
            seen.add(site)
            addr = self.b.pair_at(site, site + loc['use'])
            if addr is None: continue
            if a.get('deref'):
                slot, addr = addr, self.b.relocs().get(addr)
                if addr is None: continue   # a slot without a relative relocation: this reference counts as missing
                slots.add(slot)
            got.setdefault(addr, []).append(tier.split(',')[0])
            if 'weak' in tier: weak[addr] = weak.get(addr, 0) + 1   # "copy k of n by order: weak": kept apart from the tier
        n = len(a['data'])
        if not got: raise AnchorError(f'none of its {n} code references was found')
        if len(got) > 1: raise AnchorError('its code references disagree: ' + ', '.join(f'{hexu(k)} ({len(v)})' for k, v in got.items()))
        (addr, tiers), = got.items()
        if len(tiers) < min(2, n): raise AnchorError(f'only 1 of its {n} code references was found (need 2)')
        how = f'{len(tiers)}/{n} refs (' + ', '.join(f'{tiers.count(t)} {t}' for t in ('exact', 'body', 'window') if t in tiers) + ')'
        if n == 1: how += ', weak: one reference'
        elif len(tiers) - weak.get(addr, 0) < 2: how += f', weak: {weak[addr]} of them identical copies by order'
        if slots: how += ' through the slot' + ('s ' if len(slots) > 1 else ' ') + ', '.join(hexu(s) for s in sorted(slots))
        return addr, how


OFFSET = re.compile(r'\s*([+-])\s*(?:0[xX]([0-9A-Fa-f]+)|(\d+))')


def parse_expr(s):
    """An address expression: NAME | main | heap | [EXPR], each followed by +/- offsets (hex 0x..., or decimal). Returns
    ('name', name, off) or ('deref', inner, off) (the value read at inner, plus off)."""
    def term(i):
        """One term from position i: (node, the position after it and its offsets)."""
        m = re.compile(r'\s*(?:(\[)|([A-Za-z_][A-Za-z0-9_]*))').match(s, i)
        if not m: raise AnchorError(f'bad address "{s}"')
        if m.group(1):
            inner, i = term(m.end())
            m2 = re.compile(r'\s*\]').match(s, i)
            if not m2: raise AnchorError(f'bad address "{s}": missing ]')
            kind, val, i = 'deref', inner, m2.end()
        else: kind, val, i = 'name', m.group(2), m.end()
        off = 0
        while (m := OFFSET.match(s, i)):
            n = int(m.group(2), 16) if m.group(2) is not None else int(m.group(3), 10)
            off += n if m.group(1) == '+' else -n; i = m.end()
        return (kind, val, off), i
    node, i = term(0)
    if s[i:].strip(): raise AnchorError(f'bad address "{s}"')
    return node


TYPES = {'u8': (1, 'B'), 'u16': (2, 'H'), 'u32': (4, 'I'), 'u64': (8, 'Q'), 's8': (1, 'b'), 's16': (2, 'h'),
         's32': (4, 'i'), 's64': (8, 'q'), 'f32': (4, 'f'), 'f64': (8, 'd')}


class Compiler:
    """Compiles the cheats of a source for one build into Atmosphère entries: (name, master, [words], meta row). Warnings
    that do not stop a cheat (rewritten words, Atmosphère's size limit) collect in self.warnings."""

    def __init__(self, src, build, plain):
        """Compile src for build; plain writes patches without their guards."""
        self.src, self.b, self.plain, self.warnings = src, build, plain, []
        self.r = Resolver(src.get('anchors', {}), build)

    def addr(self, node, cheat):
        """(region, offset, how) of a static address node: region 0 main, 1 heap. A fixed main / heap address is valid
        only when the cheat's builds name this build; a main address must lie in the image, a heap one in 40 bits; a
        data anchor plus its field offset must stay in the anchor's segment."""
        kind, name, off = node
        if kind == 'deref': raise AnchorError('a pointer chain is not allowed here')
        if name in ('main', 'heap'):
            if self.b.build_id not in cheat.get('builds', []):
                raise AnchorError(f'a fixed {name} address is valid only on the builds the cheat lists ({", ".join(cheat.get("builds", [])) or "none"})')
            region, addr, how = (0 if name == 'main' else 1), off, 'fixed'
        else:
            base, how = self.r.resolve(name)
            region, addr = 0, base + off
            # a field never leaves its object's segment: an anchor in .rodata with an offset into .data (sources written
            # before import kept bases in the target's segment) would land elsewhere once .rodata grows
            if 'data' in self.src.get('anchors', {}).get(name, {}) and self.b.where(base) != self.b.where(addr):
                raise AnchorError(f'{name}{"+" if off >= 0 else "-"}{hexu(abs(off))} crosses from {self.b.where(base)} into {self.b.where(addr)}: '
                                  'a field offset never leaves its anchor\'s segment')
        if not (0 <= addr < (len(self.b.img) if region == 0 else 1 << REGION_BITS)):
            raise AnchorError(f'address {hexu(addr)} is outside the {"main NSO image" if region == 0 else "region"}')
        return region, addr, how

    def code_words(self, text, cheat):
        """The words of a code template: {EXPR} address tokens (the second word of an instruction with a region-relative
        address, whose first word keeps the address bits zero) and {bl:EXPR} / {b:EXPR} value tokens of opcode 0 stores.
        A store into the code or the cave goes through site_word, the rules patches follow, whatever gates it. A program
        the decoder cannot read has no tokens to fill: it is kept verbatim on the builds its cheat names, else refused."""
        words, special, how = [], {}, set()
        for t in re.findall(r'\{[^}]*\}|[0-9A-Fa-f]{8}|\S+', text):
            if t.startswith('{'): special[len(words)] = t[1:-1].strip(); words.append(0)
            elif re.fullmatch(r'[0-9A-Fa-f]{8}', t): words.append(int(t, 16))
            else: raise AnchorError(f'"{t}" is not a code word')
        try: decode_all(words)
        except AnchorError:
            if special or self.b.build_id not in cheat.get('builds', []): raise
            return words, {'fixed, kept verbatim (not decoded)'}
        i = 0
        while i < len(words):
            d, node = decode(words, i), None
            if i + 1 in special and ':' not in special[i + 1]:
                if 'bits' not in d: raise AnchorError(f'word {i + 1}: an address token where {words[i]:08X} has no address')
                node = parse_expr(special.pop(i + 1))
                region, off, h = self.addr(node, cheat); how.add(h)
                if region != d['mem']: raise AnchorError(f'word {i + 1}: the address is in another region than {words[i]:08X} names')
                if not 0 <= off < 1 << d['bits']: raise AnchorError(f'word {i + 1}: address {hexu(off)} does not fit')
                words[i] = (words[i] & ~(0xFF if d['bits'] == 40 else 0xF)) | (off >> 32); words[i + 1] = off & 0xffffffff
                d = decode(words, i)
            if d['op'] == 0:
                tokens = set()
                for k in range(len(mem_words(d['width'], 0))):
                    j = value_index(i, d['width'], k)
                    if j in special and ':' in special[j]:
                        link, expr = special.pop(j).split(':', 1)
                        if link not in ('b', 'bl') or d['width'] < 4: raise AnchorError(f'word {j}: bad token "{link}:"')
                        region, target, h = self.addr(parse_expr(expr), cheat); how.add(h)
                        words[j] = encode_branch(link == 'bl', d['rel'] + 4 * k, target); tokens.add(j)
                if node is not None and d['mem'] == 0: self._store_values(node, d, i, words, tokens)
            if d['op'] == 1 and node is not None and d['mem'] == 0: self._compare_values(node, d, i, words)
            i += d['n']
        if special: raise AnchorError(f'word {min(special)}: a token where none can stand')
        return words, how

    def _store_values(self, node, d, i, words, tokens):
        """Apply site_word to the value words (in place) of the anchored opcode 0 store d at word i of a template, for
        each of its 4-byte memory words that lies in the code or the cave; tokens are the indexes already re-encoded."""
        for k in range(len(mem_words(d['width'], 0))):
            a, width, j = d['rel'] + 4 * k, min(d['width'], 4), value_index(i, d['width'], k)
            if self.b.where(a, width) in ('text', 'pad'): words[j] = self.site_word(node, a, width, words[j], j in tokens)

    def _compare_values(self, node, d, i, words):
        """Map the value words (in place) of the anchored opcode 1 compare d at word i the way a restore is mapped: a
        4-byte memory word of the code compared with its authored original is compared with this build's word, so an
        "if [X] == original" gate still opens where that instruction moved. Other values, and words outside the code
        anchor's verified words, are left as written (a compare only gates; it writes nothing)."""
        width = (words[i] >> 24) & 0xF
        if width < 4: return
        for k in range(width // 4):
            a, j = d['rel'] + 4 * k, value_index(i, width, k)
            if self.b.where(a, 4) != 'text': continue
            try: authored = self._site_old(node, a, 4)
            except AnchorError: continue   # beyond the anchored words: nothing recorded to map from
            if words[j] == authored: words[j] = self.b.word(a)

    def value(self, cheat, v):
        """(width, the value as an unsigned integer) of a data cheat's value in its type."""
        t = cheat.get('type', 'u32')
        if t not in TYPES: raise AnchorError(f'unknown type "{t}"')
        width, fmt = TYPES[t]
        try: raw = struct.pack('<' + fmt, float(v) if fmt in 'fd' else int(v))
        except (struct.error, ValueError, TypeError) as e: raise AnchorError(f'value {v!r} does not fit {t}') from e
        return width, int.from_bytes(raw, 'little')

    def data(self, cheat):
        """The program of a data cheat (freeze, set, min, max), how it resolved, and its meta (where its value words are,
        the static target as region:offset). never-decrease has no Atmosphère program: Atmosphère's VM keeps no state of
        a cheat between passes, so nxnative's host runs it from the meta row (type and address) and the .txt holds an
        empty entry of that name, which other engines show as an inert label."""
        action, v = cheat.get('action', 'freeze'), cheat.get('value', 0)
        ask = v == 'ask'
        if ask: v = cheat.get('default', cheat.get('min', 0))
        width, val = self.value(cheat, v)
        vw = [val >> 32, val & 0xffffffff] if width == 8 else [val]   # as Atmosphère writes a value: high word first
        node = parse_expr(cheat['target'])
        meta = {'type': cheat.get('type', 'u32'), 'action': action, 'value': str(v)}
        if ask: meta['ask'] = f'{cheat.get("min", "")}..{cheat.get("max", "")}'
        if action == 'never-decrease':
            if node[0] == 'deref': raise AnchorError('never-decrease through a pointer chain is not supported yet')
            region, off, how = self.addr(node, cheat)
            meta.update(address=f'{region}:{hexu(off)}', value='')
            return [], how + '; nxnative only: the host keeps the highest value, other engines see an empty entry', meta
        if action in ('freeze', 'set'):
            if node[0] == 'deref': words, how = self.chain(node, width, vw, cheat)
            else:
                region, off, how = self.addr(node, cheat)
                words = [width << 24 | region << 20 | off >> 32, off & 0xffffffff] + vw
                meta['value_words'] = ','.join(str(2 + k) for k in range(len(vw)))
                meta['address'] = f'{region}:{hexu(off)}'
            if action == 'set': meta['once'] = '1'
            return words, how, meta
        if action in ('min', 'max'):
            if node[0] == 'deref': raise AnchorError(f'"{action}" through a pointer chain needs a register conditional (C0), not supported yet')
            if cheat.get('type', 'u32')[0] in 'sf':   # opcode 1 compares unsigned: a negative value in memory would compare huge
                raise AnchorError(f'"{action}" compares unsigned (Atmosphère\'s opcode 1): only unsigned types')
            region, off, how = self.addr(node, cheat)
            cond = 3 if action == 'min' else 1   # min: raise it when below (<); max: lower it when above (>)
            hi, lo = off >> 32, off & 0xffffffff
            words = [0x10000000 | width << 24 | region << 20 | cond << 16 | hi, lo] + vw + [width << 24 | region << 20 | hi, lo] + vw + [0x20000000]
            meta['value_words'] = ','.join(str(k) for k in [*range(2, 2 + len(vw)), *range(4 + len(vw), 4 + 2 * len(vw))])
            meta['address'] = f'{region}:{hexu(off)}'
            return words, how, meta
        raise AnchorError(f'action "{action}" is not supported by this version of the tool')

    def chain(self, node, width, vw, cheat):
        """A freeze through a pointer chain [..[base]+o1..]+o: while the first pointer is not 0, load it, follow each
        level, add the last offset, store, then zero register 15 again (dmnt runs all enabled cheats as one program, so a
        register left set would shift a later cheat that adds it). Opcodes 1, 5, 7, 6, 4 and 2: all in the host's VM."""
        levels = []
        while node[0] == 'deref': levels.append(node[2]); node = node[1]
        levels.reverse()   # levels[i] is added after the (i + 1)-th load; the last one is the field offset
        region, base, how = self.addr(node, cheat)
        if any(not 0 <= o < 1 << 32 for o in levels): raise AnchorError('pointer chain offsets must be 0 .. 0xFFFFFFFF')
        hi, lo = base >> 32, base & 0xffffffff
        words = [0x18060000 | region << 20 | hi, lo, 0, 0]               # if u64 [region + base] != 0
        words += [0x580F0000 | region << 20 | hi, lo]                     # r15 = u64 [region + base]
        for o in levels[:-1]: words += [0x580F1000, o]                    # r15 = u64 [r15 + o]
        if levels[-1]: words += [0x780F0000, levels[-1]]                  # r15 += o
        words += [0x600F0000 | width << 24] + [0] * (2 - len(vw)) + vw    # [r15] = value (two value words)
        words += [0x400F0000, 0, 0]                                       # r15 = 0
        return words + [0x20000000], how                                  # end of the "not 0" block

    def _site_old(self, node, a, width):
        """The authored original aligned word that holds a store of width bytes at a into the code, from its code
        anchor's recorded words. Raises AnchorError when [a, a + width) is not inside those words."""
        name = node[1]
        loc = self.src.get('anchors', {}).get(name, {}).get('code')
        if loc is None: raise AnchorError(f'patch word at {hexu(a)} is in the code but "{name}" is not a code anchor')
        base, _ = self.r.resolve(name)
        old = b''.join(struct.pack('<I', int(x, 16)) for x in loc['old'].split())
        if not (base <= a and a + width <= base + len(old)): raise AnchorError(f'patch word at {hexu(a)} is outside the verified words of {name}')
        return int.from_bytes(old[(a & ~3) - base:(a & ~3) - base + 4], 'little')   # code sites are whole aligned words

    def site_word(self, node, a, width, new, token=False):
        """The value a store of width bytes at a writes on this build: the one place where patches and code templates
        (gated or not) learn what may be written. In the code: carry_write over a relocated original; then the whole
        word the store makes (a 1- or 2-byte store's too), when it is not this build's own, must not be a new adrp user
        (adrp_paired; allowed on the source's own build) and goes through _check_pc_relative. In the cave: a PC-relative
        word must stay inside the cave. A fixed main address (the cheat names its builds) and a token (re-encoded for
        this build) are written as they are. AnchorError when refused."""
        if node[1] == 'main' or token: return new
        where, a4 = self.b.where(a, width), a & ~3
        sh, mask = 8 * (a & 3), (1 << 8 * width) - 1
        if where == 'text':
            authored, here = self._site_old(node, a, width), self.b.word(a4)
            got = carry_write(authored, here, new, a, width)
            if got is None:
                raise AnchorError(f'the word at {hexu(a4)} is relocated in this build ({here:08X}, was {authored:08X}): '
                                  'the new word would keep the old build\'s address bits')
            made = here & ~(mask << sh) | got << sh
            if made != here:
                p = adrp_paired(self.b.word, a4, made)
                if p is not None and self.b.build_id != self.src.get('authored'):
                    raise AnchorError(f'the word {made:08X} written at {hexu(a4)} takes the page of the adrp at {hexu(p)}: '
                                      'its low page bits hold for the source\'s own build only')
                self._check_pc_relative(node, a4, made)
            return got
        if where == 'pad':
            made = self.b.word(a4) & ~(mask << sh) | new << sh
            t = pc_relative_target(made, a4)
            if t is not None and self.b.where(t) != 'pad':   # the cave moves as one block: only offsets inside it hold
                raise AnchorError(f'the word {made:08X} written at {hexu(a4)} in the cave is PC-relative to {hexu(t)}, outside the cave')
        return new

    def _check_pc_relative(self, node, a, w):
        """Refuse the PC-relative word w written at a when its target may not be the authored one. Its offset holds
        when the target lies in the same code anchor's words (they move together; not for an adrp, whose page depends
        on the page of its own address), or, for a branch, in the site's function found by fingerprint or body digest
        (the same layout). A function found by its window proves only the words around the site, so then it is refused."""
        t = pc_relative_target(w, a)
        if t is None: return
        loc, (site, how) = self.src['anchors'][node[1]]['code'], self.r.resolve(node[1])
        if site <= t < site + 4 * len(loc['old'].split()) and w & 0x9f000000 != 0x90000000: return
        start = site - loc.get('at', 0)
        if (branch_target(w, a) is not None or is_conditional_branch(w)) and 'size' in loc and how.startswith(('exact', 'body')) \
                and start <= t < start + loc['size']: return
        raise AnchorError(f'the word {w:08X} written at {hexu(a)} is PC-relative to {hexu(t)}: its offset is right only inside its own '
                          'function found by fingerprint or body digest' + (f' (found here by {how})' if 'size' in loc else ''))

    def patch(self, cheat):
        """The on and off programs of a patch. Per word: "if it still holds this build's original, write the new word"
        (--plain: just write it); a word equal to the original is written plainly; off puts the originals back where the
        new words are. Cave words need zeros there in this build; code words must lie inside their verified site, and
        site_word decides what may be written over a relocated or PC-relative word. Words the rewriter changed are
        reported: the guard leaves them, so a patch that changes other words too is refused whole (the guard would
        apply a partial hook, the cave and the branch to it without the rest, or half of a two-word change)."""
        on, off, how, rewritten, changed = [], [], set(), [], 0
        for w in cheat['patch']:
            if 'at' not in w or 'new' not in w: raise AnchorError('a patch item needs at and new')
            node = parse_expr(w['at'])
            region, base, h = self.addr(node, cheat); how.add(h)
            if region != 0: raise AnchorError('a patch writes into the main NSO only')
            width = w.get('width', 4)
            if width not in (1, 2, 4): raise AnchorError(f'patch width {width}')
            for k, v in enumerate(w['new'].split()):
                a = base + width * k
                where = self.b.where(a, width)
                if where not in ('text', 'pad'): raise AnchorError(f'patch address {hexu(a)} is neither code nor the cave')
                orig = int.from_bytes(self.b.img[a:a + width], 'little')
                token = ':' in v
                if token:
                    link, expr = v.split(':', 1)
                    if width != 4 or link not in ('b', 'bl'): raise AnchorError(f'bad token "{v}"')
                    new = encode_branch(link == 'bl', a, self.addr(parse_expr(expr), cheat)[1])
                else:
                    try: new = int(v, 16)
                    except ValueError as e: raise AnchorError(f'"{v}" is not a hex word') from e
                if where == 'pad' and orig: raise AnchorError(f'the cave at {hexu(a)} is not free in this build')
                new = self.site_word(node, a, width, new, token)
                rw = self.b.rewritten(a, width)
                if rw is not None and int.from_bytes(rw, 'little') != orig:
                    rewritten.append((a, rw, new != orig))
                    self.warnings.append(f'warning: "{cheat["name"]}": the rewriter changed the word at {hexu(a)} ({rw[::-1].hex().upper()}): '
                                         + ('--plain overwrites the rewritten instruction' if self.plain else 'the guard leaves it, so the cheat has no effect there'))
                hi, lo = a >> 32, a & 0xffffffff
                store = [width << 24 | hi, lo, new]
                if new == orig: on += store; continue
                changed += 1
                on += store if self.plain else [0x10050000 | width << 24 | hi, lo, orig] + store + [0x20000000]   # if [a] == orig
                if where == 'text':
                    back = [width << 24 | hi, lo, orig]
                    off += back if self.plain else [0x10050000 | width << 24 | hi, lo, new] + back + [0x20000000]   # if [a] == new
        skipped = [a for a, _, changes in rewritten if changes]
        if skipped and changed > 1 and not self.plain:
            raise AnchorError(f'the rewriter changed the word at {hexu(skipped[0])}: its guard would skip it and apply the other '
                              f'{changed - 1} changed word{"s" if changed > 2 else ""} alone (a partial hook); --plain writes them all')
        return on, off, how

    def cheat(self, c):
        """[(name, master, words, meta)] for one cheat (two for a patch with an off entry, in the source's order)."""
        base = {'section': c.get('section', ''), 'note': c.get('note', '')}
        master = bool(c.get('master'))
        if c.get('label'): return [(c['name'], master, [], dict(base, kind='label'))]
        if 'patch' in c:
            on, off, how = self.patch(c)
            on_name = c.get('on_name', c['name'])
            off_name = c.get('off_name') or (f'{c["name"]} - off' if c.get('restore') else '')
            out = [(on_name, master, on, dict(base, kind='patch', pair=off_name, how=summary(how)))]
            if off_name:
                out.append((off_name, bool(c.get('off_master')), off, dict(base, kind='patch-off', pair=on_name, how=summary(how))))
                if c.get('off_first'): out.reverse()
            return out
        if 'code' in c:
            words, how = self.code_words(c['code'], c)
            return [(c['name'], master, words, dict(base, kind='code', how=summary(how)))]
        if 'target' in c:
            words, how, meta = self.data(c)
            return [(c['name'], master, words, dict(base, kind='data', how=summary({how}), **meta))]
        raise AnchorError('a cheat needs target, patch, code or label')


def summary(how):
    """How the anchors of one cheat were resolved, for the report and the meta file."""
    return '; '.join(sorted(h for h in how if h)) or 'no anchors'


def compile_source(src_path, build, plain=False):
    """(the source, [(name, master, words or None when skipped, meta)], report lines, skipped count) for one build."""
    try: src = tomllib.loads(Path(src_path).read_text(encoding='utf-8'))
    except (OSError, tomllib.TOMLDecodeError) as e: raise AnchorError(f'{Path(src_path).resolve()}: {e}') from e
    if src.get('format') != FORMAT: raise AnchorError(f'{Path(src_path).resolve()}: format {src.get("format")!r}, this tool reads {FORMAT}')
    comp = Compiler(src, build, plain)
    entries, report, skipped = [], [], 0
    for c in src.get('cheats', []):
        if 'name' not in c: raise AnchorError(f'{Path(src_path).resolve()}: a cheat without a name')
        try:
            if c.get('builds') and build.build_id not in c['builds']: raise AnchorError(f'written for build {", ".join(c["builds"])} only')
            try: got = comp.cheat(c)
            except (KeyError, ValueError, TypeError) as e: raise AnchorError(f'malformed in the source ({e!r})') from e
        except AnchorError as e:
            report.append(f'[RED] "{c["name"]}" skipped: {e}'); skipped += 1
            entries.append((c['name'], False, None, {'kind': 'unresolved', 'section': c.get('section', ''), 'note': str(e)}))
            continue
        entries += got
        if not c.get('label'): report.append(f'ok    "{c["name"]}": {got[0][3].get("how", "")}')
        for name, _, words, _ in got:   # dmnt refuses a cheat over 0x100 words (this host takes 0x2000); guards make patches longer
            if len(words) > ATMOSPHERE_WORDS:
                report.append(f'warning: "{name}" has {len(words)} words, over the {ATMOSPHERE_WORDS} a Switch accepts per cheat'
                              + (' (--plain drops the guards)' if 'patch' in c and not plain else ''))
    weak = [e[0] for e in entries if 'weak' in e[3].get('how', '')]
    if weak: report.append(f'warning: {len(weak)} entries resolved weakly (one reference, or identical copies by order): ' + ', '.join(f'"{n}"' for n in weak))
    return src, entries, report + comp.warnings, skipped


def render(entries):
    """The Atmosphère text of the compiled entries, one instruction per line, with EdiZon's section pseudo-cheats
    ([--SectionStart:Name--] ... [--SectionEnd:Name--]) around each run of one section; skipped cheats are left out."""
    out, cur = [], ''
    for name, master, words, meta in entries + [('', False, None, {'section': ''})]:
        sec = meta.get('section', '')
        if sec != cur:
            if cur: out.append(f'[--SectionEnd:{cur}--]\n\n')
            if sec: out.append(f'[--SectionStart:{sec}--]\n\n')
            cur = sec
        if words is None: continue
        out.append(('{' + name + '}' if master else '[' + name + ']') + '\n')
        try: out.append(format_words(words, decode_all(words)))
        except AnchorError: out.append(format_words(words))   # a program kept verbatim (Compiler.code_words): four words per line
        out.append('\n')
    return ''.join(out)


META_HEAD = 'name\tkind\tsection\ttype\taction\tvalue\task\tvalue_words\tonce\tpair\tresolved\tnote\taddress'   # the host reads it by column name
META_FIRST = re.compile(r'# cheat_anchor\.py: compiled from (.*) for build ([0-9A-F]{16}) on ')
META_HASH = re.compile(r'# txt sha256 ([0-9a-f]{64})$')


def meta_text(src_name, build, entries, src, txt):
    """The compiled file's companion: header lines naming the source, the .txt's SHA-256 (so a later compile can tell a
    file it wrote from one edited since) and the builds' version names; then one row per entry, what the Mac panel can
    show beside the plain Atmosphère text."""
    out = [f'# cheat_anchor.py: compiled from {src_name} for build {build.build_id} on {TODAY}',
           f'# txt sha256 {hashlib.sha256(txt.encode("utf-8")).hexdigest()}']
    names = dict(src.get('builds', {}))
    if build.version: names.setdefault(build.build_id, build.version)
    out += [f'# build {k} {v}' for k, v in names.items()] + [META_HEAD]
    for name, _, _, m in entries:
        row = [name, m.get('kind', ''), m.get('section', ''), m.get('type', ''), m.get('action', ''), m.get('value', ''),
               m.get('ask', ''), m.get('value_words', ''), m.get('once', ''), m.get('pair', ''), m.get('how', ''), m.get('note', ''),
               m.get('address', '')]
        out.append('\t'.join(str(x).replace('\t', ' ').replace('\n', ' ') for x in row))
    return '\n'.join(out) + '\n'


def ours(txt, meta, src_name):
    """'' when txt is this tool's unchanged output of this source (its meta names the source and the .txt's hash still
    matches), else why it is not."""
    if not meta.is_file(): return 'no meta file of this tool beside it'
    head = meta.read_text(encoding='utf-8', errors='replace').split('\n')[:2]
    m1, m2 = META_FIRST.match(head[0]), META_HASH.match(head[1]) if len(head) > 1 else None
    if not m1 or not m2: return 'its meta file is not this tool\'s'
    if hashlib.sha256(txt.read_bytes()).hexdigest() != m2.group(1): return 'it was edited since it was compiled'
    if m1.group(1) != src_name: return f'it was compiled from another source ({m1.group(1)})'
    return ''


def write_compiled(out_dir, src_path, build, entries, src, replace):
    """Write <build>.txt and <build>.meta.tsv. A .txt that is not this tool's unchanged output of this source (hand-made,
    edited, or another source's) is never overwritten: the output goes to <build>.txt.new, or with replace the old
    file is kept as <build>.txt.orig."""
    out_dir = Path(out_dir); out_dir.mkdir(parents=True, exist_ok=True)
    txt, meta = out_dir / f'{build.build_id}.txt', out_dir / f'{build.build_id}.meta.tsv'
    lines, why = [], ours(txt, meta, Path(src_path).name) if txt.exists() else ''
    if why:
        if replace:
            orig = txt.with_name(txt.name + '.orig')
            if orig.exists(): raise AnchorError(f'{orig.resolve()} already exists: move it away first')
            txt.rename(orig); lines.append(f'kept the old file as {orig.resolve()} ({why})')
        else:
            lines.append(f'{txt.resolve()} is kept ({why}): the output goes to {txt.name}.new (--replace keeps the old one as .orig)')
            txt, meta = txt.with_name(txt.name + '.new'), meta.with_name(meta.name + '.new')
    text = render(entries)
    txt.write_text(text, encoding='utf-8')
    meta.write_text(meta_text(Path(src_path).name, build, entries, src, text), encoding='utf-8')
    lines.append(f'wrote {txt.resolve()} and {meta.name}')
    return lines


def main(argv=None):
    """The command line: import, compile or check (see the header); returns the exit status."""
    ap = argparse.ArgumentParser(description='Anchor Atmosphère cheats to the game\'s code (import) and compile them for any build (compile, check).')
    sub = ap.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('import', help='an Atmosphère .txt into an anchored <game>.cheats.toml')
    p.add_argument('txt'); p.add_argument('--nso', required=True, help='ExeFS/main of the build the file was written for')
    p.add_argument('-o', required=True, help='the .cheats.toml to write'); p.add_argument('--force', action='store_true', help='overwrite an existing source')
    p.add_argument('--assume-build', action='store_true', help='the file names another build: anchor it on this NSO anyway')
    for name in ('compile', 'check'):
        p = sub.add_parser(name, help='the anchored source into <build ID>.txt for the NSO\'s build' if name == 'compile' else 'compile without writing anything')
        p.add_argument('src'); p.add_argument('--nso', required=True, help='ExeFS/main of the target build')
        p.add_argument('--plain', action='store_true', help='patches as plain stores, without "still original?" guards (for build-time baking)')
        if name == 'compile':
            p.add_argument('-o', required=True, help='the cheats folder')
            p.add_argument('--replace', action='store_true', help='replace a <build>.txt this tool did not write, kept as .orig')
    a = ap.parse_args(argv)
    try:
        build = Build(a.nso)
        if a.cmd == 'import':
            if Path(a.o).exists() and not a.force: raise AnchorError(f'{Path(a.o).resolve()} exists (--force overwrites it)')
            src, report, bound = import_file(a.txt, build, a.assume_build)
            write_toml(src, a.o, Path(a.txt).name)
            print('\n'.join(report + [f'wrote {Path(a.o).resolve()}']))
            return 2 if bound else 0
        src, entries, report, skipped = compile_source(a.src, build, a.plain)
        if a.cmd == 'compile': report += write_compiled(a.o, a.src, build, entries, src, a.replace)
        done = sum(1 for e in entries if e[2] is not None and e[3].get('kind') != 'label')
        report.append(f'build {build.build_id}' + (f' ({build.version})' if build.version else '') + f': {done} entries compiled, {skipped} cheats skipped')
        print('\n'.join(report))
        return 2 if skipped else 0
    except AnchorError as e:
        print(f'[RED] {e}', file=sys.stderr)
        return 1


if __name__ == '__main__': sys.exit(main())
