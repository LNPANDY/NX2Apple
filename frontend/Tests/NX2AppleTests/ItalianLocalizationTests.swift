import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher

/// The Italian catalog (L10n.it) has to be complete and has to keep the rules of the shared table.
/// A string added to the table later needs its Italian entry, and this fails until it has one.
final class ItalianLocalizationTests: XCTestCase {
    /// Keys whose Italian text is the English text on purpose: names, units and button letters.
    private let sameAsEnglish: Set<String> = [
        "onboarding.platform.mac", "onboarding.platform.iphone", "onboarding.setup.metal",
        "onboarding.background.python", "onboarding.background.dotnet", "onboarding.demo.mario",
        "console.kind.gamepad", "console.batteryPercent", "console.brand", "console.platform.mac",
        "console.platform.iphone", "console.fps30", "console.fps60", "saves.toDevice", "saves.toMac", "section.app",
        "section.log", "settings.language.zh", "settings.language.en", "settings.language.sv", "settings.language.de",
        "library.ok", "build.ios", "update.pill", "data.keys", "dep.iossdk", "dep.tool.xcodegen", "dep.tool.zstd",
        "dep.tool.spirv-cross", "dep.tool.glslangValidator", "dep.glslang", "dep.xcode", "dep.metal", "dep.brew",
        "dep.xcodegen", "dep.zstd", "dep.spirv.win", "dep.zstd.win", "dep.spirv", "dep.dotnet", "dep.phase.download",
        "dep.python.hint", "controls.fn.A", "controls.fn.B", "controls.fn.X", "controls.fn.Y", "controls.fn.L",
        "controls.fn.R", "controls.fn.ZL", "controls.fn.ZR", "controls.fn.Plus", "controls.fn.Minus", "engine.detail",
        "settings.language.it", "settings.language.fr", "launch.opt.DM_FPS_TARGET.30", "launch.opt.DM_FPS_TARGET.60",
        "launch.set.DM_PRESENT_UPSCALE", "launch.opt.DM_PRESENT_UPSCALE.off", "launch.opt.DM_PRESENT_UPSCALE.metalfx", "key.tab",
    ]

    /// printf-style placeholders in order: %@, %d, %ld, %lld, %.0f and %.1f, positional %1$@, and %%.
    private func placeholders(_ s: String) -> [String] {
        let re = try! NSRegularExpression(pattern: "%(?:[0-9]+\\$)?(?:\\.[0-9]+)?(?:ll|l)?[@dsf%]")
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { String(s[Range($0.range, in: s)!]) }
    }

    func testEveryKeyHasAnItalianEntry() {
        for key in L10n.table.keys.sorted() {
            let it = L10n.it[key]
            XCTAssertNotNil(it, "\(key) has no Italian text")
            XCTAssertFalse(it?.isEmpty ?? true, key)
        }
        for key in L10n.it.keys { XCTAssertNotNil(L10n.table[key], "\(key) is Italian text for a key that does not exist") }
    }

    func testItalianIsNotLeftInEnglish() {
        for (key, row) in L10n.table where !sameAsEnglish.contains(key) {
            XCTAssertNotEqual(L10n.it[key], row.en, "\(key) has the English text in the Italian table")
        }
    }

    func testFormatPlaceholdersMatchEnglishInCountAndOrder() {
        for (key, row) in L10n.table {
            XCTAssertEqual(placeholders(L10n.string(key, .it)), placeholders(row.en), key)
        }
    }

    func testItalianFollowsTheTextRules() {
        for (key, row) in L10n.table {
            let it = L10n.string(key, .it)
            XCTAssertFalse(it.contains(";") || it.contains("\u{FF1B}"), "\(key) has a semicolon")
            XCTAssertFalse(it.contains("..."), "\(key) spells the ellipsis with three dots")
            XCTAssertEqual(row.en.contains("\u{2026}"), it.contains("\u{2026}"), "\(key): ellipsis differs from English")
            if !row.en.contains("NX2Apple") { XCTAssertFalse(it.contains("NX2Apple"), "\(key) adds the product name") }
            XCTAssertEqual(it, it.trimmingCharacters(in: .whitespaces) + (it.hasSuffix(": ") ? " " : ""), "\(key) has stray spaces")
        }
    }

    func testItalianCatalogIsUsed() {
        XCTAssertEqual(L10n.string("settings.language.it", .it), "Italiano")
        XCTAssertEqual(L10n.string("settings.language.it", .en), "Italiano")
        XCTAssertEqual(L10n.string("onboarding.start", .it), "Inizia")
        XCTAssertEqual(L10n.string("onboarding.later", .it), "Configura pi\u{f9} tardi")
        XCTAssertEqual(L10n.string("dep.recheck", .it), "Verifica di nuovo")
        XCTAssertEqual(L10n.string("saves.cancel", .it), "Annulla")
        XCTAssertEqual(Lang(rawValue: "it"), .it)
    }

    /// The prompt's strings outside the table (LocalizationStaleFrameworks.swift) have their Italian text too.
    func testTheStaleFrameworksPromptIsInItalian() {
        for key in ["stale.title", "stale.message", "stale.removeFailed", "stale.go", "stale.stop"] {
            XCTAssertNotEqual(L10n.string(key, .it), L10n.string(key, .en), key)
            XCTAssertEqual(placeholders(L10n.string(key, .it)), placeholders(L10n.string(key, .en)), key)
        }
    }

    func testTheLanguagePickerOffersItalian() {
        XCTAssertTrue(BuilderView.languageCodes.contains("it"))
    }
}
