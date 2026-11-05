import XCTest
import Combine
@testable import NX2Apple
@testable import NXCore
@testable import NXModel

/// A real stand-in build stays alive while its window is replaced. No game or device is needed.
@MainActor final class BuildSessionTests: IsolatedDefaultsTestCase {
    func testRecreatedWindowKeepsTheRunningBuildItsLogAndStopControl() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("build-session-" + UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        func write(_ path: String, _ text: String = "") throws {
            let url = folder.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write(EngineLayout.marker)
        try write(RepoLayout.romfsImageTool)
        try write(RepoLayout.buildScript, """
        import json, pathlib, time
        # '--work-dir' is supported by this stand-in.
        print(json.dumps(dict(ev='stage', k=1, n=1, name='Shaders')), flush=True)
        print(json.dumps(dict(ev='progress', k=1, frac=0.25)), flush=True)
        print('compiling before the window closes', flush=True)
        while not pathlib.Path('continue').exists():
            time.sleep(0.01)
        print(json.dumps(dict(ev='progress', k=1, frac=0.5)), flush=True)
        print('compiling after the window reopens', flush=True)
        while True:
            time.sleep(1)
        """)
        try write("Game [0100000000001000].nsp")
        try write("prod.keys")
        let stores = LauncherStores(defaults: testDefaults)
        stores.repo.path = folder.path
        stores.dependencies.pythonPath = "/usr/bin/python3"
        stores.dependencies.dotnetPath = "/usr/bin/true"
        stores.dependencies.checked = true
        stores.dependencies.deps = [Dep(id: "test", name: "test", hint: "", present: true, installCmd: [])]
        stores.build.target = BuildTarget.mac
        stores.build.appReplaceCheck = { _ in true }
        stores.build.cloudFolderCheck = { _ in false }
        stores.build.slots[0].paths = [folder.appendingPathComponent("Game [0100000000001000].nsp").path]
        stores.build.slots[3].paths = [folder.appendingPathComponent("prod.keys").path]
        let session = LauncherSession(stores: stores, library: GameLibrary(file: folder.appendingPathComponent("library.json")))
        let console = ConsoleCoordinator()
        var window: RootView? = RootView(shared: session, console: console)
        let before = expectation(description: "output before closing the window")
        let beforeToken = stores.build.log.$text.filter { $0.contains("compiling before") }.prefix(1).sink { _ in before.fulfill() }
        window?.stores.build.startBuild()
        defer { stores.build.stop() }
        wait(for: [before], timeout: 10)
        withExtendedLifetime(beforeToken) {}
        let process = try XCTUnwrap(stores.build.proc)
        XCTAssertTrue(process.isRunning)

        window = nil
        window = RootView(shared: session, console: console)
        let reopened = try XCTUnwrap(window)
        XCTAssertTrue(reopened.stores.build.running)
        XCTAssertFalse(reopened.stores.build.canBuild, "the new window cannot start a duplicate build")
        XCTAssertEqual(reopened.stores.build.stages.first?.name, "Shaders")
        XCTAssertEqual(reopened.stores.build.stages.first?.percent, 25)
        XCTAssertTrue(reopened.stores.build.log.text.contains("compiling before"))
        let after = expectation(description: "new window receives later output")
        let afterToken = reopened.stores.build.log.$text.filter { $0.contains("compiling after") }.prefix(1).sink { _ in after.fulfill() }
        try write("continue")
        wait(for: [after], timeout: 10)
        withExtendedLifetime(afterToken) {}
        XCTAssertTrue(process.isRunning)
        XCTAssertEqual(reopened.stores.build.stages.first?.percent, 50)
        XCTAssertEqual(reopened.stores.build.proc?.processIdentifier, process.processIdentifier)
        let stopped = expectation(description: "stop from the new window ends the build")
        let stopToken = reopened.stores.build.$running.filter { !$0 }.prefix(1).sink { _ in stopped.fulfill() }
        reopened.stores.build.stop()
        wait(for: [stopped], timeout: 10)
        withExtendedLifetime(stopToken) {}
        XCTAssertFalse(process.isRunning)
        XCTAssertEqual(reopened.stores.build.doneNote, stores.localizer.t("msg.stopped"))
    }
}
