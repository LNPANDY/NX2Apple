import Foundation

/// Parsed `nx2apple://launch` request and optional validated `x-callback-url` targets.
public struct DeepLinkRequest: Equatable, Sendable {
    public var target: String
    public var successURL: URL?
    public var errorURL: URL?

    public init(target: String, successURL: URL? = nil, errorURL: URL? = nil) {
        self.target = target
        self.successURL = successURL
        self.errorURL = errorURL
    }
}

/// Parses, validates, and resolves `nx2apple://launch` deep links for Apple Shortcuts and `x-callback-url` callers.
public enum DeepLinkRouter {
    private static let blockedCallbackSchemes: Set<String> = [
        "javascript", "data", "file", "http", "https", "about", "blob", "vbscript", "nx2apple"
    ]

    /// True when `url` targets the `nx2apple://launch` action regardless of whether `id` is present.
    public static func isLaunchURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "nx2apple",
              url.host?.lowercased() == "launch" else {
            return false
        }
        return true
    }

    /// Parses `nx2apple://launch?id=<target>&x-success=...&x-error=...` or shorthand `nx2apple://launch/<target>`.
    public static func parse(_ url: URL) -> DeepLinkRequest? {
        guard isLaunchURL(url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let queryItems = components.queryItems ?? []
        let queryTarget = queryItems.first(where: { $0.name == "id" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let pathTarget = decodedSinglePathSegment(from: components.percentEncodedPath)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let target: String?
        if let queryTarget, !queryTarget.isEmpty {
            target = queryTarget
        } else if let pathTarget, !pathTarget.isEmpty {
            target = pathTarget
        } else {
            target = nil
        }

        guard let resolvedTarget = target else { return nil }

        let successURL = validatedCallbackURL(queryItems.first(where: { $0.name == "x-success" })?.value)
        let errorURL = validatedCallbackURL(queryItems.first(where: { $0.name == "x-error" })?.value)
        return DeepLinkRequest(target: resolvedTarget, successURL: successURL, errorURL: errorURL)
    }

    /// Extracts a validated `x-error` URL even when `nx2apple://launch` lacks a target `id`.
    public static func extractErrorCallback(from url: URL) -> URL? {
        guard isLaunchURL(url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let raw = components.queryItems?.first(where: { $0.name == "x-error" })?.value else {
            return nil
        }
        return validatedCallbackURL(raw)
    }

    /// Allows only custom app schemes matching `^[A-Za-z][A-Za-z0-9+.-]*$` and rejects dangerous or recursive schemes.
    public static func validatedCallbackURL(_ raw: String?) -> URL? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let url = URL(string: trimmed),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme,
              isValidCustomScheme(scheme) else {
            return nil
        }
        if blockedCallbackSchemes.contains(scheme.lowercased()) {
            return nil
        }
        return url
    }

    /// Safely appends `errorMessage` to an `x-error` callback URL via `URLComponents`.
    public static func errorCallbackURL(base: URL, message: String) -> URL {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return base
        }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "errorMessage" }
        items.append(URLQueryItem(name: "errorMessage", value: message))
        components.queryItems = items
        return components.url ?? base
    }

    /// Case-insensitive 4-tier matching against scanned `CatalogueEntry` items:
    /// 1. `.framework` folder name (with or without `.framework` suffix) or `manifest.framework`
    /// 2. `bundleInfo?.bundleIdentifier`
    /// 3. Title ID (`entry.id`, `manifest.titleID`, `bundleInfo?.titleID`)
    /// 4. Display name (`bundleInfo?.displayName`, `manifest.name`, `readableName`)
    public static func matchEntry(target: String, in entries: [CatalogueEntry]) -> CatalogueEntry? {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowerTarget = trimmed.lowercased()
        let strippedTarget = lowerTarget.hasSuffix(".framework")
            ? String(lowerTarget.dropLast(".framework".count))
            : lowerTarget

        // Tier 1: .framework folder name with/without .framework suffix or manifest.framework
        if let match = entries.first(where: { entry in
            tier1FrameworkNames(for: entry).contains { candidate in
                let lower = candidate.lowercased()
                let stem = lower.hasSuffix(".framework") ? String(lower.dropLast(".framework".count)) : lower
                return lower == lowerTarget || (!strippedTarget.isEmpty && stem == strippedTarget)
            }
        }) {
            return match
        }

        // Tier 2: Info.plist CFBundleIdentifier
        if let match = entries.first(where: { entry in
            guard let bundleID = normalizedNonEmpty(entry.bundleInfo?.bundleIdentifier) else { return false }
            return bundleID.lowercased() == lowerTarget
        }) {
            return match
        }

        // Tier 3: Title ID
        if let match = entries.first(where: { entry in
            let candidates = [entry.id, entry.manifest?.titleID, entry.bundleInfo?.titleID].compactMap(normalizedNonEmpty)
            return candidates.contains { $0.lowercased() == lowerTarget }
        }) {
            return match
        }

        // Tier 4: Game title / display name
        return entries.first(where: { entry in
            let candidates = [entry.bundleInfo?.displayName, entry.manifest?.name, entry.readableName]
                .compactMap(normalizedNonEmpty)
            return candidates.contains { $0.lowercased() == lowerTarget }
        })
    }

    /// Generates `nx2apple://launch?id=<FrameworkName>` for an entry.
    public static func shortcutURLString(for entry: CatalogueEntry) -> String {
        var components = URLComponents()
        components.scheme = "nx2apple"
        components.host = "launch"
        components.queryItems = [URLQueryItem(name: "id", value: entry.shortcutFrameworkIdentifier)]
        return components.string ?? "nx2apple://launch?id=\(entry.shortcutFrameworkIdentifier)"
    }

    private static func decodedSinglePathSegment(from percentEncodedPath: String) -> String? {
        var trimmed = percentEncodedPath
        while trimmed.hasPrefix("/") { trimmed.removeFirst() }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty, !trimmed.contains("/") else { return nil }
        return trimmed.removingPercentEncoding
    }

    private static func isValidCustomScheme(_ scheme: String) -> Bool {
        guard let first = scheme.unicodeScalars.first,
              (first.value >= 65 && first.value <= 90) || (first.value >= 97 && first.value <= 122) else {
            return false
        }
        return scheme.unicodeScalars.allSatisfy { scalar in
            let v = scalar.value
            return (v >= 65 && v <= 90) || (v >= 97 && v <= 122) || (v >= 48 && v <= 57)
                || scalar == "+" || scalar == "." || scalar == "-"
        }
    }

    private static func tier1FrameworkNames(for entry: CatalogueEntry) -> [String] {
        var names: [String] = []
        if entry.directory.pathExtension.lowercased() == "framework",
           let name = normalizedNonEmpty(entry.directory.lastPathComponent) {
            names.append(name)
        }
        if let fwName = entry.frameworkURL?.lastPathComponent,
           fwName.lowercased().hasSuffix(".framework"),
           let name = normalizedNonEmpty(fwName) {
            names.append(name)
        }
        if let mfName = entry.manifest?.framework,
           mfName.lowercased().hasSuffix(".framework"),
           let name = normalizedNonEmpty(mfName) {
            names.append(name)
        }
        return names
    }

    private static func normalizedNonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
