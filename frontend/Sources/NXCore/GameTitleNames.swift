import Foundation

/// A game's name in the launcher's language. A Mac app packed with `--control` (dm/mac/pack_app.py) carries `DMTitleNames` in its
/// Info.plist: the title the game's own control data (`control.nacp`) gives in each of its languages, keyed by Horizon's language
/// codes (`RomFSLanguages.table`). The bundle name is the first of them, usually American English, so a Chinese launcher would
/// otherwise show an English or Korean name for a game that has a Chinese one.
package enum GameTitleNames {
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

    /// The Horizon codes that fit a launcher language, best first: the code itself, then the regional ones it starts in the control
    /// data's order (`en` takes `en-US`, then `en-GB`, `es` takes `es`, then `es-419`, `fr` takes `fr`, then `fr-CA`). Chinese takes Simplified first, as the launcher's Chinese is, unless the
    /// first of `preferred` (the system's languages) is a Traditional Chinese one.
    package static func codes(for lang: Lang, preferred: [String] = Locale.preferredLanguages) -> [String] {
        let all = RomFSLanguages.table.map(\.code)
        if lang.code == "zh" {
            let first = preferred.first?.lowercased() ?? ""
            let traditional = first.hasPrefix("zh-hant") || ["zh-tw", "zh-hk", "zh-mo"].contains { first.hasPrefix($0) }
            return traditional ? ["zh-Hant", "zh-Hans"] : ["zh-Hans", "zh-Hant"]
        }
        let code = lang.code.lowercased()
        return all.filter { $0.lowercased() == code } + all.filter { $0.lowercased().hasPrefix(code + "-") }
    }

    /// The name to show in `lang`: the first of its codes that `names` has, nil when it has none of them (the caller shows the
    /// bundle name, as before).
    package static func pick(_ names: [String: String], for lang: Lang, preferred: [String] = Locale.preferredLanguages) -> String? {
        guard !names.isEmpty else { return nil }
        return codes(for: lang, preferred: preferred).lazy.compactMap { names[$0] }.first
    }
}
