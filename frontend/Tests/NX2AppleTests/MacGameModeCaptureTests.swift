import AppKit
import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXModel
import NXLauncher

/// Visual QA for the per-game macOS Game Mode launch option across all 10 launcher languages (`NX_LAUNCHER_CAPTURE_DIR`):
/// renders both the desktop `LaunchOptionsView` sheet and Console mode's `ConsoleView` options page.
final class MacGameModeCaptureTests: IsolatedDefaultsTestCase {
    private let titleID = "01007EF00011E000"
    private let languages = #"[["en-US", "American English"], ["fr", "French"], ["de", "German"], ["ja", "Japanese"], ["zh-Hans", "Simplified Chinese"]]"#

    @MainActor func testCaptureMacGameModeAcrossLanguages() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else {
            throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture native views")
        }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-gamemode-cap-" + UUID().uuidString)
        let bundleID = TestPreferences.domain(in: temporary, "gamemode-capture")
        defer {
            CFPreferencesAppSynchronize(bundleID as CFString)
            try? FileManager.default.removeItem(at: temporary)
        }

        let app = temporary.appendingPathComponent("Game.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        let dm = app.appendingPathComponent("Contents/Resources/dm")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dm, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: macOS.appendingPathComponent("nxnative").path)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: macOS.appendingPathComponent("dmhost").path)

        let rows = [
            #"{"env": "DM_FPS_TARGET", "kind": "choice", "section": "Game", "label": "Frame rate", "note": "", "default": "60", "options": [["30", "30 fps"], ["60", "60 fps"]], "level": "basic"}"#,
            #"{"env": "DM_OPMODE", "kind": "choice", "section": "Game", "label": "Console mode", "note": "", "default": "1", "options": [["1", "Docked"], ["0", "Handheld"]], "level": "basic"}"#,
            #"{"env": "DM_LANG", "kind": "choice", "section": "Game", "label": "Game language", "note": "", "default": "en-US", "options": \#(languages), "level": "basic"}"#,
        ]
        try Data(#"{"schema": 1, "game": "\#(titleID)", "settings": [\#(rows.joined(separator: ","))]}"#.utf8)
            .write(to: dm.appendingPathComponent("launcher.json"))
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleName": "Sample Adventure",
            "CFBundleDisplayName": "Sample Adventure",
            "CFBundleExecutable": "nxnative",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0.0",
            "LSSupportsGameMode": false,
            "DMTitleID": titleID,
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))

        func capture(_ name: String, _ view: some View, width: CGFloat, height: CGFloat) throws {
            let host = NSHostingView(rootView: view.frame(width: width, height: height))
            let window = NSWindow(
                contentRect: NSRect(x: -10000, y: 0, width: width, height: height),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderBack(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.35))
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name))
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }

        var game = LibraryGame(titleID: titleID, name: "Sample Adventure")
        game.appPath = app.path
        if ProcessInfo.processInfo.environment["NX_CAPTURE_GAMEMODE_ON"] == "1" {
            game.launchOptions["MAC_GAME_MODE"] = "1"
        }
        struct Snapshot: Codable { let games: [LibraryGame]; let folder: String }
        let file = temporary.appendingPathComponent("library.json")
        try JSONEncoder().encode(Snapshot(games: [game], folder: temporary.path)).write(to: file)
        let library = GameLibrary(file: file)
        let modelStores = LauncherStores(defaults: testDefaults)
        let model = modelStores.build

        for lang in Lang.all {
            modelStores.localizer.lang = lang
            model.lang = lang
            let desktopView = LaunchOptionsView(m: model, library: library, gameID: library.games[0].id)
                .environmentObject(PadFocus())
                .environmentObject(modelStores.localizer)
                .environmentObject(modelStores.saveSettings)
                .environmentObject(modelStores.players)
            try capture("desktop-gamemode-\(lang.code).png", desktopView, width: LauncherSheet.width, height: 760)

            let settings = try XCTUnwrap(LaunchSetting.forMac(
                app: app.path,
                titleID: titleID,
                repo: "",
                labels: { L10n.string($0, lang) },
                preferred: ["en-US"]
            ))
            let store = SavedChoices(domain: bundleID)
            var values: [String: String] = [:]
            for s in settings {
                values[s.env] = s.storeBacked ? store.current(s) : library.games[0].launchValue(s)
            }
            let consoleGame = ConsoleGame(
                id: "game",
                title: "Sample Adventure",
                version: "1.0.0",
                platforms: [.mac],
                artwork: nil,
                status: .ready,
                settings: settings,
                values: values
            )
            var state = ConsoleState(
                games: [consoleGame],
                focusedGameID: "game",
                controllers: [.init(id: "pad.1", name: "Controller", player: 1)],
                time: Date(timeIntervalSince1970: 1_793_210_400)
            )
            state.isPreview = true
            let driver = MockConsoleDriver(state: state, lang: lang, animated: false)
            driver.openOptions("game")
            try capture(
                "console-gamemode-\(lang.code).png",
                ConsoleView(driver: driver, lang: lang).transaction { $0.disablesAnimations = true },
                width: 1280,
                height: 820
            )
        }
    }
}
