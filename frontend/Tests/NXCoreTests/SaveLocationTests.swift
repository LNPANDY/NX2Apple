import XCTest
@testable import NXCore

final class SaveLocationTests: XCTestCase {
    private let support = URL(fileURLWithPath: "/Users/x/Library/Application Support")
    private let tid = "0100000000010000"

    private func effective(global: SaveGlobalSettings = .init(), game: SaveGameOverride = .init(), holds: Bool? = true) -> SaveLocations.EffectiveSave {
        SaveLocations.effectiveSave(titleID: tid, appPath: "", global: global, game: game, support: support, volumeHolds: { _ in holds })
    }

    func testNothingSetKeepsTheUsualPlaceAndAddsNoEnvironment() {
        let save = effective()
        XCTAssertEqual(save.path.path, "/Users/x/Library/Application Support/nxnative/\(tid)/save")
        XCTAssertEqual(save.source, .standard)
        let cloud = SaveLocations.effectiveCloud(global: .init(), game: .init(), own: .init(source: .none, value: nil, folder: nil))
        XCTAssertEqual(SaveLocations.environment(save: save, cloud: cloud), [:])
    }

    func testGlobalRootThenTheGamesOwnFolderWins() {
        let global = SaveGlobalSettings(saveRoot: "/Volumes/Saves")
        XCTAssertEqual(effective(global: global).path.path, "/Volumes/Saves/\(tid)/save")
        XCTAssertEqual(effective(global: global).source, .global)
        let own = effective(global: global, game: SaveGameOverride(saveFolder: "/Volumes/Mine/zelda"))
        XCTAssertEqual(own.path.path, "/Volumes/Mine/zelda")
        XCTAssertEqual(own.source, .game, "the game's choice is shown as its own, not as the global default")
    }

    func testAChosenFolderOnAVolumeWithoutCloneAndSwapFallsBackToLibrary() {
        let save = effective(global: SaveGlobalSettings(saveRoot: "/Volumes/ExFAT"), holds: false)
        XCTAssertEqual(save.source, .fallback)
        XCTAssertFalse(save.volumeHoldsSaves)
        XCTAssertEqual(save.path.path, "/Users/x/Library/Application Support/nxnative/\(tid)/save")
        XCTAssertEqual(SaveLocations.environment(save: save, cloud: .init(folder: nil, source: .standard))["DM_SAVE"], save.path.path,
                       "the game is told, so it does not read the exFAT folder")
    }

    func testALibraryFolderInjectsDMSaveSoEnginesWithoutTheLibraryPatchUseTheSameSave() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lib-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent(".nx2apple-library"))
        let appPath = root.appendingPathComponent("Zelda.app").path
        let save = SaveLocations.effectiveSave(titleID: tid, appPath: appPath, global: .init(), game: .init(),
                                               support: support, volumeHolds: { _ in true })
        XCTAssertEqual(save.source, .libraryFolder)
        XCTAssertEqual(save.path.path, root.appendingPathComponent("save/\(tid)").path)
        let env = SaveLocations.environment(save: save, cloud: .init(folder: nil, source: .standard))
        XCTAssertEqual(env["DM_SAVE"], save.path.path)
    }

    func testCloudOrderIsOverrideThenTheGamesOwnSettingThenGlobal() {
        let global = SaveGlobalSettings(cloudFolder: "icloud", cloudOn: true)
        let none = CloudSaveSync.Setting(source: .none, value: nil, folder: nil)
        let envOwn = CloudSaveSync.Setting(source: .playerEnv, value: "/Volumes/Cloud", folder: "/Volumes/Cloud")
        XCTAssertEqual(SaveLocations.effectiveCloud(global: global, game: .init(), own: none), .init(folder: "icloud", source: .global))
        XCTAssertEqual(SaveLocations.effectiveCloud(global: global, game: .init(), own: envOwn), .init(folder: "/Volumes/Cloud", source: .game),
                       "a setting the game already has is not replaced by the global one")
        XCTAssertEqual(SaveLocations.effectiveCloud(global: global, game: SaveGameOverride(cloud: .off), own: envOwn), .init(folder: nil, source: .game))
        XCTAssertEqual(SaveLocations.effectiveCloud(global: global, game: SaveGameOverride(cloud: .folder("/x")), own: none), .init(folder: "/x", source: .game))
        XCTAssertEqual(SaveLocations.effectiveCloud(global: .init(cloudFolder: "icloud", cloudOn: false), game: .init(), own: none).folder, nil)
    }

    func testOverridesRoundTripAsJSONAndEmptyMeansNone() throws {
        let value = SaveGameOverride(cloud: .folder("icloud"), saveFolder: "/a")
        XCTAssertEqual(try JSONDecoder().decode(SaveGameOverride.self, from: JSONEncoder().encode(value)), value)
        XCTAssertTrue(SaveGameOverride().isEmpty)
    }

    func testTheLibraryVolumeAnswersForARealFolder() {
        // Every Mac volume answers either way for an existing folder. The test only needs it not to crash, and a temp folder is on the system volume.
        _ = VolumeSaves.holdsSaves(at: NSTemporaryDirectory())
        _ = VolumeSaves.holdsSaves(at: NSTemporaryDirectory() + "/not/yet/there")
    }
}

