import Foundation

// A game framework of the shared app is one folder with tens of thousands of shader files. A copy or a delete of it takes a minute
// on an external disk, and a launcher that is quit in that minute must not leave half a framework where the shell library names it:
// build_shell.sh then refused the whole shared app at "Prepare the shared app", naming a path and not the game. So a framework is
// only ever replaced or taken away by a rename, which cannot stop halfway, and the slow delete runs afterwards in the background on
// a hidden folder that nothing reads. The check below also keeps a framework that is incomplete anyway out of the shared app.

extension ShellInstall {
    /// The hidden folder a framework is renamed to before its files are deleted. It sits next to the framework (one volume, so the
    /// rename is one step), starts with a dot and has no `.framework` suffix, so no listing of frameworks takes it for one.
    package static let discardPrefix = ".discarded-"

    /// Renames `path` out of the way and deletes it in the background. True when nothing is left at `path` (it was not there either).
    /// A folder that cannot be renamed stays where it was, whole.
    @discardableResult
    package static func discard(_ path: String, fm: FileManager = .default, background: Bool = true) -> Bool {
        guard fm.fileExists(atPath: path) else { return true }
        let parent = (path as NSString).deletingLastPathComponent
        let aside = parent + "/" + discardPrefix + UUID().uuidString
        do { try fm.moveItem(atPath: path, toPath: aside) } catch { return !fm.fileExists(atPath: path) }
        if background { DispatchQueue.global(qos: .utility).async { try? FileManager.default.removeItem(atPath: aside) } }
        else { try? fm.removeItem(atPath: aside) }
        return true
    }

    /// Deletes what an earlier `discard` or interrupted mirror backup renamed but could not finish deleting, in the background.
    package static func sweepDiscarded(in folder: String, fm: FileManager = .default) {
        let leftovers = ((try? fm.contentsOfDirectory(atPath: folder)) ?? [])
            .filter { $0.hasPrefix(discardPrefix) || $0.hasPrefix(backupPrefix) }
            .map { folder + "/" + $0 }
        guard !leftovers.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { for path in leftovers { try? FileManager.default.removeItem(atPath: path) } }
    }

    /// The file a framework lacks for build_shell.sh, nil when it is complete: its readable `game.manifest.json`, then the executable
    /// the manifest names (`DmGame<title ID>` when it names none). The script's other checks (the shader chain, a title ID twice) stay its own.
    package static func missingFile(inFramework framework: String, titleID: String, fm: FileManager = .default) -> String? {
        let manifest = "game.manifest.json"
        guard let data = fm.contents(atPath: framework + "/" + manifest),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return manifest }
        let executable = (json["framework_executable"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "DmGame\(titleID)"
        return fm.fileExists(atPath: framework + "/" + executable) ? nil : executable
    }

    package static func projectFrameworksFile(root: String) -> String { projectFolder(root: root) + "/frameworks.txt" }

    /// Records the library's framework rows in `<root>/project/frameworks.txt` when a stand-in `build_shell.sh` did not write it.
    package static func writeProjectFrameworks(root: String, games: [ShellLibrary.Game], fm: FileManager = .default) {
        let file = projectFrameworksFile(root: root)
        guard !fm.fileExists(atPath: file), !games.isEmpty else { return }
        let rows = games.map { "\($0.titleID)\t\($0.framework)\t\($0.name)" }.joined(separator: "\n") + "\n"
        try? rows.write(toFile: file, atomically: true, encoding: .utf8)
    }

    /// Whether `<root>/project/DmShell.xcodeproj` embeds a different set of frameworks than `games` (for example after a game was
    /// deleted or its stale framework was removed), or references a framework folder that is no longer on disk.
    package static func projectNeedsUpdate(root: String, games: [ShellLibrary.Game], fm: FileManager = .default) -> Bool {
        let expected = games.map(\.framework)
        if let text = try? String(contentsOfFile: projectFrameworksFile(root: root), encoding: .utf8) {
            let recorded = text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return nil }
                let cols = trimmed.split(separator: "\t", omittingEmptySubsequences: false)
                return cols.count >= 2 ? String(cols[1]) : trimmed
            }
            return recorded != expected || recorded.contains { !fm.fileExists(atPath: $0) }
        }
        let pbxPath = projectFolder(root: root) + "/" + projectName + "/project.pbxproj"
        guard let pbx = try? String(contentsOfFile: pbxPath, encoding: .utf8),
              let re = try? NSRegularExpression(pattern: #"DmGame[0-9A-Fa-f]+\.framework"#) else { return false }
        let matches = re.matches(in: pbx, range: NSRange(pbx.startIndex..., in: pbx))
        let referenced = Set(matches.compactMap { Range($0.range, in: pbx).map { String(pbx[$0]) } })
        guard !referenced.isEmpty else { return false }
        let currentNames = Set(expected.map { ($0 as NSString).lastPathComponent })
        return referenced != currentNames || expected.contains { !fm.fileExists(atPath: $0) }
    }

    /// Removes any `DmGame*.framework` left inside the built `DmShell.app/Frameworks` folders (install and export derived data)
    /// that is no longer in `games`, so an incremental `xcodebuild` or re-sign never keeps a deleted game's framework in the app.
    package static func pruneEmbeddedFrameworks(root: String, keeping games: [ShellLibrary.Game], fm: FileManager = .default) {
        let keep = Set(games.map { ($0.framework as NSString).lastPathComponent })
        for app in [appPath(root: root), exportAppPath(root: root)] {
            let folder = app + "/Frameworks"
            for item in (try? fm.contentsOfDirectory(atPath: folder)) ?? []
                where item.hasPrefix("DmGame") && item.hasSuffix(".framework") && !keep.contains(item) {
                try? fm.removeItem(atPath: folder + "/" + item)
            }
        }
    }
}

extension ShellInstaller {
    /// Before build_shell.sh: every framework of the library must be whole. Another game's framework that is not (a delete or a copy
    /// that was cut off) is left out of this shared app and out of shell.json, with a note that names the game and the file. Building
    /// that game again brings it back. Its mirror is taken away, a framework in a build folder stays (the build script owns it).
    /// Returns the notes, or the failure when the framework of the game being built is the incomplete one.
    func leaveOutIncomplete(_ library: inout ShellLibrary, titleID: String, name: String) -> (notes: [String], failure: String?) {
        var notes: [String] = [], gone = Set<String>()
        for game in library.games {
            guard let missing = ShellInstall.missingFile(inFramework: game.framework, titleID: game.titleID) else { continue }
            if game.titleID == titleID { return ([], fmt("shell.frameworkIncomplete", name, missing)) }
            let note = fmt("shell.gameLeftOut", game.name.isEmpty ? game.titleID : game.name, missing)
            log("library: " + note + " (" + game.framework + ")\n")
            notes.append(note)
            gone.insert(game.titleID)
            if game.framework == ShellInstall.mirroredFramework(root: root, titleID: game.titleID) { ShellInstall.discard(game.framework) }
        }
        library.games.removeAll { gone.contains($0.titleID) }
        return (notes, nil)
    }
}
