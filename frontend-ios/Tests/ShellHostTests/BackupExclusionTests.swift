import Foundation
import Testing
@testable import ShellHost

/// #618: the game files are many GB and `Documents` is in the iCloud backup, so the backup passed 5 GB. Game data is marked, saves are not.
@MainActor @Suite struct BackupExclusionTests {
    private func filled(_ box: Sandbox) throws -> URL {
        let dir = try box.giveAppData()
        try Data(count: BackupExclusion.smallFileLimit + 1).write(to: dir.appendingPathComponent("romfs.img"))
        for file in ["aoc/0.img", "pso/cache.bin", "temp/t.bin", "save/0/file.bin", "save_device/0/file.bin", "save.work/0/file.bin", "env.txt", "log.txt"] {
            try box.write("x", to: dir.appendingPathComponent(file))
        }
        return dir
    }
    private func excluded(_ dir: URL, _ name: String) -> Bool { BackupExclusion.isExcluded(dir.appendingPathComponent(name)) }

    @Test func gameDataIsMarkedAndSavesAndSettingsAreNot() throws {
        let box = try Sandbox()
        let dir = try filled(box)
        BackupExclusion.apply(appDataRoot: box.appData)
        for name in ["romfs", "romfs.img", "aoc", "pso", "temp"] { #expect(excluded(dir, name), "\(name) is game data") }
        for name in ["save", "save_device", "save.work", "env.txt", "log.txt"] { #expect(!excluded(dir, name), "\(name) stays in the backup") }
        #expect(!BackupExclusion.isExcluded(box.appData), "the games folder itself is not marked, it would hide the saves")
    }

    @Test func theOldSingleGameNamesInDocumentsAreMarked() throws {
        let box = try Sandbox()
        let documents = box.appData.deletingLastPathComponent()
        for name in ["romfs", "ROMFS.img", "aoc", "temp"] { try box.write("x", to: documents.appendingPathComponent(name + "/f")) }
        try box.write("x", to: documents.appendingPathComponent("log.txt"))
        BackupExclusion.apply(appDataRoot: box.appData)
        for name in ["romfs", "ROMFS.img", "aoc", "temp"] { #expect(BackupExclusion.isExcluded(documents.appendingPathComponent(name)), Comment(rawValue: name)) }
        #expect(!BackupExclusion.isExcluded(documents.appendingPathComponent("log.txt")))
    }

    /// What an earlier version put there is marked on the first start after the update, and a second run changes nothing.
    @Test func existingDataIsMarkedOnceAndTheSecondRunChangesNothing() throws {
        let box = try Sandbox()
        let dir = try filled(box)
        #expect(!excluded(dir, "romfs.img"))
        let first = BackupExclusion.apply(appDataRoot: box.appData)
        #expect(first.count == 5)
        #expect(BackupExclusion.apply(appDataRoot: box.appData).isEmpty)
        try box.write("x", to: dir.appendingPathComponent("added/new.bin"))
        #expect(BackupExclusion.apply(appDataRoot: box.appData).map(\.lastPathComponent) == ["added"], "game data that comes later is marked too")
    }

    @Test func aMissingFolderIsNoError() {
        let nowhere = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "/Documents/games")
        #expect(BackupExclusion.apply(appDataRoot: nowhere).isEmpty)
    }

    @Test func theShellMarksTheDataWhenItStarts() async throws {
        let box = try Sandbox()
        let dir = try filled(box)
        _ = ShellHostModel(config: box.config())
        for _ in 0..<100 where !excluded(dir, "romfs.img") { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(excluded(dir, "romfs.img") && !excluded(dir, "save"))
    }

    @Test func foldersTheLaunchCreatesKeepTempOutAndSaveIn() throws {
        let box = try Sandbox()
        let dir = box.appData.appendingPathComponent("0100000000000001", isDirectory: true)
        let plan = EngineLaunchPlan(environment: [:], arguments: [], frameworkExecutable: dir, imageMarker: "", logURL: dir,
                                    workingDirectory: dir, foldersToCreate: [dir.appendingPathComponent("save"), dir.appendingPathComponent("temp")])
        try plan.createFolders()
        #expect(excluded(dir, "temp") && !excluded(dir, "save"))
    }
}
