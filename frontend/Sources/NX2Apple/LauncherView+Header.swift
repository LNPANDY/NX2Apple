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
                Button { page = destination; if destination == .builds { buildEditorOpen = false } } label: {
                    // The selected tab is bold. The bold text also sizes the (hidden) slot, so a tab never changes width as the selection moves.
                    ZStack {
                        navLabel(destination, compact: compact).font(DS.Font.bodyStrong).hidden()
                        navLabel(destination, compact: compact).font(page == destination ? DS.Font.bodyStrong : DS.Font.body)
                    }
                        .padding(.horizontal, tabInset).frame(height: LauncherControl.height - 6)
                        .foregroundStyle(page == destination ? LauncherPalette.segmentSelectedText : LauncherPalette.text)
                        .background(page == destination ? LauncherPalette.segmentSelected : .clear,
                                    in: Capsule())
                        .contentShape(Capsule())   // the whole pill takes the click, not only its text
                }
                .buttonStyle(.plain).launcherHover().help(loc.t("nav." + destination.rawValue))
                .accessibilityAddTraits(page == destination ? .isSelected : [])
                .padTarget("tab." + destination.rawValue, scope: "main", focusColor: page == destination ? LauncherPalette.segmentSelectedText : nil) { page = destination; if destination == .builds { buildEditorOpen = false } }
            }
        }
        .padding(3)
        .launcherGlass(in: Capsule())
        .fixedSize(horizontal: true, vertical: false)
    }

    /// The build wizard's own navigation, at the top of its content column instead of beside the wordmark (#1458): back to the
    /// Builds list and the wizard's options.
    var buildWizardBar: some View {
        HStack(spacing: DS.Space.xs) {
            BuildHeaderControls(build: m, onBack: {
                buildEditorOpen = false; padFocus.focused = "builds.first"
            }, onInstallExisting: {
                m.target = BuildTarget.ios; devices.exportIPA = false; buildStep = 2
            }, onExport: {
                m.target = BuildTarget.ios; devices.exportIPA = true; buildStep = 2
            }, onCancel: { confirmingBuildCancel = true }, logOpen: $buildLogOpen, onShowSteps: { allBuildStepsOpen = true }, onEdit: { editingBuildResult = true; buildStep = 0 })
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.xl).padding(.vertical, DS.Space.s)
        .frame(maxWidth: DS.Control.contentWidth).frame(maxWidth: .infinity)
    }

    var topBar: some View {
        LauncherHeaderLayout {
            HStack(spacing: DS.Space.m) {
                LauncherWordmark()
            }.padding(.leading, 90)
            ViewThatFits(in: .horizontal) {
                navigationTabs(tabInset: 18)
                navigationTabs(tabInset: 8)
                navigationTabs(compact: true, tabInset: 14)
            }
            LauncherGlassGroup(spacing: 8) {
            HStack(spacing: 8) {
                PlayerPicker(players: stores.players, compact: searching)   // whose saves Play uses (PlayerPicker.swift)
                searchField
                // A newer release is out: a small icon, last in the bar, opens the update sheet. Without one the bar
                // stays as it is.
                if let update = updates.update {
                    let readOnly = updates.installability == .readOnly
                    Button { updates.showUpdateSheet = true } label: {
                        Image(systemName: readOnly ? "exclamationmark.arrow.circlepath" : "arrow.down.circle")
                            .foregroundStyle(readOnly ? LauncherPalette.building : LauncherPalette.ready)
                    }
                    .buttonStyle(LauncherIconButtonStyle())
                    .padTarget("top.update", scope: "main") { updates.showUpdateSheet = true }
                    .help(String(format: loc.t("update.pill"), update.tag) + "\n" + loc.t(readOnly ? "update.readOnlyHint" : "update.pillHelp"))
                    .accessibilityLabel(String(format: loc.t("update.pill"), update.tag))
                }
                Button { page = .settings } label: { Image(systemName: "gearshape.fill") }
                .buttonStyle(LauncherIconButtonStyle(selected: page == .settings))
                .help(loc.t("nav.settings")).accessibilityLabel(loc.t("nav.settings"))
                .accessibilityAddTraits(page == .settings ? .isSelected : [])
                .keyboardShortcut(",", modifiers: .command)
                .padTarget("top.settings", scope: "main", focusColor: page == .settings ? LauncherPalette.segmentSelectedText : nil, activate: { page = .settings })
            }
            }.padding(.trailing, 24)
        }
        .frame(height: 64)
        .background(TitlebarDoubleClick())   // an empty part of the bar acts as the title bar does
        .launcherGlassLayer()   // the top bar floats above the content: its controls are glass (#1458)
    }


    /// The magnifier opens into a search field in the bar itself; Esc, or leaving it empty, closes it again.
    private var searchField: some View {
        HStack(spacing: 8) {
            Button {
                searching = true
                if page == .builds { buildEditorOpen = false } else { page = .library }
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
                    .textFieldStyle(.plain).font(DS.Font.body)
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
        .launcherGlass(in: Capsule())
        .overlay { if searching && searchFocused { DSPill().strokeBorder(LauncherPalette.cream, lineWidth: 2) } }
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
