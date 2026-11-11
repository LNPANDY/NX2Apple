import Foundation
import XCTest
@testable import NXCore

final class MacGameModeTests: XCTestCase {
    private var temporary: URL!
    private let titleID = "01007EF00011E000"

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-macgamemode-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporary)
    }

    /// Builds a real Mach-O `.app` bundle matching `dm/mac/pack_app.py` (launcher + `dmhost` + `Info.plist`) and signs it ad-hoc.
    private func makeSignedGameBundle(initialGameMode: Bool = false) throws -> URL {
        let app = temporary.appendingPathComponent("SampleGame.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        let resources = app.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: macOS.appendingPathComponent("nxnative").path)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: macOS.appendingPathComponent("dmhost").path)
        let info: [String: Any] = [
            "CFBundleIdentifier": "org.nxnative.tests.samplegame",
            "CFBundleName": "Sample Game",
            "CFBundleDisplayName": "Sample Game",
            "CFBundleExecutable": "nxnative",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.2.0",
            "LSSupportsGameMode": initialGameMode,
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

    func testRealBundleToggleUpdatesInfoPlistStripsDetritusAndVerifiesStrictSignature() throws {
        let app = try makeSignedGameBundle(initialGameMode: false)
        XCTAssertTrue(MacGameMode.canConfigure(app: app.path))
        XCTAssertFalse(MacGameMode.isEnabled(inApp: app.path))

        // Drop an AppleDouble sidecar inside Resources as an exFAT volume would; re-signing must clean it first.
        let detritus = app.appendingPathComponent("Contents/Resources/._romfs.img")
        try Data([0x00, 0x05, 0x16, 0x07]).write(to: detritus)

        try MacGameMode.applySync(true, toApp: app.path)
        XCTAssertTrue(MacGameMode.isEnabled(inApp: app.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: detritus.path), "AppleDouble sidecar is stripped before codesign")

        let verifyOn = SystemProcessRunner().capture(ProcessLaunch(
            executable: "/usr/bin/codesign",
            arguments: ["--verify", "--deep", "--strict", app.path],
            mergesErrors: true
        ))
        XCTAssertTrue(verifyOn.ok, "strict codesign verification failed after turning Game Mode on: \(verifyOn.out) \(verifyOn.err)")

        try MacGameMode.applySync(false, toApp: app.path)
        XCTAssertFalse(MacGameMode.isEnabled(inApp: app.path))
        let verifyOff = SystemProcessRunner().capture(ProcessLaunch(
            executable: "/usr/bin/codesign",
            arguments: ["--verify", "--deep", "--strict", app.path],
            mergesErrors: true
        ))
        XCTAssertTrue(verifyOff.ok, "strict codesign verification failed after turning Game Mode off: \(verifyOff.out) \(verifyOff.err)")
    }

    func testStripDetritusDoesNotFollowSymbolicLinksOutsideBundle() throws {
        let app = try makeSignedGameBundle(initialGameMode: false)
        let outsideDir = temporary.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        let outsideDetritus = outsideDir.appendingPathComponent("._keep")
        try Data([0x01, 0x02]).write(to: outsideDetritus)
        try FileManager.default.createSymbolicLink(
            at: app.appendingPathComponent("Contents/Resources/external-link"),
            withDestinationURL: outsideDir
        )
        let insideDetritus = app.appendingPathComponent("Contents/Resources/.DS_Store")
        try Data([0x03, 0x04]).write(to: insideDetritus)

        MacGameMode.stripDetritus(in: app)
        XCTAssertFalse(FileManager.default.fileExists(atPath: insideDetritus.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideDetritus.path), "symlink target outside bundle must not be touched")
    }

    func testIdempotentApplySkipsCodesignWhenPlistAlreadyMatches() throws {
        let app = try makeSignedGameBundle(initialGameMode: false)
        let fake = FakeProcessRunner()
        try MacGameMode.applySync(false, toApp: app.path, runner: fake)
        XCTAssertTrue(fake.launches.isEmpty, "no codesign invocation when LSSupportsGameMode already matches")
    }

    func testCustomDeveloperIdentitySignatureIsProtectedAndPlistStaysUntouched() throws {
        let app = try makeSignedGameBundle(initialGameMode: false)
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        let originalBytes = try Data(contentsOf: plistURL)

        let fake = FakeProcessRunner()
        fake.answer = { launch in
            if launch.arguments.first == "-dv" {
                return ProcessResult(
                    status: 0,
                    out: "Executable=\(app.path)/Contents/MacOS/nxnative\nAuthority=Developer ID Application: Jane Doe (TEAMID1234)\n"
                )
            }
            XCTFail("must not overwrite a Developer ID signature with ad-hoc '-': \(launch.arguments)")
            return ProcessResult(status: 1)
        }

        XCTAssertThrowsError(try MacGameMode.applySync(true, toApp: app.path, runner: fake)) { err in
            XCTAssertEqual(err as? MacGameMode.ApplyError, .customSignature)
        }
        XCTAssertEqual(try Data(contentsOf: plistURL), originalBytes)
        XCTAssertFalse(MacGameMode.isEnabled(inApp: app.path))
    }

    func testFailedCodesignRestoresOriginalInfoPlistBytesAndValidSignature() throws {
        let app = try makeSignedGameBundle(initialGameMode: false)
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        let originalBytes = try Data(contentsOf: plistURL)

        var signAttempts = 0
        let fake = FakeProcessRunner()
        fake.answer = { launch in
            if launch.arguments.first == "-dv" {
                return ProcessResult(status: 0, out: "Signature=adhoc\n")
            }
            if launch.executable == "/usr/bin/codesign", launch.arguments.contains("--sign") {
                signAttempts += 1
                if signAttempts == 1 {
                    return ProcessResult(status: 1, err: "codesign: simulated signing failure")
                }
                return SystemProcessRunner().capture(launch)
            }
            return ProcessResult(status: 0)
        }

        XCTAssertThrowsError(try MacGameMode.applySync(true, toApp: app.path, runner: fake)) { err in
            guard case .signingFailed(let detail)? = err as? MacGameMode.ApplyError else {
                return XCTFail("expected signingFailed, got \(err)")
            }
            XCTAssertTrue(detail.contains("simulated signing failure"))
        }
        XCTAssertEqual(try Data(contentsOf: plistURL), originalBytes, "original Info.plist bytes must be restored on failure")
        XCTAssertFalse(MacGameMode.isEnabled(inApp: app.path))
        let verify = SystemProcessRunner().capture(ProcessLaunch(
            executable: "/usr/bin/codesign",
            arguments: ["--verify", "--deep", "--strict", app.path],
            mergesErrors: true
        ))
        XCTAssertTrue(verify.ok, "rolled-back bundle must still pass strict signature verification")
    }

    func testCoordinatorGenerationCoalescesRapidTogglesAndSyncsBeforeLaunch() throws {
        let app = try makeSignedGameBundle(initialGameMode: false)
        let gate = DispatchSemaphore(value: 0)
        let enteredFirst = DispatchSemaphore(value: 0)
        var signCalls = 0
        let lock = NSLock()

        let fake = FakeProcessRunner()
        fake.answer = { launch in
            if launch.arguments.first == "-dv" {
                return ProcessResult(status: 0, out: "Signature=adhoc\n")
            }
            if launch.executable == "/usr/bin/codesign", launch.arguments.contains("--sign") {
                lock.lock()
                signCalls += 1
                let current = signCalls
                lock.unlock()
                if current == 1 {
                    enteredFirst.signal()
                    gate.wait()
                }
                return SystemProcessRunner().capture(launch)
            }
            return ProcessResult(status: 0)
        }

        let coordinator = MacGameMode.Coordinator(runner: fake)
        coordinator.scheduleApply(true, toApp: app.path)
        XCTAssertEqual(enteredFirst.wait(timeout: .now() + 5), .success)

        // While the first re-sign is in flight, flip off -> on -> off: intermediate toggles are superseded by generation checks.
        coordinator.scheduleApply(false, toApp: app.path)
        coordinator.scheduleApply(true, toApp: app.path)
        coordinator.scheduleApply(false, toApp: app.path)
        XCTAssertFalse(coordinator.effectiveEnabled(forApp: app.path, storedOption: nil))
        XCTAssertTrue(coordinator.needsLaunchSync(enabled: false, forApp: app.path))

        gate.signal()
        coordinator.flushForTesting()

        lock.lock()
        let totalSigns = signCalls
        lock.unlock()
        XCTAssertEqual(totalSigns, 2, "only the in-flight first sign and the final generation's sign should run")
        XCTAssertFalse(MacGameMode.isEnabled(inApp: app.path))
        XCTAssertFalse(coordinator.needsLaunchSync(enabled: false, forApp: app.path))
    }
}
