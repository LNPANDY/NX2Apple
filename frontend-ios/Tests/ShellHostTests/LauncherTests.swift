import Foundation
import Observation
import Testing
@testable import ShellHost

/// Collects what the stub logs.
final class LogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}

func sampleGame() throws -> LaunchableGame {
    let entry = GameCatalogue.read(directory: Fixtures.gamesURL.appendingPathComponent(Fixtures.orbit))
    return LaunchableGame(titleID: entry.id, name: entry.title, manifest: try #require(entry.manifest), directory: entry.directory,
                          frameworkURL: try #require(entry.frameworkURL), dataURL: URL(fileURLWithPath: "/tmp/data"),
                          appFolder: URL(fileURLWithPath: "/tmp/app"), environment: ["DM_OPMODE": "1"], cloudSavesURL: nil)
}

@MainActor private final class WaitingLauncher: GameLauncher {
    private(set) var calls = 0
    private var entered: CheckedContinuation<Void, Never>?
    private var pending: CheckedContinuation<Void, any Error>?

    func launch(_ game: LaunchableGame) async throws {
        calls += 1
        try await withCheckedThrowingContinuation { pending = $0; entered?.resume(); entered = nil }
    }

    func waitForLaunch() async {
        if pending != nil { return }
        await withCheckedContinuation { entered = $0 }
    }

    func finish(failing: Bool) {
        let continuation = pending
        pending = nil
        if failing { continuation?.resume(throwing: Failure()) } else { continuation?.resume() }
    }
}

@MainActor @Suite struct LauncherTests {
    @Test(arguments: [false, true]) func launchStatusIsObservableAndClearsAfterSuccessOrFailure(failing: Bool) async throws {
        let box = try Sandbox()
        try box.giveAppData()
        let launcher = WaitingLauncher(), model = ShellHostModel(config: box.config(), launcher: launcher)
        let changes = LogBox()
        #expect(!model.launchingGame)
        withObservationTracking { _ = model.launchingGame } onChange: { changes.add("starting") }

        let play = Task { await model.playNow(Fixtures.orbit) }
        await launcher.waitForLaunch()
        #expect(model.launchingGame && changes.all == ["starting"])
        await model.playNow(Fixtures.orbit)
        #expect(launcher.calls == 1, "Play stays guarded while the loading indicator is visible")

        withObservationTracking { _ = model.launchingGame } onChange: { changes.add("finished") }
        launcher.finish(failing: failing)
        await play.value
        #expect(!model.launchingGame && changes.all == ["starting", "finished"])
        #expect((model.notice != nil) == failing)
    }

    @Test func theStubLogsAndSaysItCannotLaunch() async throws {
        let box = LogBox()
        let launcher = StubGameLauncher(log: { box.add($0) })
        let game = try sampleGame()
        await #expect(throws: GameLaunchError.notAvailable) { try await launcher.launch(game) }
        #expect(box.all.count == 1)
        #expect(box.all[0].contains(Fixtures.orbit) && box.all[0].contains("does not start it"))
        #expect(GameLaunchError.notAvailable.localizedDescription == "Launching is not available yet.")
    }
}
