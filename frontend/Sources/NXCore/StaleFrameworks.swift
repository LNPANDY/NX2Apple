import Foundation

/// LNPANDY/NX2Apple#449: the shared iPhone and iPad app takes frameworks of one shader chain only. After an engine update that
/// changes the chain, the frameworks already in the shell folder are stale, and build_shell.sh refuses them at the last step.
/// This finds them before the long steps. The chain of the engine is the `DMSH_CHAIN` of `dm/gfx/nvn/dmsh_chain.h` (the
/// `b-<chain>` folder name), the chain of a framework is the `chain` of its `game.manifest.json`, the two values the script compares.
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

    /// The manifest of a framework folder: its `chain`, `title_id` and `name`. nil when it has none or it cannot be read.
    private static func manifest(of framework: String) -> (chain: String, titleID: String, name: String)? {
        guard let data = FileManager.default.contents(atPath: framework + "/game.manifest.json"),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let chain = json["chain"] as? String else { return nil }
        return (chain, json["title_id"] as? String ?? "", json["name"] as? String ?? "")
    }

    /// The frameworks of another chain than `chain`: those in the shell folder's mirror (`<root>/frameworks`) and those the
    /// library names (`known`: title ID, name and framework folder of each game in shell.json). One entry per title ID, with every
    /// folder that holds it. A framework whose manifest cannot be read is not decided here: build_shell.sh's own check stays
    /// for it. `except` is the game being built now, whose framework this build replaces.
    package static func find(root: String, chain: String, known: [(titleID: String, name: String, framework: String)],
                             except: String? = nil) -> [Entry] {
        let fm = FileManager.default
        let mirror = root + "/frameworks"
        var folders = known.map(\.framework)
        for item in ((try? fm.contentsOfDirectory(atPath: mirror)) ?? []).sorted() where item.hasSuffix(".framework") {
            folders.append(mirror + "/" + item)
        }
        var entries: [Entry] = []
        var seen = Set<String>()
        for folder in folders where seen.insert(folder).inserted && fm.fileExists(atPath: folder) {
            guard let m = manifest(of: folder), m.chain != chain else { continue }
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

    /// Deletes the stale frameworks' folders and nothing else. Returns the folders it could not delete.
    @discardableResult
    package static func remove(_ entries: [Entry]) -> [String] {
        var failed: [String] = []
        for path in entries.flatMap(\.paths) {
            do { try FileManager.default.removeItem(atPath: path) }
            catch { if FileManager.default.fileExists(atPath: path) { failed.append(path) } }
        }
        return failed
    }

    /// The names the prompt lists, one per line.
    package static func list(_ entries: [Entry]) -> String {
        entries.map { "• " + $0.name }.joined(separator: "\n")
    }
}
