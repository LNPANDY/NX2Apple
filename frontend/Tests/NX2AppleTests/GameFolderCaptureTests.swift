import AppKit
import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXModel

/// The Builds page with a Switch 2 game folder chosen (LNPANDY/NX2Apple#512, #445). A synthetic folder and a stand-in engine: an
/// NPDM with only the program ID, empty RomFS folders, a profile with only its name. No game data.
final class GameFolderCaptureTests: IsolatedDefaultsTestCase {
    /// A stand-in engine tree (the marker file, pack_dump.py, Donkey Kong Bananza's profile) and the game's folder beside it.
    static func makeFolders(in root: String, profile: Bool = true, packer: Bool = true) -> (engine: String, game: String) {
        let fm = FileManager.default
        func write(_ path: String, _ data: Data = Data([1])) {
            try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            fm.createFile(atPath: path, contents: data)
        }
        let engine = root + "/engine", game = root + "/Donkey Kong Bananza"
        write(engine + "/" + EngineLayout.marker)
        if packer { write(engine + "/scripts/pack_dump.py") }
        if profile {
            write(engine + "/dm/games/040074A01BF12000/game.tsv",
                  Data("# Donkey Kong Bananza (Switch 2, update v458752). In bring-up\ntitle_id\t040074A01BF12000\nname\tDonkey Kong Bananza\n".utf8))
        }
        write(game + "/base/exefs/main.npdm", npdm(programID: 0x040074A01BF12000))
        write(game + "/base/exefs/main")
        for dir in ["/base/romfs", "/updates/458752/exefs", "/updates/458752/romfs", "/dlc/040074a01bf13001/0/romfs"] {
            try? fm.createDirectory(atPath: game + dir, withIntermediateDirectories: true)
        }
        return (engine, game)
    }

    /// A minimal main.npdm, as GameFolderTests (NXCoreTests) makes it.
    static func npdm(programID: UInt64) -> Data {
        var d = [UInt8](repeating: 0, count: 0x100)
        d.replaceSubrange(0..<4, with: Array("META".utf8))
        let off = 0x80, size = 0x40
        for i in 0..<4 { d[0x70 + i] = UInt8(off >> (8 * i) & 0xFF); d[0x74 + i] = UInt8(size >> (8 * i) & 0xFF) }
        d.replaceSubrange(off..<off + 4, with: Array("ACI0".utf8))
        for i in 0..<8 { d[off + 0x10 + i] = UInt8(programID >> (8 * UInt64(i)) & 0xFF) }
        return Data(d)
    }

    // MARK: Visual QA (matched by --filter testRenderLauncherForVisualQA)

    @MainActor func testRenderLauncherForVisualQAGameFolder() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else { throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture native views") }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let root = NSTemporaryDirectory() + "gamefolder-capture-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: root) }
        let folders = Self.makeFolders(in: root)
        NSApplication.shared.setActivationPolicy(.accessory)
        let stores = LauncherStores(defaults: testDefaults); let model = stores.build
        stores.repo.path = folders.engine
        model.lang = CaptureLanguage.current(.en)
        model.outDir = root
        MainActor.assumeIsolated { stores.dependencies.checked = true }
        MainActor.assumeIsolated { stores.dependencies.deps = [Dep(id: "test", name: "Xcode", hint: "", present: true, installCmd: [])] }
        let library = GameLibrary(file: URL(fileURLWithPath: root + "/preview.json"))
        func capture(_ name: String, target: String) throws {
            model.target = target
            model.scan(folder: folders.game)
            let host = NSHostingView(rootView: LauncherView(stores: stores, library: library, initialPage: .builds, performStartupChecks: false))
            let window = OffscreenWindow(size: NSSize(width: 1440, height: 1024), styleMask: [.titled, .closable, .resizable])
            window.contentView = host
            window.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
            window.orderOut(nil)
        }
        try capture("build-game-folder-mac", target: BuildTarget.mac)
        try capture("build-game-folder-ios", target: BuildTarget.ios)
    }
}
