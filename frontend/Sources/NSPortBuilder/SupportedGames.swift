import Foundation

/// Every game nxnative has a profile for: `dm/games/<title ID>/game.tsv` of the checkout. The library's
/// "All" filter shows these beside the games the player owns, covers scraped the same way, so the
/// collection doubles as the list of what the engine supports today.
enum SupportedGames {
    /// Lightweight library entries (title ID and name only, no paths). A game the player owns is matched
    /// by title ID and shown from their own entry instead.
    static func load(repo: String) -> [LibraryGame] {
        guard !repo.isEmpty else { return [] }
        let fm = FileManager.default
        let gamesDir = repo + "/dm/games"
        guard let entries = try? fm.contentsOfDirectory(atPath: gamesDir) else { return [] }
        var games: [LibraryGame] = []
        for entry in entries.sorted() {
            guard entry.count == 16, entry.allSatisfy(\.isHexDigit), entry != "0000000000000000" else { continue }
            let tsv = gamesDir + "/" + entry + "/game.tsv"
            guard let text = try? String(contentsOfFile: tsv, encoding: .utf8) else { continue }
            let name = text.split(separator: "\n").compactMap { line -> String? in
                let parts = line.split(separator: "\t", maxSplits: 1)
                return parts.first == "name" && parts.count > 1 ? String(parts[1]) : nil
            }.first ?? entry
            games.append(LibraryGame(titleID: entry, name: name))
        }
        return games
    }
}
