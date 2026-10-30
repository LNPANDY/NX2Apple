import Foundation
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

@MainActor @Suite struct LauncherTests {
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
