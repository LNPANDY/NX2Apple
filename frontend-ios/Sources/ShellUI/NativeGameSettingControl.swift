import SwiftUI

/// Native settings for every profile-supplied row. Values and options remain supplied by each game's profile.
struct NativeGameSettingControl: View {
    let row: SettingRow
    let targetPrefix: String
    let change: (String) -> Void

    var body: some View {
        Group {
            switch row.kind {
            case .choice:
                NativeChoiceControl(row: row, menuOnly: row.id == "DM_LANG" || row.id == "DM_LANGUAGE",
                                    inline: true, targetPrefix: targetPrefix, change: change)
            case .toggle(let on, let off):
                Toggle(isOn: Binding(get: { row.value == on }, set: { change($0 ? on : off) })) {
                    label
                }
                .toggleStyle(NativeCreamToggleStyle())
                .shellTarget(targetPrefix + row.id, enabled: row.enabled) { change(row.value == on ? off : on) }
            case .range(let lower, let upper, let step, let unit):
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        label
                        Spacer(minLength: 8)
                        Text((Double(row.value) ?? lower).formatted(.number.precision(.fractionLength(0...2))) + unit)
                            .font(.body.bold()).monospacedDigit().foregroundStyle(ShellPalette.cream)
                    }
                    if lower < upper && step > 0 {
                        Slider(value: Binding(get: { Double(row.value) ?? lower }, set: { change(String($0)) }),
                               in: lower...upper, step: step)
                            .tint(ShellPalette.cream)
                            .accessibilityLabel(row.label)
                            .shellTarget(targetPrefix + row.id, enabled: row.enabled) {
                                let current = Double(row.value) ?? lower
                                change(String(current >= upper ? lower : min(upper, current + step)))
                            }
                    }
                }
            }
        }
        .disabled(!row.enabled)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setting.\(row.id)")
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.label).font(.body)
            if !row.note.isEmpty {
                Text(row.note).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
