import XCTest
@testable import NSPortBuilder

/// Channels, asset URLs and the installer (EngineUpdater.swift). The archive is built here with `ditto`,
/// so the unpack path is real; nothing touches the network.
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

    // MARK: Installing

    /// A tree as the release publishes it: the files the launcher runs by path, at the archive's root.
    private func makeTree(_ name: String = "tree") throws -> URL {
        let fm = FileManager.default
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: dir.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("dm/tools"), withIntermediateDirectories: true)
        try Data("print()".utf8).write(to: dir.appendingPathComponent("scripts/build_ipa_from_nsp.py"))
        try Data([0]).write(to: dir.appendingPathComponent("dm/tools/romfs_image.py"))
        try Data("ee6648cb".utf8).write(to: dir.appendingPathComponent(".upstream-ref"))
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

    func testInstallingATreeMakesItUsableAndKeepsTheChosenPins() throws {
        let store = EngineStore(root: root.appendingPathComponent("engine"))
        let archive = try zip(makeTree())

        try EngineInstaller.install(zip: archive, pin: "aaaaaaa", store: store)
        XCTAssertTrue(store.isUsable("aaaaaaa"))

        try EngineInstaller.install(zip: archive, pin: "bbbbbbb", store: store, keeping: "aaaaaaa")
        XCTAssertTrue(store.isUsable("bbbbbbb"))
        XCTAssertTrue(store.isUsable("aaaaaaa"), "the previous pin stays for a build that is still running")

        try EngineInstaller.install(zip: archive, pin: "ccccccc", store: store, keeping: "bbbbbbb")
        XCTAssertTrue(store.isUsable("ccccccc"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory(for: "aaaaaaa").path), "older trees are pruned")
    }

    /// A release may wrap the tree in one folder; the installer takes that level.
    func testAWrappedTreeIsFound() throws {
        let store = EngineStore(root: root.appendingPathComponent("engine"))
        let wrapped = root.appendingPathComponent("wrap", isDirectory: true)
        try FileManager.default.createDirectory(at: wrapped, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: try makeTree(), to: wrapped.appendingPathComponent("engine"))
        try EngineInstaller.install(zip: try zip(wrapped), pin: "ddddddd", store: store)
        XCTAssertTrue(store.isUsable("ddddddd"))
    }

    func testAnIncompleteTreeIsRefusedAndNothingIsLeftBehind() throws {
        let store = EngineStore(root: root.appendingPathComponent("engine"))
        let broken = root.appendingPathComponent("broken", isDirectory: true)
        try FileManager.default.createDirectory(at: broken.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try Data([0]).write(to: broken.appendingPathComponent("scripts/build_ipa_from_nsp.py"))   // no dm/tools, no .upstream-ref
        XCTAssertThrowsError(try EngineInstaller.install(zip: try zip(broken), pin: "eeeeeee", store: store)) { error in
            guard case EngineInstaller.Failure.incomplete = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory(for: "eeeeeee").path))
    }

    func testSomethingThatIsNotAnArchiveFails() throws {
        let store = EngineStore(root: root.appendingPathComponent("engine"))
        let notZip = root.appendingPathComponent("nope.zip")
        try Data("not a zip".utf8).write(to: notZip)
        XCTAssertThrowsError(try EngineInstaller.install(zip: notZip, pin: "fffffff", store: store)) { error in
            XCTAssertEqual(error as? EngineInstaller.Failure, .unpack)
        }
    }

    // MARK: Remembering the choice

    func testTheSelectionSurvivesAndRemembersWhereItCameFrom() {
        let suite = UserDefaults(suiteName: "engine-selection-" + UUID().uuidString)!
        var s = EngineSelection.load(suite)
        XCTAssertEqual(s.channel, .stable, "stable by default")
        XCTAssertEqual(s.pin, "")

        s.channel = .experimental
        s.switched(to: "aaaaaaa"); s.save(suite)
        XCTAssertEqual(EngineSelection.load(suite).pin, "aaaaaaa")
        XCTAssertEqual(EngineSelection.load(suite).channel, .experimental)

        s.switched(to: "bbbbbbb"); s.save(suite)
        let back = EngineSelection.load(suite)
        XCTAssertEqual(back.pin, "bbbbbbb")
        XCTAssertEqual(back.previousPin, "aaaaaaa", "the pin we came from is kept")
    }
}
