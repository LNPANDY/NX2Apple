import XCTest
import CryptoKit
@testable import NSPortBuilder

/// The self-update's rules on bundles in a temporary folder: never the running app, never the network.
final class AppUpdateTests: XCTestCase {
    private var temporary: URL!
    private let bundleID = "org.nxnative.NSPortBuilder"

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-update-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temporary)
    }

    /// A launcher bundle as the release workflow assembles it.
    @discardableResult
    private func makeApp(_ name: String = "NX2Apple", in dir: URL? = nil, id: String? = nil, version: String = "0.4.8",
                         executable: Bool = true, marker: String = "new", minOS: String? = nil) throws -> URL {
        let app = (dir ?? temporary).appendingPathComponent(name + ".app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let exe = macOS.appendingPathComponent("NSPortBuilder")
        try Data(marker.utf8).write(to: exe)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: exe.path)
        var info: [String: Any] = ["CFBundleIdentifier": id ?? bundleID, "CFBundleExecutable": "NSPortBuilder",
                                   "CFBundleShortVersionString": version, "CFBundlePackageType": "APPL"]
        if let minOS { info["LSMinimumSystemVersion"] = minOS }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app
    }

    private func digest(_ file: URL) throws -> String {
        "sha256:" + SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
    }

    /// The app zipped as the release workflow does (ditto -c -k --keepParent).
    private func zip(_ app: URL) throws -> URL {
        let out = temporary.appendingPathComponent("download-" + UUID().uuidString + ".zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--keepParent", app.path, out.path]
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        return out
    }

    private func marker(_ app: URL) throws -> String {
        String(decoding: try Data(contentsOf: app.appendingPathComponent("Contents/MacOS/NSPortBuilder")), as: UTF8.self)
    }

    // ---- digest ----

    func testDigestMatches() throws {
        let file = temporary.appendingPathComponent("a.zip")
        try Data("release".utf8).write(to: file)
        XCTAssertEqual(AppUpdate.checkDigest(file, expected: try digest(file)), .match)
        XCTAssertEqual(AppUpdate.checkDigest(file, expected: try digest(file).uppercased().replacingOccurrences(of: "SHA256:", with: "sha256:")), .match)
    }

    func testDigestMismatch() throws {
        let file = temporary.appendingPathComponent("a.zip")
        try Data("release".utf8).write(to: file)
        let other = temporary.appendingPathComponent("b.zip")
        try Data("something else".utf8).write(to: other)
        XCTAssertEqual(AppUpdate.checkDigest(file, expected: try digest(other)), .mismatch)
        XCTAssertEqual(AppUpdate.checkDigest(file, expected: "sha256:1234"), .mismatch)   // malformed: never a match
    }

    func testDigestMissing() throws {
        let file = temporary.appendingPathComponent("a.zip")
        try Data("release".utf8).write(to: file)
        XCTAssertEqual(AppUpdate.checkDigest(file, expected: nil), .missing)
        XCTAssertEqual(AppUpdate.checkDigest(file, expected: ""), .missing)
        XCTAssertEqual(AppUpdate.checkDigest(file, expected: "sha512:abcd"), .missing)   // nothing to compare with
    }

    // ---- the app inside ----

    func testBundleValidation() throws {
        let good = try makeApp("Good")
        XCTAssertNil(AppUpdate.bundleProblem(good, expectedID: bundleID, tag: "v0.4.8"))
        XCTAssertEqual(AppUpdate.bundleProblem(try makeApp("Other", id: "com.example.Other"), expectedID: bundleID, tag: "v0.4.8"), .wrongIdentifier)
        XCTAssertEqual(AppUpdate.bundleProblem(good, expectedID: "", tag: "v0.4.8"), .wrongIdentifier)   // the running app has no identifier
        XCTAssertEqual(AppUpdate.bundleProblem(try makeApp("NoExe", executable: false), expectedID: bundleID, tag: "v0.4.8"), .noExecutable)
        XCTAssertEqual(AppUpdate.bundleProblem(good, expectedID: bundleID, tag: "v0.4.9"), .wrongVersion)
        XCTAssertEqual(AppUpdate.bundleProblem(temporary.appendingPathComponent("Missing.app"), expectedID: bundleID, tag: "v0.4.8"), .noInfo)
    }

    private func os(_ major: Int, _ minor: Int, _ patch: Int = 0) -> OperatingSystemVersion {
        OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: patch)
    }

    func testOSVersionComparison() throws {
        XCTAssertEqual(AppUpdate.parseOSVersion("26.6")?.minorVersion, 6)
        XCTAssertEqual(AppUpdate.parseOSVersion("26")?.minorVersion, 0)
        XCTAssertEqual(AppUpdate.parseOSVersion("26.6.1")?.patchVersion, 1)
        XCTAssertNil(AppUpdate.parseOSVersion(""))
        XCTAssertNil(AppUpdate.parseOSVersion("26.x"))
        XCTAssertNil(AppUpdate.parseOSVersion("1.2.3.4"))
        XCTAssertTrue(AppUpdate.isOlder(os(26, 5, 9), than: os(26, 6)))
        XCTAssertTrue(AppUpdate.isOlder(os(15, 9), than: os(26, 0)))
        XCTAssertTrue(AppUpdate.isOlder(os(26, 6), than: os(26, 6, 1)))
        XCTAssertFalse(AppUpdate.isOlder(os(26, 6), than: os(26, 6)))
        XCTAssertFalse(AppUpdate.isOlder(os(27, 0), than: os(26, 6)))   // minor 0 < 6 must not count when the major is higher
        XCTAssertEqual(AppUpdate.describe(os(26, 6)), "26.6")
        XCTAssertEqual(AppUpdate.describe(os(26, 6, 1)), "26.6.1")
    }

    func testMinimumOSDecidesWhetherAReleaseMayBeInstalled() throws {
        let needs266 = try makeApp("Needs", minOS: "26.6")
        XCTAssertEqual(AppUpdate.minimumOSAbove(os(15, 5), app: needs266), "26.6")
        XCTAssertEqual(AppUpdate.minimumOSAbove(os(26, 5, 3), app: needs266), "26.6")
        XCTAssertNil(AppUpdate.minimumOSAbove(os(26, 6), app: needs266))
        XCTAssertNil(AppUpdate.minimumOSAbove(os(27, 0), app: needs266))
        XCTAssertNil(AppUpdate.minimumOSAbove(os(13, 0), app: try makeApp("None")))                  // no minimum written
        XCTAssertNil(AppUpdate.minimumOSAbove(os(13, 0), app: try makeApp("Junk", minOS: "later")))  // unreadable: not a reason to refuse
    }

    func testStagingRefusesAReleaseThisMacCannotOpen() throws {
        let source = temporary.appendingPathComponent("source-os", isDirectory: true)
        let archive = try zip(try makeApp(in: source, minOS: "26.6"))
        let release = AppUpdate.Release(tag: "v0.4.8", url: "https://example.invalid/a.zip", digest: try digest(archive))
        func attempt(_ running: OperatingSystemVersion) throws -> Result<AppUpdate.Staged, BuildModel.StageFailure> {
            let copy = temporary.appendingPathComponent("copy-" + UUID().uuidString + ".zip")
            try FileManager.default.copyItem(at: archive, to: copy)
            let root = temporary.appendingPathComponent("stage-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            return BuildModel.stage(zip: copy, release: release, in: root, expectedID: bundleID, requireDigest: true, runningOS: running)
        }
        XCTAssertEqual(try attempt(os(15, 5)).failure, .needsNewerMacOS("26.6"))
        XCTAssertEqual(BuildModel.StageFailure.needsNewerMacOS("26.6").key, "app.needsNewerMacOS")
        XCTAssertNil(try attempt(os(26, 6)).failure)
    }

    func testStagingVerifiesDigestAndBundle() throws {
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        let archive = try zip(try makeApp(in: source))
        let release = AppUpdate.Release(tag: "v0.4.8", url: "https://example.invalid/NX2Apple-macOS-arm64.zip", digest: try digest(archive))
        let root = temporary.appendingPathComponent("stage-ok", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let staged = try BuildModel.stage(zip: archive, release: release, in: root, expectedID: bundleID, requireDigest: true).get()
        XCTAssertEqual(staged.release, release)
        XCTAssertEqual(staged.app.lastPathComponent, "NX2Apple.app")
        XCTAssertEqual(try marker(staged.app), "new")
    }

    func testStagingRefusesMismatchMissingDigestAndWrongApp() throws {
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        func attempt(_ digest: String?, automatic: Bool, id: String? = nil) throws -> Result<AppUpdate.Staged, BuildModel.StageFailure> {
            let dir = source.appendingPathComponent(UUID().uuidString)
            let archive = try zip(try makeApp(in: dir, id: id))
            let root = temporary.appendingPathComponent("stage-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let release = AppUpdate.Release(tag: "v0.4.8", url: "https://example.invalid/a.zip", digest: digest == "self" ? try self.digest(archive) : digest)
            return BuildModel.stage(zip: archive, release: release, in: root, expectedID: bundleID, requireDigest: automatic)
        }
        let wrong = "sha256:" + String(repeating: "0", count: 64)
        XCTAssertEqual(try attempt(wrong, automatic: true).failure, .mismatch)
        XCTAssertEqual(try attempt(wrong, automatic: false).failure, .mismatch)   // a wrong digest is refused by hand too
        XCTAssertEqual(try attempt(nil, automatic: true).failure, .noDigest)
        XCTAssertNil(try attempt(nil, automatic: false).failure)                  // by hand, a release without one installs as before
        XCTAssertEqual(try attempt("self", automatic: true, id: "com.example.Other").failure, .notOurApp)
    }

    // ---- which copies replace themselves ----

    func testReleaseInstallIsUpdatable() throws {
        let apps = temporary.appendingPathComponent("Applications", isDirectory: true)
        let app = try makeApp(in: apps, version: "0.4.7")
        XCTAssertEqual(AppUpdate.installability(app, appVersion: "0.4.7"), .ok)
    }

    func testDeveloperBuildsDoNotUpdate() throws {
        // swift run: a bare executable's folder, no bundle
        let release = temporary.appendingPathComponent("frontend/.build/arm64-apple-macosx/release", isDirectory: true)
        try FileManager.default.createDirectory(at: release, withIntermediateDirectories: true)
        XCTAssertEqual(AppUpdate.installability(release, appVersion: "0.4.7"), .developer)
        // a bundle under .build or DerivedData
        XCTAssertEqual(AppUpdate.installability(try makeApp(in: release, version: "0.4.7"), appVersion: "0.4.7"), .developer)
        let derived = temporary.appendingPathComponent("DerivedData/NX2Apple/Build/Products/Release", isDirectory: true)
        XCTAssertEqual(AppUpdate.installability(try makeApp(in: derived, version: "0.4.7"), appVersion: "0.4.7"), .developer)
        // frontend/NX2Apple.app, assembled beside the Package.swift it was built from
        let frontend = temporary.appendingPathComponent("frontend", isDirectory: true)
        try Data().write(to: frontend.appendingPathComponent("Package.swift"))
        XCTAssertEqual(AppUpdate.installability(try makeApp(in: frontend, version: "0.4.7"), appVersion: "0.4.7"), .developer)
        // a bundle whose plist does not carry this binary's release number, or a binary without one
        let elsewhere = temporary.appendingPathComponent("elsewhere", isDirectory: true)
        XCTAssertEqual(AppUpdate.installability(try makeApp("Stale", in: elsewhere, version: "0.4.6"), appVersion: "0.4.7"), .developer)
        XCTAssertEqual(AppUpdate.installability(try makeApp("Dev", in: elsewhere, version: "dev"), appVersion: "dev"), .developer)
        XCTAssertEqual(AppUpdate.installability(try makeApp("NoID", in: elsewhere, id: "", version: "0.4.7"), appVersion: "0.4.7"), .developer)
    }

    func testReleaseVersions() {
        XCTAssertTrue(AppUpdate.isReleaseVersion("0.4.7"))
        XCTAssertTrue(AppUpdate.isReleaseVersion("1.0"))
        for v in ["", "dev", "1", "0.4.7-local", "0..7", "v0.4.7", "０.４"] { XCTAssertFalse(AppUpdate.isReleaseVersion(v), v) }
    }

    func testReleaseParsingTakesTheDigest() {
        let json: [String: Any] = ["tag_name": "v0.4.8", "assets": [
            ["name": "nxnative-macOS-arm64.zip", "browser_download_url": "https://example.invalid/old.zip", "digest": "sha256:aa"],
            ["name": "NX2Apple-macOS-arm64.zip", "browser_download_url": "https://example.invalid/new.zip", "digest": "sha256:bb"],
        ]]
        XCTAssertEqual(BuildModel.appRelease(fromJSON: json), AppUpdate.Release(tag: "v0.4.8", url: "https://example.invalid/new.zip", digest: "sha256:bb"))
        let legacy: [String: Any] = ["tag_name": "v0.4.8", "assets": [["name": "NS-Port-Builder-macOS-arm64.zip", "browser_download_url": "https://example.invalid/legacy.zip"]]]
        XCTAssertEqual(BuildModel.appRelease(fromJSON: legacy)?.digest, nil)
        XCTAssertNil(BuildModel.appRelease(fromJSON: ["tag_name": "v0.4.8", "assets": []]))
    }

    // ---- when ----

    func testInstallSwapsTheBundleInPlaceWhenTheNameMatches() throws {
        let dir = temporary.appendingPathComponent("Applications")
        let current = try makeApp("Current", in: dir, marker: "old")
        let staged = try makeApp("Current", in: temporary.appendingPathComponent("staged"), marker: "new")
        let placed = try AppUpdate.install(staged, over: current, buildRunning: false, trashOld: false)
        XCTAssertEqual(placed, current, "a same-name install stays where it was")
        XCTAssertEqual(try marker(current), "new")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["Current.app"])   // no "(new)"/"(old)" copy beside it
    }

    func testInstallUsesTheStagedNameWhenItDiffers() throws {
        // The rename era: nxnative → NS Port Builder → NX2Apple. In-place replacement kept the old
        // folder's name for ever, and an updated app still called itself the old name.
        let dir = temporary.appendingPathComponent("Applications")
        let current = try makeApp("Current", in: dir, marker: "old")
        let staged = try makeApp("Renamed", in: temporary.appendingPathComponent("staged"), marker: "new")
        let placed = try AppUpdate.install(staged, over: current, buildRunning: false, trashOld: false)
        XCTAssertEqual(placed.standardizedFileURL.path, dir.appendingPathComponent("Renamed.app").path)
        XCTAssertEqual(try marker(placed), "new", "the new bundle is the staged one, under its own name")
        XCTAssertEqual(try marker(current), "old", "with trashOld off the old copy is left alone (the running app in the real flow)")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(), ["Current.app", "Renamed.app"])
    }

    func testInstallWithTheStagedNameRemovesTheOldBundle() throws {
        let dir = temporary.appendingPathComponent("Applications")
        let current = try makeApp("Current", in: dir, marker: "old")
        let staged = try makeApp("Renamed", in: temporary.appendingPathComponent("staged"), marker: "new")
        _ = try AppUpdate.install(staged, over: current, buildRunning: false, trashOld: true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["Renamed.app"],
                       "the old-named bundle is retired once the new one is in place")
    }

    func testTheInstallTargetFollowsTheStagedNameOnlyWhenItDiffers() {
        let dir = URL(fileURLWithPath: "/Applications")
        XCTAssertEqual(AppUpdate.installTarget(for: dir.appendingPathComponent("NX2Apple.app"),
                                               current: dir.appendingPathComponent("NX2Apple.app")),
                       dir.appendingPathComponent("NX2Apple.app"))
        XCTAssertEqual(AppUpdate.installTarget(for: dir.appendingPathComponent("NX2Apple.app"),
                                               current: dir.appendingPathComponent("NS Port Builder.app")),
                       dir.appendingPathComponent("NX2Apple.app"), "a rename installs under the release's own name")
    }

    func testInstallRefusedWhileBuildRuns() throws {
        let current = try makeApp("Current", in: temporary.appendingPathComponent("Applications"), marker: "old")
        let staged = try makeApp("Staged", in: temporary.appendingPathComponent("staged"), marker: "new")
        XCTAssertThrowsError(try AppUpdate.install(staged, over: current, buildRunning: true, trashOld: false)) {
            XCTAssertEqual($0 as? AppUpdate.InstallError, .buildRunning)
        }
        XCTAssertEqual(try marker(current), "old")
    }

    func testModelWaitsForTheBuild() throws {
        let current = try makeApp("Current", in: temporary.appendingPathComponent("Applications"), marker: "old")
        let staged = try makeApp("Staged", in: temporary.appendingPathComponent("staged"), marker: "new")
        let model = BuildModel()
        model.lang = .en
        model.appInstallability = .ok
        model.appStaged = AppUpdate.Staged(release: AppUpdate.Release(tag: "v0.4.8", url: "", digest: nil), app: staged)
        model.running = true
        XCTAssertFalse(model.mayInstallAppUpdate)
        XCTAssertFalse(model.installStagedUpdate(relaunch: false, at: current))
        model.restartToUpdate()   // refused before it gets as far as a relaunch
        XCTAssertEqual(try marker(current), "old")
        XCTAssertNotNil(model.appStaged)   // still waiting for the quit
        XCTAssertEqual(model.appStatus, L10n.string("app.waitForBuild", .en))
    }

    func testDeveloperModelNeverInstalls() throws {
        let current = try makeApp("Current", in: temporary.appendingPathComponent("Applications"), marker: "old")
        let staged = try makeApp("Staged", in: temporary.appendingPathComponent("staged"), marker: "new")
        let model = BuildModel()
        model.appInstallability = .developer
        model.appStaged = AppUpdate.Staged(release: AppUpdate.Release(tag: "v0.4.8", url: "", digest: nil), app: staged)
        XCTAssertFalse(model.installStagedUpdate(relaunch: false, at: current))
        XCTAssertEqual(try marker(current), "old")
    }

    func testEveryUpdateStringHasBothLanguages() {
        for key in ["app.staging", "app.ready", "app.restartNow", "app.waitForBuild", "app.stageNetFail", "app.noDigest",
                    "app.digestMismatch", "app.unpackFail", "app.notOurApp", "app.devBuild", "app.readOnly", "app.auto",
                    "app.autoNote", "app.autoDev", "app.autoReadOnly", "library.appReady"] {
            XCTAssertNotNil(L10n.table[key], key)
        }
        XCTAssertTrue(L10n.selfCheck().isEmpty)
    }
}

