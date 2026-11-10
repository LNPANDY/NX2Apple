import XCTest
@testable import NXCore

final class ControllerPreferencesTests: XCTestCase {
    func testSteamDefaultsAndMalformedFields() {
        let defaults = SteamControllerMapping(raw: nil)
        XCTAssertEqual(defaults.pads, [1, 4])
        XCTAssertTrue(defaults.gyro)
        XCTAssertTrue(defaults.buttons.isEmpty)
        let mixed = SteamControllerMapping(raw: ["buttons": ["16": 63, "17": 2.5, "18": 99, "0": 1], "pads": [3, 9], "gyro": "no"])
        XCTAssertEqual(mixed.buttons, [16: 63])
        XCTAssertEqual(mixed.pads, [3, 4])
        XCTAssertTrue(mixed.gyro)
    }

    func testImportOncePreservesHostChoicesAndReset() {
        let memory = MemoryControllerPreferences()
        let store = ControllerPreferences(storage: memory)
        memory.values["launcher.DM_PAD_MAP"] = "A=Shake"
        XCTAssertEqual(store.launchControls(["DM_PAD_MAP": "A=B", "DM_KEYMAP": "A=40", "DM_PAD_MERGE": "1"]), ["DM_PAD_MERGE": "1"])
        XCTAssertEqual(memory.values["launcher.DM_PAD_MAP"] as? String, "A=Shake")
        XCTAssertEqual(memory.values["launcher.DM_KEYMAP"] as? String, "A=40")
        store.setMap("DM_PAD_MAP", value: nil)
        _ = store.launchControls(["DM_PAD_MAP": "A=B"])
        XCTAssertNil(memory.values["launcher.DM_PAD_MAP"], "a reset in the game's mapping panel stays reset")
    }

    func testDisabledSavingDoesNotReadOrWriteChoices() {
        let memory = MemoryControllerPreferences()
        let store = ControllerPreferences(storage: memory)
        let controls = ["DM_PAD_MAP": "A=B", "DM_SAVED_CHOICES": "0"]
        XCTAssertEqual(store.launchControls(controls, savingEnabled: false), controls)
        XCTAssertTrue(memory.values.isEmpty)
        XCTAssertEqual(store.launchControls(controls), controls)
        XCTAssertTrue(memory.values.isEmpty)
    }

    func testSteamFieldEditsPreserveOtherAndUnknownChoices() {
        let memory = MemoryControllerPreferences()
        let store = ControllerPreferences(storage: memory)
        memory.values[ControllerPreferences.steamKey] = ["buttons": ["16": 63], "future": "keep"]
        store.setSteamPad(1, mode: 3)
        store.setSteamGyro(false)
        store.setSteamButton(17, target: 0)
        let raw = memory.values[ControllerPreferences.steamKey] as! [String: Any]
        XCTAssertEqual(raw["future"] as? String, "keep")
        XCTAssertEqual(store.steam.buttons, [16: 63, 17: 0])
        XCTAssertEqual(store.steam.pads, [1, 3])
        XCTAssertFalse(store.steam.gyro)
        store.setSteamButton(16, target: -1)
        XCTAssertNil(store.steam.buttons[16])
    }
    func testGlobalControllerHelpIsTranslatedInEveryLanguage() {
        for key in ["controls.globalNote", "controls.globalApplied"] {
            let english = L10n.string(key, .en)
            XCTAssertNotEqual(english, key)
            XCTAssertNotEqual(L10n.string(key, .zh), english)
            XCTAssertNotEqual(L10n.string(key, Lang("de")), english)
            for code in ["fr", "it", "ja", "sv"] { XCTAssertNotEqual(L10n.string(key, Lang(code)), english, code) }
        }
    }

