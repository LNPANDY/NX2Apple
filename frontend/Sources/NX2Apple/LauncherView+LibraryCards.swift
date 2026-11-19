import SwiftUI
import NXCore
import NXLauncher

extension LauncherView {
    /// A game's card in the Recently played row (`columns` nil: left and right only) or the All games grid. `choose`, in the grid,
    /// replaces both the click and Return or A: the game becomes the hero and the library comes back (#1458). In the row a click
    /// selects and Return or A starts the hero's primary action.
    @ViewBuilder func collectionCard(_ game: LibraryGame, width: CGFloat, selected: Bool, in list: [LibraryGame], columns: Int?,
                                     choose: (() -> Void)? = nil) -> some View {
        let activate = { if let choose { if libraryInputAvailable { choose() } } else { activateLibraryCard(game) } }
        let card = LibraryGameCard(title: game.displayName(loc.lang), image: artwork[game.id],
                                   focus: displayed(game).artwork.focus(for: .thumbnail),
                                   state: LibraryArtworkState(game, building: m.running && activeBuildID == game.id),
                                   width: width, selected: selected,
                                   select: { if let choose { choose() } else { library.selectedID = game.id; keyboardCard = game.id } })
            .focusable()
            .focused($keyboardCard, equals: game.id)
            .background(LibraryCardKeyboardActions(enabled: keyboardCard == game.id && libraryInputAvailable, activate: activate))
            .padTarget("card." + game.id.uuidString, scope: "main", radius: 7, activate: activate,
                       adjust: { step in if !moveCollectionFocus(game, in: list, by: step), columns == nil { padFocus.move(dx: CGFloat(step), dy: 0) } },
                       vertical: { direction in columns.map { moveCollectionFocus(game, in: list, by: direction * $0) } ?? false })
            .environment(\.padRingStyle, .none)
            .onMoveCommand { direction in
                let step: Int
                switch direction {
                case .left: step = -1
                case .right: step = 1
                case .up: guard let columns else { return }; step = -columns
                case .down: guard let columns else { return }; step = columns
                default: return
                }
                _ = moveCollectionFocus(game, in: list, by: step)
            }
        if #available(macOS 14, *) { card.focusEffectDisabled() }
        else { card }
    }
    @discardableResult private func moveCollectionFocus(_ game: LibraryGame, in list: [LibraryGame], by delta: Int) -> Bool {
        guard libraryInputAvailable, let index = list.firstIndex(where: { $0.id == game.id }),
              list.indices.contains(index + delta) else { return false }
        let id = list[index + delta].id
        keyboardCard = id
        if padFocus.visible { padFocus.focusAfterScroll("card." + id.uuidString) }
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
