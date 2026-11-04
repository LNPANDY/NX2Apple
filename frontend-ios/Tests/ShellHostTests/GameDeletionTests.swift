import Foundation
import Testing
@testable import ShellHost

/// #559: deleting a game in the shell removes its folder in the app (the saves only when asked), never a folder the player
/// picked, and keeps the game off the list until a new build of it or its game data comes again.
@MainActor @Suite struct GameDeletionTests {
    /// The orbit fixture's folder with game data, add-on content, saves, shader caches, a temp folder and a log.
    private func fill(_ box: Sandbox) throws -> URL {
        let dir = try box.giveAppData()
        for file in ["aoc/0.img", "save/0/file.bin", "save_device/0/file.bin", "save.work/0/file.bin", "temp/t.bin", "log.txt"] {
            try box.write("x", to: dir.appendingPathComponent(file))
        }
        for prefix in ["msl-", ".partial-"] {
            try box.write("shader", to: dir.appendingPathComponent(".shader-resources/" + prefix + UUID().uuidString + "/b-3f9a2c/example.metallib"))
        }
        return dir
    }
    private func names(_ dir: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() }
    private func listed(_ model: ShellHostModel) -> Bool { model.details.contains { $0.id == Fixtures.orbit } }

    @Test func deletingKeepsTheSavesAndTakesTheGameOffTheList() throws {
        let box = try Sandbox()
        let dir = try fill(box)
        let model = ShellHostModel(config: box.config())
        let before = model.details.count
        #expect(listed(model))
        model.deleteGame(Fixtures.orbit, saves: false)
        #expect(names(dir) == ["save", "save.work", "save_device"], "game data, shader caches, add-on content, temp and log are gone, the saves stay")
        #expect(!listed(model) && model.details.count == before - 1)
        #expect(model.notice == nil)
        #expect(!listed(ShellHostModel(config: box.config())), "still off the list when the app opens again")
    }

    @Test func deletingWithSavesRemovesTheWholeFolder() throws {
        let box = try Sandbox()
        let dir = try fill(box)
        let model = ShellHostModel(config: box.config())
        model.deleteGame(Fixtures.orbit, saves: true)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        #expect(!listed(model))
    }

    @Test func gameDataSentAgainBringsTheGameBack() throws {
        let box = try Sandbox()
        _ = try fill(box)
        ShellHostModel(config: box.config()).deleteGame(Fixtures.orbit, saves: false)
        try box.giveAppData()
        let model = ShellHostModel(config: box.config())
        #expect(listed(model))
        #expect(try #require(model.details.first { $0.id == Fixtures.orbit }).game.state == .playable)
        #expect(box.defaults(Fixtures.orbit).string(forKey: GameDeletion.deletedKey) == nil, "the mark is dropped once the game is back")
    }

    @Test func aNewBuildOfTheGameBringsItBack() throws {
        let box = try Sandbox()
        _ = try fill(box)
        ShellHostModel(config: box.config()).deleteGame(Fixtures.orbit, saves: false)
        #expect(!listed(ShellHostModel(config: box.config())), "the same build stays deleted")
        let manifest = box.games.appendingPathComponent(Fixtures.orbit).appendingPathComponent("game.manifest.json")
        let text = try String(contentsOf: manifest, encoding: .utf8)
        try Data(text.replacingOccurrences(of: "\"schema\": 1,", with: "\"schema\": 1,\n  \"built_at\": \"2026-11-03T10:00:00Z\",").utf8).write(to: manifest)
        let model = ShellHostModel(config: box.config())
        #expect(listed(model))
        #expect(try #require(model.details.first { $0.id == Fixtures.orbit }).game.state == .needsGameData)
    }

    @Test func aFolderThePlayerPickedIsNotTouched() async throws {
        let box = try Sandbox()
        let picked = box.root.appendingPathComponent("Picked/Orbit", isDirectory: true)
        try box.write("", to: picked.appendingPathComponent("romfs/fixture.marker"))
        let model = ShellHostModel(config: box.config(), picker: FakePicker(url: picked))
        await model.pickGameDataNow(Fixtures.orbit)
        #expect(try #require(model.details.first { $0.id == Fixtures.orbit }).game.state == .playable)
        model.deleteGame(Fixtures.orbit, saves: true)
        #expect(FileManager.default.fileExists(atPath: picked.appendingPathComponent("romfs/fixture.marker").path))
        #expect(box.defaults(Fixtures.orbit).data(forKey: BookmarkStore.gameDataKey) == nil, "the pick is forgotten")
        #expect(!listed(model))
    }

    @Test func theRemovalsListNamesEverythingButTheSaves() throws {
        let box = try Sandbox()
        let dir = try fill(box)
        #expect(GameDeletion.removals(in: dir, saves: false).map(\.lastPathComponent) == [".shader-resources", "aoc", "log.txt", "romfs", "temp"])
        #expect(GameDeletion.removals(in: dir, saves: true).count == 8)
        #expect(GameDeletion.removals(in: dir.appendingPathComponent("missing"), saves: true).isEmpty)
    }
}
