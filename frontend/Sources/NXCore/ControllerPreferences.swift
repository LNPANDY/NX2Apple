import Foundation

/// The game's preferences domain, shared with the native controller panel.
package protocol ControllerPreferenceStorage {
    func read(_ key: String) -> Any?
    func write(_ key: String, value: Any?)
    func synchronize() -> Bool
}

package final class SystemControllerPreferences: ControllerPreferenceStorage {
    private let domain: CFString
    package init(domain: String) { self.domain = domain as CFString }
    package func read(_ key: String) -> Any? { CFPreferencesCopyAppValue(key as CFString, domain) }
    package func write(_ key: String, value: Any?) { CFPreferencesSetAppValue(key as CFString, value as CFPropertyList?, domain) }
    package func synchronize() -> Bool { CFPreferencesAppSynchronize(domain) }
}

package struct SteamControllerMapping: Equatable {
    package private(set) var buttons: [Int: Int] = [:]
    package private(set) var pads = [1, 4]
    package private(set) var gyro = true

    package init(raw: Any?) {
        guard let raw = raw as? [String: Any] else { return }
        if let buttons = raw["buttons"] as? [String: Any] {
            for id in 16...23 {
                if let n = Self.integer(buttons[String(id)]), Self.target(n), n != -1 { self.buttons[id] = n }
            }
        }
        if let pads = raw["pads"] as? [Any], pads.count == 2 {
            for i in 0...1 { if let n = Self.integer(pads[i]), (0...4).contains(n) { self.pads[i] = n } }
        }
        if let n = Self.integer(raw["gyro"]), n == 0 || n == 1 { gyro = n == 1 }
    }

    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        let n = number.doubleValue
        guard n.isFinite, n >= Double(Int32.min), n <= Double(Int32.max), n.rounded() == n else { return nil }
        return Int(n)
    }
    static func target(_ n: Int) -> Bool { n == -1 || (0...15).contains(n) || n == 63 }
}

package final class ControllerPreferences {
    package static let steamKey = "controller.Valve Triton"
    package static let importedKey = "nx2apple.controllerMappingsImported"
    private let storage: ControllerPreferenceStorage
    package init(storage: ControllerPreferenceStorage) { self.storage = storage }
    package var steam: SteamControllerMapping { SteamControllerMapping(raw: storage.read(Self.steamKey)) }
    package func map(_ env: String) -> String? {
        guard let value = storage.read("launcher." + env) as? String, ControllerMap.valid(value, pad: env == "DM_PAD_MAP") else { return nil }
        return value
    }
    @discardableResult package func refresh() -> Bool { storage.synchronize() }

    /// Import only once, including an unchanged global layout. A reset by the game must stay reset.
    package func launchControls(_ controls: [String: String], savingEnabled: Bool = true) -> [String: String] {
        guard savingEnabled, controls["DM_SAVED_CHOICES"] != "0" else { return controls }
        _ = storage.synchronize()
        if storage.read(Self.importedKey) == nil {
            for env in ["DM_KEYMAP", "DM_PAD_MAP"] where storage.read("launcher." + env) == nil {
                if let value = controls[env], ControllerMap.valid(value, pad: env == "DM_PAD_MAP") {
                    storage.write("launcher." + env, value: value)
                }
            }
            storage.write(Self.importedKey, value: true)
            // On failure keep the environment for this launch. A subsequent refresh can retry persistence.
            if !storage.synchronize() {
                storage.write(Self.importedKey, value: nil)
                FileHandle.standardError.write(Data("Controller mappings could not be saved. Using the global layout for this launch.\n".utf8))
                return controls
            }
        }
        return controls.filter { $0.key != "DM_KEYMAP" && $0.key != "DM_PAD_MAP" }
    }

    @discardableResult package func setMap(_ env: String, value: String?) -> Bool {
        guard ["DM_KEYMAP", "DM_PAD_MAP"].contains(env) else { return false }
        if let value, !ControllerMap.valid(value, pad: env == "DM_PAD_MAP") { return false }
        storage.write("launcher." + env, value: value)
        return storage.synchronize()
    }

    @discardableResult package func setSteamPad(_ index: Int, mode: Int) -> Bool {
        guard (0...1).contains(index), (0...4).contains(mode) else { return false }
        return editSteam { raw in
            var pads = SteamControllerMapping(raw: raw).pads
            pads[index] = mode
            raw["pads"] = pads == [1, 4] ? nil : pads
        }
    }
    @discardableResult package func setSteamGyro(_ enabled: Bool) -> Bool {
        editSteam { $0["gyro"] = enabled ? nil : false }
    }
    @discardableResult package func setSteamButton(_ id: Int, target: Int) -> Bool {
        guard (16...23).contains(id), SteamControllerMapping.target(target) else { return false }
        return editSteam { raw in
            var buttons = raw["buttons"] as? [String: Any] ?? [:]
            buttons[String(id)] = target == -1 ? nil : target
            raw["buttons"] = buttons.isEmpty ? nil : buttons
        }
    }
    @discardableResult package func resetSteam() -> Bool {
        editSteam { raw in
            var buttons = raw["buttons"] as? [String: Any] ?? [:]
            for id in 16...23 { buttons[String(id)] = nil }
            raw["buttons"] = buttons.isEmpty ? nil : buttons
            raw["pads"] = nil
            raw["gyro"] = nil
        }
    }
    private func editSteam(_ edit: (inout [String: Any]) -> Void) -> Bool {
        _ = storage.synchronize()
        var raw = storage.read(Self.steamKey) as? [String: Any] ?? [:]
        edit(&raw)
        let mapping = SteamControllerMapping(raw: raw)
        var buttons = raw["buttons"] as? [String: Any] ?? [:]
        for id in 0...15 { buttons[String(id)] = nil }
        for id in 16...23 { buttons[String(id)] = mapping.buttons[id] }
        raw["buttons"] = buttons.isEmpty ? nil : buttons
        raw["pads"] = mapping.pads == [1, 4] ? nil : mapping.pads
        raw["gyro"] = mapping.gyro ? nil : false
        storage.write(Self.steamKey, value: raw.isEmpty ? nil : raw)
        return storage.synchronize()
    }
}
