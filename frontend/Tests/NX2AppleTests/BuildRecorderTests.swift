import XCTest
@testable import NX2Apple
@testable import NXCore
import NXModel

/// A build that ends while console mode is up (no LauncherView) is still written into the library: BuildRecorder lives in the session.
@MainActor final class BuildRecorderTests: IsolatedDefaultsTestCase {
    private var temporary: URL!
    private let titleID = "0100535012974000"

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        CFPreferencesAppSynchronize(TestPreferences.domain(in: temporary, "recorder") as CFString)
        try FileManager.default.removeItem(at: temporary)
    }

    private func makeApp(name: String) throws -> URL {
        let app = temporary.appendingPathComponent("out/" + name + ".app")
        let executables = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: executables, withIntermediateDirectories: true)
        for name in ["nxnative", "dmhost"] {
            try FileManager.default.createSymbolicLink(at: executables.appendingPathComponent(name), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        }
        let info: [String: Any] = ["DMTitleID": titleID, "CFBundleDisplayName": name, "CFBundleExecutable": "nxnative",
                                   "CFBundleIdentifier": TestPreferences.domain(in: temporary, "recorder")]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app
    }

    /// Lets the main queue run what the recorder queued (it records after the store's change, as LauncherView did).
    private func drainMainQueue() {
        let drained = expectation(description: "main queue")
        DispatchQueue.main.async { DispatchQueue.main.async { drained.fulfill() } }
        wait(for: [drained], timeout: 5)
    }

    func testBuildThatEndsWithoutTheLauncherViewIsRecorded() throws {
        let stores = LauncherStores(defaults: testDefaults)
        stores.repo.path = temporary.path
        let file = temporary.appendingPathComponent("library.json")
        let other = LibraryGame(titleID: "01007EF00011E000", name: "Other")
        try JSONEncoder().encode([other]).write(to: file)
        let library = GameLibrary(file: file)
        library.selectedID = other.id
        let recorder = BuildRecorder(stores: stores, library: library)   // the session's: no LauncherView is up
        let m = stores.build
        let base = temporary.appendingPathComponent("Hades [\(titleID)][v0].nsp").path
        let slot = try XCTUnwrap(m.slots.firstIndex { $0.id == "base" })
        m.slots[slot].paths = [base]
        try FileManager.default.createDirectory(at: temporary.appendingPathComponent("out"), withIntermediateDirectories: true)
        m.outDir = temporary.appendingPathComponent("out").path
        m.target = BuildTarget.mac

        m.running = true
        let id = try XCTUnwrap(recorder.activeBuildID, "the build's game goes into the library as it starts")
        XCTAssertEqual(library.games.first { $0.id == id }?.titleID, titleID)
        XCTAssertFalse(library.games.first { $0.id == id }?.isReady ?? true)

        let app = try makeApp(name: "Hades")
        m.macAppPath = app.path
        m.done = true
        m.running = false
        drainMainQueue()

        let game = try XCTUnwrap(library.games.first { $0.id == id })
        XCTAssertEqual(game.appPath, app.path)
        XCTAssertTrue(game.isReady)
        XCTAssertEqual(library.selectedID, id, "the built game is the selected one")
        XCTAssertNil(recorder.activeBuildID, "the build is recorded and over")
        XCTAssertEqual(GameLibrary(file: file).games.first { $0.id == id }?.appPath, app.path, "library.json holds it")
    }

    func testStandaloneIOSActionsKeepMacTargetOutOfBuildingStateAndBuildStepsRestoreBuildingGame() throws {
        final class InstantRunner: ProcessRunner {
            var captureHandler: (ProcessLaunch) -> ProcessResult = { _ in ProcessResult(status: 0, out: "") }
            func capture(_ launch: ProcessLaunch) -> ProcessResult { captureHandler(launch) }
            func stream(_ launch: ProcessLaunch, line: @escaping (String) -> Void) -> Bool { true }
            func streamLines(_ launch: ProcessLaunch, started: @escaping (RunningProcess) -> Void, line: @escaping (String) -> Void) -> ProcessResult {
                ProcessResult(status: 0, out: "")
            }
            func start(_ launch: ProcessLaunch, onOutput: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) throws -> RunningProcess {
                DispatchQueue.global(qos: .userInitiated).async { onExit(0) }
                return Process()
            }
        }

        let fm = FileManager.default
        let runner = InstantRunner()
        let stores = LauncherStores(runner: runner, defaults: testDefaults)
        stores.repo.path = temporary.path
        let file = temporary.appendingPathComponent("library-standalone.json")
        let installedIOS = LibraryGame(titleID: "01007EF00011E000", name: "Installed iOS",
                                       iosAppPath: temporary.appendingPathComponent("DmShell.app").path,
                                       installedDevice: "DEVICE-1")
        try JSONEncoder().encode([installedIOS]).write(to: file)
        let library = GameLibrary(file: file)
        library.selectedID = installedIOS.id
        let recorder = BuildRecorder(stores: stores, library: library)
        var recordedEvents = 0
        let recordedToken = recorder.recorded.sink { recordedEvents += 1 }
        defer { withExtendedLifetime(recordedToken) {} }

        let m = stores.build
        m.home = temporary.appendingPathComponent("home").path
        m.outDir = temporary.appendingPathComponent("out").path
        try fm.createDirectory(atPath: m.outDir, withIntermediateDirectories: true)
        // The Build form sits on mac with a different game selected in its base slot.
        let unbuiltMac = temporary.appendingPathComponent("Hades [\(titleID)][v0].nsp").path
        let slot = try XCTUnwrap(m.slots.firstIndex { $0.id == "base" })
        m.slots[slot].paths = [unbuiltMac]
        m.target = BuildTarget.mac
        XCTAssertEqual(m.runningTarget, BuildTarget.mac)

        let appDir = temporary.appendingPathComponent("shell/derived-data/Build/Products/Release-iphoneos/DmShell.app")
        let projDir = temporary.appendingPathComponent("shell/project/DmShell.xcodeproj")
        try fm.createDirectory(at: appDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: projDir, withIntermediateDirectories: true)
        var shellLib = ShellLibrary()
        let fwDir = temporary.appendingPathComponent("shell/frameworks/DmGame01007EF00011E000.framework")
        try fm.createDirectory(at: fwDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: fwDir.appendingPathComponent("game.manifest.json"))
        try Data("bin".utf8).write(to: fwDir.appendingPathComponent("DmGame01007EF00011E000"))
        shellLib.add(.init(titleID: "01007EF00011E000", name: "Installed iOS", framework: fwDir.path))
        try shellLib.save(root: temporary.appendingPathComponent("shell").path)
        try "01007EF00011E000\t\(fwDir.path)\tInstalled iOS\n".write(
            to: temporary.appendingPathComponent("shell/project/frameworks.txt"), atomically: true, encoding: .utf8
        )

        m.installedOn = "DEVICE-1"
        m.installedAppPath = appDir.path
        stores.deviceStore.installDevice = "DEVICE-1"
        stores.deviceStore.signingTeam = "TEAM123456"

        func assertStandaloneAction(_ name: String, trigger: () -> Void) {
            var sawRunningIOS = false
            var sawBuildingGameFalse = false
            let sub = m.$running.filter { $0 }.prefix(1).sink { _ in
                sawRunningIOS = (m.runningTarget == BuildTarget.ios)
                sawBuildingGameFalse = !m.buildingGame
                XCTAssertNil(recorder.activeBuildID, "\(name) must not mark the Build form's mac game as BUILDING in the library")
            }
            let finished = expectation(description: name)
            let endSub = m.$running.dropFirst().filter { !$0 }.prefix(1).sink { _ in finished.fulfill() }
            trigger()
            wait(for: [finished], timeout: 10)
            withExtendedLifetime(sub) {}
            withExtendedLifetime(endSub) {}
            drainMainQueue()
            XCTAssertTrue(sawRunningIOS, "\(name) must set runningTarget to ios while running")
            XCTAssertTrue(sawBuildingGameFalse, "\(name) must set buildingGame to false while running")
            XCTAssertFalse(m.running)
            XCTAssertEqual(m.target, BuildTarget.mac, "\(name) must not mutate the Build form's target picker")
            XCTAssertEqual(m.runningTarget, BuildTarget.mac, "\(name) must restore runningTarget to mac after finishing so OutcomeCard and recordBuild read mac")
            XCTAssertNil(recorder.activeBuildID)
            XCTAssertEqual(recordedEvents, 0, "\(name) must not record a build into the library")
            XCTAssertNil(library.games.first { $0.titleID == self.titleID }, "\(name) must not insert the Build form's game into the library")
        }

        // 1. reinstallOnDevice while picker sits on mac
        assertStandaloneAction("reinstallOnDevice") {
            m.reinstallOnDevice()
        }
        XCTAssertFalse(m.done, "reinstallOnDevice does not set done = true on the build store")
        XCTAssertEqual(m.runningTarget, BuildTarget.mac, "OutcomeCard reads runningTarget == mac when idle after a standalone action")

        // 2. resignOnDevice
        assertStandaloneAction("resignOnDevice") {
            m.resignOnDevice(app: appDir.path, device: "DEVICE-1")
        }

        // 3. saveIPA
        let ipaURL = temporary.appendingPathComponent("out/Saved.ipa")
        assertStandaloneAction("saveIPA") {
            m.saveIPA(to: ipaURL)
        }

        // 4. sendGameData
        let archiveDir = temporary.appendingPathComponent("out/games/01007EF00011E000")
        try fm.createDirectory(at: archiveDir, withIntermediateDirectories: true)
        try Data("romfs".utf8).write(to: archiveDir.appendingPathComponent("romfs.img"))
        m.archivePath = archiveDir.path
        m.exportedIPAPath = ipaURL.path
        try Data("ipa".utf8).write(to: ipaURL)
        assertStandaloneAction("sendGameData") {
            m.sendGameData(bundle: "org.nxnative.shell")
        }

        // 5. copyToDrive
        let driveDir = temporary.appendingPathComponent("drive")
        try fm.createDirectory(at: driveDir, withIntermediateDirectories: true)
        stores.deviceStore.driveFolder = driveDir.path
        m.refreshDrive()
        assertStandaloneAction("copyToDrive") {
            m.copyToDrive()
        }

        // 6. confirmShellMove
        let moveDest = temporary.appendingPathComponent("moved-shell")
        try fm.createDirectory(at: moveDest, withIntermediateDirectories: true)
        m.prepareShellMove(into: moveDest.path)
        assertStandaloneAction("confirmShellMove") {
            _ = m.confirmShellMove()
        }

        // 7. Build pipeline steps (packArchive, exportShell, installShell) reset buildingGame back to true after a standalone action.
        let workDir = temporary.appendingPathComponent("work")
        let extractV0 = workDir.appendingPathComponent("extract/v0")
        try fm.createDirectory(at: extractV0, withIntermediateDirectories: true)
        try Data("image".utf8).write(to: extractV0.appendingPathComponent("RomFS.img"))
        m.buildingGame = false
        var packed = ""
        let archiveEnded = expectation(description: "packArchive")
        m.packArchive(workDir: workDir.path, titleID: titleID) {
            packed = $0
            archiveEnded.fulfill()
        }
        XCTAssertTrue(m.buildingGame, "packArchive must reset buildingGame to true")
        XCTAssertEqual(m.runningTarget, BuildTarget.ios)
        wait(for: [archiveEnded], timeout: 5)
        XCTAssertFalse(packed.isEmpty)
        m.running = false
        drainMainQueue()

        m.buildingGame = false
        let exportEnded = expectation(description: "exportShell")
        let exportSub = m.$running.dropFirst().filter { !$0 }.prefix(1).sink { _ in exportEnded.fulfill() }
        m.exportShell(framework: fwDir.path, titleID: titleID, name: "Hades")
        XCTAssertTrue(m.buildingGame, "exportShell must reset buildingGame to true")
        wait(for: [exportEnded], timeout: 10)
        withExtendedLifetime(exportSub) {}
        drainMainQueue()

        m.buildingGame = false
        let installEnded = expectation(description: "installShell")
        let installSub = m.$running.dropFirst().filter { !$0 }.prefix(1).sink { _ in installEnded.fulfill() }
        m.installShell(framework: fwDir.path, titleID: titleID, name: "Hades", archive: archiveDir.path, dataOnly: true)
        XCTAssertTrue(m.buildingGame, "installShell must reset buildingGame to true")
        wait(for: [installEnded], timeout: 10)
        withExtendedLifetime(installSub) {}
        drainMainQueue()
    }
}