final class SaveMigrationTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("save-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func write(_ path: String, _ text: String = "x") throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func testCopyKeepsTheOldFolderAndBringsDeviceSaveAlong() throws {
        try write("old/save/a.bin"); try write("old/save/sub/b.bin"); try write("old/save/._a.bin"); try write("old/save_device/d.bin")
        let n = try SaveMigration.copy(from: root.appendingPathComponent("old/save"), to: root.appendingPathComponent("new/save"), gameRunning: false, volumeHolds: { _ in true })
        XCTAssertEqual(n, 3, "AppleDouble files are not part of a save")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("old/save/a.bin").path), "nothing moves")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("new/save_device/d.bin").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("new/save/._a.bin").path))
    }

    func testNothingIsOverwrittenAndARunningGameBlocksIt() throws {
        try write("old/save/a.bin", "old"); try write("new/save/a.bin", "mine")
        XCTAssertThrowsError(try SaveMigration.copy(from: root.appendingPathComponent("old/save"), to: root.appendingPathComponent("new/save"), gameRunning: false, volumeHolds: { _ in true })) {
            XCTAssertEqual($0 as? SaveMigration.Failure, .destinationNotEmpty(root.appendingPathComponent("new/save").path))
        }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("new/save/a.bin")), "mine")
        XCTAssertThrowsError(try SaveMigration.copy(from: root.appendingPathComponent("old/save"), to: root.appendingPathComponent("other/save"), gameRunning: true, volumeHolds: { _ in true })) {
            XCTAssertEqual($0 as? SaveMigration.Failure, .gameRunning)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("other").path))
    }

    func testAVolumeWithoutCloneAndSwapIsRefusedAndAMissingSourceIsReported() throws {
        try write("old/save/a.bin")
        XCTAssertThrowsError(try SaveMigration.copy(from: root.appendingPathComponent("old/save"), to: root.appendingPathComponent("exfat/save"), gameRunning: false, volumeHolds: { _ in false })) {
            XCTAssertEqual($0 as? SaveMigration.Failure, .volumeCannotHoldSaves)
        }
        XCTAssertThrowsError(try SaveMigration.copy(from: root.appendingPathComponent("none/save"), to: root.appendingPathComponent("x/save"), gameRunning: false, volumeHolds: { _ in true })) {
            XCTAssertEqual($0 as? SaveMigration.Failure, .sourceMissing)
        }
    }
}

