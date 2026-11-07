import Foundation
import Testing
@testable import ShellUI

/// Every text of the shell comes in all seven languages of the app. The catalogs are generated from `frontend/l10n/*.json`
/// (`tools/l10n_shell_catalogs.py`), so a new `ios.*` key without all seven fails here and in `tools/tests/test_l10n_shell_catalogs.py`.
@Suite struct ShellStringsTests {
    private static let languages = ["en", "zh-Hans", "de", "sv", "fr", "it", "ja"]

    /// Texts a language writes exactly as English does, by English text, with the languages that do. Names, units and words that are
    /// the same in that language. Anything else equal to English is a text nobody translated. Reviewed with each new entry.
    private static let cognates: [String: Set<String>] = [
        "30 fps": ["de", "sv", "it", "ja"], "60 fps": ["de", "sv", "it", "ja"],   // a unit
        "120 fps": ["de", "sv", "it", "ja"],                              // a unit
        "16:9 (Switch)": ["de", "sv", "fr", "it"],                 // aspect ratio and console name
        "MetalFX": ["de", "sv", "fr", "it", "ja"],                          // a name
        "Standard": ["de", "sv", "fr", "it"],                         // launch.opt: the game's standard mode, a word in each
        "Controller": ["de", "it"],
        "Handheld": ["de"],
        "Interface": ["fr"],
        "Layout": ["sv"],
        "Portrait": ["fr"],
        "Upscaling": ["it"],
        "Minus": ["de", "sv"], "Plus": ["de", "sv", "fr"],            // the Switch's buttons
        "Version %@": ["de", "sv", "fr"],
        "Version": ["de", "sv", "fr"],
        "OK": ["de", "sv", "fr", "it", "ja"],
    ]

