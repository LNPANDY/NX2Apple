import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher

/// The Controls page's layout and the DM_KEYMAP / DM_PAD_MAP it passes (read by dm/host/input_map.h).
final class ControlsTests: IsolatedDefaultsTestCase {
    private var defaults: UserDefaults!

    override func setUp() { defaults = TestDefaults.make("nxnative-controls-tests") }

    private func fn(_ id: String) -> ControlLayout.Function { ControlLayout.functions.first { $0.id == id }! }

    func testDefaultsPassNothing() {
        let layout = ControlLayout(defaults: defaults)
        XCTAssertTrue(layout.isDefault)
        XCTAssertEqual(layout.environment, [:])
        XCTAssertEqual(layout.key(fn("A")), 38)
        XCTAssertNil(layout.key(fn("RUp")))
    }

    /// #901: the editor opens with a snapshot. Cancel puts it back, and Save keeps the edits.
    func testASnapshotTellsEditsApartAndRestoreUndoesThemAlsoInTheSavedSettings() {
        let layout = ControlLayout(defaults: defaults)
        let opened = layout.snapshot
        XCTAssertEqual(layout.snapshot, opened, "nothing changed: Cancel leaves without asking")
        layout.assign(fn("A"), key: 40)
        layout.setSends("A", "B")
        XCTAssertNotEqual(layout.snapshot, opened, "edits: Cancel asks before discarding")
        XCTAssertFalse(layout.environment.isEmpty)
        layout.restore(opened)
        XCTAssertEqual(layout.snapshot, opened)
        XCTAssertEqual(layout.environment, [:])
        XCTAssertEqual(ControlLayout(defaults: defaults).environment, [:], "the discarded edit is not kept for the next start")
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

final class StageNameTests: IsolatedDefaultsTestCase {
    func testTheScriptsStageNamesAreShownInTheLaunchersLanguage() {
        let zh = { (k: String) in L10n.string(k, .zh) }, sv = { (k: String) in L10n.string(k, .sv) }
        XCTAssertEqual(Stage.localizedName("Mac shaders", zh), "Mac 着色器")
        XCTAssertEqual(Stage.localizedName("iOS shaders", zh), "iOS 着色器")
        XCTAssertEqual(Stage.localizedName("survey: code modules", sv), "Kartläggning: kodmoduler")
        XCTAssertEqual(Stage.localizedName("extract v1.2.0", sv), "Extrahera v1.2.0", "the version is kept")
        XCTAssertEqual(Stage.localizedName("Vulkan shader capture", zh), "Vulkan 着色器捕获")
        XCTAssertEqual(Stage.localizedName("a stage added later", zh), "a stage added later", "an unknown name stays as the script wrote it")
        XCTAssertEqual(Stage.localizedName("Mac app", { $0 }), "Mac app")
        let de = { (k: String) in L10n.string(k, Lang("de")) }
        XCTAssertEqual(Stage.localizedName("extract", de), "extract", "nxb 0.6.1 names the stage without a version: no \"%@ extrahieren\"")
        XCTAssertEqual(Stage.localizedName("extract v0 + v327680", de), "v0 + v327680 extrahieren")
    }

    /// A Switch 2 game folder packs its versions (pack_dump.py), a NUP unpacks them (pack_nup.py): build_ipa_from_nsp.py's
    /// stages "pack v458752", "pack DLC" and "unpack v196608" were shown in English in every language (#445).
    func testTheGameFolderStagesAreShownInTheLaunchersLanguage() {
        let de = { (k: String) in L10n.string(k, Lang("de")) }, zh = { (k: String) in L10n.string(k, .zh) }
        XCTAssertEqual(Stage.localizedName("pack v458752", de), "v458752 packen")
        XCTAssertEqual(Stage.localizedName("pack DLC", zh), "打包 DLC", "the DLC stage is its own row, not pack of \"DLC\"")
        XCTAssertEqual(Stage.localizedName("unpack v196608", zh), "解包 v196608")
        for lang in Lang.all {
            for key in ["stage.pack", "stage.pack_dlc", "stage.unpack"] { XCTAssertNotEqual(L10n.string(key, lang), key, "\(key) in \(lang)") }
        }
    }
}
