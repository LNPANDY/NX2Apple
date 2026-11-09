import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXModel

@MainActor final class XcodeSelectionTests: IsolatedDefaultsTestCase {
    func testPickerSelectionReachesOnboardingBuildAndInstallAndCanBeCleared() async throws {
        let stores = LauncherStores(defaults: testDefaults)
        let runner = stores.runner
        let selection = DependencyStore(localizer: stores.localizer, runner: runner, repo: stores.repo, defaults: testDefaults,
                                        scan: { _, _ in .init(deps: [], python: "", dotnet: "") }, report: { _ in })
        guard let system = Toolchain.developerDir(runner: runner), system.hasSuffix(".app/Contents/Developer") else {
            throw XCTSkip("A working Xcode is required")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("External Drive " + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = folder.appendingPathComponent("Developer's Xcode.app")
        try FileManager.default.createSymbolicLink(at: app, withDestinationURL: URL(fileURLWithPath: system).deletingLastPathComponent().deletingLastPathComponent())
        let path = app.path + "/Contents/Developer"
        XCTAssertTrue(selection.selectXcode(app))
        XCTAssertFalse(selection.selectXcode(folder))
        XCTAssertEqual(XcodeSelection.app(in: testDefaults), app.path)
        XCTAssertTrue(DependencyCheck.xcodeDep(needsIOS: false, customApp: app.path, runner: runner).present)
        let probe = await OnboardingEnvironment.liveProbe(defaults: testDefaults)
        XCTAssertEqual(probe.appPath, app.path)
        XCTAssertTrue(probe.selectedIsXcode)

        let clean = stores.build.toolEnvironment(python: "/usr/bin/python3")
        XCTAssertEqual(runner.output("/usr/bin/xcode-select", ["-p"], env: clean)?.trimmingCharacters(in: .newlines), path)
        XCTAssertNotNil(runner.output("/usr/bin/xcrun", ["--sdk", "macosx", "--show-sdk-version"], env: clean))
        let output = folder.appendingPathComponent("install-stage-selection")
        let finished = expectation(description: "install tool finished")
        stores.build.runTool(id: 1, name: "Selection", ["/bin/sh", "-c", "/usr/bin/xcode-select -p > \"$1\"", "sh", output.path], step: { _ in nil }) { error in
            XCTAssertNil(error)
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 15)
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8).trimmingCharacters(in: .newlines), path)

        try FileManager.default.removeItem(at: app)
        let git = runner.capture(ProcessLaunch(["/usr/bin/git", "--version"], environment: clean))
        XCTAssertTrue(git.ok, git.err)
        XCTAssertTrue(git.out.hasPrefix("git version"))
        XCTAssertTrue(runner.runOK("/usr/bin/python3", ["--version"], env: clean))
        let missing = DependencyCheck.xcodeDep(needsIOS: false, customApp: app.path, runner: runner)
        XCTAssertFalse(missing.present)
        XCTAssertEqual(missing.hint, "xcodeChoice.unavailable")
        let disconnected = await OnboardingEnvironment.liveProbe(defaults: testDefaults)
        XCTAssertNil(disconnected.appPath)
        XCTAssertTrue(disconnected.selectedAppUnavailable)
        XCTAssertEqual(selection.xcodeApp, app.path)
        try FileManager.default.createSymbolicLink(at: app, withDestinationURL: URL(fileURLWithPath: system).deletingLastPathComponent().deletingLastPathComponent())
        XCTAssertEqual(Toolchain.developerDir(runner: runner), path)
        XCTAssertTrue(selection.selectXcode(nil))
        XCTAssertNil(XcodeSelection.app(in: testDefaults))
        XCTAssertEqual(Toolchain.developerDir(runner: runner), system)
    }
}
