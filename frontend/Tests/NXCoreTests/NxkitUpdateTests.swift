import CryptoKit
import Foundation
import XCTest
@testable import NXCore

/// nxkit updates itself (LNPANDY/NX2Apple#1460): the signature over SHA256SUMS, then the ZIP and both programs against it, the manifest, the
/// versions under Application Support, the atomic switch and the rollback. A fixture key pair is made here, the real private key is never used.
final class NxkitUpdateTests: XCTestCase {
    private final class FakeTransport: EngineTransport, @unchecked Sendable {
        var answers: [URL: EngineFetch<Data>] = [:]
        var archives: [URL: URL] = [:]
        var downloads = 0
        func data(from url: URL) -> EngineFetch<Data> { answers[url] ?? .missing }
        func download(from url: URL, to destination: URL) -> Bool {
            downloads += 1
            guard let src = archives[url], let payload = try? Data(contentsOf: src) else { return false }
            return (try? payload.write(to: destination)) != nil
        }
    }

    private var temporary: URL!
    private var store: NxkitVersionStore!
    private let key = Curve25519.Signing.PrivateKey()
    private var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }
    private let os26 = OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0)
    private let noPrepare: @Sendable (URL) -> Bool = { _ in true }

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxkit-update-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        store = NxkitVersionStore(root: temporary.appendingPathComponent("support/nxkit", isDirectory: true))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporary)
    }

    // MARK: The key and the signature

    func testThePublicKeyConstantIsAnEd25519Key() throws {
        let raw = try XCTUnwrap(Data(base64Encoded: NxkitUpdate.publicKey))
        XCTAssertEqual(raw.count, 32)
        XCTAssertNotNil(NxkitUpdate.key(NxkitUpdate.publicKey))
    }

    private func signature(_ data: Data, with key: Curve25519.Signing.PrivateKey? = nil) throws -> Data {
        Data(((try (key ?? self.key).signature(for: data)).base64EncodedString() + "\n").utf8)
    }

    func testSignatureGoodBadAndMissing() throws {
        let sums = Data("\(String(repeating: "a", count: 64))  nxb-v0.11.0-macos-arm64.zip\n".utf8)
        let good = try signature(sums)
        XCTAssertTrue(NxkitUpdate.verifySignature(sums: sums, signature: good, publicKey: publicKey))
        XCTAssertNoThrow(try NxkitUpdate.verifiedSums(sums: sums, signature: good, publicKey: publicKey))
        // another key, changed bytes, garbage
        XCTAssertFalse(NxkitUpdate.verifySignature(sums: sums, signature: try signature(sums, with: Curve25519.Signing.PrivateKey()), publicKey: publicKey))
        XCTAssertFalse(NxkitUpdate.verifySignature(sums: sums + Data(" ".utf8), signature: good, publicKey: publicKey))
        XCTAssertFalse(NxkitUpdate.verifySignature(sums: sums, signature: Data("bm90IGEgc2lnbmF0dXJl\n".utf8), publicKey: publicKey))
        XCTAssertFalse(NxkitUpdate.verifySignature(sums: sums, signature: good, publicKey: "short"))
        XCTAssertThrowsError(try NxkitUpdate.verifiedSums(sums: sums, signature: Data("x".utf8), publicKey: publicKey)) {
            XCTAssertEqual($0 as? NxkitUpdate.Rejection, .badSignature)
        }
        XCTAssertThrowsError(try NxkitUpdate.verifiedSums(sums: sums, signature: nil, publicKey: publicKey)) {
            XCTAssertEqual($0 as? NxkitUpdate.Rejection, .unsigned)
        }
    }

    func testReleaseNamesTheZipTheSumsAndTheSignature() throws {
        let json = """
        {"tag_name":"v0.11.0","assets":[
         {"name":"SHA256SUMS","browser_download_url":"https://github.com/v0lumehi/nxkit/releases/download/v0.11.0/SHA256SUMS"},
         {"name":"SHA256SUMS.sig","browser_download_url":"https://github.com/v0lumehi/nxkit/releases/download/v0.11.0/SHA256SUMS.sig"},
         {"name":"nxb-v0.11.0-macos-arm64.zip","browser_download_url":"https://github.com/v0lumehi/nxkit/releases/download/v0.11.0/nxb-v0.11.0-macos-arm64.zip"}]}
        """
        let r = try XCTUnwrap(NxkitUpdate.parseRelease(Data(json.utf8)))
        XCTAssertEqual(r.version, "0.11.0")
        XCTAssertEqual(r.zipName, "nxb-v0.11.0-macos-arm64.zip")
        XCTAssertEqual(r.sumsURL?.lastPathComponent, "SHA256SUMS")
        XCTAssertEqual(r.signatureURL?.lastPathComponent, "SHA256SUMS.sig")
        XCTAssertNil(NxkitUpdate.parseRelease(Data(#"{"tag_name":"v1","assets":[]}"#.utf8)))
    }

    // MARK: A release ZIP

    private struct Fixture { let zip: URL; let zipName: String; let sums: Data; let table: [String: String] }

    /// A release laid out as nxkit's: one folder with nxb, nxkit-host and MANIFEST.json, its SHA256SUMS listing the ZIP and both programs.
    private func makeRelease(_ version: String, host: Bool = true, manifestFormat: Int = 1, macOSMin: String = "26.0",
                             tamperHost: Bool = false) throws -> Fixture {
        let folder = "nxb-v\(version)-macos-arm64"
        let dir = temporary.appendingPathComponent("src-\(UUID().uuidString)/\(folder)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho nxb \(version)\n".utf8).write(to: dir.appendingPathComponent("nxb"))
        var files = ["nxb": try XCTUnwrap(NxkitBuilder.sha256(of: dir.appendingPathComponent("nxb")))]
        if host {
            try Data("#!/bin/sh\necho host \(version)\n".utf8).write(to: dir.appendingPathComponent("nxkit-host"))
            files["nxkit-host"] = try XCTUnwrap(NxkitBuilder.sha256(of: dir.appendingPathComponent("nxkit-host")))
        }
        let manifest: [String: Any] = ["format": manifestFormat, "version": version, "platform": "macos", "arch": "arm64",
                                       "macos_min": macOSMin, "files": files]
        try JSONSerialization.data(withJSONObject: manifest).write(to: dir.appendingPathComponent("MANIFEST.json"))
        if tamperHost { try Data("#!/bin/sh\necho changed\n".utf8).write(to: dir.appendingPathComponent("nxkit-host")) }
        let zipName = folder + ".zip"
        let zip = temporary.appendingPathComponent(UUID().uuidString + ".zip")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = ["-c", "-k", "--keepParent", dir.path, zip.path]
        try proc.run()
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0)
        var lines = ["\(try XCTUnwrap(NxkitBuilder.sha256(of: zip)))  \(zipName)"]
        for (name, sha) in files.sorted(by: { $0.key < $1.key }) { lines.append("\(sha)  \(folder)/\(name)") }
        let sums = Data((lines.joined(separator: "\n") + "\n").utf8)
        return Fixture(zip: zip, zipName: zipName, sums: sums, table: NxkitBuilder.parseChecksums(String(decoding: sums, as: UTF8.self)))
    }

    // MARK: Install

    func testAGoodReleaseInstallsIntoItsVersionFolderWithoutSwitching() throws {
        let r = try makeRelease("0.11.0")
        XCTAssertEqual(try store.install(zip: r.zip, zipName: r.zipName, sums: r.table, running: os26, prepare: noPrepare), "0.11.0")
        XCTAssertTrue(store.isVerified("0.11.0"))
        let dir = store.folder(for: "0.11.0").path
        for name in ["nxb", "nxkit-host", "MANIFEST.json", ".verified"] { XCTAssertTrue(FileManager.default.fileExists(atPath: dir + "/" + name), name) }
        XCTAssertNil(store.readState().current, "installing never switches")
    }

    func testAZipThatDoesNotMatchItsSumsInstallsNothing() throws {
        let r = try makeRelease("0.11.0")
        var table = r.table
        table[r.zipName] = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try store.install(zip: r.zip, zipName: r.zipName, sums: table, running: os26, prepare: noPrepare)) {
            XCTAssertEqual($0 as? NxkitUpdate.Rejection, .checksum)
        }
        table.removeValue(forKey: r.zipName)
        XCTAssertThrowsError(try store.install(zip: r.zip, zipName: r.zipName, sums: table, running: os26, prepare: noPrepare))
        XCTAssertFalse(store.isVerified("0.11.0"))
    }

    func testAProgramThatDiffersFromItsSumsAndManifestInstallsNothing() throws {
        let r = try makeRelease("0.11.0", tamperHost: true)
        // the ZIP matches, the host inside does not
        XCTAssertThrowsError(try store.install(zip: r.zip, zipName: r.zipName, sums: r.table, running: os26, prepare: noPrepare)) {
            XCTAssertEqual($0 as? NxkitUpdate.Rejection, .checksum)
        }
        XCTAssertFalse(store.isVerified("0.11.0"))
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: store.root.path))?.filter { !$0.hasPrefix(".") } ?? [], [])
    }

    func testAReleaseWithoutNxkitHostInstallsNothing() throws {
        let r = try makeRelease("0.11.0", host: false)
        XCTAssertThrowsError(try store.install(zip: r.zip, zipName: r.zipName, sums: r.table, running: os26, prepare: noPrepare)) {
            XCTAssertEqual($0 as? NxkitUpdate.Rejection, .incomplete)
        }
    }

    func testAManifestThisLauncherOrThisMacDoesNotTakeInstallsNothing() throws {
        let format2 = try makeRelease("0.12.0", manifestFormat: 2)
        XCTAssertThrowsError(try store.install(zip: format2.zip, zipName: format2.zipName, sums: format2.table, running: os26, prepare: noPrepare)) {
            XCTAssertEqual($0 as? NxkitUpdate.Rejection, .incompatible(.format(2)))
        }
        let newer = try makeRelease("0.12.0", macOSMin: "27.0")
        XCTAssertThrowsError(try store.install(zip: newer.zip, zipName: newer.zipName, sums: newer.table, running: os26, prepare: noPrepare)) {
            XCTAssertEqual($0 as? NxkitUpdate.Rejection, .incompatible(.macOS("27.0")))
        }
    }

    func testAFailedSigningInstallsNothing() throws {
        let r = try makeRelease("0.11.0")
        XCTAssertThrowsError(try store.install(zip: r.zip, zipName: r.zipName, sums: r.table, running: os26, prepare: { _ in false }))
        XCTAssertFalse(store.isVerified("0.11.0"))
    }

    // MARK: Which pair runs

    private func bundled(_ version: String) throws -> String {
        let dir = temporary.appendingPathComponent("App.app/Contents/Resources/nxbuild-\(version)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["nxb", "nxkit-host"] {
            FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data("x".utf8), attributes: [.posixPermissions: 0o755])
        }
        try Data(#"{"format":1,"version":"\#(version)","arch":"arm64","macos_min":"26.0","files":{"nxb":"a","nxkit-host":"bundledhost"}}"#.utf8)
            .write(to: dir.appendingPathComponent("MANIFEST.json"))
        return dir.path
    }

    private func install(_ version: String) throws {
        let r = try makeRelease(version)
        try store.install(zip: r.zip, zipName: r.zipName, sums: r.table, running: os26, prepare: noPrepare)
    }

    func testVersionSelectionBundledInstalledAndNewer() throws {
        let app = try bundled("0.10.2")
        XCTAssertEqual(store.resolve(bundled: app)?.source, .bundled, "nothing installed: the bundled pair")
        XCTAssertEqual(store.resolve(bundled: app)?.version, "0.10.2")
        XCTAssertEqual(store.resolve(bundled: app)?.hostBuild, "bundledhost")

        try install("0.11.0")
        XCTAssertEqual(store.resolve(bundled: app)?.source, .bundled, "installed but not switched to")
        try store.switchTo("0.11.0")
        let sel = try XCTUnwrap(store.resolve(bundled: app))
        XCTAssertEqual(sel.source, .installed)
        XCTAssertEqual(sel.version, "0.11.0")
        XCTAssertEqual(sel.folder, store.folder(for: "0.11.0").path)

        // an app update that bundles a newer nxkit wins over the older installed one
        XCTAssertEqual(store.resolve(bundled: try bundled("0.12.0"))?.source, .bundled)
        // a version folder without its marker is never used
        try FileManager.default.removeItem(atPath: store.folder(for: "0.11.0").path + "/.verified")
        XCTAssertEqual(store.resolve(bundled: app)?.source, .bundled)
        XCTAssertNil(NxkitVersionStore(root: temporary.appendingPathComponent("none")).resolve(bundled: nil))
    }

    func testSwitchIsAtomicKeepsThePreviousAndRollsBack() throws {
        try install("0.11.0")
        try store.switchTo("0.11.0")
        try install("0.12.0")
        try store.switchTo("0.12.0")
        XCTAssertEqual(store.readState(), NxkitVersionStore.State(current: "0.12.0", previous: "0.11.0"))
        XCTAssertEqual(store.previousVersion, "0.11.0")
        try store.rollback()
        XCTAssertEqual(store.readState(), NxkitVersionStore.State(current: "0.11.0", previous: "0.12.0"))
        // a third version removes the oldest that is neither in use nor the previous one
        try install("0.13.0")
        try store.switchTo("0.13.0")
        XCTAssertEqual(store.readState(), NxkitVersionStore.State(current: "0.13.0", previous: "0.11.0"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.folder(for: "0.12.0").path))
        // the state file is written whole: no temporary file is left beside it
        let names = try FileManager.default.contentsOfDirectory(atPath: store.root.path).sorted()
        XCTAssertEqual(names, ["0.11.0", "0.13.0", "state.json"])
    }

    // MARK: The check

    private func serve(_ r: Fixture, version: String, signature: EngineFetch<Data>?) -> FakeTransport {
        let t = FakeTransport()
        let base = "https://github.com/v0lumehi/nxkit/releases/download/v\(version)/"
        var assets = [#"{"name":"SHA256SUMS","browser_download_url":"\#(base)SHA256SUMS"}"#,
                      #"{"name":"\#(r.zipName)","browser_download_url":"\#(base)\#(r.zipName)"}"#]
        if signature != nil { assets.append(#"{"name":"SHA256SUMS.sig","browser_download_url":"\#(base)SHA256SUMS.sig"}"#) }
        t.answers[NxkitUpdate.latestReleaseURL] = .ok(Data(#"{"tag_name":"v\#(version)","assets":[\#(assets.joined(separator: ","))]}"#.utf8))
        t.answers[URL(string: base + "SHA256SUMS")!] = .ok(r.sums)
        if let signature { t.answers[URL(string: base + "SHA256SUMS.sig")!] = signature }
        t.archives[URL(string: base + r.zipName)!] = r.zip
        return t
    }

    func testCheckInstallsASignedNewerRelease() throws {
        let r = try makeRelease("0.11.0")
        let t = serve(r, version: "0.11.0", signature: .ok(try signature(r.sums)))
        XCTAssertEqual(store.checkAndInstall(inUse: "0.10.2", transport: t, running: os26, publicKey: publicKey, prepare: noPrepare), .installed("0.11.0"))
        XCTAssertTrue(store.isVerified("0.11.0"))
        XCTAssertEqual(store.checkAndInstall(inUse: "0.11.0", transport: t, running: os26, publicKey: publicKey, prepare: noPrepare), .upToDate)
    }

    func testCheckWithoutOrWithABadSignatureDownloadsNothing() throws {
        let r = try makeRelease("0.11.0")
        let unsigned = serve(r, version: "0.11.0", signature: nil)
        XCTAssertEqual(store.checkAndInstall(inUse: "0.10.2", transport: unsigned, running: os26, publicKey: publicKey, prepare: noPrepare),
                       .rejected("0.11.0", .unsigned))
        XCTAssertEqual(unsigned.downloads, 0, "the signature is checked before the ZIP is fetched")
        let missingSig = serve(r, version: "0.11.0", signature: .missing)
        XCTAssertEqual(store.checkAndInstall(inUse: "0.10.2", transport: missingSig, running: os26, publicKey: publicKey, prepare: noPrepare),
                       .rejected("0.11.0", .unsigned))
        let bad = serve(r, version: "0.11.0", signature: .ok(try signature(r.sums, with: Curve25519.Signing.PrivateKey())))
        XCTAssertEqual(store.checkAndInstall(inUse: "0.10.2", transport: bad, running: os26, publicKey: publicKey, prepare: noPrepare),
                       .rejected("0.11.0", .badSignature))
        XCTAssertEqual(bad.downloads, 0)
        XCTAssertFalse(store.isVerified("0.11.0"))
    }

    func testCheckOfflineOrRateLimitedIsQuiet() throws {
        let offline = FakeTransport()
        offline.answers[NxkitUpdate.latestReleaseURL] = .failed   // no network, or GitHub's 403 for the rate limit
        XCTAssertEqual(store.checkAndInstall(inUse: "0.10.2", transport: offline, running: os26, publicKey: publicKey, prepare: noPrepare), .unreachable)
        let r = try makeRelease("0.11.0")
        let sigDown = serve(r, version: "0.11.0", signature: .failed)
        XCTAssertEqual(store.checkAndInstall(inUse: "0.10.2", transport: sigDown, running: os26, publicKey: publicKey, prepare: noPrepare), .unreachable)
    }

    func testCheckOfAnOlderOrEqualReleaseIsUpToDate() throws {
        let r = try makeRelease("0.10.2")
        let t = serve(r, version: "0.10.2", signature: nil)
        XCTAssertEqual(store.checkAndInstall(inUse: "0.10.2", transport: t, running: os26, publicKey: publicKey, prepare: noPrepare), .upToDate)
    }
}
