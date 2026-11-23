import Combine
import Foundation

/// The build files of the library's games (#232): what a rebuild reuses in `<output folder>/<title ID>_build`, tens of GB for a large
/// game. Nothing is removed on its own. The player removes one game's files from its Manage menu or from Settings > Tools, after a
/// question (`confirming`), and never while that game builds. The game keeps working: its app, its IPA and its game data stay.
///
/// The store holds the sizes and the question. Measuring and removing are closures (the app passes `BuildFolder`'s survey and removal,
/// which keep the logs, the profile and every protected path), and both run off the main actor.
@MainActor package final class BuildFilesStore: ObservableObject {
    /// One game with a build folder, as the app finds it.
    package struct Game: Equatable, Sendable {
        package let id: UUID
        package let gameID: UUID?
        package let name: String
        package let folder: String
        package let protecting: [String]
        package var ownerID: UUID { gameID ?? id }
        package init(id: UUID, gameID: UUID? = nil, name: String, folder: String, protecting: [String] = []) {
            self.id = id; self.gameID = gameID; self.name = name; self.folder = folder; self.protecting = protecting
        }
    }

    /// A game's removable build files and their size in bytes.
    package struct Entry: Equatable, Identifiable, Sendable {
        package let id: UUID
        package let gameID: UUID?
        package let name: String
        package let folder: String
        package let bytes: Int64
        package var ownerID: UUID { gameID ?? id }
        package init(id: UUID, gameID: UUID? = nil, name: String, folder: String, bytes: Int64) {
            self.id = id; self.gameID = gameID; self.name = name; self.folder = folder; self.bytes = bytes
        }
    }

    /// Largest first, then by name: the list of Settings > Tools.
    @Published package private(set) var entries: [Entry] = []
    @Published package private(set) var measuring = false
    /// The game whose files are being removed.
    @Published package private(set) var removing: UUID?
    /// The game the question is open for (the 560 pt sheet).
    @Published package var confirming: UUID?
    /// The last removal's error, for the line under the card.
    @Published package private(set) var failure: String?
    /// The games measured at least once: a game with a folder that is not measured yet shows its menu item without a size.
    private(set) var measured: Set<UUID> = []
    private var games: [UUID: Game] = [:]
    private var confirmingAllForGame = false
    private var generation = 0

    private let measure: @Sendable (Game) -> Int64
    private let removeFiles: @Sendable (Game) throws -> Int64

    /// - Parameters:
    ///   - measure: the bytes a removal would free (0: nothing to remove).
    ///   - remove: removes them and returns the bytes freed.
    package init(measure: @escaping @Sendable (Game) -> Int64, remove: @escaping @Sendable (Game) throws -> Int64) {
        self.measure = measure
        self.removeFiles = remove
    }

    package var total: Int64 { entries.reduce(0) { $0 + $1.bytes } }
    package func entry(_ id: UUID) -> Entry? { entries.first { $0.id == id } }
    /// All build-folder entries belonging to `gameID`.
    package func entries(forGame gameID: UUID) -> [Entry] { entries.filter { $0.ownerID == gameID } }
    /// Whether the store has a size for this game yet (with or without files to remove).
    package func isMeasured(_ id: UUID) -> Bool { measured.contains(id) }
    package func isMeasured(forGame gameID: UUID) -> Bool {
        measured.contains(gameID) || games.values.contains { $0.ownerID == gameID && measured.contains($0.id) }
    }
    package var confirmingEntry: Entry? {
        guard let confirming else { return nil }
        if !confirmingAllForGame { return entry(confirming) }
        let matched = entries(forGame: confirming)
        guard !matched.isEmpty else { return nil }
        if matched.count == 1 { return matched[0] }
        let baseName = matched.first { $0.id == confirming }?.name ?? matched[0].name
        return Entry(
            id: confirming,
            gameID: confirming,
            name: baseName,
            folder: matched.map(\.folder).joined(separator: "\n"),
            bytes: matched.reduce(0) { $0 + $1.bytes }
        )
    }

    package nonisolated static func sorted(_ entries: [Entry]) -> [Entry] {
        entries.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Measures the games' build folders again, off the main actor. A game that is gone or has nothing to remove drops out of the list.
    @discardableResult package func refresh(_ games: [Game]) -> Task<Void, Never> {
        self.games = Dictionary(games.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        generation += 1
        let generation = generation, measure = measure
        measuring = true
        return Task { @MainActor in
            let sizes = await Task.detached(priority: .utility) { games.map { ($0, measure($0)) } }.value
            guard generation == self.generation else { return }
            entries = Self.sorted(sizes.filter { $0.1 > 0 }.map {
                Entry(id: $0.0.id, gameID: $0.0.gameID, name: $0.0.name, folder: $0.0.folder, bytes: $0.1)
            })
            measured = Set(games.map(\.id))
            measuring = false
        }
    }

    /// Asks before removing a single build folder entry (the sheet). Nothing to ask for a folder with none, or while that game builds.
    package func ask(_ id: UUID, building: Bool) {
        guard !building, removing == nil, entry(id) != nil else { return }
        failure = nil
        confirmingAllForGame = false
        confirming = id
    }

    /// Asks before removing all build folders belonging to `gameID` (from the game's Manage menu).
    package func askForGame(_ gameID: UUID, building: Bool) {
        let matched = entries(forGame: gameID)
        guard !building, removing == nil, !matched.isEmpty else { return }
        if matched.count == 1 {
            ask(matched[0].id, building: building)
            return
        }
        failure = nil
        confirmingAllForGame = true
        confirming = gameID
    }

    /// The answer to the question: removes the files, then measures that entry (or all folders of that game) again. Refused while the game builds.
    @discardableResult package func remove(_ id: UUID, building: Bool) -> Task<Void, Never>? {
        let removeAllForGame = confirmingAllForGame && confirming == id
        confirming = nil
        confirmingAllForGame = false
        let targets: [Game] = removeAllForGame
            ? games.values.filter { $0.ownerID == id }
            : games[id].map { [$0] } ?? []
        guard !building, removing == nil, !targets.isEmpty else { return nil }
        removing = id
        failure = nil
        let removeFiles = removeFiles, measure = measure
        return Task { @MainActor in
            let results = await Task.detached(priority: .userInitiated) { () -> (Error?, [(Game, Int64)]) in
                var firstError: Error?
                var after: [(Game, Int64)] = []
                for target in targets {
                    do { _ = try removeFiles(target) } catch let e { if firstError == nil { firstError = e } }
                    after.append((target, measure(target)))
                }
                return (firstError, after)
            }.value
            removing = nil
            if let error = results.0 { failure = error.localizedDescription }
            let removedIDs = Set(targets.map(\.id))
            var next = entries.filter { !removedIDs.contains($0.id) }
            for (target, remainingBytes) in results.1 {
                if remainingBytes > 0 {
                    next.append(Entry(id: target.id, gameID: target.gameID, name: target.name, folder: target.folder, bytes: remainingBytes))
                }
                measured.insert(target.id)
            }
            entries = Self.sorted(next)
        }
    }
}
