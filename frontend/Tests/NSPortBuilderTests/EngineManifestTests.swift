import CryptoKit
import XCTest
@testable import NSPortBuilder

/// The release manifest and the engine store (EngineManifest.swift). Everything is driven from bytes and
/// temporary folders here: no network, no release.
final class EngineManifestTests: XCTestCase {
    private lazy var digest = String(repeating: "a", count: 64)

    private func json(version: String = "0.8.0", pin: String = "ee6648cb2bb4", engine: String? = nil, app: String? = nil, sources: [String] = []) -> Data {
        let e = engine ?? "{\"asset\":\"engine.zip\",\"sha256\":\"\(digest)\"}"
        let a = app ?? "{\"asset\":\"app.zip\",\"sha256\":\"\(digest)\"}"
        return Data("""
        {"version":"\(version)","pin":"\(pin)","engine":\(e),"app":\(a),"sources":\(sources)}
        """.utf8)
    }

    // MARK: Decoding

    func testAWellFormedManifestDecodes() throws {
        let m = try EngineManifest.decode(json(sources: ["https://example.invalid/v0.8.0/"]))
        XCTAssertEqual(m.version, "0.8.0")
        XCTAssertEqual(m.pin, "ee6648cb2bb4")
        XCTAssertEqual(m.engine.asset, "engine.zip")
        XCTAssertEqual(m.app?.asset, "app.zip")
        XCTAssertEqual(m.sources, ["https://example.invalid/v0.8.0/"])
    }

    /// An older launcher reads a newer manifest: extra keys are ignored rather than rejected.
    func testUnknownKeysAreIgnored() throws {
        let data = Data("""
        {"version":"1.0.0","pin":"ee6648cb2bb4","engine":{"asset":"e.zip","sha256":"\(digest)","future":true},"runtime":"arm64"}
        """.utf8)
        XCTAssertNoThrow(try EngineManifest.decode(data))
    }

    func testTheAppAssetIsOptional() throws {
        let data = Data("""
        {"version":"0.8.0","pin":"ee6648cb2bb4","engine":{"asset":"engine.zip","sha256":"\(digest)"}}
        """.utf8)
        XCTAssertNil(try EngineManifest.decode(data).app)
    }

    func testAManifestTheLauncherCannotActOnIsRejected() {
        XCTAssertThrowsError(try EngineManifest.decode(Data("not json".utf8))) { XCTAssertEqual($0 as? EngineManifest.Problem, .notJSON) }
        XCTAssertThrowsError(try EngineManifest.decode(json(version: "  "))) { XCTAssertEqual($0 as? EngineManifest.Problem, .missingVersion) }
        XCTAssertThrowsError(try EngineManifest.decode(json(pin: "abc"))) { XCTAssertEqual($0 as? EngineManifest.Problem, .missingPin) }
    }

    func testADigestThatIsNotLowercaseHexIsRejected() {
        for bad in [String(repeating: "A", count: 64), String(repeating: "a", count: 63), "sha256:" + digest] {
            XCTAssertThrowsError(try EngineManifest.decode(json(engine: "{\"asset\":\"e.zip\",\"sha256\":\"\(bad)\"}"))) {
                XCTAssertEqual($0 as? EngineManifest.Problem, .badDigest(bad), bad)
            }
        }
    }

    // MARK: Signatures

    private func signed(_ data: Data) throws -> (signature: String, publicKey: String) {
        let key = Curve25519.Signing.PrivateKey()
        let sig = try key.signature(for: data)
        return (sig.base64EncodedString(), key.publicKey.rawRepresentation.base64EncodedString())
    }

    func testAValidSignatureVerifiesAndATamperedManifestDoesNot() throws {
        let data = json()
        let (sig, pub) = try signed(data)
        XCTAssertEqual(EngineManifest.verify(manifest: data, signature: sig, publicKey: pub), .valid)
        let tampered = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "0.8.0", with: "9.9.9").utf8)
        XCTAssertEqual(EngineManifest.verify(manifest: tampered, signature: sig, publicKey: pub), .invalid)
    }

    func testAnAbsentSignatureIsNotValid() throws {
        let (_, pub) = try signed(json())
        XCTAssertEqual(EngineManifest.verify(manifest: json(), signature: nil, publicKey: pub), .absent)
        XCTAssertEqual(EngineManifest.verify(manifest: json(), signature: "not base64!!", publicKey: pub), .absent)
    }

    func testABuildWithoutAKeyCannotCheckAndSaysSo() {
        XCTAssertEqual(EngineManifest.verify(manifest: json(), signature: nil, publicKey: ""), .noKey)
    }

    /// The rule that decides an install: once a key is configured only a valid signature installs; with no
    /// key the check cannot run, which is what a repository build sees.
    func testWhatAnInstallAccepts() {
        XCTAssertTrue(EngineManifest.allowsInstall(.valid))
        XCTAssertFalse(EngineManifest.allowsInstall(.invalid), "a configured key refuses a bad signature, by hand too")
        XCTAssertFalse(EngineManifest.allowsInstall(.absent), "a configured key refuses an unsigned manifest")
        XCTAssertTrue(EngineManifest.allowsInstall(.noKey), "no key configured: today's behaviour")
    }

    // MARK: The store

    func testTheStoreKeepsOneTreePerPinAndPrunesTheRest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("engine-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EngineStore(root: root)
        let fm = FileManager.default
        for pin in ["aaaaaaa", "bbbbbbb", "ccccccc"] {
            let dir = store.directory(for: pin)
            try fm.createDirectory(at: dir.appendingPathComponent("scripts"), withIntermediateDirectories: true)
            try fm.createDirectory(at: dir.appendingPathComponent("dm/tools"), withIntermediateDirectories: true)
            try Data([0]).write(to: dir.appendingPathComponent("scripts/build_ipa_from_nsp.py"))
            try Data([0]).write(to: dir.appendingPathComponent("dm/tools/romfs_image.py"))
            try Data([0]).write(to: dir.appendingPathComponent(".upstream-ref"))
        }
        XCTAssertTrue(store.isUsable("aaaaaaa"))
        XCTAssertEqual(store.prune(keeping: ["aaaaaaa"]), ["bbbbbbb", "ccccccc"])
        XCTAssertTrue(store.isUsable("aaaaaaa"))
        XCTAssertFalse(fm.fileExists(atPath: store.directory(for: "bbbbbbb").path))
    }

    func testAPartiallyUnpackedTreeIsNotUsable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("engine-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EngineStore(root: root)
        let dir = store.directory(for: "ddddddd")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try Data([0]).write(to: dir.appendingPathComponent("scripts/build_ipa_from_nsp.py"))
        XCTAssertFalse(store.isUsable("ddddddd"), "no dm/tools/romfs_image.py and no .upstream-ref")
    }
}
