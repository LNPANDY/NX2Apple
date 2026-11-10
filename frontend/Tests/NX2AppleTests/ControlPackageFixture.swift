import Foundation
@testable import NX2Apple

/// Synthetic packages for `PackageControl`: a Control NCA whose RomFS holds an icon and `control.nacp`, encrypted as a console's is
/// (header in AES-XTS, section in AES-CTR, the key from a common ticket or the key area), in an NSP (PFS0) or an XCI (HFS0). Every
/// key is made up here, no game data is used.
enum ControlPackageFixture {
    static let headerKey = (0..<32).map { UInt8(0xA0 ^ $0) }
    static let titlekek = (0..<16).map { UInt8(0x30 &+ $0) }
    static let keyAreaKey = (0..<16).map { UInt8(0x50 &+ $0) }
    static let titleKey = (0..<16).map { UInt8(0x70 &+ $0) }
    /// Key generation 3 in the header: revision 02.
    static let generation: UInt8 = 3
    static var keys: [String: [UInt8]] { ["header_key": headerKey, "titlekek_02": titlekek, "key_area_key_application_02": keyAreaKey] }

    static func keysFile(_ keys: [String: [UInt8]] = keys) -> String {
        keys.map { "\($0.key) = \($0.value.map { String(format: "%02X", $0) }.joined())" }.sorted().joined(separator: "\n") + "\n"
    }

    /// A 0x4000-byte NACP with these titles at their language index (0 American English, 12 Korean, 14 Simplified Chinese).
    static func nacp(_ titles: [Int: String]) -> [UInt8] {
        var t = [UInt8](repeating: 0, count: 0x4000)
        for (i, name) in titles { let b = Array(name.utf8); t.replaceSubrange((i * 0x300)..<(i * 0x300 + b.count), with: b) }
        return t
    }

    static func le(_ v: UInt64, _ n: Int) -> [UInt8] { (0..<n).map { UInt8(v >> (8 * UInt64($0)) & 0xFF) } }
    static func pad(_ b: [UInt8], _ to: Int) -> [UInt8] { b + [UInt8](repeating: 0, count: (to - b.count % to) % to) }

    /// A RomFS whose root holds `icon_AmericanEnglish.dat` and then `control.nacp` (found through the first file's sibling).
    static func romfs(nacp: [UInt8]) -> [UInt8] {
        let icon = [UInt8](repeating: 0xEE, count: 0x30)
        func fileEntry(sibling: UInt64, offset: UInt64, size: Int, name: String) -> [UInt8] {
            pad(le(0, 4) + le(sibling, 4) + le(offset, 8) + le(UInt64(size), 8) + le(0xFFFF_FFFF, 4) + le(UInt64(name.utf8.count), 4) + Array(name.utf8), 4)
        }
        let first = fileEntry(sibling: 0, offset: 0, size: icon.count, name: "icon_AmericanEnglish.dat")
        let second = fileEntry(sibling: 0xFFFF_FFFF, offset: UInt64(icon.count), size: nacp.count, name: "control.nacp")
        let files = fileEntry(sibling: UInt64(first.count), offset: 0, size: icon.count, name: "icon_AmericanEnglish.dat") + second
        let dir = le(0, 4) + le(0xFFFF_FFFF, 4) + le(0xFFFF_FFFF, 4) + le(0, 4) + le(0xFFFF_FFFF, 4) + le(0, 4)
        let dirHash = 0x50, dirMeta = dirHash + 4, fileHash = dirMeta + dir.count, fileMeta = fileHash + 4
        let data = (fileMeta + files.count + 0xF) & ~0xF
        var head = le(0x50, 8) + le(UInt64(dirHash), 8) + le(4, 8) + le(UInt64(dirMeta), 8) + le(UInt64(dir.count), 8)
        head += le(UInt64(fileHash), 8) + le(4, 8) + le(UInt64(fileMeta), 8) + le(UInt64(files.count), 8) + le(UInt64(data), 8)
        return pad(head + le(0xFFFF_FFFF, 4) + dir + le(0xFFFF_FFFF, 4) + files, 0x10) + icon + nacp
    }

