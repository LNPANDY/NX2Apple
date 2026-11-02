import XCTest
import CryptoKit
@testable import NXModel
@testable import NXCore

/// `AppUpdateStore` without SwiftUI: a fake `ProcessRunner` stands in for ditto and xattr, a fake `ReleaseSource` for GitHub, and the
/// bundles are folders in a temporary directory. This is the pattern for the tests of a store (frontend/ARCHITECTURE.md).
@MainActor final class AppUpdateStoreTests: XCTestCase {
    private var temporary: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    private let runner = FakeProcessRunner()
    private let source = FakeReleaseSource()
    private let bundleID = "org.nxnative.NSPortBuilder"
    private let zipData = Data("zip".utf8)

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxmodel-update-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        suite = "nxmodel-update-tests-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
        // ditto: the fake unpacks a launcher bundle of the version the test names (its tag without the "v") into the last argument
        runner.answer = { [bundleID] launch in
            guard launch.executable.hasSuffix("ditto"), let dir = launch.arguments.last else { return ProcessResult() }
            let macOS = URL(fileURLWithPath: dir).appendingPathComponent("NX2Apple.app/Contents/MacOS")
            try? FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
            let exe = macOS.appendingPathComponent("NSPortBuilder")
            try? Data("new".utf8).write(to: exe)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
            let info: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleExecutable": "NSPortBuilder", "CFBundleShortVersionString": "0.4.8"]
            try? (try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0))
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("NX2Apple.app/Contents/Info.plist"))
            return ProcessResult()
        }
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temporary)
        defaults.removePersistentDomain(forName: suite)
    }

    private func digest(_ data: Data) -> String { "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func makeStore(_ installability: AppUpdate.Installability = .ok, automatic: Bool = false, version: String = "0.4.6",
                           buildRunning: @escaping () -> Bool = { false }, relaunch: @escaping (URL) -> Bool = { _ in true },
                           terminate: @escaping () -> Void = {},
                           uninstall: @escaping (Uninstall.Plan) -> (removed: [String], failures: [String]) = { _ in ([], []) }) -> AppUpdateStore {
        defaults.set(automatic, forKey: AppUpdateStore.automaticKey)
        let store = AppUpdateStore(localizer: Localizer(.en), runner: runner, releases: source, version: version,
                                   bundle: temporary.appendingPathComponent("Applications/NX2Apple.app"), bundleIdentifier: bundleID,
                                   defaults: defaults, buildRunning: buildRunning, relaunch: relaunch, terminate: terminate,
                                   uninstall: uninstall, trashOldApp: false)
        store.installability = installability
        return store
    }

    private func text(_ key: String, _ args: CVarArg...) -> String { String(format: L10n.string(key, .en), arguments: args) }

    /// A launcher bundle in the folder, as the release workflow assembles it.
    private func makeApp(_ name: String, in dir: URL, marker: String) throws -> URL {
        let app = dir.appendingPathComponent(name + ".app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try Data(marker.utf8).write(to: macOS.appendingPathComponent("NSPortBuilder"))
        return app
    }

    private func marker(_ app: URL) throws -> String {
        String(decoding: try Data(contentsOf: app.appendingPathComponent("Contents/MacOS/NSPortBuilder")), as: UTF8.self)
    }

    // ---- The version ----

    func testTheVersionIsAReleaseVersion() {
        XCTAssertTrue(AppUpdate.isReleaseVersion(AppUpdateStore.appVersion))
        XCTAssertEqual(makeStore().version, "0.4.6")
        XCTAssertEqual(AppUpdateStore(localizer: Localizer(.en), runner: runner, releases: source).version, AppUpdateStore.appVersion)
    }

    // ---- The check ----

    func testAFoundReleaseIsOfferedInTheSheetAndWaitsForTheButton() async {
        source.latest = FakeReleaseSource.release(tag: "v0.4.8", digest: "sha256:aa", notes: "What changed")
        let store = makeStore()
        await store.checkForUpdate().value
        XCTAssertEqual(store.update, AppUpdate.Release(tag: "v0.4.8", url: "https://example.invalid/NX2Apple-macOS-arm64.zip", digest: "sha256:aa", notes: "What changed"))
        XCTAssertEqual(store.status, text("app.found", "v0.4.8"))
        XCTAssertTrue(store.showUpdateSheet)
        XCTAssertFalse(store.busy)
        XCTAssertTrue(source.downloads.isEmpty, "with automatic updates off nothing is downloaded before the button")
        XCTAssertNil(store.staged)
    }

    func testADeveloperBuildOnlySaysThatAReleaseExists() async {
        source.latest = FakeReleaseSource.release(tag: "v0.4.8")
        let store = makeStore(.developer, automatic: true)
        await store.checkForUpdate().value
        XCTAssertEqual(store.update?.tag, "v0.4.8")
        XCTAssertEqual(store.status, text("app.devBuild", "v0.4.8"))
        XCTAssertFalse(store.showUpdateSheet)
        XCTAssertTrue(source.downloads.isEmpty)
    }

    func testAReadOnlyCopySaysSo() async {
        source.latest = FakeReleaseSource.release(tag: "v0.4.8")
        let store = makeStore(.readOnly)
        await store.checkForUpdate().value
        XCTAssertEqual(store.status, text("app.readOnly", "v0.4.8"))
    }

    func testTheCurrentVersionIsUpToDateAndSilentStaysQuiet() async {
        source.latest = FakeReleaseSource.release(tag: "v0.4.6")
        let store = makeStore()
        await store.checkForUpdate(silent: true).value
        XCTAssertEqual(store.status, "")
        XCTAssertNil(store.update)
        await store.checkForUpdate().value
        XCTAssertEqual(store.status, text("app.upToDate"))
        XCTAssertFalse(store.showUpdateSheet)
    }

    func testNoAnswerIsNotUpToDate() async {
        let store = makeStore()
        await store.checkForUpdate(silent: true).value
        XCTAssertEqual(store.status, "")
        await store.checkForUpdate().value
        XCTAssertEqual(store.status, text("app.netFail"))
        XCTAssertFalse(store.busy)
    }

    func testANewerReleaseWithoutOurDownloadIsNotUpToDate() async {
        source.latest = FakeReleaseSource.release(tag: "v0.4.8", asset: "Something-else.zip")
        let store = makeStore()
        await store.checkForUpdate(silent: true).value
        XCTAssertEqual(store.status, "")
        await store.checkForUpdate().value
        XCTAssertEqual(store.status, text("app.noAsset", "v0.4.8"))
        XCTAssertNil(store.update)
    }

    func testACheckWhileOneRunsDoesNothing() async {
        source.latest = FakeReleaseSource.release(tag: "v0.4.8")
        let store = makeStore()
        let first = store.checkForUpdate()
        XCTAssertTrue(store.busy)
        await store.checkForUpdate().value
        await first.value
        XCTAssertEqual(source.latestCalls, 1)
    }

    // ---- Staging ----

    func testAutomaticUpdatesDownloadVerifyAndStageAFoundRelease() async throws {
        source.latest = FakeReleaseSource.release(tag: "v0.4.8", digest: digest(zipData))
        let store = makeStore(automatic: true)
        await store.checkForUpdate().value
        XCTAssertTrue(store.busy, "the download starts right behind the check")
        XCTAssertEqual(store.status, text("app.staging", "v0.4.8"))
        XCTAssertTrue(store.showUpdateSheet)
        while store.busy { await Task.yield() }
        XCTAssertEqual(source.downloads.map(\.lastPathComponent), ["NX2Apple-macOS-arm64.zip"])
        XCTAssertEqual(store.staged?.release.tag, "v0.4.8")
        XCTAssertEqual(store.staged?.app.lastPathComponent, "NX2Apple.app")
        XCTAssertEqual(store.status, text("app.ready", "v0.4.8"))
        XCTAssertNil(store.blocked)
        XCTAssertTrue(runner.commands.first?.hasPrefix("ditto -x -k ") == true, "\(runner.commands)")
    }

    func testAChosenUpdateWithoutADigestIsStagedByHandButNotAutomatically() async {
        let release = AppUpdate.Release(tag: "v0.4.8", url: "https://example.invalid/NX2Apple-macOS-arm64.zip", digest: nil)
        let store = makeStore()
        await store.stage(release, automatic: true).value
        XCTAssertNil(store.staged)
        XCTAssertEqual(store.blocked, text("app.noDigest", "v0.4.8"))
        await store.stage(release, automatic: false).value
        XCTAssertEqual(store.staged?.release, release)
        XCTAssertNil(store.blocked, "a new attempt clears the refusal")
    }

    func testADigestThatDoesNotMatchIsRefused() async {
        let release = AppUpdate.Release(tag: "v0.4.8", url: "https://example.invalid/a.zip", digest: "sha256:" + String(repeating: "0", count: 64))
        let store = makeStore()
        await store.stage(release, automatic: false).value
        XCTAssertNil(store.staged)
        XCTAssertEqual(store.status, text("app.digestMismatch", "v0.4.8"))
        XCTAssertEqual(store.blocked, store.status)
        XCTAssertFalse(store.busy)
    }

    func testADownloadThatFailsIsANetworkFailure() async {
        source.file = nil
        let release = AppUpdate.Release(tag: "v0.4.8", url: "https://example.invalid/a.zip", digest: nil)
        let store = makeStore()
        await store.stage(release, automatic: false).value
        XCTAssertEqual(store.status, text("app.stageNetFail", "v0.4.8"))
        XCTAssertEqual(store.blocked, store.status)
        XCTAssertTrue(runner.launches.isEmpty, "nothing to unpack")
    }

    func testOnlyAReleasedCopyStages() async {
        let release = AppUpdate.Release(tag: "v0.4.8", url: "https://example.invalid/a.zip", digest: nil)
        for kind in [AppUpdate.Installability.developer, .readOnly] {
            let store = makeStore(kind)
            await store.stage(release, automatic: false).value
            XCTAssertTrue(source.downloads.isEmpty)
            XCTAssertNil(store.staged)
        }
    }

    func testTurningAutomaticOnStagesTheKnownReleaseAndIsSaved() async {
        let release = AppUpdate.Release(tag: "v0.4.8", url: "https://example.invalid/a.zip", digest: nil)
        let store = makeStore(automatic: false)
        store.update = release
        store.automatic = true
        XCTAssertTrue(store.busy)
        XCTAssertEqual(defaults.object(forKey: AppUpdateStore.automaticKey) as? Bool, true)
        while store.busy { await Task.yield() }
        // automatic refuses a release without a digest, and says so
        XCTAssertNil(store.staged)
        XCTAssertEqual(store.blocked, text("app.noDigest", "v0.4.8"))
        store.automatic = false
        XCTAssertEqual(defaults.object(forKey: AppUpdateStore.automaticKey) as? Bool, false)
    }

    // ---- Installing ----

    private func stagedStore(_ installability: AppUpdate.Installability = .ok, buildRunning: @escaping () -> Bool = { false },
                             relaunch: @escaping (URL) -> Bool = { _ in true }, terminate: @escaping () -> Void = {},
                             automatic: Bool = true) throws -> (AppUpdateStore, current: URL) {
        let current = try makeApp("NX2Apple", in: temporary.appendingPathComponent("Applications"), marker: "old")
        let staged = try makeApp("NX2Apple", in: temporary.appendingPathComponent("staged"), marker: "new")
        let store = makeStore(installability, automatic: automatic, buildRunning: buildRunning, relaunch: relaunch, terminate: terminate)
        store.staged = AppUpdate.Staged(release: AppUpdate.Release(tag: "v0.4.8", url: "", digest: nil), app: staged)
        return (store, current)
    }

    func testTheStoreWaitsForTheBuild() throws {
        let (store, current) = try stagedStore(buildRunning: { true })
        XCTAssertFalse(store.mayInstall)
        XCTAssertFalse(store.install(relaunch: false, at: current))
        store.restartNow()   // refused before it gets as far as a relaunch
        XCTAssertEqual(try marker(current), "old")
        XCTAssertNotNil(store.staged, "still waiting for the quit")
        XCTAssertEqual(store.status, text("app.waitForBuild"))
        store.appWillTerminate()
        XCTAssertEqual(try marker(current), "old", "quitting during a build leaves the swap for a later quit")
    }

    func testADeveloperCopyNeverInstalls() throws {
        let (store, current) = try stagedStore(.developer)
        XCTAssertFalse(store.install(relaunch: false, at: current))
        XCTAssertEqual(try marker(current), "old")
    }

    func testRestartNowSwapsInRelaunchesAndQuits() throws {
        var relaunched: URL?
        var quit = 0
        let (store, current) = try stagedStore(relaunch: { relaunched = $0; return true }, terminate: { quit += 1 })
        XCTAssertTrue(store.install(relaunch: true, at: current))
        XCTAssertEqual(try marker(current), "new")
        XCTAssertNil(store.staged)
        XCTAssertEqual(relaunched, current)
        XCTAssertEqual(quit, 1)
        XCTAssertEqual(store.status, text("app.relaunching", "v0.4.8"))
        XCTAssertTrue(runner.commands.contains { $0.hasPrefix("xattr -dr com.apple.quarantine ") }, "the new copy loses the quarantine flag")
    }

    func testAFailedRelaunchSaysSoAndDoesNotQuit() throws {
        var quit = 0
        let (store, current) = try stagedStore(relaunch: { _ in false }, terminate: { quit += 1 })
        XCTAssertTrue(store.install(relaunch: true, at: current))
        XCTAssertEqual(quit, 0)
        XCTAssertEqual(store.status, text("app.relaunchFail", "v0.4.8"))
    }

    func testTheStagedUpdateGoesInWhenTheAppQuitsWithAutomaticOn() throws {
        var quit = 0
        let (store, current) = try stagedStore(terminate: { quit += 1 })
        store.appWillTerminate()
        XCTAssertEqual(try marker(current), "new")
        XCTAssertNil(store.staged)
        XCTAssertEqual(quit, 0, "quitting never relaunches")
    }

    func testTheStagedUpdateWaitsForTheQuitWithAutomaticOff() throws {
        let (store, current) = try stagedStore(automatic: false)
        store.appWillTerminate()
        XCTAssertNotNil(store.staged)
        XCTAssertEqual(try marker(current), "old")
    }

    func testTheUpdateButtonInstallsAStagedCopyOfTheSameRelease() throws {
        var quit = 0
        let (store, current) = try stagedStore(terminate: { quit += 1 })
        store.update = store.staged?.release
        store.performUpdate()
        XCTAssertEqual(try marker(current), "new", "it goes in over the store's own bundle")
        XCTAssertEqual(quit, 1)
        XCTAssertTrue(source.downloads.isEmpty, "nothing is downloaded twice")
    }

    // ---- Uninstall ----

    func testConfirmingTheUninstallRunsThePlanAndSaysWhatWent() {
        var ran: Uninstall.Plan?
        let store = makeStore(uninstall: { ran = $0; return (["a", "b"], []) })
        let plan = Uninstall.Plan(stateFolders: ["/x"], app: "/Applications/NX2Apple.app")
        store.uninstallPlan = plan
        store.confirmUninstall()
        XCTAssertEqual(ran, plan)
        XCTAssertNil(store.uninstallPlan)
        XCTAssertEqual(store.status, text("uninstall.done", 2))
    }

    func testAnUninstallThatFailsListsWhatFailed() {
        let store = makeStore(uninstall: { _ in ([], ["/x: in use"]) })
        store.uninstallPlan = Uninstall.Plan(stateFolders: ["/x"])
        store.confirmUninstall()
        XCTAssertEqual(store.status, L10n.string("uninstall.failed", .en) + "\n/x: in use")
    }

    func testConfirmingWithoutAPlanDoesNothing() {
        var ran = 0
        let store = makeStore(uninstall: { _ in ran += 1; return ([], []) })
        store.confirmUninstall()
        XCTAssertEqual(ran, 0)
        XCTAssertEqual(store.status, "")
    }
}
