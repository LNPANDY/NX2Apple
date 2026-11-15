import Darwin
import Foundation

/// Copies game data onto an external drive or local folder (LNPANDY/NX2Apple#416) for the iPhone app's "Game data" picker.
/// When a game name is known, data lands in `<folder>/<SafeName>/<SafeName>.img` alongside `aoc/` and `.titleid`
/// (`<SafeName> (<TitleID>)` on collision). Existing `<folder>/<TitleID>/romfs.img` folders on the same volume are upgraded
/// in place by atomic rename, and matching `DMROMFS1` base images overwrite only the trailing `DMMSLTR1` shader section.
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

    /// Result of comparing two `DMROMFS1` images for 1-second partial trailer overwrite.
    package enum TrailerDelta: Equatable, Sendable {
        case fullCopy
        case identical
        case partialOverwrite(baseSize: UInt64, sourceSize: UInt64, destinationSize: UInt64)

        package var trailerBytesToWrite: Int64 {
            if case .partialOverwrite(let base, let src, _) = self, src > base { return Int64(src - base) }
            return 0
        }

        package var netSpaceNeeded: Int64 {
            if case .partialOverwrite(_, let src, let dst) = self, src > dst { return Int64(src - dst) }
            return 0
        }
    }

    package static let fat32FileLimit: Int64 = 4_294_967_295
    private static let headerSize: UInt64 = 32, footerSize: UInt64 = 64
    private static let pageAlignment: UInt64 = 16_384, footerAlignment: UInt64 = 8

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
        let name = withUnsafePointer(to: &info.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
        }
        let (prod, overflow) = info.f_bavail.multipliedReportingOverflow(by: UInt64(info.f_bsize))
        let freeBytes = overflow || prod > UInt64(Int64.max) ? Int64.max : Int64(prod)
        return Volume(freeBytes: freeBytes, fileSystem: name, readOnly: info.f_flags & UInt32(MNT_RDONLY) != 0)
    }

    /// `<chosen folder>/<title ID>` when no game name is supplied.
    package static func destination(folder: String, titleID: String) -> String {
        destination(folder: folder, name: "", titleID: titleID)
    }

    /// `<chosen folder>/<SafeName>` (or `<SafeName> (<TitleID>)` when another game already owns `<SafeName>`).
    package static func destination(folder: String, name: String, titleID: String, fm: FileManager = .default) -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return titleID.isEmpty ? folder : joinPath(folder, titleID) }
        let sub = RomFSArchive.archiveDirectoryName(gameName: trimmedName, titleID: titleID, gamesRoot: folder, fm: fm)
        return joinPath(folder, sub)
    }

    /// Renames a legacy `<folder>/<titleID>/romfs.img` directory into `<folder>/<SafeName>/<SafeName>.img` on the same volume
    /// before checking or copying, when `name` is non-empty and the target folder does not belong to another title.
    @discardableResult
    package static func upgradeLegacyFolder(folder: String, name: String, titleID: String, preferredDestination: String? = nil,
                                            preferredImageName: String? = nil, fm: FileManager = .default) -> String {
        let dest = preferredDestination ?? destination(folder: folder, name: name, titleID: titleID, fm: fm)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedID = titleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !folder.isEmpty, !trimmedName.isEmpty, !trimmedID.isEmpty, volume(at: folder, fm: fm)?.readOnly != true else { return dest }

        let destName = (dest as NSString).lastPathComponent
        let targetImageName = preferredImageName ?? (destName + ".img")
        if let legacyDir = findLegacyTitleFolder(in: folder, titleID: trimmedID, excludingName: destName, fm: fm),
           isRegularFile(joinPath(legacyDir, "romfs.img"), fm: fm) {
            if !fm.fileExists(atPath: dest) {
                if (try? fm.moveItem(atPath: legacyDir, toPath: dest)) != nil {
                    renameLegacyImageIfNeeded(in: dest, targetImageName: targetImageName, fm: fm)
                    writeTitleIDMarker(in: dest, titleID: trimmedID)
                }
            } else if folderAllowsTitleID(dest, titleID: trimmedID, fm: fm) {
                let targetImg = joinPath(dest, targetImageName)
                if !fm.fileExists(atPath: targetImg) {
                    try? fm.moveItem(atPath: joinPath(legacyDir, "romfs.img"), toPath: targetImg)
                }
                for item in ((try? fm.contentsOfDirectory(atPath: legacyDir)) ?? [])
                where !item.hasPrefix(".") && item != "romfs.img" && !item.lowercased().hasSuffix(".img.id") {
                    let dstChild = joinPath(dest, item)
                    if !fm.fileExists(atPath: dstChild) { try? fm.moveItem(atPath: joinPath(legacyDir, item), toPath: dstChild) }
                }
                writeTitleIDMarker(in: dest, titleID: trimmedID)
                let remaining = ((try? fm.contentsOfDirectory(atPath: legacyDir)) ?? [])
                    .filter { !$0.hasPrefix(".") && !$0.lowercased().hasSuffix(".img.id") }
                if remaining.isEmpty { try? fm.removeItem(atPath: legacyDir) }
            }
        } else if fm.fileExists(atPath: dest),
                  destName.caseInsensitiveCompare(trimmedID) != .orderedSame,
                  folderAllowsTitleID(dest, titleID: trimmedID, fm: fm) {
            renameLegacyImageIfNeeded(in: dest, targetImageName: targetImageName, fm: fm)
            writeTitleIDMarker(in: dest, titleID: trimmedID)
        }
        return dest
    }

    /// Read-only summary of a single game's planned transfer onto `folder` without mutating the drive.
    package struct TransferInspection: Equatable, Sendable {
        package var destination: String
        package var bytesToCopy: Int64
        package var netSpaceNeeded: Int64
        package var largestFile: Int64

        package init(destination: String, bytesToCopy: Int64, netSpaceNeeded: Int64, largestFile: Int64) {
            self.destination = destination
            self.bytesToCopy = bytesToCopy
            self.netSpaceNeeded = netSpaceNeeded
            self.largestFile = largestFile
        }
    }

    /// Evaluates `bytesToCopy`, `netSpaceNeeded`, and `largestFile` in a single read-only pass (never renaming or writing on `folder`).
    package static func inspectTransfer(archive: String, name: String, titleID: String, inFolder folder: String,
                                        fm: FileManager = .default) -> TransferInspection {
        let dest = destination(folder: folder, name: name, titleID: titleID, fm: fm)
        let transfer = transferFiles(archive: archive, name: name, titleID: titleID, destination: dest, fm: fm)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedID = titleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let destName = (dest as NSString).lastPathComponent
        let dstPrimary = RomFSArchive.primaryImageName(inFiles: transfer.sizes.keys, folderName: destName)

        var compareDir = dest
        var have = ShellInstall.localFiles(in: dest, fm: fm)
        var targetOverrides: [String: String] = [:]
        if !trimmedName.isEmpty, !trimmedID.isEmpty,
           let legacyDir = findLegacyTitleFolder(in: folder, titleID: trimmedID, excludingName: destName, fm: fm),
           isRegularFile(joinPath(legacyDir, "romfs.img"), fm: fm),
           (!fm.fileExists(atPath: dest) || folderAllowsTitleID(dest, titleID: trimmedID, fm: fm)) {
            if !fm.fileExists(atPath: dest) {
                compareDir = legacyDir
                have = ShellInstall.localFiles(in: legacyDir, fm: fm)
                if let dstPrimary, dstPrimary != "romfs.img", let legacySize = have.removeValue(forKey: "romfs.img") {
                    have[dstPrimary] = legacySize
                    targetOverrides[dstPrimary] = joinPath(legacyDir, "romfs.img")
                }
            } else if let dstPrimary, !fm.fileExists(atPath: joinPath(dest, dstPrimary)),
                      let legacySize = (try? fm.attributesOfItem(atPath: joinPath(legacyDir, "romfs.img"))[.size] as? NSNumber)?.int64Value {
                have[dstPrimary] = legacySize
                targetOverrides[dstPrimary] = joinPath(legacyDir, "romfs.img")
            }
        } else if !trimmedName.isEmpty, !trimmedID.isEmpty,
                  fm.fileExists(atPath: dest),
                  destName.caseInsensitiveCompare(trimmedID) != .orderedSame,
                  folderAllowsTitleID(dest, titleID: trimmedID, fm: fm),
                  let dstPrimary, dstPrimary != "romfs.img",
                  !fm.fileExists(atPath: joinPath(dest, dstPrimary)),
                  let legacySize = have.removeValue(forKey: "romfs.img") {
            have[dstPrimary] = legacySize
            targetOverrides[dstPrimary] = joinPath(dest, "romfs.img")
        }

        var totalBytes: Int64 = 0, totalNet: Int64 = 0, largest: Int64 = 0
        for relative in transfer.sizes.keys.sorted() {
            let sz = transfer.sizes[relative] ?? 0
            if sz > largest { largest = sz }
            let plan = plannedWrite(relative: relative, size: sz, have: have, archive: archive, origins: transfer.origins,
                                    destination: compareDir, targetOverride: targetOverrides[relative])
            let (nb, ob) = totalBytes.addingReportingOverflow(plan.bytesToWrite)
            totalBytes = ob ? Int64.max : nb
            let (nn, on) = totalNet.addingReportingOverflow(plan.netSpace)
            totalNet = on ? Int64.max : nn
        }
        return TransferInspection(destination: dest, bytesToCopy: totalBytes, netSpaceNeeded: totalNet, largestFile: largest)
    }

    /// Maps the archive's files for copying into `destination`, renaming the primary `.img` to `<DestinationFolderName>.img`
    /// whenever a non-empty game `name` is provided.
    package static func transferFiles(archive: String, name: String = "", titleID: String = "", destination destDir: String? = nil,
                                      fm: FileManager = .default) -> (sizes: [String: Int64], origins: [String: String]) {
        let raw = ShellInstall.transferSources(archive: archive, titleID: titleID, fm: fm)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              let srcPrimary = RomFSArchive.primaryImageName(inFiles: raw.sizes.keys, folderName: (archive as NSString).lastPathComponent),
              let primarySize = raw.sizes[srcPrimary] else { return raw }
        let resolvedDest = destDir ?? destination(folder: "/_", name: trimmedName, titleID: titleID, fm: fm)
        let destFolder = (resolvedDest as NSString).lastPathComponent
        guard !destFolder.isEmpty else { return raw }
        let dstPrimary = destFolder + ".img"
        guard dstPrimary != srcPrimary else { return raw }

        var sizes = raw.sizes, origins = raw.origins
        sizes.removeValue(forKey: srcPrimary)
        let srcPath = origins.removeValue(forKey: srcPrimary) ?? joinPath(archive, srcPrimary)
        sizes[dstPrimary] = primarySize
        origins[dstPrimary] = srcPath
        return (sizes, origins)
    }

    /// What stops the copy of `files` onto `volume`, nil when it can go ahead. Order: read-only, FAT32 limit, then net free space.
    package static func problem(files: [String: Int64], have: [String: Int64] = [:], volume: Volume,
                                archive: String = "", origins: [String: String] = [:], destination: String = "") -> Problem? {
        if volume.readOnly { return .readOnly }
        let largest = files.values.max() ?? 0
        if fileSystemName(volume.fileSystem) == "FAT32", largest > fat32FileLimit { return .fat32(largest: largest) }
        let neededSpace = destination.isEmpty
            ? bytesToCopy(files: files, have: have)
            : netSpaceNeeded(files: files, have: have, archive: archive, origins: origins, destination: destination)
        return neededSpace > volume.freeBytes ? .noSpace(needed: neededSpace, free: volume.freeBytes) : nil
    }

    /// The I/O bytes that still have to be written: missing/changed files, or only the `DMMSLTR1` trailer delta when base RomFS matches.
    package static func bytesToCopy(files: [String: Int64], have: [String: Int64],
                                    archive: String = "", origins: [String: String] = [:], destination: String = "") -> Int64 {
        files.keys.sorted().reduce(Int64(0)) { sum, relative in
            let fileBytes = plannedWrite(relative: relative, size: files[relative] ?? 0, have: have,
                                         archive: archive, origins: origins, destination: destination).bytesToWrite
            let (next, overflow) = sum.addingReportingOverflow(fileBytes)
            return overflow ? Int64.max : next
        }
    }

    /// Net additional free space required on `destination`'s volume (`max(0, srcSize - dstSize)` for in-place trailer updates).
    package static func netSpaceNeeded(files: [String: Int64], have: [String: Int64],
                                       archive: String = "", origins: [String: String] = [:], destination: String = "") -> Int64 {
        files.keys.sorted().reduce(Int64(0)) { sum, relative in
            let space = plannedWrite(relative: relative, size: files[relative] ?? 0, have: have,
                                     archive: archive, origins: origins, destination: destination).netSpace
            let (next, overflow) = sum.addingReportingOverflow(space)
            return overflow ? Int64.max : next
        }
    }

    package enum CopyError: Error, Equatable { case cancelled }

    /// Copies `files` into `destination`, using 1-second in-place partial trailer overwrite when an existing `DMROMFS1` image shares
    /// an identical base header + index, or falling back to a staged hidden `.partial-<uuid>` copy otherwise.
    package static func copy(archive: String, files: [String: Int64], origins: [String: String] = [:], to destination: String,
                             name: String = "", titleID: String = "", chunk: Int = 8 << 20,
                             progress: (Int64, Int64) -> Void, cancelled: () -> Bool = { false }) throws {
        let fm = FileManager.default
        let parentFolder = (destination as NSString).deletingLastPathComponent
        let destFolderName = (destination as NSString).lastPathComponent
        let effectiveID: String = {
            let trimmed = titleID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
            guard !archive.isEmpty, let marker = try? String(contentsOfFile: joinPath(archive, ".titleid"), encoding: .utf8) else { return "" }
            return marker.trimmingCharacters(in: .whitespacesAndNewlines)
        }()
        let effectiveName: String = {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
            guard !effectiveID.isEmpty, !destFolderName.isEmpty, destFolderName.caseInsensitiveCompare(effectiveID) != .orderedSame else { return "" }
            return destFolderName
        }()
        if !effectiveName.isEmpty, !effectiveID.isEmpty, !parentFolder.isEmpty {
            _ = upgradeLegacyFolder(folder: parentFolder, name: effectiveName, titleID: effectiveID, preferredDestination: destination,
                                    preferredImageName: RomFSArchive.primaryImageName(inFiles: files.keys, folderName: destFolderName), fm: fm)
        }

        let have = ShellInstall.localFiles(in: destination, fm: fm)
        var work: [(relative: String, plan: FileWritePlan)] = []
        var total: Int64 = 0
        for relative in files.keys.sorted() {
            let plan = plannedWrite(relative: relative, size: files[relative] ?? 0, have: have,
                                    archive: archive, origins: origins, destination: destination, chunk: max(4096, chunk))
            if case .skip = plan { continue }
            work.append((relative, plan))
            let (next, overflow) = total.addingReportingOverflow(plan.bytesToWrite)
            total = overflow ? Int64.max : next
        }

        var done: Int64 = 0
        progress(0, total)
        for (relative, plan) in work {
            if cancelled() { throw CopyError.cancelled }
            let target = joinPath(destination, relative)
            let sourcePath = origins[relative] ?? joinPath(archive, relative)
            switch plan {
            case .skip: break
            case .partial(let baseSize, let srcSize, let dstSize):
                try overwriteTrailer(sourcePath: sourcePath, targetPath: target, baseSize: baseSize, sourceSize: srcSize,
                                     destinationSize: dstSize, chunk: chunk, done: &done, total: total, progress: progress, cancelled: cancelled)
            case .stagedFullCopy:
                try copyWholeFileStaged(sourcePath: sourcePath, targetPath: target, chunk: chunk, done: &done, total: total,
                                        fm: fm, progress: progress, cancelled: cancelled)
            }
        }
        if !effectiveName.isEmpty, !effectiveID.isEmpty, fm.fileExists(atPath: destination) {
            writeTitleIDMarker(in: destination, titleID: effectiveID)
        }
        progress(total, total)
    }

    // MARK: - DMROMFS1 / DMMSLTR1 Binary Inspection & Comparison

    /// O(1) fingerprint of an image's valid `DMMSLTR1` footer (or `nil` when no trailer is present), used by transfer receipts.
    package static func trailerFingerprint(atPath path: String) -> String? {
        let fd = Darwin.open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { _ = Darwin.close(fd) }
        guard let fileSize = regularFileSize(fd: fd), fileSize >= headerSize,
              let head = preadBytes(fd: fd, offset: 0, count: Int(headerSize)),
              let parsed = parseDMROMFSHeader(head, fileSize: fileSize),
              case .validTrailer(let tag) = validateTrailer(fd: fd, fileSize: fileSize, baseSize: parsed.baseSize) else { return nil }
        return tag
    }

    /// Compares two `DMROMFS1` images (`sourcePath` and `destinationPath`) to decide whether `destinationPath` already matches,
    /// can be updated via in-place trailer overwrite (`[baseSize ..< sourceSize)`), or requires a full staged copy.
    package static func compareImages(source sourcePath: String, destination destinationPath: String, chunk: Int = 8 << 20) -> TrailerDelta {
        let srcFd = Darwin.open(sourcePath, O_RDONLY)
        guard srcFd >= 0 else { return .fullCopy }
        defer { _ = Darwin.close(srcFd) }

        let dstFd = Darwin.open(destinationPath, O_RDONLY)
        guard dstFd >= 0 else { return .fullCopy }
        defer { _ = Darwin.close(dstFd) }

        guard let srcInfo = regularFileInfo(fd: srcFd), let dstInfo = regularFileInfo(fd: dstFd),
              srcInfo.size >= headerSize, dstInfo.size >= headerSize,
              let srcHead = preadBytes(fd: srcFd, offset: 0, count: Int(headerSize)),
              let dstHead = preadBytes(fd: dstFd, offset: 0, count: Int(headerSize)),
              srcHead == dstHead,
              let parsed = parseDMROMFSHeader(srcHead, fileSize: srcInfo.size),
              dstInfo.size >= parsed.baseSize else { return .fullCopy }
        let srcSize = srcInfo.size, dstSize = dstInfo.size

        if case .invalid = validateTrailer(fd: srcFd, fileSize: srcSize, baseSize: parsed.baseSize) { return .fullCopy }

        let step = max(4096, chunk)
        if parsed.ioff > headerSize {
            let payloadLen = parsed.ioff - headerSize, sampleCap: UInt64 = 65_536
            if payloadLen <= sampleCap * 2 {
                guard rangesEqual(fdA: srcFd, fdB: dstFd, offset: headerSize, length: payloadLen, chunk: step) else { return .fullCopy }
            } else {
                guard rangesEqual(fdA: srcFd, fdB: dstFd, offset: headerSize, length: sampleCap, chunk: step),
                      rangesEqual(fdA: srcFd, fdB: dstFd, offset: parsed.ioff - sampleCap, length: sampleCap, chunk: step) else { return .fullCopy }
            }
        }
        guard rangesEqual(fdA: srcFd, fdB: dstFd, offset: parsed.ioff, length: parsed.isz, chunk: step) else { return .fullCopy }

        if srcSize == dstSize {
            if srcSize == parsed.baseSize { return .identical }
            let footerOff = srcSize - footerSize
            if rangesEqual(fdA: srcFd, fdB: dstFd, offset: footerOff, length: footerSize, chunk: Int(footerSize)),
               rangesEqual(fdA: srcFd, fdB: dstFd, offset: parsed.baseSize, length: footerOff - parsed.baseSize, chunk: step) {
                return .identical
            }
        }
        return .partialOverwrite(baseSize: parsed.baseSize, sourceSize: srcSize, destinationSize: dstSize)
    }

    // MARK: - Private Helpers

    private enum FileWritePlan {
        case skip
        case partial(baseSize: UInt64, srcSize: UInt64, dstSize: UInt64)
        case stagedFullCopy(size: Int64)

        var bytesToWrite: Int64 {
            switch self {
            case .skip: return 0
            case .partial(let base, let src, _): return src > base ? Int64(src - base) : 0
            case .stagedFullCopy(let size): return max(0, size)
            }
        }

        var netSpace: Int64 {
            switch self {
            case .skip: return 0
            case .partial(_, let src, let dst): return src > dst ? Int64(src - dst) : 0
            case .stagedFullCopy(let size): return max(0, size)
            }
        }
    }

    private static func plannedWrite(relative: String, size: Int64, have: [String: Int64], archive: String,
                                     origins: [String: String], destination: String, targetOverride: String? = nil,
                                     chunk: Int = 8 << 20) -> FileWritePlan {
        guard !destination.isEmpty else { return have[relative] == size ? .skip : .stagedFullCopy(size: size) }
        let sourcePath = origins[relative] ?? (archive.isEmpty ? "" : joinPath(archive, relative))
        let targetPath = targetOverride ?? joinPath(destination, relative)
        if !sourcePath.isEmpty, relative.lowercased().hasSuffix(".img"), isValidDMROMFSBase(atPath: sourcePath) {
            if FileManager.default.fileExists(atPath: targetPath) {
                switch compareImages(source: sourcePath, destination: targetPath, chunk: chunk) {
                case .identical: return .skip
                case .partialOverwrite(let base, let src, let dst): return .partial(baseSize: base, srcSize: src, dstSize: dst)
                case .fullCopy: return .stagedFullCopy(size: size)
                }
            }
            return .stagedFullCopy(size: size)
        }
        return have[relative] == size ? .skip : .stagedFullCopy(size: size)
    }

    private static func isValidDMROMFSBase(atPath path: String) -> Bool {
        let fd = Darwin.open(path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { _ = Darwin.close(fd) }
        guard let fileSize = regularFileSize(fd: fd), fileSize >= headerSize,
              let head = preadBytes(fd: fd, offset: 0, count: Int(headerSize)),
              let parsed = parseDMROMFSHeader(head, fileSize: fileSize) else { return false }
        if case .invalid = validateTrailer(fd: fd, fileSize: fileSize, baseSize: parsed.baseSize) { return false }
        return true
    }

    private enum TrailerValidation { case noTrailer, validTrailer(String), invalid }

    private static func parseDMROMFSHeader(_ head: [UInt8], fileSize: UInt64) -> (ioff: UInt64, isz: UInt64, baseSize: UInt64)? {
        guard head.count == Int(headerSize), head[0..<8].elementsEqual("DMROMFS1".utf8) else { return nil }
        let ioff = le64(head, 8), isz = le64(head, 16)
        guard ioff >= headerSize, ioff <= fileSize, isz <= fileSize - ioff else { return nil }
        return (ioff, isz, ioff + isz)
    }

    private static func validateTrailer(fd: Int32, fileSize: UInt64, baseSize: UInt64) -> TrailerValidation {
        if fileSize == baseSize { return .noTrailer }
        guard fileSize > baseSize, fileSize - baseSize >= footerSize else { return .invalid }
        let footerOffset = fileSize - footerSize
        guard let footer = preadBytes(fd: fd, offset: footerOffset, count: Int(footerSize)),
              footer[0..<8].elementsEqual("DMMSLTR1".utf8) else { return .invalid }
        let version = le32(footer, 8), gfxAPI = footer[12], flags = footer[13], chainLen = Int(le16(footer, 14))
        let baseRomfsSize = le64(footer, 16), mslOffset = le64(footer, 24), mslSize = le64(footer, 32)
        guard version == 1, (1...3).contains(gfxAPI), baseRomfsSize == baseSize,
              baseSize <= UInt64.max - (pageAlignment - 1),
              mslOffset == ((baseSize + (pageAlignment - 1)) & ~(pageAlignment - 1)),
              mslSize >= headerSize, mslOffset <= footerOffset, mslSize <= footerOffset - mslOffset else { return .invalid }
        let rawEnd = mslOffset + mslSize
        guard rawEnd <= UInt64.max - (footerAlignment - 1),
              ((rawEnd + (footerAlignment - 1)) & ~(footerAlignment - 1)) == footerOffset,
              chainLen <= 24 else { return .invalid }
        let prefix = footer[40..<(40 + chainLen)], padding = footer[(40 + chainLen)..<64]
        guard !prefix.contains(0), prefix.allSatisfy({ $0 < 0x80 }), padding.allSatisfy({ $0 == 0 }),
              let chain = String(bytes: prefix, encoding: .utf8) else { return .invalid }
        let sampleLen = Int(min(mslSize, 4096))
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in (preadBytes(fd: fd, offset: mslOffset, count: sampleLen) ?? []) { hash = (hash ^ UInt64(b)) &* 0x0000_0100_0000_01b3 }
        for b in (preadBytes(fd: fd, offset: rawEnd - UInt64(sampleLen), count: sampleLen) ?? []) { hash = (hash ^ UInt64(b)) &* 0x0000_0100_0000_01b3 }
        for b in footer { hash = (hash ^ UInt64(b)) &* 0x0000_0100_0000_01b3 }
        return .validTrailer(String(format: "trailer=%d:%d:%@:%llu:%llu:%016llx", gfxAPI, flags, chain, mslOffset, mslSize, hash))
    }

    private static func rangesEqual(fdA: Int32, fdB: Int32, offset: UInt64, length: UInt64, chunk: Int) -> Bool {
        if length == 0 { return true }
        let cap = Int(min(UInt64(max(4096, chunk)), length))
        var bufA = [UInt8](repeating: 0, count: cap), bufB = [UInt8](repeating: 0, count: cap)
        var cur = offset, left = length
        while left > 0 {
            let want = Int(min(UInt64(cap), left))
            guard preadIntoBool(fd: fdA, buffer: &bufA, count: want, offset: cur),
                  preadIntoBool(fd: fdB, buffer: &bufB, count: want, offset: cur) else { return false }
            if want == cap ? (bufA != bufB) : !bufA[0..<want].elementsEqual(bufB[0..<want]) { return false }
            cur += UInt64(want); left -= UInt64(want)
        }
        return true
    }

    private static func overwriteTrailer(sourcePath: String, targetPath: String, baseSize: UInt64, sourceSize: UInt64,
                                         destinationSize: UInt64, chunk: Int, done: inout Int64, total: Int64,
                                         progress: (Int64, Int64) -> Void, cancelled: () -> Bool) throws {
        if cancelled() { throw CopyError.cancelled }
        try PostBuildCleanup.breakHardLinksIfNeeded(at: targetPath)

        let srcFd = Darwin.open(sourcePath, O_RDONLY)
        guard srcFd >= 0 else { throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: sourcePath]) }
        defer { _ = Darwin.close(srcFd) }

        let dstFd = Darwin.open(targetPath, O_RDWR)
        guard dstFd >= 0 else { throw writeError(for: targetPath) }
        defer { _ = Darwin.close(dstFd) }
        guard let dstInfo = regularFileInfo(fd: dstFd), dstInfo.nlink <= 1 else { throw writeError(for: targetPath) }

        if sourceSize == baseSize {
            if cancelled() { throw CopyError.cancelled }
            if destinationSize > baseSize {
                guard Darwin.ftruncate(dstFd, off_t(baseSize)) == 0, Darwin.fsync(dstFd) == 0 else { throw writeError(for: targetPath) }
            }
            return
        }

        guard sourceSize >= baseSize + footerSize else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: sourcePath])
        }
        let payloadEnd = sourceSize - footerSize
        let zeroFooter = [UInt8](repeating: 0, count: Int(footerSize))
        var committed = false
        var dirtied = false
        defer {
            if dirtied && !committed {
                _ = Darwin.ftruncate(dstFd, off_t(baseSize))
                _ = Darwin.fsync(dstFd)
            }
        }

        dirtied = true
        if destinationSize >= baseSize + footerSize {
            try pwriteFrom(fd: dstFd, buffer: zeroFooter, count: zeroFooter.count, offset: destinationSize - footerSize, path: targetPath)
            guard Darwin.fsync(dstFd) == 0 else { throw writeError(for: targetPath) }
        }

        let step = max(4096, chunk)
        var buf = [UInt8](repeating: 0, count: step)
        var offset = baseSize
        while offset < payloadEnd {
            if cancelled() { throw CopyError.cancelled }
            let want = Int(min(UInt64(step), payloadEnd - offset))
            try preadInto(fd: srcFd, buffer: &buf, count: want, offset: offset, path: sourcePath)
            try pwriteFrom(fd: dstFd, buffer: buf, count: want, offset: offset, path: targetPath)
            offset += UInt64(want); done += Int64(want)
            progress(done, total)
        }

        if cancelled() { throw CopyError.cancelled }
        guard Darwin.fsync(dstFd) == 0 else { throw writeError(for: targetPath) }

        var footer = [UInt8](repeating: 0, count: Int(footerSize))
        try preadInto(fd: srcFd, buffer: &footer, count: footer.count, offset: payloadEnd, path: sourcePath)
        try pwriteFrom(fd: dstFd, buffer: footer, count: footer.count, offset: payloadEnd, path: targetPath)
        if destinationSize > sourceSize {
            guard Darwin.ftruncate(dstFd, off_t(sourceSize)) == 0 else { throw writeError(for: targetPath) }
        }
        guard Darwin.fsync(dstFd) == 0 else { throw writeError(for: targetPath) }
        committed = true
        done += Int64(footerSize)
        progress(done, total)
    }

    private static func copyWholeFileStaged(sourcePath: String, targetPath: String, chunk: Int, done: inout Int64, total: Int64,
                                            fm: FileManager, progress: (Int64, Int64) -> Void, cancelled: () -> Bool) throws {
        let parent = (targetPath as NSString).deletingLastPathComponent
        let fileName = (targetPath as NSString).lastPathComponent
        try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
        let partial = joinPath(parent, ".\(fileName).partial-\(UUID().uuidString)")
        defer { try? fm.removeItem(atPath: partial) }

        guard fm.createFile(atPath: partial, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: partial])
        }
        let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: sourcePath))
        let output = try FileHandle(forWritingTo: URL(fileURLWithPath: partial))
        var closedOutput = false
        defer { try? input.close(); if !closedOutput { try? output.close() } }
        let step = max(1, chunk)
        while true {
            if cancelled() {
                try? output.close(); closedOutput = true
                try? fm.removeItem(atPath: partial)
                throw CopyError.cancelled
            }
            guard let data = try autoreleasepool(invoking: { try input.read(upToCount: step) }), !data.isEmpty else { break }
            try output.write(contentsOf: data)
            done += Int64(data.count)
            progress(done, total)
        }
        _ = Darwin.fsync(output.fileDescriptor)
        try output.close(); closedOutput = true
        if Darwin.rename(partial, targetPath) != 0 {
            try? fm.removeItem(atPath: targetPath)
            try fm.moveItem(atPath: partial, toPath: targetPath)
        }
    }

    private static func regularFileInfo(fd: Int32) -> (size: UInt64, nlink: UInt16)? {
        var st = Darwin.stat()
        guard Darwin.fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size >= 0 else { return nil }
        return (UInt64(st.st_size), st.st_nlink)
    }

    private static func regularFileSize(fd: Int32) -> UInt64? { regularFileInfo(fd: fd)?.size }

    private static func preadBytes(fd: Int32, offset: UInt64, count: Int) -> [UInt8]? {
        guard count > 0 else { return [] }
        var buf = [UInt8](repeating: 0, count: count)
        return preadIntoBool(fd: fd, buffer: &buf, count: count, offset: offset) ? buf : nil
    }

    private static func preadIntoBool(fd: Int32, buffer: inout [UInt8], count: Int, offset: UInt64) -> Bool {
        guard count >= 0, count <= buffer.count, offset <= UInt64(Int64.max), UInt64(count) <= UInt64(Int64.max) - offset else { return false }
        var got = 0
        while got < count {
            let n = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.pread(fd, base.advanced(by: got), count - got, off_t(offset + UInt64(got)))
            }
            if n < 0 { if errno == EINTR { continue }; return false }
            if n == 0 { return false }
            got += n
        }
        return true
    }

    private static func preadInto(fd: Int32, buffer: inout [UInt8], count: Int, offset: UInt64, path: String) throws {
        guard preadIntoBool(fd: fd, buffer: &buffer, count: count, offset: offset) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: path])
        }
    }

    private static func pwriteFrom(fd: Int32, buffer: [UInt8], count: Int, offset: UInt64, path: String) throws {
        guard count >= 0, count <= buffer.count, offset <= UInt64(Int64.max), UInt64(count) <= UInt64(Int64.max) - offset else {
            throw writeError(for: path)
        }
        var put = 0
        while put < count {
            let n = buffer.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.pwrite(fd, base.advanced(by: put), count - put, off_t(offset + UInt64(put)))
            }
            if n < 0 { if errno == EINTR { continue }; throw writeError(for: path) }
            if n == 0 { throw writeError(for: path) }
            put += n
        }
    }

    private static func writeError(for path: String) -> Error {
        CocoaError(errno == ENOSPC ? .fileWriteOutOfSpace : .fileWriteUnknown, userInfo: [NSFilePathErrorKey: path])
    }

    private static func le16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) | (UInt16(b[o + 1]) << 8) }
    private static func le32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
    }
    private static func le64(_ b: [UInt8], _ o: Int) -> UInt64 {
        (0..<8).reduce(0) { $0 | (UInt64(b[o + $1]) << (8 * UInt64($1))) }
    }

    private static func joinPath(_ base: String, _ component: String) -> String {
        if base == "/" { return "/" + component }
        return (base.hasSuffix("/") ? String(base.dropLast()) : base) + "/" + component
    }

    private static func findLegacyTitleFolder(in folder: String, titleID: String, excludingName: String, fm: FileManager) -> String? {
        guard let entries = try? fm.contentsOfDirectory(atPath: folder) else { return nil }
        for entry in entries.sorted() where !entry.hasPrefix(".") {
            guard entry.caseInsensitiveCompare(titleID) == .orderedSame,
                  entry.caseInsensitiveCompare(excludingName) != .orderedSame else { continue }
            let path = joinPath(folder, entry)
            if (try? fm.attributesOfItem(atPath: path)[.type]) as? FileAttributeType == .typeDirectory { return path }
        }
        return nil
    }

    private static func isRegularFile(_ path: String, fm: FileManager) -> Bool {
        (try? fm.attributesOfItem(atPath: path)[.type]) as? FileAttributeType == .typeRegular
    }

    private static func folderAllowsTitleID(_ folderPath: String, titleID: String, fm: FileManager = .default) -> Bool {
        if let raw = try? String(contentsOfFile: joinPath(folderPath, ".titleid"), encoding: .utf8) {
            let marker = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !marker.isEmpty { return marker.caseInsensitiveCompare(titleID) == .orderedSame }
        }
        let folderName = (folderPath as NSString).lastPathComponent
        if isHexTitleID(folderName), folderName.caseInsensitiveCompare(titleID) != .orderedSame { return false }
        for entry in ((try? fm.contentsOfDirectory(atPath: folderPath)) ?? []).sorted()
        where !entry.hasPrefix(".") && entry.lowercased().hasSuffix(".img") && !entry.lowercased().contains(".nxpart") {
            let imgPath = joinPath(folderPath, entry)
            guard isRegularFile(imgPath, fm: fm) else { continue }
            if let owner = titleIDFromIdentityFile(imgPath + ".id") {
                return owner.caseInsensitiveCompare(titleID) == .orderedSame
            }
            let stem = (entry as NSString).deletingPathExtension
            if isHexTitleID(stem), stem.caseInsensitiveCompare(titleID) != .orderedSame { return false }
        }
        return true
    }

    private static func isHexTitleID(_ s: String) -> Bool { s.count == 16 && s.allSatisfy(\.isHexDigit) }

    private static func titleIDFromIdentityFile(_ idPath: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: idPath)) else { return nil }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let title = (json["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        if let text = String(data: data, encoding: .utf8) {
            for token in text.split(whereSeparator: \.isWhitespace) where token.hasPrefix("title=") {
                let val = String(token.dropFirst("title=".count))
                if !val.isEmpty, val != "-" { return val }
            }
        }
        return nil
    }

    private static func renameLegacyImageIfNeeded(in dest: String, targetImageName: String, fm: FileManager) {
        let legacyImg = joinPath(dest, "romfs.img"), targetImg = joinPath(dest, targetImageName)
        guard legacyImg.caseInsensitiveCompare(targetImg) != .orderedSame,
              isRegularFile(legacyImg, fm: fm), !fm.fileExists(atPath: targetImg) else { return }
        try? fm.moveItem(atPath: legacyImg, toPath: targetImg)
        try? fm.removeItem(atPath: legacyImg + ".id")
    }

    private static func writeTitleIDMarker(in folderPath: String, titleID: String) {
        let clean = titleID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !clean.isEmpty else { return }
        try? (clean + "\n").write(toFile: joinPath(folderPath, ".titleid"), atomically: true, encoding: .utf8)
    }
}
