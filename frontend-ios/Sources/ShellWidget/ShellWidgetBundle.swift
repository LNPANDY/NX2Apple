import AppIntents
import Foundation
import ShellUI
import SwiftUI
import WidgetKit

// MARK: - AppIntents Configuration & Dynamic Game Picker

public enum ShellWidgetCollectionOption: String, AppEnum, Sendable {
    case recentAndReady
    case switch2Only
    case pinnedGame

    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Collection")
    public static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .recentAndReady: DisplayRepresentation(title: "Recent & Ready"),
        .switch2Only: DisplayRepresentation(title: "Switch 2 Only"),
        .pinnedGame: DisplayRepresentation(title: "Pinned Game"),
    ]

    public var filter: ShellWidgetFilter {
        switch self {
        case .recentAndReady: return .all
        case .switch2Only: return .switch2
        case .pinnedGame: return .pinned
        }
    }
}

public enum ShellWidgetTapOption: String, AppEnum, Sendable {
    case launchGame
    case showInLibrary

    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "When Tapped")
    public static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .launchGame: DisplayRepresentation(title: "Launch Game"),
        .showInLibrary: DisplayRepresentation(title: "Show in Library"),
    ]

    public var behavior: ShellWidgetTapBehavior {
        switch self {
        case .launchGame: return .launch
        case .showInLibrary: return .inspect
        }
    }
}

public struct ShellWidgetGameEntity: AppEntity, Sendable {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Featured Game")
    public static let defaultQuery = ShellWidgetGameQuery()

    public var id: String
    public var title: String
    public var subtitle: String

    public init(id: String, title: String, subtitle: String = "") {
        self.id = id
        self.title = title
        self.subtitle = subtitle
    }

    public var displayRepresentation: DisplayRepresentation {
        if subtitle.isEmpty {
            return DisplayRepresentation(title: "\(title)")
        }
        return DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)")
    }
}

public struct ShellWidgetGameQuery: EntityQuery, Sendable {
    public init() {}

    public func entities(for identifiers: [String]) async throws -> [ShellWidgetGameEntity] {
        let wanted = Set(identifiers.map { $0.uppercased() })
        let snapshot = WidgetSnapshotStore.loadSnapshot(decodeArtwork: false)
        let pool = snapshot.games.isEmpty ? ShellWidgetSnapshot.sample.games : snapshot.games
        return pool
            .filter { wanted.contains($0.id.uppercased()) }
            .map(Self.makeEntity)
    }

    public func suggestedEntities() async throws -> [ShellWidgetGameEntity] {
        let snapshot = WidgetSnapshotStore.loadSnapshot(decodeArtwork: false)
        let pool = snapshot.games.isEmpty ? ShellWidgetSnapshot.sample.games : snapshot.games
        return pool.map(Self.makeEntity)
    }

    private static func makeEntity(_ game: ShellWidgetGame) -> ShellWidgetGameEntity {
        var parts: [String] = []
        if game.isSwitch2 { parts.append(ShellWidgetStrings.switch2Title) }
        if !game.version.isEmpty { parts.append("v\(game.version)") }
        return ShellWidgetGameEntity(id: game.id, title: game.title, subtitle: parts.joined(separator: " · "))
    }
}

public struct ShellContinueWidgetIntent: WidgetConfigurationIntent {
    public static let title: LocalizedStringResource = "Continue Playing"
    public static let description = IntentDescription(
        "Jump back into your recent and ready games from the Home Screen or Lock Screen."
    )

    @Parameter(title: "Collection", default: .recentAndReady)
    public var collection: ShellWidgetCollectionOption

    @Parameter(title: "Featured Game")
    public var featuredGame: ShellWidgetGameEntity?

    @Parameter(title: "When Tapped", default: .launchGame)
    public var tapAction: ShellWidgetTapOption

    public init() {}

    public init(
        collection: ShellWidgetCollectionOption = .recentAndReady,
        featuredGame: ShellWidgetGameEntity? = nil,
        tapAction: ShellWidgetTapOption = .launchGame
    ) {
        self.collection = collection
        self.featuredGame = featuredGame
        self.tapAction = tapAction
    }

