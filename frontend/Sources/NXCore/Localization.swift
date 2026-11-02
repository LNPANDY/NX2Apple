import Foundation

// The app's interface language follows the system at every launch: a device language that has a file in `frontend/l10n` selects
// that catalog and any other uses English. The Settings picker can override that choice without changing the device language.
//
// The texts are not in this file. Every language is one JSON file in `frontend/l10n` (`LocalizationFiles` finds and reads
// them), and English and Chinese have every key, so the two cannot drift apart. The other languages are overlays that use English
// as an explicit safe fallback while they are filled, which lets a new language be added without changing every view first.

/// A language of the launcher: its code, which is the name of its file in `frontend/l10n` (`sv` is `sv.json`). The list, each
/// language's own name and the locale prefixes that select it come from the files' `_language` entries, so a new language is a new
/// file and no code. Chinese and English are the two every key must have, and English is the fallback.
package struct Lang: Hashable, Sendable {
    package let code: String

    package init(_ code: String) { self.code = code }

    package static let zh = Lang("zh")
    package static let en = Lang("en")

    /// Every language that has a file, in picker order.
    package static let all: [Lang] = infos.map { Lang($0.code) }

    private static let infos: [LocalizationFiles.Language] = LocalizationFiles.languages()

    /// The language with this code, nil when no file has it (an empty or stale stored choice).
    package static func find(_ code: String) -> Lang? { all.first { $0.code == code } }

    /// The language's own name, which the picker shows. A language without a file shows its code.
    package var name: String { Self.infos.first { $0.code == code }?.name ?? code }

    /// The language tags and locale names (lowercased) that select it.
    package var locales: [String] { Self.infos.first { $0.code == code }?.locales ?? [code] }

    /// The first language one of whose locale prefixes starts the first of `preferred`, else English. A pure function of its input, so a
    /// test can pass in languages that exist only in a temporary folder.
    package static func detect(preferred: [String], among languages: [LocalizationFiles.Language]) -> Lang {
        guard let first = preferred.first?.lowercased() else { return .en }
        return languages.first { $0.locales.contains { first.hasPrefix($0) } }.map { Lang($0.code) } ?? .en
    }

    /// The device language when a file has it, else English.
    package static func device() -> Lang { detect(preferred: Locale.preferredLanguages, among: infos) }

    /// What the app starts in: the language picked in Settings, else the device's.
    ///
    /// The picker exists because the device language is not always the one someone wants to read
    /// this app in (a Chinese Windows display language on hardware bought abroad, a Mac kept in
    /// English by habit). "Follow the system" stays the default; the states are stored as
    /// "" (follow) or a language code ("zh", "en", "sv", "de", "fr", or any other file in `frontend/l10n`).
    package static func initial() -> Lang {
        find(UserDefaults.standard.string(forKey: "appLanguage") ?? "") ?? device()
    }

    /// The stored choice, or nil when following the system.
    package static var saved: Lang? {
        get { find(UserDefaults.standard.string(forKey: "appLanguage") ?? "") }
        set { UserDefaults.standard.set(newValue?.code ?? "", forKey: "appLanguage") }
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
        catalogs[lang.code]?[key] ?? catalogs["en"]?[key] ?? key
    }

    /// Every key has both languages and none is empty. Logged, never fatal.
    package static func selfCheck() -> [String] {
        var bad: [String] = []
        for (key, row) in table where row.zh.isEmpty || row.en.isEmpty { bad.append(key) }
        return bad
    }
}
