import Foundation
import Testing
import ShellUI
@testable import ShellHost

@Suite struct SettingsTests {
    private func profile(_ id: String = Fixtures.orbit) throws -> LauncherProfile {
        try LauncherProfile.parse(Data(contentsOf: Fixtures.gamesURL.appendingPathComponent(id).appendingPathComponent("launcher.json")))
    }

    @Test func defaultsComeFromTheProfile() throws {
        let box = try Sandbox()
        let store = GameSettingsStore(profile: try profile(), defaults: box.defaults(Fixtures.orbit))
        #expect(store.values() == ["DM_OPMODE": "1", "DM_SHOW_FPS": "0", "DM_UPSCALER": "off", "DM_UPSCALER_SHARPNESS": "0.5", "DM_RENDER_SCALE": "1.0"])
        #expect(!store.hasModifiedSettings)
    }

    @Test func aChangeIsKeptUnderTheLauncherKey() throws {
        let box = try Sandbox()
        let defaults = box.defaults(Fixtures.orbit)
        let store = GameSettingsStore(profile: try profile(), defaults: defaults)
        #expect(store.set("DM_SHOW_FPS", to: "1"))
        #expect(defaults.object(forKey: "launcher.DM_SHOW_FPS") as? String == "1")
        #expect(store.values()["DM_SHOW_FPS"] == "1")
        #expect(store.hasModifiedSettings)
        // A new store over the same suite, as after a relaunch.
        #expect(GameSettingsStore(profile: try profile(), defaults: box.defaults(Fixtures.orbit)).values()["DM_SHOW_FPS"] == "1")
    }

    @Test func onlyAChoiceThatDiffersFromTheDefaultIsStored() throws {
        let box = try Sandbox()
        let defaults = box.defaults(Fixtures.orbit)
        let store = GameSettingsStore(profile: try profile(), defaults: defaults)
        store.set("DM_RENDER_SCALE", to: "1.25")
        #expect(defaults.object(forKey: "launcher.DM_RENDER_SCALE") as? String == "1.25")
        store.set("DM_RENDER_SCALE", to: "1.00")   // a slider writes 1.00 for 1.0
        #expect(defaults.object(forKey: "launcher.DM_RENDER_SCALE") == nil)
        #expect(!store.hasModifiedSettings)
    }

    @Test func invalidValuesAreRefused() throws {
        let box = try Sandbox()
        let defaults = box.defaults(Fixtures.orbit)
        let store = GameSettingsStore(profile: try profile(), defaults: defaults)
        #expect(!store.set("DM_OPMODE", to: "7"))
        #expect(!store.set("DM_RENDER_SCALE", to: "9"))
        #expect(!store.set("DM_NOT_THERE", to: "1"))
        #expect(defaults.object(forKey: "launcher.DM_OPMODE") == nil)
    }

    @Test func aSavedValueTheGameNoLongerOffersReadsAsTheDefault() throws {
        let box = try Sandbox()
        let defaults = box.defaults(Fixtures.orbit)
        defaults.set("handheld-old", forKey: "launcher.DM_OPMODE")
        defaults.set(3, forKey: "launcher.DM_SHOW_FPS")   // not a string: ignored, as launcher.c would
        let store = GameSettingsStore(profile: try profile(), defaults: defaults)
        #expect(store.values()["DM_OPMODE"] == "1")
        #expect(store.values()["DM_SHOW_FPS"] == "0")
    }

    @Test func resetRestoresTheTestedDefaults() throws {
        let box = try Sandbox()
        let defaults = box.defaults(Fixtures.orbit)
        let store = GameSettingsStore(profile: try profile(), defaults: defaults)
        store.set("DM_OPMODE", to: "0"); store.set("DM_SHOW_FPS", to: "1"); store.set("DM_RENDER_SCALE", to: "0.75")
        #expect(store.hasModifiedSettings)
        store.reset()
        #expect(!store.hasModifiedSettings)
        #expect(store.values()["DM_OPMODE"] == "1")
        for s in try profile().settings { #expect(defaults.object(forKey: s.defaultsKey) == nil) }
    }

    @Test func gamesKeepTheirOwnChoices() throws {
        let box = try Sandbox()
        let a = GameSettingsStore(profile: try profile(Fixtures.orbit), defaults: box.defaults(Fixtures.orbit))
        let b = GameSettingsStore(profile: try profile(Fixtures.chain), defaults: box.defaults(Fixtures.chain))
        a.set("DM_SHOW_FPS", to: "1")
        #expect(b.values()["DM_SHOW_FPS"] == "0")
        b.reset()
        #expect(a.values()["DM_SHOW_FPS"] == "1")
        #expect(GameDefaults.suite(for: Fixtures.orbit) !== GameDefaults.suite(for: Fixtures.chain))
    }

    @Test func sectionsFollowTheListAndHideSubSettings() throws {
        let p = try profile()
        var values = GameSettingsStore(profile: p, defaults: try Sandbox().defaults("x")).values()
        var sections = SettingsPresenter.sections(profile: p, values: values)
        #expect(sections.map(\.title) == ["Game", "Performance"])
        #expect(sections[1].rows.map(\.id) == ["DM_UPSCALER", "DM_RENDER_SCALE"], "sharpness needs the upscaler on")
        values["DM_UPSCALER"] = "fsr"
        sections = SettingsPresenter.sections(profile: p, values: values)
        #expect(sections[1].rows.map(\.id) == ["DM_UPSCALER", "DM_UPSCALER_SHARPNESS", "DM_RENDER_SCALE"])
        let mode = sections[0].rows[0]
        #expect(mode.kind == .choice([SettingOption("1", "Docked"), SettingOption("0", "Handheld")]))
        #expect(sections[0].rows[1].kind == .toggle(on: "1", off: "0"))
        #expect(sections[1].rows[2].kind == .range(min: 0.5, max: 1.5, step: 0.05, unit: "×"))
        #expect(sections[1].rows[2].value == "1.0")
    }
}
