import SwiftUI
import XCTest
import NXModel
@testable import NXCore
@testable import NXLauncher
@testable import NX2Apple

@MainActor final class OnboardingImportTests: IsolatedDefaultsTestCase {
    func testReadyHandoffAdvancesAndBackCancelsIt() {
        for goBack in [false, true] {
            var state = MockOnboardingDriver.sampleState
            state.step = .done; state.done = .ready; state.platform = .selected(.mac)
            state.games = .found([.init(id: "sample", title: "Sample", version: "", needsKeys: false)])
            let driver = MockOnboardingDriver(state: state, animated: false)
            let pad = LauncherGamepad(observeSystem: false, appIsActive: { true })
            let host = NSHostingView(rootView: OnboardingView(driver: driver, lang: .en, gamepad: pad))
            let window = OffscreenWindow(size: .init(width: 900, height: 680))
            window.contentView = host; window.orderFront(nil)
            defer { pad.deactivate(); window.contentView = nil; window.orderOut(nil); window.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            if goBack { pad.perform(.b) }
            RunLoop.main.run(until: Date().addingTimeInterval(1.4))
            XCTAssertEqual(driver.state.exit, goBack ? nil : .library)
            if goBack { XCTAssertEqual(driver.state.step, .games) }
        }
    }

    func testSharedCardsReflowAndControllerSelectionQueuesOnlyEligibleGames() throws {
        for size in [CGSize(width: 900, height: 680), CGSize(width: 1280, height: 900)] {
            for dark in [false, true] {
                var state = MockOnboardingDriver.sampleState
                state.step = .games; state.keys = .skipped; state.platform = .selected(.both)
                state.games = .found((0..<9).map {
                    OnboardingGame(id: "game\($0)", title: "Game \($0) with a long title", version: "1.0", needsKeys: $0 == 0)
                })
                let driver = MockOnboardingDriver(state: state, animated: false)
                let focus = PadFocus(), pad = LauncherGamepad(observeSystem: false, appIsActive: { true })
                let host = NSHostingView(rootView: OnboardingView(driver: driver, lang: .en, gamepad: pad, padFocus: focus)
                    .environment(\.colorScheme, dark ? .dark : .light))
                let window = OffscreenWindow(size: size)
                window.contentView = host; window.orderFront(nil)
                defer { pad.deactivate(); window.contentView = nil; window.orderOut(nil); window.close() }
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                XCTAssertNil(focus.frame(of: "onboarding.game.game0"), "encrypted games cannot be selected without keys")
                XCTAssertNil(focus.frame(of: "onboarding.games.build"))
                let cards = focus.frames["onboarding", default: []].filter { $0.id.hasPrefix("onboarding.game.") }
                XCTAssertFalse(cards.isEmpty)
                for card in cards {
                    XCTAssertGreaterThan(card.frame.width, 190)
                    XCTAssertLessThanOrEqual(card.frame.maxX, size.width - 39)
                }
                if let path = ProcessInfo.processInfo.environment["NX_IMPORT_CAPTURE_DIR"] {
                    let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: rep)
                    let dir = URL(fileURLWithPath: path)
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("import-top-\(Int(size.width))-\(dark ? "dark" : "light").png"))
                }
                focus.show(default: "onboarding.game.game1"); pad.perform(.a)
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                XCTAssertNotNil(focus.frame(of: "onboarding.games.build"))
                if let path = ProcessInfo.processInfo.environment["NX_IMPORT_CAPTURE_DIR"] {
                    let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: rep)
                    let dir = URL(fileURLWithPath: path)
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("import-\(Int(size.width))-\(dark ? "dark" : "light").png"))
                }
                focus.focused = "onboarding.games.build"; pad.perform(.a)
                XCTAssertEqual(driver.state.queuedGameIDs, ["game1"])
                XCTAssertEqual(driver.state.step, .done)
            }
        }
    }

    func testRealDriverUsesSharedQueueSnapshotsAndNeverStartsBeforeReview() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let stores = LauncherStores(defaults: TestDefaults.make("onboarding.import"))
        var env = OnboardingEnvironment(); env.defaults = TestDefaults.make("onboarding.import.driver")
        let driver = LiveOnboardingDriver(stores: stores, library: GameLibrary(file: root.appendingPathComponent("library.json")), env: env)
        driver.state.step = .games; driver.state.platform = .selected(.both); driver.state.keys = .skipped
        var keyless = LibraryGame(titleID: "0100000000000001", name: "Keyless")
        keyless.inputs = [GameLibrary.folderInput: [root.appendingPathComponent("game.nup").path]]
        keyless.outputDirectory = root.path
        driver.importedGames = [keyless]
        driver.state.games = .found([
            .init(id: keyless.titleID, title: keyless.name, version: "", needsKeys: false),
            .init(id: "locked", title: "Encrypted", version: "", needsKeys: true)
        ])
        driver.buildGames([keyless.titleID, "locked", "not-imported"])
        XCTAssertEqual(stores.queue.games.count, 1)
        XCTAssertEqual(stores.queue.entries.map(\.target), [BuildTarget.mac, BuildTarget.ios])
        XCTAssertEqual(Set(stores.queue.entries.map(\.batch)).count, 1)
        XCTAssertTrue(stores.queue.entries.allSatisfy { $0.status == .queued && $0.gameFolder == keyless.inputs[GameLibrary.folderInput]?.first })
        XCTAssertFalse(stores.queue.active)
        XCTAssertFalse(stores.build.running)
        XCTAssertEqual(driver.state.queuedGameIDs, [keyless.titleID])
        XCTAssertEqual(driver.state.step, .done)
        driver.state.step = .games
        driver.buildGames([keyless.titleID])
        XCTAssertEqual(stores.queue.entries.count, 2, "duplicate game/platform selections merge")
    }
}
