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
