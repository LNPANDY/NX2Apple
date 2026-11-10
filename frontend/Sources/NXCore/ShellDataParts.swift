import Foundation

/// A game file too large for one devicectl copy goes over as parts (#899). `devicectl device copy to` does not stream: CoreDeviceService
/// reads the whole source into memory first (`Data(contentsOf:)` in TransferFilesActionImplementation). With a file near the Mac's
/// memory, CoreDeviceService swaps until it stalls and nothing reaches the device (the file there stays at 0 KB), or the connection
/// drops (`CoreDeviceError 3`). Each part is one copy of at most `partSize`, so only one part is in memory at a time.
///
/// On the device a part is `<file>.nxpart.<index>.<count>` next to the file it belongs to (`romfs.img.nxpart.0003.0009`). The shared
/// app joins a complete set into `<file>` when it starts (frontend-ios `DataParts`), part by part, so it needs at most one part of
/// extra space. Every part but the last is exactly `partSize` long: the shared app checks that, and the launcher and the app use the
/// same value. A part that is already on the device with its size is not sent again, so a send that stops halfway resumes.
package enum ShellDataParts {
    /// The size of every part but the last: 512 MiB. The same value as `DataParts.partSize` in frontend-ios.
    package static let partSize: Int64 = 512 << 20

    /// What the data copy sends: a whole file, or one part of a file.
    package enum Item: Equatable {
        case whole(String)
        case part(String, index: Int, count: Int)

        /// The file in the archive the item is taken from.
        package var file: String {
            switch self { case .whole(let f), .part(let f, _, _): return f }
        }
    }

    /// The device name of part `index` (from 0) of `count` of `file` (a path relative to the game's folder).
    package static func name(of file: String, index: Int, count: Int) -> String {
        file + ".nxpart." + String(format: "%04d", index) + "." + String(format: "%04d", count)
    }

    /// Whether `path` on the device is a part of `file`.
    package static func isPart(_ path: String, of file: String) -> Bool {
        path.hasPrefix(file + ".nxpart.")
    }

    package static func count(size: Int64, partSize: Int64 = partSize) -> Int {
        Int(max(1, (size + partSize - 1) / partSize))
    }

    /// The bytes of part `index` of a file of `size`: `partSize`, the rest for the last one.
    package static func range(index: Int, size: Int64, partSize: Int64 = partSize) -> (offset: Int64, length: Int64) {
        let offset = Int64(index) * partSize
        return (offset, min(partSize, size - offset))
    }

    /// The largest file sent whole when the shared app on the device may not join parts (an app signed by another tool, built by an
    /// older launcher): a quarter of the Mac's memory, so a file CoreDeviceService can still read in one go, and never below one part.
    package static func singleCopyLimit(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Int64 {
        max(partSize, Int64(clamping: physicalMemory / 4))
    }

    /// What to send, in a stable order: every local file the device does not have with its size. A file larger than `splitAbove`
    /// goes as parts, of which only those not on the device with their size are sent. A file the device has whole needs nothing.
    package static func toCopy(local: [String: Int64], device: [String: Int64], splitAbove: Int64, partSize: Int64 = partSize) -> [Item] {
        var items: [Item] = []
        for (file, size) in local.sorted(by: { $0.key < $1.key }) where device[file] != size {
            guard size > splitAbove else { items.append(.whole(file)); continue }
            let count = count(size: size, partSize: partSize)
            for index in 0..<count where device[name(of: file, index: index, count: count)] != range(index: index, size: size, partSize: partSize).length {
                items.append(.part(file, index: index, count: count))
            }
        }
        return items
    }

    /// The bytes an item sends.
    package static func bytes(of item: Item, local: [String: Int64], partSize: Int64 = partSize) -> Int64 {
        let size = local[item.file] ?? 0
        switch item {
        case .whole: return size
        case .part(_, let index, _): return range(index: index, size: size, partSize: partSize).length
        }
    }

    /// Writes part `index` of `source` to `destination`, 8 MiB at a time, so the launcher holds no more than that in memory either.
    package static func writePart(source: String, index: Int, size: Int64, partSize: Int64 = partSize, to destination: String) throws {
        let (offset, length) = range(index: index, size: size, partSize: partSize)
        guard let input = FileHandle(forReadingAtPath: source) else { throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: source]) }
        defer { try? input.close() }
        FileManager.default.createFile(atPath: destination, contents: nil)
        guard let output = FileHandle(forWritingAtPath: destination) else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination]) }
        defer { try? output.close() }
        try input.seek(toOffset: UInt64(offset))
        var left = length
        while left > 0 {
            let chunk = try autoreleasepool { try input.read(upToCount: Int(min(left, 8 << 20))) } ?? Data()
            guard !chunk.isEmpty else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: source]) }
            try output.write(contentsOf: chunk)
            left -= Int64(chunk.count)
        }
    }

    /// The device file that says what the shared app can do, written by the app at every start (frontend-ios `DataParts`).
    package static let featuresFile = "Documents/shell-features.txt"
    /// The line of `featuresFile` that says the app joins parts.
    package static let joinsPartsLine = "data-parts 1"

    package static func joinsParts(features text: String?) -> Bool {
        text?.split(whereSeparator: \.isNewline).contains { $0.trimmingCharacters(in: .whitespaces) == joinsPartsLine } ?? false
    }

    package static func featuresCommand(xcrun: String, device: String, bundleID: String, destination: String) -> [String] {
        [xcrun, "devicectl", "device", "copy", "from", "--device", device, "--domain-type", "appDataContainer",
         "--domain-identifier", bundleID, "--source", featuresFile, "--destination", destination]
    }
}

extension ShellInstaller {
    /// Whether the app on the device said, at its last start, that it joins parts. An app that never started, or one built
    /// before parts, has no such line: false.
    func appSaysItJoinsParts(bundleID: String, label: String) -> Bool {
        let copy = NSTemporaryDirectory() + "nspb-shell-features-\(UUID().uuidString.prefix(8)).txt"
        defer { try? FileManager.default.removeItem(atPath: copy) }
        _ = run(ShellDataParts.featuresCommand(xcrun: xcrun, device: device, bundleID: bundleID, destination: copy), env: nil, label: label, step: { _ in nil })
        return ShellDataParts.joinsParts(features: try? String(contentsOfFile: copy, encoding: .utf8))
    }
}