    func testWholeMapValidationShakeAndHostCaseRules() {
        for spec in ["a=sHaKe,B=NoNe", "A=B,", "Left=RS"] { XCTAssertTrue(ControllerMap.valid(spec, pad: true), spec) }
        for spec in ["", "A=16", "Shake=A", "A=B,,", "A=B, B=A", "A=B,bad", "A=RUp"] { XCTAssertFalse(ControllerMap.valid(spec, pad: true), spec) }
        for spec in ["a=40,b=038", "Shake=NoNe", "rUp=127,"] { XCTAssertTrue(ControllerMap.valid(spec, pad: false), spec) }
        for spec in ["A=-1", "A=128", "A=1.5", "A= 40", "A=", "A=00000000", "A=40,B=oops"] { XCTAssertFalse(ControllerMap.valid(spec, pad: false), spec) }
        XCTAssertFalse(ControllerMap.valid(String(repeating: "A=B,", count: 300), pad: true), "host saved-map buffer limit")
        let keys = ControllerMap.keys("a=40")
        XCTAssertEqual(keys["A"], 40)
        XCTAssertNil(keys["B"], "the host leaves the function that owned this key unbound")
        XCTAssertEqual(ControllerMap.pad("a=sHaKe,b=NONE"), ["A": "Shake", "B": "none"])
        let memory = MemoryControllerPreferences()
        let store = ControllerPreferences(storage: memory)
        XCTAssertTrue(store.setMap("DM_PAD_MAP", value: "a=sHaKe"))
        XCTAssertEqual(store.map("DM_PAD_MAP"), "a=sHaKe")
        XCTAssertFalse(store.setMap("DM_PAD_MAP", value: "A=B,broken"))
        XCTAssertEqual(store.map("DM_PAD_MAP"), "a=sHaKe", "reject whole invalid writes without removing the old choice")
    }

    func testUnchangedImportAlsoRecordsMarkerAndLeavesOtherPreferencesAlone() {
        let memory = MemoryControllerPreferences()
        memory.values["launcher.DM_FPS_TARGET"] = "60"
        memory.values[ControllerPreferences.steamKey] = ["buttons": ["16": 63]]
        let store = ControllerPreferences(storage: memory)
        XCTAssertEqual(store.launchControls([:]), [:])
        XCTAssertEqual(memory.values[ControllerPreferences.importedKey] as? Bool, true)
        _ = store.launchControls(["DM_PAD_MAP": "A=B"])
        XCTAssertNil(memory.values["launcher.DM_PAD_MAP"])
        XCTAssertEqual(memory.values["launcher.DM_FPS_TARGET"] as? String, "60")
        XCTAssertEqual(store.steam.buttons, [16: 63])
    }

    func testMalformedNumbersAreIgnoredAndResetPreservesFutureFields() {
        let raw: [String: Any] = ["buttons": ["16": -1, "17": 1.25, "18": "2", "19": 15, "20": 63, "21": -2], "pads": [2.5, 0], "gyro": 0.5]
        let mapping = SteamControllerMapping(raw: raw)
        XCTAssertEqual(mapping.buttons, [19: 15, 20: 63])
        XCTAssertEqual(mapping.pads, [1, 0])
        XCTAssertTrue(mapping.gyro)
        XCTAssertEqual(SteamControllerMapping(raw: ["pads": [2], "gyro": 0]).pads, [1, 4])
        XCTAssertFalse(SteamControllerMapping(raw: ["gyro": 0]).gyro)
        let memory = MemoryControllerPreferences()
        memory.values[ControllerPreferences.steamKey] = ["future": 7, "buttons": ["0": 1, "16": 63, "99": 12], "pads": [0, 3], "gyro": false]
        let store = ControllerPreferences(storage: memory)
        XCTAssertTrue(store.resetSteam())
        let reset = memory.values[ControllerPreferences.steamKey] as! [String: Any]
        XCTAssertEqual(reset["future"] as? Int, 7)
        XCTAssertEqual(reset["buttons"] as? [String: Int], ["99": 12])
        XCTAssertNil(reset["pads"])
        XCTAssertNil(reset["gyro"])
        XCTAssertEqual(store.steam, SteamControllerMapping(raw: nil))
    }

    func testFailedSynchronizationIsReportedAndLaunchFallsBack() {
        let memory = MemoryControllerPreferences()
        memory.syncOK = false
        let store = ControllerPreferences(storage: memory)
        XCTAssertFalse(store.setSteamGyro(false))
        XCTAssertFalse(store.setMap("DM_PAD_MAP", value: "A=Shake"))
        XCTAssertEqual(store.launchControls(["DM_KEYMAP": "A=40"]), ["DM_KEYMAP": "A=40"])
        XCTAssertNil(memory.values[ControllerPreferences.importedKey])
        memory.syncOK = true
        XCTAssertEqual(store.launchControls(["DM_KEYMAP": "A=40"]), [:])
    }

