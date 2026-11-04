import AppleArchive
import Foundation
import System

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

        // The launch plan already knows how to use an explicit setting, player shaders, or the loose framework tree.
        guard game.environment["DM_MSL_DIR"] == nil else { return nil }
        for folder in [game.appFolder, game.frameworkURL] {
            let msl = folder.appendingPathComponent("msl", isDirectory: true)
            if (try? msl.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { return nil }
        }

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
