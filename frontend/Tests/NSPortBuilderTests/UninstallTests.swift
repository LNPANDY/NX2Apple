import XCTest
@testable import NSPortBuilder

/// The uninstall plan (Uninstall.swift): what goes, what stays. The removal runs in a temporary folder,
/// so the real state and checkout are never touched.
final class UninstallTests: XCTestCase {
    private var home: URL!
    private var games: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("uninstall-" + UUID().uuidString)
        games = home.appendingPathComponent("Games")
        guard let home, let games else { throw XCTSkip("temporary folder unavailable") }
        for dir in [games, home.appendingPathComponent("Library/Application Support/NS Port Builder"),
                    home.appendingPathComponent("Library/Application Support/NX2Apple/engine/aaaaaaa"),
                    home.appendingPathComponent("NX2Apple")] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try Data("k".utf8).write(to: home.appendingPathComponent("prod.keys"))
        try Data("save".utf8).write(to: games.appendingPathComponent("save.dat"))
        setHome(home.path)
    }

    override func tearDownWithError() throws {
        setHome(NSHomeDirectory())
        try? FileManager.default.removeItem(at: home)
    }

    /// Uninstall computes from NSHomeDirectory: the tests point it at the temporary folder.
    private func setHome(_ path: String) {
        UserDefaults.standard.set(path, forKey: "NSGlobalDomain_home")   // not read by the app; the env below is
        setenv("HOME", path, 1)
    }

    private func originFixture(checkout: URL) throws {
        let git = "/usr/bin/git"
        _ = BuildModel.runQuiet([git, "-C", checkout.path, "init", "-b", "main"], env: BuildModel.gitEnv())
        _ = BuildModel.runQuiet([git, "-C", checkout.path, "remote", "add", "origin", "https://github.com/LNPANDY/NX2Apple.git"], env: BuildModel.gitEnv())
    }

    func testThePlanTakesStateAndItsOwnCheckoutAndLeavesGamesAndKeys() throws {
        let checkout = home.appendingPathComponent("NX2Apple").path
        try originFixture(checkout: URL(fileURLWithPath: checkout))
        let plan = Uninstall.plan(home: home.path, gamesFolder: games.path, checkouts: [checkout])
        XCTAssertEqual(plan.stateFolders.contains(home.path + "/Library/Application Support/NS Port Builder"), true)
        XCTAssertEqual(plan.stateFolders.contains(home.path + "/Library/Application Support/NX2Apple"), true)
        XCTAssertEqual(plan.checkouts, [checkout])

        let result = Uninstall.run(plan, movingAppToTrash: false)
        XCTAssertTrue(result.failures.isEmpty, result.failures.joined(separator: "\n"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: games.appendingPathComponent("save.dat").path), "the games folder stays")
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("prod.keys").path), "the keys stay")
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkout), "the launcher's own checkout goes")
    }

    /// A checkout the player picked from somewhere else is not removed: we cannot know what else it holds.
    func testACheckoutFromAnotherFolderIsNotTouched() throws {
        let picked = home.appendingPathComponent("Elsewhere/NX2Apple")
        try FileManager.default.createDirectory(at: picked, withIntermediateDirectories: true)
        try originFixture(checkout: picked)
        let plan = Uninstall.plan(home: home.path, gamesFolder: games.path, checkouts: [picked.path])
        XCTAssertTrue(plan.checkouts.isEmpty, "not the launcher's own ~/NX2Apple clone")
        XCTAssertTrue(FileManager.default.fileExists(atPath: picked.path))
    }

    func testARepoWithoutOurOriginIsNotTouched() throws {
        let checkout = home.appendingPathComponent("NX2Apple").path
        let git = "/usr/bin/git"
        _ = BuildModel.runQuiet([git, "-C", checkout, "remote", "add", "origin", "https://github.com/someone/else.git"], env: BuildModel.gitEnv())
        let plan = Uninstall.plan(home: home.path, gamesFolder: games.path, checkouts: [checkout])
        XCTAssertTrue(plan.checkouts.isEmpty, "a fork with another origin is the player's own work")
    }

    /// A games folder or build output folder inside ~/NX2Apple keeps the whole checkout: removing it
    /// would take the player's games or builds along.
    func testACheckoutHoldingTheGamesOrTheBuildsStays() throws {
        let checkout = home.appendingPathComponent("NX2Apple")
        try originFixture(checkout: checkout)
        let inner = checkout.appendingPathComponent("Games")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try Data("save".utf8).write(to: inner.appendingPathComponent("save.dat"))

        let gamesInside = Uninstall.plan(home: home.path, gamesFolder: inner.path, checkouts: [checkout.path])
        XCTAssertTrue(gamesInside.checkouts.isEmpty, "the games folder lives in the checkout")
        let gamesAsCheckout = Uninstall.plan(home: home.path, gamesFolder: checkout.path + "/", checkouts: [checkout.path])
        XCTAssertTrue(gamesAsCheckout.checkouts.isEmpty, "the games folder is the checkout itself")
        let outputInside = Uninstall.plan(home: home.path, gamesFolder: games.path,
                                          outputFolder: checkout.appendingPathComponent("builds").path,
                                          checkouts: [checkout.path])
        XCTAssertTrue(outputInside.checkouts.isEmpty, "the build output lives in the checkout")
        let sibling = Uninstall.plan(home: home.path, gamesFolder: home.appendingPathComponent("NX2AppleGames").path,
                                     checkouts: [checkout.path])
        XCTAssertEqual(sibling.checkouts, [checkout.path], "a folder that only shares the name prefix does not count")

        let result = Uninstall.run(outputInside, movingAppToTrash: false)
        XCTAssertTrue(result.failures.isEmpty, result.failures.joined(separator: "\n"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: inner.appendingPathComponent("save.dat").path))
    }

    /// The settings live in UserDefaults, not in a state folder: the uninstall removes that domain too.
    func testTheSettingsDomainIsRemoved() throws {
        let domain = "uninstall-test-" + UUID().uuidString
        UserDefaults.standard.setPersistentDomain(["buildOutputDirectory": "/somewhere"], forName: domain)
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }
        let plan = Uninstall.plan(home: home.path, gamesFolder: games.path, checkouts: [], defaultsDomain: domain)
        XCTAssertEqual(plan.defaultsDomain, domain)
        _ = Uninstall.run(plan, movingAppToTrash: false)
        XCTAssertNil(UserDefaults.standard.persistentDomain(forName: domain)?["buildOutputDirectory"])
    }

    func testThePercentTextAndTrashAreHonestAboutFailures() {
        XCTAssertFalse(Uninstall.trash("/nonexistent/" + UUID().uuidString), "a missing path reports failure")
    }
}
