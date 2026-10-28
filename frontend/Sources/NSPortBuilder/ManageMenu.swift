import SwiftUI

/// What the Manage menu of a game's hero does. One closure per item, so the menu (ManageItem.list) and its tests never
/// reach into the launcher's state.
struct ManageActions {
    var rebuild: () -> Void = {}
    var options: () -> Void = {}
    var saves: () -> Void = {}
    var changeArtwork: () -> Void = {}
    var resetArtwork: () -> Void = {}
    var reveal: () -> Void = {}
    var freeSpace: () -> Void = {}
    var remove: () -> Void = {}
}

/// One row of the Manage menu.
struct ManageItem: Identifiable {
    let id: String
    let symbol: String
    let title: String
    var enabled = true
    var destructive = false
    var separatorBefore = false
    let run: () -> Void

    /// The menu's rows, in order, built in one place: a new item is one line here. The rules are the ones the system menu had:
    /// Build again is off while a build runs or with no recorded inputs, Remove while this game is the one building.
    static func list(game: LibraryGame, labels t: (String) -> String, running: Bool, olderTools: Bool, activeBuildID: UUID?,
                     hasBuildFolder: Bool, actions a: ManageActions) -> [ManageItem] {
        var items = [ManageItem(id: "rebuild", symbol: "arrow.clockwise", title: t(olderTools ? "library.rebuild" : "library.buildAgain"),
                                enabled: !running && !game.inputs["base", default: []].isEmpty, run: a.rebuild)]
        if game.isReady { items.append(.init(id: "options", symbol: "slider.horizontal.3", title: t("launch.title"), run: a.options)) }
        items.append(.init(id: "saves", symbol: "tray.and.arrow.down", title: t("saves.menu"), run: a.saves))
        items.append(.init(id: "artwork", symbol: "photo", title: t("library.changeArtwork"), run: a.changeArtwork))
        if !game.artworkPath.isEmpty { items.append(.init(id: "resetArtwork", symbol: "arrow.uturn.backward", title: t("library.resetArtwork"), run: a.resetArtwork)) }
        if game.revealTarget != nil { items.append(.init(id: "reveal", symbol: "folder", title: t("install.reveal"), run: a.reveal)) }
        if hasBuildFolder { items.append(.init(id: "freeSpace", symbol: "externaldrive", title: t("free.menu"), run: a.freeSpace)) }
        items.append(.init(id: "remove", symbol: "trash", title: t("library.remove"), enabled: game.id != activeBuildID,
                           destructive: true, separatorBefore: true, run: a.remove))
        return items
    }

    /// The pad-focus id of the row.
    var padID: String { "manage." + id }
}

/// What a controller's button does around the Manage menu; the rest of the launcher's routing stays in ContentView.padAction.
enum ManagePad {
    enum Route: Equatable {
        case open       // Y: open the selected game's menu
        case close      // B: close it
        case swallow    // X, Y, L and R while it is open: nothing happens behind it
        case pass       // the D-pad and A (PadFocus moves or activates in the menu's scope), or any button with the menu closed
    }

    static func route(_ action: LauncherGamepad.Action, menuOpen: Bool, sheetOpen: Bool, hasGame: Bool) -> Route {
        if menuOpen {
            switch action {
            case .b: return .close
            case .x, .y, .l, .r: return .swallow
            case .up, .down, .left, .right, .a: return .pass
            }
        }
        return action == .y && !sheetOpen && hasGame ? .open : .pass
    }

    /// The row a controller lands on when the menu opens: the first one that can be used.
    static func firstFocus(_ items: [ManageItem]) -> String? { items.first { $0.enabled }?.padID }
}

/// The hero's Manage button reports its frame here so the menu opens against it, outside the hero's clipping.
struct ManageAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>?
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}

