import SwiftUI

/// A game's state and the one thing to do about it: Play, choose game data, update the app, or read the log.
public struct GameStateView: View {
    public let game: GameTile
    public var actions: ShellActions
    public var showsExplanation: Bool
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
    }
    private func perform() {
        switch game.state {
        case .playable: actions.onPlay(game.id)
        case .needsGameData: actions.onPickGameData(game.id)
        case .needsAppUpdate: actions.onAppUpdate()
        case .broken: actions.onShowLog(game.id)
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
