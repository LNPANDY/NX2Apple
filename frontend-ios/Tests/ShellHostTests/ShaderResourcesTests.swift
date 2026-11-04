import AppleArchive
import Foundation
import System
import Testing
@testable import ShellHost

@MainActor @Suite struct ShaderResourcesTests {
    private let shader = "b-3f9a2c/example.metallib"

    private func archive(_ text: String, in box: Sandbox, at archive: URL) throws {
        let source = box.root.appendingPathComponent("shader-input")
        try box.write(text, to: source.appendingPathComponent(shader))
        let keys = try #require(ArchiveHeader.FieldKeySet("TYP,PAT,DAT"))
        try ArchiveByteStream.withFileStream(path: FilePath(archive.path), mode: .writeOnly,
                                             options: [.create, .truncate], permissions: .ownerReadWrite) { file in
            try ArchiveByteStream.withCompressionStream(using: .lzfse, writingTo: file) { compressed in
                try ArchiveStream.withEncodeStream(writingTo: compressed) {
                    try $0.writeDirectoryContents(archiveFrom: FilePath(source.path), keySet: keys)
                }
            }
        }
    }

    private func msl(_ game: LaunchableGame, in box: Sandbox) throws -> String {
        let plan = EngineLaunchPlan.make(game: game, appResources: box.root, documents: box.appData.deletingLastPathComponent(), envFileText: nil)
        return try #require(plan.environment["DM_MSL_DIR"])
    }

