import SwiftUI
import NXCore
import NXLauncher

/// One of a game's options in console mode, as one row of a grouped list, the same height for every kind: the title at the left and
/// the value at the right, as a value stepper "‹ 100 % ›" (left and right change it, the chevrons dim at the ends) or a switch for on
/// and off. A thin bar under the value only for a continuous range, filled to where the value sits in it (ConsoleValueBar). A takes
/// the next value. No sliders or segments in the list. A choice with one value shows it without chevrons and takes no change.
struct ConsoleOptionRow: View {
    let setting: LaunchSetting
    let value: String
    /// The value as the row shows it (a percentage for the render scale, the option's name for a choice).
    let label: String
    let compact: Bool
    let lang: Lang
    let scope: String
    /// Kept for the callers: a range no longer needs to be picked with A first.
    let editing: Bool
    let edit: (Bool) -> Void
    /// A step left (-1) or right (+1), and a value set directly.
    let adjust: (Int) -> Void
    let set: (String) -> Void

    var id: String { "console.option." + setting.env }
    private var isOn: Bool { value == setting.onValue }

    private var options: [String] { (setting.options ?? []).compactMap(\.first) }
    /// Whether left (-1) or right (+1) changes the value: a choice stops at its ends, a range at its bounds.
    func canStep(_ by: Int) -> Bool {
        switch setting.kind {
        case "choice":
            guard options.count > 1 else { return false }
            let index = options.firstIndex(of: value) ?? 0
            return options.indices.contains(index + by)
        case "range":
            guard let next = ConsoleOption.stepped(setting, value: value, by: by) else { return false }
            return Double(next) != Double(value) ?? Double(setting.def)
        case "toggle": return true
        default: return false
        }
    }
    private var fixed: Bool { setting.kind == "choice" && options.count <= 1 }
    private func step(_ by: Int) { if canStep(by) { adjust(by) } }
    /// A: a switch flips, a choice takes the next value (round to the first), a range one step up.
    private func activate() {
        if setting.kind == "choice", !fixed, !canStep(1), let first = options.first { set(first) } else { step(1) }
    }

    /// The bar's fill for a continuous range, nil for everything else.
    var fill: Double? {
        guard setting.kind == "range", let lo = setting.min, let hi = setting.max,
              ConsoleValueBar.isContinuous(lo: lo, hi: hi, step: setting.step ?? 0.05) else { return nil }
        return ConsoleValueBar.fillFraction(value: Double(value) ?? Double(setting.def) ?? lo, lo: lo, hi: hi)
    }

    var body: some View {
        ConsoleFocused(id: id) { focused in
            HStack(spacing: DS.Console.Space.m) {
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(setting.label).font(DS.Console.Font.body).foregroundStyle(DS.Color.textPrimary).lineLimit(1).minimumScaleFactor(0.8)
                    if !setting.note.isEmpty {
                        Text(setting.note).font(DS.Console.Font.callout).foregroundStyle(DS.Color.textSecondary).lineLimit(1).truncationMode(.tail)
                    }
                }
                Spacer(minLength: DS.Console.Space.s)
                if setting.kind == "toggle" {
                    ConsoleSwitch(isOn: isOn, compact: false).onTapGesture { adjust(1) }
                } else {
                    ConsoleValueStepper(label: label, canDecrease: canStep(-1), canIncrease: canStep(1), fixed: fixed, fill: fill, step: step)
                }
            }
            .padding(.horizontal, DS.Console.Space.l)
            .frame(maxWidth: .infinity, minHeight: DS.Console.Control.rowHeight, alignment: .leading)
            .background(focused ? DS.Color.surfaceRaised : .clear, in: RoundedRectangle(cornerRadius: DS.Console.Radius.row))
            .contentShape(Rectangle())
        }
        .consoleFocus(id, scope: scope, enabled: !fixed, activate: activate, adjust: step)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(setting.label).accessibilityValue(label)
        .accessibilityHint(L10n.string("console.adjustHint", lang))
        .accessibilityAdjustableAction { direction in step(direction == .increment ? 1 : -1) }
        .accessibilityAction { activate() }
    }
}

/// A switch drawn at the console's size: the accent with the knob at the right when on.
struct ConsoleSwitch: View {
    let isOn: Bool
    let compact: Bool
    var body: some View {
        let width: CGFloat = compact ? 48 : 56, height: CGFloat = compact ? 28 : 32
        ZStack(alignment: isOn ? .trailing : .leading) {
            // Solid colours and no shadow: no dark rim around the knob or the track in either state.
            Capsule().fill(isOn ? DS.Color.accent : DS.Color.textTertiary)
            Circle().fill(isOn ? DS.Color.accentOn : DS.Color.textPrimary).padding(3)
        }
        .frame(width: width, height: height)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isOn)
        .accessibilityHidden(true)
    }
}
