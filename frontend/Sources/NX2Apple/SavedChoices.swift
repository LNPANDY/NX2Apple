import Foundation

/// A Mac game's launch options as seedds/nxnative keeps them (docs/frontends.md, "Saved choices"): one string per setting under
/// `launcher.<VAR>` in the built app's own preferences domain (its CFBundleIdentifier, `org.nxnative.<title ID lowercased>` unless the
/// app was packed with another). Only a choice that differs from the tested default is kept; dm/mac/launcher.c reads the keys at every
/// start, so a start from Finder or the Dock has them too, and the app's own settings window shares them.
///
/// What is stored and what is not:
/// - Every row of the app's launcher.json is a saved choice.
/// - A setting this launcher adds that launcher.json has no row for (Display mode, DM_FULLSCREEN, today) is not: launcher.c would
///   ignore a key it has no rule for. It stays in the library file and goes into the environment at Play, like the mods'
///   DM_ROMFS_OVERLAY and the Controls page's DM_KEYMAP / DM_PAD_MAP (those become saved choices when seedds/nxnative#386 merges).
/// - A launch override (anything in the environment at Play) is temporary and is never written here.
struct SavedChoices {
    let domain: String

    init(domain: String) { self.domain = domain }

    /// The app's preferences domain: CFBundleIdentifier from its Info.plist, else the default the packer uses.
    init(app: String, titleID: String) { self.init(domain: Self.domain(app: app, titleID: titleID)) }

    static func domain(app: String, titleID: String) -> String {
        let plist = URL(fileURLWithPath: app).appendingPathComponent("Contents/Info.plist")
        if let data = try? Data(contentsOf: plist),
           let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let id = info["CFBundleIdentifier"] as? String, !id.isEmpty { return id }
        return "org.nxnative." + titleID.lowercased()
    }

    static func key(_ env: String) -> String { "launcher." + env }

    /// The stored value, whatever it is (nil when there is none); the migration only asks whether the key is taken.
    func raw(_ env: String) -> Any? { CFPreferencesCopyAppValue(Self.key(env) as CFString, domain as CFString) }

    /// The saved choice the way launcher.c reads it: a string this build still offers, else nil (the tested default applies).
    func value(_ s: LaunchSetting) -> String? {
        guard let v = raw(s.env) as? String, s.accepts(v) else { return nil }
        return v
    }

    /// What the setting is set to: the saved choice, else the tested default.
    func current(_ s: LaunchSetting) -> String { value(s) ?? s.def }

    /// A choice equal to the tested default removes the key, so the setting follows a later build's defaults.
    func set(_ s: LaunchSetting, _ v: String) {
        if s.isDefault(v) || !s.accepts(v) { CFPreferencesSetAppValue(Self.key(s.env) as CFString, nil, domain as CFString) }
        else { CFPreferencesSetAppValue(Self.key(s.env) as CFString, v as CFString, domain as CFString) }
        CFPreferencesAppSynchronize(domain as CFString)
    }

    /// "Reset to tested defaults": the keys of the settings the player can change.
    func reset(_ settings: [LaunchSetting]) {
        for s in settings where s.storeBacked { CFPreferencesSetAppValue(Self.key(s.env) as CFString, nil, domain as CFString) }
        CFPreferencesAppSynchronize(domain as CFString)
    }

    /// Whether any setting has a saved choice (the Reset button shows).
    func hasChoices(_ settings: [LaunchSetting]) -> Bool { settings.contains { $0.storeBacked && raw($0.env) != nil } }

    /// The one-time move of the options an earlier launcher kept in the library file: a valid choice that differs from the default
    /// goes to the domain where it has no value yet. Returns the variables that are the store's now (to drop from the library).
    @discardableResult
    func migrate(_ legacy: [String: String], settings: [LaunchSetting]) -> Set<String> {
        var moved = Set<String>()
        for s in settings where s.storeBacked {
            guard let v = legacy[s.env] else { continue }
            moved.insert(s.env)
            if raw(s.env) == nil, s.accepts(v), !s.isDefault(v) { set(s, v) }
        }
        return moved
    }
}

