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

    /// Deletes what an earlier `discard` renamed but could not finish deleting (the launcher was quit), in the background.
    package static func sweepDiscarded(in folder: String, fm: FileManager = .default) {
        let leftovers = ((try? fm.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.hasPrefix(discardPrefix) }.map { folder + "/" + $0 }
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
