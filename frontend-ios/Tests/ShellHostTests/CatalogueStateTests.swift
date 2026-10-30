import Foundation
import Testing
import ShellUI
@testable import ShellHost

@Suite struct CatalogueStateTests {
    @Test func scansEveryBundleAndKeepsTheBrokenOnes() throws {
        let entries = GameCatalogue.scan(root: Fixtures.gamesURL)
        #expect(entries.count == 8)
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        #expect(byID[Fixtures.orbit]?.problem == nil)
        #expect(byID[Fixtures.orbit]?.title == "Orbit Fixture")
        #expect(byID[Fixtures.noFramework]?.problem?.reason == "Game code missing")
        #expect(byID[Fixtures.badManifest]?.problem?.detail.contains("not valid JSON") == true)
        #expect(byID[Fixtures.missingKey]?.problem != nil)
        #expect(byID[Fixtures.badSettings]?.problem?.detail.contains("DM_X") == true)
        #expect(byID[Fixtures.badManifest]?.title == "Unknown game", "a manifest with no readable name is an unknown game, never its folder name")
        #expect(entries.suffix(2).allSatisfy { $0.manifest == nil }, "games whose manifest cannot be read sort last")
    }

    @Test func missingFilesAreBrokenWithAReason() throws {
        let box = try Sandbox()
        let fm = FileManager.default
        let dir = box.games.appendingPathComponent(Fixtures.orbit)
        try fm.removeItem(at: dir.appendingPathComponent("game.manifest.json"))
        #expect(GameCatalogue.read(directory: dir).problem?.reason == "Game manifest missing")
        try fm.removeItem(at: box.games.appendingPathComponent(Fixtures.chain).appendingPathComponent("launcher.json"))
        #expect(GameCatalogue.read(directory: box.games.appendingPathComponent(Fixtures.chain)).problem?.reason == "Settings list missing")
    }

