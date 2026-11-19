import Foundation
import XCTest
@testable import NXCore

/// nxkit (Beta), LNPANDY/NX2Apple#1460: the registry, where it runs, the bundled pair, MANIFEST.json, the command line and nxb's output.
final class NxkitBuilderTests: XCTestCase {
    private var temporary: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxkit-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporary)
    }

    // MARK: Registry

    func testKindDescriptorAndRegistry() {
        XCTAssertEqual(EngineUpstreamKind(rawValue: "nxkit"), .nxkit)
        XCTAssertEqual(EngineUpstreamKind.nxkit.displayName, "nxkit (Beta)")
        XCTAssertEqual(EngineUpstreamKind.nxkit.cardNoteKey, "nxkit.betaNote")
        XCTAssertFalse(EngineUpstreamKind.nxkit.isBuiltIn)
        XCTAssertTrue(EngineUpstreamKind.nxkit.buildsMacOnly)
        XCTAssertTrue(EngineUpstreamKind.macNativeGames.buildsMacOnly)
        XCTAssertFalse(EngineUpstreamKind.s2arm.buildsMacOnly)
        XCTAssertEqual(EngineUpstreamKind.nxkit.macOnlyNoteKey, "upstream.nxkitMacOnly")
        XCTAssertFalse(EngineUpstreamKind.nxkit.needsPythonAndDotnet)
        XCTAssertTrue(EngineUpstreamKind.s2arm.needsPythonAndDotnet)

        let descriptor = EngineUpstream.descriptor(for: .nxkit)
        XCTAssertEqual(descriptor.requiredTools, ["nxb", "nxkit-host"])
        XCTAssertEqual(descriptor.environmentPrefixes, ["NXB_", "NXKIT_"])

        XCTAssertEqual(EngineUpstream.availableOnMac(macNativeGamesEnabled: true, s2armEnabled: true, nxkitEnabled: true),
                       [.nxnative, .macNativeGames, .s2arm, .nxkit])
        XCTAssertEqual(EngineUpstream.availableOnMac(macNativeGamesEnabled: false, s2armEnabled: false, nxkitEnabled: true), [.nxnative, .nxkit])
        XCTAssertEqual(EngineUpstream.availableOnMac(macNativeGamesEnabled: false, s2armEnabled: false, nxkitEnabled: false), [.nxnative])
        // bundled, never downloaded as an upstream checkout
        XCTAssertNil(UpstreamEngineStore.archiveURL(for: .nxkit))
        XCTAssertNil(UpstreamEngineStore(root: temporary).directory(for: .nxkit))
    }

    func testFeatureSwitchIsOnUnlessTheEnvironmentTurnsItOff() {
        let off = ProcessInfo.processInfo.environment["NX2APPLE_MULTI_UPSTREAM"] == "0"
        XCTAssertEqual(NxkitBuilder.featureEnabled, !off)
    }

    // MARK: Where it runs

    func testMacOS26AndAppleSiliconOnly() {
        XCTAssertEqual(NxkitBuilder.availability(macOSMajor: 26, appleSilicon: true), .available)
        XCTAssertEqual(NxkitBuilder.availability(macOSMajor: 27, appleSilicon: true), .available)
        XCTAssertEqual(NxkitBuilder.availability(macOSMajor: 15, appleSilicon: true), .needsNewerMacOS)
        XCTAssertEqual(NxkitBuilder.availability(macOSMajor: 26, appleSilicon: false), .needsAppleSilicon)
        XCTAssertEqual(NxkitBuilder.availability(macOSMajor: 15, appleSilicon: false), .needsAppleSilicon)
    }

    // MARK: The bundled pair

    func testTheBundledPairIsNxbAndNxkitHostSideBySide() throws {
        XCTAssertEqual(NxkitBuilder.bundledFolder(resources: "/Applications/NX2Apple.app/Contents/Resources"),
                       "/Applications/NX2Apple.app/Contents/Resources/nxbuild")
        XCTAssertNil(NxkitBuilder.bundledFolder(resources: nil))
        let fm = FileManager.default
        let dir = temporary.appendingPathComponent("nxbuild").path
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        XCTAssertFalse(NxkitBuilder.canBuildApps(dir))
        fm.createFile(atPath: dir + "/nxb", contents: Data("x".utf8), attributes: [.posixPermissions: 0o755])
        XCTAssertFalse(NxkitBuilder.canBuildApps(dir), "nxb alone cannot make an app")
        fm.createFile(atPath: dir + "/nxkit-host", contents: Data("x".utf8), attributes: [.posixPermissions: 0o644])
        XCTAssertFalse(NxkitBuilder.canBuildApps(dir), "both must be executable")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir + "/nxkit-host")
        XCTAssertTrue(NxkitBuilder.canBuildApps(dir))
        XCTAssertFalse(NxkitBuilder.canBuildApps(""))
    }

    // MARK: MANIFEST.json

    private let manifestJSON = """
    {"format": 1, "version": "0.10.2", "platform": "macos", "arch": "arm64", "macos_min": "26.0",
     "files": {"nxb": "ba20f1b45d8a5d755bf83b03729cc359d4d6375b704705344cf151dd2ad0f6e3",
               "nxkit-host": "e01c6312144767845a60021bc69fb597dd0c6f4eec353ae6739e9e586e5e374b"}}
    """

    func testManifestOfTheRelease() throws {
        let m = try XCTUnwrap(NxkitBuilder.parseManifest(Data(manifestJSON.utf8)))
        XCTAssertEqual(m.format, 1)
        XCTAssertEqual(m.version, "0.10.2")
        XCTAssertEqual(m.arch, "arm64")
        XCTAssertEqual(m.macOSMin, "26.0")
        XCTAssertEqual(m.hostBuild, "e01c6312144767845a60021bc69fb597dd0c6f4eec353ae6739e9e586e5e374b")
        XCTAssertNil(NxkitBuilder.parseManifest(Data("{}".utf8)))
        XCTAssertNil(NxkitBuilder.parseManifest(Data("not json".utf8)))
    }

    func testManifestCompatibility() {
        let os26 = OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        let os261 = OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0)
        let os15 = OperatingSystemVersion(majorVersion: 15, minorVersion: 6, patchVersion: 0)
        var m = NxkitBuilder.Manifest(format: 1, version: "0.11.0", files: [:])
        XCTAssertNil(NxkitBuilder.incompatibility(m, running: os26))
        XCTAssertEqual(NxkitBuilder.incompatibility(m, running: os15), .macOS("26.0"))
        m.macOSMin = "26.1"
        XCTAssertEqual(NxkitBuilder.incompatibility(m, running: os26), .macOS("26.1"))
        XCTAssertNil(NxkitBuilder.incompatibility(m, running: os261))
        m.macOSMin = "26"
        XCTAssertNil(NxkitBuilder.incompatibility(m, running: os26))
        m.format = 2
        XCTAssertEqual(NxkitBuilder.incompatibility(m, running: os26), .format(2), "a ZIP layout this launcher does not know")
        m.format = 1; m.arch = "x86_64"
        XCTAssertEqual(NxkitBuilder.incompatibility(m, running: os26), .arch("x86_64"))
    }

    // MARK: Versions and checksums

    func testVersionComparison() {
        XCTAssertEqual(NxkitBuilder.normalizedVersion("v0.10.2"), "0.10.2")
        XCTAssertEqual(NxkitBuilder.normalizedVersion("nxb 0.10.2\n"), "0.10.2")
        XCTAssertTrue(NxkitBuilder.isNewer("v0.11.0", than: "0.10.2"))
        XCTAssertTrue(NxkitBuilder.isNewer("0.10.10", than: "0.10.2"))
        XCTAssertFalse(NxkitBuilder.isNewer("0.10.2", than: "v0.10.2"))
        XCTAssertFalse(NxkitBuilder.isNewer("0.9.9", than: "0.10.2"))
        XCTAssertTrue(NxkitBuilder.isNewer("0.10.2", than: ""))
        XCTAssertFalse(NxkitBuilder.isNewer("", than: "0.10.2"))
    }

    func testChecksumFile() {
        let a = String(repeating: "a", count: 64), b = String(repeating: "B", count: 64)
        let sums = NxkitBuilder.parseChecksums("\(a)  nxb-v0.10.2-macos-arm64.zip\n\(b) *nxb-v0.10.2-macos-arm64/nxb\nnot a line\n")
        XCTAssertEqual(sums["nxb-v0.10.2-macos-arm64.zip"], a)
        XCTAssertEqual(sums["nxb-v0.10.2-macos-arm64/nxb"], b.lowercased())
        XCTAssertEqual(sums.count, 2)
    }

    // MARK: The build

    func testArgumentsForSwitch1() {
        let args = NxkitBuilder.arguments(input: "/g", nup: nil, keysPath: "/k/prod.keys", outputAppPath: "/o/A.app", workDir: "/w", titleID: "0100f2c0115b6000")
        XCTAssertEqual(args, ["build", "/g", "-k", "/k/prod.keys", "--platform", "mac", "-o", "/o/A.app", "--work-dir", "/w", "--progress", "json",
                              "--title-id", "0100F2C0115B6000"])
        XCTAssertFalse(NxkitBuilder.arguments(input: "/g", nup: nil, keysPath: "", outputAppPath: "/o", workDir: "/w", titleID: nil).contains("-k"))
    }

    func testArgumentsForSwitch2TakeTheNupAndNoKeys() {
        let args = NxkitBuilder.arguments(input: "/g", nup: "/n/game.nup", keysPath: "/k/prod.keys", outputAppPath: "/o/A.app", workDir: "/w", titleID: nil)
        XCTAssertEqual(args, ["build", "/n", "--nup", "/n/game.nup", "--platform", "mac", "-o", "/o/A.app", "--work-dir", "/w", "--progress", "json"])
    }

    func testEnvironmentNamesTheHostBesideNxbAndTheWorkFolderIsPerGame() {
        let env = NxkitBuilder.environment(folder: "/A.app/Contents/Resources/nxbuild", base: ["HOME": "/h"])
        XCTAssertEqual(env["NXB_NXKIT_HOST"], "/A.app/Contents/Resources/nxbuild/nxkit-host")
        XCTAssertEqual(env["HOME"], "/h")
        XCTAssertEqual(NxkitBuilder.workDirectory(home: "/Users/p", key: "0100F2C0115B6000"), "/Users/p/Library/Caches/NX2Apple/nxkit/0100F2C0115B6000")
    }

    func testExitCodesAndTheLastLines() {
        XCTAssertEqual([1, 2, 3, 4, 6, 130].map { NxkitBuilder.exitKey($0) }, ["nxb.exit.1", "nxb.exit.2", "nxb.exit.3", "nxb.exit.4", "nxb.exit.6", "nxb.exit.130"])
        XCTAssertEqual(NxkitBuilder.exitKey(7), "nxb.exit.other")
        let log = """
        {"ev":"stage","k":1,"n":3,"name":"extract"}
        {"ev":"say","msg":"[RED] a key is missing: master_key_0b","t":1.0}
        nxb: exiting
        """
        XCTAssertEqual(NxkitBuilder.lastError(in: log), "a key is missing: master_key_0b")
        XCTAssertNil(NxkitBuilder.lastError(in: "just a line\n"))
        XCTAssertEqual(NxkitBuilder.outputTail(log, count: 12), ["[RED] a key is missing: master_key_0b", "nxb: exiting"], "say as its message, other events left out")
        XCTAssertEqual(NxkitBuilder.outputTail(log, count: 1), ["nxb: exiting"])
    }
}
