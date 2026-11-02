import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher

/// The French overlay reads as French: nothing is left in English but the listed names. Completeness and placeholders for every
/// language are in NXCoreTests/LocalizationRulesTests.swift.
final class FrenchLocalizationTests: XCTestCase {
    /// Keys whose French text is the English one on purpose: names, units, button letters, codes.
    static let sameAsEnglish: Set<String> = [
        "onboarding.platform.mac", "onboarding.platform.iphone", "onboarding.background.python",
        "onboarding.background.dotnet", "onboarding.games.version", "onboarding.demo.mario",
        "console.brand", "console.platform.mac", "console.platform.iphone", "console.version",
        "saves.toDevice", "saves.toMac", "section.app", "app.version", "settings.language.zh",
        "settings.language.en", "settings.language.sv", "settings.language.de", "settings.language.fr", "library.ok",
        "build.ios", "data.keys", "dep.tool.xcodegen",
        "dep.tool.zstd", "dep.tool.spirv-cross", "dep.tool.glslangValidator", "diag.title", "dep.brew",
        "dep.spirv.win", "dep.zstd.win", "dep.python.hint", "controls.mode.auto", "controls.fn.A",
        "controls.fn.B", "controls.fn.X", "controls.fn.Y", "controls.fn.L", "controls.fn.R",
        "controls.fn.ZL", "controls.fn.ZR", "controls.fn.Plus", "controls.fn.Minus", "launch.mods",
        "pad.options", "engine.channel.stable", "launch.opt.DM_PRESENT_UPSCALE.off", "launch.opt.DM_PRESENT_UPSCALE.metalfx", "key.tab",
    ]

    func testNothingIsLeftInEnglishButTheListedNames() {
        let english = L10n.table.compactMap { key, row in L10n.fr[key] == row.en ? key : nil }
        XCTAssertEqual(Set(english), Self.sameAsEnglish)
    }

    func testFrenchIsSelectedAndReadsItsCatalog() {
        XCTAssertEqual(Lang.find("fr"), .fr)
        XCTAssertEqual(L10n.string("settings.language.fr", .fr), "Français")
        XCTAssertEqual(L10n.string("settings.language.fr", .en), "Français", "a language's name is in that language")
        XCTAssertEqual(L10n.string("onboarding.start", .fr), "Commencer")
        XCTAssertEqual(L10n.string("onboarding.platform.title", .fr), "Où voulez-vous jouer\u{a0}?")
        XCTAssertEqual(String(format: L10n.string("onboarding.stepCount", .fr), 2, 6), "Étape 2 sur 6")
    }
}
