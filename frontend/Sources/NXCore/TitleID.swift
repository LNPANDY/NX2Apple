import Foundation

/// The title ID in a Switch file name and what follows from it: the owning base game, the update version and the key of a
/// game's work folder. Pure functions of the name.
package enum TitleID {
    /// The title ID in a file name: `[0100F2C0115B6000]` first, else a bare 16-digit ID that starts with 01 as a token
    /// (start of the name or after `_`, space, `-`, `.`, `(`, `[`). Only the file name counts, so a full path works and a folder named with an ID never
    /// stands in for the file (#382). Like `01007EF00011E000_v0_420d1c5034ab.nsp`.
    package static func parse(_ path: String) -> UInt64? {
        let name = (path as NSString).lastPathComponent
        let found = firstGroup(#"\[([0-9A-Fa-f]{16})\]"#, in: name)
            ?? firstGroup(#"(?:^|[_ \-.(\[])(01[0-9A-Fa-f]{14})(?![0-9A-Fa-f])"#, in: name)
        return found.flatMap { UInt64($0, radix: 16) }
    }

    /// The name of a game's work folder and output (`<key>_build`, `<key>.app`). The title ID in the file name when there
    /// is one, so `<ID>_build` stays what the library looks for. Else the file name without its extension, cut to letters,
    /// digits, `-` and `_`, plus a short hash of the full name: two games never share a folder (and so a shader cache),
    /// the same file name always gets the same one (a rebuild reuses its cache). Never a constant.
    package static func buildKey(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        if let id = parse(name) { return String(format: "%016llX", id) }
        let stem = (name as NSString).deletingPathExtension
        var hash: UInt32 = 2166136261   // FNV-1a, stable across runs (Hashable is seeded per launch)
        for byte in stem.utf8 { hash = (hash ^ UInt32(byte)) &* 16777619 }
        let clean = String(stem.unicodeScalars.map { c in
            c.isASCII && (CharacterSet.alphanumerics.contains(c) || c == "-" || c == "_") ? Character(c) : "_"
        }).prefix(40)
        return (clean.isEmpty ? "game" : String(clean)) + "-" + String(format: "%08x", hash)
    }

    /// The base game's title ID (low 12 bits clear) a title ID belongs to, as build_ipa_from_nsp.py reads it:
    /// 0x000 is a base game, 0x800 its update, anything else add-on content in the block above the base.
    package static func owner(_ tid: UInt64) -> UInt64 {
        let low = tid & 0xFFF
        return low == 0 ? tid : (low == 0x800 ? tid & ~0xFFF : (tid & ~0xFFF) - 0x1000)
    }

    /// The version in a file name, 0 when absent: `[v65536]` first, then the `_v65536` / ` v65536` token the
    /// eShop-style names use (`01007EF00011E800_v1114112_038ff9df0888.nsp`). Picks the newest of several updates.
    package static func updateVersion(_ name: String) -> Int {
        for pattern in [#"\[v(\d+)\]"#, #"(?:^|[_ ])v(\d+)(?=$|[_ .\-)\]])"#] {
            if let v = firstGroup(pattern, in: name), let n = Int(v) { return n }
        }
        return 0
    }

    private static func firstGroup(_ pattern: String, in name: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = name as NSString
        guard let m = re.firstMatch(in: name, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range(at: 1))
    }
}
