import AppIntents
import Foundation
import ShellHost

/// An installed game in NX2Apple exposed to Apple Shortcuts so players can add a Home Screen launcher without pasting URLs.
struct ShortcutGameEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Game"
    static let defaultQuery = ShortcutGameQuery()

    var id: String
    var title: String
    var iconPNG: Data?

    var displayRepresentation: DisplayRepresentation {
        if let iconPNG {
            return DisplayRepresentation(title: "\(title)", image: .init(data: iconPNG))
        }
        return DisplayRepresentation(title: "\(title)")
    }

    init(id: String, title: String, iconPNG: Data? = nil) {
        self.id = id
        self.title = title
        self.iconPNG = iconPNG
    }

    init(item: ShortcutGameItem) {
        self.id = item.id
        self.title = item.title
        self.iconPNG = item.iconPNG
    }
}

struct ShortcutGameQuery: EntityStringQuery {
    private func allItems() -> [ShortcutGameItem] {
        let frameworks = Bundle.main.privateFrameworksURL
            ?? Bundle.main.bundleURL.appendingPathComponent("Frameworks", isDirectory: true)
        return HomeScreenShortcutSupport.availableGames(
            gamesRoot: frameworks,
            hotFrameworksRoot: ShellHostConfig.defaultHotFrameworksRoot(),
            appDataRoot: ShellHostConfig.defaultAppDataRoot()
        )
    }

    func entities(for identifiers: [String]) async throws -> [ShortcutGameEntity] {
        let items = allItems()
        return identifiers.compactMap { requested in
            let lowered = requested.lowercased()
            guard let matched = items.first(where: {
                $0.id.lowercased() == lowered || $0.titleID.lowercased() == lowered
            }) else {
                return nil
            }
            return ShortcutGameEntity(id: requested, title: matched.title, iconPNG: matched.iconPNG)
        }
    }

    func entities(matching string: String) async throws -> [ShortcutGameEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let items = allItems()
        guard !query.isEmpty else {
            return items.map(ShortcutGameEntity.init(item:))
        }
        return items
            .filter { $0.title.localizedStandardContains(query) || $0.id.localizedStandardContains(query) }
            .map(ShortcutGameEntity.init(item:))
    }

    func suggestedEntities() async throws -> [ShortcutGameEntity] {
        allItems().map(ShortcutGameEntity.init(item:))
    }
}

/// Launches the chosen game directly, sharing the same cold/warm transition path as `nx2apple://launch`.
struct LaunchGameIntent: AppIntent {
    static let title: LocalizedStringResource = "Launch Game"
    static let description = IntentDescription("Launches a game directly in NX2Apple.")
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Game")
    var game: ShortcutGameEntity

    init() {}

    init(game: ShortcutGameEntity) {
        self.game = game
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        var components = URLComponents()
        components.scheme = "nx2apple"
        components.host = "launch"
        components.queryItems = [URLQueryItem(name: "id", value: game.id)]
        if let url = components.url {
            _ = ShellLibrary.handleOpenURL(url)
        }
        return .result()
    }
}

struct ShellShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LaunchGameIntent(),
            phrases: [
                "Launch \(\.$game) in \(.applicationName)",
                "Play \(\.$game) in \(.applicationName)"
            ],
            shortTitle: "Launch Game",
            systemImageName: "gamecontroller.fill"
        )
    }
}
