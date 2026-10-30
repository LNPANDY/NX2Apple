import XCTest
import SwiftUI
import AppKit
@testable import NSPortBuilder

/// "Game files inside the IPA": the option passes `--romfs bundle` and sets DM_FULL_ROMFS=1 and DM_COPY_ROMFS=YES (build_ipa.sh
/// lets DM_COPY_ROMFS win over DM_FULL_ROMFS), is off by default, and only an iPhone or iPad build takes it. The install
/// flows with the stand-in tools are in LibraryTests (testFull...).
final class FullRomfsTests: XCTestCase {
    private let key = "fullRomfsInIPA"

    override func setUp() { UserDefaults.standard.removeObject(forKey: key) }
    override func tearDown() { UserDefaults.standard.removeObject(forKey: key) }

    @MainActor func testTheOptionIsOffByDefaultAndAddsNothing() {
        let m = BuildModel()
        XCTAssertFalse(m.fullRomfs)
        XCTAssertEqual(BuildModel.gameFilesEnvironment(fullRomfs: m.fullRomfs, target: "ios"), [:])
        XCTAssertEqual(BuildModel.gameFilesArguments(fullRomfs: m.fullRomfs, target: "ios"), [])
    }

    @MainActor func testTheOptionPacksTheGameFilesForAnIPAOnly() {
        // DM_COPY_ROMFS=YES as well: build_ipa.sh gives it precedence over DM_FULL_ROMFS, so nothing set earlier can turn it slim
        XCTAssertEqual(BuildModel.gameFilesEnvironment(fullRomfs: true, target: "ios"), ["DM_FULL_ROMFS": "1", "DM_COPY_ROMFS": "YES"])
        XCTAssertEqual(BuildModel.gameFilesEnvironment(fullRomfs: true, target: "mac-app"), [:])
        // and the script's own option, so it also wins where a build passes `--romfs separate` (#213)
        XCTAssertEqual(BuildModel.gameFilesArguments(fullRomfs: true, target: "ios"), ["--romfs", "bundle"])
        XCTAssertEqual(BuildModel.gameFilesArguments(fullRomfs: true, target: "mac-app"), [])
    }

    @MainActor func testTheChoiceIsRemembered() {
        let m = BuildModel()
        m.fullRomfs = true
        XCTAssertTrue(BuildModel().fullRomfs)
    }

    func testAReSignOfAnAppWithItsGameFilesKeepsThemExplicitly() {
        func command(_ keeps: Bool) -> [String] {
            BuildModel.resignCommand(xcrun: "/x", project: "/p", scheme: "S", device: "D", derived: "/d", team: "T", bundle: "b", keepsGameFiles: keeps)
        }
        // YES, not just no NO: a Gen/dm.xcconfig that says NO would win over an absent setting
        XCTAssertTrue(command(true).contains("DM_COPY_ROMFS=YES"))
        XCTAssertFalse(command(true).contains("DM_COPY_ROMFS=NO"))
        XCTAssertTrue(command(false).contains("DM_COPY_ROMFS=NO"))
        XCTAssertFalse(command(false).contains("DM_COPY_ROMFS=YES"))
    }

    func testWhatCountsAsGameFilesInAnIPA() {
        XCTAssertTrue(BuildModel.isGameFilesEntry("Payload/DmIOS.app/romfs.img"))
        XCTAssertTrue(BuildModel.isGameFilesEntry("Payload/Game.app/romfs/data/a.bin"))
        XCTAssertFalse(BuildModel.isGameFilesEntry("Payload/DmIOS.app/romfs.id"))
        XCTAssertFalse(BuildModel.isGameFilesEntry("Payload/DmIOS.app/romfs/"))
        XCTAssertFalse(BuildModel.isGameFilesEntry("Payload/DmIOS.app/DmIOS"))
        XCTAssertFalse(BuildModel.isGameFilesEntry("Payload/DmIOS.app/aoc/1.img"))
        XCTAssertFalse(BuildModel.isGameFilesEntry("romfs.img"))
    }

    func testAnArtifactIsCheckedForTheGameFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fullromfs-art-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        let slim = dir.appendingPathComponent("slim/DmIOS.app"), image = dir.appendingPathComponent("image/DmIOS.app"), folder = dir.appendingPathComponent("folder/DmIOS.app")
        for app in [slim, image, folder] { try fm.createDirectory(at: app, withIntermediateDirectories: true) }
        try Data("id".utf8).write(to: slim.appendingPathComponent("romfs.id"))
        try Data("img".utf8).write(to: image.appendingPathComponent("romfs.img"))
        try Data().write(to: folder.appendingPathComponent("romfs.img"))   // an empty image is not game data
        XCTAssertFalse(BuildModel.appHoldsGameFiles(slim.path))
        XCTAssertTrue(BuildModel.appHoldsGameFiles(image.path))
        XCTAssertFalse(BuildModel.appHoldsGameFiles(folder.path))
        try fm.createDirectory(at: folder.appendingPathComponent("romfs"), withIntermediateDirectories: true)
        XCTAssertFalse(BuildModel.appHoldsGameFiles(folder.path))   // an empty folder neither
        try Data("x".utf8).write(to: folder.appendingPathComponent("romfs/a.bin"))
        XCTAssertTrue(BuildModel.appHoldsGameFiles(folder.path))
        // the IPA: its Payload
        guard fm.isExecutableFile(atPath: "/usr/bin/ditto") else { throw XCTSkip("ditto is required") }
        for (name, app) in [("slim", slim), ("image", image)] {
            let payload = dir.appendingPathComponent(name + "/Payload")
            try fm.createDirectory(at: payload, withIntermediateDirectories: true)
            try fm.moveItem(at: app, to: payload.appendingPathComponent("DmIOS.app"))
            let ipa = dir.appendingPathComponent(name + ".ipa")
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = BuildModel.ipaCommand(payload: payload.path, ipa: ipa.path).dropFirst().map { $0 }
            try p.run(); p.waitUntilExit()
            XCTAssertEqual(BuildModel.ipaHoldsGameFiles(ipa.path), name == "image", name)
        }
        XCTAssertFalse(BuildModel.ipaHoldsGameFiles(dir.appendingPathComponent("missing.ipa").path))
    }

    func testTheDevicesOldGameFilesAreRecognisedInTheListing() {
        XCTAssertTrue(BuildModel.listingHoldsOldGameFiles(["Documents/games/0100535012974000/romfs.img  4294967296"]))
        XCTAssertTrue(BuildModel.listingHoldsOldGameFiles(["Documents/romfs.img 5"]))
        XCTAssertTrue(BuildModel.listingHoldsOldGameFiles(["Documents/romfs/data/a.bin 5"]))
        XCTAssertTrue(BuildModel.listingHoldsOldGameFiles(["Documents/games/0100535012974000/romfs 0"]))
        XCTAssertFalse(BuildModel.listingHoldsOldGameFiles(["Name Size", "Documents/saves/0.sav 12", "Documents/log.txt 3", "Documents/romfs.id 40"]))
        XCTAssertFalse(BuildModel.listingHoldsOldGameFiles([]))
        // only the app's own Documents are listed, and only the game's files are looked for: nothing is deleted
        let command = BuildModel.documentsListing(xcrun: "/x", device: "D", bundle: "b")
        XCTAssertEqual(Array(command[1...4]), ["devicectl", "device", "info", "files"])
        XCTAssertFalse(command.contains("delete") || command.contains("--remove-existing-content"))
    }

    func testThePickedFilesSizeIsKnownBeforeTheBuild() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fullromfs-size-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("folder/sub"), withIntermediateDirectories: true)
        let base = dir.appendingPathComponent("base.nsp"), update = dir.appendingPathComponent("folder/sub/update.nsp"), keys = dir.appendingPathComponent("prod.keys")
        try Data(count: 3000).write(to: base); try Data(count: 500).write(to: update); try Data(count: 99).write(to: keys)
        let m = BuildModel()
        XCTAssertNil(m.pickedGameFilesBytes)
        m.slots[0].paths = [base.path]
        m.slots[1].paths = [dir.appendingPathComponent("folder").path]
        m.slots[3].paths = [keys.path]
        XCTAssertEqual(m.pickedGameFilesBytes, 3500)   // the keys are not game files
        XCTAssertEqual(BuildModel.size(ofItem: dir.appendingPathComponent("missing").path), 0)
    }

    func testTheNewStringsHaveEveryLanguage() {
        for key in ["opt.fullRomfs", "opt.fullRomfs.note", "opt.fullRomfs.size", "msg.doneFull", "install.step2full", "msg.fullNoGameFiles", "dev.oldFilesStage", "dev.oldGameFiles"] {
            for lang in [Lang.zh, .en, .sv] {
                let s = L10n.string(key, lang)
                XCTAssertNotEqual(s, key)
                XCTAssertFalse(s.contains(";") || s.contains("；"), s)
            }
            XCTAssertNotEqual(L10n.string(key, .sv), L10n.string(key, .en))
        }
    }

    /// Opt-in native rendering for pull request screenshots (NX_LAUNCHER_CAPTURE_DIR).
    @MainActor func testRenderTheBuildOptionsForScreenshots() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else { throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture native views") }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("fullromfs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        for (name, on, lang) in [("full-romfs-off", false, Lang.en), ("full-romfs-on", true, .en), ("full-romfs-on-zh", true, .zh), ("full-romfs-on-sv", true, .sv)] {
            let m = BuildModel()
            m.lang = lang
            m.target = "ios"
            m.depsChecked = true
            m.deps = [BuildModel.Dep(id: "test", name: "Xcode", hint: "", present: true, installCmd: [])]
            m.fullRomfs = on
            let view = ContentView(model: m, library: GameLibrary(file: tmp.appendingPathComponent(name + ".json")), initialPage: .builds, performStartupChecks: false)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 1150), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
            window.orderOut(nil)
        }
        UserDefaults.standard.removeObject(forKey: key)
    }
}
