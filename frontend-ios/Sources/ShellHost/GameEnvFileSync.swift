import Foundation

/// Reads and updates per-game `Documents/games/<title ID>/env.txt` overrides without clobbering
/// comments, blank lines, or advanced non-UI keys (such as `DM_GUEST_FILE` or `DM_MEMSTAT`).
public enum GameEnvFileSync {
    /// Parses active `KEY=VALUE` entries from `env.txt` using the same first-wins semantics as `EngineLaunchPlan.make`.
    public static func readOverrides(at envURL: URL, fileManager fm: FileManager = .default) -> [String: String] {
        guard let data = fm.contents(atPath: envURL.path),
              let text = String(data: data, encoding: .utf8) else {
            return [:]
        }
        return parseOverrides(text)
    }

    public static func parseOverrides(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for entry in EngineLaunchPlan.parseEnvFile(text) where result[entry.key] == nil {
            result[entry.key] = entry.value
        }
        return result
    }

    /// Synchronizes a single UI-managed setting key back to an existing `env.txt` only when that key is actively set there.
    /// When `value` is `nil`, every active line for `key` is commented out so the default can take effect cleanly.
    /// When `value` is non-nil, the first active line is updated in place and duplicate active lines for `key` are commented out.
    @discardableResult
    public static func syncKey(_ key: String, value: String?, in envURL: URL, fileManager fm: FileManager = .default) -> Bool {
        guard let data = fm.contents(atPath: envURL.path),
              let text = String(data: data, encoding: .utf8) else {
            return false
        }
        guard let updated = rewriting(text, updates: [key: value]) else { return false }
        do {
            try Data(updated.utf8).write(to: envURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Comments out every active line whose key belongs to `keys` (used by "Reset to defaults"), preserving all other keys and comments.
    @discardableResult
    public static func clearKeys(_ keys: Set<String>, in envURL: URL, fileManager fm: FileManager = .default) -> Bool {
        guard !keys.isEmpty,
              let data = fm.contents(atPath: envURL.path),
              let text = String(data: data, encoding: .utf8) else {
            return false
        }
        var updates: [String: String?] = [:]
        for key in keys { updates[key] = .some(nil) }
        guard let updated = rewriting(text, updates: updates) else { return false }
        do {
            try Data(updated.utf8).write(to: envURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Pure text rewriter shared by `syncKey` and `clearKeys`. Returns `nil` when no active matching line needs changing.
    static func rewriting(_ text: String, updates: [String: String?]) -> String? {
        guard !updates.isEmpty else { return nil }
        let lineEnding = text.contains("\r\n") ? "\r\n" : "\n"
        let hasTrailingNewline = text.hasSuffix("\n") || text.hasSuffix("\r")
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var rawLines = normalized.components(separatedBy: "\n")
        if hasTrailingNewline, rawLines.last == "" {
            rawLines.removeLast()
        }

        var changed = false
        var updatedFirstLineForKey = Set<String>()
        var output: [String] = []
        output.reserveCapacity(rawLines.count)

        for raw in rawLines {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  !trimmed.hasPrefix("#"),
                  let eq = trimmed.firstIndex(of: "="),
                  eq != trimmed.startIndex else {
                output.append(raw)
                continue
            }
            let key = String(trimmed[..<eq])
            guard let targetValue = updates[key] else {
                output.append(raw)
                continue
            }
            if let newValue = targetValue {
                if updatedFirstLineForKey.insert(key).inserted {
                    let replacement = "\(key)=\(newValue)"
                    if raw != replacement { changed = true }
                    output.append(replacement)
                } else {
                    changed = true
                    output.append("# \(trimmed)")
                }
            } else {
                changed = true
                output.append("# \(trimmed)")
            }
        }

        guard changed else { return nil }
        var joined = output.joined(separator: lineEnding)
        if hasTrailingNewline { joined += lineEnding }
        return joined
    }
}
