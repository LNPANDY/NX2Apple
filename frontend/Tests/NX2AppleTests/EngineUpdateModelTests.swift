import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher

/// The engine in the model: that the release app never runs git, and the engine strings. What the app does with an update check's
/// outcome is `EngineSyncStore`, tested in NXModelTests. Nothing here touches the network or the store.
final class EngineUpdateModelTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/nonexistent-engine-bundle")

    /// A launcher built from the repository keeps git, the release app never touches it.
    @MainActor func testTheReleaseAppNeverRunsGit() {
        let m = BuildModel()
        m.engineSync.bundle = root
        m.repo.clone()
        m.repo.pull()
        m.repo.autoPull(3)
        m.repo.adoptAsGit()
        m.repo.checkForUpdates()
        XCTAssertFalse(m.repo.busy)
        XCTAssertEqual(m.repo.status, "")
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
