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

    public func section(global: PadMap) -> SettingSection {
        func follow(_ label: String) -> SettingOption { SettingOption("follow", hostText("Follow global (\(label))")) }
        let on = hostText("On"), off = hostText("Off")
        var swapOptions = [follow(global.swapAB ? on : off), SettingOption("on", on), SettingOption("off", off)]
        // A single-button edit need not be a complete swap or an explicit off. Show that state truthfully.
        if swapValue == "custom" { swapOptions.append(SettingOption("custom", hostText("Custom"))) }
        var rows = [SettingRow(id: "pad.swapAB", label: hostText("Swap A and B"),
                               note: hostText("Only affects physical controllers in games. Shell menus keep A to confirm and B to go back."),
                               kind: .choice(swapOptions), value: swapValue, fromShell: swapValue == "follow")]
        rows += PadMap.buttons.map { button in
            SettingRow(id: "pad.\(button)", label: PadMap.label(button),
                       kind: .choice([follow(PadMap.label(global.output(for: button)))] + PadMap.options),
                       value: entries[button] ?? "follow", fromShell: entries[button] == nil)
        }
        return SettingSection(id: "pad", title: hostText("Controller"), rows: rows)
    }
}
