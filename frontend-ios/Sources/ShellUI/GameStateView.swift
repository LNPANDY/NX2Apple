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
            Button(action: perform) { Label(game.state.actionTitle, systemImage: game.state.actionSymbol) }
                .buttonStyle(PrimaryPillStyle())
                .accessibilityIdentifier("state.action")
                .accessibilityLabel(game.state.actionTitle + ", " + game.title)
                .shellTarget("set.play", radius: 25, action: perform)
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
        case .needsGameData: actions.onPickGameData(game.id)
        case .needsAppUpdate: actions.onAppUpdate()
        case .broken: actions.onShowLog(game.id)
        }
    }
}

/// How to fix a broken game or update the app: both happen on the Mac, so this says so in two sentences and offers
/// what can be done here. The log stays available for a bug report.
public struct StateHelpView: View {
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
            Text(game.state.actionTitle).shellText(26, .heavy, relativeTo: .title).tracking(-0.7)
                .accessibilityAddTraits(.isHeader).accessibilityIdentifier("help.title")
            Text(message).shellText(15).foregroundStyle(.white.opacity(0.78)).fixedSize(horizontal: false, vertical: true)
            if case .broken(_, let detail) = game.state, !detail.isEmpty {
                Text(detail).shellText(13).foregroundStyle(.white.opacity(0.5)).fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 10) {
                Button(action: onClose) { Text(ShellStrings.text("Done")).frame(maxWidth: .infinity) }
                    .buttonStyle(PrimaryPillStyle(expands: true))
                    .accessibilityIdentifier("help.done")
                    .shellTarget("help.done", radius: 25, action: onClose)
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
        case .broken: ShellStrings.text("Build this game again on your Mac and install it on this device. The Mac app checks every file while it builds, so the new copy is complete.")
        case .needsAppUpdate: ShellStrings.text("This game needs a newer version of this app. Update it with the Mac app on your Mac, then install it on this device again.")
        default: ""
        }
    }
}

/// No game in the app yet: an empty shelf, said plainly.
public struct EmptyLibraryView: View {
    public init() {}
    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                ForEach(0..<3, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(.white.opacity(0.16 - Double(index) * 0.045), style: StrokeStyle(lineWidth: 1.2, dash: [5, 5]))
                        .frame(width: 76, height: 76)
                }
            }.padding(.bottom, 14).accessibilityHidden(true)
            SectionHeading(title: ShellStrings.text("Your games"))
            Text(ShellStrings.text("A little room for adventure")).shellText(30, .heavy, relativeTo: .title).tracking(-0.8)
                .fixedSize(horizontal: false, vertical: true)
            Text(ShellStrings.text("Your games will appear here when they are included in this app."))
                .shellText(15).foregroundStyle(.white.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(28).frame(maxWidth: 460, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
