import XCTest
import SwiftUI
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher
import NXModel

/// Opt-in renders of the launcher in Light and in Dark at 1440 x 1024 for visual QA: Library, Builds (iPhone destination),
/// Settings General, a game's options sheet, the Supported games sheet and the console mode. The window's appearance picks the
/// scheme, the saved choice stays System. `NX_LAUNCHER_CAPTURE_DIR=<dir> swift test --filter LightAppearanceCaptureTests`.
@MainActor final class LightAppearanceCaptureTests: IsolatedDefaultsTestCase {
    private var temporary: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nx-light-capture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: temporary) }

    private func makeApp(_ id: String, name: String) throws -> URL {
        let app = temporary.appendingPathComponent(id + ".app")
        let executables = app.appendingPathComponent("Contents/MacOS")
        let dm = app.appendingPathComponent("Contents/Resources/dm")
        try FileManager.default.createDirectory(at: executables, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dm, withIntermediateDirectories: true)
        for exe in ["nxnative", "dmhost"] {
            try FileManager.default.createSymbolicLink(at: executables.appendingPathComponent(exe), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        }
        let info: [String: Any] = ["DMTitleID": id, "CFBundleDisplayName": name, "CFBundleExecutable": "nxnative", "CFBundleShortVersionString": "1.6.0",
                                   "CFBundleIdentifier": TestPreferences.domain(in: temporary, "light-" + id)]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        let fps = #"{"env": "DM_FPS_TARGET", "kind": "choice", "label": "Frame rate", "note": "", "default": "60", "section": "Game", "level": "basic", "options": [["30", "30"], ["60", "60"]]}"#
        let rumble = #"{"env": "DM_RUMBLE", "kind": "toggle", "label": "Rumble", "note": "", "default": "1", "section": "Game", "level": "basic"}"#
        let scale = #"{"env": "DM_RENDER_SCALE", "kind": "range", "label": "Render scale", "note": "", "default": "1.0", "section": "Game", "level": "basic", "min": 0.5, "max": 2.0, "step": 0.25}"#
        try #"{"game": "\#(id)", "settings": [\#(fps), \#(rumble), \#(scale)]}"#.write(to: dm.appendingPathComponent("launcher.json"), atomically: true, encoding: .utf8)
        return app
    }

    func testRenderLightAndDark() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else { throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture native views") }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)

        let library = GameLibrary(file: temporary.appendingPathComponent("library.json"))
        library.applicationFolders = []
        let hades = try library.addApp(makeApp("0100535012974000", name: "Hades"))
        // the two entries the screenshots showed: a raw title ID and a size in the kept name
        var oot = LibraryGame(titleID: "0400486024DEC000", name: "0400486024DEC000")
        oot.inputs["base"] = ["/Volumes/NX/games/The Legend of Zelda Ocarina of Time [NUP]/The Legend of Zelda Ocarina of Time [0400486024DEC000][v131072].nup"]
        library.upsert(oot)
        library.upsert(LibraryGame(titleID: "0100ACD0163D0000", name: "Batman Arkham Knight  (0.01 GB)"))
        library.selectedID = hades

        let stores = LauncherStores(defaults: testDefaults)
        stores.dependencies.checked = true
        stores.localizer.lang = CaptureLanguage.current(Lang("de"))
        let supported = Array(SupportedGames.list(engineRoot: EngineLayout.root(RepoLayout.find())).prefix(10))

        func shot<V: View>(_ name: String, _ view: V, light: Bool, size: NSSize = NSSize(width: 1440, height: 1024)) throws {
            let root = view.environmentObject(PadFocus()).environmentObject(stores.localizer).launcherDropdownHost()
                .frame(width: size.width, height: size.height).background(LauncherPalette.background)
            let host = NSHostingView(rootView: root)
            let window = OffscreenWindow(size: size, styleMask: [.titled, .closable, .resizable, .fullSizeContentView])
            window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
            window.contentView = host
            window.orderFront(nil)
            defer { window.orderOut(nil); window.contentView = nil; window.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("\(name)-\(light ? "light" : "dark").png"))
        }

        for light in [true, false] {
            try shot("library", LauncherView(stores: stores, library: library, initialPage: .library, performStartupChecks: false), light: light)
            // the narrowest window, and a controller's focus on the Library tab (the ring and the selected tile's underline)
            try shot("library-900", LauncherView(stores: stores, library: library, initialPage: .library, performStartupChecks: false), light: light,
                     size: NSSize(width: 900, height: 680))
            try shot("library-1100", LauncherView(stores: stores, library: library, initialPage: .library, performStartupChecks: false), light: light,
                     size: NSSize(width: 1100, height: 760))
            let pad = PadFocus()
            pad.show(default: nil)
            pad.focused = "tab.library"
            try shot("library-focus", LauncherView(stores: stores, library: library, initialPage: .library, performStartupChecks: false, padFocus: pad), light: light)
            stores.build.target = BuildTarget.ios
            try shot("builds-ios", LauncherView(stores: stores, library: library, initialPage: .builds, performStartupChecks: false), light: light)
            try shot("settings-general", LauncherView(stores: stores, library: library, initialPage: .settings, settingsCategory: .general, performStartupChecks: false), light: light)
            try shot("game-options", LaunchOptionsView(m: stores.build, library: library, gameID: hades), light: light, size: NSSize(width: 680, height: 720))
            try shot("supported-games", SupportedGamesSheet(games: supported, owned: { id in library.games.first { $0.titleID == id } }, covers: .saved(in: URL(fileURLWithPath: "/nonexistent"), maxPixel: SupportedGamesSheet.coverPixels), showInLibrary: { _ in }),
                     light: light, size: NSSize(width: 680, height: 720))
            try shot("console", ConsoleView(driver: MockConsoleDriver(scenario: .full), lang: Lang("de")), light: light)
        }
    }
}
