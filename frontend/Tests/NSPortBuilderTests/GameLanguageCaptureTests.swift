import AppKit
import SwiftUI
import XCTest
@testable import NSPortBuilder

/// The Game language row with its System language choice, on a French Mac, for visual QA (NX_LAUNCHER_CAPTURE_DIR): the desktop
/// Launch options sheet and the console mode's options.
final class GameLanguageCaptureTests: XCTestCase {
    private let titleID = "0100A3D008C5C000"
    private let languages = #"[["en-US", "American English"], ["en-GB", "British English"], ["fr", "French"], ["de", "German"], ["ja", "Japanese"]]"#

    @MainActor func testCaptureTheGameLanguageRow() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else { throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture native views") }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-language-" + UUID().uuidString)
        let bundleID = "org.nxnative.frontendtests.language." + temporary.lastPathComponent
        defer {
            for key in (CFPreferencesCopyKeyList(bundleID as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String]) ?? [] {
                CFPreferencesSetAppValue(key as CFString, nil, bundleID as CFString)
            }
            CFPreferencesAppSynchronize(bundleID as CFString)
            try? FileManager.default.removeItem(at: temporary)
        }
        let app = temporary.appendingPathComponent("Game.app")
        let dm = app.appendingPathComponent("Contents/Resources/dm")
        try FileManager.default.createDirectory(at: dm, withIntermediateDirectories: true)
        let rows = [
            #"{"env": "DM_FPS_TARGET", "kind": "choice", "section": "Game", "label": "Frame rate", "note": "", "default": "30", "options": [["30", "30 fps"], ["60", "60 fps"]], "level": "basic"}"#,
            #"{"env": "DM_LANG", "kind": "choice", "section": "Game", "label": "Game language", "note": "", "default": "en-US", "options": \#(languages), "level": "basic"}"#,
        ]
        try Data(#"{"schema": 1, "game": "\#(titleID)", "settings": [\#(rows.joined(separator: ","))]}"#.utf8).write(to: dm.appendingPathComponent("launcher.json"))
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": bundleID, "DMTitleID": titleID], format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let french = ["fr-FR", "en-US"]
        let settings = try XCTUnwrap(LaunchSetting.forMac(app: app.path, titleID: titleID, repo: "", labels: { L10n.string($0, .en) }, preferred: french))
        let store = SavedChoices(domain: bundleID)
        store.followSystemLanguage(try XCTUnwrap(LaunchSetting.read(app: app.path)), preferred: french)

        func capture(_ name: String, _ view: some View, width: CGFloat, height: CGFloat) throws {
            let host = NSHostingView(rootView: view.frame(width: width, height: height))
            let window = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderBack(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name))
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }

        // The desktop sheet: the row shows the default, System language (French)
        var game = LibraryGame(titleID: titleID, name: "[Game]")
        game.appPath = app.path
        struct Snapshot: Codable { let games: [LibraryGame]; let folder: String }
        let file = temporary.appendingPathComponent("library.json")
        try JSONEncoder().encode(Snapshot(games: [game], folder: temporary.path)).write(to: file)
        let library = GameLibrary(file: file)
        let model = BuildModel()
        model.lang = .en
        try capture("game-language-launch-options.png",
                    LaunchOptionsView(m: model, library: library, gameID: library.games[0].id).environmentObject(PadFocus()),
                    width: 760, height: 520)

        // Console mode: the same row in the game's options
        let row = try XCTUnwrap(settings.first { $0.env == "DM_LANG" })
        XCTAssertEqual(store.current(row), "system")
        var values: [String: String] = [:]
        for s in settings { values[s.env] = s.storeBacked ? store.current(s) : s.def }
        let consoleGame = ConsoleGame(id: "game", title: "[Game]", version: "1.0.0", platforms: [.mac], artwork: nil, status: .ready,
                                      settings: settings, values: values)
        var state = ConsoleState(games: [consoleGame], focusedGameID: "game", controllers: [.init(id: "pad.1", name: "Controller", player: 1)],
                                 time: Date(timeIntervalSince1970: 1_793_210_400))
        state.isPreview = true
        let driver = MockConsoleDriver(state: state, lang: .en, animated: false)
        driver.openOptions("game")
        try capture("game-language-console.png", ConsoleView(driver: driver, lang: .en).transaction { $0.disablesAnimations = true },
                    width: 1280, height: 800)
    }
}