    /// A Control NCA for `programID`. With `rightsID` its key is the ticket's title key, else the key area's (encrypted with
    /// key_area_key_application_02). The RomFS starts 0x200 bytes into the section, after a stand-in hash level.
    static func controlNCA(programID: UInt64, nacp: [UInt8], rightsID: [UInt8]?, encrypted: Bool = true, headerKey: [UInt8] = headerKey) -> [UInt8] {
        let section = pad([UInt8](repeating: 0, count: 0x200) + romfs(nacp: nacp), 0x200)
        var h = [UInt8](repeating: 0, count: 0xC00)
        h.replaceSubrange(0x200..<0x204, with: Array("NCA3".utf8))
        h[0x205] = 2; h[0x220] = generation
        h.replaceSubrange(0x210..<0x218, with: le(programID, 8))
        h.replaceSubrange(0x240..<0x248, with: le(6, 4) + le(UInt64(6 + section.count / 0x200), 4))
        let key: [UInt8]
        if let rightsID {
            h.replaceSubrange(0x230..<0x240, with: rightsID); key = titleKey
        } else {
            let area = [UInt8](repeating: 0x11, count: 32) + titleKey.reversed() + [UInt8](repeating: 0x22, count: 16)
            h.replaceSubrange(0x300..<0x340, with: KeyCheck.ecb(area, key: keyAreaKey, encrypt: true)!); key = Array(titleKey.reversed())
        }
        let fs = 0x400, counter: [UInt8] = [1, 0, 0, 0, 2, 0, 0, 0]
        h[fs] = 2; h[fs + 2] = 0; h[fs + 3] = 3; h[fs + 4] = encrypted ? 3 : 1
        h.replaceSubrange((fs + 8)..<(fs + 12), with: Array("IVFC".utf8))
        h.replaceSubrange((fs + 0x18 + 5 * 0x18)..<(fs + 0x18 + 5 * 0x18 + 16), with: le(0x200, 8) + le(UInt64(section.count - 0x200), 8))
        h.replaceSubrange((fs + 0x140)..<(fs + 0x148), with: counter)
        var body = section
        if encrypted {
            var blocks: [UInt8] = []
            for i in 0..<UInt64(section.count / 16) { blocks += counter.reversed() + PackageControl.be((0xC00 >> 4) + i) }
            body = zip(section, KeyCheck.ecb(blocks, key: key, encrypt: true)!).map { $0 ^ $1 }
        }
        return KeyCheck.xts(h, key: headerKey, encrypt: true)! + body
    }

    /// A common ticket (RSA-2048 SHA-256 signature) for `rightsID`, its title key under titlekek_02. Type 1 is a personalized one.
    static func ticket(rightsID: [UInt8], type: UInt8 = 0) -> [UInt8] {
        var t = [UInt8](repeating: 0, count: 0x2C0)
        t.replaceSubrange(0..<4, with: le(0x10004, 4))
        t.replaceSubrange(0x180..<0x190, with: KeyCheck.ecb(titleKey, key: titlekek, encrypt: true)!)
        t[0x281] = type
        t.replaceSubrange(0x2A0..<0x2B0, with: rightsID)
        return t
    }

    /// A PFS0 or HFS0 of these files.
    static func partition(_ files: [(String, [UInt8])], hfs0: Bool = false) -> [UInt8] {
        var names: [UInt8] = [], entries: [UInt8] = [], data: [UInt8] = []
        for (file, bytes) in files {
            entries += le(UInt64(data.count), 8) + le(UInt64(bytes.count), 8) + le(UInt64(names.count), 4)
            entries += [UInt8](repeating: 0, count: hfs0 ? 0x2C : 4)
            names += Array(file.utf8) + [0]
            data += bytes
        }
        names = pad(names, 0x20)
        return Array((hfs0 ? "HFS0" : "PFS0").utf8) + le(UInt64(files.count), 4) + le(UInt64(names.count), 4) + le(0, 4) + entries + names + data
    }

    /// A cartridge image: the card header (HEAD at 0x100, the root partition's offset at 0x130), a root HFS0 with an empty update
    /// partition and the secure partition holding `files`.
    static func xci(_ files: [(String, [UInt8])], keyArea: Bool = false) -> [UInt8] {
        var card = [UInt8](repeating: 0, count: 0x200)
        card.replaceSubrange(0x100..<0x104, with: Array("HEAD".utf8))
        card.replaceSubrange(0x130..<0x138, with: le(0x200, 8))
        let root = partition([("update", partition([], hfs0: true)), ("secure", partition(files, hfs0: true))], hfs0: true)
        return (keyArea ? [UInt8](repeating: 0x5A, count: 0x1000) : []) + card + root
    }
}
