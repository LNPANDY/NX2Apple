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

    private let defaults: UserDefaults
    private let key: String
    private var held: URL?

    public init(defaults: UserDefaults, key: String) {
        self.defaults = defaults
        self.key = key
    }

    #if os(macOS)
    private static let createOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
    private static let resolveOptions: URL.BookmarkResolutionOptions = [.withSecurityScope]
    #else
    private static let createOptions: URL.BookmarkCreationOptions = []
    private static let resolveOptions: URL.BookmarkResolutionOptions = []
    #endif

    public var hasBookmark: Bool { (defaults.data(forKey: key)?.isEmpty ?? true) == false }

    private static func fresh(_ url: URL) -> Data? {
        // The scope the picker granted lasts while it is held, and a bookmark written without it stops resolving
        // from the next launch on.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try? url.bookmarkData(options: createOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Stores a bookmark for a URL the player just picked. False when the system refuses one or it does not resolve back.
    @discardableResult public func store(_ url: URL) -> Bool {
        guard let data = Self.fresh(url) else { return false }
        var stale = false
        guard (try? URL(resolvingBookmarkData: data, options: Self.resolveOptions, relativeTo: nil, bookmarkDataIsStale: &stale)) != nil else { return false }
        releaseScope()
        defaults.set(data, forKey: key)
        return true
    }

    public func resolve() -> BookmarkResolution {
        guard let data = defaults.data(forKey: key), !data.isEmpty else { return .none }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: Self.resolveOptions, relativeTo: nil, bookmarkDataIsStale: &stale) else { return .stale }
        if held?.path != url.path { releaseScope() }
        if held == nil { _ = url.startAccessingSecurityScopedResource(); held = url }
        if stale, let again = Self.fresh(url) { defaults.set(again, forKey: key) }
        return .url(url)
    }

    /// Forgets the choice.
    public func clear() {
        releaseScope()
        defaults.removeObject(forKey: key)
    }

    private func releaseScope() {
        held?.stopAccessingSecurityScopedResource()
        held = nil
    }
}