    @Test func launcherJSONInsideTheFrameworkIsFound() throws {
        let box = try Sandbox()
        let dir = box.games.appendingPathComponent(Fixtures.orbit)
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("DmGame.framework/dm"), withIntermediateDirectories: true)
        try fm.moveItem(at: dir.appendingPathComponent("launcher.json"), to: dir.appendingPathComponent("DmGame.framework/dm/launcher.json"))
        #expect(GameCatalogue.read(directory: dir).problem == nil)
    }

    @Test func titleIDMismatchIsBroken() throws {
        let box = try Sandbox()
        let from = box.games.appendingPathComponent(Fixtures.orbit)
        let to = box.games.appendingPathComponent("0100000000990000")
        try FileManager.default.moveItem(at: from, to: to)
        #expect(GameCatalogue.read(directory: to).problem?.detail.contains("0100000000990000") == true)
    }

    @Test func findsBannerAndIcon() throws {
        let box = try Sandbox()
        let dir = box.games.appendingPathComponent(Fixtures.orbit)
        #expect(GameCatalogue.read(directory: dir).bannerURL == nil)
        try pngData(width: 160, height: 90).write(to: dir.appendingPathComponent("banner.png"))
        try pngData(width: 64, height: 64).write(to: dir.appendingPathComponent("icon.png"))
        let entry = GameCatalogue.read(directory: dir)
        #expect(entry.bannerURL?.lastPathComponent == "banner.png")
        #expect(entry.iconURL?.lastPathComponent == "icon.png")
    }

    // MARK: State

    private func entry(_ id: String) -> CatalogueEntry { GameCatalogue.read(directory: Fixtures.gamesURL.appendingPathComponent(id)) }
    private let env = HostEnvironment(chain: "b-3f9a2c", osVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0))
    private let found = DataResolution(url: URL(fileURLWithPath: "/tmp/x"), source: .app, pickedIsStale: false)

    @Test func stateFollowsWhatIsPresent() {
        #expect(GameStateResolver.state(for: entry(Fixtures.orbit), data: found, environment: env) == .playable)
        #expect(GameStateResolver.state(for: entry(Fixtures.orbit), data: .missing, environment: env) == .needsGameData)
        #expect(GameStateResolver.state(for: entry(Fixtures.chain), data: found, environment: env) == .needsAppUpdate)
        #expect(GameStateResolver.state(for: entry(Fixtures.newerOS), data: found, environment: env) == .needsAppUpdate)
        // An app update comes before game data: the player cannot fix the data on an app that cannot run the game.
        #expect(GameStateResolver.state(for: entry(Fixtures.chain), data: .missing, environment: env) == .needsAppUpdate)
        // A host without an engine (the demo) skips the chain check.
        #expect(GameStateResolver.state(for: entry(Fixtures.chain), data: found, environment: HostEnvironment(chain: nil, osVersion: env.osVersion)) == .playable)
    }

    @Test func brokenBundlesAreBrokenWhateverElseIsPresent() {
        for id in [Fixtures.noFramework, Fixtures.badManifest, Fixtures.missingKey, Fixtures.badSettings] {
            guard case .broken(let reason, let detail, let technical) = GameStateResolver.state(for: entry(id), data: found, environment: env) else {
                Issue.record("\(id) is not broken"); continue
            }
            #expect(!reason.isEmpty && !detail.isEmpty && !technical.isEmpty && detail != technical)
        }
    }

    // MARK: Data

    private func manifest() throws -> GameManifest { try #require(entry(Fixtures.orbit).manifest) }

    @Test func dataInTheAppFolder() throws {
        let box = try Sandbox()
        let m = try manifest()
        let app = box.appData.appendingPathComponent(Fixtures.orbit)
        #expect(!DataLocator.locate(manifest: m, picked: .none, appFolder: app).found)
        try box.giveAppData()
        let r = DataLocator.locate(manifest: m, picked: .none, appFolder: app)
        #expect(r.found && r.source == .app && r.url == app)
    }

    @Test func imageCountsOnlyWhenItHasContent() throws {
        let box = try Sandbox()
        let m = try manifest()
        let app = box.appData.appendingPathComponent(Fixtures.orbit)
        try box.write("", to: app.appendingPathComponent("romfs.img"))
        #expect(!DataLocator.locate(manifest: m, picked: .none, appFolder: app).found)
        try box.write("x", to: app.appendingPathComponent("romfs.img"))
        #expect(DataLocator.locate(manifest: m, picked: .none, appFolder: app).found)
    }

    @Test func pickedLocationComesFirstAndFallsThrough() throws {
        let box = try Sandbox()
        let m = try manifest()
        let app = box.appData.appendingPathComponent(Fixtures.orbit)
        let picked = box.root.appendingPathComponent("Drive/MyGame")
        try box.write("", to: picked.appendingPathComponent("fixture.marker"))
        var r = DataLocator.locate(manifest: m, picked: .url(picked), appFolder: app)
        #expect(r.source == .picked && r.url == picked)
        // The picked folder lost its data: the app's own folder answers, when it has any.
        try FileManager.default.removeItem(at: picked)
        #expect(!DataLocator.locate(manifest: m, picked: .url(picked), appFolder: app).found)
        try box.giveAppData()
        r = DataLocator.locate(manifest: m, picked: .url(picked), appFolder: app)
        #expect(r.source == .app)
        // A picked romfs.img file counts through its folder.
        let img = box.root.appendingPathComponent("Drive2/romfs.img")
        try box.write("x", to: img)
        #expect(DataLocator.locate(manifest: m, picked: .url(img), appFolder: app).url == img.deletingLastPathComponent())
    }

    @Test func staleBookmarkIsReported() throws {
        let box = try Sandbox()
        let r = DataLocator.locate(manifest: try manifest(), picked: .stale, appFolder: box.appData.appendingPathComponent(Fixtures.orbit))
        #expect(!r.found && r.pickedIsStale)
    }
}
