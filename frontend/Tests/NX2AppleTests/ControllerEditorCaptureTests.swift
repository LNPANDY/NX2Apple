import XCTest
import SwiftUI
@testable import NX2Apple
@testable import NXCore
import NXModel
@testable import NXLauncher

/// Opt-in native screenshots of the controller settings, with an isolated game preferences domain.
@MainActor final class ControllerEditorCaptureTests: IsolatedDefaultsTestCase {
    func testRenderControllerSettings() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"],
              let json = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_SETTINGS"] else {
            throw XCTSkip("Set capture output and launcher settings fixture")
        }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("controller-capture-" + UUID().uuidString)
        let app = temporary.appendingPathComponent("Hades.app")
        let dm = app.appendingPathComponent("Contents/Resources/dm")
        try FileManager.default.createDirectory(at: dm, withIntermediateDirectories: true)
        let domain = TestPreferences.domain(in: temporary, "controller-capture")
        let prefs = SystemControllerPreferences(domain: domain)
        defer {
            _ = prefs.synchronize()
            try? FileManager.default.removeItem(at: temporary)
        }
        let info: [String: Any] = ["CFBundleIdentifier": domain, "DMControllerMappings": 1, "DMTitleID": "0100535012974000"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: json), to: dm.appendingPathComponent("launcher.json"))
        var game = LibraryGame(titleID: "0100535012974000", name: "Hades", appPath: app.path)
        let libraryFile = temporary.appendingPathComponent("library.json")
        try JSONEncoder().encode([game]).write(to: libraryFile)
        let library = GameLibrary(file: libraryFile)
        game = library.games[0]
        let stores = LauncherStores(defaults: testDefaults)
        stores.localizer.lang = CaptureLanguage.current(.en)
        let layout = ControlLayout(defaults: testDefaults)
        layout.assign(ControlLayout.functions.first { $0.id == "RUp" }!, key: 34)
        layout.setSends("A", "B"); layout.setSends("B", "A")
        NSApplication.shared.setActivationPolicy(.accessory)
        func capture<V: View>(_ name: String, _ view: V) throws {
            let host = NSHostingView(rootView: view.environmentObject(PadFocus()).environmentObject(stores.localizer).launcherDropdownHost())
            let window = OffscreenWindow(size: NSSize(width: 600, height: 700))
            window.contentView = host
            window.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
            window.orderOut(nil)
        }
        try capture("controls", ControlsView(layout: layout))
        try capture("launch-options", LaunchOptionsView(m: stores.build, library: library, gameID: game.id, globalControls: layout))
        try capture("controller-mapping", GameControllerMappingView(game: game, globalControls: layout))
        prefs.write(ControllerPreferences.steamKey, value: ["buttons": ["16": 63, "23": 10], "pads": [2, 3], "gyro": false])
        _ = prefs.synchronize()
        try capture("controller-mapping-custom", GameControllerMappingView(game: game, globalControls: layout))
    }
}