    var effectiveFilter: ShellWidgetFilter {
        if featuredGame != nil && collection == .recentAndReady {
            return .pinned
        }
        return collection.filter
    }
}

public struct ShellSwitch2WidgetIntent: WidgetConfigurationIntent {
    public static let title: LocalizedStringResource = "Switch 2 Deck"
    public static let description = IntentDescription(
        "Spotlight your Switch 2 collection with instant one-tap launch."
    )

    @Parameter(title: "Featured Game")
    public var featuredGame: ShellWidgetGameEntity?

    @Parameter(title: "When Tapped", default: .launchGame)
    public var tapAction: ShellWidgetTapOption

    public init() {}
}

// MARK: - Timeline Entries & Providers

public struct ShellWidgetEntry: TimelineEntry {
    public let date: Date
    public let snapshot: ShellWidgetSnapshot
    public let filter: ShellWidgetFilter
    public let tapBehavior: ShellWidgetTapBehavior

    public init(
        date: Date,
        snapshot: ShellWidgetSnapshot,
        filter: ShellWidgetFilter = .all,
        tapBehavior: ShellWidgetTapBehavior = .launch
    ) {
        self.date = date
        self.snapshot = snapshot
        self.filter = filter
        self.tapBehavior = tapBehavior
    }
}

struct ShellContinueTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ShellWidgetEntry {
        ShellWidgetEntry(date: Date(), snapshot: .sample, filter: .all, tapBehavior: .launch)
    }

    func snapshot(for configuration: ShellContinueWidgetIntent, in context: Context) async -> ShellWidgetEntry {
        let now = Date()
        let filter = configuration.effectiveFilter
        let pinnedID = configuration.featuredGame?.id
        let loaded = WidgetSnapshotStore.loadSnapshot(filter: filter, pinnedGameID: pinnedID, now: now)
        let resolved = (context.isPreview && loaded.games.isEmpty)
            ? ShellWidgetSnapshot.sample.resolved(filter: filter, pinnedGameID: pinnedID)
            : loaded
        return ShellWidgetEntry(date: now, snapshot: resolved, filter: filter, tapBehavior: configuration.tapAction.behavior)
    }

    func timeline(for configuration: ShellContinueWidgetIntent, in context: Context) async -> Timeline<ShellWidgetEntry> {
        let now = Date()
        let filter = configuration.effectiveFilter
        let resolved = WidgetSnapshotStore.loadSnapshot(filter: filter, pinnedGameID: configuration.featuredGame?.id, now: now)
        let entry = ShellWidgetEntry(date: now, snapshot: resolved, filter: filter, tapBehavior: configuration.tapAction.behavior)
        let nextRefresh = nextMidnight(after: now)
        return Timeline(entries: [entry], policy: .after(nextRefresh))
    }
}

struct ShellSwitch2TimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ShellWidgetEntry {
        let sample = ShellWidgetSnapshot.sample.resolved(filter: .switch2)
        return ShellWidgetEntry(date: Date(), snapshot: sample, filter: .switch2, tapBehavior: .launch)
    }

    func snapshot(for configuration: ShellSwitch2WidgetIntent, in context: Context) async -> ShellWidgetEntry {
        let now = Date()
        let pinnedID = configuration.featuredGame?.id
        let loaded = WidgetSnapshotStore.loadSnapshot(filter: .switch2, pinnedGameID: pinnedID, now: now)
        let resolved: ShellWidgetSnapshot
        if context.isPreview && loaded.games.isEmpty {
            let s2 = ShellWidgetSnapshot.sample.resolved(filter: .switch2)
            resolved = pinnedID.map { s2.resolved(filter: .pinned, pinnedGameID: $0) } ?? s2
        } else {
            resolved = loaded
        }
        return ShellWidgetEntry(date: now, snapshot: resolved, filter: .switch2, tapBehavior: configuration.tapAction.behavior)
    }

    func timeline(for configuration: ShellSwitch2WidgetIntent, in context: Context) async -> Timeline<ShellWidgetEntry> {
        let now = Date()
        let resolved = WidgetSnapshotStore.loadSnapshot(filter: .switch2, pinnedGameID: configuration.featuredGame?.id, now: now)
        let entry = ShellWidgetEntry(date: now, snapshot: resolved, filter: .switch2, tapBehavior: configuration.tapAction.behavior)
        return Timeline(entries: [entry], policy: .after(nextMidnight(after: now)))
    }
}

