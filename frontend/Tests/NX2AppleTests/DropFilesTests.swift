import XCTest
import SwiftUI
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher

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
        MainActor.assumeIsolated { model.dependencies.checked = true }
        MainActor.assumeIsolated { model.dependencies.deps = [Dep(id: "test", name: "Xcode", hint: "", present: true, installCmd: [])] }
        let library = GameLibrary(file: temporary.appendingPathComponent("preview.json"))
        // the page as a drag shows it: the highlight drawn over the Builds page
        let page = BuilderView(m: model, updates: model.appUpdates, repo: model.repo, engine: model.engineSync, dependencies: model.dependencies, library: library).environmentObject(PadFocus()).environmentObject(model.localizer)
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
