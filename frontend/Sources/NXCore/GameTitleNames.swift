import Compression
import Foundation

/// A game's name in the launcher's language. A Mac app packed with `--control` (dm/mac/pack_app.py) carries `DMTitleNames` in its
/// Info.plist: the title the game's own control data (`control.nacp`) gives in each of its languages, keyed by Horizon's language
/// codes (`RomFSLanguages.table`). The bundle name is the first of them, usually American English, so a Chinese launcher would
/// otherwise show an English or Korean name for a game that has a Chinese one.
package enum GameTitleNames {
    /// The system's languages, read once: `pick` runs for every card on every redraw, and `Locale.preferredLanguages` is not free.
    package static let systemLanguages = Locale.preferredLanguages

    /// The `DMTitleNames` of an Info.plist, the entries that name a known language with a name that is not blank. Empty for an app
    /// packed before the key existed.
    package static func read(_ info: [String: Any]) -> [String: String] {
        guard let raw = info["DMTitleNames"] as? [String: Any] else { return [:] }
        let known = Set(RomFSLanguages.table.map(\.code))
        var names: [String: String] = [:]
        for (code, value) in raw {
            guard known.contains(code), let name = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { continue }
            names[code] = name
        }
        return names
    }

    /// The names in a game's control data (`control.nacp`), as dm/tools/nacp.py `names()` reads them: 0x300 bytes per language
    /// (name 0x200 + publisher 0x100) in `RomFSLanguages.table` order, or, from newer SDKs, a u16 size and raw deflate that inflates
    /// to 32 entries (the 16 after the table name no language the launcher knows). An entry that is empty, not UTF-8 or not
    /// printable is left out. For an app packed before `DMTitleNames`: `TitleNameLookup` reads the control data from the game's files.
    package static func names(nacp: Data) -> [String: String] {
        let bytes = [UInt8](nacp)
        var area = Array(bytes.prefix(0x3000))
        if bytes.count >= 2 {
            let size = Int(bytes[0]) | Int(bytes[1]) << 8
            if size > 0, 2 + size <= bytes.count {
                var out = [UInt8](repeating: 0, count: 0x6000 + 1)   // no more than 32 entries: a crafted size must not inflate further
                let n = bytes.withUnsafeBufferPointer { src in
                    out.withUnsafeMutableBufferPointer { dst in
                        compression_decode_buffer(dst.baseAddress!, dst.count, src.baseAddress! + 2, size, nil, COMPRESSION_ZLIB)   // raw deflate
                    }
                }
                if n == 0x6000 { area = Array(out.prefix(0x6000)) }   // another length: a plain title that happened to inflate
            }
        }
        var names: [String: String] = [:]
        for (i, language) in RomFSLanguages.table.enumerated() where (i + 1) * 0x300 <= area.count {
            let field = area[(i * 0x300)..<(i * 0x300 + 0x200)]
            let raw = field.prefix { $0 != 0 }
            guard !raw.isEmpty, let name = String(bytes: raw, encoding: .utf8),
                  !name.unicodeScalars.contains(where: { [.control, .format, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory) }),
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            names[language.code] = name
        }
        return names
    }

    /// The human-readable display version at `0x3060..<0x3070` of `control.nacp` (`dm/tools/nacp.py`), such as `"1.0.0"`,
    /// `"1.2.1"` or `"1.0.0.2"`. Nil when the buffer is truncated, blank, non-printable or does not begin with an ASCII digit.
    package static func displayVersion(nacp: Data) -> String? {
        guard nacp.count >= 0x3070 else { return nil }
        let slice = nacp.subdata(in: 0x3060..<0x3070)
        let raw = slice.prefix { $0 != 0 }
        guard !raw.isEmpty,
              let text = String(bytes: raw, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty,
              !text.unicodeScalars.contains(where: { [.control, .format, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory) }),
              let first = text.unicodeScalars.first, ("0"..."9").contains(first) else { return nil }
        return text
    }

    /// The Horizon codes that fit a launcher language, best first: the code itself, then the regional ones it starts in the control
    /// data's order (`en` takes `en-US`, then `en-GB`, `es` takes `es`, then `es-419`, `fr` takes `fr`, then `fr-CA`). Chinese takes
    /// Simplified first, as the launcher's Chinese is, unless the first of `preferred` (the system's languages) is a Traditional Chinese one.
    package static func codes(for lang: Lang, preferred: [String] = systemLanguages) -> [String] {
        let all = RomFSLanguages.table.map(\.code)
        if lang.code == "zh" {
            let first = preferred.first?.lowercased() ?? ""
            let traditional = first.hasPrefix("zh-hant") || ["zh-tw", "zh-hk", "zh-mo"].contains { first.hasPrefix($0) }
            return traditional ? ["zh-Hant", "zh-Hans"] : ["zh-Hans", "zh-Hant"]
        }
        let code = lang.code.lowercased()
        let base = String(code.prefix { $0 != "-" })
        let exact = all.filter { $0.lowercased() == code } + all.filter { $0.lowercased().hasPrefix(code + "-") }
        let fallback = base == code ? [] : (all.filter { $0.lowercased() == base } + all.filter { $0.lowercased().hasPrefix(base + "-") && $0.lowercased() != code })
        return exact + fallback
    }

    /// The name to show in `lang`: the first of its codes that `names` has, else the English one (a Japanese launcher shows a
    /// Korean cartridge's English name rather than its Korean one), nil when it has neither (the caller shows the bundle name).
    package static func pick(_ names: [String: String], for lang: Lang, preferred: [String] = systemLanguages) -> String? {
        guard !names.isEmpty else { return nil }
        return (codes(for: lang, preferred: preferred) + codes(for: .en, preferred: preferred)).lazy.compactMap { names[$0] }.first
    }
}
