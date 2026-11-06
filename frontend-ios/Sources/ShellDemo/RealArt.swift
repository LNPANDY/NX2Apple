import Foundation
import ShellUI

/// The test launcher's Nintendo catalogue. Readiness, installed versions and recency are simulated.
enum RealArt {
    static func tiles() -> [GameTile] {
        let args = ProcessInfo.processInfo.arguments
        let bundled = Bundle.main.url(forResource: "catalog", withExtension: "json", subdirectory: "ReviewCatalog")
        #if SWIFT_PACKAGE
        let metadata = Bundle.module.url(forResource: "catalog", withExtension: "json")
        #else
        let metadata = Bundle.main.url(forResource: "catalog", withExtension: "json")
        #endif
        let file: URL?
        if let flag = args.firstIndex(of: "--review-catalog"), args.indices.contains(flag + 1) {
            file = URL(fileURLWithPath: args[flag + 1])
        } else { file = bundled ?? metadata }
        guard let file else { return [] }
        do {
            let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: file))
            guard !catalog.games.isEmpty, Set(catalog.games.map(\.id)).count == catalog.games.count else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return try catalog.games.map { entry in
                guard !entry.title.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                func artwork(_ name: String?) throws -> Artwork? {
                    guard let name else { return nil }
                    let image = file.deletingLastPathComponent().appendingPathComponent(name).standardizedFileURL
                    guard image.deletingLastPathComponent() == file.deletingLastPathComponent().standardizedFileURL else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    // Public image files stay local; metadata-only builds use the standard title placeholder.
                    guard FileManager.default.fileExists(atPath: image.path) else { return nil }
                    guard let art = Artwork(id: name, data: try Data(contentsOf: image)) else { throw CocoaError(.fileReadCorruptFile) }
                    return art
                }
                let state: GameState = switch entry.demoState {
                case "missingData": .needsGameData
                case "updateRequired": .needsAppUpdate
                case "broken": .broken(reason: demoText("Game files damaged"), detail: demoText("Some of this game's bundled files could not be verified."))
                default: .playable
                }
                return GameTile(id: entry.id, title: entry.title, banner: try artwork(entry.artwork), icon: try artwork(entry.icon),
                                state: state, recentlyPlayed: entry.demoLastPlayedDaysAgo.map { ShellFormat.played(Date().addingTimeInterval(-Double($0) * 86_400)) },
                                version: entry.demoVersion ?? "")
            }
        } catch {
            fputs("Nintendo demo catalog: \(error.localizedDescription)\n", stderr)
            return []
        }
    }
    private struct Catalog: Decodable {
        struct Entry: Decodable {
            let id: String; let title: String; let artwork: String?; let icon: String?
            let demoState: String?; let demoVersion: String?; let demoLastPlayedDaysAgo: Int?
        }
        let games: [Entry]
    }
}
