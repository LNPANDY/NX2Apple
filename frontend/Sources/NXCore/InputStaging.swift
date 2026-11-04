import Foundation

/// The folder the build script reads when the picked game files live in more than one folder (#132).
/// The script keys a provisional profile's shader split and shader build on the files' size and
/// modification time and on the profile's path (`<input folder>/<title ID>_build/profile`), so the
/// folder must be the same one on every build of a game. It sits in the game's build folder, is
/// never deleted after a build, and holds exactly the current selection: one symlink per file
/// (the script follows links, so it sees the original's size and date). The build's own
/// folders next to the links (`<title ID>_build`, `<title ID>_survey`) are left alone.
package enum InputStaging {
    package static let folderName = "staging"
    private static let gameExtensions: Set<String> = ["nsp", "xci", "nsz", "xcz"]

    package static func folder(workDir: String) -> String { workDir + "/" + folderName }

    /// The name a file has in the staging folder: a game file keeps its name with the extension in lowercase. The script
    /// finds packages with `*.nsp` (and `.xci`, `.nsz`, `.xcz`) and that glob is case-sensitive, so `Game [0100F2C0115B6000].NSP`
    /// was not found ("no NSP with a readable title ID", #554).
    package static func stagedName(_ name: String) -> String {
        let ext = (name as NSString).pathExtension
        guard gameExtensions.contains(ext.lowercased()), ext != ext.lowercased() else { return name }
        return (name as NSString).deletingPathExtension + "." + ext.lowercased()
    }

    /// Whether a file's name is one the script would not find as it is: a game file with an upper or mixed case extension.
    package static func needsLowercaseName(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return stagedName(name) != name
    }

    /// Makes `dir` hold exactly `files`, by file name. Returns how many were linked.
    package static func sync(files: [String], into dir: String) -> Int {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var wanted: [String: String] = [:]
        for f in files where !f.isEmpty { wanted[stagedName((f as NSString).lastPathComponent)] = f }
        // A stale entry from an earlier selection goes. Only game files and links are touched.
        for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
            let path = dir + "/" + name
            let isLink = (try? fm.destinationOfSymbolicLink(atPath: path)) != nil
            guard isLink || gameExtensions.contains((name as NSString).pathExtension.lowercased()) else { continue }
            if let src = wanted[name], isLink, (try? fm.destinationOfSymbolicLink(atPath: path)) == src { continue }
            try? fm.removeItem(atPath: path)
        }
        var linked = 0
        for (name, src) in wanted {
            let dst = dir + "/" + name
            if (try? fm.destinationOfSymbolicLink(atPath: dst)) == src { linked += 1; continue }
            if (try? fm.createSymbolicLink(atPath: dst, withDestinationPath: src)) != nil { linked += 1; continue }
            // No symlinks here (a volume without them): a hard link keeps the file's date, a copy gets it back.
            if (try? fm.linkItem(atPath: src, toPath: dst)) != nil { linked += 1; continue }
            if (try? fm.copyItem(atPath: src, toPath: dst)) != nil {
                if let date = (try? fm.attributesOfItem(atPath: src))?[.modificationDate] {
                    try? fm.setAttributes([.modificationDate: date], ofItemAtPath: dst)
                }
                linked += 1
            }
        }
        return linked
    }
}