extension View {
    /// Draws the Manage menu over the window when `items` is non-nil, above the button that reported ManageAnchorKey (below it
    /// when there is no room above), with a click anywhere else closing it.
    func manageMenuOverlay(items: [ManageItem]?, label: String, pad: PadFocus, close: @escaping () -> Void) -> some View {
        overlayPreferenceValue(ManageAnchorKey.self) { anchor in
            GeometryReader { g in
                if let items, let anchor {
                    let button = g[anchor]
                    let height = ManageMenuPanel.height(items)
                    let above = button.minY - 8 - height >= ManageMenuPanel.topInset   // not over the top bar
                    ZStack(alignment: .topLeading) {
                        Color.black.opacity(0.001).contentShape(Rectangle()).onTapGesture(perform: close)
                            .accessibilityHidden(true)
                        ManageMenuPanel(items: items, label: label, close: close).environmentObject(pad)
                            .offset(x: min(max(button.minX, 8), max(8, g.size.width - ManageMenuPanel.width - 8)),
                                    y: above ? button.minY - 8 - height : min(button.maxY + 8, max(8, g.size.height - height - 8)))
                    }
                }
            }
        }
    }
}

/// The Manage button's look: the icon and the word, as the system menu's label had them.
struct ManageButtonLabel: View {
    let title: String
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "ellipsis.circle").font(.system(size: 27, weight: .ultraLight))
            Text(title).font(.manrope(13))
        }
        .foregroundStyle(.white).contentShape(Rectangle())
    }
}

/// The dropdown: the app's dark surface with its border and radius, a symbol and a label per row, Remove in red under a
/// divider. Arrow keys move, Return activates, Esc closes (a local key monitor while it is open: the hero's Play button
/// owns Return otherwise); a controller moves by PadFocus in the "manage" scope.
struct ManageMenuPanel: View {
    static let width: CGFloat = 250
    static let rowHeight: CGFloat = 36
    static let topInset: CGFloat = 74   // the top bar (65 pt) and a gap
    static func height(_ items: [ManageItem]) -> CGFloat {
        CGFloat(items.count) * rowHeight + CGFloat(items.filter(\.separatorBefore).count) * 9 + 12
    }

    let items: [ManageItem]
    let label: String
    let close: () -> Void
    @State private var highlighted: Int?
    @State private var monitor: Any?
    @EnvironmentObject private var pad: PadFocus

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if item.separatorBefore { Divider().opacity(0.4).padding(.vertical, 4).padding(.horizontal, 6) }
                row(item, index: index)
            }
        }
        .padding(6)
        .frame(width: Self.width)
        .background(LauncherPalette.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.10)))
        .shadow(color: .black.opacity(0.5), radius: 18, y: 6)
        .padScope("manage", pad)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
        .onAppear(perform: startKeys)
        .onDisappear(perform: stopKeys)
    }

    private func row(_ item: ManageItem, index: Int) -> some View {
        let tint = item.destructive ? Color(red: 1, green: 0.42, blue: 0.40) : Color.white.opacity(0.92)
        return Button { activate(item) } label: {
            HStack(spacing: 11) {
                Image(systemName: item.symbol).font(.system(size: 13, weight: .medium)).frame(width: 18)
                Text(item.title).font(.manrope(13, .medium)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(tint).opacity(item.enabled ? 1 : 0.4)
            .padding(.horizontal, 10).frame(height: Self.rowHeight)
            .background(highlighted == index && item.enabled ? Color.white.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(!item.enabled)
        .onHover { inside in if inside && item.enabled { highlighted = index } else if !inside && highlighted == index { highlighted = nil } }
        .accessibilityLabel(item.title)
        .padTarget(item.padID, scope: "manage", radius: 8) { activate(item) }
    }

    private func activate(_ item: ManageItem) {
        guard item.enabled else { return }
        close()
        item.run()
    }

    private func step(_ delta: Int) {
        let usable = items.indices.filter { items[$0].enabled }
        guard !usable.isEmpty else { return }
        if let current = highlighted, let at = usable.firstIndex(of: current) {
            highlighted = usable[(at + delta + usable.count) % usable.count]
        } else {
            highlighted = delta > 0 ? usable.first : usable.last
        }
    }

    private func startKeys() {
        stopKeys()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 125: step(1)
            case 126: step(-1)
            case 36, 76: if let i = highlighted, items.indices.contains(i) { activate(items[i]) }
            case 53: close()
            default: return event
            }
            return nil
        }
    }

    private func stopKeys() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