private extension Result {
    var failure: Failure? { if case .failure(let f) = self { return f }; return nil }
}

/// The update check's three outcomes must be distinguishable: a newer release with a download, a
/// newer release whose download this build cannot name, and genuinely being current.
///
/// The middle one used to be reported as "已是最新" (issue: an installed 0.4.6 said it was current
/// while 0.4.8 was out). A build that looks for one exact asset name and does not find it has not
/// established that it is up to date — it has established that it cannot tell, and saying "up to
/// date" leaves that install stuck for ever.
final class UpdateCheckTests: XCTestCase {
    func testAVersionComparisonReadsTheNumbers() {
        XCTAssertTrue(BuildModel.isNewer("v0.4.8", than: "0.4.6"))
        XCTAssertTrue(BuildModel.isNewer("v0.4.10", than: "0.4.8"), "0.4.10 is newer than 0.4.8, not older")
        XCTAssertFalse(BuildModel.isNewer("v0.4.8", than: "0.4.8"))
        XCTAssertFalse(BuildModel.isNewer("v0.4.6", than: "0.4.8"))
    }

    /// The asset names this app will accept, oldest first. A release that carries any of them can
    /// update every install back to 0.4.5; one that carries none leaves those installs stuck, which
    /// is why checkAppUpdate has to say so rather than report "up to date".
    func testTheAssetNamesCoverEveryInstallThatCanStillUpdate() {
        let names = BuildModel.appAssetNames
        XCTAssertTrue(names.contains("NX2Apple-macOS-arm64.zip"), "the current name")
        XCTAssertTrue(names.contains("nxnative-macOS-arm64.zip"), "installs from before the rename to NX2Apple")
        XCTAssertTrue(names.contains("NS-Port-Builder-macOS-arm64.zip"), "installs from before the rename to nxnative")
    }
}
