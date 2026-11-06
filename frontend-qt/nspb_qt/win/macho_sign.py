"""An ad-hoc code signature with entitlements for the app's executable, made on Windows.

macOS has `codesign` / `ldid`. The IPA stays for the player's signing tool to sign (Sideloadly,
SideStore, AltStore): those keep the entitlements the executable asks for, filtered by what the
Apple ID's App ID allows. An executable with no signature asks for none, so SideStore installed
the app without Increased Memory Limit even after SideInstaller had enabled it for the App ID.

The executable must have been linked with `-Wl,-adhoc_codesign` (`ld64.lld` writes an
`LC_CODE_SIGNATURE` and a placeholder signature at the end of `__LINKEDIT`); this replaces that
signature with: a CodeDirectory (SHA-256, 4 KB pages, the main-binary exec segment, special
slots for the requirements, the entitlements and their DER form), an empty requirements set,
the entitlements plist and the DER entitlements.
"""
from __future__ import annotations

import hashlib
import plistlib
import struct
import sys
from pathlib import Path

CSMAGIC_REQUIREMENTS = 0xFADE0C01
CSMAGIC_CODEDIRECTORY = 0xFADE0C02
CSMAGIC_EMBEDDED_SIGNATURE = 0xFADE0CC0
CSMAGIC_ENTITLEMENTS = 0xFADE7171
CSMAGIC_ENTITLEMENTS_DER = 0xFADE7172
CSSLOT_CODEDIRECTORY, CSSLOT_REQUIREMENTS, CSSLOT_ENTITLEMENTS, CSSLOT_DER = 0, 2, 5, 7
LC_SEGMENT_64, LC_CODE_SIGNATURE = 0x19, 0x1D
PAGE = 12   # log2 of the code page size the hashes cover


