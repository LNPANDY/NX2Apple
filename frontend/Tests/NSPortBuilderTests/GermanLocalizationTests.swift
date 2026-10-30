import XCTest
@testable import NSPortBuilder

/// The German catalog (L10n.de) has to be complete and has to keep the rules of the shared table.
/// A string added to the table later needs its German entry, and this fails until it has one.
final class GermanLocalizationTests: XCTestCase {
    /// Keys whose German text is the English text on purpose: names, units and button letters.
    private let sameAsEnglish: Set<String> = [
        "onboarding.platform.mac", "onboarding.platform.iphone", "onboarding.setup.metal",
        "onboarding.background.python", "onboarding.background.dotnet", "onboarding.games.version",
        "onboarding.demo.mario", "console.kind.gamepad", "console.brand", "console.platform.mac",
        "console.platform.iphone", "console.version", "console.fps30", "console.fps60", "saves.toDevice",
        "saves.toMac", "cheats.title", "section.app", "app.version", "nav.builds", "settings.language.zh",
        "settings.language.en", "library.ok", "build.ios", "data.update", "data.keys", "msg.ipaAt",
        "dep.iossdk", "dep.tool.xcodegen", "dep.tool.zstd", "dep.tool.spirv-cross", "dep.tool.glslangValidator",
        "dep.glslang", "dep.xcode", "dep.metal", "dep.brew", "dep.xcodegen", "dep.zstd", "dep.spirv.win",
        "dep.zstd.win", "dep.spirv", "dep.dotnet", "dep.phase.download", "dep.python.hint",
        "controls.fn.A", "controls.fn.B", "controls.fn.X", "controls.fn.Y", "controls.fn.L", "controls.fn.R",
        "controls.fn.ZL", "controls.fn.ZR", "controls.fn.Plus", "controls.fn.Minus", "launch.mods",
    ]

    /// printf-style placeholders in order: %@, %d, %ld, %lld, %.0f and %.1f, positional %1$@, and %%.
    private func placeholders(_ s: String) -> [String] {
        let re = try! NSRegularExpression(pattern: "%(?:[0-9]+\\$)?(?:\\.[0-9]+)?(?:ll|l)?[@dsf%]")
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { String(s[Range($0.range, in: s)!]) }
    }

    func testEveryKeyHasAGermanEntry() {
        for key in L10n.table.keys.sorted() {
            let de = L10n.de[key]
            XCTAssertNotNil(de, "\(key) has no German text")
            XCTAssertFalse(de?.isEmpty ?? true, key)
        }
        for key in L10n.de.keys { XCTAssertNotNil(L10n.table[key], "\(key) is German text for a key that does not exist") }
    }

    func testGermanIsNotLeftInEnglish() {
        for (key, row) in L10n.table where !sameAsEnglish.contains(key) {
            XCTAssertNotEqual(L10n.de[key], row.en, "\(key) has the English text in the German table")
        }
    }

    func testFormatPlaceholdersMatchEnglishInCountAndOrder() {
        for (key, row) in L10n.table {
            XCTAssertEqual(placeholders(L10n.string(key, .de)), placeholders(row.en), key)
        }
    }

    func testGermanFollowsTheTextRules() {
        for (key, row) in L10n.table {
            let de = L10n.string(key, .de)
            XCTAssertFalse(de.contains(";") || de.contains("\u{FF1B}"), "\(key) has a semicolon")
            XCTAssertFalse(de.contains("..."), "\(key) spells the ellipsis with three dots")
            XCTAssertEqual(row.en.contains("\u{2026}"), de.contains("\u{2026}"), "\(key): ellipsis differs from English")
            XCTAssertFalse(de.contains("\u{201C}") && !de.contains("\u{201E}"), "\(key) quotes with English marks")
            if !row.en.contains("NX2Apple") { XCTAssertFalse(de.contains("NX2Apple"), "\(key) adds the product name") }
            XCTAssertEqual(de, de.trimmingCharacters(in: .whitespaces) + (de.hasSuffix(": ") ? " " : ""), "\(key) has stray spaces")
        }
    }

    func testGermanCatalogIsUsed() {
        XCTAssertEqual(L10n.string("settings.language.de", .de), "Deutsch")
        XCTAssertEqual(L10n.string("settings.language.de", .en), "German")
        XCTAssertEqual(L10n.string("onboarding.start", .de), "Los geht\u{2019}s")
        XCTAssertEqual(L10n.string("onboarding.later", .de), "Sp\u{e4}ter einrichten")
        XCTAssertEqual(L10n.string("dep.recheck", .de), "Erneut pr\u{fc}fen")
        XCTAssertEqual(L10n.string("saves.cancel", .de), "Abbrechen")
        XCTAssertEqual(Lang(rawValue: "de"), .de)
    }

    func testLanguageNamesExistInEveryLanguage() {
        for lang: Lang in [.zh, .en, .sv, .de] {
            for code in ["zh", "en", "sv", "de"] {
                let key = "settings.language.\(code)"
                XCTAssertNotEqual(L10n.string(key, lang), key)
            }
        }
    }
}

/// The opt-in capture tests render in English (and Chinese). Set `NX_CAPTURE_LANG=de` (or `sv`, `zh`)
/// to render them all in that language instead, for example into /tmp/de-shots.
enum CaptureLanguage {
    private static var chosen: Lang? { ProcessInfo.processInfo.environment["NX_CAPTURE_LANG"].flatMap { Lang(rawValue: $0) } }
    static func current(_ fallback: Lang) -> Lang { chosen ?? fallback }
    static func all(_ fallback: [Lang]) -> [Lang] { chosen.map { [$0] } ?? fallback }
}
