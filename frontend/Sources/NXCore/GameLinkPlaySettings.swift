import Foundation

/// A generated game's Link Play entitlement is advertised by its bundle. The game profile also
/// declares which titles can gain the feature after a rebuild; neither check belongs in the UI.
package enum LinkPlayCapability {
    package static func supportedByApp(_ appPath: String) -> Bool {
        guard !appPath.isEmpty else { return false }
        let plist = URL(fileURLWithPath: appPath).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let marker = info["DMLinkPlay"] as? NSNumber else { return false }
        return marker.intValue == 1
    }

    package static func declaredInProfile(titleID: String, repo: String) -> Bool {
        guard !repo.isEmpty else { return false }
        let root = EngineLayout.root(repo)
        let path = root + "/dm/games/" + titleID.uppercased() + "/game.tsv"
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        return contents.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "link_play\tldn" }
    }
}

/// Settings for Pokopia's experimental nn::ldn LAN transport. No network activity happens in the frontend.
package struct LinkPlayConfiguration: Equatable {
    package var enabled = false
    package var joinAddress = ""
    package var discovery = true
    package var tcpOnly = false
    package var internet = false
    package var room = ""
    package var relayAddress = ""
    package var interact = false
    package var story = false

    package init() {}
}

package enum LinkPlaySettingsError: LocalizedError, Equatable {
    case invalidJoin, invalidRelay, publicJoin, invalidRoom, missingRoom

    package var errorDescription: String? {
        switch self {
        case .invalidJoin: return "Enter the host's IPv4 address, optionally followed by :port."
        case .invalidRelay: return "Enter the relay's IPv4 address, optionally followed by :port."
        case .publicJoin: return "A public host address requires Internet play."
        case .invalidRoom: return "Room codes must contain 16 Crockford Base32 letters or digits."
        case .missingRoom: return "Joining over the internet requires the host's room code."
        }
    }
}

