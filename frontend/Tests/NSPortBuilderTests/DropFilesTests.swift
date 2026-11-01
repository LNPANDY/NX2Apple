import XCTest
import SwiftUI
@testable import NSPortBuilder

/// Files dropped on the Builds page (issue #68), sorted by the same classification as Choose game folder.
final class DropFilesTests: XCTestCase {
    private var temporary: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-drop-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }

    /// A stand-in file of `size` bytes (the classification skips empty ones, as an unfinished download leaves).
    @discardableResult private func file(_ name: String, size: Int = 16, in folder: String = "") throws -> String {
        let dir = folder.isEmpty ? temporary! : temporary.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent(name).path
        FileManager.default.createFile(atPath: path, contents: Data(repeating: 0, count: size))
        return path
    }

    /// The per-row Choose… dialog must not grey out compressed dumps (issue #236).
    func testChooseDialogOffersCompressedDumps() {
        XCTAssertEqual(Set(BuildModel.allowedFileTypes(for: .base)), ["nsp", "xci", "nsz", "xcz"])
        XCTAssertEqual(BuildModel.allowedFileTypes(for: .update), BuildModel.allowedFileTypes(for: .base))
        XCTAssertEqual(Set(BuildModel.allowedFileTypes(for: .dlc)), ["nsp", "nsz"])
        XCTAssertEqual(BuildModel.allowedFileTypes(for: .keys), ["keys"])
    }

    func testADroppedMixedSetIsSortedByTitleID() throws {
        let base = try file("Game [0100000000010000][v0].nsp", size: 64)
        let repack = try file("Game [0100000000010000].nsz", size: 32)
        let old = try file("Game [0100000000010800][v65536].nsp")
        let new = try file("Game [0100000000010800][v131072].nsz")
        let dlc1 = try file("Game DLC [0100000000011001].nsp"), dlc2 = try file("Game DLC [0100000000011002].xci")
        let keys = try file("prod.keys")
        let unfinished = try file("Game [0100000000010000].xci", size: 0)
        let unnamed = try file("game.nsp"), text = try file("readme.txt")
        let found = BuildModel.classify([dlc2, text, old, repack, unfinished, base, keys, new, unnamed, dlc1])
        XCTAssertEqual(found, BuildModel.FoundInputs(base: base, update: new, dlc: [dlc1, dlc2], keys: keys),
                       "the largest base, the newest update, every add-on sorted, the keys")
        XCTAssertEqual(BuildModel.classify([text, unnamed]), BuildModel.FoundInputs())
        XCTAssertFalse(BuildModel.FoundInputs(keys: keys).anyGame)
    }

    /// The names from issue #237: the title ID bare at the start of the name, the version as a `_vN` token.
    func testBareTitleIDNamesAreClassified() throws {
        let base = try file("01007EF00011E000_v0_420d1c5034ab.nsp", size: 64)
        let old = try file("01007EF00011E800_v1048576_48d51e6d7ff4.nsp")
        let new = try file("01007EF00011E800_v1114112_038ff9df0888.nsp")
        let dlc1 = try file("01007EF00011F001_v196608_8a46aae731b8.nsp")
        let dlc2 = try file("01007EF00011F002_v196608_193e5731baf2.nsp")
        let found = BuildModel.classify([dlc2, old, base, dlc1, new])
        XCTAssertEqual(found, BuildModel.FoundInputs(base: base, update: new, dlc: [dlc1, dlc2]))
        XCTAssertEqual(found.updateCount, 2)
        XCTAssertEqual(found.updateVersion, 1114112)
        // bracket names keep working, and win when a name has both
        XCTAssertEqual(BuildModel.titleID("Game [0100F2C0115B6000][v0].nsp"), 0x0100F2C0115B6000)
        XCTAssertEqual(BuildModel.titleID("Game 0100AAAA00000000 [0100F2C0115B6000].nsp"), 0x0100F2C0115B6000)
        XCTAssertEqual(BuildModel.updateVersion("Game [v65536] _v1.nsp"), 65536)
        XCTAssertEqual(BuildModel.updateVersion("Game v131072.nsp"), 131072)
        XCTAssertEqual(BuildModel.updateVersion("01007EF00011E800_v1114112_038ff9df0888.nsp"), 1114112)
        XCTAssertEqual(BuildModel.updateVersion("game.nsp"), 0)
        // token separators, and only IDs that look like Switch title IDs
        XCTAssertEqual(BuildModel.titleID("Game (01007EF00011E000).nsp"), 0x01007EF00011E000)
        XCTAssertEqual(BuildModel.titleID("Game-01007EF00011E000.nsp"), 0x01007EF00011E000)
        XCTAssertNil(BuildModel.titleID("0200000000000000_v0.nsp"))
        XCTAssertNil(BuildModel.titleID("x01007EF00011E000.nsp"), "not a token")
        XCTAssertNil(BuildModel.titleID("01007EF00011E0001.nsp"), "17 digits")
        // another game's update and DLC in the same folder are not taken for this base
        let other = try file("0100AAAA00000800_v65536_aaaaaaaaaaaa.nsp")
        let otherDLC = try file("0100AAAA00001001_v0_bbbbbbbbbbbb.nsp")
        XCTAssertEqual(BuildModel.classify([base, new, dlc1, other, otherDLC]).update, new)
        XCTAssertEqual(BuildModel.classify([base, new, dlc1, other, otherDLC]).dlc, [dlc1])
    }

    func testRowChecks() throws {
        let base = "01007EF00011E000_v0_420d1c5034ab.nsp"
        let update = "01007EF00011E800_v1114112_038ff9df0888.nsp"
        let dlc = "01007EF00011F001_v196608_8a46aae731b8.nsp"
        func check(_ kind: InputKind, _ name: String, _ b: String? = base) -> BuildModel.RowMismatch? {
            BuildModel.rowMismatch(kind, name: name, base: b)
        }
        XCTAssertNil(check(.update, update))
        XCTAssertNil(check(.dlc, dlc))
        XCTAssertNil(check(.base, base, nil))
        XCTAssertEqual(check(.dlc, update), .notDLC(0x01007EF00011E800), "the reporter's update in the DLC row")
        XCTAssertEqual(check(.update, dlc), .notUpdate(0x01007EF00011F001))
        XCTAssertEqual(check(.dlc, base), .notDLC(0x01007EF00011E000))
        XCTAssertEqual(check(.update, base), .notUpdate(0x01007EF00011E000))
        XCTAssertEqual(check(.base, update, nil), .notBase(0x01007EF00011E800))
        XCTAssertEqual(check(.base, dlc, nil), .notBase(0x01007EF00011F001))
        XCTAssertEqual(check(.update, "0100AAAA00000800_v1.nsp"), .otherGame)
        XCTAssertEqual(check(.dlc, "0100AAAA00001001_v1.nsp"), .otherGame)
        XCTAssertNil(check(.update, "0100AAAA00000800_v1.nsp", nil), "no base chosen yet")
        XCTAssertNil(check(.dlc, "game.nsp"), "no title ID in the name: the build script reads it from the package")
        XCTAssertNil(check(.keys, "prod.keys"))
    }

    func testPickedFilesThatDoNotFitTheRowAreNotTaken() throws {
        let m = BuildModel()
        let base = try file("01007EF00011E000_v0_420d1c5034ab.nsp")
        let update = try file("01007EF00011E800_v1114112_038ff9df0888.nsp")
        let dlc1 = try file("01007EF00011F001_v196608_8a46aae731b8.nsp")
        let dlc2 = try file("01007EF00011F002_v196608_193e5731baf2.nsp")
        m.take(picked: [base], kind: .base)
        m.take(picked: [update], kind: .dlc)
        XCTAssertEqual(m.dlcPaths, [])
        XCTAssertFalse(m.slot("dlc").problem.isEmpty)
        XCTAssertTrue(m.slot("dlc").problem.contains("01007EF00011E800"))
        m.take(picked: [dlc2, update, dlc1], kind: .dlc)
        XCTAssertEqual(m.dlcPaths, [dlc1, dlc2], "the files that fit are taken, the update is named on the row")
        XCTAssertFalse(m.slot("dlc").problem.isEmpty)
        m.take(picked: [dlc1], kind: .update)
        XCTAssertEqual(m.updatePath, "")
        m.take(picked: [update], kind: .update)
        XCTAssertEqual(m.updatePath, update)
        XCTAssertEqual(m.slot("update").problem, "")
        // a file of another game
        let foreign = try file("0100AAAA00000800_v65536_aaaaaaaaaaaa.nsp")
        m.take(picked: [foreign], kind: .update)
        XCTAssertEqual(m.updatePath, update, "the earlier choice stays")
        XCTAssertFalse(m.slot("update").problem.isEmpty)
        // dropped, the same checks apply
        let foreignDLC = try file("0100AAAA00001001_v0_bbbbbbbbbbbb.nsp")
        m.take(dropped: [foreignDLC])
        XCTAssertEqual(m.dlcPaths, [dlc1, dlc2])
        XCTAssertFalse(m.slot("dlc").problem.isEmpty)
    }

    func testTheUpdateRowSaysWhichOfSeveralUpdatesItTook() throws {
        let folder = temporary.appendingPathComponent("reporter")
        _ = try file("01007EF00011E000_v0_420d1c5034ab.nsp", size: 64, in: "reporter")
        _ = try file("01007EF00011E800_v1048576_48d51e6d7ff4.nsp", in: "reporter")
        let new = try file("01007EF00011E800_v1114112_038ff9df0888.nsp", in: "reporter")
        _ = try file("01007EF00011F001_v196608_8a46aae731b8.nsp", in: "reporter")
        _ = try file("01007EF00011F002_v196608_193e5731baf2.nsp", in: "reporter")
        let m = BuildModel()
        m.lang = .en
        m.scan(folder: folder.path)
        XCTAssertEqual(m.updatePath, new)
        XCTAssertEqual(m.dlcPaths.count, 2)
        XCTAssertEqual(m.slot("update").note, "v1114112, the newest of 2. An update contains the earlier ones.")
        XCTAssertTrue(m.slot("update").summary(m.t).contains("the newest of 2"))
        XCTAssertFalse(m.slot("update").note.contains(";"))
        XCTAssertTrue(m.slot("dlc").summary(m.t).hasPrefix("2 files"))
        XCTAssertTrue(BuildModel().slot("dlc").summary(m.t).contains("several files"))
    }

    func testDroppedFilesJoinWhatIsAlreadyChosen() throws {
        let m = BuildModel()
        let base = try file("Game [0100000000010000].nsp", in: "base")
        let dlc1 = try file("Game DLC [0100000000011001].nsp", in: "dlc")
        m.take(dropped: [base, dlc1])
        XCTAssertEqual(m.basePath, base)
        XCTAssertEqual(m.gameDir, (base as NSString).deletingLastPathComponent)
        let update = try file("Game [0100000000010800][v65536].nsp", in: "update")
        let dlc2 = try file("Game DLC [0100000000011002].nsp", in: "dlc")
        let keys = try file("prod.keys", in: "keys")
        m.take(dropped: [update, dlc2, keys])
        XCTAssertEqual(m.basePath, base, "a drop without a base game keeps the chosen one")
        XCTAssertEqual(m.updatePath, update)
        XCTAssertEqual(m.dlcPaths, [dlc1, dlc2], "add-on content is added to")
        XCTAssertEqual(m.keysPath, keys)
        XCTAssertEqual(m.gameDir, (base as NSString).deletingLastPathComponent)

        // nothing usable: the slots stay; a note only on an empty base row
        m.take(dropped: [try file("cover.jpg")])
        XCTAssertEqual(m.basePath, base)
        XCTAssertEqual(m.slot("base").problem, "")
        let empty = BuildModel()
        empty.take(dropped: [try file("notes.txt")])
        XCTAssertEqual(empty.slot("base").problem, "data.noNsp")
    }

    func testOneDroppedFolderIsTheSameAsChoosingIt() throws {
        let base = try file("Game [0100000000010000].nsp", in: "Game/Base")
        let update = try file("Game [0100000000010800][v65536].nsp", in: "Game/Update")
        let keys = try file("prod.keys", in: "Game")
        try file("Game [0100000000010800][v999999].nsp", in: "Game/0100000000010000_build")   // the pipeline's own folder is pruned
        let folder = temporary.appendingPathComponent("Game").path
        let m = BuildModel()
        m.take(dropped: [folder])
        XCTAssertEqual(m.gameDir, folder)
        XCTAssertEqual(m.basePath, base)
        XCTAssertEqual(m.updatePath, update)
        XCTAssertEqual(m.keysPath, keys)

        // a folder with a file beside it: the folder's files and the file, added to what is chosen
        let other = BuildModel()
        let dlc = try file("Game DLC [0100000000011001].nsp", in: "elsewhere")
        other.take(dropped: [folder, dlc])
        XCTAssertEqual(other.basePath, base)
        XCTAssertEqual(other.dlcPaths, [dlc])
        XCTAssertEqual(other.gameDir, (base as NSString).deletingLastPathComponent)
    }

    // MARK: Visual QA (matched by --filter testRenderLauncherForVisualQA)

    @MainActor func testRenderLauncherForVisualQADropHighlight() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else { throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture native views") }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        let oldOutput = UserDefaults.standard.object(forKey: "buildOutputDirectory")
        defer { UserDefaults.standard.set(oldOutput, forKey: "buildOutputDirectory") }
        let model = BuildModel()
        model.lang = CaptureLanguage.current(.en)
        model.outDir = temporary.path
        model.depsChecked = true
        model.deps = [BuildModel.Dep(id: "test", name: "Xcode", hint: "", present: true, installCmd: [])]
        let library = GameLibrary(file: temporary.appendingPathComponent("preview.json"))
        // the page as a drag shows it: the highlight drawn over the Builds page
        let page = BuilderView(m: model, library: library).environmentObject(PadFocus())
            .modifier(GameFilesDrop(enabled: true, label: model.t("drop.hint"), targeted: true) { _ in })
            .frame(width: 1100, height: 760).background(LauncherPalette.background).environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: page)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("build-drop.png"))
        window.orderOut(nil)
    }
}
