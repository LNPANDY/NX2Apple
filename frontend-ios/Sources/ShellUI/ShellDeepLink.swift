import Foundation

/// Routes opened by Home Screen and Lock Screen widgets (`nx2apple://...`).
public enum ShellDeepLink: Equatable, Sendable {
    public static let scheme = "nx2apple"

    case library
    case controllers
    case game(id: String)
    case play(id: String)
    case settings(id: String)

    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme else { return nil }
        let host = (url.host() ?? "").lowercased()
        let rawID = url.pathComponents.dropFirst().first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedID = Self.normalizeGameID(rawID)
        switch host {
        case "", "library":
            self = .library
        case "controllers":
            self = .controllers
        case "game":
            guard !normalizedID.isEmpty else { self = .library; return }
            self = .game(id: normalizedID)
        case "play":
            guard !normalizedID.isEmpty else { self = .library; return }
            self = .play(id: normalizedID)
        case "settings":
            guard !normalizedID.isEmpty else { self = .library; return }
            self = .settings(id: normalizedID)
        default:
            return nil
        }
    }

    public var url: URL {
        switch self {
        case .library:
            return URL(string: "\(Self.scheme)://library")!
        case .controllers:
            return URL(string: "\(Self.scheme)://controllers")!
        case .game(let id):
            return Self.route("game", id: id)
        case .play(let id):
            return Self.route("play", id: id)
        case .settings(let id):
            return Self.route("settings", id: id)
        }
    }

    private static func route(_ host: String, id: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = "/" + normalizeGameID(id)
        return components.url ?? URL(string: "\(scheme)://library")!
    }

    public static func normalizeGameID(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count == 16, trimmed.allSatisfy(\.isHexDigit) {
            return trimmed.uppercased()
        }
        return trimmed
    }
}

/// Monotonically sequenced deep-link navigation event passed from `ShellHostModel` into `LibraryView`.
public struct ShellNavigationRequest: Equatable, Sendable {
    public var sequence: Int
    public var link: ShellDeepLink

    public init(sequence: Int, link: ShellDeepLink) {
        self.sequence = sequence
        self.link = link
    }
}
