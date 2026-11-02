import XCTest
@testable import NX2Apple
@testable import NXCore
import NXModel
@testable import NXLauncher

/// The engine in the model: that the release app never runs git, and the engine strings. What the app does with an update check's
/// outcome is `EngineSyncStore`, tested in NXModelTests. Nothing here touches the network or the store.
@MainActor final class EngineUpdateModelTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/nonexistent-engine-bundle")

    /// A launcher built from the repository keeps git, the release app never touches it.
    @MainActor func testTheReleaseAppNeverRunsGit() {
        let mStores = LauncherStores(); let m = mStores.build
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
}
