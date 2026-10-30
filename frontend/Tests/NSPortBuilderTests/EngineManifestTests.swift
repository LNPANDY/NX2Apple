import CryptoKit
import XCTest
@testable import NSPortBuilder

/// The release manifest and the engine store (EngineManifest.swift). Everything is driven from bytes and
/// temporary folders here: no network, no release.
final class EngineManifestTests: XCTestCase {
    private lazy var digest = String(repeating: "a", count: 64)
    private let pin = String(repeating: "e", count: 40)
    private var engineID: String { pin + "-0123456789ab" }

    private func json(version: String = "0.8.0", pin: String? = nil, engineID: String? = nil, engine: String? = nil,
                      app: String? = nil, sources: [String] = []) -> Data {
        let e = engine ?? "{\"asset\":\"engine.zip\",\"sha256\":\"\(digest)\"}"
        let a = app ?? "{\"asset\":\"app.zip\",\"sha256\":\"\(digest)\"}"
        let sourceList = "[" + sources.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        return Data("""
        {"version":"\(version)","pin":"\(pin ?? self.pin)","engine_id":"\(engineID ?? self.engineID)","engine":\(e),"app":\(a),"sources":\(sourceList)}
        """.utf8)
    }

    // MARK: Decoding

    func testAWellFormedManifestDecodes() throws {
        let m = try EngineManifest.decode(json(sources: ["https://example.invalid/v0.8.0/"]))
        XCTAssertEqual(m.version, "0.8.0")
        XCTAssertEqual(m.pin, pin)
        XCTAssertEqual(m.engineID, engineID)
        XCTAssertEqual(m.engine.asset, "engine.zip")
        XCTAssertEqual(m.app?.asset, "app.zip")
        XCTAssertEqual(m.sources, ["https://example.invalid/v0.8.0/"])
    }

    /// An older launcher reads a newer manifest: extra keys are ignored rather than rejected.
    func testUnknownKeysAreIgnored() throws {
        let data = Data("""
        {"version":"1.0.0","pin":"\(pin)","engine_id":"\(engineID)","engine":{"asset":"e.zip","sha256":"\(digest)","future":true},"runtime":"arm64"}
        """.utf8)
        XCTAssertNoThrow(try EngineManifest.decode(data))
    }

    func testTheAppAssetIsOptional() throws {
        let data = Data("""
        {"version":"0.8.0","pin":"\(pin)","engine_id":"\(engineID)","engine":{"asset":"engine.zip","sha256":"\(digest)"}}
        """.utf8)
        XCTAssertNil(try EngineManifest.decode(data).app)
    }

    func testAManifestTheLauncherCannotActOnIsRejected() {
        XCTAssertThrowsError(try EngineManifest.decode(Data("not json".utf8))) { XCTAssertEqual($0 as? EngineManifest.Problem, .notJSON) }
        XCTAssertThrowsError(try EngineManifest.decode(json(version: "  "))) { XCTAssertEqual($0 as? EngineManifest.Problem, .missingVersion) }
        XCTAssertThrowsError(try EngineManifest.decode(json(pin: "abc"))) { XCTAssertEqual($0 as? EngineManifest.Problem, .missingPin) }
        XCTAssertThrowsError(try EngineManifest.decode(json(pin: "../../x"))) { XCTAssertEqual($0 as? EngineManifest.Problem, .missingPin) }
    }

    /// The store is keyed on engine_id, so a manifest without one, or with one for another pin, installs nothing.
    func testTheEngineIDMustBelongToThePin() {
        let other = String(repeating: "f", count: 40) + "-0123456789ab"
        for bad in ["", other, pin, pin + "-0123456789AB", pin + "-0123", "../" + engineID, engineID + "/x"] {
            XCTAssertThrowsError(try EngineManifest.decode(json(engineID: bad))) {
                XCTAssertEqual($0 as? EngineManifest.Problem, .badEngineID(bad), bad)
            }
        }
        let noID = Data("""
        {"version":"0.8.0","pin":"\(pin)","engine":{"asset":"engine.zip","sha256":"\(digest)"}}
        """.utf8)
        XCTAssertThrowsError(try EngineManifest.decode(noID)) { XCTAssertEqual($0 as? EngineManifest.Problem, .badEngineID("")) }
    }

