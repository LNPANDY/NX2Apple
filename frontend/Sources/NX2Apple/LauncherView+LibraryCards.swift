import SwiftUI
import NXCore
import NXLauncher

extension LauncherView {
    @ViewBuilder func collectionCard(_ game: LibraryGame, width: CGFloat, selected: Bool, columns: Int) -> some View {
        let card = LibraryGameCard(title: game.displayName(loc.lang), image: artwork[game.id],
                                   focus: displayed(game).artwork.focus(for: .thumbnail),
                                   state: LibraryArtworkState(game, building: m.running && activeBuildID == game.id),
                                   width: width, selected: selected,
                                   select: { library.selectedID = game.id; keyboardCard = game.id })
            .focusable()
            .focused($keyboardCard, equals: game.id)
            .background(LibraryCardKeyboardActions(enabled: keyboardCard == game.id && libraryInputAvailable) { activateLibraryCard(game) })
            .padTarget("card." + game.id.uuidString, scope: "main", radius: 7, activate: { activateLibraryCard(game) },
                       adjust: { _ = moveCollectionFocus(game, by: $0) },
                       vertical: { moveCollectionFocus(game, by: $0 * columns) })
            .environment(\.padRingStyle, .none)
            .onMoveCommand { direction in
                let step: Int
                switch direction {
                case .left: step = -1
                case .right: step = 1
                case .up: step = -columns
                case .down: step = columns
                default: return
                }
                _ = moveCollectionFocus(game, by: step)
            }
        if #available(macOS 14, *) { card.focusEffectDisabled() }
        else { card }
    }
    @discardableResult private func moveCollectionFocus(_ game: LibraryGame, by delta: Int) -> Bool {
        guard libraryInputAvailable, let index = filteredGames.firstIndex(where: { $0.id == game.id }),
              filteredGames.indices.contains(index + delta) else { return false }
        let id = filteredGames[index + delta].id
        keyboardCard = id
        if padFocus.visible { padFocus.focused = "card." + id.uuidString }
        return true
    }
    func activateLibraryCard(_ game: LibraryGame) {
        guard libraryInputAvailable, !launching, !m.running || game.isReady else { return }
        library.selectedID = game.id
        primaryAction(game)
    }
}

/// Keyboard activation belongs to the focused card, independently of pointer selection or the previous hero.
private struct LibraryCardKeyboardActions: View {
    let enabled: Bool
    let activate: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            Button(action: activate) { EmptyView() }
                .keyboardShortcut(enabled ? KeyboardShortcut(.return, modifiers: []) : nil)
            Button(action: activate) { EmptyView() }
                .keyboardShortcut(enabled ? KeyboardShortcut(.space, modifiers: []) : nil)
        }.buttonStyle(.plain).hidden().accessibilityHidden(true)
    }
}
