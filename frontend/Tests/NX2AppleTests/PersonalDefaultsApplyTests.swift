import XCTest
@testable import NX2Apple
@testable import NXCore

/// Personal defaults reaching a game (LNPANDY/NX2Apple#680) and the language precedence of #282.
final class PersonalDefaultsApplyTests: IsolatedDefaultsTestCase {
    private func language(default def: String = "en-US") -> LaunchSetting {
        LaunchSetting(env: "DM_LANG", kind: "choice", label: "Game language", note: "", def: def, section: "Game",
                      options: [["en-US", "American English"], ["de", "German"], ["fr", "French"]], min: nil, max: nil, step: nil, on: nil, off: nil)
    }
    private func rumble() -> LaunchSetting {
        LaunchSetting(env: "DM_RUMBLE", kind: "toggle", label: "Game rumble", note: "", def: "1", section: "Controls",
                      options: nil, min: nil, max: nil, step: nil, on: nil, off: nil)
    }

    func testAPersonalLanguageFindsTheGamesNearestOne() {
        let store = SavedChoices(domain: "org.nxnative.test-\(UUID().uuidString)")
        defer { CFPreferencesSetAppValue("launcher.DM_LANG" as CFString, nil, store.domain as CFString) }
        let wrote = store.applyPersonal(PersonalDefaults(values: ["DM_LANG": "de"]), to: [language()])
        XCTAssertEqual(wrote, ["DM_LANG"])
        XCTAssertEqual(store.raw("DM_LANG") as? String, "de")
    }

    func testAnExplicitChoiceIsNeverOverwritten() {
        let store = SavedChoices(domain: "org.nxnative.test-\(UUID().uuidString)")
        defer { CFPreferencesSetAppValue("launcher.DM_LANG" as CFString, nil, store.domain as CFString) }
        store.set(language(), "fr")
        XCTAssertEqual(store.applyPersonal(PersonalDefaults(values: ["DM_LANG": "de"]), to: [language()]), [])
        XCTAssertEqual(store.raw("DM_LANG") as? String, "fr")
    }

    func testALanguageTheGameLacksIsLeftToTheMacsLanguage() {
        let store = SavedChoices(domain: "org.nxnative.test-\(UUID().uuidString)")
        XCTAssertEqual(store.applyPersonal(PersonalDefaults(values: ["DM_LANG": "ko"]), to: [language()]), [])
        XCTAssertNil(store.raw("DM_LANG"))
    }

    func testOnlyLanguageDisplayAndRumbleAreAppliedAndRumbleOffIsWritten() {
        let store = SavedChoices(domain: "org.nxnative.test-\(UUID().uuidString)")
        defer { CFPreferencesSetAppValue("launcher.DM_RUMBLE" as CFString, nil, store.domain as CFString) }
        let render = LaunchSetting(env: "DM_RENDER_SCALE", kind: "range", label: "Render scale", note: "", def: "1.0", section: "Game",
                                   options: nil, min: 0.5, max: 1, step: 0.05, on: nil, off: nil)
        let wrote = store.applyPersonal(PersonalDefaults(values: ["DM_RUMBLE": "0", "DM_RENDER_SCALE": "0.5"]), to: [rumble(), render])
        XCTAssertEqual(wrote, ["DM_RUMBLE"])
        XCTAssertEqual(store.raw("DM_RUMBLE") as? String, "0")
        XCTAssertNil(store.raw("DM_RENDER_SCALE"))
    }

    func testNewGamesAreNotYetAppliedAndLoadedOnesAre() throws {
        var fresh = LibraryGame(titleID: "0100000000000001", name: "A")
        XCTAssertFalse(fresh.defaultsApplied, "a game the library adds gets the defaults before its first start")
        let data = try JSONEncoder().encode(fresh)
        fresh = try JSONDecoder().decode(LibraryGame.self, from: data)
        XCTAssertFalse(fresh.defaultsApplied)
    }
}
