import Foundation

extension ShellInstall {
    /// Prefix for temporary backup directories created while replacing an existing mirrored framework.
    package static let backupPrefix = ".old-"

    /// File operations used by `mirrorFramework`, injectable so tests can fault-inject partial writes and move failures.
    package struct MirrorFileOps {
        package var fileExists: (String) -> Bool
        package var createDirectory: (String) throws -> Void
        package var copyItem: (String, String) throws -> Void
        package var moveItem: (String, String) throws -> Void
        package var removeItem: (String) throws -> Void

        package init(
            fileExists: @escaping (String) -> Bool,
            createDirectory: @escaping (String) throws -> Void,
            copyItem: @escaping (String, String) throws -> Void,
            moveItem: @escaping (String, String) throws -> Void,
            removeItem: @escaping (String) throws -> Void
        ) {
            self.fileExists = fileExists
            self.createDirectory = createDirectory
            self.copyItem = copyItem
            self.moveItem = moveItem
            self.removeItem = removeItem
        }

        package static let live = MirrorFileOps(
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            createDirectory: { try FileManager.default.createDirectory(atPath: $0, withIntermediateDirectories: true) },
            copyItem: { try FileManager.default.copyItem(atPath: $0, toPath: $1) },
            moveItem: { try FileManager.default.moveItem(atPath: $0, toPath: $1) },
            removeItem: { try FileManager.default.removeItem(atPath: $0) }
        )
    }

    /// Mirrors a framework into the shell folder using a two-phase staging copy and `.old-<UUID>` backup swap.
    /// On APFS the staging copy is a clone that costs no extra space and isolates later writes in the build folder.
    /// If placing the staged directory into `target` fails, any half-written `target` directory is unconditionally
    /// removed first (both first-time and overwrite installs), any `.old-<UUID>` backup is restored to `target`,
    /// and the staging directory is cleaned up. With `keepPrevious`, the backup path is returned instead of removed
    /// so the caller can roll back if a later step rejects the framework.
    @discardableResult
    package static func mirrorFramework(
        framework: String,
        root: String,
        titleID: String? = nil,
        keepPrevious: Bool = false,
        fileOps: MirrorFileOps = .live
    ) throws -> String? {
        let target = mirroredFramework(root: root, titleID: titleID ?? Self.titleID(ofFramework: framework))
        let folder = (target as NSString).deletingLastPathComponent
        try fileOps.createDirectory(folder)
        let staging = folder + "/" + discardPrefix + "stage-" + UUID().uuidString
        do {
            try fileOps.copyItem(framework, staging)
        } catch {
            try? fileOps.removeItem(staging)
            throw error
        }

        var backup: String? = nil
        if fileOps.fileExists(target) {
            let aside = folder + "/" + backupPrefix + UUID().uuidString
            do {
                try fileOps.moveItem(target, aside)
                backup = aside
            } catch {
                if !fileOps.fileExists(target), fileOps.fileExists(aside) {
                    try? fileOps.moveItem(aside, target)
                }
                try? fileOps.removeItem(staging)
                throw error
            }
        }

        do {
            try fileOps.moveItem(staging, target)
        } catch {
            try? fileOps.removeItem(target)
            if let backup {
                try? fileOps.moveItem(backup, target)
            }
            try? fileOps.removeItem(staging)
            throw error
        }

        if keepPrevious {
            return backup
        }
        if let backup {
            try? fileOps.removeItem(backup)
        }
        return nil
    }
}
