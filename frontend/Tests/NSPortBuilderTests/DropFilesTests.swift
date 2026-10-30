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
        model.lang = .en
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
