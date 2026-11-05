import Foundation

/// One goal from a supported game. The text is a short description of a publicly known goal, not a line copied from the game.
package struct Achievement: Codable, Equatable {
    package var id: String
    package var name: String
    package var detail: String
    /// The name stays hidden until the player marks it done.
    package var hidden: Bool
}

/// The goals for one title ID.
package struct AchievementList: Codable, Equatable {
    package var titleID: String
    package var name: String
    package var achievements: [Achievement]
}

/// The achievement files shipped with the launcher, one JSON file per supported game.
package enum AchievementCatalog {
    /// Reads every JSON file in the folder. A title ID is matched without regard to case.
    /// A second file for the same title adds any goals the first file did not already have.
    /// `skipBroken` keeps the files that did decode. The strict read throws on the first bad file.
    package static func load(from directory: URL, fm: FileManager = .default, skipBroken: Bool = false) throws -> [String: AchievementList] {
        let urls = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var out: [String: AchievementList] = [:]
        let decoder = JSONDecoder()
        for url in urls where url.pathExtension.lowercased() == "json" {
            do {
                let list = try decoder.decode(AchievementList.self, from: Data(contentsOf: url))
                store(list, into: &out)
            } catch {
                if !skipBroken { throw error }
            }
        }
        return out
    }

    /// The catalog compiled into NXCore. Empty when the resources were not copied.
    /// A full read is kept. A missing folder or a read with no usable file is tried again next time.
    package static func bundled(bundle: Bundle = .module) -> [String: AchievementList] {
        if bundle === Bundle.module, let memory { return memory }
        let directory = bundle.url(forResource: "AchievementCatalog", withExtension: nil)
            ?? bundle.resourceURL?.appendingPathComponent("AchievementCatalog")
        guard let directory, let loaded = try? load(from: directory, skipBroken: true), !loaded.isEmpty else { return [:] }
        if bundle === Bundle.module { memory = loaded }
        return loaded
    }

    /// Keeps both lists when two files name the same title in different case.
    private static func store(_ list: AchievementList, into out: inout [String: AchievementList]) {
        let key = list.titleID.uppercased()
        guard var kept = out[key] else { out[key] = list; return }
        var seen = Set(kept.achievements.map(\.id))
        for item in list.achievements where seen.insert(item.id).inserted { kept.achievements.append(item) }
        out[key] = kept
    }

    private static var memory: [String: AchievementList]?
}

/// Which goals the player has marked done. Stored by title ID. The game itself is not read.
package struct AchievementProgress: Equatable {
    package var done: [String: [String]]
    /// The file is there but could not be read. A later save must not replace it.
    package var unreadable: Bool

    package init(done: [String: [String]] = [:], unreadable: Bool = false) {
        self.done = done
        self.unreadable = unreadable
    }

    package static func file(in support: URL) -> URL {
        support.appendingPathComponent("achievements.json")
    }

    package static func load(file: URL) -> AchievementProgress {
        guard FileManager.default.fileExists(atPath: file.path) else { return AchievementProgress() }
        guard let data = try? Data(contentsOf: file),
              let raw = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            return AchievementProgress(unreadable: true)
        }
        var done: [String: [String]] = [:]
        for (id, names) in raw {
            let key = id.uppercased()
            done[key] = Array(Set(done[key] ?? []).union(names)).sorted()
        }
        return AchievementProgress(done: done)
    }

    package func unlocked(titleID: String) -> Set<String> {
        Set(done[titleID.uppercased()] ?? [])
    }

    /// How many of this list the player has marked. An id that is not on the list does not count.
    package func marked(titleID: String, ids: [String]) -> Int {
        unlocked(titleID: titleID).intersection(Set(ids)).count
    }

    package mutating func toggle(titleID: String, id: String) {
        if unreadable { return }
        let key = titleID.uppercased()
        var ids = unlocked(titleID: key)
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        done[key] = ids.sorted()
    }

    package func write(file: URL) throws {
        if unreadable { throw CocoaError(.fileReadCorruptFile) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(done)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }
}
