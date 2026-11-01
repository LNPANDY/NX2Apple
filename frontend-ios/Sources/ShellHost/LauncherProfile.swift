import Foundation

/// One row of `launcher.json` (docs/launcher.schema.json). The same fields, rules and defaults as the per-game app's
/// `Setting` in dm/ios/Sources/LauncherSettings.swift, so a value saved here means the same there.
public struct LauncherSetting: Decodable, Equatable, Sendable, Identifiable {
    public var env: String
    public var kind: String
    public var section: String?
    public var label: String
    public var note: String
    public var def: String
    public var needs: String?
    public var level: String?
    public var options: [[String]]?
    public var min: Double?
    public var max: Double?
    public var step: Double?
    public var on: String?
    public var off: String?
    public var id: String { env }
    public var sectionTitle: String { section ?? "Game" }
    public var onValue: String { on ?? "1" }
    public var offValue: String { off ?? "0" }

    enum CodingKeys: String, CodingKey { case env, kind, label, note, def = "default", section, needs, level, options, min, max, step, on, off }

    /// A range compares as numbers: a slider writes 1.00 for 1.0.
    public func isDefault(_ v: String) -> Bool {
        kind == "range" ? abs((Double(v) ?? .nan) - (Double(def) ?? .nan)) < 1e-6 : v == def
    }

    /// A saved value the game still offers.
    public func accepts(_ v: String) -> Bool {
        switch kind {
        case "choice": return options?.contains { $0.first == v } ?? false
        case "range":
            guard !v.contains(where: { $0 == "x" || $0 == "X" }), let n = Double(v), n.isFinite, let lo = min, let hi = max else { return false }
            return n >= lo && n <= hi
        case "toggle": return v == onValue || v == offValue
        default: return true
        }
    }

    /// The UserDefaults key the engine's launcher reads: `launcher.<VAR>`.
    public var defaultsKey: String { "launcher." + env }
}

/// `launcher.json`, schema 1.
public struct LauncherProfile: Decodable, Equatable, Sendable {
    public var schema: Int?
    public var game: String
    public var settings: [LauncherSetting]

    public static func parse(_ data: Data) throws(GameProblem) -> LauncherProfile {
        let profile: LauncherProfile
        do { profile = try JSONDecoder().decode(LauncherProfile.self, from: data) }
        catch { throw describe(error, file: "launcher.json", cause: .settingsDamaged) }
        let reason = ProblemCause.settingsDamaged.label
        if let schema = profile.schema, schema != 1 {
            throw GameProblem(cause: .settingsUnsupported, reason: hostText("Settings list not supported"), detail: hostText("launcher.json has schema \(schema), this app reads schema 1."))
        }
        guard isTitleID(profile.game) else {
            throw GameProblem(cause: .settingsDamaged, reason: reason, detail: hostText("game \"\(profile.game)\" in launcher.json is not 16 hex digits."))
        }
        var seen = Set<String>()
        for s in profile.settings {
            guard s.env.hasPrefix("DM_"), s.env.dropFirst(3).allSatisfy({ $0.isUppercase || $0.isNumber || $0 == "_" }), s.env.count > 3 else {
                throw GameProblem(cause: .settingsDamaged, reason: reason, detail: hostText("\"\(s.env)\" is not a DM_ switch."))
            }
            guard seen.insert(s.env).inserted else {
                throw GameProblem(cause: .settingsDamaged, reason: reason, detail: hostText("\(s.env) appears twice in launcher.json."))
            }
            switch s.kind {
            case "choice":
                guard let o = s.options, !o.isEmpty, o.allSatisfy({ $0.count == 2 }) else {
                    throw GameProblem(cause: .settingsDamaged, reason: reason, detail: hostText("\(s.env) is a choice without [value, label] options."))
                }
            case "range":
                guard s.min != nil, s.max != nil, let step = s.step, step > 0 else {
                    throw GameProblem(cause: .settingsDamaged, reason: reason, detail: hostText("\(s.env) is a range without min, max and step."))
                }
            case "toggle": break
            default:
                throw GameProblem(cause: .settingsDamaged, reason: reason, detail: hostText("\(s.env) has the unknown kind \"\(s.kind)\"."))
            }
        }
        return profile
    }
}
