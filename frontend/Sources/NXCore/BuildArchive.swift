import Foundation

/// The RomFS tree a build extracts and the stamp that lets the next build skip the pack (pure file-system functions).
package enum RomFSArchive {
    /// (file count, bytes) of a RomFS tree — the reuse fingerprint's content part.
    package nonisolated static func treeStats(_ dir: String) -> (count: Int, bytes: Int)? {
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: dir) else { return nil }
        var count = 0, bytes = 0
        while let rel = en.nextObject() as? String {
            let s = ((try? fm.attributesOfItem(atPath: dir + "/" + rel))?[.size] as? Int) ?? 0
            count += 1; bytes += s
        }
        return (count, bytes)
    }

    package nonisolated static func writeStamp(source: String, version: String, to path: String) {
        guard let s = treeStats(source) else { return }
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        try? "\(version)\t\(s.count)\t\(s.bytes)".write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// The stamped (version, count, bytes) versus the source tree's now: nil = pack again.
    /// The newest version folder the extraction wrote, or nil when it wrote none.
    ///
    /// Either shape counts: RomFS/ from the older tools, RomFS.img from the current ones (the
    /// rewriter packs the game files itself — build_ipa_from_nsp.py:876 tests for the image).
    /// Looking only for the folder made every 0.4.8 build report "archive skipped" after a
    /// successful extraction (issue #73).
    package nonisolated static func extractedVersion(in extract: String) -> String? {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: extract)) ?? [])
            .filter { $0.hasPrefix("v") && (fm.fileExists(atPath: extract + "/" + $0 + "/RomFS") ||
                                            fm.fileExists(atPath: extract + "/" + $0 + "/RomFS.img")) }
            .sorted { (Int($0.dropFirst()) ?? 0) < (Int($1.dropFirst()) ?? 0) }
            .last
    }

    package nonisolated static func archiveReusable(source: String, version: String, stamp: String) -> Int? {
        guard let s = treeStats(source) else { return nil }
        let parts = stamp.split(separator: "\t")
        guard parts.count == 3, parts[0] == version,
              Int(parts[1]) == s.count, Int(parts[2]) == s.bytes else { return nil }
        return s.count
    }

    private static let reservedWindowsDeviceNames: Set<String> = [
        "CON", "PRN", "AUX", "NUL",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    ]

    private static let strippedFilenameScalars: Set<UnicodeScalar> = [
        "/", "\\", ":", "*", "?", "\"", "<", ">", "|",
    ]

    /// Produces a cross-platform filesystem-safe folder/image stem from `name`, falling back to `fallback` when empty or reserved.
    package nonisolated static func sanitizeGameName(_ name: String, fallback: String) -> String {
        var stripped = String.UnicodeScalarView()
        stripped.reserveCapacity(name.unicodeScalars.count)
        for scalar in name.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F || strippedFilenameScalars.contains(scalar) {
                continue
            }
            stripped.append(scalar)
        }
        var collapsed = ""
        collapsed.reserveCapacity(stripped.count)
        var previousWasSpace = false
        for ch in String(stripped) {
            if ch.isWhitespace {
                if !previousWasSpace {
                    collapsed.append(" ")
                    previousWasSpace = true
                }
            } else {
                collapsed.append(ch)
                previousWasSpace = false
            }
        }
        while collapsed.first == " " { collapsed.removeFirst() }
        while let last = collapsed.last, last == " " || last == "." { collapsed.removeLast() }
        guard !collapsed.isEmpty else { return fallback }
        let upper = collapsed.uppercased()
        let stem = upper.split(separator: ".", omittingEmptySubsequences: false).first.map(String.init) ?? upper
        if reservedWindowsDeviceNames.contains(upper) || reservedWindowsDeviceNames.contains(stem) {
            return fallback
        }
        return collapsed
    }

    /// Strips dump tags such as `[0100...]`, `[v0]`, `(1.2 GB)`, and bare 16-hex title ID tokens from a package stem.
    package nonisolated static func cleanPackageGameName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let cleaned = trimmed
            .replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
            .replacingOccurrences(
                of: "\\(\\s*[0-9]+([.,][0-9]+)?\\s*(B|KB|MB|GB|TB|KiB|MiB|GiB|TiB|v\\d+)\\s*\\)",
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(
                of: "(?:^|[\\s_\\-]+)0[14][0-9A-Fa-f]{14}(?![0-9A-Fa-f])(?:[_ ]v\\d+)?(?:_[0-9A-Fa-f]{8,64})?(?:\\s*[\\-_]\\s*)?",
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " -._\t\n\r"))
        return cleaned.isEmpty ? trimmed : cleaned
    }

    /// Resolves the archive subdirectory name under `gamesRoot` (`<SafeName>`, or `<SafeName> (<TitleID>)` on collision).
    package nonisolated static func archiveDirectoryName(
        gameName: String,
        titleID: String,
        gamesRoot: String,
        fm: FileManager = .default
    ) -> String {
        let tidUpper = titleID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let fallback = tidUpper.isEmpty ? titleID : tidUpper
        let safe = sanitizeGameName(gameName, fallback: fallback)
        guard !gamesRoot.isEmpty, !tidUpper.isEmpty else { return safe }
        if safe.caseInsensitiveCompare(tidUpper) == .orderedSame { return safe }
        let candidate = joinPath(gamesRoot, safe)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: candidate, isDirectory: &isDir) else { return safe }
        guard isDir.boolValue else { return "\(safe) (\(tidUpper))" }
        if let marker = readTitleIDMarker(in: candidate) {
            return marker.caseInsensitiveCompare(tidUpper) == .orderedSame ? safe : "\(safe) (\(tidUpper))"
        }
        if isHexTitleID(safe) {
            return "\(safe) (\(tidUpper))"
        }
        for imgName in topLevelImageNames(in: candidate, fm: fm) {
            let imgPath = joinPath(candidate, imgName)
            if let owner = titleIDFromIdentityFile(imgPath + ".id") {
                return owner.caseInsensitiveCompare(tidUpper) == .orderedSame ? safe : "\(safe) (\(tidUpper))"
            }
            let stem = (imgName as NSString).deletingPathExtension
            if isHexTitleID(stem), stem.caseInsensitiveCompare(tidUpper) != .orderedSame {
                return "\(safe) (\(tidUpper))"
            }
        }
        return safe
    }

    /// Returns existing archive subdirectories under `gamesRoot` that belong to `titleID` (by folder name, `.titleid`, or `.img.id`).
    package nonisolated static func archiveDirectories(
        forTitleID titleID: String,
        gamesRoot: String,
        fm: FileManager = .default
    ) -> [String] {
        let tid = titleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tid.isEmpty, !gamesRoot.isEmpty,
              let entries = try? fm.contentsOfDirectory(atPath: gamesRoot) else { return [] }
        var matches: [String] = []
        for entry in entries.sorted() where !entry.hasPrefix(".") {
            let folderPath = joinPath(gamesRoot, entry)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: folderPath, isDirectory: &isDir), isDir.boolValue else { continue }
            if archiveFolderMatchesTitleID(folderPath: folderPath, folderName: entry, titleID: tid, fm: fm) {
                matches.append(folderPath)
            }
        }
        return matches
    }

    /// Selects the primary RomFS image filename inside `archive` (`<folderName>.img`, then `romfs.img`, then sole top-level `*.img`).
    package nonisolated static func primaryImageName(in archive: String, fm: FileManager = .default) -> String? {
        guard !archive.isEmpty else { return nil }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: archive, isDirectory: &isDir), isDir.boolValue else { return nil }
        let candidates = topLevelImageNames(in: archive, fm: fm)
        let folderName = (archive as NSString).lastPathComponent
        return choosePrimaryImageName(from: candidates, folderName: folderName)
    }

    /// Full path to the primary RomFS image inside `archive`, or `nil` when none exists.
    package nonisolated static func primaryImagePath(in archive: String, fm: FileManager = .default) -> String? {
        guard let name = primaryImageName(in: archive, fm: fm) else { return nil }
        return joinPath(archive, name)
    }

    /// Selects the primary top-level RomFS image key from a sequence of relative file paths (such as transfer or archive manifests).
    package nonisolated static func primaryImageName(inFiles keys: some Sequence<String>, folderName: String? = nil) -> String? {
        var unique = Set<String>()
        for key in keys where !key.contains("/") && !key.contains("\\") && isTopLevelImageFileName(key) {
            unique.insert(key)
        }
        return choosePrimaryImageName(from: unique.sorted(), folderName: folderName)
    }

    private nonisolated static func choosePrimaryImageName(from sortedCandidates: [String], folderName: String?) -> String? {
        guard !sortedCandidates.isEmpty else { return nil }
        if let folderName, !folderName.isEmpty {
            let expected = folderName + ".img"
            if let exact = sortedCandidates.first(where: { $0 == expected }) { return exact }
            if let ci = sortedCandidates.first(where: { $0.caseInsensitiveCompare(expected) == .orderedSame }) { return ci }
        }
        if let exact = sortedCandidates.first(where: { $0 == "romfs.img" }) { return exact }
        if let ci = sortedCandidates.first(where: { $0.caseInsensitiveCompare("romfs.img") == .orderedSame }) { return ci }
        return sortedCandidates.count == 1 ? sortedCandidates[0] : nil
    }

    private nonisolated static func isTopLevelImageFileName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix(".") else { return false }
        let lower = name.lowercased()
        guard (lower as NSString).pathExtension == "img",
              !lower.contains(".nxpart") else { return false }
        return true
    }

    private nonisolated static func topLevelImageNames(in folder: String, fm: FileManager) -> [String] {
        guard let entries = try? fm.contentsOfDirectory(atPath: folder) else { return [] }
        return entries.filter { name in
            guard isTopLevelImageFileName(name) else { return false }
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: joinPath(folder, name), isDirectory: &isDir) && !isDir.boolValue
        }.sorted()
    }

    private nonisolated static func joinPath(_ base: String, _ component: String) -> String {
        if base == "/" { return "/" + component }
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        return trimmed + "/" + component
    }

    private nonisolated static func isHexTitleID(_ s: String) -> Bool {
        s.count == 16 && s.allSatisfy(\.isHexDigit)
    }

    private nonisolated static func readTitleIDMarker(in folder: String) -> String? {
        guard let raw = try? String(contentsOfFile: joinPath(folder, ".titleid"), encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private nonisolated static func titleIDFromIdentityFile(_ idPath: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: idPath)) else { return nil }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let title = (json["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }
        if let text = String(data: data, encoding: .utf8) {
            for token in text.split(whereSeparator: \.isWhitespace) where token.hasPrefix("title=") {
                let value = String(token.dropFirst("title=".count))
                if !value.isEmpty, value != "-" { return value }
            }
        }
        return nil
    }

    private nonisolated static func archiveFolderMatchesTitleID(
        folderPath: String,
        folderName: String,
        titleID: String,
        fm: FileManager
    ) -> Bool {
        if let marker = readTitleIDMarker(in: folderPath) {
            return marker.caseInsensitiveCompare(titleID) == .orderedSame
        }
        if folderName.caseInsensitiveCompare(titleID) == .orderedSame {
            return true
        }
        if isHexTitleID(folderName) {
            return false
        }
        for imgName in topLevelImageNames(in: folderPath, fm: fm) {
            let stem = (imgName as NSString).deletingPathExtension
            if stem.caseInsensitiveCompare(titleID) == .orderedSame { return true }
            if let owner = titleIDFromIdentityFile(joinPath(folderPath, imgName) + ".id"),
               owner.caseInsensitiveCompare(titleID) == .orderedSame {
                return true
            }
        }
        return false
    }

    /// The RomFS images an earlier build of this game left outside its build folder: `games/<FolderName>/<GameName>.img`, legacy
    /// `games/<id>/romfs.img`, and `<App>.app/Contents/Resources/romfs.img` under `root`. Only images accompanied by their `.id`
    /// sidecar are returned so `--romfs-from` can verify them before skipping extraction (#708).
    package nonisolated static func reusableImages(root: String, key: String) -> [String] {
        let fm = FileManager.default
        let isTitleID = isHexTitleID(key)
        var candidates: [String] = []
        var seen = Set<String>()
        func addCandidate(_ path: String) {
            guard fm.fileExists(atPath: path), fm.fileExists(atPath: path + ".id") else { return }
            let canonical = URL(fileURLWithPath: path).standardizedFileURL.path
            if seen.insert(canonical).inserted {
                candidates.append(path)
            }
        }

        let gamesRoot = joinPath(root, "games")
        if isTitleID {
            addCandidate(joinPath(joinPath(gamesRoot, key), "romfs.img"))
        }
        for entry in ((try? fm.contentsOfDirectory(atPath: gamesRoot)) ?? []).sorted() where !entry.hasPrefix(".") {
            let folderPath = joinPath(gamesRoot, entry)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: folderPath, isDirectory: &isDir), isDir.boolValue else { continue }
            let folderMatches = !isTitleID || archiveFolderMatchesTitleID(folderPath: folderPath, folderName: entry, titleID: key, fm: fm)
            let imageNames = topLevelImageNames(in: folderPath, fm: fm)
            if folderMatches {
                if let primary = primaryImageName(in: folderPath, fm: fm) {
                    addCandidate(joinPath(folderPath, primary))
                }
                for imgName in imageNames {
                    addCandidate(joinPath(folderPath, imgName))
                }
            } else if isTitleID {
                for imgName in imageNames {
                    let imgPath = joinPath(folderPath, imgName)
                    let stem = (imgName as NSString).deletingPathExtension
                    if stem.caseInsensitiveCompare(key) == .orderedSame
                        || titleIDFromIdentityFile(imgPath + ".id")?.caseInsensitiveCompare(key) == .orderedSame {
                        addCandidate(imgPath)
                    }
                }
            }
        }

        addCandidate(joinPath(root, key + ".app/Contents/Resources/romfs.img"))
        let rootURL = URL(fileURLWithPath: root)
        let rootEntries = ((try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for appURL in rootEntries where appURL.pathExtension.lowercased() == "app" && appURL.lastPathComponent != key + ".app" {
            guard (try? appURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false else { continue }
            let image = joinPath(root, appURL.lastPathComponent + "/Contents/Resources/romfs.img")
            guard fm.fileExists(atPath: image), fm.fileExists(atPath: image + ".id") else { continue }
            if !isTitleID || appImageMatchesTitleID(appURL: appURL, idPath: image + ".id", titleID: key) {
                addCandidate(image)
            }
        }
        return candidates
    }

    private nonisolated static func appImageMatchesTitleID(appURL: URL, idPath: String, titleID: String) -> Bool {
        if let title = titleIDFromIdentityFile(idPath) {
            return title.caseInsensitiveCompare(titleID) == .orderedSame
        }
        if let data = try? Data(contentsOf: appURL.appendingPathComponent("Contents/Info.plist")),
           let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let rawID = info["DMTitleID"] as? String, !rawID.isEmpty {
            return rawID.caseInsensitiveCompare(titleID) == .orderedSame
        }
        return false
    }

    /// Copies the `.id` sidecar of `image` (`<imgPath>.id`) to `<copy>.id`, removing any stale `<copy>.id` when `image` has none (#708).
    package nonisolated static func copyImageIdentity(of image: String, to copy: String) {
        let fm = FileManager.default
        let srcID = image + ".id"
        let dstID = copy + ".id"
        if URL(fileURLWithPath: srcID).standardizedFileURL == URL(fileURLWithPath: dstID).standardizedFileURL {
            return
        }
        try? fm.removeItem(atPath: dstID)
        if fm.fileExists(atPath: srcID) {
            try? fm.createDirectory(atPath: (dstID as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try? fm.copyItem(atPath: srcID, toPath: dstID)
        }
    }

    package nonisolated static func copyAddOnContent(from: String, to: String) -> Int {
        let fm = FileManager.default
        guard fm.fileExists(atPath: from) else { return 0 }
        try? fm.removeItem(atPath: to)
        try? fm.copyItem(atPath: from, toPath: to)
        return ((try? fm.contentsOfDirectory(atPath: to)) ?? []).count
    }
}

/// The command lines and the PATH of the build's tools.
package enum BuildCommands {
    /// The PATH of the processes that run the build, installing packages and writing the RomFS image: the bundled tools in front of
    /// `base` (BundledTools.swift), which is Homebrew's folders and the system's. One place, so that no environment forgets the bundle.
    package nonisolated static func toolPath(_ base: String = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", python: String? = nil) -> String {
        BundledTools.path(base, python: python)
    }

    package nonisolated static func reinstallCommand(xcrun: String, device: String, app: String) -> [String] {
        [xcrun, "devicectl", "device", "install", "app", "--device", device, app]
    }

    /// ditto writes the archive the way Finder's "compress" does; the IPA's root must be Payload/, and --norsrc keeps
    /// __MACOSX out (the signature itself lives in _CodeSignature inside the app).
    package nonisolated static func ipaCommand(payload: String, ipa: String) -> [String] {
        ["/usr/bin/ditto", "-c", "-k", "--norsrc", "--keepParent", payload, ipa]
    }
}
