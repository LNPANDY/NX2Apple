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

    /// Minimum free bytes checked on the shell cache volume when an iOS build writes to a separate external output volume.
    package static let shellRootMinimumBytes: Int64 = 4_000_000_000

    /// True for high-compression Switch packages (`.nsz` and `.xcz`) whose decompression and intermediate outputs peak around 3.5x.
    package static func isCompressedPackage(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "nsz" || ext == "xcz"
    }

    /// Estimated peak space needed on the output volume: 1.0x for uncompressed inputs and 3.5x for `.nsz` / `.xcz` archives.
    package static func estimatedNeeded(for paths: [String], fm: FileManager = .default) -> Int64 {
        var total: Int64 = 0
        for path in paths where !path.isEmpty {
            let bytes = size(of: [path], fm: fm)
            guard bytes > 0 else { continue }
            let scaled: Int64
            if isCompressedPackage(path) {
                let half = bytes / 2
                scaled = bytes <= (Int64.max - half) / 3 ? bytes * 3 + half : Int64.max
            } else {
                scaled = bytes
            }
            total = total <= Int64.max - scaled ? total + scaled : Int64.max
        }
        return total
    }

    /// Stable volume identifier for `path` (or its nearest existing ancestor), nil when the file system cannot answer.
    package static func volumeID(at path: String, fm: FileManager = .default) -> String? {
        guard !path.isEmpty else { return nil }
        var url = URL(fileURLWithPath: path)
        while !fm.fileExists(atPath: url.path), url.path != "/" { url.deleteLastPathComponent() }
        if let values = try? url.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeURLKey]) {
            if let uuid = values.volumeUUIDString, !uuid.isEmpty { return "uuid:" + uuid }
            if let vol = values.volume?.standardizedFileURL.path, !vol.isEmpty { return "vol:" + vol }
        }
        if let dev = (try? fm.attributesOfItem(atPath: url.path))?[.systemNumber] as? NSNumber {
            return "dev:\(dev.int64Value)"
        }
        return nil
    }

    /// Whether two paths resolve to the same volume. Returns true when either volume cannot be determined so unknown mounts never false-block.
    package static func sameVolume(
        _ first: String,
        _ second: String,
        volumeID: (String) -> String? = { BuildSpace.volumeID(at: $0) }
    ) -> Bool {
        guard !first.isEmpty, !second.isEmpty,
              let v1 = volumeID(first), let v2 = volumeID(second) else { return true }
        return v1 == v2
    }

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
    /// macOS answers 0 (or nil) for `volumeAvailableCapacityForImportantUsage` on some external drives such as exFAT (#1155),
    /// so a non-positive or missing answer falls back to `statfs` (`DriveCopy.volume`).
    package static func available(
        at path: String,
        fm: FileManager = .default,
        importantCapacity: (URL) -> Int64? = {
            (try? $0.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
        },
        fallbackCapacity: (String, FileManager) -> Int64? = { DriveCopy.volume(at: $0, fm: $1)?.freeBytes }
    ) -> Int64? {
        guard !path.isEmpty else { return nil }
        var url = URL(fileURLWithPath: path)
        while !fm.fileExists(atPath: url.path), url.path != "/" { url.deleteLastPathComponent() }
        if let important = importantCapacity(url), important > 0 { return important }
        return fallbackCapacity(url.path, fm)
    }

    package static func text(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}
