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
    package static func load(from directory: URL, fm: FileManager = .default) throws -> [String: AchievementList] {
        let urls = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var out: [String: AchievementList] = [:]
        let decoder = JSONDecoder()
        for url in urls where url.pathExtension.lowercased() == "json" {
            let list = try decoder.decode(AchievementList.self, from: Data(contentsOf: url))
            out[list.titleID.uppercased()] = list
        }
        return out
    }

    /// The catalog compiled into NXCore. Empty when the resources were not copied.
    package static func bundled(bundle: Bundle = .module) -> [String: AchievementList] {
        let directory = bundle.url(forResource: "AchievementCatalog", withExtension: nil)
            ?? bundle.resourceURL?.appendingPathComponent("AchievementCatalog")
        guard let directory else { return [:] }
        return (try? load(from: directory)) ?? [:]
    }
}

/// Which goals the player has marked done. Stored by title ID. The game itself is not read.
package struct AchievementProgress: Equatable {
    package var done: [String: [String]]

    package init(done: [String: [String]] = [:]) { self.done = done }

    package static func file(in support: URL) -> URL {
        support.appendingPathComponent("achievements.json")
    }

    package static func load(file: URL) -> AchievementProgress {
        guard let data = try? Data(contentsOf: file),
              let raw = try? JSONDecoder().decode([String: [String]].self, from: data) else { return AchievementProgress() }
        var done: [String: [String]] = [:]
        for (id, names) in raw { done[id.uppercased()] = names }
        return AchievementProgress(done: done)
    }

    package func unlocked(titleID: String) -> Set<String> {
        Set(done[titleID.uppercased()] ?? [])
    }

    package mutating func toggle(titleID: String, id: String) {
        let key = titleID.uppercased()
        var ids = unlocked(titleID: key)
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        done[key] = ids.sorted()
    }

    package func write(file: URL) throws {
        let data = try JSONEncoder().encode(done)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }
}
