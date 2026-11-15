import Foundation

public enum BookmarkResolution: Equatable, Sendable {
    case none
    case url(URL)
    /// A bookmark exists but does not resolve (the app is signed differently): ask the player to pick again.
    case stale
}

/// One security-scoped bookmark in a game's defaults, as dm/ios/Sources/DataBookmark.m keeps them: the key
/// `pickedDataBookmark` for the game data and `cloudSavesBookmark` for the cloud-save folder. The bookmark is written
/// with the picker's scope switched on, must resolve again before it is kept, and its scope is held for the session once
/// resolved. A bookmark the system calls stale but still resolves is rewritten.
@MainActor public final class BookmarkStore {
    public static let gameDataKey = "pickedDataBookmark"
    public static let cloudSavesKey = "cloudSavesBookmark"

    struct ScopeAccess: Sendable {
        var start: @Sendable (URL) -> Bool
        var stop: @Sendable (URL) -> Void

        static let system = ScopeAccess(
            start: { $0.startAccessingSecurityScopedResource() },
            stop: { $0.stopAccessingSecurityScopedResource() }
        )
    }

    private let defaults: UserDefaults
    private let key: String
    private let scope: ScopeAccess
    nonisolated(unsafe) private var held: URL?

    public convenience init(defaults: UserDefaults, key: String) {
        self.init(defaults: defaults, key: key, scope: .system)
    }

    init(defaults: UserDefaults, key: String, scope: ScopeAccess) {
        self.defaults = defaults
        self.key = key
        self.scope = scope
    }

    deinit {
        if let url = held { scope.stop(url) }
    }

    #if os(macOS)
    private static let createOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
    private static let resolveOptions: URL.BookmarkResolutionOptions = [.withSecurityScope]
    #else
    private static let createOptions: URL.BookmarkCreationOptions = []
    private static let resolveOptions: URL.BookmarkResolutionOptions = []
    #endif

    public var hasBookmark: Bool { (defaults.data(forKey: key)?.isEmpty ?? true) == false }

    /// Stores a bookmark for a URL the player just picked. False when the system refuses one or it does not resolve back.
    @discardableResult public func store(_ url: URL) -> Bool {
        releaseScope()
        // The scope the picker granted lasts while it is held, and a bookmark written without it stops resolving
        // from the next launch on. Keep the new scope open on success, or close it right away when storing fails.
        let accessed = scope.start(url)
        guard let data = try? url.bookmarkData(options: Self.createOptions, includingResourceValuesForKeys: nil, relativeTo: nil) else {
            if accessed { scope.stop(url) }
            return false
        }
        var stale = false
        guard (try? URL(resolvingBookmarkData: data, options: Self.resolveOptions, relativeTo: nil, bookmarkDataIsStale: &stale)) != nil else {
            if accessed { scope.stop(url) }
            return false
        }
        if accessed { held = url }
        defaults.set(data, forKey: key)
        return true
    }

    public func resolve() -> BookmarkResolution {
        guard let data = defaults.data(forKey: key), !data.isEmpty else {
            releaseScope()
            return .none
        }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: Self.resolveOptions, relativeTo: nil, bookmarkDataIsStale: &stale) else {
            releaseScope()
            return .stale
        }
        if held?.path != url.path { releaseScope() }
        if held == nil {
            let accessed = scope.start(url)
            if accessed { held = url }
        }
        if stale, let again = try? url.bookmarkData(options: Self.createOptions, includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(again, forKey: key)
        }
        return .url(url)
    }

    /// Forgets the choice.
    public func clear() {
        releaseScope()
        defaults.removeObject(forKey: key)
    }

    private func releaseScope() {
        if let url = held {
            scope.stop(url)
            held = nil
        }
    }
}
