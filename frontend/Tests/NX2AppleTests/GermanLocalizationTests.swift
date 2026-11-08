import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher

/// The German catalog (L10n.de) has to read as German and keep the text rules of the shared table.
/// Completeness and placeholders for every language are in NXCoreTests/LocalizationRulesTests.swift.
final class GermanLocalizationTests: IsolatedDefaultsTestCase {
    /// Keys whose German text is the English text on purpose: names, units and button letters.
    private let sameAsEnglish: Set<String> = [
        "onboarding.platform.mac", "onboarding.platform.iphone", "onboarding.setup.metal",
        "onboarding.background.python", "onboarding.background.dotnet", "onboarding.games.version",
        "onboarding.demo.mario", "msg.ipaAt", "console.kind.gamepad", "console.platform.mac",
        "console.platform.iphone", "console.version", "console.fps30", "console.fps60", "saves.toDevice",
        "saves.toMac", "cheats.title", "section.app", "app.version", "nav.builds", "library.ok", "build.ios", "data.update", "data.keys", "delete.part.ipa",
        "dep.iossdk", "dep.tool.xcodegen", "dep.tool.zstd", "dep.tool.spirv-cross", "dep.tool.glslangValidator",
        "dep.glslang", "dep.xcode", "dep.metal", "dep.brew", "dep.xcodegen", "dep.zstd", "dep.spirv.win",
        "dep.zstd.win", "dep.spirv", "dep.dotnet", "dep.phase.download", "dep.python.hint",
        "controls.fn.A", "controls.fn.B", "controls.fn.X", "controls.fn.Y", "controls.fn.L", "controls.fn.R",
        "controls.fn.ZL", "controls.fn.ZR", "controls.fn.Plus", "controls.fn.Minus", "launch.mods", "artwork.screenshot",
        "update.pill", "launch.opt.DM_OPMODE.0", "launch.opt.DM_PRESENT_UPSCALE.off",
        "launch.opt.DM_FPS_TARGET.30", "launch.opt.DM_FPS_TARGET.60", "launch.opt.DM_FPS_TARGET.120", "launch.opt.DM_PRESENT_UPSCALE.metalfx", "launch.opt.DM_UPSCALER.metalfx",
        "launch.opt.DM_SCREEN_ASPECT.0",   // 16:9 (Switch) reads the same in every language
        "switch2.badge",   // the console's name
        // The iOS shell's words that German writes as English does: OK, the controller, the Switch's Minus and Plus buttons, Version.
        // Every other ios.* key needs a German text that differs (ShellStringsTests in frontend-ios checks all seven languages).
        "ios.host.ok", "ios.host.padController", "ios.ui.padController", "ios.ui.padMinus", "ios.ui.padPlus", "ios.ui.version", "ios.ui.gameVersionLabel",
    ]

    func testGermanIsNotLeftInEnglish() {
        for (key, row) in L10n.table where !sameAsEnglish.contains(key) {
            XCTAssertNotEqual(L10n.de[key], row.en, "\(key) has the English text in the German table")
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
        XCTAssertEqual(Lang("de").name, "Deutsch")
        XCTAssertEqual(L10n.string("onboarding.start", .de), "Los geht\u{2019}s")
        XCTAssertEqual(L10n.string("onboarding.later", .de), "Sp\u{e4}ter einrichten")
        XCTAssertEqual(L10n.string("dep.recheck", .de), "Erneut pr\u{fc}fen")
        XCTAssertEqual(L10n.string("saves.cancel", .de), "Abbrechen")
        XCTAssertEqual(Lang.find("de"), .de)
    }

    /// The picker shows each language by its own name, which comes from the `_language` entry of its file.
    func testLanguageNamesAreTheLanguagesOwnNames() {
        let endonyms = ["zh": "中文", "en": "English", "sv": "Svenska", "de": "Deutsch", "fr": "Français"]
        for (code, name) in endonyms { XCTAssertEqual(Lang(code).name, name, code) }
    }
}

/// The opt-in capture tests render in English (and Chinese). Set `NX_CAPTURE_LANG=de` (or `sv`, `zh`)
/// to render them all in that language instead, for example into /tmp/de-shots.
enum CaptureLanguage {
    private static var chosen: Lang? { ProcessInfo.processInfo.environment["NX_CAPTURE_LANG"].flatMap { Lang.find($0) } }
    static func current(_ fallback: Lang) -> Lang { chosen ?? fallback }
    static func all(_ fallback: [Lang]) -> [Lang] { chosen.map { [$0] } ?? fallback }
}
