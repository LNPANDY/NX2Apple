import SwiftUI

/// The open button-mapping card: whose map it is (`ControllersView.mappingID` for the shell's, else a game's ID) and the
/// row whose options are showing, nil for the list of rows.
struct PadMappingState: Equatable {
    let gameID: String
    var row: String?
}

private struct ShellOpenPadMappingKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: ((String) -> Void)? = nil
}
private struct ShellOpenButtonTestKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: (() -> Void)? = nil
}
extension EnvironmentValues {
    /// Opens the button-mapping card for the shell (`ControllersView.mappingID`) or a game. The library provides it.
    var shellOpenPadMapping: ((String) -> Void)? {
        get { self[ShellOpenPadMappingKey.self] }
        set { self[ShellOpenPadMappingKey.self] = newValue }
    }
    /// Opens the button test. The library provides it.
    var shellOpenButtonTest: (() -> Void)? {
        get { self[ShellOpenButtonTestKey.self] }
        set { self[ShellOpenButtonTestKey.self] = newValue }
    }
}

/// The rows of a mapping, shared by the card and the compact row that opens it. A row's `fromShell` means it does what it
/// would do anyway: the default for the shell's map, the shell's choice for a game's.
public enum PadMappingRows {
    /// The shell's map as rows: Swap A and B, then the 16 buttons.
    static func global(_ map: PadMap) -> [SettingRow] {
        let swap = SettingRow(id: "swapAB", label: ShellStrings.text("Swap A and B"),
                              note: ShellStrings.text("Only affects physical controllers in games, not shell menus. Each game can override these settings."),
                              kind: .choice([SettingOption("0", ShellStrings.text("Off")), SettingOption("1", ShellStrings.text("On"))]),
                              value: map.swapAB ? "1" : "0", fromShell: !map.swapAB)
        return [swap] + PadMap.buttons.map { button in
            SettingRow(id: button, label: PadMap.label(button), kind: .choice(PadMap.options), value: map.output(for: button),
                       fromShell: map.output(for: button) == button)
        }
    }
    /// A game's rows, as the host puts them in its "pad" section.
    static func game(_ detail: GameDetail) -> [SettingRow] {
        detail.sections.first { $0.id == sectionID }?.rows ?? []
    }
    static let sectionID = "pad"
    /// The setting a game's card sends to forget the game's own mapping.
    public static let resetID = "pad.reset"
    static func valueLabel(_ row: SettingRow) -> String {
        if case .choice(let options) = row.kind { return options.first { $0.id == row.value }?.label ?? row.value }
        return row.value
    }
    /// The compact row's value: nothing changed, or how much.
    static func summary(_ rows: [SettingRow], game: Bool) -> String {
        let changed = Set(rows.filter { !$0.fromShell }.map(\.id))
        guard let swap = rows.first, !changed.isEmpty else { return ShellStrings.text(game ? "Follow global" : "Default") }
        // Swapping A and B changes the rows of A and B too: only those three changed reads as the swap's own value.
        if changed.contains(swap.id) && changed.isSubset(of: Set(rows.prefix(3).map(\.id))) { return swap.label + ": " + valueLabel(swap) }
        return ShellStrings.text("Custom")
    }
}

/// The compact row that opens the mapping card, in the Controllers page and in a game's settings.
struct PadMappingEntryRow: View {
    let gameID: String
    let rows: [SettingRow]
    var targetID: String
    @Environment(\.shellOpenPadMapping) private var openMapping
    var body: some View {
        let isGame = gameID != ControllersView.mappingID
        let row = SettingRow(id: "padMapping", label: ShellStrings.text("Button mapping"),
                             note: ShellStrings.text(isGame ? "Overrides the global mapping for this game only." : "What each button of a physical controller sends in games."),
                             kind: .choice([]), value: "")
        ChoiceValueRow(row: row, valueLabel: PadMappingRows.summary(rows, game: isGame), hint: ShellStrings.text("Opens the button mapping")) {
            openMapping?(gameID)
        }
        .shellTarget(targetID, radius: 11) { openMapping?(gameID) }
        .accessibilityIdentifier("padMapping.open")
    }
}

