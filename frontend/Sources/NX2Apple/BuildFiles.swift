import SwiftUI
import Combine
import NXCore
import NXModel
import NXLauncher

/// What `BuildFilesStore` (#232) measures and removes in a game's build folder: every part `BuildFolder` knows (the extracted game files,
/// the shaders, the Xcode build, the caches), with the paths Free space never touches kept (the apps, the IPA, the game data archive,
/// the NSPs and keys) and the folder's logs, profile, saves and converted NSPs left in place. The same code as the Free space sheet.
enum BuildFiles {
    nonisolated static func measure(_ game: BuildFilesStore.Game) -> Int64 {
        BuildFolder.survey(game.folder, protecting: game.protecting).sizes.values.reduce(0, +)
    }

    nonisolated static func remove(_ game: BuildFilesStore.Game) throws -> Int64 {
        try BuildFolder.remove(Set(BuildFolderPart.allCases), in: game.folder, protecting: game.protecting, buildRunning: false)
    }

    /// The library's games that have a build folder, as the store measures them.
    @MainActor static func games(_ games: [LibraryGame], lang: Lang) -> [BuildFilesStore.Game] {
        games.compactMap { game in
            BuildFolder.location(for: game).map {
                BuildFilesStore.Game(id: game.id, name: game.displayName(lang), folder: $0, protecting: BuildFolder.protectedPaths(for: game))
            }
        }
    }

    /// The Manage menu's row title: "Remove build files (31 GB)" once the size is known.
    @MainActor static func menuTitle(_ store: BuildFilesStore, game: UUID, t: (String) -> String) -> String? {
        if let entry = store.entry(game) { return String(format: t("buildfiles.menu"), BuildFilesCard.bytes(entry.bytes)) }
        return store.isMeasured(game) ? nil : t("buildfiles.title")
    }
}

/// Keeps the store's sizes current (the library changed, a build was recorded) and shows its question as a sheet over the launcher,
/// with the controller's scope. Its own modifier keeps LauncherView's chain short.
private struct BuildFilesWiring: ViewModifier {
    @ObservedObject var store: BuildFilesStore
    @ObservedObject var library: GameLibrary
    let recorded: PassthroughSubject<Void, Never>
    let buildingID: UUID?
    let pad: PadFocus
    let scope: () -> String
    @EnvironmentObject var loc: Localizer

    func body(content: Content) -> some View {
        content
            .onAppear(perform: refresh)
            .onChange(of: library.games.map(\.id)) { _ in refresh() }
            .onReceive(recorded) { refresh() }
            .sheet(item: Binding(get: { store.confirmingEntry }, set: { if $0 == nil { store.confirming = nil } })) { entry in
                BuildFilesRemoveSheet(entry: entry, cancel: { store.confirming = nil },
                                      confirm: { store.remove(entry.id, building: entry.id == buildingID) })
                    .environmentObject(pad).environmentObject(loc)
            }
            .onChange(of: store.confirming) { id in pad.scope = id != nil ? "buildfiles" : scope() }
    }

    private func refresh() { store.refresh(BuildFiles.games(library.games, lang: loc.lang)) }
}

extension View {
    func buildFilesWiring(_ store: BuildFilesStore, library: GameLibrary, recorded: PassthroughSubject<Void, Never>, buildingID: UUID?,
                          pad: PadFocus, scope: @escaping () -> String) -> some View {
        modifier(BuildFilesWiring(store: store, library: library, recorded: recorded, buildingID: buildingID, pad: pad, scope: scope))
    }
}
