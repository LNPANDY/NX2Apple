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
}
