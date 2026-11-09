import Foundation

/// Joins a game file the Mac launcher sent in parts (LNPANDY/NX2Apple#899). devicectl reads a whole file into the Mac's memory before
/// it sends it, so the launcher sends a file larger than one part as `<file>.nxpart.<index>.<count>` (`ShellDataParts` in the
/// launcher's NXCore). The parts sit next to the file they belong to, in the game's folder of `Documents/games/` or below it.
///
/// A complete set becomes `<file>` again: the parts are appended one by one to `<file>.nxjoin`, each part removed once its bytes
/// are written, and the join is renamed over `<file>`. The device needs at most one part of extra space. A join that stops (the
/// app quits, the phone restarts) goes on at the next start: `<file>.nxjoin` then holds the parts before the first one still
/// there, which is `index * partSize` bytes, and a few bytes more when it stopped while appending, which are cut off. A join
/// that does not fit (the parts before it were sent again, or it is shorter than it should be) is removed, and the parts wait
/// for the ones the launcher sends again. A set that is not complete is left alone: the rest is on its way.
///
/// The app also writes `Documents/shell-features.txt`, so that a launcher sending data to an app it did not build itself can tell
/// whether this app joins parts.
public enum DataParts {
    /// The size of every part but the last: 512 MiB. The same value as `ShellDataParts.partSize` in the launcher.
    public static let partSize: Int64 = 512 << 20
    static let marker = ".nxpart."
    static let joinSuffix = ".nxjoin"
    public static let featuresName = "shell-features.txt"
    static let features = "data-parts 1\n"

    struct Name: Equatable { var file: String; var index: Int; var count: Int }

    /// `romfs.img.nxpart.0003.0009` → (romfs.img, 3, 9). Nil for any other name.
    static func parse(_ name: String) -> Name? {
        guard let range = name.range(of: marker, options: .backwards) else { return nil }
        let file = String(name[..<range.lowerBound])
        let numbers = name[range.upperBound...].split(separator: ".", omittingEmptySubsequences: false)
        guard !file.isEmpty, numbers.count == 2, let index = Int(numbers[0]), let count = Int(numbers[1]),
              count > 0, index >= 0, index < count else { return nil }
        return Name(file: file, index: index, count: count)
    }

    /// Writes `shell-features.txt` into `documents`, unless it says so already.
    public static func writeFeatures(documents: URL, fileManager fm: FileManager = .default) {
        let url = documents.appendingPathComponent(featuresName)
        if (try? String(contentsOf: url, encoding: .utf8)) == features { return }
        try? fm.createDirectory(at: documents, withIntermediateDirectories: true)
        try? Data(features.utf8).write(to: url, options: .atomic)
    }

    /// Joins every complete set of parts under `appDataRoot` (`Documents/games`). Returns the files that were made whole.
    @discardableResult
    public static func joinAll(appDataRoot: URL, partSize: Int64 = partSize, fileManager fm: FileManager = .default) -> [URL] {
        var sets: [String: (folder: URL, file: String, count: Int, parts: [Int: URL])] = [:]
        guard let walk = fm.enumerator(at: appDataRoot, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        for case let url as URL in walk {
            guard let name = parse(url.lastPathComponent),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let folder = url.deletingLastPathComponent()
            let key = folder.path + "/" + name.file + "#" + String(name.count)
            var set = sets[key] ?? (folder, name.file, name.count, [:])
            set.parts[name.index] = url
            sets[key] = set
        }
        var joined: [URL] = []
        for (_, set) in sets.sorted(by: { $0.key < $1.key }) {
            let file = set.folder.appendingPathComponent(set.file)
            if join(file: file, count: set.count, parts: set.parts, partSize: partSize, fm: fm) { joined.append(file) }
        }
        return joined
    }

    /// One set. True when `file` is whole now.
    static func join(file: URL, count: Int, parts: [Int: URL], partSize: Int64, fm: FileManager) -> Bool {
        func size(_ url: URL) -> Int64? { ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value }
        guard let first = parts.keys.min(), (first..<count).allSatisfy({ parts[$0] != nil }) else { return false }
        // Every part but the last is one part long, the last one at most that: anything else is not a set this app can join
        for (index, url) in parts {
            guard let s = size(url), index == count - 1 ? (s > 0 && s <= partSize) : s == partSize else { return false }
        }
        let join = URL(fileURLWithPath: file.path + joinSuffix)
        let done = Int64(first) * partSize
        if first == 0 {
            try? fm.removeItem(at: join)
            guard fm.createFile(atPath: join.path, contents: nil) else { return false }
        } else {
            guard let have = size(join), have >= done else { try? fm.removeItem(at: join); return false }
        }
        guard let out = try? FileHandle(forWritingTo: join) else { return false }
        defer { try? out.close() }
        do {
            try out.truncate(atOffset: UInt64(done))
            try out.seekToEnd()
            for index in first..<count {
                guard let url = parts[index], let input = try? FileHandle(forReadingFrom: url) else { return false }
                defer { try? input.close() }
                while true {
                    let chunk = try autoreleasepool { try input.read(upToCount: 8 << 20) } ?? Data()
                    if chunk.isEmpty { break }
                    try out.write(contentsOf: chunk)
                }
                try out.synchronize()
                try fm.removeItem(at: url)
            }
            try out.close()
        } catch {
            return false
        }
        // rename(2) puts the whole file in place of an older one in one step
        return rename(join.path, file.path) == 0
    }
}
