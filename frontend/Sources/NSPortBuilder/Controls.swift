import AppKit
import SwiftUI

/// The player's keyboard and controller layout for every game, passed at Play as the host's DM_KEYMAP and DM_PAD_MAP
/// (dm/host/input_map.h). Only what differs from the host's defaults is kept and passed, so a build whose host does not
/// read the two variables plays as before, and an unchanged layout passes nothing.
final class ControlLayout: ObservableObject {
    /// A function the keyboard can hold, named as the host names it (DM_KEYS's names).
    struct Function: Identifiable {
        let id: String
        let defaultKey: Int?   // macOS virtual key code; the right stick has none
        /// The sheet's two keyboard cards: the sticks and the D-pad, then the buttons and Shake.
        var isDirection: Bool { ControlLayout.directions.contains(id) }
    }

    /// The host's default keys (input_map.h key_map_default), in the order the Controls sheet lists them.
    static let functions: [Function] = [
        .init(id: "LUp", defaultKey: 13), .init(id: "LDown", defaultKey: 1), .init(id: "LLeft", defaultKey: 0), .init(id: "LRight", defaultKey: 2),
        .init(id: "RUp", defaultKey: nil), .init(id: "RDown", defaultKey: nil), .init(id: "RLeft", defaultKey: nil), .init(id: "RRight", defaultKey: nil),
        .init(id: "Up", defaultKey: 126), .init(id: "Down", defaultKey: 125), .init(id: "Left", defaultKey: 123), .init(id: "Right", defaultKey: 124),
        .init(id: "A", defaultKey: 38), .init(id: "B", defaultKey: 40), .init(id: "X", defaultKey: 32), .init(id: "Y", defaultKey: 34),
        .init(id: "L", defaultKey: 12), .init(id: "R", defaultKey: 14), .init(id: "ZL", defaultKey: 6), .init(id: "ZR", defaultKey: 8),
        .init(id: "Plus", defaultKey: 36), .init(id: "Minus", defaultKey: 48), .init(id: "LS", defaultKey: 3), .init(id: "RS", defaultKey: 5),
        .init(id: "Shake", defaultKey: 49),
    ]
    static let directions: Set = ["LUp", "LDown", "LLeft", "LRight", "RUp", "RDown", "RLeft", "RRight", "Up", "Down", "Left", "Right"]
    /// The 16 buttons a controller's buttons can send (DM_PAD_MAP), in the sheet's order.
    static let buttons = ["A", "B", "X", "Y", "L", "R", "ZL", "ZR", "Plus", "Minus", "LS", "RS", "Up", "Down", "Left", "Right"]

