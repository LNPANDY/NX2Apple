import Foundation

/// Physical controller buttons in the engine's input_map.h order. Sticks and shell navigation are unaffected.
public struct PadMap: Equatable, Sendable {
    public static let buttons = ["A", "B", "X", "Y", "LS", "RS", "L", "R", "ZL", "ZR", "Plus", "Minus", "Left", "Up", "Right", "Down"]
    public private(set) var entries: [String: String]

    public init(_ entries: [String: String] = [:]) {
        self.entries = Self.validated(entries).filter { $0.key != $0.value }
    }

    /// Game overrides keep identities, since A=A must be able to override a global A=B.
    public static func validated(_ entries: [String: String]) -> [String: String] {
        entries.filter { buttons.contains($0.key) && (buttons.contains($0.value) || $0.value == "none") }
    }

    public func output(for button: String) -> String { entries[button] ?? button }
    public var swapAB: Bool { output(for: "A") == "B" && output(for: "B") == "A" }
    public var envValue: String? {
        let pairs = Self.buttons.compactMap { key in entries[key].map { "\(key)=\($0)" } }
        return pairs.isEmpty ? nil : pairs.joined(separator: ",")
    }
    public mutating func set(_ button: String, to output: String) {
        guard Self.validated([button: output])[button] != nil else { return }
        entries[button] = output == button ? nil : output
    }
    public mutating func setSwapAB(_ on: Bool) {
        set("A", to: on ? "B" : "A")
        set("B", to: on ? "A" : "B")
    }
    public static func merged(global: PadMap, game: [String: String]) -> PadMap {
        PadMap(global.entries.merging(validated(game)) { _, game in game })
    }

    /// Nintendo names presented to the player, localized in ShellUI for both mapping pages.
    public static func label(_ button: String) -> String {
        switch button {
        case "Plus": "+"
        case "Minus": "−"
        case "LS": ShellStrings.text("Left stick press")
        case "RS": ShellStrings.text("Right stick press")
        case "Left": ShellStrings.text("D-pad left")
        case "Up": ShellStrings.text("D-pad up")
        case "Right": ShellStrings.text("D-pad right")
        case "Down": ShellStrings.text("D-pad down")
        case "none": ShellStrings.text("None")
        default: button
        }
    }
    public static var options: [SettingOption] { (buttons + ["none"]).map { SettingOption($0, label($0)) } }
}