    /// Asset names end up in a URL and a file name, sources are where the archive comes from.
    func testAssetNamesAndSourcesAreCheckedBeforeTheyAreUsed() {
        for bad in ["../engine.zip", "dir/engine.zip", ".engine.zip", ""] {
            XCTAssertThrowsError(try EngineManifest.decode(json(engine: "{\"asset\":\"\(bad)\",\"sha256\":\"\(digest)\"}"))) {
                XCTAssertEqual($0 as? EngineManifest.Problem, .badAsset(bad), bad)
            }
        }
        for bad in ["http://example.invalid/v0.8.0/", "file:///etc/", "https:///nohost/"] {
            XCTAssertThrowsError(try EngineManifest.decode(json(sources: [bad]))) {
                XCTAssertEqual($0 as? EngineManifest.Problem, .badSource(bad), bad)
            }
        }
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

    /// The compiled key and `frontend/engine-signing.pub` are the same value, so the release workflow's key check
    /// (which reads the file) also covers what the app verifies with. Skipped while the file is not in the tree.
    func testTheCompiledKeyMatchesTheKeyFile() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("engine-signing.pub")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { throw XCTSkip("no frontend/engine-signing.pub") }
        let key = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") } ?? ""
        XCTAssertEqual(EngineManifest.publicKey, key)
    }

    // MARK: The store

    private func makeStore() -> (EngineStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("engine-tests-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (EngineStore(root: root), root)
    }

    private func id(_ c: Character) -> String { String(repeating: c, count: 40) + "-0123456789ab" }

    private func writeTree(_ dir: URL, id: String?) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("dm/tools"), withIntermediateDirectories: true)
        try Data([0]).write(to: dir.appendingPathComponent("scripts/build_ipa_from_nsp.py"))
        try Data([0]).write(to: dir.appendingPathComponent("dm/tools/romfs_image.py"))
        try Data([0]).write(to: dir.appendingPathComponent(".upstream-ref"))
        if let id { try Data((id + "\n").utf8).write(to: dir.appendingPathComponent(EngineStore.idFile)) }
    }

    func testTheStoreKeepsOneTreePerEngineAndPrunesTheRest() throws {
        let (store, _) = makeStore()
        for c: Character in ["a", "b", "c"] { try writeTree(store.directory(for: id(c))!, id: id(c)) }
        XCTAssertTrue(store.isUsable(id("a")))
        XCTAssertEqual(store.prune(keeping: [id("a")]), [id("b"), id("c")])
        XCTAssertTrue(store.isUsable(id("a")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory(for: id("b"))!.path))
    }

    /// Prune removes only what the store itself makes: an engine folder, a scratch folder, a download.
    func testPruneLeavesEverythingElseAlone() throws {
        let (store, root) = makeStore()
        let fm = FileManager.default
        try writeTree(store.directory(for: id("a"))!, id: id("a"))
        for name in ["notes", "aaaaaaa", ".DS_Store-dir"] {
            try fm.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data([0]).write(to: root.appendingPathComponent("readme.txt"))
        try fm.createDirectory(at: root.appendingPathComponent(".tmp-123"), withIntermediateDirectories: true)
        try Data([0]).write(to: root.appendingPathComponent(".download-123.zip"))
        XCTAssertEqual(store.prune(keeping: []), [".download-123.zip", ".tmp-123", id("a")])
        for name in ["notes", "aaaaaaa", ".DS_Store-dir", "readme.txt"] {
            XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent(name).path), name)
        }
    }

    func testOnlyAnEngineIDBecomesAFolder() {
        let (store, _) = makeStore()
        XCTAssertNotNil(store.directory(for: id("a")))
        for bad in ["", "..", "../x", "aaaaaaa", id("a") + "/..", "/" + id("a"), id("a").uppercased()] {
            XCTAssertNil(store.directory(for: bad), bad)
            XCTAssertFalse(store.isUsable(bad), bad)
        }
    }

    func testAPartiallyUnpackedTreeIsNotUsable() throws {
        let (store, _) = makeStore()
        let dir = store.directory(for: id("d"))!
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try Data([0]).write(to: dir.appendingPathComponent("scripts/build_ipa_from_nsp.py"))
        XCTAssertFalse(store.isUsable(id("d")), "no dm/tools/romfs_image.py, no .upstream-ref, no .engine-id")
    }

    /// A tree is the engine its folder names only when its own .engine-id says so.
    func testATreeThatCallsItselfSomethingElseIsNotUsable() throws {
        let (store, _) = makeStore()
        try writeTree(store.directory(for: id("a"))!, id: id("b"))
        XCTAssertFalse(store.isUsable(id("a")))
        try writeTree(store.directory(for: id("c"))!, id: nil)
        XCTAssertFalse(store.isUsable(id("c")))
        XCTAssertNil(EngineStore.identity(of: store.directory(for: id("c"))!))
        XCTAssertEqual(EngineStore.identity(of: store.directory(for: id("a"))!), id("b"), "the newline is not part of the id")
    }
}
