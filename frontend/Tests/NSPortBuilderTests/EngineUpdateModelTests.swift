import XCTest
@testable import NSPortBuilder

/// The engine in the model (EngineUpdateModel.swift): what the release app does with an update check's outcome, and
/// that it never runs git. Nothing here touches the network or the store.
final class EngineUpdateModelTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/nonexistent-engine-bundle")

    private func id(_ c: Character) -> String { String(repeating: c, count: 40) + "-0123456789ab" }

    /// A launcher built from the repository keeps git, the release app never touches it.
    func testTheReleaseAppNeverRunsGit() {
        let m = BuildModel()
        m.engineBundle = root
        m.cloneRepo()
        m.pullRepo()
        m.autoPull(3)
        m.adoptRepoAsGit()
        m.checkRepoUpdates()
        XCTAssertFalse(m.repoBusy)
        XCTAssertEqual(m.repoStatus, "")
    }

    func testAnEngineInstalledDuringABuildWaits() {
        let m = BuildModel()
        m.lang = .en
        m.engineBundle = root
        m.running = true
        let path = m.repoPath
        m.applyEngineOutcome(.installed(.init(id: id("a"), version: "0.7.4"), .download), channel: .stable, quiet: false)
        XCTAssertEqual(m.repoPath, path, "the running build keeps its tools")
        XCTAssertEqual(m.pendingEngine?.engine.id, id("a"))
        XCTAssertEqual(m.engineStatus, String(format: L10n.string("engine.waitsForBuild", .en), "0.7.4"))
        m.checkEngineUpdate()
        XCTAssertFalse(m.engineBusy, "no check while a build runs")
    }

    func testTheLaunchCheckIsQuietWhenOffline() {
        let m = BuildModel()
        m.lang = .en
        m.applyEngineOutcome(.failed(.network), channel: .stable, quiet: true)
        XCTAssertEqual(m.engineStatus, "")
        m.applyEngineOutcome(.failed(.digest), channel: .stable, quiet: true)
        XCTAssertEqual(m.engineStatus, L10n.string("engine.fail.digest", .en))
        m.applyEngineOutcome(.failed(.noManifest), channel: .experimental, quiet: false)
        XCTAssertEqual(m.engineStatus, "The Experimental channel has no engine for this app version yet")
    }

    func testChangingTheChannelAsksFirst() {
        let m = BuildModel()
        m.engineBundle = root
        m.engineSelection.channel = .stable
        m.requestEngineChannel(.stable)
        XCTAssertNil(m.confirmingChannel, "the same channel asks nothing")
        m.requestEngineChannel(.experimental)
        XCTAssertEqual(m.confirmingChannel, .experimental)
        XCTAssertEqual(m.engineSelection.channel, .stable, "nothing changes before the answer")
        m.cancelEngineChannel()
        XCTAssertNil(m.confirmingChannel)
        XCTAssertEqual(m.engineSelection.channel, .stable)
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
