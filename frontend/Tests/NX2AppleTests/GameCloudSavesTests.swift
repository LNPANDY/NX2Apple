import AppKit
import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher

/// #499: the Mac launcher shows and sets a game's cloud saves folder where dm/mac/launcher.c reads it, and reads the last
/// session's sync from the game's log.
final class GameCloudSavesTests: IsolatedDefaultsTestCase {
    private var root: URL!
    private let titleID = "0100535012974000"
    private var preference: String?

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-cloud-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        preference = nil
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func write(_ text: String, _ relative: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    private func read(_ relative: String) -> String? { try? String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8) }

    /// The game's app in a library folder, ~/Library and the preference standing in, nothing of the real ones touched.
    private func saves() -> GameCloudSaves {
        var s = GameCloudSaves(titleID: titleID, appPath: root.path + "/lib/Hades.app")
        s.home = root.path + "/home"
        s.support = root.appendingPathComponent("support")
        s.readPreference = { [unowned self] in preference }
        s.writePreference = { [unowned self] in preference = $0 }
        return s
    }
    private var env: String { "support/nxnative/\(titleID)/env.txt" }

    func testWithoutAnyLineThePreferenceIsWhatChanges() throws {
        let s = saves()
        XCTAssertFalse(s.setting.isOn)
        try s.choose("/Cloud/Saves")
        XCTAssertEqual(preference, "/Cloud/Saves")
        XCTAssertNil(read(env), "no env.txt is made for it")
        XCTAssertEqual(s.setting, .init(source: .preference, value: "/Cloud/Saves", folder: "/Cloud/Saves"))
        try s.turnOff()
        XCTAssertNil(preference)
        XCTAssertFalse(s.setting.isOn)
    }

    /// #490: an env.txt line from an older version wins over the preference, so the change goes into that line.
    func testAnOldEnvLineIsChangedWhereItIs() throws {
        try write("# my settings\nDM_SAVE_SYNC=icloud\nDM_FPS_TARGET=60\n", env)
        let s = saves()
        XCTAssertEqual(s.setting.source, .playerEnv)
        XCTAssertEqual(s.setting.folder, root.path + "/home/Library/Mobile Documents/com~apple~CloudDocs/nxnative Saves")
        try s.choose("/Cloud/Shared")
        XCTAssertEqual(read(env), "# my settings\nDM_SAVE_SYNC=/Cloud/Shared\nDM_FPS_TARGET=60\n")
        XCTAssertEqual(s.setting.folder, "/Cloud/Shared")
        try s.turnOff()
        XCTAssertEqual(read(env), "# my settings\nDM_SAVE_SYNC=0\nDM_FPS_TARGET=60\n")
        XCTAssertFalse(s.setting.isOn)
    }

    /// The app's own env.txt is inside the signed app: a change goes into the player's env.txt, which wins over it.
    func testTheAppsEnvLineIsOverriddenNotEdited() throws {
        try write("DM_SAVE_SYNC=icloud\n", "lib/Hades.app/Contents/Resources/dm/env.txt")
        try write("DM_FPS_TARGET=30", env)
        let s = saves()
        XCTAssertEqual(s.setting.source, .appEnv)
        try s.turnOff()
        XCTAssertEqual(read(env), "DM_FPS_TARGET=30\nDM_SAVE_SYNC=0\n")
        XCTAssertEqual(read("lib/Hades.app/Contents/Resources/dm/env.txt"), "DM_SAVE_SYNC=icloud\n")
        XCTAssertFalse(s.setting.isOn)
    }

    func testTheLastSessionComesFromTheNewestLog() throws {
        try write("", "lib/.nx2apple-library")
        try write("[dm] save sync: on: /c\n[dm] save sync: in step with the cloud\n", "lib/log/\(titleID).prev.log")
        let s = saves()
        XCTAssertEqual(s.lastSession()?.state, .inStep)
        try write("[dm] save sync: on: /c\n[dm] [RED] save sync: sending to /c failed (errno=1)\n", "lib/log/\(titleID).log")
        XCTAssertEqual(s.lastSession()?.state, .failed("sending to /c failed (errno=1)"))
        XCTAssertNotNil(s.lastSession()?.date)
    }

    func testNoLogMeansNotPlayed() {
        XCTAssertNil(saves().lastSession())
    }

    func testTheFolderIsShownByItsNameInICloudDrive() {
        let drive = "/Users/jo/Library/Mobile Documents/com~apple~CloudDocs"
        XCTAssertEqual(CloudSavesCard.shown(drive + "/nxnative Saves", home: "/Users/jo"), "iCloud Drive › nxnative Saves")
        XCTAssertEqual(CloudSavesCard.shown(drive + "/Games/Saves", home: "/Users/jo"), "iCloud Drive › Games › Saves")
        XCTAssertEqual(CloudSavesCard.name(drive + "/nxnative Saves"), "nxnative Saves")
    }

    /// The Cloud saves section for visual QA (`NX_LAUNCHER_CAPTURE_DIR`, `NX_CAPTURE_LANG`): off, on with a save in the folder and
    /// the last session sent, a folder without the game's save (#490), and an env.txt line with a failed sync.
    @MainActor func testRenderCloudSavesForVisualQA() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else { throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture native views") }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        let localizer = LauncherStores(defaults: testDefaults).localizer
        localizer.lang = CaptureLanguage.current(.en)
        let game = LibraryGame(titleID: titleID, name: "Hades")
        let drive = "/Users/jo/Library/Mobile Documents/com~apple~CloudDocs"
        let date = Date(timeIntervalSinceNow: -3600)
        let cases: [(String, String?, String?, CloudSaveSync.FolderCheck?, (state: CloudSaveSync.LogState?, date: Date?)?)] = [
            ("cloud-off", nil, nil, nil, (nil, date)),
            ("cloud-sent", drive + "/nxnative Saves", nil, .hasSave(date), (.sent("3 files"), date)),
            ("cloud-no-save", drive + "/NX2Apple Saves", nil, .noSave, (.inStep, date)),
            ("cloud-env-failed", nil, "DM_SAVE_SYNC=" + drive + "/Old Saves\n", .missing, (.failed("sending to \(drive)/Old Saves/\(titleID)/save.dmsync failed (errno=13)"), date)),
        ]
        for (name, pref, envText, check, last) in cases {
            if let envText { try write(envText, env) } else { try? FileManager.default.removeItem(at: root.appendingPathComponent(env)) }
            preference = pref
            let card = CloudSavesCard(game: game, saves: saves(), preview: (check, last), home: "/Users/jo")
                .environmentObject(localizer).environmentObject(PadFocus()).padding(30).frame(width: 600).background(LauncherPalette.background)
                .font(.manrope(13)).preferredColorScheme(.dark)
            let host = NSHostingView(rootView: card)
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            let window = OffscreenWindow(size: host.frame.size)
            window.contentView = host
            window.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("\(name)-\(localizer.lang.code).png"))
            window.orderOut(nil)
        }
    }
}
