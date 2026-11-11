import Foundation
import XCTest
@testable import NX2Apple
@testable import NXCore

final class MacGameModeOptionsTests: IsolatedDefaultsTestCase {
    private var temporary: URL!
    private let titleID = "01007EF00011E000"

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-gamemode-opt-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        MacGameMode.shared.flushForTesting()
        try? FileManager.default.removeItem(at: temporary)
        try super.tearDownWithError()
    }

    private func makePlayableMacApp() throws -> URL {
        let app = temporary.appendingPathComponent("Adventure.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        let dm = app.appendingPathComponent("Contents/Resources/dm")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dm, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: macOS.appendingPathComponent("nxnative").path)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: macOS.appendingPathComponent("dmhost").path)
        let launcherJSON = #"{"schema": 1, "game": "\#(titleID)", "settings": [{"env": "DM_OPMODE", "kind": "choice", "section": "Game", "label": "Console mode", "note": "", "default": "1", "level": "basic", "options": [["1", "Docked"], ["0", "Handheld"]]}]}"#
        try Data(launcherJSON.utf8).write(to: dm.appendingPathComponent("launcher.json"))
        let info: [String: Any] = [
            "CFBundleIdentifier": TestPreferences.domain(in: temporary, "adventure"),
            "CFBundleName": "Adventure",
            "CFBundleDisplayName": "Adventure",
            "CFBundleExecutable": "nxnative",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0.0",
            "LSSupportsGameMode": false,
            "DMTitleID": titleID,
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"), options: .atomic)
        let runner = SystemProcessRunner()
        XCTAssertTrue(runner.capture(ProcessLaunch(
            executable: "/usr/bin/codesign",
            arguments: ["--force", "--sign", "-", macOS.appendingPathComponent("dmhost").path],
            mergesErrors: true
        )).ok)
        XCTAssertTrue(runner.capture(ProcessLaunch(
            executable: "/usr/bin/codesign",
            arguments: ["--force", "--sign", "-", app.path],
            mergesErrors: true
        )).ok)
        return app
    }

    @MainActor func testPlayableMacAppOffersGameModeToggleUpdatesPlistWithoutPollutingEnvironmentAndResetsCleanly() throws {
        let app = try makePlayableMacApp()
        for lang in Lang.all {
            let list = try XCTUnwrap(LaunchSetting.forMac(app: app.path, titleID: titleID, repo: "", labels: { L10n.string($0, lang) }))
            let row = try XCTUnwrap(list.first { $0.env == MacGameMode.optionEnv }, "missing MAC_GAME_MODE in \(lang.code)")
            XCTAssertEqual(LaunchCategory.of(row), .game)
            XCTAssertTrue(row.isBasic)
            XCTAssertFalse(row.storeBacked)
            XCTAssertFalse(row.label.isEmpty)
            XCTAssertFalse(row.note.isEmpty)
            XCTAssertFalse(row.label.contains(";"))
            XCTAssertFalse(row.note.contains(";"))
            XCTAssertFalse(row.note.contains("；"))
        }

        let settings = try XCTUnwrap(LaunchSetting.forMac(app: app.path, titleID: titleID, repo: "", labels: { L10n.string($0, .en) }))
        let fullscreenIdx = try XCTUnwrap(settings.firstIndex { $0.env == "DM_FULLSCREEN" })
        let gameModeIdx = try XCTUnwrap(settings.firstIndex { $0.env == MacGameMode.optionEnv })
        XCTAssertEqual(gameModeIdx, fullscreenIdx + 1, "macOS Game Mode sits right below Display mode")
        let row = settings[gameModeIdx]

        let libraryFile = temporary.appendingPathComponent("library.json")
        let library = GameLibrary(file: libraryFile)
        let gameID = try library.addApp(app)

        XCTAssertEqual(library.games[0].launchValue(row), "0")
        library.setLaunchOption(row, "1", for: gameID)
        XCTAssertEqual(library.games[0].launchValue(row), "1")
        XCTAssertNil(library.games[0].launchEnvironment(settings)[MacGameMode.optionEnv], "MAC_GAME_MODE is an Info.plist setting, never a child env var")

        let startEnv = GameStart.environment(
            for: library.games[0],
            library: library,
            controls: ControlLayout(defaults: testDefaults),
            repo: "",
            labels: { L10n.string($0, .en) }
        )
        XCTAssertNil(startEnv[MacGameMode.optionEnv], "GameStart.environment must not leak MAC_GAME_MODE to the game process")

        MacGameMode.shared.flushForTesting()
        XCTAssertTrue(MacGameMode.isEnabled(inApp: app.path))
        let verifyOn = SystemProcessRunner().capture(ProcessLaunch(
            executable: "/usr/bin/codesign",
            arguments: ["--verify", "--deep", "--strict", app.path],
            mergesErrors: true
        ))
        XCTAssertTrue(verifyOn.ok)

        // Reset ("Use tested values" / Console "Reset to defaults") restores LSSupportsGameMode = false and re-signs.
        library.resetLaunchOptions(for: gameID)
        XCTAssertEqual(library.games[0].launchValue(row), "0")
        MacGameMode.shared.flushForTesting()
        XCTAssertFalse(MacGameMode.isEnabled(inApp: app.path))
        let verifyOff = SystemProcessRunner().capture(ProcessLaunch(
            executable: "/usr/bin/codesign",
            arguments: ["--verify", "--deep", "--strict", app.path],
            mergesErrors: true
        ))
        XCTAssertTrue(verifyOff.ok)
    }
}
