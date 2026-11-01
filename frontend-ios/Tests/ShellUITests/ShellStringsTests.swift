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
        for key in ["Settings", "Done", "Interface", "Performance overlay", "Game data", "Cloud saves", "Choose folder…"] {
            #expect(strings[key] != nil, "\(key)")
        }
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