    /// Function → key code, nil for no key; only functions moved from their default key.
    @Published private(set) var keys: [String: Int?] = [:]
    /// Button → the button it sends, "none" for nothing; only buttons that send another. The Custom layout's.
    @Published private(set) var pad: [String: String] = [:]
    /// The controller's layout (ControlPresets.swift): Standard, By label, Auto between the two, or Custom (`pad`).
    @Published private(set) var padMode: PadMode = .standard
    /// The connected controller's GCController.productCategory, which Auto goes by; tests stand in for it.
    var controllerCategory: () -> String? = ControlLayout.connectedCategory
    /// "All controllers are player 1" (launcher setting, off by default): passed at Play as DM_PAD_MERGE=1. It is not a layout
    /// change, so it stays out of `isDefault`, `changeCount` and the Controls sheet's reset.
    @Published var padMerge: Bool { didSet { defaults.set(padMerge, forKey: Self.padMergeKey) } }
    static let padMergeKey = "padMerge"
    private let defaults: UserDefaults
    /// A key code, -1 for no key. `mode` is nil in settings saved before the layouts, which had only the custom buttons.
    private struct Saved: Codable { var keys: [String: Int]; var pad: [String: String]; var mode: String? }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        padMerge = defaults.bool(forKey: Self.padMergeKey)
        if let data = defaults.data(forKey: "controlLayout"), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            keys = saved.keys.filter { k, code in Self.functions.contains { $0.id == k } && code < 128 }.mapValues { $0 < 0 ? nil : $0 }
            pad = saved.pad.filter { b, to in Self.buttons.contains(b) && (to == "none" || Self.buttons.contains(to)) }
            padMode = saved.mode.flatMap(PadMode.init(rawValue:)) ?? (pad.isEmpty ? .standard : .custom)
        }
    }

    var isDefault: Bool { keys.isEmpty && padChanges == 0 }
    var changeCount: Int { keys.count + padChanges }
    /// A preset counts as one change; Custom as its buttons.
    private var padChanges: Int {
        switch padMode {
        case .standard: return 0
        case .custom: return pad.count
        case .byLabel, .auto: return 1
        }
    }

    /// The key a function is on now.
    func key(_ f: Function) -> Int? { keys[f.id] ?? f.defaultKey }

    /// Puts a function on a key, or on none. One key holds one function, as in the host: the function the key held
    /// before is left on no key.
    func assign(_ f: Function, key: Int?) {
        var next = keys
        if let key { for g in Self.functions where g.id != f.id && self.key(g) == key { next[g.id] = .some(nil) } }
        next[f.id] = key == f.defaultKey ? nil : .some(key)
        for g in Self.functions where next[g.id] != nil && next[g.id]! == g.defaultKey { next[g.id] = nil }
        keys = next
        save()
    }

    /// What a button sends in the layout chosen (for Auto, the one it picks for the controller connected now).
    func sends(_ button: String) -> String { activePad[button] ?? button }

    /// A button changed by hand makes the layout Custom, starting from what the buttons sent until then.
    func setSends(_ button: String, _ to: String) {
        if padMode != .custom { pad = activePad; padMode = .custom }
        pad[button] = to == button ? nil : to
        save()
    }

    func setPadMode(_ mode: PadMode) { padMode = mode; save() }

    private var activePad: [String: String] { padMap(for: padMode, category: padMode == .auto ? controllerCategory() : nil) }

    func resetKeyboard() { keys = [:]; save() }
    func resetController() { pad = [:]; padMode = .standard; save() }

    /// DM_KEYMAP and DM_PAD_MAP for the changes, in the sheet's order, and DM_PAD_MERGE=1 when merging is on; empty when nothing changed.
    var environment: [String: String] {
        var env: [String: String] = [:]
        if padMerge { env["DM_PAD_MERGE"] = "1" }
        let k = Self.functions.compactMap { f in keys[f.id].map { "\(f.id)=\($0.map(String.init) ?? "none")" } }
        if !k.isEmpty { env["DM_KEYMAP"] = k.joined(separator: ",") }
        let active = activePad
        let p = Self.buttons.compactMap { b in active[b].map { "\(b)=\($0)" } }
        if !p.isEmpty { env["DM_PAD_MAP"] = p.joined(separator: ",") }
        return env
    }

    private func save() {
        if let data = try? JSONEncoder().encode(Saved(keys: keys.mapValues { $0 ?? -1 }, pad: pad, mode: padMode.rawValue)) { defaults.set(data, forKey: "controlLayout") }
    }

    /// A key's name on a US keyboard, by virtual key code (the host reads codes, so the name is only for the label).
    static func keyName(_ code: Int?) -> String? {
        guard let code else { return nil }
        let names: [Int: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "Return", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\",
            43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "Tab", 49: "Space", 50: "`", 51: "Delete", 65: "Keypad .", 67: "Keypad *",
            69: "Keypad +", 71: "Clear", 75: "Keypad /", 76: "Enter", 78: "Keypad -", 81: "Keypad =", 82: "Keypad 0", 83: "Keypad 1",
            84: "Keypad 2", 85: "Keypad 3", 86: "Keypad 4", 87: "Keypad 5", 88: "Keypad 6", 89: "Keypad 7", 91: "Keypad 8", 92: "Keypad 9",
            96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11", 105: "F13", 107: "F14", 109: "F10", 111: "F12",
            113: "F15", 115: "Home", 116: "Page Up", 117: "Forward Delete", 118: "F4", 119: "End", 120: "F2", 121: "Page Down", 122: "F1",
            123: "←", 124: "→", 125: "↓", 126: "↑",
        ]
        return names[code] ?? "Key \(code)"
    }
}