/// launcher.json as a reader sees it: the schema version and the rows it can draw.
struct LaunchList {
    var schema: Int
    var settings: [LaunchSetting]
    /// The newest schema this launcher knows. A newer major version is read as far as it can be (rows of a kind it does not know are
    /// left out) and noted in the log, never refused: schema 1 only grows by optional fields, and a later schema's rows that still
    /// have a known kind are drawn the same way.
    static let knownSchema = 1
    static let kinds: Set<String> = ["choice", "range", "toggle"]

    private struct Lossy: Decodable {
        let row: LaunchSetting?
        init(from decoder: Decoder) throws { row = try? LaunchSetting(from: decoder) }
    }
    private struct File: Decodable {
        let schema: Int?
        let settings: [Lossy]
    }

    static func parse(_ data: Data, log: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }) -> LaunchList? {
        guard let file = try? JSONDecoder().decode(File.self, from: data) else { return nil }
        let schema = file.schema ?? 1   // a list written before the field existed is 1
        if schema > knownSchema { log("launcher.json is schema \(schema); this launcher knows \(knownSchema): drawing the rows it understands") }
        let rows = file.settings.compactMap(\.row).filter { kinds.contains($0.kind) }
        return LaunchList(schema: schema, settings: rows)
    }
}

extension LaunchSetting {
    /// Sections this launcher has names for; any other is drawn after them, in the order of its first row.
    static let knownSections = ["Game", "Controls", "Performance"]

    /// The sections of `rows` in the order to draw: the known ones in the order of their first rows, then the unknown ones in list order.
    static func orderedSections(_ rows: [LaunchSetting]) -> [String] {
        let all = rows.reduce(into: [String]()) { if !$0.contains($1.sectionTitle) { $0.append($1.sectionTitle) } }
        return all.filter { knownSections.contains($0) } + all.filter { !knownSections.contains($0) }
    }

    /// `needs` (`<VAR>=<value>`): a sub-setting, drawn only while the row that sets <VAR> has that value. A row naming a variable the
    /// list does not have, or a needs it cannot parse, stays drawn.
    func isShown(in list: [LaunchSetting], value: (LaunchSetting) -> String) -> Bool {
        guard let needs, let eq = needs.firstIndex(of: "=") else { return true }
        let variable = String(needs[..<eq]), wanted = String(needs[needs.index(after: eq)...])
        guard let parent = list.first(where: { $0.env == variable }) else { return true }
        return value(parent) == wanted
    }
}

extension SavedChoices {
    /// Whether the app's launcher reads the store itself. seedds/nxnative's pack_app.py writes `DMSettings` (the rules launcher.c checks
    /// a saved choice against) into Info.plist only together with that reading (#431), so its presence means "the store applies" and an
    /// app without it has an older launcher.c that ignores the preferences domain. Those apps are given the choices in the environment.
    static func appReadsStore(app: String) -> Bool {
        let plist = URL(fileURLWithPath: app).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return false }
        return info["DMSettings"] is [Any]
    }
}

extension LibraryGame {
    /// The environment a Mac game is started with: launch overrides, never written to the store. The rows of launcher.json are saved
    /// choices; an app whose launcher reads the store (`appReadsStore`) gets none of them here, since a value in the environment would
    /// override a choice made elsewhere. An older app does not read it, so it is given the saved non-default choices as variables, as
    /// this launcher always did. The rest is the Controls page's layout, what only this launcher has (Display mode), the mods, and
    /// DM_LAUNCHER=0 (this launcher is the settings window, so the app's own is skipped; saved choices still apply).
    func startEnvironment(controls: [String: String], settings: [LaunchSetting], mods: [GameMod],
                          store: SavedChoices? = nil, appReadsStore: Bool = true) -> [String: String] {
        var environment = controls
        if !appReadsStore, let store {
            for s in settings where s.storeBacked {
                if let v = store.value(s), !s.isDefault(v) { environment[s.env] = v }
            }
        }
        environment.merge(launchEnvironment(settings)) { _, own in own }
        environment.merge(modEnvironment(mods)) { _, mods in mods }
        environment["DM_LAUNCHER"] = "0"
        return environment
    }
}
