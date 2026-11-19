import SwiftUI
import NXCore
import NXModel
import NXLauncher

extension LauncherView {
    @ViewBuilder private func navLabel(_ destination: LauncherPage, compact: Bool) -> some View {
        if compact { Image(systemName: destination.symbol).accessibilityLabel(loc.t("nav." + destination.rawValue)) }
        else {
            HStack(spacing: 6) {
                if destination != .settings { Image(systemName: destination.symbol).accessibilityHidden(true) }
                Text(loc.t("nav." + destination.rawValue))
            }
        }
    }

    private func navigationTabs(compact: Bool = false, tabInset: CGFloat) -> some View {
        HStack(spacing: 2) {
            ForEach([LauncherPage.library, .builds], id: \.self) { destination in
                Button { page = destination } label: {
                    // The selected tab is bold. The bold text also sizes the (hidden) slot, so a tab never changes width as the selection moves.
                    ZStack {
                        navLabel(destination, compact: compact).font(.manrope(13, .bold)).hidden()
                        navLabel(destination, compact: compact).font(.manrope(13, page == destination ? .bold : .medium))
                    }
                        .padding(.horizontal, tabInset).frame(height: LauncherControl.height - 6)
                        .foregroundStyle(page == destination ? LauncherPalette.segmentSelectedText : LauncherPalette.text)
                        .background(page == destination ? LauncherPalette.segmentSelected : .clear,
                                    in: Capsule())
                        .contentShape(Capsule())   // the whole pill takes the click, not only its text
                }
                .buttonStyle(.plain).launcherHover().help(loc.t("nav." + destination.rawValue))
                .accessibilityAddTraits(page == destination ? .isSelected : [])
                .padTarget("tab." + destination.rawValue, scope: "main", focusColor: page == destination ? LauncherPalette.segmentSelectedText : nil) { page = destination }
            }
        }
        .padding(3)
        .background(LauncherPalette.segmentTrack, in: Capsule())
        .overlay(Capsule().strokeBorder(LauncherPalette.segmentTrackBorder))
        .fixedSize(horizontal: true, vertical: false)
    }

    var topBar: some View {
        LauncherHeaderLayout {
            HStack(spacing: 16) {
                LauncherBrandMark(onHero: page == .library && colorScheme == .dark).fixedSize()
            }.padding(.leading, 90)
            ViewThatFits(in: .horizontal) {
                navigationTabs(tabInset: 18)
                navigationTabs(tabInset: 8)
                navigationTabs(compact: true, tabInset: 14)
            }
            HStack(spacing: 6) {
                PlayerPicker(players: stores.players, compact: searching)   // whose saves Play uses (PlayerPicker.swift)
                searchField
                // A newer release is out: a small icon, last in the bar, opens the update sheet. Without one the bar
                // stays as it is.
                if let update = updates.update {
                    let readOnly = updates.installability == .readOnly
                    Button { updates.showUpdateSheet = true } label: {
                        Image(systemName: readOnly ? "exclamationmark.arrow.circlepath" : "arrow.down.circle")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(readOnly ? LauncherPalette.building : LauncherPalette.ready)
                            .frame(width: 34, height: 34).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).launcherHover()
                    .padTarget("top.update", scope: "main") { updates.showUpdateSheet = true }
                    .padding(.leading, 16.5).padding(.trailing, -7.5)
                    .help(String(format: loc.t("update.pill"), update.tag) + "\n" + loc.t(readOnly ? "update.readOnlyHint" : "update.pillHelp"))
                    .accessibilityLabel(String(format: loc.t("update.pill"), update.tag))
                }
                Button { page = .settings } label: {
                    Image(systemName: "gearshape.fill").font(.system(size: 15, weight: .medium))
                        .frame(width: LauncherControl.height, height: LauncherControl.height)
                        .foregroundStyle(page == .settings ? LauncherPalette.segmentSelectedText : LauncherPalette.text)
                        .background(page == .settings ? LauncherPalette.segmentSelected : LauncherPalette.secondaryFill, in: Circle())
                        .overlay(Circle().strokeBorder(LauncherPalette.secondaryBorder))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain).launcherHover()
                .help(loc.t("nav.settings")).accessibilityLabel(loc.t("nav.settings"))
                .accessibilityAddTraits(page == .settings ? .isSelected : [])
                .keyboardShortcut(",", modifiers: .command)
                .padTarget("top.settings", scope: "main", focusColor: page == .settings ? LauncherPalette.segmentSelectedText : nil, activate: { page = .settings })
                .padding(.leading, 8)
            }.padding(.trailing, 24)
        }
        .frame(height: 64)
        .background(TitlebarDoubleClick())   // an empty part of the bar acts as the title bar does
    }


    /// The magnifier opens into a search field in the bar itself; Esc, or leaving it empty, closes it again.
    private var searchField: some View {
        HStack(spacing: 8) {
            Button {
                searching = true
                page = .library
                searchFocused = true
            } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 16, weight: .medium))
                    .foregroundStyle(searching ? Color.secondary : Color.primary)
                    .frame(width: searching ? 16 : LauncherControl.height, height: searching ? 16 : LauncherControl.height).contentShape(Rectangle())
            }
            .keyboardShortcut("f", modifiers: .command)
            .buttonStyle(.plain).launcherHover().help(loc.t("library.search") + " (\u{2318}F)")   // the shortcut in the tooltip and to VoiceOver
            .accessibilityLabel(loc.t("library.search")).accessibilityHint(loc.t("library.searchShortcut"))
            if searching {
                TextField(loc.t("library.search"), text: $search)
                    .textFieldStyle(.plain).font(.manrope(14))
                    .focused($searchFocused)
                    .onAppear { DispatchQueue.main.async { searchFocused = true } }
                    .onSubmit { if search.isEmpty { closeSearch() } }
                    .onExitCommand { closeSearch() }
                    .frame(minWidth: 100, idealWidth: 210, maxWidth: 210)
                    .transition(.identity)
                Button { closeSearch() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(LauncherPalette.secondaryText)
                        .frame(width: 24, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain).launcherHover().help(loc.t("library.clearSearch")).accessibilityLabel(loc.t("library.clearSearch"))
            }
        }
        .padding(.horizontal, searching ? 12 : 0)
        .frame(height: 36)
        .background(LauncherPalette.secondaryFill, in: Capsule())
        .overlay(Capsule().strokeBorder(searching && searchFocused ? LauncherPalette.cream : LauncherPalette.secondaryBorder,
                                         lineWidth: searching && searchFocused ? 2 : 1))
        .transaction { $0.animation = nil }
        .onChange(of: searchFocused) { focused in
            if !focused && search.isEmpty { closeSearch() }
        }
    }

    private func closeSearch() {
        search = ""
        searchFocused = false
        searching = false
    }

}

/// Equal clearance around the center keeps navigation stationary when either edge changes width.
struct LauncherHeaderLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 1000, height: 64)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let edges = ProposedViewSize(width: max(0, bounds.width / 2 - 60), height: bounds.height)
        let leading = subviews[0].sizeThatFits(edges)
        let trailing = subviews[2].sizeThatFits(edges)
        let center = ProposedViewSize(width: max(0, bounds.width - 2 * (max(leading.width, trailing.width) + 12)), height: bounds.height)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: edges)
        subviews[1].place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: center)
        subviews[2].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: edges)
    }
}
