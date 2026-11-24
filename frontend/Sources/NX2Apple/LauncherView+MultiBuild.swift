import AppKit
import SwiftUI
import NXCore
import NXModel
import NXLauncher

/// Multi-engine build switching, per-engine launch menu, and Manage items for `LauncherView`.
extension LauncherView {
    /// Launches the requested engine's Mac `.app` without changing the game's persisted default build.
    func launchWithMacEngine(_ game: LibraryGame, upstream: EngineUpstreamKind) {
        guard !launching, let targeted = game.targetingMacBuild(upstream) else { return }
        primaryAction(targeted)
    }

    /// Persists the preferred default Mac engine build for `game`.
    func setDefaultMacEngine(_ game: LibraryGame, upstream: EngineUpstreamKind) {
        library.setPreferredMacUpstream(upstream, for: game.id)
    }

    /// Compact glass Menu placed beside Play on the hero when a game has 2+ Mac engine builds.
    @ViewBuilder func heroEngineMenu(_ game: LibraryGame) -> some View {
        let builds = game.sortedMacBuilds
        if game.isReady, builds.count > 1 {
            let active = game.activeMacUpstream(defaults: library.defaults) ?? builds.first?.upstream ?? .nxnative
            Menu {
                ForEach(builds, id: \.upstream) { build in
                    Button {
                        launchWithMacEngine(game, upstream: build.upstream)
                    } label: {
                        Label(String(format: loc.t("library.launchWithEngine"), build.upstream.displayName), systemImage: "play.fill")
                    }
                }
                Divider()
                ForEach(builds, id: \.upstream) { build in
                    Button {
                        setDefaultMacEngine(game, upstream: build.upstream)
                    } label: {
                        if build.upstream == active {
                            Label(String(format: loc.t("library.setDefaultEngine"), build.upstream.displayName), systemImage: "checkmark")
                        } else {
                            Text(String(format: loc.t("library.setDefaultEngine"), build.upstream.displayName))
                        }
                    }
                }
            } label: {
                heroEngineMenuLabel(title: active.displayName, symbol: "square.stack.3d.up.fill")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(launching || artworkEditor != nil)
            .opacity(!launching && artworkEditor == nil ? 1 : 0.45)
            .help(loc.t("library.switchBuild.menu"))
            .accessibilityLabel(loc.t("library.switchBuild.menu"))
            .accessibilityIdentifier("hero.engineMenu")
        }
    }

    /// The Manage menu's rows for a game, wired to the launcher's sheets and multi-engine actions.
    func manageItems(_ game: LibraryGame) -> [ManageItem] {
        let builtUpstreams = game.sortedMacBuilds.map(\.upstream)
        let activeUpstream = game.activeMacUpstream(defaults: library.defaults)
        return ManageItem.list(
            game: game,
            labels: loc.t,
            running: m.running,
            olderTools: toolsAge.older.contains(game.id),
            activeBuildID: activeBuildID,
            hasBuildFolder: !BuildFolder.locations(for: game).isEmpty,
            buildFilesTitle: BuildFiles.menuTitle(stores.buildFiles, game: game.id, t: loc.t),
            hasLog: GameLog.latest(titleID: game.titleID, appPath: game.appPath) != nil,
            deviceName: devices.deviceName(game.installedDevice),
            launching: launching,
            activeUpstream: activeUpstream,
            builtUpstreams: builtUpstreams,
            actions: ManageActions(
                rebuild: { configureBuild(game) },
                openOnDevice: { openOnDevice(game) },
                launchWithEngine: { upstream in launchWithMacEngine(game, upstream: upstream) },
                setDefaultEngine: { upstream in setDefaultMacEngine(game, upstream: upstream) },
                options: { optionsFor = game.id },
                saves: { savesFor = game.id },
                cheats: { cheatsFor = game.id },
                changeArtwork: { page = .library; openArtwork(game) },
                rename: { renaming = game },
                reveal: { if let path = game.revealTarget { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } },
                showLog: { if let log = GameLog.latest(titleID: game.titleID, appPath: game.appPath) { GameLog.show(log) } },
                removeBuildFiles: { stores.buildFiles.askForGame(game.id, building: m.running && activeBuildID == game.id) },
                remove: { removing = game },
                delete: { deleting = game }
            )
        )
    }

    func manageItems(for game: LibraryGame?) -> [ManageItem] { game.map(manageItems) ?? [] }
}
