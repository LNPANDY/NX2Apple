import Foundation
import NXCore

/// One row of the app's `dm/launcher.json` (dm/games/settings.py), the list the iPhone launcher shows
/// (dm/ios/Sources/LauncherSettings.swift). Each sets an environment variable the game reads at start.
struct LaunchSetting: Decodable, Identifiable {
    let env, kind: String
    var label, note: String   // var: localized() puts the launcher's language in place of the build's English
    var def: String
    let section: String?
    var options: [[String]]?   // choice: [value, label]
    let min, max, step: Double?   // range
    let on, off: String?   // toggle: the values the variable takes
    /// "basic" for a setting shown first (settings.tsv's level column, seedds/nxnative#399); without it, `basicByDefault` decides.
    var level: String? = nil
    /// The 3D views' base size the setting scales, docked and handheld ([width, height]); the render scale's row shows pixels with it.
    var base: [String: [Int]]? = nil
    /// `<VAR>=<value>` (schema 1, optional): the row is a sub-setting, shown only while the row that sets <VAR> has that value.
    var needs: String? = nil
    /// The game language row's preselected language: the Mac's, when the game has it (forMac sets it and makes it the default).
    var macLanguage: String? = nil
    /// The packed default of the game language row of a game built in English (forMac sets it): `def` may be the Mac's language
    /// instead, and every pick on this row is kept, so a later Mac language does not replace it.
    var packedDefault: String? = nil
    /// The value that leaves the variable unset (DM_FULLSCREEN is on when it is set at all).
    var unsetValue: String? = nil
    /// A setting this launcher adds itself (launcher.json has no row for it) is not a saved choice: the store has no rule for it.
    var storeBacked: Bool { unsetValue == nil }
    var id: String { env }
    var sectionTitle: String { section ?? "Game" }
    /// The rows the sheet shows first, as seedds/nxnative#374 groups them; the rest are under Advanced settings.
    static let basicByDefault: Set = ["DM_FPS_TARGET", "DM_RENDER_SCALE", "DM_FULLSCREEN", "DM_OPMODE", "DM_LANG", "DM_RUMBLE"]
    var isBasic: Bool { level.map { $0 == "basic" } ?? Self.basicByDefault.contains(env) }
    var onValue: String { on ?? "1" }
    var offValue: String { off ?? "0" }
    func isDefault(_ v: String) -> Bool {   // a range compares as numbers (a slider writes 1.00 for 1.0)
        kind == "range" ? abs((Double(v) ?? .nan) - (Double(def) ?? .nan)) < 1e-6 : v == def
    }
    func accepts(_ v: String) -> Bool {   // a saved choice the build still offers
        switch kind {
        case "choice": return options?.contains { $0.first == v } ?? false
        case "range":   // as dm/mac/launcher.c: no leading space, no hex, no NaN
            guard !v.isEmpty, !(v.first?.isWhitespace ?? true), !v.contains("x"), !v.contains("X"),
                  let n = Double(v), n.isFinite, let lo = min, let hi = max else { return false }
            return n >= lo && n <= hi
        case "toggle": return v == onValue || v == offValue
        default: return true
        }
    }
    enum CodingKeys: String, CodingKey { case env, kind, label, note, def = "default", section, options, min, max, step, on, off, level, base, needs }

