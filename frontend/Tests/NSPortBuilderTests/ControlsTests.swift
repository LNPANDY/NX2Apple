import XCTest
@testable import NSPortBuilder

/// The Controls page's layout and the DM_KEYMAP / DM_PAD_MAP it passes (read by dm/host/input_map.h).
final class ControlsTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "nxnative-controls-tests"

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    private func fn(_ id: String) -> ControlLayout.Function { ControlLayout.functions.first { $0.id == id }! }

    func testDefaultsPassNothing() {
        let layout = ControlLayout(defaults: defaults)
        XCTAssertTrue(layout.isDefault)
        XCTAssertEqual(layout.environment, [:])
        XCTAssertEqual(layout.key(fn("A")), 38)
        XCTAssertNil(layout.key(fn("RUp")))
    }

    func testAssigningAnotherFunctionsKeyLeavesThatFunctionOnNone() {
        let layout = ControlLayout(defaults: defaults)
        layout.assign(fn("A"), key: 40)   // K, B's key
        XCTAssertEqual(layout.key(fn("A")), 40)
        XCTAssertNil(layout.key(fn("B")))
        XCTAssertEqual(layout.environment, ["DM_KEYMAP": "A=40,B=none"])
        layout.assign(fn("B"), key: 38)   // and B to J: a swap
        XCTAssertEqual(layout.environment, ["DM_KEYMAP": "A=40,B=38"])
    }

    func testMovingBackToTheDefaultKeyDropsTheEntry() {
        let layout = ControlLayout(defaults: defaults)
        layout.assign(fn("RUp"), key: 126)   // ↑, the D-pad's
        XCTAssertEqual(layout.environment, ["DM_KEYMAP": "RUp=126,Up=none"])
        layout.assign(fn("Up"), key: 126)
        XCTAssertTrue(layout.isDefault, "RUp lost ↑ and is back on no key, its default")
    }

    func testControllerButtonsAndPersistence() {
        let layout = ControlLayout(defaults: defaults)
        layout.setSends("A", "B"); layout.setSends("B", "A"); layout.setSends("Minus", "none")
        layout.assign(fn("Shake"), key: nil)
        XCTAssertEqual(layout.environment, ["DM_KEYMAP": "Shake=none", "DM_PAD_MAP": "A=B,B=A,Minus=none"])
        XCTAssertEqual(layout.changeCount, 4)
        let reloaded = ControlLayout(defaults: defaults)
        XCTAssertEqual(reloaded.environment, layout.environment)
        reloaded.setSends("A", "A")
        XCTAssertEqual(reloaded.environment["DM_PAD_MAP"], "B=A,Minus=none")
        reloaded.resetKeyboard(); reloaded.resetController()
        XCTAssertTrue(ControlLayout(defaults: defaults).isDefault)
    }

    func testEveryFunctionHasALabelAndTheDefaultKeysAreDistinct() {
        let keys = ControlLayout.functions.compactMap(\.defaultKey)
        XCTAssertEqual(Set(keys).count, keys.count)
        for f in ControlLayout.functions { XCTAssertNotNil(L10n.table["controls.fn." + f.id], f.id) }
        XCTAssertEqual(ControlLayout.keyName(49), "Space")
        XCTAssertEqual(ControlLayout.keyName(126), "↑")
        XCTAssertEqual(ControlLayout.keyName(49, { L10n.string($0, .zh) }), "空格")
        XCTAssertEqual(ControlLayout.keyName(83, { L10n.string($0, .sv) }), "Numeriskt 1")
        XCTAssertEqual(ControlLayout.keyName(0, { L10n.string($0, .zh) }), "A", "a letter stays a letter")
        XCTAssertEqual(ControlLayout.keyName(200, { L10n.string($0, .sv) }), "Tangent 200")
    }
}

final class StageNameTests: XCTestCase {
    func testTheScriptsStageNamesAreShownInTheLaunchersLanguage() {
        let zh = { (k: String) in L10n.string(k, .zh) }, sv = { (k: String) in L10n.string(k, .sv) }
        XCTAssertEqual(Stage.localizedName("Mac shaders", zh), "Mac 着色器")
        XCTAssertEqual(Stage.localizedName("iOS shaders", zh), "iOS 着色器")
        XCTAssertEqual(Stage.localizedName("survey: code modules", sv), "Kartläggning: kodmoduler")
        XCTAssertEqual(Stage.localizedName("extract v1.2.0", sv), "Extrahera v1.2.0", "the version is kept")
        XCTAssertEqual(Stage.localizedName("Vulkan shader capture", zh), "Vulkan 着色器捕获")
        XCTAssertEqual(Stage.localizedName("a stage added later", zh), "a stage added later", "an unknown name stays as the script wrote it")
        XCTAssertEqual(Stage.localizedName("Mac app", { $0 }), "Mac app")
    }
}
