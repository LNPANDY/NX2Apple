import AppKit
import SwiftUI
import NXCore
import NXLauncher

extension LauncherView {
    @ViewBuilder func collectionCard(_ game: LibraryGame, width: CGFloat, selected: Bool, columns: Int) -> some View {
        let building = m.running && activeBuildID == game.id
        let state = library.artworkState(for: game, building: building)
        let card = LibraryGameCard(title: game.displayName(loc.lang), image: artwork[game.id],
                                   focus: displayed(game).artwork.focus(for: .thumbnail),
                                   state: state,
                                   width: width, selected: selected,
                                   select: { library.selectedID = game.id; keyboardCard = game.id },
                                   doubleClick: { activateLibraryCard(game) },
                                   contextMenuItems: { cardContextItems(game, ready: state.mac) })
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
    @discardableResult func moveCollectionFocus(_ game: LibraryGame, by delta: Int) -> Bool {
        guard libraryInputAvailable, let index = filteredGames.firstIndex(where: { $0.id == game.id }),
              filteredGames.indices.contains(index + delta) else { return false }
        let id = filteredGames[index + delta].id
        keyboardCard = id
        if padFocus.visible { padFocus.focusAfterScroll("card." + id.uuidString) }
        return true
    }
    func activateLibraryCard(_ game: LibraryGame) {
        guard libraryInputAvailable, !launching, !m.running || game.isReady else { return }
        library.selectedID = game.id
        primaryAction(game)
    }

    private func cardContextItems(_ game: LibraryGame, ready: Bool) -> [ManageItem] {
        let canAct = !launching && (!m.running || ready)
        let primaryTitle: String
        let primarySymbol: String
        if ready {
            primaryTitle = loc.t("library.play")
            primarySymbol = "play.fill"
        } else if game.onDevice {
            primaryTitle = String(format: loc.t("dev.open"), devices.deviceName(game.installedDevice))
            primarySymbol = "iphone"
        } else {
            primaryTitle = loc.t("library.setUpBuild")
            primarySymbol = "hammer.fill"
        }
        var items = [
            ManageItem(id: "ctx.primary", symbol: primarySymbol, title: primaryTitle, enabled: canAct) {
                activateLibraryCard(game)
            }
        ]
        let canRebuild = !m.running && (!game.inputs["base", default: []].isEmpty || game.inputs[GameLibrary.folderInput] != nil)
        items.append(ManageItem(
            id: "ctx.rebuild",
            symbol: "arrow.clockwise",
            title: loc.t(toolsAge.older.contains(game.id) ? "library.rebuild" : "library.buildAgain"),
            enabled: canRebuild,
            separatorBefore: true
        ) {
            configureBuild(game)
        })
        items.append(ManageItem(id: "ctx.options", symbol: "slider.horizontal.3", title: loc.t("launch.title")) {
            optionsFor = game.id
        })
        items.append(ManageItem(id: "ctx.artwork", symbol: "photo", title: loc.t("library.changeArtwork")) {
            page = .library; openArtwork(game)
        })
        if let revealPath = game.revealTarget {
            items.append(ManageItem(id: "ctx.reveal", symbol: "folder", title: loc.t("install.reveal")) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: revealPath)])
            })
        }
        if ready {
            items.append(ManageItem(
                id: "ctx.log",
                symbol: "doc.text.magnifyingglass",
                title: loc.t("library.showLog")
            ) {
                if let log = GameLog.latest(titleID: game.titleID, appPath: game.appPath) { GameLog.show(log) }
            })
        }
        return items
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
