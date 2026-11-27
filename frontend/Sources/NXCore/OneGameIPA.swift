import Foundation

/// One game's own IPA with its game data inside (LNPANDY/NX2Apple#540), the second kind of the export next to the shared app. It is
/// the engine's one-game app as build_ipa_from_nsp.py makes it without `--shell-framework`: the RomFS goes to `<App>/romfs` (or
/// `romfs.img`) and the add-on content to `<App>/aoc`, which the app reads when its Documents hold no image (dm/ios main.m). The
/// fork's build_ipa.sh leaves the game data out by default (patch 0004, the slim IPA), so `DM_FULL_ROMFS=1` asks for it. pack_ipa.py
/// writes zip64 records when a file, an offset or the count passes the 32-bit fields. The bundle ID is the script's default
/// without a team suffix, `org.nxnative.<title ID>`: its own app, apart from the shared app and its saves.
package enum OneGameIPA {
    /// `<folder>/<title ID>.ipa` for `nxnative`, or `<folder>/<title ID>-<engine>.ipa` for other engines.
    package static func path(folder: String, titleID: String, upstream: EngineUpstreamKind = .nxnative) -> String {
        let base = folder + "/" + titleID
        return upstream == .nxnative ? (base + ".ipa") : (base + "-\(upstream.rawValue).ipa")
    }

    /// Team-scoped bundle ID (`org.nxnative.<tid>.<teamID>` or `org.nxnative.<tid>.<variant>.<teamID>`)
    /// when driving an external `nxnative` fork without NX2Apple's private patches.
    package static func personalBundleID(titleID: String, teamID: String, upstream: EngineUpstreamKind = .nxnative) -> String? {
        let tid = titleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let team = teamID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tid.isEmpty, !team.isEmpty, team != "0000000000" else { return nil }
        if upstream.isNxnativeVariant {
            return "org.nxnative.\(tid).\(upstream.rawValue).\(team)"
        }
        return "org.nxnative.\(tid).\(team)"
    }

    /// The script's arguments for the IPA, in place of the shared app's `--shell-framework`.
    package static func arguments(
        ipa: String,
        bundleID: String? = nil,
        separateRomfs: Bool = false,
        includeRomfsFlag: Bool = true
    ) -> [String] {
        var args = ["--platform", "ios"]
        if includeRomfsFlag {
            args += ["--romfs", separateRomfs ? "separate" : "bundle"]
        }
        args += ["-o", ipa]
        if let bundleID, !bundleID.isEmpty {
            args += ["--bundle-id", bundleID]
        }
        return args
    }

    /// What build_ipa.sh needs to pack or omit the game data in the IPA.
    package static let environment = ["DM_FULL_ROMFS": "1"]

    package static func environment(separateRomfs: Bool) -> [String: String] {
        separateRomfs ? ["DM_COPY_ROMFS": "NO"] : environment
    }

    /// Folder next to a separate-RomFS `.ipa` holding the external `romfs.img` (`<ipa-stem>-romfs`).
    package static func separateRomfsDirectory(forIPA ipaPath: String) -> String {
        guard !ipaPath.isEmpty else { return "" }
        return (ipaPath as NSString).deletingPathExtension + "-romfs"
    }

    /// Canonical external `romfs.img` path next to a separate-RomFS `.ipa`.
    package static func separateRomfsImagePath(forIPA ipaPath: String) -> String {
        let dir = separateRomfsDirectory(forIPA: ipaPath)
        return dir.isEmpty ? "" : dir + "/romfs.img"
    }

    /// Locates the extracted `RomFS.img` inside `<workDir>/extract/<version>/` when present and non-empty.
    package nonisolated static func locateExtractedRomFSImage(in workDir: String, fm: FileManager = .default) -> String? {
        guard !workDir.isEmpty else { return nil }
        let extract = workDir + "/extract"
        guard let version = RomFSArchive.extractedVersion(in: extract) else { return nil }
        let imagePath = extract + "/" + version + "/RomFS.img"
        return isRegularNonEmptyFile(imagePath, fm: fm) ? imagePath : nil
    }

    /// Exposes the extracted `RomFS.img` beside `ipaPath` as `romfs.img` using a zero-cost APFS clone or same-volume
    /// hard link so `extract/<version>/RomFS.img` stays intact for future rebuilds. Falls back to the extracted path
    /// on cross-volume or non-APFS destinations to avoid multi-minute 20+ GB copies at build completion.
    package nonisolated static func stageSeparateRomFSImage(
        workDir: String,
        ipaPath: String,
        fm: FileManager = .default,
        sameVolumeOverride: Bool? = nil
    ) -> String? {
        let destImg = separateRomfsImagePath(forIPA: ipaPath)
        guard let source = locateExtractedRomFSImage(in: workDir, fm: fm) else {
            return (!destImg.isEmpty && isRegularNonEmptyFile(destImg, fm: fm)) ? destImg : nil
        }
        guard !destImg.isEmpty else { return source }
        if isMatchingFile(source, destImg, fm: fm) {
            return destImg
        }

        let destDir = separateRomfsDirectory(forIPA: ipaPath)
        let createdDir = !fm.fileExists(atPath: destDir)
        do {
            try fm.createDirectory(atPath: destDir, withIntermediateDirectories: true)
        } catch {
            return source
        }

        let sourceVol = BuildSpace.volumeID(at: source, fm: fm)
        let destVol = BuildSpace.volumeID(at: destDir, fm: fm)
        let sameVolume = sameVolumeOverride ?? (sourceVol != nil && sourceVol == destVol)
        let isAPFS = DriveCopy.volume(at: destDir, fm: fm)?.fileSystem.lowercased() == "apfs"

        if sameVolume {
            let partial = destDir + "/.romfs.img.partial-" + UUID().uuidString
            defer { try? fm.removeItem(atPath: partial) }
            do {
                if isAPFS {
                    try fm.copyItem(atPath: source, toPath: partial)
                } else {
                    try fm.linkItem(atPath: source, toPath: partial)
                }
                if fm.fileExists(atPath: destImg) {
                    _ = try fm.replaceItemAt(URL(fileURLWithPath: destImg), withItemAt: URL(fileURLWithPath: partial))
                } else {
                    try fm.moveItem(atPath: partial, toPath: destImg)
                }
                return destImg
            } catch {
                // Fall back to the extracted image path when cloning or hard-linking fails.
            }
        }
        cleanupSeparateRomFSArtifacts(forIPA: ipaPath, fm: fm)
        if createdDir, ((try? fm.contentsOfDirectory(atPath: destDir)) ?? ["-"]).isEmpty {
            try? fm.removeItem(atPath: destDir)
        }
        return source
    }

    /// Removes the staged external `romfs.img` for `ipaPath` and removes `<ipa-stem>-romfs` when empty.
    package nonisolated static func cleanupSeparateRomFSArtifacts(forIPA ipaPath: String, fm: FileManager = .default) {
        let destDir = separateRomfsDirectory(forIPA: ipaPath)
        let destImg = separateRomfsImagePath(forIPA: ipaPath)
        guard !destDir.isEmpty, !destImg.isEmpty else { return }
        try? fm.removeItem(atPath: destImg)
        if ((try? fm.contentsOfDirectory(atPath: destDir)) ?? ["-"]).isEmpty {
            try? fm.removeItem(atPath: destDir)
        }
    }

    private nonisolated static func isRegularNonEmptyFile(_ path: String, fm: FileManager) -> Bool {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { return false }
        let size = (try? fm.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
        return size > 0
    }

    private nonisolated static func isMatchingFile(_ a: String, _ b: String, fm: FileManager) -> Bool {
        guard isRegularNonEmptyFile(a, fm: fm), isRegularNonEmptyFile(b, fm: fm),
              let attrA = try? fm.attributesOfItem(atPath: a),
              let attrB = try? fm.attributesOfItem(atPath: b),
              let sizeA = (attrA[.size] as? NSNumber)?.int64Value,
              let sizeB = (attrB[.size] as? NSNumber)?.int64Value,
              sizeA == sizeB,
              let dateA = attrA[.modificationDate] as? Date,
              let dateB = attrB[.modificationDate] as? Date else {
            return false
        }
        return abs(dateA.timeIntervalSince(dateB)) < 1
    }
}
