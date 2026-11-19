import AppKit
import SwiftUI

/// The columns of the Builds list, with the widths and spacing SwiftUI's `Table` gave them in the inset style: the game
/// fills what the fixed columns leave, NSTableView's 17 point intercell spacing sits between them and 16 points pad each side.
enum BuildColumns {
    static let gameMin: CGFloat = 220, mac: CGFloat = 100, mobile: CGFloat = 160, manage: CGFloat = 52
    static let spacing: CGFloat = 17
    static let inset: CGFloat = 16
    static let headerHeight: CGFloat = 28

    /// A row draws the line below it, as the table did: not under the last row, and not next to the selected one.
    static func separator(below index: Int, selected: Int?, count: Int) -> Bool {
        index < count - 1 && index != selected && index + 1 != selected
    }
}

/// One line of the Builds list in its four columns, for the header and for every row.
struct BuildColumnsRow<Game: View, Mac: View, Mobile: View, Manage: View>: View {
    @ViewBuilder let game: Game
    @ViewBuilder let mac: Mac
    @ViewBuilder let mobile: Mobile
    @ViewBuilder let manage: Manage
    var body: some View {
        HStack(spacing: BuildColumns.spacing) {
            game.frame(minWidth: BuildColumns.gameMin, maxWidth: .infinity, alignment: .leading)
            mac.frame(width: BuildColumns.mac, alignment: .leading)
            mobile.frame(width: BuildColumns.mobile, alignment: .leading)
            manage.frame(width: BuildColumns.manage)
        }
        .padding(.horizontal, BuildColumns.inset)
    }
}

/// The Builds list. It was a SwiftUI `Table` (#1392), which measured and built every visible row twice when the tab opened
/// and made opening Builds about twice as slow as before. This lazy stack builds each row once and keeps what the table
/// did: the column header, one selected row (a click, the arrow keys, the controller), the context menu, the primary action
/// on a double click or Return, the row separators and the selection colours of AppKit.
struct BuildInventoryList<Row: View, Menu: View>: View {
    let entries: [BuildInventoryEntry]
    @Binding var selection: UUID?
    let navigation: BuildTableNavigation
    let titles: (game: String, mac: String, mobile: String)
    /// Where a row's separator starts, from the row's leading edge: under the name, past the artwork when there is one.
    let separatorLead: (BuildInventoryEntry) -> CGFloat
    @ViewBuilder let row: (BuildInventoryEntry) -> Row
    @ViewBuilder let menu: (BuildInventoryEntry) -> Menu
    let primaryAction: (BuildInventoryEntry) -> Void
    @FocusState private var focused: Bool
    @Environment(\.controlActiveState) private var windowState

    var body: some View {
        let selected = selection.flatMap { id in entries.firstIndex { $0.id == id } }
        return VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(zip(entries.indices, entries)), id: \.1.id) { index, entry in
                            line(entry, selected: index == selected, separator: BuildColumns.separator(below: index, selected: selected, count: entries.count))
                        }
                    }
                    .padding(.vertical, 5)
                }
                .onAppear { navigation.scroll = { id in proxy.scrollTo(id) } }
            }
        }
        .background(alignment: .topLeading) {
            Button { if let selected { primaryAction(entries[selected]) } } label: { EmptyView() }
                .keyboardShortcut(focused ? KeyboardShortcut(.return, modifiers: []) : nil)
                .buttonStyle(.plain).hidden().accessibilityHidden(true)
        }
        .focusable()
        .focused($focused)
        .modifier(NoFocusEffect())
        .onMoveCommand { direction in
            let step: Int
            switch direction {
            case .up: step = -1
            case .down: step = 1
            default: return
            }
            guard let next = BuildListKeys.moved(from: selection, by: step, in: entries.map(\.id)) else { return }
            selection = next
            navigation.reveal(next)
        }
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        BuildColumnsRow {
            title(titles.game)
        } mac: {
            title(titles.mac).overlay(alignment: .leading) { columnRule }
        } mobile: {
            title(titles.mobile).overlay(alignment: .leading) { columnRule }
        } manage: {
            Color.clear.overlay(alignment: .leading) { columnRule }
        }
        .frame(height: BuildColumns.headerHeight)
        .overlay(alignment: .bottom) { Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1.5).offset(y: 0.5) }   // AppKit's header rule
    }

    private func title(_ text: String) -> some View {
        Text(text).lineLimit(1).padding(.leading, 2).accessibilityAddTraits(.isHeader)
    }

    /// The short line AppKit draws between two column titles, halfway into the spacing.
    private var columnRule: some View {
        Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1, height: 16)
            .offset(x: -(BuildColumns.spacing / 2).rounded(.up)).accessibilityHidden(true)
    }

    private func line(_ entry: BuildInventoryEntry, selected: Bool, separator: Bool) -> some View {
        let emphasized = selected && focused && windowState == .key   // AppKit's accent selection: the list has the keys
        return row(entry)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(emphasized ? AnyShapeStyle(Color(nsColor: .alternateSelectedControlTextColor)) : AnyShapeStyle(.primary))
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: emphasized ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor))
                        .padding(.horizontal, 10)
                }
            }
            .overlay(alignment: .bottom) {
                if separator {
                    Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
                        .padding(.leading, BuildColumns.inset + separatorLead(entry)).padding(.trailing, BuildColumns.inset)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                selection = entry.id
                focused = true
                if NSApp.currentEvent?.clickCount == 2 { primaryAction(entry) }
            }
            .contextMenu { menu(entry) }
            .id(entry.id)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The selection shows where the keyboard is, so the list draws no focus ring around itself (macOS 14 and later).
private struct NoFocusEffect: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14, *) { content.focusEffectDisabled() } else { content }
    }
}
