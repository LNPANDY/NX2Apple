import Foundation
import ShellUI

/// Sparse overrides in the game's own suite. An absent button follows global, an identity explicitly restores default.
public struct GamePadMapStore {
    public let defaults: UserDefaults
    public init(defaults: UserDefaults) { self.defaults = defaults }
    public var entries: [String: String] {
        PadMap.validated(defaults.dictionary(forKey: GameDefaults.padMapKey) as? [String: String] ?? [:])
    }
    public var swapValue: String {
        let map = entries
        if map["A"] == nil && map["B"] == nil { return "follow" }
        if map["A"] == "B" && map["B"] == "A" { return "on" }
        if map["A"] == "A" && map["B"] == "B" { return "off" }
        return "custom"
    }
    public func change(_ setting: String, value: String) {
        if setting == PadMappingRows.resetID { reset(); return }
        var map = entries
        if setting == "pad.swapAB" {
            switch value {
            case "follow": map["A"] = nil; map["B"] = nil
            case "on": map["A"] = "B"; map["B"] = "A"
            case "off": map["A"] = "A"; map["B"] = "B"
            default: return
            }
        } else {
            guard setting.hasPrefix("pad.") else { return }
            let button = String(setting.dropFirst(4))
            guard PadMap.buttons.contains(button) else { return }
            if value == "follow" { map[button] = nil }
            else if PadMap.validated([button: value])[button] != nil { map[button] = value }
            else { return }
        }
        if map.isEmpty { reset() } else { defaults.set(map, forKey: GameDefaults.padMapKey) }
    }
    public func reset() { defaults.removeObject(forKey: GameDefaults.padMapKey) }

    /// The rows of the game's mapping card. A row that follows the shell's map holds "follow". The swap holds "custom" while
    /// A and B are changed to something that is neither the swap nor explicitly off: no segment is chosen then.
    public func section() -> SettingSection {
        let follow = SettingOption("follow", hostText("Default"))
        let rows = [SettingRow(id: "pad.swapAB", label: hostText("Swap A and B"),
                               kind: .choice([follow, SettingOption("on", hostText("On")), SettingOption("off", hostText("Off"))]),
                               value: swapValue, fromShell: swapValue == "follow")]
            + PadMap.buttons.map { button in
                SettingRow(id: "pad.\(button)", label: PadMap.label(button), kind: .choice([follow] + PadMap.options),
                           value: entries[button] ?? "follow", fromShell: entries[button] == nil)
            }
        return SettingSection(id: "pad", title: hostText("Controller"), rows: rows)
    }
}