final class SaveArchiveTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("archive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    private func read(_ path: String) -> String? { try? String(contentsOf: root.appendingPathComponent(path)) }

    func testExportWritesOrdinaryFilesUnderTheTitleIDAndNeverReplacesAnEarlierExport() throws {
        try write("mac/save/slot0.bin", "A"); try write("mac/save_device/d.bin", "D")
        let out = root.appendingPathComponent("out")
        let first = try SaveArchive.export(save: root.appendingPathComponent("mac/save"), titleID: "0100abc000010000", to: out)
        XCTAssertEqual(first.files, 2)
        XCTAssertEqual(read("out/0100ABC000010000/save/slot0.bin"), "A")
        try write("mac/save/slot0.bin", "B")
        _ = try SaveArchive.export(save: root.appendingPathComponent("mac/save"), titleID: "0100abc000010000", to: out)
        XCTAssertEqual(read("out/0100ABC000010000/save/slot0.bin"), "A", "the first export is kept")
    }

    func testExportRefusesAnEmptySaveAndADestinationInsideIt() throws {
        XCTAssertThrowsError(try SaveArchive.export(save: root.appendingPathComponent("none"), titleID: "01", to: root.appendingPathComponent("o"))) {
            XCTAssertEqual($0 as? SaveArchive.Failure, .nothingToExport)
        }
        try write("mac/save/a", "x")
        XCTAssertThrowsError(try SaveArchive.export(save: root.appendingPathComponent("mac/save"), titleID: "01", to: root.appendingPathComponent("mac/save"))) {
            XCTAssertEqual($0 as? SaveArchive.Failure, .destinationInsideSave)
        }
    }

    func testPreviewReadsAnExportOrAFlatFolder() throws {
        try write("exp/save/a.bin", "1"); try write("exp/save_device/b.bin", "2"); try write("flat/slot.bin", "3"); try write("flat/._slot.bin", "x")
        XCTAssertEqual(SaveArchive.preview(root.appendingPathComponent("exp"))?.fileCount, 2)
        XCTAssertEqual(Set(SaveArchive.preview(root.appendingPathComponent("exp"))?.folders.keys.map { $0 } ?? []), ["save", "save_device"])
        let flat = SaveArchive.preview(root.appendingPathComponent("flat"))
        XCTAssertEqual(flat?.fileCount, 1)
        XCTAssertEqual(flat?.folders["save"], root.appendingPathComponent("flat"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)
        XCTAssertNil(SaveArchive.preview(root.appendingPathComponent("empty")))
    }

    func testImportBacksUpTheCurrentSaveThenReplacesIt() throws {
        try write("mac/save/old.bin", "old"); try write("src/new.bin", "new")
        let preview = try XCTUnwrap(SaveArchive.preview(root.appendingPathComponent("src")))
        let backup = try SaveArchive.import(preview, into: root.appendingPathComponent("mac/save"), gameRunning: false, now: Date(timeIntervalSince1970: 0), volumeHolds: { _ in true })
        XCTAssertNil(read("mac/save/old.bin"))
        XCTAssertEqual(read("mac/save/new.bin"), "new")
        let kept = try XCTUnwrap(backup)
        XCTAssertEqual(try String(contentsOf: kept.appendingPathComponent("save/old.bin")), "old")
        XCTAssertTrue(kept.path.hasSuffix(" before import"))
        XCTAssertTrue(kept.path.contains("/save-backups/"), "beside the save, where a sync's backups are too")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("mac/save.import").path))
    }

    func testImportIntoNoSaveMakesNoBackupAndAGameRunningRefusesBeforeAnyChange() throws {
        try write("src/new.bin", "new")
        let preview = try XCTUnwrap(SaveArchive.preview(root.appendingPathComponent("src")))
        XCTAssertNil(try SaveArchive.import(preview, into: root.appendingPathComponent("fresh/save"), gameRunning: false, volumeHolds: { _ in true }))
        XCTAssertEqual(read("fresh/save/new.bin"), "new")
        try write("mac/save/old.bin", "old")
        XCTAssertThrowsError(try SaveArchive.import(preview, into: root.appendingPathComponent("mac/save"), gameRunning: true, volumeHolds: { _ in true })) {
            XCTAssertEqual($0 as? SaveArchive.Failure, .gameRunning)
        }
        XCTAssertEqual(read("mac/save/old.bin"), "old")
        XCTAssertThrowsError(try SaveArchive.import(preview, into: root.appendingPathComponent("mac/save"), gameRunning: false, volumeHolds: { _ in false })) {
            XCTAssertEqual($0 as? SaveArchive.Failure, .volumeCannotHoldSaves)
        }
    }
}
