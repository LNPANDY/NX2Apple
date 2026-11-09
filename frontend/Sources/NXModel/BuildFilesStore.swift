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
        package let name: String
        package let folder: String
        package let protecting: [String]
        package init(id: UUID, name: String, folder: String, protecting: [String] = []) {
            self.id = id; self.name = name; self.folder = folder; self.protecting = protecting
        }
    }

    /// A game's removable build files and their size in bytes.
    package struct Entry: Equatable, Identifiable, Sendable {
        package let id: UUID
        package let name: String
        package let folder: String
        package let bytes: Int64
        package init(id: UUID, name: String, folder: String, bytes: Int64) {
            self.id = id; self.name = name; self.folder = folder; self.bytes = bytes
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
    /// Whether the store has a size for this game yet (with or without files to remove).
    package func isMeasured(_ id: UUID) -> Bool { measured.contains(id) }
    package var confirmingEntry: Entry? { confirming.flatMap(entry) }

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
            entries = Self.sorted(sizes.filter { $0.1 > 0 }.map { Entry(id: $0.0.id, name: $0.0.name, folder: $0.0.folder, bytes: $0.1) })
            measured = Set(games.map(\.id))
            measuring = false
        }
    }

    /// Asks before removing a game's build files (the sheet). Nothing to ask for a game with none, or while that game builds.
    package func ask(_ id: UUID, building: Bool) {
        guard !building, removing == nil, entry(id) != nil else { return }
        failure = nil
        confirming = id
    }

    /// The answer to the question: removes the files, then measures that game again. Refused while the game builds.
    @discardableResult package func remove(_ id: UUID, building: Bool) -> Task<Void, Never>? {
        confirming = nil
        guard !building, removing == nil, let game = games[id] else { return nil }
        removing = id
        failure = nil
        let removeFiles = removeFiles, measure = measure
        return Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) { () -> (Error?, Int64) in
                var error: Error?
                do { _ = try removeFiles(game) } catch let e { error = e }
                return (error, measure(game))
            }.value
            removing = nil
            if let error = result.0 { failure = error.localizedDescription }
            var next = entries.filter { $0.id != id }
            if result.1 > 0 { next.append(Entry(id: game.id, name: game.name, folder: game.folder, bytes: result.1)) }
            entries = Self.sorted(next)
            measured.insert(id)
        }
    }
}
