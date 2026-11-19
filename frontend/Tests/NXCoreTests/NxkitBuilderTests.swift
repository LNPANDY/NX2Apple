import Foundation
import XCTest
@testable import NXCore

final class NxkitBuilderTests: XCTestCase {
    private final class FakeTransport: EngineTransport, @unchecked Sendable {
        var answers: [URL: Data] = [:]
        var archives: [URL: URL] = [:]

        func data(from url: URL) -> EngineFetch<Data> {
            answers[url].map { .ok($0) } ?? .missing
        }

        func download(from url: URL, to destination: URL) -> Bool {
            guard let src = archives[url], let payload = try? Data(contentsOf: src) else { return false }
            return (try? payload.write(to: destination)) != nil
        }
    }

    private var temporary: URL!
    private var storeRoot: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxkit-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        storeRoot = temporary.appendingPathComponent("upstreams", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporary)
    }

    // MARK: Registry

    func testKindDescriptorAndRegistry() {
        XCTAssertEqual(EngineUpstreamKind(rawValue: "nxkit"), .nxkit)
        XCTAssertEqual(EngineUpstreamKind.nxkit.displayName, "nxkit")
        XCTAssertEqual(EngineUpstreamKind.nxkit.cardNoteKey, "upstream.nxkitCardNote")
        XCTAssertFalse(EngineUpstreamKind.nxkit.isBuiltIn)
        XCTAssertTrue(EngineUpstreamKind.nxkit.buildsMacOnly)
        XCTAssertTrue(EngineUpstreamKind.macNativeGames.buildsMacOnly)
        XCTAssertFalse(EngineUpstreamKind.s2arm.buildsMacOnly)
        XCTAssertEqual(EngineUpstreamKind.nxkit.macOnlyNoteKey, "upstream.nxkitMacOnly")
        XCTAssertFalse(EngineUpstreamKind.nxkit.needsPythonAndDotnet)
        XCTAssertTrue(EngineUpstreamKind.s2arm.needsPythonAndDotnet)

        let descriptor = EngineUpstream.descriptor(for: .nxkit)
        XCTAssertEqual(descriptor.markerPaths, ["nxb"])
        XCTAssertEqual(descriptor.requiredTools, ["nxb", "nxkit-host"])
        XCTAssertEqual(descriptor.environmentPrefixes, ["NXB_", "NXKIT_"])

        XCTAssertEqual(
            EngineUpstream.availableOnMac(macNativeGamesEnabled: true, s2armEnabled: true, nxkitEnabled: true),
            [.nxnative, .macNativeGames, .s2arm, .nxkit]
        )
        XCTAssertEqual(
            EngineUpstream.availableOnMac(macNativeGamesEnabled: false, s2armEnabled: false, nxkitEnabled: true),
            [.nxnative, .nxkit]
        )
        XCTAssertEqual(
            EngineUpstream.availableOnMac(macNativeGamesEnabled: false, s2armEnabled: false, nxkitEnabled: false),
            [.nxnative]
        )
        XCTAssertNil(UpstreamEngineStore.archiveURL(for: .nxkit))
        XCTAssertEqual(UpstreamEngineStore(root: storeRoot).directory(for: .nxkit)?.lastPathComponent, "nxkit")
    }

    func testFeatureSwitchIsOnUnlessTheEnvironmentTurnsItOff() {
        let off = ProcessInfo.processInfo.environment["NX2APPLE_MULTI_UPSTREAM"] == "0"
        XCTAssertEqual(NxkitBuilder.featureEnabled, !off)
    }

    // MARK: Release

    private let releaseJSON = """
    {"tag_name":"v0.10.1","assets":[
     {"name":"SHA256SUMS","browser_download_url":"https://github.com/v0lumehi/nxkit/releases/download/v0.10.1/SHA256SUMS"},
     {"name":"nxb-v0.10.1-macos-arm64.zip","browser_download_url":"https://github.com/v0lumehi/nxkit/releases/download/v0.10.1/nxb-v0.10.1-macos-arm64.zip"}]}
    """

    func testParseRelease() throws {
        let release = try XCTUnwrap(NxkitBuilder.parseRelease(Data(releaseJSON.utf8)))
        XCTAssertEqual(release.tag, "v0.10.1")
        XCTAssertEqual(release.version, "0.10.1")
        XCTAssertEqual(release.zipName, "nxb-v0.10.1-macos-arm64.zip")
        XCTAssertEqual(release.zipURL.absoluteString, "https://github.com/v0lumehi/nxkit/releases/download/v0.10.1/nxb-v0.10.1-macos-arm64.zip")
        XCTAssertEqual(release.sumsURL?.lastPathComponent, "SHA256SUMS")
        XCTAssertNil(NxkitBuilder.parseRelease(Data("{\"tag_name\":\"v1\",\"assets\":[]}".utf8)))
        XCTAssertNil(NxkitBuilder.parseRelease(Data("not json".utf8)))
    }

    func testVersionComparison() {
        XCTAssertEqual(NxkitBuilder.normalizedVersion("v0.10.1"), "0.10.1")
        XCTAssertEqual(NxkitBuilder.normalizedVersion("nxb 0.10.1"), "0.10.1")
        XCTAssertTrue(NxkitBuilder.isNewer("v0.10.2", than: "v0.10.1"))
        XCTAssertTrue(NxkitBuilder.isNewer("v0.11.0", than: "v0.9.9"))
        XCTAssertFalse(NxkitBuilder.isNewer("v0.10.1", than: "v0.10.1"))
        XCTAssertFalse(NxkitBuilder.isNewer("v0.9.0", than: "v0.10.1"))
        XCTAssertTrue(NxkitBuilder.isNewer("v0.10.1", than: ""))
    }

    // MARK: Checksums

    func testChecksumVerification() throws {
        let file = temporary.appendingPathComponent("a.zip")
        try Data("hello".utf8).write(to: file)
        let hello = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        let sums = NxkitBuilder.parseChecksums("""
        \(hello)  a.zip
        \(hello.uppercased()) *dir/b
        not a line
        abc  short
        """)
        XCTAssertEqual(sums["a.zip"], hello)
        XCTAssertEqual(sums["dir/b"], hello)
        XCTAssertNil(sums["short"])

        XCTAssertEqual(NxkitBuilder.verify(file: file, listedAs: "a.zip", in: sums), .ok)
        XCTAssertEqual(NxkitBuilder.verify(file: file, listedAs: "a.zip", in: ["a.zip": String(repeating: "0", count: 64)]), .mismatch)
        XCTAssertEqual(NxkitBuilder.verify(file: file, listedAs: "other.zip", in: sums), .missing)
        XCTAssertEqual(NxkitBuilder.verify(file: temporary.appendingPathComponent("gone.zip"), listedAs: "a.zip", in: sums), .missing)
    }

    // MARK: Command line

    func testArgumentsForSwitch1() {
        let args = NxkitBuilder.arguments(input: "/games/zelda", nup: nil, keysPath: "/k/prod.keys",
                                          outputAppPath: "/out/Zelda.app", workDir: "/work/0100", titleID: "01007ef00011e000")
        XCTAssertEqual(args, ["build", "/games/zelda", "-k", "/k/prod.keys", "--platform", "mac", "-o", "/out/Zelda.app",
                              "--work-dir", "/work/0100", "--progress", "json", "--title-id", "01007EF00011E000"])
    }

    func testArgumentsForSwitch2TakeTheNupAndNoKeys() {
        let args = NxkitBuilder.arguments(input: "/games/ootbox/ignored", nup: "/games/oot/Oot.nup", keysPath: "/k/prod.keys",
                                          outputAppPath: "/out/Oot.app", workDir: "/work/0400", titleID: nil)
        XCTAssertEqual(args, ["build", "/games/oot", "--nup", "/games/oot/Oot.nup", "--platform", "mac", "-o", "/out/Oot.app",
                              "--work-dir", "/work/0400", "--progress", "json"])
        XCTAssertFalse(args.contains("-k"))
    }

    func testEnvironmentNamesTheHostAndTheWorkFolderIsPerGame() {
        let env = NxkitBuilder.environment(tree: "/s/upstreams/nxkit", base: ["HOME": "/h"])
        XCTAssertEqual(env["NXB_NXKIT_HOST"], "/s/upstreams/nxkit/nxkit-host")
        XCTAssertEqual(env["HOME"], "/h")
        XCTAssertEqual(NxkitBuilder.workDirectory(home: "/Users/p", key: "0100F2C0115B6000"), "/Users/p/Library/Caches/NX2Apple/nxkit/0100F2C0115B6000")
    }

    func testLastErrorPrefersTheRedLine() {
        let log = "{\"ev\":\"say\",\"msg\":\"[RED] a key is missing: master_key_0b\",\"t\":1.0}\nnxb: exiting\n"
        XCTAssertEqual(NxkitBuilder.lastError(in: log), "a key is missing: master_key_0b")
        XCTAssertEqual(NxkitBuilder.lastError(in: "just a line\n"), "just a line")
    }

    // MARK: Install

    /// A release ZIP as the tests need it: a folder named like the release with `nxb` and, when asked, `nxkit-host`.
    private func makeRelease(host: Bool, tamper: Bool = false) throws -> (zip: URL, name: String, sums: [String: String]) {
        let folderName = "nxb-v0.10.1-macos-arm64"
        let dir = temporary.appendingPathComponent(folderName, isDirectory: true)
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho nxb 0.10.1\n".utf8).write(to: dir.appendingPathComponent("nxb"))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent("nxb").path)
        if host {
            try Data("#!/bin/sh\n".utf8).write(to: dir.appendingPathComponent("nxkit-host"))
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent("nxkit-host").path)
            try Data("{\"nxb\":\"0.10.1\"}".utf8).write(to: dir.appendingPathComponent("MANIFEST.json"))
        }
        let zip = temporary.appendingPathComponent("release-\(host).zip")
        try? fm.removeItem(at: zip)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = ["-c", "-k", "--keepParent", dir.path, zip.path]
        try proc.run()
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0)
        let zipName = "nxb-v0.10.1-macos-arm64.zip"
        var sums = [zipName: try XCTUnwrap(NxkitBuilder.sha256(of: zip)),
                    folderName + "/nxb": try XCTUnwrap(NxkitBuilder.sha256(of: dir.appendingPathComponent("nxb")))]
        if host { sums[folderName + "/nxkit-host"] = try XCTUnwrap(NxkitBuilder.sha256(of: dir.appendingPathComponent("nxkit-host"))) }
        if tamper { sums[zipName] = String(repeating: "0", count: 64) }
        return (zip, zipName, sums)
    }

    func testInstallWithHostCanBuildApps() throws {
        let release = try makeRelease(host: true)
        let store = UpstreamEngineStore(root: storeRoot)
        let dest = try store.installNxkit(zip: release.zip, zipName: release.name, tag: "v0.10.1", sums: release.sums)
        XCTAssertEqual(dest.path, store.directory(for: .nxkit)?.path)
        XCTAssertTrue(NxkitBuilder.isUsableTree(dest.path))
        XCTAssertTrue(NxkitBuilder.canBuildApps(dest.path))
        XCTAssertEqual(NxkitBuilder.readInfo(in: dest.path), NxkitBuilder.InstallInfo(tag: "v0.10.1", hasHost: true))
        XCTAssertNotNil(store.usableDirectory(for: .nxkit))
        for name in ["nxb", "nxkit-host"] {
            let mode = (try FileManager.default.attributesOfItem(atPath: dest.appendingPathComponent(name).path)[.posixPermissions] as? Int) ?? 0
            XCTAssertEqual(mode & 0o111, 0o111, name + " is executable")
        }
    }

    func testInstallOfAZipWithoutNxkitHostIsUsableButCannotBuildApps() throws {
        let release = try makeRelease(host: false)
        let store = UpstreamEngineStore(root: storeRoot)
        let dest = try store.installNxkit(zip: release.zip, zipName: release.name, tag: "v0.10.1", sums: release.sums)
        XCTAssertTrue(NxkitBuilder.isUsableTree(dest.path))
        XCTAssertFalse(NxkitBuilder.canBuildApps(dest.path))
        XCTAssertEqual(NxkitBuilder.readInfo(in: dest.path)?.hasHost, false)
    }

    func testInstallRefusesAZipThatDoesNotMatchItsChecksum() throws {
        let release = try makeRelease(host: true, tamper: true)
        let store = UpstreamEngineStore(root: storeRoot)
        XCTAssertThrowsError(try store.installNxkit(zip: release.zip, zipName: release.name, tag: "v0.10.1", sums: release.sums)) {
            XCTAssertEqual($0 as? UpstreamEngineStore.Failure, .checksum)
        }
        XCTAssertNil(store.usableDirectory(for: .nxkit))
    }

    func testInstallRefusesAZipTheChecksumFileDoesNotList() throws {
        let release = try makeRelease(host: true)
        let store = UpstreamEngineStore(root: storeRoot)
        XCTAssertThrowsError(try store.installNxkit(zip: release.zip, zipName: release.name, tag: "v0.10.1", sums: [:])) {
            XCTAssertEqual($0 as? UpstreamEngineStore.Failure, .checksum)
        }
        XCTAssertNil(store.usableDirectory(for: .nxkit))
    }

    func testInstallRefusesAFileThatDiffersFromItsListedHash() throws {
        var release = try makeRelease(host: true)
        release.sums["nxb-v0.10.1-macos-arm64/nxkit-host"] = String(repeating: "f", count: 64)
        let store = UpstreamEngineStore(root: storeRoot)
        XCTAssertThrowsError(try store.installNxkit(zip: release.zip, zipName: release.name, tag: "v0.10.1", sums: release.sums)) {
            XCTAssertEqual($0 as? UpstreamEngineStore.Failure, .checksum)
        }
        XCTAssertNil(store.usableDirectory(for: .nxkit))
    }

    func testUpdateKeepsTheOldInstallWhenTheNewZipIsBad() throws {
        let store = UpstreamEngineStore(root: storeRoot)
        let good = try makeRelease(host: true)
        try store.installNxkit(zip: good.zip, zipName: good.name, tag: "v0.10.1", sums: good.sums)
        let bad = try makeRelease(host: true, tamper: true)
        XCTAssertThrowsError(try store.installNxkit(zip: bad.zip, zipName: bad.name, tag: "v0.11.0", sums: bad.sums))
        let dir = try XCTUnwrap(store.usableDirectory(for: .nxkit))
        XCTAssertEqual(NxkitBuilder.readInfo(in: dir.path)?.tag, "v0.10.1")
    }

    func testDownloadAndInstallFromTheLatestRelease() throws {
        let release = try makeRelease(host: true)
        let latest = try XCTUnwrap(NxkitBuilder.parseRelease(Data(releaseJSON.utf8)))
        let transport = FakeTransport()
        let sumsText = release.sums.map { $0.value + "  " + $0.key }.joined(separator: "\n")
        transport.answers[try XCTUnwrap(latest.sumsURL)] = Data(sumsText.utf8)
        transport.archives[latest.zipURL] = release.zip
        let store = UpstreamEngineStore(root: storeRoot)
        let result = store.downloadAndInstallNxkit(release: latest, transport: transport)
        guard case .success(let dir) = result else { return XCTFail("\(result)") }
        XCTAssertTrue(NxkitBuilder.canBuildApps(dir.path))
        // the download folder holds no leftovers
        let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: storeRoot.path)) ?? []).filter { $0.hasPrefix(".") }
        XCTAssertEqual(leftovers, [])
    }

    func testDownloadWithoutChecksumFileInstallsNothing() throws {
        let release = try makeRelease(host: true)
        let latest = try XCTUnwrap(NxkitBuilder.parseRelease(Data(releaseJSON.utf8)))
        let transport = FakeTransport()
        transport.archives[latest.zipURL] = release.zip   // SHA256SUMS answers 404
        let store = UpstreamEngineStore(root: storeRoot)
        XCTAssertEqual(store.downloadAndInstallNxkit(release: latest, transport: transport).nxkitFailure, .checksum)
        XCTAssertNil(store.usableDirectory(for: .nxkit))
    }
}

private extension Result {
    var nxkitFailure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
