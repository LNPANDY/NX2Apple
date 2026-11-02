import Foundation
import Testing
@testable import ShellUI

/// Every text of the shell comes in English and in Simplified Chinese, the two languages that have every key. The catalogs are generated
/// from `frontend/l10n/*.json` (`tools/l10n_shell_catalogs.py`): another language may miss a text and then shows English.
@Suite struct ShellStringsTests {
    private static let languages = ["en", "zh-Hans"]

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
    /// Info.plist declares en and zh-Hans (CFBundleLocalizations). So both lprojs must be in the package bundle.
    @Test func bothLanguagesAreCompiledIntoTheBundle() throws {
        func text(_ language: String) throws -> String {
            let path = try #require(ShellStrings.bundle.path(forResource: language, ofType: "lproj"), "\(language).lproj")
            return String(localized: "Done", bundle: try #require(Bundle(path: path)))
        }
        #expect(try text("en") == "Done")
        #expect(try text("zh-Hans") != "Done")
        #expect(ShellStrings.bundle.path(forResource: "zh-Hant", ofType: "lproj") == nil, "Traditional Chinese has no catalog and falls back")
    }
}
