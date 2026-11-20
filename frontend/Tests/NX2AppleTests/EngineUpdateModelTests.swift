import XCTest
@testable import NX2Apple
@testable import NXCore
import NXModel
@testable import NXLauncher

/// The engine in the model: that the release app never runs git, and the engine strings. What the app does with an update check's
/// outcome is `EngineSyncStore`, tested in NXModelTests. Nothing here touches the network or the store.
@MainActor final class EngineUpdateModelTests: IsolatedDefaultsTestCase {
    private let root = URL(fileURLWithPath: "/nonexistent-engine-bundle")

    /// A launcher built from the repository keeps git, the release app never touches it.
    @MainActor func testTheReleaseAppNeverRunsGit() {
        let mStores = LauncherStores(defaults: testDefaults); let m = mStores.build
        mStores.engineSync.bundle = root
        mStores.repo.clone()
        mStores.repo.pull()
        mStores.repo.autoPull(3)
        mStores.repo.adoptAsGit()
        mStores.repo.checkForUpdates()
        XCTAssertFalse(mStores.repo.busy)
        XCTAssertEqual(mStores.repo.status, "")
    }

    // MARK: Strings

    func testEveryEngineStringIsTranslated() {
        let failures: [EngineUpdate.Failure] = [.network, .noManifest, .unsigned(.absent), .badManifest(.notJSON),
                                                .wrongChannel("x"), .download, .digest, .install(.move)]
        for key in failures.map(EngineUpdate.key) + ["engine.switch.toExperimental", "engine.switch.toStable"] {
            for lang: Lang in [.zh, .en, .sv, .de] { XCTAssertNotEqual(L10n.string(key, lang), key, key) }
        }
        for c in EngineChannel.allCases { XCTAssertNotNil(L10n.table[c.labelKey], c.labelKey) }
        XCTAssertEqual(L10n.string("engine.channel.experimental", .zh), "实验版")
    }

    @MainActor func testSwitchingRepoPathRefreshesBuiltInNxnativeLocalVersion() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("nx2apple-repo-refresh-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: tmp) }
        let oldTree = tmp.appendingPathComponent("old-engine", isDirectory: true)
        let newTree = tmp.appendingPathComponent("new-engine", isDirectory: true)
        try FileManager.default.createDirectory(at: oldTree, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newTree, withIntermediateDirectories: true)
        try Data("94a0944755da1a443f42651bf7ee49ab24ed5ee5\n".utf8).write(to: oldTree.appendingPathComponent(".upstream-ref"))
        try Data("0b5fd6020093407af8bb5ad166e78e00bd2b7242\n".utf8).write(to: newTree.appendingPathComponent(".upstream-ref"))

        let stores = LauncherStores(defaults: testDefaults)
        stores.repo.path = oldTree.path
        stores.build.refreshUpstreamLocalVersion(for: .nxnative)
        XCTAssertEqual(stores.build.upstreamLocalVersions[.nxnative]?.version, "94a0944")

        stores.repo.path = newTree.path
        stores.build.refreshUpstreamLocalVersion(for: .nxnative)
        XCTAssertEqual(stores.build.upstreamLocalVersions[.nxnative]?.version, "0b5fd60")
        XCTAssertEqual(stores.build.upstreamVersionBadge(.nxnative), "0b5fd60")

        // Also verify EngineSyncStore switching via LauncherStores refreshes upstreamLocalVersions[.nxnative] automatically.
        let storeRoot = tmp.appendingPathComponent("engines", isDirectory: true)
        let eid = "1111111111111111111111111111111111111111-0123456789ab"
        let switchedDir = storeRoot.appendingPathComponent(eid, isDirectory: true)
        try FileManager.default.createDirectory(at: switchedDir.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: switchedDir.appendingPathComponent("dm/tools"), withIntermediateDirectories: true)
        try Data([0]).write(to: switchedDir.appendingPathComponent("scripts/build_ipa_from_nsp.py"))
        try Data([0]).write(to: switchedDir.appendingPathComponent("dm/tools/romfs_image.py"))
        try Data("1111111111111111111111111111111111111111\n".utf8).write(to: switchedDir.appendingPathComponent(".upstream-ref"))
        try Data((eid + "\n").utf8).write(to: switchedDir.appendingPathComponent(".engine-id"))
        let customSync = EngineSyncStore(
            localizer: stores.localizer, runner: stores.runner, repo: stores.repo, python: stores.dependencies,
            engineStore: EngineStore(root: storeRoot), bundle: root, defaults: testDefaults,
            setRepoPath: { stores.repo.path = $0; stores.build.refreshUpstreamLocalVersion(for: .nxnative) }
        )
        customSync.switchEngine(to: EngineUpdate.Engine(id: eid, version: "1.5.0"), channel: .stable, announce: false)
        XCTAssertEqual(stores.build.upstreamLocalVersions[.nxnative]?.version, "1111111")
    }
}
