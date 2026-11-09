import Foundation

/// The free-space check before a build (LNPANDY/NX2Apple#966). The one number the launcher knows for certain is the size of the
/// files it was given, and a build needs at least that much, so that is the lower bound it checks. It does not guess the rest:
/// the message says the estimate is a lower bound, and that a stopped build keeps its progress. Nothing is removed automatically.
package struct BuildSpace: Equatable, Sendable {
    /// The least the build needs: the game files' size.
    package var needed: Int64
    package var available: Int64

    package init(needed: Int64, available: Int64) { self.needed = needed; self.available = available }

    package var isShort: Bool { available < needed }

    /// The size in bytes of the files and folders (recursively), unreadable ones count as 0.
    package static func size(of paths: [String], fm: FileManager = .default) -> Int64 {
        var total: Int64 = 0
        for path in paths where !path.isEmpty {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir) else { continue }
            if !isDir.boolValue {
                total += (try? fm.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
                continue
            }
            guard let walk = fm.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { continue }
            for case let url as URL in walk {
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
            }
        }
        return total
    }

    /// The free bytes on the volume of `path` (or of its nearest existing parent), nil when the system cannot say.
    package static func available(at path: String, fm: FileManager = .default) -> Int64? {
        var url = URL(fileURLWithPath: path)
        while !fm.fileExists(atPath: url.path), url.path != "/" { url.deleteLastPathComponent() }
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    package static func text(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}