private func nextMidnight(after now: Date) -> Date {
    let calendar = Calendar.current
    if let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) {
        return tomorrow.addingTimeInterval(60)
    }
    return now.addingTimeInterval(3600)
}

// MARK: - WidgetKit Entry Host View

private struct ShellWidgetContainerView: View {
    let entry: ShellWidgetEntry
    @Environment(\.widgetFamily) private var widgetFamily

    private var shellFamily: ShellWidgetFamily {
        #if os(iOS)
        switch widgetFamily {
        case .systemSmall: return .small
        case .systemMedium: return .medium
        case .systemLarge: return .large
        case .systemExtraLarge: return .extraLarge
        case .accessoryRectangular: return .accessoryRectangular
        case .accessoryCircular: return .accessoryCircular
        case .accessoryInline: return .accessoryInline
        default: return .medium
        }
        #else
        switch widgetFamily {
        case .systemSmall: return .small
        case .systemMedium: return .medium
        case .systemLarge: return .large
        case .systemExtraLarge: return .extraLarge
        default: return .medium
        }
        #endif
    }

    private var defaultDestination: URL {
        entry.snapshot.games.first?.primaryURL(behavior: entry.tapBehavior) ?? ShellDeepLink.library.url
    }

    var body: some View {
        ShellWidgetView(
            snapshot: entry.snapshot,
            family: shellFamily,
            filter: entry.filter,
            tapBehavior: entry.tapBehavior
        )
        .widgetURL(defaultDestination)
        .containerBackground(for: .widget) {
            switch shellFamily {
            case .small, .medium, .large, .extraLarge:
                ShellWidgetBackdrop(snapshot: entry.snapshot)
            case .accessoryCircular:
                AccessoryWidgetBackground()
            case .accessoryRectangular, .accessoryInline:
                Color.clear
            }
        }
    }
}

// MARK: - Public Widgets & Bundle

#if os(iOS)
private let continueFamilies: [WidgetFamily] = [
    .systemSmall, .systemMedium, .systemLarge, .systemExtraLarge,
    .accessoryRectangular, .accessoryCircular, .accessoryInline,
]
#else
private let continueFamilies: [WidgetFamily] = [
    .systemSmall, .systemMedium, .systemLarge, .systemExtraLarge,
]
#endif

private let switch2Families: [WidgetFamily] = [
    .systemSmall, .systemMedium, .systemLarge, .systemExtraLarge,
]

public struct ShellContinueWidget: Widget {
    public static let kind = "dev.nx2apple.shell.widget.continue"

    public init() {}

    public var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: ShellContinueWidgetIntent.self, provider: ShellContinueTimelineProvider()) { entry in
            ShellWidgetContainerView(entry: entry)
        }
        .configurationDisplayName(ShellWidgetStrings.continueTitle)
        .description(ShellWidgetStrings.continueDescription)
        .supportedFamilies(continueFamilies)
        .contentMarginsDisabled()
    }
}

public struct ShellSwitch2Widget: Widget {
    public static let kind = "dev.nx2apple.shell.widget.switch2"

    public init() {}

    public var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: ShellSwitch2WidgetIntent.self, provider: ShellSwitch2TimelineProvider()) { entry in
            ShellWidgetContainerView(entry: entry)
        }
        .configurationDisplayName(ShellWidgetStrings.switch2Title)
        .description(ShellWidgetStrings.switch2Description)
        .supportedFamilies(switch2Families)
        .contentMarginsDisabled()
    }
}

public struct ShellWidgetSuite: WidgetBundle {
    public init() {}

    public var body: some Widget {
        ShellContinueWidget()
        ShellSwitch2Widget()
    }
}
