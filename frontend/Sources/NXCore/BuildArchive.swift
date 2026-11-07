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

    /// Replace `to` with a copy of `from` when `from` exists. Returns how many entries `to` holds afterwards.
    /// The RomFS images an earlier build of this game left outside its build folder: the iPhone build's games/<id>/romfs.img and the
    /// Mac app's Contents/Resources/romfs.img, under `root` (the output folder, else the input folder). Only those with the identity
    /// file the build script writes beside an image: the script checks it, the image's SHA-256 and its files against the game
    /// packages, and takes the image instead of extracting the RomFS again for the other platform (`--romfs-from`, #708).
    /// A build key that is no title ID (a file name without one, #515) names the Mac app but not the games folder, which the
    /// archive step names after the framework's title ID: then every game's image there is named, and the script, which reads
    /// the title in each identity file first, keeps this game's.
    package nonisolated static func reusableImages(root: String, key: String) -> [String] {
        let fm = FileManager.default
        let isTitleID = key.count == 16 && key.allSatisfy(\.isHexDigit)
        let games = isTitleID ? [key] : ((try? fm.contentsOfDirectory(atPath: root + "/games")) ?? []).sorted()
        return (games.map { root + "/games/" + $0 + "/romfs.img" } + [root + "/" + key + ".app/Contents/Resources/romfs.img"])
            .filter { fm.fileExists(atPath: $0) && fm.fileExists(atPath: $0 + ".id") }
    }

    /// The identity file beside an extracted image (RomFS.img.id) goes with the image's copy, as romfs.img.id; without one a stale
    /// file is removed, as it would vouch for an image it was not written for (#708).
    package nonisolated static func copyImageIdentity(of image: String, to copy: String) {
        let fm = FileManager.default
        try? fm.removeItem(atPath: copy + ".id")
        if fm.fileExists(atPath: image + ".id") { try? fm.copyItem(atPath: image + ".id", toPath: copy + ".id") }
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
