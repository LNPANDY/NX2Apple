import Foundation

/// Reclaims intermediate build files once a build, archive step or shell export has finished writing its final output.
package enum PostBuildCleanup {
    package enum ImagePlacement: Equatable, Sendable {
        case moved
        case reused
    }

    /// Moves `source` (`extract/v<N>/RomFS.img`) to `destination` (`games/<id>/romfs.img`), falling back to a staged copy across volumes
    /// before removing the source image so a game never keeps two multi-gigabyte copies on disk.
    package nonisolated static func placeImage(from source: String, to destination: String) throws -> ImagePlacement {
        let fm = FileManager.default
        if let src = try? fm.attributesOfItem(atPath: source),
           let have = try? fm.attributesOfItem(atPath: destination),
           let srcSize = src[.size] as? Int64, let dstSize = have[.size] as? Int64, srcSize == dstSize,
           let srcDate = src[.modificationDate] as? Date, let dstDate = have[.modificationDate] as? Date,
           abs(srcDate.timeIntervalSince(dstDate)) < 1 {
            RomFSArchive.copyImageIdentity(of: source, to: destination)
            removeExtractedImageArtifacts(at: source, fm: fm)
            return .reused
        }

        let parent = (destination as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
        let partial = parent + "/.romfs.img.partial-" + UUID().uuidString
        defer { try? fm.removeItem(atPath: partial) }

        do {
            try fm.moveItem(atPath: source, toPath: partial)
        } catch {
            try? fm.removeItem(atPath: partial)
            try fm.copyItem(atPath: source, toPath: partial)
        }

        if fm.fileExists(atPath: destination) {
            _ = try fm.replaceItemAt(URL(fileURLWithPath: destination), withItemAt: URL(fileURLWithPath: partial))
        } else {
            try fm.moveItem(atPath: partial, toPath: destination)
        }
        RomFSArchive.copyImageIdentity(of: source, to: destination)
        removeExtractedImageArtifacts(at: source, fm: fm)
        return .moved
    }

    /// Moves `<work>/aoc` into `<dest>/aoc` atomically, falling back to a staged copy across volumes and removing `<work>/aoc` afterwards.
    package nonisolated static func placeAddOnContent(from source: String, to destination: String) -> Int {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source) else { return 0 }
        let parent = (destination as NSString).deletingLastPathComponent
        let partial = parent + "/.aoc.partial-" + UUID().uuidString
        defer { try? fm.removeItem(atPath: partial) }
        do {
            try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
            do {
                try fm.moveItem(atPath: source, toPath: partial)
            } catch {
                try? fm.removeItem(atPath: partial)
                try fm.copyItem(atPath: source, toPath: partial)
            }
            if fm.fileExists(atPath: destination) {
                _ = try fm.replaceItemAt(URL(fileURLWithPath: destination), withItemAt: URL(fileURLWithPath: partial))
            } else {
                try fm.moveItem(atPath: partial, toPath: destination)
            }
            try? fm.removeItem(atPath: source)
            try? fm.removeItem(atPath: source + ".key")
        } catch {
            return ((try? fm.contentsOfDirectory(atPath: destination)) ?? []).count
        }
        return ((try? fm.contentsOfDirectory(atPath: destination)) ?? []).count
    }

    /// Removes temporary build products in `workDir` while keeping incremental caches (`ExeFS`, `patched_*`, `shader`, PSO `.mtl4a` + `key.*`,
    /// Xcode `Intermediates.noindex`, `logs`, `profile` and `run`).
    package nonisolated static func cleanWorkDirectory(_ workDir: String, removeExtractedRomFS: Bool = true, removeShellFramework: Bool = false) {
        guard !workDir.isEmpty else { return }
        let fm = FileManager.default
        for item in ["nsp", "nsp.partial", "ipa/build/ios/pkg/dd/Build/Products"] {
            try? fm.removeItem(atPath: workDir + "/" + item)
        }
        if removeExtractedRomFS {
            let extract = workDir + "/extract"
            for entry in ((try? fm.contentsOfDirectory(atPath: extract)) ?? []) {
                let versionDir = extract + "/" + entry
                if entry.hasSuffix(".partial") {
                    try? fm.removeItem(atPath: versionDir)
                } else if entry.hasPrefix("v") {
                    removeExtractedImageArtifacts(at: versionDir + "/RomFS.img", fm: fm)
                    try? fm.removeItem(atPath: versionDir + "/RomFS")
                }
            }
            for item in ["aoc", "aoc.partial", "aoc.key"] {
                try? fm.removeItem(atPath: workDir + "/" + item)
            }
        }
        for psoWork in [workDir + "/pso/mac-work", workDir + "/ipa/build/ios/pso/work"] {
            for entry in ((try? fm.contentsOfDirectory(atPath: psoWork)) ?? []) where entry.hasPrefix("batches.") {
                try? fm.removeItem(atPath: psoWork + "/" + entry)
            }
        }
        if removeShellFramework {
            try? fm.removeItem(atPath: workDir + "/shell-framework")
        }
    }

    /// Removes the `<work>/shell-framework` staging container once the shared shell has mirrored its framework, leaving `<shellRoot>/frameworks`
    /// and any other location untouched.
    package nonisolated static func cleanBuiltFrameworkContainer(_ frameworkPath: String) {
        guard !frameworkPath.isEmpty else { return }
        let container = URL(fileURLWithPath: frameworkPath).deletingLastPathComponent()
        guard container.lastPathComponent == "shell-framework" else { return }
        try? FileManager.default.removeItem(at: container)
    }

    /// Removes the unsigned app products left by `ShellInstaller.export` while keeping `Intermediates.noindex` and the signed install's
    /// `<root>/derived-data` untouched.
    package nonisolated static func cleanShellExportProducts(root: String) {
        guard !root.isEmpty else { return }
        try? FileManager.default.removeItem(atPath: ShellInstall.exportDerivedData(root: root) + "/Build/Products")
    }

    private nonisolated static func removeExtractedImageArtifacts(at imagePath: String, fm: FileManager) {
        try? fm.removeItem(atPath: imagePath)
        try? fm.removeItem(atPath: imagePath + ".id")
        try? fm.removeItem(atPath: imagePath + ".formats")
    }
}
