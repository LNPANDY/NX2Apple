import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher

/// Issue #70: the controller layouts and the DM_PAD_MAP each passes. Controllers are stand-in product categories; nothing
/// reads a real controller.
final class ControlPresetsTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "nxnative-control-presets-tests"

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    private func layout(_ category: String? = nil) -> ControlLayout {
        let l = ControlLayout(defaults: defaults)
        l.controllerCategory = { category }
        return l
    }

    func testEachLayoutsPadMap() {
        let l = layout()
        XCTAssertEqual(l.padMode, .standard, "the default")
        XCTAssertNil(l.environment["DM_PAD_MAP"])
        l.setPadMode(.byLabel)
        XCTAssertEqual(l.environment, ["DM_PAD_MAP": "A=B,B=A,X=Y,Y=X"])
        XCTAssertEqual(l.sends("A"), "B")
        XCTAssertEqual(l.changeCount, 1)
        XCTAssertFalse(l.isDefault)
        l.setPadMode(.custom)
        XCTAssertNil(l.environment["DM_PAD_MAP"], "Custom with no button changed")
        XCTAssertTrue(l.isDefault)
        l.setSends("ZL", "ZR")
        XCTAssertEqual(l.environment, ["DM_PAD_MAP": "ZL=ZR"])
        l.setPadMode(.standard)
        XCTAssertNil(l.environment["DM_PAD_MAP"], "Standard ignores the custom buttons")
        l.setPadMode(.custom)
        XCTAssertEqual(l.environment, ["DM_PAD_MAP": "ZL=ZR"], "and Custom has them back")
    }

    func testAutoPicksByLabelForNintendoAndXboxControllers() {
        for category in ["Switch Pro Controller", "Nintendo Switch JoyCon (L/R)", "Nintendo Switch Joy-Con (L/R)", "Nintendo Switch Joy-Con (L)",
                         "Xbox One", "Xbox Series X", "XBOX Wireless Controller"] {
            XCTAssertEqual(ControlLayout.autoMode(category: category), .byLabel, category)
        }
        for category in ["DualSense", "DualShock 4", "MFi", "HID", "Arcade Stick", ""] {
            XCTAssertEqual(ControlLayout.autoMode(category: category), .standard, category)
        }
        XCTAssertEqual(ControlLayout.autoMode(category: nil), .standard, "no controller")
        let xbox = layout("Xbox One")
        xbox.setPadMode(.auto)
        XCTAssertEqual(xbox.environment, ["DM_PAD_MAP": "A=B,B=A,X=Y,Y=X"])
        let dualSense = layout("DualSense")
        dualSense.setPadMode(.auto)
        XCTAssertEqual(dualSense.environment, [:])
        XCTAssertEqual(dualSense.changeCount, 1, "Auto is a choice, whatever it picks now")
    }

    func testEditingAButtonSwitchesToCustomFromWhatTheButtonsSent() {
        let l = layout("Switch Pro Controller")
        l.setPadMode(.auto)
        l.setSends("ZL", "none")
        XCTAssertEqual(l.padMode, .custom)
        XCTAssertEqual(l.environment, ["DM_PAD_MAP": "A=B,B=A,X=Y,Y=X,ZL=none"], "Auto's By label, plus the change")
        let reloaded = layout()
        XCTAssertEqual(reloaded.padMode, .custom)
        XCTAssertEqual(reloaded.environment, l.environment)
        reloaded.resetController()
        XCTAssertEqual(reloaded.padMode, .standard)
        XCTAssertTrue(layout().isDefault)
    }

    func testSettingsSavedBeforeTheLayoutsStillLoad() throws {
        defaults.set(Data(#"{"keys":{"A":40,"B":-1},"pad":{"A":"B","B":"A","Minus":"none"}}"#.utf8), forKey: "controlLayout")
        let old = layout()
        XCTAssertEqual(old.padMode, .custom, "buttons set by hand are the Custom layout")
        XCTAssertEqual(old.environment, ["DM_KEYMAP": "A=40,B=none", "DM_PAD_MAP": "A=B,B=A,Minus=none"])
        defaults.set(Data(#"{"keys":{"Shake":-1},"pad":{}}"#.utf8), forKey: "controlLayout")
        XCTAssertEqual(layout().padMode, .standard)
        defaults.set(Data(#"{"keys":{},"pad":{},"mode":"byLabel"}"#.utf8), forKey: "controlLayout")
        XCTAssertEqual(layout().padMode, .byLabel)
        defaults.set(Data(#"{"keys":{},"pad":{"X":"Y"},"mode":"a mode from a later version"}"#.utf8), forKey: "controlLayout")
        XCTAssertEqual(layout().padMode, .custom)
    }

    /// The reasoning behind one By label map for both families, played through: GameController's element for each printed
    /// letter, the host's positional reading of it (front_mac.m pad_read), then DM_PAD_MAP as input_map.h applies it.
    func testByLabelGivesEveryPrintedLetterOnNintendoAndXboxControllers() {
        let host = ["buttonA": "B", "buttonB": "A", "buttonX": "Y", "buttonY": "X"]   // pad_read: by position, right A, bottom B, top X, left Y
        // Xbox: the letters are Apple's diamond. Nintendo: GameController reports the letters (seedds/nxnative#382: the Pro
        // Controller's A, on the right, arrives as buttonA). Either way the letter's element has the letter's name.
        let families = ["Xbox": ["A": "buttonA", "B": "buttonB", "X": "buttonX", "Y": "buttonY"],
                        "Nintendo": ["A": "buttonA", "B": "buttonB", "X": "buttonX", "Y": "buttonY"]]
        let map = ControlLayout.byLabelPad
        for (family, element) in families {
            for letter in ["A", "B", "X", "Y"] {
                let positional = host[element[letter]!]!
                XCTAssertEqual(map[positional] ?? positional, letter, "\(family) \(letter)")
            }
        }
        // A PlayStation controller has no letters: Standard leaves the host's positions, the Switch's layout
        XCTAssertEqual(ControlLayout.autoMode(category: "DualSense"), .standard)
    }
}
