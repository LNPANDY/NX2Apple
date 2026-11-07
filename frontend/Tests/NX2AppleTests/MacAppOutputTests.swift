import XCTest
import SwiftUI
@testable import NX2Apple
import NXCore
import NXModel
import NXLauncher

@MainActor final class MacAppOutputTests: IsolatedDefaultsTestCase {
    private let titleID = "0100000000010000"

    // Both launch paths run this stand-in packer. Its metadata deliberately differs from the input filename.
    private let packer = """
    #!/usr/bin/python3
    import pathlib, plistlib, sys
    if sys.argv[1:] == ['version']:
        print('nxb 0.6.3')
        sys.exit()
    work = pathlib.Path(sys.argv[sys.argv.index('--work-dir') + 1])
    work.mkdir(parents=True, exist_ok=True)
    app = pathlib.Path(sys.argv[sys.argv.index('-o') + 1])
    macos = app / 'Contents/MacOS'
    macos.mkdir(parents=True, exist_ok=True)
    for name in ['game', 'dmhost']:
        (macos / name).touch(mode=0o755)
    info = dict(DMTitleID='0100000000010000', CFBundleName='雪: The / Journey', CFBundleExecutable='game')
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    """

    private func buildFixture(at root: URL) throws -> LauncherStores {
        let fm = FileManager.default
        let stores = LauncherStores(localizer: Localizer(.en), defaults: testDefaults)
        let build = stores.build
        for path in RepoLayout.requiredTools + [EngineLayout.marker, "nxb"] {
            let file = root.appendingPathComponent(path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try packer.write(to: file, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        stores.repo.path = root.path
        stores.dependencies.pythonPath = "/usr/bin/python3"
        build.cloudFolderCheck = { _ in false }
        build.target = BuildTarget.mac
        stores.dependencies.checked = true
        let base = root.appendingPathComponent("Dump [\(titleID)].nsp")
        let keys = root.appendingPathComponent("test.keys")
        try Data().write(to: base)
        try Data().write(to: keys)
        build.take(picked: [base.path], kind: .base)
        build.take(picked: [keys.path], kind: .keys)
        XCTAssertTrue(build.canBuild)
        return stores
    }

    func testReadOnlyOutputNamesThePackedAppLeftInTheWorkFolder() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let stores = try buildFixture(at: root)
        let build = stores.build
        let output = root.appendingPathComponent("Games")
        let work = output.appendingPathComponent(titleID + "_build")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: output.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: output.path) }
        build.outDir = output.path
        build.startBuild()
        let deadline = Date().addingTimeInterval(10)
        while build.running && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        let retained = work.appendingPathComponent(titleID + ".app")
        let placement = MacAppOutput(workDir: work, key: titleID, titleID: titleID, preferred: "")
        XCTAssertThrowsError(try placement.finish())
        XCTAssertFalse(build.running)
        XCTAssertFalse(build.done)
        XCTAssertEqual(try MacGameBundle.read(retained).titleID, titleID)
        XCTAssertTrue(build.doneNote.contains(retained.path), build.doneNote)
        XCTAssertTrue(build.log.text.contains(build.doneNote))
        try capture(stores, errorFolder: output)
    }

    func testBothBuildersFinishWithTheReadableAppAndTheLibraryRediscoversIt() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let stores = try buildFixture(at: root)
        let build = stores.build
        for experimental in [false, true] {
            let output = root.appendingPathComponent(experimental ? "experimental" : "standard")
            try fm.createDirectory(at: output, withIntermediateDirectories: true)
            build.outDir = output.path
            build.experimentalBuilderPath = root.appendingPathComponent("nxb").path
            build.experimentalBuilder = experimental
            let library = GameLibrary(file: output.appendingPathComponent("library.json"))
            let entry = try XCTUnwrap(library.rememberInputs(build))
            build.startBuild()
            let deadline = Date().addingTimeInterval(10)
            while build.running && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
            XCTAssertTrue(build.done, build.log.text)
            let path = build.macAppPath
            if !experimental { try capture(stores, filename: URL(fileURLWithPath: path).lastPathComponent) }
            XCTAssertEqual(path, output.appendingPathComponent("雪 - The - Journey.app").path)
            XCTAssertTrue(build.log.text.contains(path))
            XCTAssertTrue(fm.fileExists(atPath: output.appendingPathComponent(titleID + "_build").path))
            XCTAssertTrue(fm.fileExists(atPath: output.appendingPathComponent(".nx2apple-library").path))
            library.recordCompletedApp(path: path, for: entry)
            XCTAssertEqual(library.games.first?.appPath, path)
            XCTAssertEqual(GameLibrary.builtApps(in: output).map { $0.resolvingSymlinksInPath().path }, [URL(fileURLWithPath: path).resolvingSymlinksInPath().path])
            let fresh = GameLibrary(file: output.appendingPathComponent("fresh.json"))
            _ = fresh.rememberInputs(build)
            XCTAssertEqual(URL(fileURLWithPath: try XCTUnwrap(fresh.games.first?.appPath)).resolvingSymlinksInPath().path, URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
        }
    }

    private func capture(_ stores: LauncherStores, filename: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else { return }
        let build = stores.build
        let realPath = build.macAppPath
        defer { build.macAppPath = realPath }
        build.macAppPath = "/Volumes/Games/" + filename
        try writeCapture(OutcomeCard(build: build, devices: stores.deviceStore, onViewGame: {}), stores: stores, to: directory, file: "mac-output.png")
    }

    private func capture(_ stores: LauncherStores, errorFolder: URL) throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else { return }
        let build = stores.build
        let message = build.doneNote
        defer { build.doneNote = message }
        build.doneNote = message.replacingOccurrences(of: errorFolder.path, with: "/Volumes/Games")
        try writeCapture(ActionCard(build: build, dependencies: stores.dependencies, repo: stores.repo), stores: stores, to: directory, file: "mac-placement-error.png")
    }

    private func writeCapture<V: View>(_ card: V, stores: LauncherStores, to directory: String, file: String) throws {
        let view = card
            .environmentObject(stores.localizer).environmentObject(PadFocus())
            .padding(24).frame(width: 840).background(Color(white: 0.09)).environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: view)
        host.frame.size = host.fittingSize
        let window = OffscreenWindow(size: host.frame.size)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let target = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: target.appendingPathComponent(file))
    }
}