    func testSavingGateMatchesEnvFilePrecedence() {
        XCTAssertFalse(ControllerMap.savingEnabled(environment: [:], playerEnv: " # ignore\n DM_SAVED_CHOICES =0 \n", appEnv: "DM_SAVED_CHOICES=1"))
        XCTAssertTrue(ControllerMap.savingEnabled(environment: ["DM_SAVED_CHOICES": "1"], playerEnv: "DM_SAVED_CHOICES=0", appEnv: nil))
        XCTAssertFalse(ControllerMap.savingEnabled(environment: [:], playerEnv: "#DM_SAVED_CHOICES=1", appEnv: "DM_SAVED_CHOICES=0"))
        XCTAssertTrue(ControllerMap.savingEnabled(environment: [:], playerEnv: "DM_SAVED_CHOICES= 0", appEnv: "DM_SAVED_CHOICES=0"), "host does not trim leading value whitespace")
        XCTAssertTrue(ControllerMap.savingEnabled(environment: [:], playerEnv: "DM_SAVED_CHOICES=1\nDM_SAVED_CHOICES=0", appEnv: nil), "first assignment wins")
    }

}

private final class MemoryControllerPreferences: ControllerPreferenceStorage {
    var values: [String: Any] = [:]
    var syncOK = true
    func read(_ key: String) -> Any? { values[key] }
    func write(_ key: String, value: Any?) { values[key] = value }
    func synchronize() -> Bool { syncOK }
}

/// #454: the global layout reaches a game's own preferences before any start, so Finder, Dock and Launchpad starts have it.
final class GlobalLayoutSyncTests: XCTestCase {
    private let pad = "A=B,B=A"
    private let other = "A=X,X=A"

    private func prefs() -> (ControllerPreferences, SyncMemory) {
        let memory = SyncMemory()
        return (ControllerPreferences(storage: memory), memory)
    }

    func testAnUntouchedGameGetsTheGlobalLayoutWithoutAStart() {
        let (prefs, memory) = prefs()
        XCTAssertTrue(prefs.syncGlobal(["DM_PAD_MAP": pad]))
        XCTAssertEqual(memory.values["launcher.DM_PAD_MAP"] as? String, pad)
        XCTAssertNil(memory.values["launcher.DM_KEYMAP"], "no keyboard change, nothing written")
    }

    func testALaterChangeOfTheGlobalLayoutFollowsInAGameThatKeptWhatWasWritten() {
        let (prefs, memory) = prefs()
        prefs.syncGlobal(["DM_PAD_MAP": pad])
        prefs.syncGlobal(["DM_PAD_MAP": other])
        XCTAssertEqual(memory.values["launcher.DM_PAD_MAP"] as? String, other)
        prefs.syncGlobal([:])   // the global layout was reset
        XCTAssertNil(memory.values["launcher.DM_PAD_MAP"])
    }

    func testAGamesOwnLayoutAndAResetInTheGameAreLeftAlone() {
        let (prefs, memory) = prefs()
        prefs.syncGlobal(["DM_PAD_MAP": pad])
        memory.values["launcher.DM_PAD_MAP"] = "A=Y,Y=A"   // the player changed it in the game
        prefs.syncGlobal(["DM_PAD_MAP": other])
        XCTAssertEqual(memory.values["launcher.DM_PAD_MAP"] as? String, "A=Y,Y=A")
        memory.values["launcher.DM_PAD_MAP"] = nil   // the game's reset
        prefs.syncGlobal(["DM_PAD_MAP": pad])
        XCTAssertNil(memory.values["launcher.DM_PAD_MAP"], "a reset in the game stays reset")
    }

    func testSavingOffAndInvalidLayoutsWriteNothing() {
        let (prefs, memory) = prefs()
        XCTAssertTrue(prefs.syncGlobal(["DM_PAD_MAP": pad], savingEnabled: false))
        XCTAssertTrue(prefs.syncGlobal(["DM_PAD_MAP": pad, "DM_SAVED_CHOICES": "0"]))
        prefs.syncGlobal(["DM_PAD_MAP": "nonsense"])
        XCTAssertNil(memory.values["launcher.DM_PAD_MAP"])
    }

    func testAFailedWriteIsReported() {
        let (prefs, memory) = prefs()
        memory.syncOK = false
        XCTAssertFalse(prefs.syncGlobal(["DM_PAD_MAP": pad]))
    }
}

private final class SyncMemory: ControllerPreferenceStorage {
    var values: [String: Any] = [:]
    var syncOK = true
    func read(_ key: String) -> Any? { values[key] }
    func write(_ key: String, value: Any?) { values[key] = value }
    func synchronize() -> Bool { syncOK }
}