    @Test func playExtractsOnceAndRetriesAnInterruptedUpdate() async throws {
        let box = try Sandbox(), gameFolder = try box.giveAppData()
        let save = gameFolder.appendingPathComponent("save/progress.sav")
        let otherCache = box.appData.appendingPathComponent(Fixtures.chain + "/.shader-resources/msl-" + UUID().uuidString + "/" + shader)
        try box.write("player save", to: save)
        try box.write("other game shaders", to: otherCache)
        let launcher = RecordingLauncher(), model = ShellHostModel(config: box.config(), launcher: launcher)
        let framework = box.games.appendingPathComponent(Fixtures.orbit + "/DmGame.framework")
        let secondShader = "b-3f9a2c/large.metallib"
        let large = String(repeating: "z", count: 4 * 1024 * 1024)
        try box.write(large, to: box.root.appendingPathComponent("shader-input/" + secondShader))
        let first = framework.appendingPathComponent("msl-" + UUID().uuidString + ".aar")
        try archive("first", in: box, at: first)
        await model.playNow(Fixtures.orbit)
        let firstGame = try #require(launcher.launched.first), firstCache = try #require(firstGame.shaderResourcesURL)
        #expect(try msl(firstGame, in: box) == firstCache.path)
        #expect(try String(contentsOf: firstCache.appendingPathComponent(shader), encoding: .utf8) == "first")

        // A repeated Play can use the published files even if the archive can no longer be read.
        let abandoned = firstCache.deletingLastPathComponent().appendingPathComponent("msl-" + UUID().uuidString)
        try box.write("old", to: abandoned.appendingPathComponent(shader))   // Terminated after publishing, before cleanup.
        try Data([0]).write(to: first)
        await model.playNow(Fixtures.orbit)
        #expect(launcher.launched.count == 2 && launcher.launched.last?.shaderResourcesURL == firstCache)
        #expect(!FileManager.default.fileExists(atPath: abandoned.path))

        let next = framework.appendingPathComponent("msl-" + UUID().uuidString + ".aar")
        try FileManager.default.removeItem(at: first)
        try archive("later", in: box, at: next)   // Same paths, chain and byte counts as the previous export.
        let complete = try Data(contentsOf: next)
        try complete.prefix(complete.count / 2).write(to: next)   // Truncate the multi-block LZFSE stream.
        await model.playNow(Fixtures.orbit)
        #expect(model.notice != nil && launcher.launched.count == 2)
        #expect(!model.launchingGame)
        let cache = gameFolder.appendingPathComponent(".shader-resources")
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path) == [firstCache.lastPathComponent])

        try complete.write(to: next)   // Retry the same export with the full archive.
        await model.playNow(Fixtures.orbit)
        let updatedGame = try #require(launcher.launched.last), updated = try #require(updatedGame.shaderResourcesURL)
        #expect(launcher.launched.count == 3 && updated != firstCache)
        #expect(!model.launchingGame)
        #expect(try String(contentsOf: updated.appendingPathComponent(shader), encoding: .utf8) == "later")
        #expect(try String(contentsOf: updated.appendingPathComponent(secondShader), encoding: .utf8) == large)
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path) == [updated.lastPathComponent])
        #expect(try String(contentsOf: save, encoding: .utf8) == "player save")
        #expect(try Data(contentsOf: gameFolder.appendingPathComponent("romfs/fixture.marker")).isEmpty)
        #expect(try String(contentsOf: otherCache, encoding: .utf8) == "other game shaders")
    }

    @Test func interruptedExtractionsAreRemovedBeforeRetryOrCacheHit() async throws {
        let box = try Sandbox(), gameFolder = try box.giveAppData()
        let launcher = RecordingLauncher(), model = ShellHostModel(config: box.config(), launcher: launcher)
        let framework = box.games.appendingPathComponent(Fixtures.orbit + "/DmGame.framework")
        let packed = framework.appendingPathComponent("msl-" + UUID().uuidString + ".aar")
        try archive("ready", in: box, at: packed)
        let cache = gameFolder.appendingPathComponent(".shader-resources")
        let interrupted = cache.appendingPathComponent(".partial-" + UUID().uuidString)
        let similar = cache.appendingPathComponent(interrupted.lastPathComponent + ".saved")
        let regularFile = cache.appendingPathComponent(".partial-" + UUID().uuidString)
        try box.write("kept", to: similar.appendingPathComponent("marker"))
        try box.write("kept", to: regularFile)
        for count in 1...2 {
            // The second launch has to use the existing cache, and still remove an abandoned partial directory.
            if count == 2 { try Data([0]).write(to: packed) }
            try box.write("unfinished", to: interrupted.appendingPathComponent(shader))
            await model.playNow(Fixtures.orbit)
            #expect(launcher.launched.count == count)
            #expect(!FileManager.default.fileExists(atPath: interrupted.path))
            #expect(try String(contentsOf: similar.appendingPathComponent("marker"), encoding: .utf8) == "kept")
            #expect(try String(contentsOf: regularFile, encoding: .utf8) == "kept")
        }
    }

    @Test func looseShadersAndPlayerOverrideRetainTheirPaths() async throws {
        let box = try Sandbox(), gameFolder = try box.giveAppData()
        let launcher = RecordingLauncher(), model = ShellHostModel(config: box.config(), launcher: launcher)
        let framework = box.games.appendingPathComponent(Fixtures.orbit + "/DmGame.framework")
        try box.write("bundled", to: framework.appendingPathComponent("msl/" + shader))
        try Data([0]).write(to: framework.appendingPathComponent("msl-" + UUID().uuidString + ".aar"))
        // A legacy framework only needs to allow traversal to its known shader path.
        try FileManager.default.setAttributes([.posixPermissions: 0o111], ofItemAtPath: framework.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: framework.path) }
        await model.playNow(Fixtures.orbit)
        let legacy = try #require(launcher.launched.first)
        #expect(legacy.shaderResourcesURL == nil)
        #expect(try msl(legacy, in: box) == framework.appendingPathComponent("msl").path)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: framework.path)
        try FileManager.default.removeItem(at: framework.appendingPathComponent("msl"))
        let override = gameFolder.appendingPathComponent("msl")
        try box.write("custom", to: override.appendingPathComponent(shader))
        await model.playNow(Fixtures.orbit)
        let custom = try #require(launcher.launched.last)
        #expect(launcher.launched.count == 2 && custom.shaderResourcesURL == nil)
        #expect(try msl(custom, in: box) == override.path)
        #expect(!FileManager.default.fileExists(atPath: gameFolder.appendingPathComponent(".shader-resources").path))
    }

    @Test func profileShaderDirectoryBypassesArchivePreparation() async throws {
        let box = try Sandbox(), gameFolder = try box.giveAppData()
        let gameRoot = box.games.appendingPathComponent(Fixtures.orbit)
        let custom = box.root.appendingPathComponent("custom-msl")
        try box.write("profile shaders", to: custom.appendingPathComponent(shader))
        let profile: [String: Any] = [
            "game": Fixtures.orbit, "settings": [
                ["env": "DM_MSL_DIR", "kind": "choice", "label": "Shaders", "note": "",
                 "default": custom.path, "options": [[custom.path, "Custom"]]]
            ]
        ]
        try JSONSerialization.data(withJSONObject: profile).write(to: gameRoot.appendingPathComponent("launcher.json"))
        let archive = gameRoot.appendingPathComponent("DmGame.framework/msl-" + UUID().uuidString + ".aar")
        try Data([0]).write(to: archive)

        let launcher = RecordingLauncher(), model = ShellHostModel(config: box.config(), launcher: launcher)
        await model.playNow(Fixtures.orbit)
        let game = try #require(launcher.launched.first)
        #expect(game.shaderResourcesURL == nil && game.environment["DM_MSL_DIR"] == custom.path)
        #expect(try msl(game, in: box) == custom.path)
        #expect(!FileManager.default.fileExists(atPath: gameFolder.appendingPathComponent(".shader-resources").path))
    }
}
