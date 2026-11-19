import Foundation

/// Which console generation a game profile was made for. Read from the first line of the profile's `game.tsv`, which names it
/// ("Game profile of Kirby … (Switch, update 1.1.0 …" or "Kirby Air Riders (Switch 2, update …"). A profile with no such line says
/// nothing, and the launcher then shows no edition: it never guesses one from a title ID or from the files a player has.
package enum GameEdition: Equatable {
    case switch1, switch2, unknown

    package static func parse(headerLine: String) -> GameEdition {
        guard headerLine.hasPrefix("#") else { return .unknown }
        if headerLine.contains("(Switch 2") { return .switch2 }
        if headerLine.contains("(Switch") { return .switch1 }
        return .unknown
    }
}

/// One game the shipped engine has a profile for (LNPANDY/NX2Apple#301). Only what the profile states: its name, the edition its first
/// line names, the version it was brought up on, and its notes. It is not a promise that a game runs, nor a list of what a player owns.
package struct SupportedGame: Identifiable, Equatable {
    package let titleID: String
    package let name: String
    package let edition: GameEdition
    /// The version the profile's package row stands for, as the profile writes it: "1.4.1", else the package id "v393216". nil with no package row.
    package let version: String?
    /// The first paragraph of the profile's README, markup removed, at most `SupportedGames.noteLimit` characters. Empty without a README.
    package let notes: String
    package var id: String { titleID }

    package init(titleID: String, name: String, edition: GameEdition, version: String?, notes: String) {
        self.titleID = titleID; self.name = name; self.edition = edition; self.version = version; self.notes = notes
    }
}

package enum SupportedGames {
    package static let noteLimit = 320

    /// Every profile under `<engineRoot>/dm/games`, by name. A folder that is not a profile (no `title_id`, no `name`) is left out.
    package static func list(engineRoot: String) -> [SupportedGame] {
        guard !engineRoot.isEmpty else { return [] }
        let games = URL(fileURLWithPath: engineRoot).appendingPathComponent("dm/games")
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: games.path)) ?? []
        return folders.compactMap { read(games.appendingPathComponent($0)) }
            .sorted { left, right in
                let order = left.name.localizedStandardCompare(right.name)
                return order == .orderedSame ? left.titleID < right.titleID : order == .orderedAscending
            }
    }

    package static func read(_ folder: URL) -> SupportedGame? {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("game.tsv"), encoding: .utf8) else { return nil }
        var titleID = "", name = "", package = ""
        var builds: [String: String] = [:]   // package id -> display version
        var first = ""
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if index == 0 { first = String(line) }
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard cols.count >= 2, !cols[0].hasPrefix("#") else { continue }
            switch cols[0] {
            case "title_id": titleID = cols[1].uppercased()
            case "name": name = cols[1]
            case "package": if package.isEmpty { package = cols[1] }
            case "build": if cols.count >= 3, builds[cols[1]] == nil { builds[cols[1]] = cols[2] }
            default: break
            }
        }
        guard titleID.count == 16, !name.isEmpty else { return nil }
        let shown = builds[package].flatMap { $0.isEmpty || $0 == "?" ? nil : $0 } ?? (package.isEmpty ? nil : package)
        return SupportedGame(titleID: titleID, name: name, edition: GameEdition.parse(headerLine: first), version: shown,
                             notes: notes(readme: folder.appendingPathComponent("README.md")))
    }

    /// The first paragraph after the README's title line, with backticks and links reduced to their words, cut at a sentence end when too long.
    package static func notes(readme: URL) -> String {
        guard let text = try? String(contentsOf: readme, encoding: .utf8) else { return "" }
        var paragraph: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") || line.hasPrefix("|") || line.hasPrefix("- ") { if !paragraph.isEmpty { break }; continue }
            if line.isEmpty { if !paragraph.isEmpty { break }; continue }
            paragraph.append(line)
        }
        var out = paragraph.joined(separator: " ").replacingOccurrences(of: "`", with: "")
        out = out.replacingOccurrences(of: "\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        if out.count > noteLimit {
            let cut = String(out.prefix(noteLimit))
            if let end = cut.lastIndex(of: "."), cut.distance(from: cut.startIndex, to: end) > noteLimit / 2 { out = String(cut[...end]) }
            else { out = cut.trimmingCharacters(in: .whitespaces) + "…" }
        }
        return out
    }
}