    private func table(_ name: String, in folder: String) throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/\(folder)/Resources/Localizable.xcstrings")
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try #require(json["strings"] as? [String: Any])
    }

    @Test(arguments: ["ShellUI", "ShellHost"]) func everyKeyHasEveryLanguage(folder: String) throws {
        let strings = try table("Localizable", in: folder)
        #expect(!strings.isEmpty)
        for (key, entry) in strings {
            let localizations = ((entry as? [String: Any])?["localizations"] as? [String: Any]) ?? [:]
            for language in Self.languages {
                let unit = (localizations[language] as? [String: Any])?["stringUnit"] as? [String: Any]
                let value = unit?["value"] as? String ?? ""
                #expect(!value.isEmpty && unit?["state"] as? String == "translated", "\(folder): \"\(key)\" lacks \(language)")
            }
        }
    }

    /// German, Swedish, French, Italian and Japanese are not left in English, except the listed cognates. The list is exact, so an entry that is
    /// no longer needed fails too.
    @Test func nothingIsLeftInEnglishButTheListedCognates() throws {
        var same: [String: Set<String>] = [:]
        for folder in ["ShellUI", "ShellHost"] {
            for (key, entry) in try table("Localizable", in: folder) {
                let localizations = ((entry as? [String: Any])?["localizations"] as? [String: Any]) ?? [:]
                for language in ["de", "sv", "fr", "it", "ja"] {
                    let value = ((localizations[language] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
                    if value == key { same[key, default: []].insert(language) }
                }
            }
        }
        #expect(same == Self.cognates)
    }

    @Test func theSettingsPageTextsAreThere() throws {
        let strings = try table("Localizable", in: "ShellUI")
        for key in ["Settings", "Done", "Interface", "Performance overlay", "Game data", "Cloud saves", "Choose folder…"] {
            #expect(strings[key] != nil, "\(key)")
        }
    }

    // MARK: A game's settings rows (launcher.json is English, the catalog is keyed by that text)

    private func languageBundle(_ language: String) throws -> Bundle {
        let path = try #require(ShellStrings.bundle.path(forResource: language, ofType: "lproj"), "\(language).lproj")
        return try #require(Bundle(path: path))
    }

    @Test func aChineseDeviceReadsTheRowsOfAGameInChinese() throws {
        let zh = try languageBundle("zh-Hans")
        let kind = SettingKind.choice([SettingOption("0", "Handheld", in: zh), SettingOption("1", "Docked", in: zh)])
        let row = SettingRow(id: "DM_OPMODE", label: "Console mode", note: "Uses more GPU time and can increase heat.", kind: kind, value: "0", in: zh)
        #expect(row.label == "主机模式")
        #expect(row.note != "Uses more GPU time and can increase heat." && !row.note.isEmpty)
        guard case .choice(let options) = row.kind else { Issue.record("not a choice"); return }
        #expect(options.map(\.label) == ["掌机模式", "底座模式"])
        #expect(options.map(\.id) == ["0", "1"], "the value written to the game is not translated")
        let section = SettingSection(id: "Game", title: "Game", rows: [row], in: zh)
        #expect(section.id == "Game" && section.title == "游戏")
    }

    @Test func aNoteWithAPercentSignIsLookedUpAsItIs() throws {
        let zh = try languageBundle("zh-Hans")
        let note = "Adjusts resolution between 70% and 100% under load. Turn off to keep full resolution for the selected console mode."
        #expect(ShellStrings.setting(note, bundle: zh) != note)
    }

    @Test func aTextWithoutATranslationStaysEnglishAndIsNeverAKey() throws {
        let zh = try languageBundle("zh-Hans")
        for text in ["Thermal throttle ceiling", "ios.ui.done", "launch.set.DM_OPMODE", "DM_FPS_TARGET"] {
            #expect(ShellStrings.setting(text, bundle: zh) == text)
        }
        #expect(ShellStrings.setting("", bundle: zh) == "")
        let row = SettingRow(id: "DM_NEW", label: "Thermal throttle ceiling", note: "A new note.", kind: .toggle(on: "1", off: "0"), value: "0", in: zh)
        #expect(row.label == "Thermal throttle ceiling" && row.note == "A new note.")
    }

    @Test func englishStaysEnglishAndAnAlreadyTranslatedTextIsNotTouched() throws {
        let en = try languageBundle("en")
        #expect(ShellStrings.setting("Console mode", bundle: en) == "Console mode")
        #expect(ShellStrings.setting("主机模式", bundle: try languageBundle("zh-Hans")) == "主机模式")
    }

    @Test func theUpstreamNoteWithASemicolonIsTranslatedToo() throws {
        let note = "Keeps a pipeline archive; uses more memory."
        #expect(ShellStrings.setting(note, bundle: try languageBundle("zh-Hans")) != note)
    }

    /// The app follows the system language: iOS picks the lproj of the bundle by the device's list, and the app's
    /// Info.plist declares every language file (CFBundleLocalizations). So every lproj must be in the package bundle.
    @Test func everyLanguageIsCompiledIntoTheBundle() throws {
        func text(_ language: String) throws -> String {
            let path = try #require(ShellStrings.bundle.path(forResource: language, ofType: "lproj"), "\(language).lproj")
            return String(localized: "Done", bundle: try #require(Bundle(path: path)))
        }
        #expect(try text("en") == "Done")
        for language in Self.languages where language != "en" { #expect(try text(language) != "Done", "\(language)") }
        #expect(ShellStrings.bundle.path(forResource: "zh-Hant", ofType: "lproj") == nil, "Traditional Chinese has no catalog and falls back")
    }

    // MARK: The touch layout editor speaks every language of the app

    /// The layout editor showed an English Done in a German screen: `ios.ui.done` was only in en and zh. Every text the editor asks for
    /// (read from its source, an interpolation as %@) has all seven languages now, so a new text without them fails here.
    @Test func everyTextOfTheLayoutEditorHasEveryLanguage() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/ShellUI")
        let source = try ["TouchLayoutEditorView.swift"].map {
            try String(contentsOf: directory.appendingPathComponent($0), encoding: .utf8)
        }.joined(separator: "\n")
        let literal = try Regex(#"ShellStrings\.text\("((?:[^"\\]|\\\([^)]*\))*)"\)"#)
        let interpolation = try Regex(#"\\\([^)]*\)"#)
        let sourceKeys = Set(source.matches(of: literal).compactMap { $0.output[1].substring.map(String.init) }.map { $0.replacing(interpolation, with: "%@") })
        #expect(sourceKeys.contains("Save") && sourceKeys.contains("Exit"), "editor strings were not found in the source")
        var keys = sourceKeys
        // Passed on as LocalizationValue: the arrows' names and the two resets.
        keys.formUnion(["Move up", "Move down", "Move left", "Move right", "Reset this control", "Reset all controls", "Moved", "In its place"])
        let strings = try table("Localizable", in: "ShellUI")
        for key in keys.sorted() {
            let localizations = ((strings[key] as? [String: Any])?["localizations"] as? [String: Any]) ?? [:]
            for language in Self.languages {
                let value = ((localizations[language] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String ?? ""
                #expect(!value.isEmpty, "\"\(key)\" lacks \(language)")
            }
        }
    }

    @Test func theTwoResetsOfTheEditorReadDifferentlyInEveryLanguage() throws {
        let strings = try table("Localizable", in: "ShellUI")
        func value(_ key: String, _ language: String) -> String? {
            (((strings[key] as? [String: Any])?["localizations"] as? [String: Any])?[language] as? [String: Any])
                .flatMap { ($0["stringUnit"] as? [String: Any])?["value"] as? String }
        }
        for language in Self.languages {
            let one = try #require(value("Reset this control", language)), all = try #require(value("Reset all controls", language))
            #expect(one != all, "\(language)")
        }
    }
}
