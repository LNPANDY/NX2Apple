import Foundation

/// The game data onto a drive or a folder of this Mac (LNPANDY/NX2Apple#416), for the iPhone's "Game data" folder. A plain file copy: no
/// device and no signing. The shell finds a game's data in `<chosen folder>/<title ID>/` by name (GameCatalogue.swift, `DataLocator`:
/// `holder(of: titleFolder)` accepts a `romfs.img` of the size the game's manifest names), and by scanning up to two levels for the
/// image's identity, which the shell derives from the image itself (RomfsIdentity.swift). So `romfs.img` and the `aoc/` images the
/// install copies go to `<folder>/<title ID>/`, the same files and relative paths as `Documents/games/<title ID>/`, and no sidecar file
/// carries the identity.
package enum DriveCopy {
    /// What a drive says about itself.
    package struct Volume: Equatable {
        package var freeBytes: Int64
        package var fileSystem: String   // statfs's name: "apfs", "exfat", "msdos" (FAT32), "hfs", "ntfs"
        package var readOnly: Bool

        package init(freeBytes: Int64, fileSystem: String, readOnly: Bool) {
            self.freeBytes = freeBytes; self.fileSystem = fileSystem; self.readOnly = readOnly
        }
    }

    /// Why the copy stops before it starts.
    package enum Problem: Equatable {
        case readOnly
        /// A FAT32 volume holds no file over 4 GB (4 GiB minus one byte). `largest` is the biggest file of the game's data.
        case fat32(largest: Int64)
        case noSpace(needed: Int64, free: Int64)
    }

    package static let fat32FileLimit: Int64 = 4_294_967_295

    /// The name a player knows the file system by.
    package static func fileSystemName(_ statfsName: String) -> String {
        switch statfsName.lowercased() {
        case "msdos": return "FAT32"
        case "exfat": return "exFAT"
        case "apfs": return "APFS"
        case "hfs": return "Mac OS Extended"
        case "ntfs": return "NTFS"
        default: return statfsName.uppercased()
        }
    }

    /// The volume that holds `path` (or the nearest folder above it that exists, for a folder the copy makes). nil when nothing answers.
    package static func volume(at path: String, fm: FileManager = .default) -> Volume? {
        var probe = path
        while !fm.fileExists(atPath: probe), probe != "/", !probe.isEmpty { probe = (probe as NSString).deletingLastPathComponent }
        var info = statfs()
        guard statfs(probe, &info) == 0 else { return nil }
        let name = withUnsafePointer(to: &info.f_fstypename) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) } }
        let (prod, overflow) = info.f_bavail.multipliedReportingOverflow(by: UInt64(info.f_bsize))
        let freeBytes = overflow || prod > UInt64(Int64.max) ? Int64.max : Int64(prod)
        return Volume(freeBytes: freeBytes, fileSystem: name, readOnly: info.f_flags & UInt32(MNT_RDONLY) != 0)
    }

    /// What stops the copy of `files` (relative path to size) onto `volume`, nil when it can go ahead. `have` is what the folder holds
    /// already at the same size, which needs no room again. The order is the order a player can fix: read-only, then the file system,
    /// then the space.
    package static func problem(files: [String: Int64], have: [String: Int64] = [:], volume: Volume) -> Problem? {
        if volume.readOnly { return .readOnly }
        let largest = files.values.max() ?? 0
        if fileSystemName(volume.fileSystem) == "FAT32", largest > fat32FileLimit { return .fat32(largest: largest) }
        let needed = bytesToCopy(files: files, have: have)
        return needed > volume.freeBytes ? .noSpace(needed: needed, free: volume.freeBytes) : nil
    }

    /// The bytes that still have to go over: files the target lacks or holds at another size.
    package static func bytesToCopy(files: [String: Int64], have: [String: Int64]) -> Int64 {
        files.reduce(Int64(0)) { $0 + (have[$1.key] == $1.value ? 0 : $1.value) }
    }

    /// `<chosen folder>/<title ID>`
    package static func destination(folder: String, titleID: String) -> String { folder + "/" + titleID }

    package enum CopyError: Error, Equatable { case cancelled }

    /// Copies `files` (paths relative to `archive`) into `destination`. A file already there at the same size is left alone, so a
    /// second run finishes a first that stopped. Each file is written under a temporary name and renamed when whole, so a drive pulled
    /// out midway never leaves a cut-off `romfs.img` that looks complete. `progress` gets the bytes done and the total to copy.
    package static func copy(archive: String, files: [String: Int64], origins: [String: String] = [:], to destination: String,
                             chunk: Int = 8 << 20, progress: (Int64, Int64) -> Void, cancelled: () -> Bool = { false }) throws {
        let fm = FileManager.default
        let have = ShellInstall.localFiles(in: destination)
        let pending = files.filter { have[$0.key] != $0.value }.keys.sorted()
        let total = pending.reduce(Int64(0)) { $0 + (files[$1] ?? 0) }
        var done: Int64 = 0
        progress(0, total)
        for relative in pending {
            if cancelled() { throw CopyError.cancelled }
            let target = destination + "/" + relative, partial = target + ".partial"
            let sourcePath = origins[relative] ?? (archive + "/" + relative)
            try fm.createDirectory(atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try? fm.removeItem(atPath: partial)
            guard fm.createFile(atPath: partial, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: partial])
            }
            let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: sourcePath))
            let output = try FileHandle(forWritingTo: URL(fileURLWithPath: partial))
            defer { try? input.close(); try? output.close() }
            while true {
                if cancelled() { try? fm.removeItem(atPath: partial); throw CopyError.cancelled }
                guard let data = try input.read(upToCount: chunk), !data.isEmpty else { break }
                try output.write(contentsOf: data)
                done += Int64(data.count)
                progress(done, total)
            }
            try output.close()
            try? fm.removeItem(atPath: target)
            try fm.moveItem(atPath: partial, toPath: target)
        }
        progress(total, total)
    }
}