def der_len(n: int) -> bytes:
    if n < 0x80:
        return bytes([n])
    b = n.to_bytes((n.bit_length() + 7) // 8, 'big')
    return bytes([0x80 | len(b)]) + b


def der(tag: int, body: bytes) -> bytes:
    return bytes([tag]) + der_len(len(body)) + body


def der_value(v) -> bytes:
    if isinstance(v, bool):
        return der(0x01, b'\xff' if v else b'\x00')
    if isinstance(v, int):
        return der(0x02, v.to_bytes(max(1, (v.bit_length() + 8) // 8), 'big', signed=True))
    if isinstance(v, str):
        return der(0x0C, v.encode())
    if isinstance(v, (list, tuple)):
        return der(0x30, b''.join(der_value(x) for x in v))
    if isinstance(v, dict):
        return der(0xB0, b''.join(
            der(0x30, der(0x0C, k.encode()) + der_value(v[k])) for k in sorted(v)))
    raise ValueError(f'entitlement value {v!r}')


def der_entitlements(ents: dict) -> bytes:
    """Apple's form: [APPLICATION 16] { INTEGER 1, [CONTEXT 16] { SEQUENCE { key, value } ... } }."""
    return der(0x70, der(0x02, b'\x01') + der_value(ents))


def blob(magic: int, body: bytes) -> bytes:
    return struct.pack('>II', magic, 8 + len(body)) + body


def sign(path: str | Path, ident: str, ents: dict | None = None) -> int:
    p = Path(path)
    b = bytearray(p.read_bytes())
    magic, _cpu, _sub, _ftype, ncmds, _sizeofcmds, _flags, _ = struct.unpack_from('<IiiIIIII', b, 0)
    if magic != 0xFEEDFACF:
        raise ValueError(f'{path}: not a 64-bit Mach-O')
    o, sig_lc, linkedit, text = 32, None, None, None
    for _ in range(ncmds):
        cmd, cs = struct.unpack_from('<II', b, o)
        if cmd == LC_CODE_SIGNATURE:
            sig_lc = o
        if cmd == LC_SEGMENT_64:
            name = bytes(b[o + 8:o + 24]).rstrip(b'\0')
            if name == b'__LINKEDIT':
                linkedit = o
            if name == b'__TEXT':
                text = o
        o += cs
    if sig_lc is None or linkedit is None:
        raise ValueError(f'{path}: no LC_CODE_SIGNATURE (link with -Wl,-adhoc_codesign)')
    dataoff = struct.unpack_from('<I', b, sig_lc + 8)[0]
    code_limit = dataoff
    reqs = blob(CSMAGIC_REQUIREMENTS, struct.pack('>I', 0))
    has_ents = bool(ents)
    if has_ents:
        assert ents is not None
        xml = plistlib.dumps(ents, fmt=plistlib.FMT_XML)
        ent = blob(CSMAGIC_ENTITLEMENTS, xml)
        entd = blob(CSMAGIC_ENTITLEMENTS_DER, der_entitlements(ents))
        nslots = CSSLOT_DER
        exec_flags = 1
    else:
        ent = entd = b''
        nslots = CSSLOT_REQUIREMENTS
        exec_flags = 0
    npages = (code_limit + (1 << PAGE) - 1) >> PAGE
    ident_b = ident.encode() + b'\0'
    hdr = 88   # CodeDirectory version 0x20400 header (through execSegFlags)
    hash_off = hdr + len(ident_b) + nslots * 32
    cd_len = hash_off + npages * 32
    text_fo, text_fs = struct.unpack_from('<QQ', b, text + 40) if text is not None else (0, 0)

    def superblob(cd: bytes) -> bytes:
        items = [(CSSLOT_CODEDIRECTORY, cd), (CSSLOT_REQUIREMENTS, reqs)]
        if has_ents:
            items += [(CSSLOT_ENTITLEMENTS, ent), (CSSLOT_DER, entd)]
        off = 12 + 8 * len(items)
        index = b''
        body = b''
        for slot, bl in items:
            index += struct.pack('>II', slot, off + len(body))
            body += bl
        return (struct.pack('>III', CSMAGIC_EMBEDDED_SIGNATURE,
                            12 + len(index) + len(body), len(items))
                + index + body)

    # the signature's final size is known before hashing: write the load command and __LINKEDIT
    # sizes first (they are inside the hashed pages)
    total = len(superblob(b'\0' * cd_len))
    size = (total + 15) & ~15
    struct.pack_into('<I', b, sig_lc + 12, size)
    le_fo = struct.unpack_from('<Q', b, linkedit + 40)[0]
    new_le = dataoff + size - le_fo
    # segment_command_64: cmd, cmdsize, segname[16], vmaddr @24, vmsize @32, fileoff @40, filesize @48
    struct.pack_into('<Q', b, linkedit + 32, (new_le + 0x3FFF) & ~0x3FFF)   # vmsize, 16 KB pages
    struct.pack_into('<Q', b, linkedit + 48, new_le)                        # filesize
    del b[dataoff:]
    special = {CSSLOT_REQUIREMENTS: reqs}
    if has_ents:
        special[CSSLOT_ENTITLEMENTS] = ent
        special[CSSLOT_DER] = entd
    slots = b''.join(
        hashlib.sha256(special[i]).digest() if i in special else b'\0' * 32
        for i in range(nslots, 0, -1))
    hashes = b''.join(
        hashlib.sha256(bytes(b[i << PAGE:min((i + 1) << PAGE, code_limit)])).digest()
        for i in range(npages))
    cd = struct.pack(
        '>IIIIIIIIIBBBBIIIIQQQQ',
        CSMAGIC_CODEDIRECTORY, cd_len, 0x20400, 0x2,          # magic, length, version, flags (adhoc)
        hash_off, hdr, nslots, npages, code_limit,            # hashOffset, identOffset, nSpecialSlots, nCodeSlots, codeLimit
        32, 2, 0, PAGE, 0,                                    # hashSize, hashType SHA-256, platform, pageSize, spare2
        0, 0, 0, 0,                                           # scatterOffset, teamOffset, spare3, codeLimit64
        text_fo, text_fs, exec_flags)                         # execSegBase, execSegLimit, execSegFlags
    assert len(cd) == hdr, len(cd)
    cd += ident_b + slots + hashes
    sb = superblob(cd)
    b += sb + b'\0' * (size - len(sb))
    p.write_bytes(bytes(b))
    return len(sb)


if __name__ == '__main__':
    exe, ident, ents_path = sys.argv[1:4]
    ents = plistlib.loads(Path(ents_path).read_bytes())
    n = sign(exe, ident, ents)
    print(f'signed {exe}: ad-hoc, {len(ents)} entitlements, signature {n} bytes')
