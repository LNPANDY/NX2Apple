import AppleArchive
import Foundation
import System

/// Marker and directory checks for large `msl/` shader trees externalized from unsigned shared IPAs (#947).
public enum ExternalShaders {
    public static let markerFile = "external-msl.json"

    static func isIncompleteEntry(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasPrefix(".partial")
            || lower.hasSuffix(".part")
            || lower.hasSuffix(".partial")
            || lower.hasSuffix(".nxjoin")
            || name.contains(DataParts.marker)
    }

    private static func scanTree(at mslURL: URL, fileManager fm: FileManager) -> (exists: Bool, hasCompleteFile: Bool, hasIncomplete: Bool) {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: mslURL.path, isDirectory: &isDir), isDir.boolValue else {
            return (false, false, false)
        }
        guard let walk = fm.enumerator(at: mslURL, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey], options: []) else {
            return (true, false, false)
        }
        var hasCompleteFile = false
        for case let url as URL in walk {
            let name = url.lastPathComponent
            if isIncompleteEntry(name) {
                return (true, hasCompleteFile, true)
            }
            if name.hasPrefix(".") {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    walk.skipDescendants()
                }
                continue
            }
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                hasCompleteFile = true
            }
        }
        return (true, hasCompleteFile, false)
    }

    /// True when `frameworkURL` carries `external-msl.json` and has no bundled `msl/` directory of its own.
    public static func isRequired(in frameworkURL: URL, fileManager fm: FileManager = .default) -> Bool {
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: frameworkURL.appendingPathComponent("msl").path, isDirectory: &isDir), isDir.boolValue {
            return false
        }
        return fm.fileExists(atPath: frameworkURL.appendingPathComponent(markerFile).path)
    }

    /// True when `mslURL` is a directory holding at least one complete shader entry and no in-flight transfer parts.
    public static func hasCompleteTree(at mslURL: URL, fileManager fm: FileManager = .default) -> Bool {
        let scan = scanTree(at: mslURL, fileManager: fm)
        return scan.exists && scan.hasCompleteFile && !scan.hasIncomplete
    }

    /// True when `mslURL` is a directory suitable as an override in `EngineLaunchPlan` (an empty player test folder
    /// or a complete tree, never a folder holding in-flight `.nxpart` / `.part` / `.partial` files).
    public static func isUsableOverride(at mslURL: URL, fileManager fm: FileManager = .default) -> Bool {
        let scan = scanTree(at: mslURL, fileManager: fm)
        return scan.exists && !scan.hasIncomplete
    }

    public static func isSatisfied(entry: CatalogueEntry, appFolder: URL, dataURL: URL?, fileManager fm: FileManager = .default) -> Bool {
        guard entry.requiresExternalShaders else { return true }
        if hasCompleteTree(at: appFolder.appendingPathComponent("msl", isDirectory: true), fileManager: fm) {
            return true
        }
        if let dataURL, hasCompleteTree(at: dataURL.appendingPathComponent("msl", isDirectory: true), fileManager: fm) {
            return true
        }
        return false
    }
}

/// The export packs the shader tree into one archive per framework to keep the IPA within sideloaders' ZIP limits.
actor ShaderResources {
    static let shared = ShaderResources()

    func prepare(_ game: LaunchableGame) throws -> URL? {
        let fm = FileManager.default
        var cache = game.appFolder.appendingPathComponent(".shader-resources", isDirectory: true)
        let directories = ((try? fm.contentsOfDirectory(at: cache, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        // Only this actor extracts into this cache. A partial directory present on entry survived an interrupted launch.
        for partial in directories where Self.hasUUIDName(partial.lastPathComponent, prefix: ".partial-") {
            try? fm.removeItem(at: partial)
        }

        // The launch plan already knows how to use an explicit setting, player/external shaders, or the loose framework tree.
        guard game.environment["DM_MSL_DIR"] == nil else { return nil }
        for folder in [game.appFolder, game.dataURL] {
            let msl = folder.appendingPathComponent("msl", isDirectory: true)
            if ExternalShaders.isUsableOverride(at: msl, fileManager: fm) { return nil }
        }
        let bundledMSL = game.frameworkURL.appendingPathComponent("msl", isDirectory: true)
        if (try? bundledMSL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { return nil }

        let files = try fm.contentsOfDirectory(at: game.frameworkURL, includingPropertiesForKeys: nil)
        let archives = files.filter { $0.pathExtension == "aar" && Self.hasUUIDName($0.deletingPathExtension().lastPathComponent, prefix: "msl-") }
        guard let archive = archives.first else { return nil }
        guard archives.count == 1 else { throw CocoaError(.fileReadCorruptFile) }

        let destination = cache.appendingPathComponent(archive.deletingPathExtension().lastPathComponent, isDirectory: true)
        if (try? destination.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true {
            try fm.createDirectory(at: cache, withIntermediateDirectories: true)
            var attributes = URLResourceValues()
            attributes.isExcludedFromBackup = true
            try cache.setResourceValues(attributes)

            let temporary = cache.appendingPathComponent(".partial-" + UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: temporary, withIntermediateDirectories: false)
            defer { try? fm.removeItem(at: temporary) }
            try extract(archive, to: temporary)
            try fm.moveItem(at: temporary, to: destination)
        }
        // A new archive UUID comes from a new installed app. No running game can still use the old app's archive.
        for old in directories where old.lastPathComponent != destination.lastPathComponent &&
            Self.hasUUIDName(old.lastPathComponent, prefix: "msl-") {
            try? fm.removeItem(at: old)
        }
        return destination
    }

    private static func hasUUIDName(_ name: String, prefix: String) -> Bool {
        name.hasPrefix(prefix) && UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
    }

    private func extract(_ archive: URL, to directory: URL) throws {
        try ArchiveByteStream.withFileStream(path: FilePath(archive.path), mode: .readOnly, options: [], permissions: []) { file in
            try ArchiveByteStream.withDecompressionStream(readingFrom: file) { decompressed in
                try ArchiveStream.withDecodeStream(readingFrom: decompressed) { input in
                    try ArchiveStream.withExtractStream(extractingTo: FilePath(directory.path), flags: [.ignoreOperationNotPermitted]) { output in
                        _ = try ArchiveStream.process(readingFrom: input, writingTo: output)
                    }
                }
            }
        }
    }
}
