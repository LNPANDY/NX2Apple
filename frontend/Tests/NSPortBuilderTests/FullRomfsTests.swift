import XCTest
import SwiftUI
import AppKit
@testable import NSPortBuilder

/// "Game files inside the IPA": the option adds the script's DM_FULL_ROMFS=1 (the script has no flag for it), is off by
/// default, and only an iPhone or iPad build takes it.
final class FullRomfsTests: XCTestCase {
    private let key = "fullRomfsInIPA"

    override func setUp() { UserDefaults.standard.removeObject(forKey: key) }
    override func tearDown() { UserDefaults.standard.removeObject(forKey: key) }

    @MainActor func testTheOptionIsOffByDefaultAndAddsNothing() {
        let m = BuildModel()
        XCTAssertFalse(m.fullRomfs)
        XCTAssertEqual(BuildModel.gameFilesEnvironment(fullRomfs: m.fullRomfs, target: "ios"), [:])
    }

    @MainActor func testTheOptionPacksTheGameFilesForAnIPAOnly() {
        XCTAssertEqual(BuildModel.gameFilesEnvironment(fullRomfs: true, target: "ios"), ["DM_FULL_ROMFS": "1"])
        XCTAssertEqual(BuildModel.gameFilesEnvironment(fullRomfs: true, target: "mac-app"), [:])
    }

    @MainActor func testTheChoiceIsRemembered() {
        let m = BuildModel()
        m.fullRomfs = true
        XCTAssertTrue(BuildModel().fullRomfs)
    }

    func testAReSignOfAnAppWithItsGameFilesDoesNotStripThem() {
        func command(_ keeps: Bool) -> [String] {
            BuildModel.resignCommand(xcrun: "/x", project: "/p", scheme: "S", device: "D", derived: "/d", team: "T", bundle: "b", keepsGameFiles: keeps)
        }
        XCTAssertTrue(command(false).contains("DM_COPY_ROMFS=NO"))
        XCTAssertFalse(command(true).contains("DM_COPY_ROMFS=NO"))
    }

    func testTheNewStringsHaveEveryLanguage() {
        for key in ["opt.fullRomfs", "opt.fullRomfs.note", "msg.doneFull", "install.step2full"] {
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
