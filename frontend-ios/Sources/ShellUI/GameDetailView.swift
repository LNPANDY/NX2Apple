import SwiftUI

/// One game's settings: what it is and its state, then the setting groups, game data, cloud saves and the reset.
/// The library supplies the scrolling container. Values come in through `detail` and leave through `actions`.
public struct GameDetailView: View {
    public let detail: GameDetail
    public var actions: ShellActions
    /// Off where the screen shows the primary action already, as beside the library's hero.
    public var showsPrimaryAction: Bool
    /// Off where the game's cover and title are already in view, as beside the library's hero.
    public var showsHeader: Bool
    public init(detail: GameDetail, actions: ShellActions = ShellActions(), showsPrimaryAction: Bool = true, showsHeader: Bool = true) {
        self.detail = detail
        self.actions = actions
        self.showsPrimaryAction = showsPrimaryAction
        self.showsHeader = showsHeader
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            if showsHeader { header }
            ForEach(detail.sections) { section in
                group(section.title) {
                    ForEach(section.rows) { row in
                        SettingControl(row: row) { actions.onChange(detail.id, row.id, $0) }
                        if row.id != section.rows.last?.id { divider }
                    }
                }
            }
            group(ShellStrings.text("Game data")) {
                SourceRow(symbol: "folder",
                          title: detail.dataSource.isEmpty ? ShellStrings.text("No data selected") : detail.dataSource,
                          note: detail.dataNote) {
                    Button(ShellStrings.text("Choose…")) { actions.onPickGameData(detail.id) }
                        .buttonStyle(ShellButtonStyle()).accessibilityLabel(ShellStrings.text("Choose game data…"))
                        .shellTarget("set.data") { actions.onPickGameData(detail.id) }
                    if !detail.dataSource.isEmpty {
                        Button(ShellStrings.text("Use app data")) { actions.onUseAppData(detail.id) }
                            .buttonStyle(ShellButtonStyle()).shellTarget("set.appdata") { actions.onUseAppData(detail.id) }
                    }
                }
                divider
                Label(detail.dlc.isEmpty ? ShellStrings.text("No additional content") : detail.dlc, systemImage: "square.stack.3d.up")
                    .shellText(14).foregroundStyle(.white.opacity(0.72)).frame(minHeight: 32)
            }
            group(ShellStrings.text("Cloud saves")) {
                SourceRow(symbol: detail.cloudSaves == nil ? "icloud.slash" : "icloud",
                          title: detail.cloudSaves ?? ShellStrings.text("Off"),
                          note: detail.cloudNote.isEmpty ? ShellStrings.text("Choose the same iCloud Drive folder you use on your Mac.") : detail.cloudNote) {
                    Button(ShellStrings.text("Choose folder…")) { actions.onPickCloudSaves(detail.id) }
                        .buttonStyle(ShellButtonStyle()).shellTarget("set.cloud") { actions.onPickCloudSaves(detail.id) }
                    if detail.cloudSaves != nil {
                        Button(ShellStrings.text("Turn off")) { actions.onDisableCloudSaves(detail.id) }
                            .buttonStyle(ShellButtonStyle()).accessibilityLabel(ShellStrings.text("Turn off cloud saves"))
                            .shellTarget("set.cloud.off") { actions.onDisableCloudSaves(detail.id) }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Button(ShellStrings.text("Reset to tested defaults")) { actions.onResetDefaults(detail.id) }
                    .buttonStyle(ShellButtonStyle())
                    .disabled(!detail.hasModifiedSettings)
                    .shellTarget("set.reset", enabled: detail.hasModifiedSettings) { actions.onResetDefaults(detail.id) }
                Text(ShellStrings.text("Brings back the settings this game was tested with."))
                    .shellText(12.5).foregroundStyle(.white.opacity(0.45)).fixedSize(horizontal: false, vertical: true)
            }
        }.foregroundStyle(.white)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                CoverView(game: detail.game, radius: 10).frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 6) {
                    Text(detail.game.title).shellText(24, .heavy, relativeTo: .title).tracking(-0.6)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader).accessibilityIdentifier("detail.title")
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { status }
                        VStack(alignment: .leading, spacing: 4) { status }
                    }
                }
            }
            if showsPrimaryAction {
                if !detail.game.state.explanation.isEmpty {
                    Text(detail.game.state.explanation).shellText(14).foregroundStyle(.white.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                }
                GameStateView(game: detail.game, actions: actions, showsExplanation: false)
            }
        }
    }

    @ViewBuilder private var status: some View {
        StatusLabel(state: detail.game.state).fixedSize()
        if !detail.game.subtitle.isEmpty {
            Text(detail.game.subtitle).shellText(12.5).foregroundStyle(.white.opacity(0.45)).fixedSize()
        }
    }

    private var divider: some View { Rectangle().fill(.white.opacity(0.06)).frame(height: 1) }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(title: title).padding(.leading, 4)
            VStack(alignment: .leading, spacing: 14) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .shellCard()
        }
    }
}

