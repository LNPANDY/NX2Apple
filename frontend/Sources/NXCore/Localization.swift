import Foundation

// The app's interface language follows the system at every launch: Chinese, Swedish, German and French variants
// select their matching catalogs; other languages use English. The Settings picker can override
// that choice without changing the device language.
//
// The texts are not in this file. Every language is one JSON file in `frontend/l10n` (`LocalizationFiles` finds and reads
// them), and English and Chinese have every key, so the two cannot drift apart. The other languages are overlays that use English
// as an explicit safe fallback while they are filled, which lets a new language be added without changing every view first.

package enum Lang: String, CaseIterable {
    case zh, en, sv, de, fr

    /// Chinese, Swedish, German and French devices use their matching catalog; every other device gets English.
    package static func device() -> Lang {
        guard let first = Locale.preferredLanguages.first?.lowercased() else { return .en }
        if first.hasPrefix("sv") { return .sv }
        if first.hasPrefix("de") { return .de }
        if first.hasPrefix("fr") { return .fr }
        return first.hasPrefix("zh") ? .zh : .en
    }

    /// What the app starts in: the language picked in Settings, else the device's.
    ///
    /// The picker exists because the device language is not always the one someone wants to read
    /// this app in (a Chinese Windows display language on hardware bought abroad, a Mac kept in
    /// English by habit). "Follow the system" stays the default; the states are stored as
    /// "" (follow), "zh", "en", "sv", "de" or "fr".
    package static func initial() -> Lang {
        switch UserDefaults.standard.string(forKey: "appLanguage") ?? "" {
        case "zh": return .zh
        case "en": return .en
        case "sv": return .sv
        case "de": return .de
        case "fr": return .fr
        default: return device()
        }
    }

    /// The stored choice, or nil when following the system.
    package static var saved: Lang? {
        get { Lang(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? "") }
        set { UserDefaults.standard.set(newValue?.rawValue ?? "", forKey: "appLanguage") }
    }
}

package enum L10n {
    /// Every language's texts, by language code and key. Read once, at the first lookup.
    package static let catalogs: [String: [String: String]] = LocalizationFiles.load()

    /// key: (Chinese, English). A key that English has and Chinese lacks has an empty Chinese text, which `selfCheck` reports.
    package static let table: [String: (zh: String, en: String)] = {
        let zh = catalogs["zh"] ?? [:]
        return (catalogs["en"] ?? [:]).reduce(into: [:]) { $0[$1.key] = (zh: zh[$1.key] ?? "", en: $1.value) }
    }()

    /// The overlays: only the keys a language has. A missing one shows the English text.
    package static let sv: [String: String] = catalogs["sv"] ?? [:]
    package static let de: [String: String] = catalogs["de"] ?? [:]
    package static let fr: [String: String] = catalogs["fr"] ?? [:]

    /// The text of `key` in `lang`, else the English text, else the key itself (it shows up in the UI rather than a blank control).
    package static func string(_ key: String, _ lang: Lang) -> String {
        catalogs[lang.rawValue]?[key] ?? catalogs["en"]?[key] ?? key
    }

    /// Every key has both languages and none is empty. Logged, never fatal.
    package static func selfCheck() -> [String] {
        var bad: [String] = []
        for (key, row) in table where row.zh.isEmpty || row.en.isEmpty { bad.append(key) }
        return bad
    }
}
