import Foundation
import Testing
import ShellUI
@testable import ShellHost

@Suite struct LooseRomfsClaimTests {
    private func installOrbitIdentity(in box: Sandbox, indexHex: String = "90b5abb4d1ea10d2",
                                      size: Int = 61, gameID: String = Fixtures.orbit) throws {
        let url = box.games.appendingPathComponent(gameID).appendingPathComponent("game.manifest.json")
        let text = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "\"DMROMFSID1 fixture\"",
                                  with: "\"DMROMFSID1 title=\(gameID) version=1.0 build=v0 size=\(size) index=\(indexHex)\"")
        try Data(text.utf8).write(to: url)
    }

    private func writeImage(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    @Test func startupClaimsTopLevelLooseImagePreservesSavesAndMarksPlayable() async throws {
        let box = try Sandbox()
        try installOrbitIdentity(in: box)
        let documents = box.appData.deletingLastPathComponent()
        let loose = documents.appendingPathComponent("My Favorite Game (v1.0).IMG")
        let imageData = ShellDataFolderTests.dmromfs(ShellDataFolderTests.indexA)
        try writeImage(imageData, to: loose)
        // Existing save data in the target game folder must stay untouched.
        let saveFile = box.appData.appendingPathComponent("\(Fixtures.orbit)/save/slot0.bin")
        try box.write("save-bytes", to: saveFile)

        let model = await MainActor.run { ShellHostModel(config: box.config()) }
        await model.waitForStartupTasks()
        await model.waitForDataChecks()

        let dest = box.appData.appendingPathComponent("\(Fixtures.orbit)/romfs.img")
        #expect(!FileManager.default.fileExists(atPath: loose.path))
        #expect(try Data(contentsOf: dest) == imageData)
        #expect(try String(contentsOf: saveFile, encoding: .utf8) == "save-bytes")
        #expect(BackupExclusion.isExcluded(dest))
        let state = await MainActor.run {
            model.details.first(where: { $0.id == Fixtures.orbit })?.game.state
        }
        #expect(state == .playable)
    }

    @Test func claimsSubdirectoryWithSiblingAocAndMslAndCleansEmptyFolder() async throws {
        let box = try Sandbox()
        try installOrbitIdentity(in: box)
        let documents = box.appData.deletingLastPathComponent()
        let folder = documents.appendingPathComponent("Dropped Folder", isDirectory: true)
        let loose = folder.appendingPathComponent("game_dump.img")
        let imageData = ShellDataFolderTests.dmromfs(ShellDataFolderTests.indexA)
        try writeImage(imageData, to: loose)
        try box.write("dlc-pack", to: folder.appendingPathComponent("aoc/dlc.bin"))
        try box.write("metal-lib", to: folder.appendingPathComponent("msl/shader.metallib"))
        try box.write("finder-meta", to: folder.appendingPathComponent(".DS_Store"))

        let entries = GameCatalogue.scan(root: box.games)
        let claimed = LooseRomfsClaimer.claimAll(documents: documents, appDataRoot: box.appData, entries: entries)

        let targetDir = box.appData.appendingPathComponent(Fixtures.orbit, isDirectory: true)
        #expect(claimed.map { $0.resolvingSymlinksInPath().path } == [targetDir.appendingPathComponent("romfs.img").resolvingSymlinksInPath().path])
        #expect(try Data(contentsOf: targetDir.appendingPathComponent("romfs.img")) == imageData)
        #expect(try String(contentsOf: targetDir.appendingPathComponent("aoc/dlc.bin"), encoding: .utf8) == "dlc-pack")
        #expect(try String(contentsOf: targetDir.appendingPathComponent("msl/shader.metallib"), encoding: .utf8) == "metal-lib")
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func keepsSubdirectoryWhenUnclaimedUserFilesRemain() async throws {
        let box = try Sandbox()
        try installOrbitIdentity(in: box)
        let documents = box.appData.deletingLastPathComponent()
        let folder = documents.appendingPathComponent("Game And Notes", isDirectory: true)
        try writeImage(ShellDataFolderTests.dmromfs(ShellDataFolderTests.indexA), to: folder.appendingPathComponent("dump.img"))
        try box.write("keep me", to: folder.appendingPathComponent("notes.txt"))

        let entries = GameCatalogue.scan(root: box.games)
        let claimed = LooseRomfsClaimer.claimAll(documents: documents, appDataRoot: box.appData, entries: entries)

        #expect(claimed.count == 1)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("notes.txt").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("dump.img").path))
    }

    @Test func neverOverwritesExistingGameImageOrActiveParts() async throws {
        let box = try Sandbox()
        try installOrbitIdentity(in: box)
        let documents = box.appData.deletingLastPathComponent()
        let targetDir = box.appData.appendingPathComponent(Fixtures.orbit, isDirectory: true)
        let existing = targetDir.appendingPathComponent("romfs.img")
        try writeImage(Data("existing-game-data".utf8), to: existing)

        let loose = documents.appendingPathComponent("duplicate.img")
        try writeImage(ShellDataFolderTests.dmromfs(ShellDataFolderTests.indexA), to: loose)

        let entries = GameCatalogue.scan(root: box.games)
        let claimed = LooseRomfsClaimer.claimAll(documents: documents, appDataRoot: box.appData, entries: entries)

        #expect(claimed.isEmpty)
        #expect(try String(contentsOf: existing, encoding: .utf8) == "existing-game-data")
        #expect(FileManager.default.fileExists(atPath: loose.path))

        // Remove romfs.img and place an active split part in target directory -> must still skip.
        try FileManager.default.removeItem(at: existing)
        try box.write("part0", to: targetDir.appendingPathComponent("romfs.img.nxpart.0000.0002"))
        #expect(LooseRomfsClaimer.claimAll(documents: documents, appDataRoot: box.appData, entries: entries).isEmpty)
        #expect(FileManager.default.fileExists(atPath: loose.path))
    }

    @Test func ignoresDamagedImagesActivePartsSymlinksAndDeepNesting() async throws {
        let box = try Sandbox()
        try installOrbitIdentity(in: box)
        let documents = box.appData.deletingLastPathComponent()
        let good = ShellDataFolderTests.dmromfs(ShellDataFolderTests.indexA)

        // Truncated / bad magic / non-matching identity images stay untouched.
        try writeImage(good.prefix(40), to: documents.appendingPathComponent("truncated.img"))
        try writeImage(Data("BADMAGIC".utf8) + good.dropFirst(8), to: documents.appendingPathComponent("badmagic.img"))
        try writeImage(ShellDataFolderTests.dmromfs(ShellDataFolderTests.indexB), to: documents.appendingPathComponent("othergame.img"))

        // Loose .img with sibling .nxpart file stays untouched.
        let staged = documents.appendingPathComponent("transferring.img")
        try writeImage(good, to: staged)
        try box.write("part", to: documents.appendingPathComponent("transferring.img.nxpart.0001.0002"))

        // Symlinked .img and symlinked subdirectory are ignored.
        let outside = box.root.appendingPathComponent("outside.img")
        try writeImage(good, to: outside)
        try FileManager.default.createSymbolicLink(at: documents.appendingPathComponent("symlink.img"), withDestinationURL: outside)

        // Two-level deep subdirectory is ignored (only top-level files and 1-level subdirs are scanned).
        try writeImage(good, to: documents.appendingPathComponent("level1/level2/deep.img"))

        let entries = GameCatalogue.scan(root: box.games)
        let claimed = LooseRomfsClaimer.claimAll(documents: documents, appDataRoot: box.appData, entries: entries)

        #expect(claimed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: outside.path))
        #expect(FileManager.default.fileExists(atPath: documents.appendingPathComponent("level1/level2/deep.img").path))
    }

    @Test func reloadClaimsImageDroppedAfterLaunchAndRevivesDeletedGame() async throws {
        let box = try Sandbox()
        try installOrbitIdentity(in: box)
        let documents = box.appData.deletingLastPathComponent()

        let entriesBefore = GameCatalogue.scan(root: box.games)
        let orbitEntry = try #require(entriesBefore.first(where: { $0.id == Fixtures.orbit }))
        box.defaults(Fixtures.orbit).set(GameDeletion.stamp(orbitEntry), forKey: GameDeletion.deletedKey)

        let model = await MainActor.run { ShellHostModel(config: box.config()) }
        await model.waitForStartupTasks()
        let beforeCount = await MainActor.run { model.entries.contains(where: { $0.id == Fixtures.orbit }) }
        #expect(!beforeCount)

        // Player transfers the matching .img while the app is running, then returns to foreground (reload).
        let loose = documents.appendingPathComponent("Resumed.img")
        try writeImage(ShellDataFolderTests.dmromfs(ShellDataFolderTests.indexA), to: loose)
        await MainActor.run { model.reload() }
        await model.waitForStartupTasks()
        await model.waitForDataChecks()

        let detail = await MainActor.run { model.details.first(where: { $0.id == Fixtures.orbit }) }
        #expect(detail?.game.state == .playable)
        #expect(!FileManager.default.fileExists(atPath: loose.path))
    }

    @Test func rejectsAmbiguousIdentitySharedByTwoManifests() async throws {
        let box = try Sandbox()
        try installOrbitIdentity(in: box, gameID: Fixtures.orbit)
        try installOrbitIdentity(in: box, gameID: Fixtures.chain)
        let documents = box.appData.deletingLastPathComponent()
        let loose = documents.appendingPathComponent("ambiguous.img")
        try writeImage(ShellDataFolderTests.dmromfs(ShellDataFolderTests.indexA), to: loose)

        let entries = GameCatalogue.scan(root: box.games)
        let claimed = LooseRomfsClaimer.claimAll(documents: documents, appDataRoot: box.appData, entries: entries)

        #expect(claimed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: loose.path))
    }
}
