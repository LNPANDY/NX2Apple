import SwiftUI

/// A game's state and the one thing to do about it: Play, choose game data, update the app, or read the log.
public struct GameStateView: View {
    public let game: GameTile
    public var actions: ShellActions
    public var showsExplanation: Bool
    @Environment(\.shellShowHelp) private var showHelp
    @State private var localHelp = false
    public init(game: GameTile, actions: ShellActions = ShellActions(), showsExplanation: Bool = true) {
        self.game = game
        self.actions = actions
        self.showsExplanation = showsExplanation
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsExplanation {
                StatusLabel(state: game.state, prominent: true)
                if !game.state.explanation.isEmpty {
                    Text(game.state.explanation).shellText(14.5).foregroundStyle(.white.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            GameLaunchActions(game: game, primary: perform, focusPrefix: "set.")
        }
        .sheet(isPresented: $localHelp) {
            StateHelpView(game: game, actions: actions) { localHelp = false }
                .presentationDetents([.medium])
                .presentationBackground(ShellPalette.background)
        }
    }
    private func perform() {
        if game.state.needsHelp {
            if let showHelp { showHelp(game) } else { localHelp = true }
            return
        }
        switch game.state {
        case .playable: actions.onPlay(game.id)
        case .needsGameData, .needsDataUpdate: actions.onPickGameData(game.id)
        case .joiningGameData: break
        case .needsAppUpdate: actions.onAppUpdate()
        case .broken: actions.onShowLog(game.id)
        }
    }
}

/// How to fix a broken game or update the app: both happen on the Mac, so this says so in two sentences and offers
/// what can be done here. The log stays available for a bug report.
public struct StateHelpView: View {
    @Environment(\.shellNativeBars) private var nativeBars
    public let game: GameTile
    public var actions: ShellActions
    public var onClose: () -> Void
    public init(game: GameTile, actions: ShellActions = ShellActions(), onClose: @escaping () -> Void = {}) {
        self.game = game
        self.actions = actions
        self.onClose = onClose
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StatusLabel(state: game.state, prominent: true)
            Text(game.state.actionTitle).shellType(ShellType.pageTitle)
                .accessibilityAddTraits(.isHeader).accessibilityIdentifier("help.title")
            Text(message).shellText(15).foregroundStyle(.white.opacity(0.78)).fixedSize(horizontal: false, vertical: true)
            if case .broken(_, _, let technical) = game.state, !technical.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(ShellStrings.text("Details")).shellText(11.5, .semibold).foregroundStyle(.white.opacity(0.62))
                    Text(verbatim: ShellStrings.text("Title ID \(game.id)")).font(.system(size: 12, design: .monospaced)).foregroundStyle(.white.opacity(0.62))
                        .textSelection(.enabled).accessibilityIdentifier("help.titleid")
                    Text(verbatim: technical).font(.system(size: 12, design: .monospaced)).foregroundStyle(.white.opacity(0.62))
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("help.details")
                }
            }
            VStack(spacing: 10) {
                if !nativeBars {
                    Button(action: onClose) { Text(ShellStrings.text("Close")).frame(maxWidth: .infinity) }
                        .buttonStyle(ShellButtonStyle(fills: true))
                        .accessibilityIdentifier("help.done")
                        .shellTarget("help.done", radius: 25, action: onClose)
                }
                switch game.state {
                case .broken:
                    Button(ShellStrings.text("Show log")) { actions.onShowLog(game.id) }
                        .buttonStyle(ShellButtonStyle(fills: true))
                        .accessibilityHint(ShellStrings.text("For a bug report"))
                        .accessibilityIdentifier("help.log")
                        .shellTarget("help.log") { actions.onShowLog(game.id) }
                case .needsAppUpdate:
                    Button(ShellStrings.text("Update app")) { actions.onAppUpdate() }
                        .buttonStyle(ShellButtonStyle(fills: true))
                        .accessibilityIdentifier("help.update")
                        .shellTarget("help.update") { actions.onAppUpdate() }
                default:
                    EmptyView()
                }
            }.padding(.top, 8)
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(.white)
    }
    private var message: String {
        switch game.state {
        case .broken(_, let detail, _) where !detail.isEmpty: detail
        case .broken: ShellStrings.text("Build this game again on your Mac and install it on this device. The Mac app checks every file while it builds, so the new copy is complete.")
        case .needsAppUpdate: ShellStrings.text("This game needs a newer version of this app. Update it with the Mac app on your Mac, then install it on this device again.")
        default: ""
        }
    }
}

/// No game in the app yet: an empty shelf with transfer guidance and a direct Settings action.
public struct EmptyLibraryView: View {
    public var onOpenSettings: (() -> Void)?
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif

    public init(onOpenSettings: (() -> Void)? = nil) {
        self.onOpenSettings = onOpenSettings
    }

    private var compactVertical: Bool {
        #if os(iOS)
        verticalSizeClass == .compact
        #else
        false
        #endif
    }

    public var body: some View {
        let tileSize: CGFloat = compactVertical ? 48 : 76
        GeometryReader { geometry in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: compactVertical ? 10 : 18) {
                    HStack(spacing: compactVertical ? 10 : 14) {
                        ForEach(0..<3, id: \.self) { index in
                            RoundedRectangle(cornerRadius: compactVertical ? 9 : 12)
                                .strokeBorder(.white.opacity(0.16 - Double(index) * 0.045), style: StrokeStyle(lineWidth: 1.2, dash: [5, 5]))
                                .frame(width: tileSize, height: tileSize)
                        }
                    }.padding(.bottom, compactVertical ? 4 : 14).accessibilityHidden(true)
                    SectionHeading(title: ShellStrings.text("Your games"))
                    Text(ShellStrings.text("A little room for adventure")).shellType(ShellType.heroTitle(compactVertical ? 24 : 30))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(ShellStrings.text("Your games will appear here when they are included in this app."))
                        .shellText(compactVertical ? 14 : 15).foregroundStyle(.white.opacity(0.72)).fixedSize(horizontal: false, vertical: true)
                    Text(ShellStrings.text("Transfer games from NX2Apple on your Mac or PC, or choose a game data folder in Settings."))
                        .shellText(compactVertical ? 13 : 14).foregroundStyle(.white.opacity(0.62)).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("empty.guide")
                    if let onOpenSettings {
                        Button(action: onOpenSettings) {
                            Label(ShellStrings.text("Open Settings"), systemImage: "gearshape")
                        }
                        .buttonStyle(PrimaryPillStyle())
                        .padding(.top, compactVertical ? 2 : 6)
                        .accessibilityIdentifier("empty.openSettings")
                        .shellTarget("lib.empty.settings", radius: ShellFocusTarget.capsule, action: onOpenSettings)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, compactVertical ? 12 : 28)
                .frame(maxWidth: 460, alignment: .leading)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