/// Where something comes from (game data, a cloud folder) and the buttons that change it.
private struct SourceRow<Buttons: View>: View {
    let symbol: String
    let title: String
    let note: String
    @ViewBuilder let buttons: () -> Buttons
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: symbol).foregroundStyle(ShellPalette.cream.opacity(0.8)).frame(width: 20).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).shellText(15, .semibold).fixedSize(horizontal: false, vertical: true)
                    if !note.isEmpty {
                        Text(note).shellText(12.5).foregroundStyle(.white.opacity(0.5)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { buttons() }
                VStack(alignment: .leading, spacing: 10) { buttons() }
            }.padding(.leading, 32)
        }
    }
}

private struct SettingControl: View {
    let row: SettingRow
    let change: (String) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch row.kind {
            case .toggle(let on, let off):
                Toggle(isOn: Binding(get: { row.value == on }, set: { change($0 ? on : off) })) { label }
                    .toggleStyle(CreamToggleStyle())
                    .shellTarget("set.row.\(row.id)", enabled: row.enabled) { change(row.value == on ? off : on) }
            case .choice(let options):
                label
                if options.count <= 3 && !typeSize.isAccessibilitySize {
                    ViewThatFits(in: .horizontal) {
                        segmented(options)
                        list(options)
                    }
                } else {
                    list(options)
                }
            case .range(let min, let max, let step, let unit):
                HStack(alignment: .firstTextBaseline) {
                    label
                    Spacer(minLength: 8)
                    Text((Double(row.value) ?? min).formatted(.number.precision(.fractionLength(0...2))) + unit)
                        .shellText(15, .bold).monospacedDigit().foregroundStyle(ShellPalette.cream)
                }
                HStack(spacing: 10) {
                    rangeButton("minus", min: min, max: max, delta: -step)
                    if min < max && step > 0 {
                        Slider(value: Binding(get: { Double(row.value) ?? min }, set: { change(String($0)) }), in: min...max, step: step)
                            .frame(minHeight: 44).tint(ShellPalette.cream).accessibilityLabel(row.label)
                    }
                    rangeButton("plus", min: min, max: max, delta: step)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .disabled(!row.enabled).opacity(row.enabled ? 1 : 0.45)
            .accessibilityIdentifier("setting.\(row.id)")
    }
    private var label: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.label).shellText(15, .semibold).fixedSize(horizontal: false, vertical: true)
            if !row.note.isEmpty { Text(row.note).shellText(12.5).foregroundStyle(.white.opacity(0.5)).fixedSize(horizontal: false, vertical: true) }
        }
    }
    /// The Mac's segmented choice: a dim track, the chosen value in cream.
    private func segmented(_ options: [SettingOption]) -> some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let chosen = row.value == option.id
                Button { change(option.id) } label: {
                    Text(option.label).shellText(13.5, chosen ? .bold : .medium).lineLimit(1)
                        .padding(.horizontal, 16).frame(minHeight: 40)
                        .foregroundStyle(chosen ? .black : .white.opacity(0.75))
                        .background(chosen ? ShellPalette.cream : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain).fixedSize()
                .accessibilityLabel(row.label + ", " + option.label)
                .accessibilityAddTraits(chosen ? .isSelected : [])
                .shellTarget("set.row.\(row.id).\(option.id)", enabled: row.enabled, radius: 8) { change(option.id) }
            }
        }
        .padding(3)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(.white.opacity(0.08)))
    }
    private func list(_ options: [SettingOption]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(options) { option in
                let chosen = row.value == option.id
                Button { change(option.id) } label: {
                    HStack {
                        Text(option.label).shellText(14, chosen ? .bold : .medium)
                        Spacer()
                        if chosen { Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)) }
                    }
                    .padding(.horizontal, 14).frame(minHeight: 44)
                    .foregroundStyle(chosen ? ShellPalette.cream : .white.opacity(0.75))
                    .background(.white.opacity(chosen ? 0.08 : 0.03), in: RoundedRectangle(cornerRadius: 9))
                    .contentShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(row.label + ", " + option.label)
                .accessibilityAddTraits(chosen ? .isSelected : [])
                .shellTarget("set.row.\(row.id).\(option.id)", enabled: row.enabled, radius: 9) { change(option.id) }
            }
        }
    }
    private func rangeButton(_ symbol: String, min: Double, max: Double, delta: Double) -> some View {
        let action = { change(String(Swift.min(max, Swift.max(min, (Double(row.value) ?? min) + delta)))) }
        return Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).frame(width: 44, height: 44)
        }
        .buttonStyle(.plain).background(.white.opacity(0.055), in: Circle())
        .overlay(Circle().strokeBorder(.white.opacity(0.10)))
        .accessibilityLabel(ShellStrings.text(symbol == "minus" ? "Decrease" : "Increase") + " " + row.label)
        .shellTarget("set.row.\(row.id).\(symbol)", enabled: row.enabled, radius: 22, action: action)
    }
}
