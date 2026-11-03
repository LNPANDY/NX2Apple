import Foundation

/// Validates a user-selected seed without changing it or claiming game compatibility.
package struct OfflineDataInventory: Equatable {
    /// Normalizes only known cache names, rejects duplicate indices before any copy.
    package static func cacheIndex(_ name: String) -> Int? {
        let digits: Substring
        if name.hasPrefix("SD_Cache."), name.count == 13 { digits = name.dropFirst(9) }
        else if name.hasPrefix("temp_cache") { digits = name.dropFirst(10) }
        else { return nil }
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let index = Int(digits), index <= 65535 else { return nil }
        return index
    }
    package let files: Int
    package let bytes: Int64
    package init(files: Int, bytes: Int64) { self.files = files; self.bytes = bytes }

    enum ValidationError: Error, LocalizedError {
        case notDirectory, symbolicLink, unsupportedFile, empty, unsupportedCacheName(String)
        var errorDescription: String? {
            switch self {
            case .notDirectory: return "Choose a folder containing extracted data."
            case .symbolicLink: return "Symbolic links are not supported in offline data."
            case .unsupportedFile: return "Offline data may contain only regular files and folders."
            case .empty: return "The selected folder has no files."
            case .unsupportedCacheName(let name): return "Unsupported cache folder: \(name). Expected SD_Cache.0000 or temp_cache0."
            }
        }
    }

    /// Builds a new immutable seed folder. Refuses to replace an earlier seed.
    /// The caller publishes it into a newly built app before signing, never into a live save.
    package static func stage(save: URL?, caches: URL?, destination: URL, cancelled: () -> Bool = { false }) throws {
        let fm = FileManager.default
        var required: Int64 = 0
        if let save { required += try inspect(save, caches: false).bytes }
        if let caches { required += try inspect(caches, caches: true).bytes }
        let parent = destination.deletingLastPathComponent()
        let capacity = try fm.attributesOfFileSystem(forPath: parent.path)
        guard let free = capacity[.systemFreeSize] as? NSNumber,
              free.int64Value >= required + 64 * 1024 * 1024 else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        guard !fm.fileExists(atPath: destination.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".offline-seed-" + UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { if fm.fileExists(atPath: staging.path) { try? fm.removeItem(at: staging) } }
        if cancelled() { throw CancellationError() }
        if let save { try fm.copyItem(at: save, to: staging.appendingPathComponent("save")) }
        if let caches {
            for item in try fm.contentsOfDirectory(at: caches, includingPropertiesForKeys: nil) {
                if item.lastPathComponent == ".DS_Store" { continue }
                guard let index = cacheIndex(item.lastPathComponent) else {
                    throw ValidationError.unsupportedCacheName(item.lastPathComponent)
                }
                if cancelled() { throw CancellationError() }
                try fm.copyItem(at: item, to: staging.appendingPathComponent("temp_cache" + String(index)))
            }
        }
        if cancelled() { throw CancellationError() }
        // The source may change after inventory. Validate the private copy before
        // publishing, so a newly inserted symlink never becomes a runnable seed.
        _ = try inspect(staging, caches: false)
        try fm.moveItem(at: staging, to: destination)
    }

    package static func inspect(_ root: URL, caches: Bool) throws -> Self {
        let fm = FileManager.default
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw ValidationError.symbolicLink }
        guard values.isDirectory == true else { throw ValidationError.notDirectory }
        if caches {
            var seen = Set<Int>()
            for item in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                if item.lastPathComponent == ".DS_Store" { continue }
                let name = item.lastPathComponent
                guard let index = cacheIndex(name), seen.insert(index).inserted else {
                    throw ValidationError.unsupportedCacheName(name)
                }
                let v = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard v.isSymbolicLink != true else { throw ValidationError.symbolicLink }
                guard v.isDirectory == true else { throw ValidationError.notDirectory }
            }
        }
        var files = 0, bytes: Int64 = 0
        var walkError: Error?
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey], errorHandler: { _, error in
            walkError = error
            return false
        }) else { throw ValidationError.notDirectory }
        for case let file as URL in walker {
            let v = try file.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            if v.isSymbolicLink == true { throw ValidationError.symbolicLink }
            guard v.isRegularFile == true || v.isDirectory == true else { throw ValidationError.unsupportedFile }
            if v.isRegularFile == true && file.lastPathComponent != ".DS_Store" { files += 1; bytes += Int64(v.fileSize ?? 0) }
        }
        if let error = walkError { throw error }
        guard files > 0 else { throw ValidationError.empty }
        return Self(files: files, bytes: bytes)
    }
}
