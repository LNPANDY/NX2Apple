import Foundation

/// LNPANDY/NX2Apple#449, #451: each game framework built for the shared app now carries its own host (`loader == "FH"` in
/// `game.manifest.json`), so an engine update that changes the shader chain leaves every installed game working. Only a
/// framework built before #451 (`loader != "FH"`, no host in the framework) is refused by `build_shell.sh` and found here
/// before the long build steps.
package enum StaleFrameworks {
    package struct Entry: Equatable {
        package var titleID: String
        package var name: String
        package var chain: String
        package var paths: [String]
    }

    /// `b-<chain>` of the engine tree at `engineRoot`, or nil when the header cannot be read.
    package static func currentChain(engineRoot: String) -> String? {
        guard let text = try? String(contentsOfFile: engineRoot + "/dm/gfx/nvn/dmsh_chain.h", encoding: .utf8) else { return nil }
        let prefix = "#define DMSH_CHAIN \""
        for line in text.split(separator: "\n") where line.hasPrefix(prefix) {
            let value = line.dropFirst(prefix.count).prefix { $0 != "\"" }
            return value.isEmpty ? nil : "b-" + value
        }
        return nil
    }

    /// The manifest of a framework folder: its `chain`, `title_id`, `name` and `loader`. nil when it has none or it cannot be read.
    private static func manifest(of framework: String) -> (chain: String, titleID: String, name: String, loader: String)? {
        guard let data = FileManager.default.contents(atPath: framework + "/game.manifest.json"),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let chain = json["chain"] as? String else { return nil }
        return (chain, json["title_id"] as? String ?? "", json["name"] as? String ?? "", json["loader"] as? String ?? "FR")
    }

    /// The frameworks built without a host of their own (`loader != "FH"`): those in the shell folder's mirror
    /// (`<root>/frameworks`) and those the library names (`known`: title ID, name and framework folder of each game in
    /// `shell.json`). Frameworks with `loader == "FH"` carry their own host and stay valid across shader chain updates (#451).
    /// One entry per title ID, with every folder that holds it. A framework whose manifest cannot be read is not decided here:
    /// `build_shell.sh`'s own check stays for it. `except` is the game being built now, whose framework this build replaces.
    package static func find(root: String, chain: String, known: [(titleID: String, name: String, framework: String)],
                             except: String? = nil) -> [Entry] {
        _ = chain
        let fm = FileManager.default
        let mirror = root + "/frameworks"
        var folders = known.map(\.framework)
        for item in ((try? fm.contentsOfDirectory(atPath: mirror)) ?? []).sorted() where item.hasSuffix(".framework") {
            folders.append(mirror + "/" + item)
        }
        var entries: [Entry] = []
        var seen = Set<String>()
        for folder in folders where seen.insert(folder).inserted && fm.fileExists(atPath: folder) {
            guard let m = manifest(of: folder), m.loader != "FH" else { continue }
            let id = m.titleID.isEmpty ? titleID(ofFolder: folder) : m.titleID
            if let except, except.caseInsensitiveCompare(id) == .orderedSame { continue }
            if let i = entries.firstIndex(where: { $0.titleID.caseInsensitiveCompare(id) == .orderedSame }) {
                entries[i].paths.append(folder)
                continue
            }
            let name = known.first { $0.titleID.caseInsensitiveCompare(id) == .orderedSame }?.name ?? ""
            entries.append(Entry(titleID: id, name: name.isEmpty ? (m.name.isEmpty ? id : m.name) : name, chain: m.chain, paths: [folder]))
        }
        return entries
    }

    /// `DmGame<title ID>.framework` as the title ID.
    private static func titleID(ofFolder folder: String) -> String {
        let name = (folder as NSString).lastPathComponent
        return name.hasPrefix("DmGame") && name.hasSuffix(".framework")
            ? String(name.dropFirst("DmGame".count).dropLast(".framework".count)) : name
    }

    /// Takes the stale frameworks' folders away and nothing else. Returns the folders it could not take away.
    /// A framework holds tens of thousands of shader files: deleting them in place took a minute on an external disk, on the main
    /// thread, and a launcher quit in that minute left a framework without its manifest and executable that the shell library
    /// still named (the next build failed at "Prepare the shared app"). So each folder is first renamed out of the way, which is
    /// one step that cannot stop halfway, and the files are deleted afterwards in the background (`ShellInstall.discard`).
    @discardableResult
    package static func remove(_ entries: [Entry]) -> [String] {
        entries.flatMap(\.paths).filter { !ShellInstall.discard($0) }
    }

    /// The names the prompt lists, one per line.
    package static func list(_ entries: [Entry]) -> String {
        entries.map { "• " + $0.name }.joined(separator: "\n")
    }
}
