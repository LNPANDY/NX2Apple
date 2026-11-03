import CryptoKit
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher

/// Channels, asset URLs, the installer and the update check (EngineUpdater.swift in NXCore, EngineSyncStore in NXModel). The
/// archive is built here with `ditto`, so the unpack path is real. Nothing touches the network.
final class EngineUpdaterTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("engine-updater-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    // MARK: Channels

    func testEachChannelHasItsManifestURL() {
        XCTAssertEqual(EngineChannel.stable.manifestURL(version: "0.7.2")?.absoluteString,
                       "https://github.com/LNPANDY/NX2Apple/releases/download/v0.7.2/latest.json")
        XCTAssertEqual(EngineChannel.experimental.manifestURL(version: "0.7.2")?.absoluteString,
                       "https://github.com/LNPANDY/NX2Apple/releases/download/engine-experimental/latest.json",
                       "the experimental tag is fixed: the nightly job replaces the assets inside it")
    }

    func testAnAssetComesFromTheManifestSourcesWhenItNamesThem() {
        let url = EngineChannel.stable.assetURL("engine.zip", version: "0.7.2", sources: ["https://mirror.invalid/v0.7.2"])
        XCTAssertEqual(url?.absoluteString, "https://mirror.invalid/v0.7.2/engine.zip")
        let withSlash = EngineChannel.stable.assetURL("engine.zip", version: "0.7.2", sources: ["https://mirror.invalid/v0.7.2/"])
        XCTAssertEqual(withSlash?.absoluteString, "https://mirror.invalid/v0.7.2/engine.zip", "no doubled slash")
    }

    func testAnAssetFallsBackToTheChannelTag() {
        XCTAssertEqual(EngineChannel.stable.assetURL("engine.zip", version: "0.7.2", sources: [])?.absoluteString,
                       "https://github.com/LNPANDY/NX2Apple/releases/download/v0.7.2/engine.zip")
        XCTAssertEqual(EngineChannel.experimental.assetURL("engine.zip", version: "0.7.2", sources: [])?.absoluteString,
                       "https://github.com/LNPANDY/NX2Apple/releases/download/engine-experimental/engine.zip")
    }

    func testAnAssetIsTriedAtEverySourceAndThenOnGitHub() {
        let urls = EngineChannel.stable.assetURLs("engine.zip", version: "0.7.2",
                                                 sources: ["https://mirror.invalid/v0.7.2", EngineChannel.releaseBase + "v0.7.2/"])
        XCTAssertEqual(urls.map(\.absoluteString), ["https://mirror.invalid/v0.7.2/engine.zip",
                                                    "https://github.com/LNPANDY/NX2Apple/releases/download/v0.7.2/engine.zip"],
                       "GitHub once, in the place the manifest put it")
        XCTAssertEqual(EngineChannel.experimental.assetURLs("e.zip", version: "0.7.2", sources: ["https://mirror.invalid/x/"]).count, 2)
    }

    func testTheSignatureSitsNextToTheManifest() {
        XCTAssertEqual(EngineChannel.experimental.signatureURL(version: "0.7.2")?.absoluteString,
                       "https://github.com/LNPANDY/NX2Apple/releases/download/engine-experimental/latest.json.sig")
    }

    func testEverySwitchOfChannelIsWarnedAbout() {
        XCTAssertEqual(EngineChannel.stable.switchWarningKey(to: .experimental), "engine.switch.toExperimental")
        XCTAssertEqual(EngineChannel.experimental.switchWarningKey(to: .stable), "engine.switch.toStable")
        XCTAssertNil(EngineChannel.stable.switchWarningKey(to: .stable))
    }

    // MARK: Installing

    private func id(_ c: Character) -> String { String(repeating: c, count: 40) + "-0123456789ab" }

    /// A tree as the release publishes it: the files the launcher runs by path and its .engine-id, at the archive's root.
    private func makeTree(_ name: String = "tree", id: String? = nil, chain: String? = nil) throws -> URL {
        let fm = FileManager.default
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: dir.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("dm/tools"), withIntermediateDirectories: true)
        try Data("print()".utf8).write(to: dir.appendingPathComponent("scripts/build_ipa_from_nsp.py"))
        try Data([0]).write(to: dir.appendingPathComponent("dm/tools/romfs_image.py"))
        try Data("ee6648cb".utf8).write(to: dir.appendingPathComponent(".upstream-ref"))
        try Data(((id ?? self.id("a")) + "\n").utf8).write(to: dir.appendingPathComponent(".engine-id"))
        if let chain {
            try fm.createDirectory(at: dir.appendingPathComponent("dm/gfx/nvn"), withIntermediateDirectories: true)
            try Data("#pragma once\n#define DMSH_CHAIN \"\(chain)\"\n".utf8).write(to: dir.appendingPathComponent("dm/gfx/nvn/dmsh_chain.h"))
        }
        return dir
    }

    private func zip(_ source: URL) throws -> URL {
        let out = root.appendingPathComponent(UUID().uuidString + ".zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", source.path, out.path]
        try ditto.run(); ditto.waitUntilExit()
        XCTAssertEqual(ditto.terminationStatus, 0, "test archive")
        return out
    }

    private var store: EngineStore { EngineStore(root: root.appendingPathComponent("engine")) }

    func testInstallingATreeMakesItUsable() throws {
        let archive = try zip(makeTree(id: id("a")))
        let dest = try EngineInstaller.install(zip: archive, engineID: id("a"), store: store)
        XCTAssertEqual(dest, store.directory(for: id("a")))
        XCTAssertTrue(store.isUsable(id("a")))
        XCTAssertNoThrow(try EngineInstaller.install(zip: archive, engineID: id("a"), store: store), "a second install is a no-op")
        let left = try FileManager.default.contentsOfDirectory(atPath: store.root.path)
        XCTAssertEqual(left, [id("a")], "no scratch folder stays behind")
    }

    /// The archive has to be the engine the manifest names, or the store would hold the wrong files under its name.
    func testATreeWithAnotherIdentityIsRefused() throws {
        let archive = try zip(makeTree(id: id("b")))
        XCTAssertThrowsError(try EngineInstaller.install(zip: archive, engineID: id("a"), store: store)) {
            XCTAssertEqual($0 as? EngineInstaller.Failure, .wrongEngine(id("b")))
        }
        XCTAssertFalse(store.isUsable(id("a")))
        XCTAssertThrowsError(try EngineInstaller.install(zip: archive, engineID: "../evil", store: store)) {
            XCTAssertEqual($0 as? EngineInstaller.Failure, .badID("../evil"))
        }
    }

    /// A release may wrap the tree in one folder. The installer takes that level.
    func testAWrappedTreeIsFound() throws {
        let wrapped = root.appendingPathComponent("wrap", isDirectory: true)
        try FileManager.default.createDirectory(at: wrapped, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: try makeTree(id: id("d")), to: wrapped.appendingPathComponent("engine"))
        try EngineInstaller.install(zip: try zip(wrapped), engineID: id("d"), store: store)
        XCTAssertTrue(store.isUsable(id("d")))
    }

    func testAnIncompleteTreeIsRefusedAndNothingIsLeftBehind() throws {
        let broken = root.appendingPathComponent("broken", isDirectory: true)
        try FileManager.default.createDirectory(at: broken.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try Data([0]).write(to: broken.appendingPathComponent("scripts/build_ipa_from_nsp.py"))   // no dm/tools, no .upstream-ref
        XCTAssertThrowsError(try EngineInstaller.install(zip: try zip(broken), engineID: id("e"), store: store)) { error in
            guard case EngineInstaller.Failure.incomplete = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory(for: id("e"))!.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.root.path), [])
    }

    func testSomethingThatIsNotAnArchiveFails() throws {
        let notZip = root.appendingPathComponent("nope.zip")
        try Data("not a zip".utf8).write(to: notZip)
        XCTAssertThrowsError(try EngineInstaller.install(zip: notZip, engineID: id("f"), store: store)) { error in
            XCTAssertEqual(error as? EngineInstaller.Failure, .unpack)
        }
    }

    /// A damaged folder under the right name (an older launcher, a crash) is replaced, not trusted.
    func testADamagedTreeUnderTheSameNameIsReplaced() throws {
        let dir = store.directory(for: id("a"))!
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([0]).write(to: dir.appendingPathComponent("junk"))
        try EngineInstaller.install(zip: try zip(makeTree(id: id("a"))), engineID: id("a"), store: store)
        XCTAssertTrue(store.isUsable(id("a")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("junk").path))
    }

    // MARK: The engine in the app

    func testTheAppsEngineIsFoundAndCopiedIntoTheStore() throws {
        let resources = root.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        XCTAssertNil(EngineBundle.tree(in: resources), "a launcher built from the repository has none")
        XCTAssertNil(EngineBundle.tree(in: nil))
        _ = try makeTree("Resources/engine", id: id("a"))
        let bundled = try XCTUnwrap(EngineBundle.tree(in: resources))
        try EngineInstaller.seed(from: bundled, engineID: id("a"), store: store)
        XCTAssertTrue(store.isUsable(id("a")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundled.appendingPathComponent(".engine-id").path), "the app is left as it was")
        XCTAssertThrowsError(try EngineInstaller.seed(from: bundled, engineID: id("b"), store: store)) {
            XCTAssertEqual($0 as? EngineInstaller.Failure, .wrongEngine(id("a")))
        }
    }

    // MARK: Remembering the choice

    func testTheSelectionSurvivesAndRemembersWhereItCameFrom() {
        let suite = UserDefaults(suiteName: "engine-selection-" + UUID().uuidString)!
        var s = EngineSelection.load(suite)
        XCTAssertEqual(s.channel, .stable, "stable by default")
        XCTAssertEqual(s.engineID, "")
        XCTAssertEqual(s.kept, [])

        s.channel = .experimental
        s.switched(to: id("a"), version: "0.7.3-experimental"); s.save(suite)
        XCTAssertEqual(EngineSelection.load(suite).engineID, id("a"))
        XCTAssertEqual(EngineSelection.load(suite).channel, .experimental)
        XCTAssertEqual(EngineSelection.load(suite).previousID, "", "nothing came before")

        s.switched(to: id("b"), version: "0.7.4-experimental"); s.save(suite)
        let back = EngineSelection.load(suite)
        XCTAssertEqual(back.engineID, id("b"))
        XCTAssertEqual(back.version, "0.7.4-experimental")
        XCTAssertEqual(back.previousID, id("a"), "the engine we came from is kept")
        XCTAssertEqual(back.kept, [id("a"), id("b")])

        s.switched(to: id("b"), version: "0.7.4-experimental")
        XCTAssertEqual(s.previousID, id("a"), "the same engine again does not forget the previous one")
    }

    // MARK: Checking and downloading

    /// Serves files from a dictionary and counts what was asked for. A missing URL is a 404, `failing` is offline.
    private final class FakeTransport: EngineTransport {
        var files: [String: Data] = [:]
        var failing = false
        var requested: [String] = []
        var downloads: [String] = []
        func data(from url: URL) -> EngineFetch<Data> {
            requested.append(url.absoluteString)
            if failing { return .failed }
            return files[url.absoluteString].map { .ok($0) } ?? .missing
        }
        func download(from url: URL, to destination: URL) -> Bool {
            downloads.append(url.absoluteString)
            guard !failing, let data = files[url.absoluteString] else { return false }
            return (try? data.write(to: destination)) != nil
        }
    }

    private let stableBase = "https://github.com/LNPANDY/NX2Apple/releases/download/v0.7.3/"
    private let experimentalBase = "https://github.com/LNPANDY/NX2Apple/releases/download/engine-experimental/"

    private func manifest(id: String, channel: String = "stable", version: String = "0.7.3", digest: String,
                          size: Int? = nil, sources: [String] = []) -> Data {
        let pin = String(id.prefix(40))
        let sizeField = size.map { ",\"size\":\($0)" } ?? ""
        let list = "[" + sources.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        return Data("""
        {"version":"\(version)","pin":"\(pin)","engine_id":"\(id)","channel":"\(channel)",
         "engine":{"asset":"NX2Apple-engine.zip","sha256":"\(digest)"\(sizeField)},"sources":\(list)}
        """.utf8)
    }

    /// A release with an engine archive of `id`: the manifest and the zip at `base`.
    private func publish(_ t: FakeTransport, id: String, channel: String = "stable", base: String, sources: [String] = []) throws -> Data {
        let archive = try Data(contentsOf: zip(makeTree("pub-" + UUID().uuidString, id: id)))
        let digest = AppUpdate.sha256(of: try write(archive))!
        let m = manifest(id: id, channel: channel, version: channel == "stable" ? "0.7.3" : "0.7.3-experimental",
                         digest: digest, size: archive.count, sources: sources)
        t.files[base + "latest.json"] = m
        for b in (sources.isEmpty ? [base] : sources) { t.files[b + "NX2Apple-engine.zip"] = archive }
        return m
    }

    private func write(_ data: Data) throws -> URL {
        let url = root.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        return url
    }

    private func run(_ t: FakeTransport, channel: EngineChannel = .stable, current: String = "", bundled: URL? = nil,
                     publicKey: String = "", install: Bool = true) -> EngineUpdate.Outcome {
        EngineUpdate.run(channel: channel, appVersion: "0.7.3", current: current, store: store, bundled: bundled,
                         publicKey: publicKey, install: install, transport: t)
    }

    func testANewEngineIsDownloadedVerifiedAndInstalled() throws {
        let t = FakeTransport()
        _ = try publish(t, id: id("a"), base: stableBase)
        XCTAssertEqual(run(t), .installed(.init(id: id("a"), version: "0.7.3"), .download))
        XCTAssertTrue(store.isUsable(id("a")))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.root.path), [id("a")], "the download is gone")
        XCTAssertEqual(run(t, current: id("a")), .current(.init(id: id("a"), version: "0.7.3")))
    }

    func testTheExperimentalChannelReadsItsOwnTag() throws {
        let t = FakeTransport()
        _ = try publish(t, id: id("b"), channel: "experimental", base: experimentalBase)
        XCTAssertEqual(run(t, channel: .experimental), .installed(.init(id: id("b"), version: "0.7.3-experimental"), .download))
    }

    func testWithAutomaticUpdatesOffANewEngineIsOnlyOffered() throws {
        let t = FakeTransport()
        _ = try publish(t, id: id("a"), base: stableBase)
        XCTAssertEqual(run(t, current: id("c"), install: false), .available(.init(id: id("a"), version: "0.7.3")))
        XCTAssertTrue(t.downloads.isEmpty)
    }

    /// A mirror that serves other bytes is passed over, and the next source is tried.
    func testAWrongArchiveFromOneSourceFallsBackToTheNext() throws {
        let t = FakeTransport()
        let mirror = "https://mirror.invalid/v0.7.3/"
        _ = try publish(t, id: id("a"), base: stableBase, sources: [mirror, stableBase])
        t.files[mirror + "NX2Apple-engine.zip"] = Data("tampered".utf8)
        XCTAssertEqual(run(t), .installed(.init(id: id("a"), version: "0.7.3"), .download))
        XCTAssertEqual(t.downloads, [mirror + "NX2Apple-engine.zip", stableBase + "NX2Apple-engine.zip"])
    }

    func testAnArchiveThatMatchesNoDigestInstallsNothing() throws {
        let t = FakeTransport()
        _ = try publish(t, id: id("a"), base: stableBase)
        t.files[stableBase + "NX2Apple-engine.zip"] = Data("tampered".utf8)
        XCTAssertEqual(run(t), .failed(.digest))
        XCTAssertFalse(store.isUsable(id("a")))
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: store.root.path)) ?? [], [])
    }

    func testNoArchiveAnywhereIsADownloadFailure() throws {
        let t = FakeTransport()
        _ = try publish(t, id: id("a"), base: stableBase)
        t.files[stableBase + "NX2Apple-engine.zip"] = nil
        XCTAssertEqual(run(t), .failed(.download))
    }

    func testOfflineIsANetworkFailure() {
        let t = FakeTransport()
        t.failing = true
        XCTAssertEqual(run(t), .failed(.network))
    }

    /// A release from before engine updates has no latest.json. Its stable engine is the one in the app.
    func testAReleaseWithoutAManifestUsesTheAppsEngine() throws {
        let resources = root.appendingPathComponent("Resources", isDirectory: true)
        _ = try makeTree("Resources/engine", id: id("a"))
        let bundled = try XCTUnwrap(EngineBundle.tree(in: resources))
        let t = FakeTransport()
        XCTAssertEqual(run(t, bundled: bundled), .installed(.init(id: id("a"), version: "0.7.3"), .bundle))
        XCTAssertEqual(run(t, channel: .experimental, bundled: bundled), .failed(.noManifest),
                       "experimental has nothing to fall back on")
    }

    /// The manifest names the engine the app already carries: it is copied, not downloaded.
    func testTheAppsOwnEngineIsNotDownloadedAgain() throws {
        let resources = root.appendingPathComponent("Resources", isDirectory: true)
        _ = try makeTree("Resources/engine", id: id("a"))
        let t = FakeTransport()
        _ = try publish(t, id: id("a"), base: stableBase)
        XCTAssertEqual(run(t, bundled: EngineBundle.tree(in: resources)), .installed(.init(id: id("a"), version: "0.7.3"), .bundle))
        XCTAssertTrue(t.downloads.isEmpty)
    }

    func testAManifestOfTheOtherChannelIsRefused() throws {
        let t = FakeTransport()
        _ = try publish(t, id: id("a"), channel: "experimental", base: stableBase)
        XCTAssertEqual(run(t), .failed(.wrongChannel("experimental")))
    }

    func testABrokenManifestIsRefused() {
        let t = FakeTransport()
        t.files[stableBase + "latest.json"] = Data("{}".utf8)
        XCTAssertEqual(run(t), .failed(.badManifest(.notJSON)))
    }

    /// With a key built in, the signature decides. Without one (today) the manifest installs unsigned.
    func testWithAKeyOnlyASignedManifestInstalls() throws {
        let key = Curve25519.Signing.PrivateKey()
        let pub = key.publicKey.rawRepresentation.base64EncodedString()
        let t = FakeTransport()
        let m = try publish(t, id: id("a"), base: stableBase)
        XCTAssertEqual(run(t, publicKey: pub), .failed(.unsigned(.absent)))
        t.files[stableBase + "latest.json.sig"] = Data(try Curve25519.Signing.PrivateKey().signature(for: m).base64EncodedString().utf8)
        XCTAssertEqual(run(t, publicKey: pub), .failed(.unsigned(.invalid)))
        XCTAssertTrue(t.downloads.isEmpty, "nothing is fetched for a manifest that is refused")
        t.files[stableBase + "latest.json.sig"] = Data((try key.signature(for: m).base64EncodedString() + "\n").utf8)
        XCTAssertEqual(run(t, publicKey: pub), .installed(.init(id: id("a"), version: "0.7.3"), .download))
    }

    // MARK: The shader chain

    func testAChangedShaderChainIsReported() throws {
        let old = try makeTree("old", id: id("a"), chain: "v41"), same = try makeTree("same", id: id("b"), chain: "v41")
        let new = try makeTree("new", id: id("c"), chain: "v42"), none = try makeTree("none", id: id("d"))
        XCTAssertNil(EngineUpdate.chainChange(from: old.path, to: same.path))
        let change = try XCTUnwrap(EngineUpdate.chainChange(from: old.path, to: new.path))
        XCTAssertEqual(change.old, "v41")
        XCTAssertEqual(change.new, "v42")
        XCTAssertNil(EngineUpdate.chainChange(from: none.path, to: new.path), "no chain to compare with")
    }
}
