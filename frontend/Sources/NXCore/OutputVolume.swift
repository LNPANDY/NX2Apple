import Foundation

/// What the volume of the output folder can do for the Mac app step. `dm/mac/pack_app.py` puts a new `.app` over an old one with
/// `renamex_np(RENAME_SWAP)`, which only APFS supports. On Mac OS Extended (Journaled), exFAT, FAT and network volumes the first build
/// works and every build after it stops at the last step with `[Errno 45] Operation not supported` (#595).
package enum OutputVolume {
    /// Whether the volume that holds `path` can swap two folders in one step. `path` may not exist yet: the nearest folder above it
    /// that exists decides. nil when the system does not say, which the caller takes as "go ahead".
    package static func supportsAppReplace(at path: String, fm: FileManager = .default) -> Bool? {
        guard !path.isEmpty else { return nil }
        var probe = path
        while !fm.fileExists(atPath: probe), probe != "/", !probe.isEmpty { probe = (probe as NSString).deletingLastPathComponent }
        if let swap = (try? URL(fileURLWithPath: probe).resourceValues(forKeys: [.volumeSupportsSwapRenamingKey]))?.volumeSupportsSwapRenaming {
            return swap
        }
        // No answer from the volume's capabilities: the file system's name from statfs. Only APFS is known to swap.
        guard let volume = DriveCopy.volume(at: probe, fm: fm) else { return nil }
        return volume.fileSystem.lowercased() == "apfs"
    }
}