/// The button mapping in a card of its own, as a long choice list is: the rows with their current values, and a row's
/// options in place of the rows once it is picked. D-pad and keys move through `map.` targets, A picks, B goes back to
/// the rows and then closes.
struct PadMappingCard: View {
    let title: String
    let rows: [SettingRow]
    let openRow: String?
    let open: (String) -> Void
    let pick: (String, String) -> Void
    let backToList: () -> Void
    let reset: () -> Void
    let close: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.shellFocus) private var focus

    private var shown: SettingRow? { openRow.flatMap { id in rows.first { $0.id == id } } }

    var body: some View {
        ViewThatFits(in: .vertical) {
            content(scrolls: false)
            content(scrolls: true)
        }
        .frame(maxWidth: 460)
        .background(Color(red: 0.075, green: 0.075, blue: 0.082), in: RoundedRectangle(cornerRadius: 26))
        .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(.white.opacity(0.10)))
        .shadow(color: .black.opacity(0.5), radius: 40)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("padMapping.card")
    }

    private func content(scrolls: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(ShellPalette.hairline).frame(height: 1)
            if scrolls {
                ScrollViewReader { proxy in
                    ScrollView { body(of: shown) }
                        .scrollIndicators(.hidden)
                        .onAppear { if let id = focus.id { proxy.scrollTo(id, anchor: .center) } }
                        .onChange(of: focus.id) { _, id in
                            guard let id, id.hasPrefix("map.") else { return }
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                                proxy.scrollTo(id, anchor: id == "map.close" || id == "map.back" ? .top : .center)
                            }
                        }
                }
            } else {
                body(of: shown)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            if shown != nil {
                Button(action: backToList) {
                    Image(systemName: "chevron.left").font(.system(size: 14, weight: .semibold)).frame(width: 44, height: 44)
                        .background(.white.opacity(0.08), in: Circle()).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(ShellStrings.text("Button mapping"))
                .accessibilityIdentifier("padMapping.back")
                .shellTarget("map.back", radius: 22, action: backToList)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(shown?.label ?? ShellStrings.text("Button mapping")).shellType(ShellType.flowTitle(20)).lineLimit(2)
                    .accessibilityAddTraits(.isHeader).accessibilityIdentifier("padMapping.title")
                Text(shown == nil ? title : ShellStrings.text("Sends in games")).shellType(ShellType.note)
                    .foregroundStyle(.white.opacity(0.5)).lineLimit(2)
            }
            Spacer(minLength: 8)
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 14, weight: .semibold)).frame(width: 44, height: 44)
                    .background(.white.opacity(0.08), in: Circle()).contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(ShellStrings.text("Close"))
            .accessibilityIdentifier("padMapping.close")
            .shellTarget("map.close", radius: 22, action: close)
        }
        .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 8)
    }

    @ViewBuilder private func body(of row: SettingRow?) -> some View {
        if let row { options(row) } else { list }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(rows) { row in
                rowButton(row)
                if row.id == rows.first?.id {
                    if !row.note.isEmpty {
                        Text(row.note).shellType(ShellType.note).foregroundStyle(.white.opacity(0.45))
                            .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 14).padding(.bottom, 8)
                    }
                    Text(ShellStrings.text("Buttons").uppercased()).shellText(10.5, .bold, relativeTo: .caption2).tracking(1.4)
                        .foregroundStyle(.white.opacity(0.45)).padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 2)
                        .accessibilityAddTraits(.isHeader)
                }
            }
            Button(action: reset) { Text(ShellStrings.text("Reset to default")) }
                .buttonStyle(ChipButtonStyle())
                .disabled(rows.allSatisfy(\.fromShell))
                .accessibilityIdentifier("padMapping.reset")
                .shellTarget("map.reset", enabled: !rows.allSatisfy(\.fromShell), action: reset)
                .padding(.horizontal, 6).padding(.top, 10)
        }
        .padding(10)
    }

    private func rowButton(_ row: SettingRow) -> some View {
        let changed = !row.fromShell
        return Button { open(row.id) } label: {
            HStack(spacing: 12) {
                Text(row.label).shellText(15, .medium).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(PadMappingRows.valueLabel(row)).shellText(14.5, changed ? .bold : .medium)
                    .foregroundStyle(changed ? ShellPalette.cream : .white.opacity(0.5)).multilineTextAlignment(.trailing)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(.white.opacity(0.4))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14).padding(.vertical, 8).frame(minHeight: 44)
            .background(.white.opacity(changed ? 0.07 : 0.0), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(row.label)
        .accessibilityValue(PadMappingRows.valueLabel(row))
        .accessibilityIdentifier("padMapping.row.\(row.id)")
        .shellTarget("map.row.\(row.id)", radius: 10) { open(row.id) }
    }

    private func options(_ row: SettingRow) -> some View {
        let options: [SettingOption] = if case .choice(let o) = row.kind { o } else { [] }
        return VStack(spacing: 4) {
            ForEach(options) { option in
                let chosen = row.value == option.id
                Button { pick(row.id, option.id) } label: {
                    HStack(spacing: 12) {
                        Text(option.label).shellText(15, chosen ? .bold : .medium).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        if chosen { Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).accessibilityHidden(true) }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8).frame(minHeight: 44)
                    .foregroundStyle(chosen ? ShellPalette.cream : .white.opacity(0.8))
                    .background(.white.opacity(chosen ? 0.09 : 0.0), in: RoundedRectangle(cornerRadius: 10))
                    .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.label)
                .accessibilityAddTraits(chosen ? .isSelected : [])
                .accessibilityIdentifier("padMapping.option.\(option.id)")
                .shellTarget("map.opt.\(option.id)", radius: 10) { pick(row.id, option.id) }
            }
        }
        .padding(10)
    }
}
