import Foundation
import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
import NXModel
@testable import NXLauncher

/// End-to-end tests for PR A4 Module 1: onboarding step 5 `prod.keys` validation covering sibling Update and DLC packages
/// in the selected game folder, and streaming Python / engine download progress wired into `LiveOnboardingDriver`.
@MainActor final class OnboardingKeysAndProgressTests: IsolatedDefaultsTestCase {
    private var temporary: URL!
    private var defaults: UserDefaults!
    private let headerKey = (0..<32).map { UInt8(0xA0 ^ $0) }

    override func setUpWithError() throws {
        OnboardingDefaults.sessionPlatform = nil
        defaults = TestDefaults.make("onboarding.keys.progress")
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("onboarding-pra4-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporary)
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func ncaHeader(generation: UInt8) -> [UInt8] {
        var header = [UInt8](repeating: 0, count: 0xC00)
        header.replaceSubrange(0x200..<0x204, with: Array("NCA3".utf8))
        header[0x206] = 2
        header[0x207] = 0
        header[0x220] = generation
        header[0x230] = 0x01
        header[0x23F] = generation
        return KeyCheck.xts(header, key: headerKey, encrypt: true)!
    }

    private func writePFS0(_ files: [(String, [UInt8])], at url: URL) throws -> String {
        var names: [UInt8] = []
        var entries: [UInt8] = []
        var payload: [UInt8] = []
        func le(_ value: Int, _ width: Int) -> [UInt8] {
            (0..<width).map { UInt8((value >> (8 * $0)) & 0xFF) }
        }
        for (file, bytes) in files {
            entries += le(payload.count, 8) + le(bytes.count, 8) + le(names.count, 4) + le(0, 4)
            names += Array(file.utf8) + [0]
            payload += bytes
        }
        while names.count % 0x20 != 0 { names.append(0) }
        let out = Array("PFS0".utf8) + le(files.count, 4) + le(names.count, 4) + le(0, 4) + entries + names + payload
        try Data(out).write(to: url)
        return url.path
    }

    private func writeKeys(_ lines: [String], name: String = "prod.keys") throws -> URL {
        let url = temporary.appendingPathComponent(name)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func keyLine(_ name: String, _ byte: UInt8 = 0x5A) -> String {
        name + " = " + hex([UInt8](repeating: byte, count: 16))
    }

    private func makeDriver(
        stores: LauncherStores,
        library: GameLibrary,
        step: OnboardingStep = .keys,
        scannedGames: [LibraryGame] = []
    ) -> LiveOnboardingDriver {
        defaults.set(OnboardingPlatform.mac.rawValue, forKey: OnboardingDefaults.platform)
        defaults.set(step.rawValue, forKey: OnboardingDefaults.step)
        defaults.set(true, forKey: OnboardingDefaults.inProgress)
        var env = OnboardingEnvironment()
        env.defaults = defaults
        env.home = temporary.path
        env.freeBytes = { 100_000_000_000 }
        env.osVersion = { OperatingSystemVersion(majorVersion: 26, minorVersion: 6, patchVersion: 0) }
        env.xcodeInstalled = { true }
        env.xcodeFolderExists = { true }
        env.xcodeProbe = {
            XcodeProbe(appPath: "/Applications/Xcode.app", selectedIsXcode: true, licenseAccepted: true, firstLaunchDone: true)
        }
        env.detectDeps = { _ in }
        env.installDep = { deps, dep in
            if let index = deps.deps.firstIndex(where: { $0.id == dep.id }) {
                deps.deps[index].installing = true
            }
        }
        env.scanGames = { _, _, _ in scannedGames }
        env.fetchArtwork = { _ in }
        env.pollInterval = 0.01
        env.advanceDelay = 0.2
        return LiveOnboardingDriver(stores: stores, library: library, env: env)
    }

    func testValidateKeysFlagsMissingUpdateMasterKeyBesideBaseGame() async throws {
        let gameFolder = temporary.appendingPathComponent("Odyssey")
        try FileManager.default.createDirectory(at: gameFolder, withIntermediateDirectories: true)

        let basePath = try writePFS0(
            [("base.nca", ncaHeader(generation: 0x0C))],
            at: gameFolder.appendingPathComponent("Game [0100000000010000][v0].nsp")
        )
        _ = try writePFS0(
            [("upd.nca", ncaHeader(generation: 0x13))],
            at: gameFolder.appendingPathComponent("Update [0100000000010800][v65536].nsp")
        )

        let oldKeys = try writeKeys(["header_key = " + hex(headerKey), keyLine("master_key_0b")], name: "old.keys")
        let fullKeys = try writeKeys(
            ["header_key = " + hex(headerKey), keyLine("master_key_0b"), keyLine("master_key_12")],
            name: "full.keys"
        )

        let stores = LauncherStores(defaults: testDefaults)
        stores.localizer.lang = .en
        stores.dependencies.checked = true
        // Only `basePath` is pre-filled, reproducing the case where onboarding used to ignore sibling Update packages.
        stores.build.updateSlot("base") { $0.paths = [basePath] }
        let library = GameLibrary(file: temporary.appendingPathComponent("library.json"))
        let driver = makeDriver(stores: stores, library: library, step: .keys)

        driver.validateKeys(oldKeys)
        for _ in 0..<60 {
            if driver.state.keys != .validating { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        guard case let .invalid(problem) = driver.state.keys else {
            XCTFail("Expected missing update master_key_12 to invalidate step 5, got \(driver.state.keys)")
            return
        }
        XCTAssertTrue(problem.contains("Update [0100000000010800][v65536].nsp"), problem)
        XCTAssertTrue(problem.contains("master_key_12"), problem)

        // Supplying updated prod.keys with master_key_12 passes validation.
        driver.validateKeys(fullKeys)
        for _ in 0..<60 {
            if driver.state.keys != .validating { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertEqual(driver.state.keys, .valid)
    }

    func testScanningGamesReverifiesUpdateAndDLCPackagesAndReturnsToKeysStepWhenTooOld() async throws {
        let gameFolder = temporary.appendingPathComponent("LibraryFolder")
        try FileManager.default.createDirectory(at: gameFolder, withIntermediateDirectories: true)

        let basePath = try writePFS0(
            [("base.nca", ncaHeader(generation: 0x0C))],
            at: gameFolder.appendingPathComponent("Base [0100000000010000][v0].nsp")
        )
        let dlcPath = try writePFS0(
            [("dlc.nca", ncaHeader(generation: 0x14))],
            at: gameFolder.appendingPathComponent("DLC [0100000000011001][v0].nsp")
        )
        let oldKeys = try writeKeys(["header_key = " + hex(headerKey), keyLine("master_key_0b")], name: "old.keys")

        var discovered = LibraryGame(titleID: "0100000000010000", name: "Super Mario Odyssey")
        discovered.inputs = ["base": [basePath], "dlc": [dlcPath]]

        let stores = LauncherStores(defaults: testDefaults)
        stores.localizer.lang = .en
        stores.dependencies.checked = true
        stores.build.updateSlot("keys") { $0.paths = [oldKeys.path] }
        let library = GameLibrary(file: temporary.appendingPathComponent("library-scan.json"))
        let driver = makeDriver(stores: stores, library: library, step: .games, scannedGames: [discovered])
        driver.state.keys = .valid

        await driver.scanGames(gameFolder)

        XCTAssertEqual(driver.state.step, .keys, "discovering a DLC requiring a newer master key must return to step 5")
        guard case let .invalid(problem) = driver.state.keys else {
            XCTFail("Expected invalid key state for DLC missing master_key_13, got \(driver.state.keys)")
            return
        }
        XCTAssertTrue(problem.contains("DLC [0100000000011001][v0].nsp"), problem)
        XCTAssertTrue(problem.contains("master_key_13"), problem)
    }

    func testStreamingDependencyAndEngineDownloadProgressReachOnboardingState() throws {
        let stores = LauncherStores(defaults: testDefaults)
        stores.localizer.lang = .en
        stores.dependencies.deps = [
            Dep(id: "python", name: "dep.python", hint: "", present: false, installing: true, installCmd: ["/usr/bin/true"]),
            Dep(id: "dotnet", name: "dep.dotnet", hint: "", present: true, installCmd: []),
        ]
        stores.dependencies.checked = true
        let library = GameLibrary(file: temporary.appendingPathComponent("library-progress.json"))
        let driver = makeDriver(stores: stores, library: library, step: .keys)
        driver.activate()

        stores.dependencies.installProgress["python"] = 0.64
        stores.dependencies.installDetail["python"] = "Downloading zstandard (64%)"
        stores.engineSync.setDownloadProgress(
            busy: true,
            fraction: 0.42,
            status: "Downloading game support (42% · 21 MB / 50 MB)…"
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(driver.state.background[.python], .running(0.64))
        XCTAssertEqual(driver.state.backgroundDetails[.python], "Downloading zstandard (64%)")
        XCTAssertEqual(driver.state.engineTransfer?.fraction, 0.42)
        XCTAssertEqual(driver.state.engineTransfer?.detail, "Downloading game support (42% · 21 MB / 50 MB)…")
    }
}