    /// The settings a Mac app was packed with; nil for an app packed before they were (see LaunchList for the schema).
    static func read(app: String) -> [LaunchSetting]? {
        let url = URL(fileURLWithPath: app).appendingPathComponent("Contents/Resources/dm/launcher.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return LaunchList.parse(data)?.settings
    }

    /// The app's settings as the Mac shows them: the Mac-only Display mode added when the list has none (the host reads
    /// DM_FULLSCREEN in front_mac.m; a list from settings.tsv will carry it as a platform:mac row), and the render scale's
    /// base size from the game's profile in the repository when the list does not carry it (render_base).
    static func forMac(app: String, titleID: String, repo: String, labels: (String) -> String,
                       preferred: [String] = Locale.preferredLanguages) -> [LaunchSetting]? {
        guard var list = read(app: app)?.map({ $0.localized(labels) }) else { return nil }
        if !list.contains(where: { $0.env == "DM_FULLSCREEN" }) {
            let display = LaunchSetting(env: "DM_FULLSCREEN", kind: "choice", label: labels("launch.display"), note: "", def: "",
                                        section: "Game", options: [["", labels("launch.display.window")], ["1", labels("launch.display.fullscreen")]],
                                        min: nil, max: nil, step: nil, on: nil, off: nil, unsetValue: "")
            list.insert(display, at: (list.firstIndex { $0.env == "DM_RENDER_SCALE" }).map { $0 + 1 } ?? 0)
        }
        if let i = list.firstIndex(where: { $0.env == "DM_LANG" }) {
            // A game with no language list gets every language and a note from the engine (seedds/nxnative aafe01d, #668): the
            // RomFS names the ones it really has
            if RomFSLanguages.isFallbackRow(options: list[i].options, note: list[i].note),
               let kept = RomFSLanguages.narrowed(list[i].options ?? [], default: list[i].def, to: RomFSLanguages.options(in: app)) {
                list[i].options = kept
                list[i].note = ""
            }
        } else {
            let langs = RomFSLanguages.options(in: app)
            if langs.count > 1 {
                let def = RomFSLanguages.defaultLanguage(forApp: app, options: langs)
                let row = LaunchSetting(env: "DM_LANG", kind: "choice", label: "Game language", note: "", def: def,
                                        section: "Game", options: langs, min: nil, max: nil, step: nil, on: nil, off: nil,
                                        level: "basic", unsetValue: def).localized(labels)
                let idx = list.firstIndex { $0.env == "DM_FULLSCREEN" }
                    ?? list.lastIndex { $0.sectionTitle == "Game" }.map { $0 + 1 } ?? 0
                list.insert(row, at: idx)
            }
        }
        if MacGameMode.canConfigure(app: app), !list.contains(where: { $0.env == MacGameMode.optionEnv }) {
            let gameMode = LaunchSetting(
                env: MacGameMode.optionEnv,
                kind: "toggle",
                label: labels("launch.set.MAC_GAME_MODE"),
                note: labels("launch.set.MAC_GAME_MODE.note"),
                def: "0",
                section: "Game",
                options: nil,
                min: nil,
                max: nil,
                step: nil,
                on: "1",
                off: "0",
                level: "basic",
                unsetValue: "0"
            )
            let idx = list.firstIndex { $0.env == "DM_FULLSCREEN" }.map { $0 + 1 }
                ?? list.lastIndex { $0.sectionTitle == "Game" }.map { $0 + 1 } ?? 0
            list.insert(gameMode, at: idx)
        }
        if let i = list.firstIndex(where: { $0.env == "DM_RENDER_SCALE" && $0.base == nil }), let base = renderBase(titleID: titleID, repo: repo) {
            list[i].base = base
        }
        // The Mac's language is the game language row's default when the game has it (SavedChoices.macLanguage)
        if let i = list.firstIndex(where: { $0.env == "DM_LANG" && $0.kind == "choice" && SavedChoices.builtInEnglish($0) }) {
            list[i].packedDefault = list[i].def
            if let code = SavedChoices.macLanguage(list[i], preferred: preferred) {
                list[i].def = code
                list[i].macLanguage = code
            }
        }
        return list
    }

    /// The row in the launcher's language: launch.set.<VAR> for the label, launch.set.<VAR>.note for the note and
    /// launch.opt.<VAR>.<value> for a choice. launcher.json carries English only; a key the table does not have (a row
    /// a newer build adds) keeps the build's own text rather than showing the key.
    func localized(_ labels: (String) -> String) -> LaunchSetting {
        func text(_ key: String, _ fallback: String) -> String {
            let s = labels(key)
            return s == key ? fallback : s
        }
        var s = self
        s.label = text("launch.set." + env, label)
        if !note.isEmpty { s.note = text("launch.set.\(env).note", note) }
        s.options = options?.map { $0.count > 1 ? [$0[0], text("launch.opt.\(env).\($0[0])", $0[1])] : $0 }
        return s
    }

    /// render_base in the game's profile ("1600x900 1280x720": docked, then handheld).
    static func renderBase(titleID: String, repo: String) -> [String: [Int]]? {
        let path = EngineLayout.root(repo) + "/dm/games/" + titleID + "/game.tsv"
        guard !repo.isEmpty, let text = try? String(contentsOfFile: path, encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("render_base\t") }) else { return nil }
        let sizes = line.dropFirst("render_base\t".count).split(separator: " ").map { $0.split(separator: "x").compactMap { Int($0) } }
        guard sizes.count == 2, sizes.allSatisfy({ $0.count == 2 }) else { return nil }
        return ["docked": sizes[0], "handheld": sizes[1]]
    }

    /// The render scale as pixels: the base size of the console mode chosen (DM_OPMODE: 1 docked, 0 handheld) times the scale.
    func pixels(scale: Double, docked: Bool) -> String? {
        guard let size = base?[docked ? "docked" : "handheld"], size.count == 2 else { return nil }
        return "\(Int((Double(size[0]) * scale).rounded()))×\(Int((Double(size[1]) * scale).rounded()))"
    }
}