/// Reads and writes the same per-title env.txt that the generated Mac app consumes at startup.
/// Only DM_COOP* keys are replaced; clock, audio, input and other options are preserved.
package struct GameLinkPlaySettings {
    package let titleID: String
    package let appPath: String
    package let support: URL

    package init(titleID: String, appPath: String = "", support: URL? = nil) {
        self.titleID = titleID
        self.appPath = appPath
        self.support = support ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    package var playerEnv: URL {
        support.appendingPathComponent("nxnative").appendingPathComponent(titleID).appendingPathComponent("env.txt")
    }

    package var bundledEnv: URL {
        URL(fileURLWithPath: appPath).appendingPathComponent("Contents/Resources/dm/env.txt")
    }

    private static let keys: Set<String> = [
        "DM_COOP", "DM_COOP_JOIN", "DM_COOP_DISCOVERY", "DM_COOP_TCP",
        "DM_COOP_INTERNET", "DM_COOP_ROOM", "DM_COOP_RELAY",
        "DM_COOP_INTERACT", "DM_COOP_STORY"
    ]

    package static func values(in text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let equal = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<equal]).trimmingCharacters(in: .whitespaces)
            if keys.contains(key) { result[key] = String(trimmed[trimmed.index(after: equal)...]) }
        }
        return result
    }

    package static func parse(_ values: [String: String]) -> LinkPlayConfiguration {
        var c = LinkPlayConfiguration()
        let coop = values["DM_COOP"] ?? "off"
        c.enabled = coop == "auto" || coop.hasPrefix("auto:") || coop.hasPrefix("join:") || coop.hasPrefix("host:")
        c.joinAddress = values["DM_COOP_JOIN"] ?? (coop.hasPrefix("join:") ? String(coop.dropFirst(5)) : "")
        c.discovery = values["DM_COOP_DISCOVERY"] != "0"
        c.tcpOnly = values["DM_COOP_TCP"] == "1"
        c.internet = values["DM_COOP_INTERNET"] == "1"
        c.room = values["DM_COOP_ROOM"] ?? ""
        c.relayAddress = values["DM_COOP_RELAY"] ?? ""
        c.interact = values["DM_COOP_INTERACT"] == "1" || values["DM_COOP_STORY"] == "1"
        c.story = values["DM_COOP_STORY"] == "1"
        return c
    }

    package func load() -> LinkPlayConfiguration {
        let bundled = appPath.isEmpty ? "" : ((try? String(contentsOf: bundledEnv, encoding: .utf8)) ?? "")
        let player = (try? String(contentsOf: playerEnv, encoding: .utf8)) ?? ""
        let effective = Self.values(in: bundled).merging(Self.values(in: player)) { _, player in player }
        return Self.parse(effective)
    }

    /// Validates what nxnative's coop_cfg_parse_ex will receive.
    package static func validate(_ c: LinkPlayConfiguration) throws {
        guard c.enabled else { return }
        if !c.joinAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let ip = ipv4(c.joinAddress) else { throw LinkPlaySettingsError.invalidJoin }
            if !c.internet && !lanAddress(ip) { throw LinkPlaySettingsError.publicJoin }
        }
        if c.internet {
            if !c.relayAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && ipv4(c.relayAddress) == nil {
                throw LinkPlaySettingsError.invalidRelay
            }
            if !c.room.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && roomCode(c.room) == nil {
                throw LinkPlaySettingsError.invalidRoom
            }
            if !c.joinAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                c.room.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw LinkPlaySettingsError.missingRoom
            }
        }
    }

    /// IPv4 and optional decimal TCP port; rejects DNS names and malformed/unspecified addresses.
    private static func ipv4(_ raw: String) -> [UInt8]? {
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else { return nil }
        if parts.count == 2 {
            let s = parts[1]
            guard !s.isEmpty, s.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let port = UInt16(String(s)), port > 0 else { return nil }
        }
        let digits = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard digits.count == 4 else { return nil }
        var address: [UInt8] = []
        for value in digits {
            guard !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let octet = UInt8(String(value)) else { return nil }
            address.append(octet)
        }
        guard address[0] > 0, address[0] < 224 else { return nil }
        return address
    }

    private static func lanAddress(_ ip: [UInt8]) -> Bool {
        ip[0] == 10 || ip[0] == 127 ||
        (ip[0] == 172 && (16...31).contains(ip[1])) ||
        (ip[0] == 192 && ip[1] == 168) ||
        (ip[0] == 169 && ip[1] == 254)
    }

    /// The engine accepts Crockford Base32 (O/I/L aliases). Store its canonical, human-readable form.
    package static func roomCode(_ raw: String) -> String? {
        let letters = raw.uppercased().filter { $0 != "-" && $0 != " " }.map { character -> Character in
            switch character { case "O": return "0"; case "I", "L": return "1"; default: return character }
        }
        let allowed = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        guard letters.count == 16, letters.allSatisfy({ allowed.contains($0) }) else { return nil }
        return stride(from: 0, to: 16, by: 4).map { String(letters[$0..<($0 + 4)]) }.joined(separator: "-")
    }

    package static func replacing(_ existing: String, with c: LinkPlayConfiguration) throws -> String {
        try validate(c)
        var lines = existing.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        lines.removeAll { line in
            guard let equal = line.firstIndex(of: "=") else { return false }
            return keys.contains(String(line[..<equal]).trimmingCharacters(in: .whitespaces))
        }
        lines.append("DM_COOP=\(c.enabled ? "auto" : "off")")
        lines.append("DM_COOP_JOIN=\(c.joinAddress.trimmingCharacters(in: .whitespacesAndNewlines))")
        lines.append("DM_COOP_DISCOVERY=\(c.discovery ? "1" : "0")")
        lines.append("DM_COOP_TCP=\(c.tcpOnly ? "1" : "0")")
        lines.append("DM_COOP_INTERNET=\(c.internet ? "1" : "0")")
        let room = c.internet ? (roomCode(c.room) ?? "") : c.room.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append("DM_COOP_ROOM=\(room)")
        lines.append("DM_COOP_RELAY=\(c.relayAddress.trimmingCharacters(in: .whitespacesAndNewlines))")
        // Never leave gameplay-hook switches armed when Link Play itself is turned off.
        lines.append("DM_COOP_INTERACT=\((c.enabled && (c.interact || c.story)) ? "1" : "0")")
        lines.append("DM_COOP_STORY=\((c.enabled && c.story) ? "1" : "0")")
        return lines.joined(separator: "\n") + "\n"
    }

    package func save(_ c: LinkPlayConfiguration) throws {
        // Do not erase an existing settings file if it cannot be read.
        let original = FileManager.default.fileExists(atPath: playerEnv.path)
            ? try String(contentsOf: playerEnv, encoding: .utf8) : ""
        let result = try Self.replacing(original, with: c)
        try FileManager.default.createDirectory(at: playerEnv.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(result.utf8).write(to: playerEnv, options: .atomic)
    }
}
