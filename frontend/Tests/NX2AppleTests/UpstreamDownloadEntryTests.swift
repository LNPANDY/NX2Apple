import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXModel
@testable import NXLauncher

/// Settings' engine pop-up offers "Download" for an external engine that is not there (LNPANDY/NX2Apple#1474): MacNativeGames, and
/// S2Arm only with its switch on. An installed engine is a plain entry, never a Download one.
@MainActor final class UpstreamDownloadEntryTests: IsolatedDefaultsTestCase {
    private func entries(_ build: BuildStore, _ stores: LauncherStores) -> [String] {
        UpstreamBuilderRow.options(build, stores.localizer).map(\.value)
    }

    func testAMissingEngineIsADownloadEntryAndAnInstalledOneIsNot() throws {
        let oldMNG = MacNativeGamesBuilder.featureEnabled, oldS2 = S2ArmBuilder.featureEnabled
        MacNativeGamesBuilder.featureEnabled = true; S2ArmBuilder.featureEnabled = false
        defer { MacNativeGamesBuilder.featureEnabled = oldMNG; S2ArmBuilder.featureEnabled = oldS2 }
        let stores = LauncherStores(defaults: testDefaults)
        let build = stores.build
        build.macNativeGamesPath = ""; build.s2armPath = ""; build.buildUpstream = .nxnative

        // not there: a Download entry, and S2Arm stays hidden with its switch off
        XCTAssertTrue(entries(build, stores).contains("download.macnativegames"))
        XCTAssertFalse(entries(build, stores).contains(EngineUpstreamKind.macNativeGames.rawValue))
        XCTAssertFalse(entries(build, stores).contains { $0.hasSuffix("s2arm") })
        XCTAssertEqual(UpstreamBuilderRow.downloadKind("download.macnativegames"), .macNativeGames)
        XCTAssertNil(UpstreamBuilderRow.downloadKind(EngineUpstreamKind.macNativeGames.rawValue))

        // with the switch on, S2Arm is offered too
        S2ArmBuilder.featureEnabled = true
        XCTAssertTrue(entries(build, stores).contains("download.s2arm"))
        S2ArmBuilder.featureEnabled = false

        // being fetched: no second Download entry
        build.setUpstreamDownloadForGallery(.macNativeGames, .downloading(fraction: nil, progressText: ""))
        XCTAssertFalse(entries(build, stores).contains("download.macnativegames"))
        build.cancelUpstreamDownload(.macNativeGames)

        // installed: a plain entry, no Download
        let tree = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tree) }
        for marker in EngineUpstream.descriptor(for: .macNativeGames).markerPaths {
            let file = tree.appendingPathComponent(marker)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
        }
        build.macNativeGamesPath = tree.path
        XCTAssertTrue(build.macNativeGamesInstalled)
        XCTAssertTrue(entries(build, stores).contains(EngineUpstreamKind.macNativeGames.rawValue))
        XCTAssertFalse(entries(build, stores).contains("download.macnativegames"))
    }

    func testDownloadingIsAllowedForAnyTitleButChoosingStaysWithTheFive() throws {
        let oldMNG = MacNativeGamesBuilder.featureEnabled
        MacNativeGamesBuilder.featureEnabled = true
        defer { MacNativeGamesBuilder.featureEnabled = oldMNG }
        let stores = LauncherStores(defaults: testDefaults)
        let build = stores.build
        build.macNativeGamesPath = ""; build.buildUpstream = .nxnative
        let nsp = FileManager.default.temporaryDirectory.appendingPathComponent("Game [0100000000010000].nsp")
        try Data().write(to: nsp)
        defer { try? FileManager.default.removeItem(at: nsp) }
        build.updateSlot("base") { $0.paths = [nsp.path] }
        XCTAssertTrue(build.isMNGBlockedByCurrentGame)
        // the Download entry is offered and not dimmed, the engine itself would be
        XCTAssertTrue(entries(build, stores).contains("download.macnativegames"))
        let dimmed: Set<String> = UpstreamBuilderRow.disabledValues(build)
        XCTAssertFalse(dimmed.contains("download.macnativegames"))
        XCTAssertTrue(dimmed.contains(EngineUpstreamKind.macNativeGames.rawValue))
    }
}