/// The Controls sheet: the keyboard's key for each function (click, then press a key) and what each controller button sends.
struct ControlsView: View {
    @ObservedObject var m: BuildModel
    @ObservedObject var layout: ControlLayout
    @Environment(\.dismiss) private var dismiss
    @State private var listening: String?
    @State private var monitor: Any?
    @EnvironmentObject private var focus: PadFocus

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(m.t("controls.title")).font(.manrope(26, .heavy)).tracking(-0.6)
                Text(m.t("controls.note")).font(.manrope(14)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 30).padding(.top, 28).padding(.bottom, 20)
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    section(m.t("controls.sticks"), ControlLayout.functions.filter(\.isDirection)) { keyRow($0) }
                    section(m.t("controls.keyButtons"), ControlLayout.functions.filter { !$0.isDirection }) { keyRow($0) }
                    PadModeSection(m: m, layout: layout)
                    section(m.t("controls.pad"), ControlLayout.buttons, note: m.t("controls.padNote")) { padRow($0) }
                }
                .padding(.horizontal, 30).padding(.bottom, 24)
            }
            .onChange(of: focus.focused) { id in if let id { withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) } } }
            }
            Divider().opacity(0.3)
            HStack(spacing: 14) {
                Text(m.t("controls.applied")).font(.manrope(12)).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 8)
                if !layout.isDefault {
                    Button(m.t("controls.reset")) { stopListening(); layout.resetKeyboard(); layout.resetController() }
                        .buttonStyle(LauncherSecondaryButtonStyle())
                        .padTarget("controls.reset", scope: "controls") { stopListening(); layout.resetKeyboard(); layout.resetController() }
                }
                Button { stopListening(); dismiss() } label: {
                    Text(m.t("launch.done")).font(.manrope(13.5, .bold)).foregroundStyle(.black)
                        .padding(.horizontal, 22).padding(.vertical, 9)
                        .background(LauncherPalette.cream, in: Capsule())
                }
                .buttonStyle(.plain).keyboardShortcut(listening == nil ? .defaultAction : nil)
                .padTarget("controls.done", scope: "controls", radius: 20) { stopListening(); dismiss() }
            }
            .padding(.horizontal, 30).padding(.vertical, 16)
        }
        .padScope("controls", focus)
        .frame(width: 600, height: 700)
        .background(LauncherPalette.background)
        .font(.manrope(13))
        .preferredColorScheme(.dark)
        .tint(LauncherPalette.cream)
        .onDisappear { stopListening() }
    }

    private func section<Item, Row: View>(_ title: String, _ items: [Item], note: String = "", @ViewBuilder row: @escaping (Item) -> Row) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.manrope(15, .semibold)).foregroundStyle(.secondary).padding(.leading, 2)
            VStack(spacing: 0) {
                ForEach(items.indices, id: \.self) { i in
                    row(items[i])
                    if i < items.count - 1 { Divider().opacity(0.25).padding(.leading, 18) }
                }
            }
            .background(LauncherPalette.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.06)))
            if !note.isEmpty {
                Text(note).font(.manrope(12)).foregroundStyle(.secondary).padding(.leading, 2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func line<Trailing: View>(_ title: String, target: String, activate: (() -> Void)? = nil, adjust: ((Int) -> Void)? = nil,
                                      @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 16) {
            Text(title).font(.manrope(14, .medium))
            Spacer(minLength: 12)
            trailing().frame(width: LaunchControl.width, alignment: .trailing)
        }
        .padding(.horizontal, 18).padding(.vertical, 9)
        .frame(minHeight: 46)
        .padTarget(target, scope: "controls", radius: 10, activate: activate, adjust: adjust)
    }

    private func keyRow(_ f: ControlLayout.Function) -> some View {
        let on = listening == f.id
        let key = layout.key(f)
        return line(m.t("controls.fn." + f.id), target: "key." + f.id, activate: { on ? stopListening() : listen(f) }) {
            HStack(spacing: 6) {
                if key != nil && !on {
                    Button { layout.assign(f, key: nil) } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                            .frame(width: 22, height: 22).contentShape(Circle())
                    }
                    .buttonStyle(.plain).help(m.t("controls.clear"))
                }
                Button { on ? stopListening() : listen(f) } label: {
                    Text(on ? m.t("controls.press") : ControlLayout.keyName(key) ?? m.t("controls.none"))
                        .font(.manrope(12.5, on ? .bold : .semibold))
                        .foregroundStyle(on ? Color.black : key == nil ? Color.white.opacity(0.45) : Color.white.opacity(0.92))
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                        .background(on ? LauncherPalette.cream : Color.white.opacity(0.06), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.white.opacity(on ? 0 : 0.10)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .frame(width: 140)
            }
        }
    }

    private func padRow(_ button: String) -> some View {
        let choices = ControlLayout.buttons + ["none"]
        return line(m.t("controls.fn." + button), target: "pad." + button,
                    adjust: { by in
                        let at = choices.firstIndex(of: layout.sends(button)) ?? 0
                        layout.setSends(button, choices[(at + by + choices.count) % choices.count])
                    }) {
            LauncherMenuPicker(options: ControlLayout.buttons.map { (value: $0, label: m.t("controls.fn." + $0)) } + [(value: "none", label: m.t("controls.none"))],
                               selection: layout.sends(button), fill: true) { layout.setSends(button, $0) }
                .frame(width: 168)   // the keyboard rows' width (× and key field), and "Right stick press" fits
        }
    }

    /// The next key pressed goes to the function; Esc leaves it as it was. Keys with ⌘ stay with the menu, as in the game.
    private func listen(_ f: ControlLayout.Function) {
        stopListening()
        listening = f.id
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.modifierFlags.contains(.command) { return e }
            if e.keyCode != 53 { layout.assign(f, key: Int(e.keyCode)) }
            stopListening()
            return nil
        }
    }

    private func stopListening() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        listening = nil
    }
}
