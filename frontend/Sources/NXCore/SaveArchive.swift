import Foundation

/// Saving a game's save as ordinary files and bringing one in (#411).
///
/// Export copies the committed save folders into a folder the player picked: `<picked>/<TITLE ID>/save` (and `save_device`). Import
/// reads a folder and replaces the game's save with it, after the current save was copied to `<DM_SAVE>-backups/<date> before import`.
/// The folder may be an export of this launcher (it holds `save`), or just the save's files (from a Switch or another tool).
/// The cloud state is left to the engine: an import changes this Mac's save but not `<DM_SAVE>.sync`, so the next start sees a local
/// change, sends it, or asks (CloudSaveGate) when the cloud's save changed as well.
package enum SaveArchive {
    package enum Failure: Error, Equatable {
        case gameRunning
        case nothingToImport
        case nothingToExport
        case destinationInsideSave
        case volumeCannotHoldSaves
    }

    /// What an import would bring in: the folders of the source and how many files they hold.
    package struct Preview: Equatable {
        package var source: URL
        /// Source folder for each target folder name (`save`, `save_device`).
        package var folders: [String: URL]
        package var fileCount: Int
    }

    /// The source folder seen as a save: its `save` / `save_device` subfolders when it has them, else the folder itself as `save`.
    package static func preview(_ source: URL, fm: FileManager = .default) -> Preview? {
        var found: [String: URL] = [:]
        for name in SaveMigration.folders {
            let sub = source.appendingPathComponent(name)
            if SaveMigration.files(in: sub, fm: fm) > 0 { found[name] = sub }
        }
        if found.isEmpty, SaveMigration.files(in: source, fm: fm) > 0 { found["save"] = source }
        guard !found.isEmpty else { return nil }
        return Preview(source: source, folders: found, fileCount: found.values.reduce(0) { $0 + SaveMigration.files(in: $1, fm: fm) })
    }

    /// Copies the game's committed save folders to `<destination>/<TITLE ID>/`. Returns that folder and the number of files.
    @discardableResult
    package static func export(save: URL, titleID: String, to destination: URL, fm: FileManager = .default) throws -> (folder: URL, files: Int) {
        let target = destination.appendingPathComponent(titleID.uppercased(), isDirectory: true)
        if target.path.hasPrefix(save.path + "/") || destination.path == save.path { throw Failure.destinationInsideSave }
        var total = 0
        for name in SaveMigration.folders {
            let source = name == "save" ? save : URL(fileURLWithPath: save.path + "_device")
            guard SaveMigration.files(in: source, fm: fm) > 0 else { continue }
            // A second export to the same place adds to it without replacing a file the player may have kept: it goes beside, dated.
            var dest = target.appendingPathComponent(name, isDirectory: true)
            if fm.fileExists(atPath: dest.path) { dest = target.appendingPathComponent(name + " " + stamp(Date()), isDirectory: true) }
            total += try SaveMigration.copyTree(source, dest, fm: fm)
        }
        guard total > 0 else { throw Failure.nothingToExport }
        return (target, total)
    }

    /// Replaces the save with the previewed one. The current save is copied to the backups folder first and only then replaced, from a
    /// copy made beside it, so an interrupted import leaves either the old save or the new one. Returns the backup folder, nil when there was no save.
    @discardableResult
    package static func `import`(_ preview: Preview, into save: URL, gameRunning: Bool, now: Date = Date(),
                                 volumeHolds: (String) -> Bool? = { VolumeSaves.holdsSaves(at: $0) },
                                 fm: FileManager = .default) throws -> URL? {
        if gameRunning { throw Failure.gameRunning }
        if volumeHolds(save.path) == false { throw Failure.volumeCannotHoldSaves }
        guard !preview.folders.isEmpty else { throw Failure.nothingToImport }
        let backups = URL(fileURLWithPath: save.path + "-backups", isDirectory: true)
        let backup = backups.appendingPathComponent(stamp(now) + " before import", isDirectory: true)
        var backedUp = false
        for (name, source) in preview.folders {
            let current = name == "save" ? save : URL(fileURLWithPath: save.path + "_device")
            if SaveMigration.files(in: current, fm: fm) > 0 {
                try SaveMigration.copyTree(current, backup.appendingPathComponent(name, isDirectory: true), fm: fm)
                backedUp = true
            }
            let staging = URL(fileURLWithPath: current.path + ".import")
            try? fm.removeItem(at: staging)
            try SaveMigration.copyTree(source, staging, fm: fm)
            try fm.createDirectory(at: current.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: current.path) { try fm.removeItem(at: current) }
            try fm.moveItem(at: staging, to: current)
        }
        return backedUp ? backup : nil
    }

    private static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return f.string(from: date)
    }
}
