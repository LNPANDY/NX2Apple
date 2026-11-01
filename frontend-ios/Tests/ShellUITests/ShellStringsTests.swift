import Foundation
import Testing
@testable import ShellUI

/// Every text of the shell comes in English and in Simplified Chinese, the two languages the interface language can pick.
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
        for key in ["Settings", "Done", "Interface", "Language", "Follow device", "Performance overlay", "Game data", "Cloud saves", "Choose folder…"] {
            #expect(strings[key] != nil, "\(key)")
        }
    }

    @Test func theChosenLanguageSelectsTheStringTable() {
        func text(_ language: String) -> String {
            String(localized: "Done", bundle: ShellLanguage.bundle(ShellStrings.bundle, language: language))
        }
        #expect(ShellLanguage.supported == ["zh-Hans", "en"])
        #expect(text("en") == "Done")
        #expect(text("zh-Hans") != "Done" && !text("zh-Hans").isEmpty)
        #expect(ShellLanguage.bundle(ShellStrings.bundle, language: "") == ShellStrings.bundle, "no choice follows the device")
        #expect(ShellLanguage.bundle(ShellStrings.bundle, language: "fr") == ShellStrings.bundle, "an unknown choice follows the device")
        let count = String(localized: "\(3) of \(5)", bundle: ShellLanguage.bundle(ShellStrings.bundle, language: "zh-Hans"))
        #expect(count != "3 of 5", "an interpolated text is found in the chosen language too")
    }
}
