import SwiftUI
import AppKit
import NXCore
import NXLauncher

/// Console mode's gallery scenes (GalleryScene.consoleScenes): the preview driver (MockConsoleDriver) on the gallery's own games, so
/// the covers are the player's when the toolbar says Covers: Real and the generated ones otherwise, never a list of its own.
extension GalleryFixtures {
    /// The catalogue's game behind a console game: the same library entry the desktop scenes use.
    private func libraryEntry(_ index: Int) -> LibraryGame? {
        guard catalog.indices.contains(index) else { return nil }
        let game = catalog[index]
        guard let cover = game.cover else { return LibraryGame(titleID: game.titleID, name: game.name) }
        var entry = LibraryGame(id: cover.id, titleID: cover.titleID, name: cover.name)
        entry.titleNames = cover.titleNames
        entry.customName = cover.customName
        entry.artwork = cover.artwork
        return entry
    }

    private func icon(_ entry: LibraryGame) -> NSImage? {
        NSImage(contentsOf: artworkFolder.appendingPathComponent(entry.titleID.uppercased()).appendingPathComponent("icon.jpg"))
    }

    /// The preview driver with the gallery's games: their names, covers, large art and icons, in the mock's states.
    func consoleDriver(_ scenario: MockConsoleDriver.Scenario = .full) -> MockConsoleDriver {
        let driver = MockConsoleDriver(scenario: scenario, lang: lang, animated: false)
        for i in driver.state.games.indices {
            guard let index = Int(driver.state.games[i].id.dropFirst("demo.".count)), let entry = libraryEntry(index) else { continue }
            driver.state.games[i].title = entry.displayName(lang)
            driver.state.games[i].artwork = GameLibrary.artwork(for: entry, slot: .thumbnail, repo: "", banners: artworkFolder, maxPixel: ArtworkImages.cardPixels)
            driver.state.games[i].artworkFocus = entry.artwork.focus(for: .thumbnail)
            driver.state.games[i].hero = GameLibrary.artwork(for: entry, slot: .hero, repo: "", banners: artworkFolder)
            driver.state.games[i].heroFocus = entry.artwork.focus(for: .hero)
            driver.state.games[i].icon = icon(entry)
        }
        driver.state.builds = ConsoleBuilds()
        return driver
    }

    /// A queue row for the gallery's game `index`.
    func queueRow(_ driver: MockConsoleDriver, _ index: Int, status: String, active: Bool = false, progress: Double? = nil,
                          outcome: ConsoleBuilds.ArtworkOutcome? = nil) -> ConsoleBuilds.QueueRow {
        let game = driver.state.games.first { $0.id == "demo.\(index)" }
        return ConsoleBuilds.QueueRow(id: UUID(), name: game?.title ?? "Game \(index)", statusKey: status, platformKey: "build.mac",
                                      icon: game?.icon, outcome: outcome, artwork: game?.artwork, active: active, progress: progress)
    }

    func builds(_ driver: MockConsoleDriver, _ kind: String) -> ConsoleBuilds {
        switch kind {
        case "running":
            return ConsoleBuilds(running: true, title: "", queue: [queueRow(driver, 3, status: "queue.status.running", active: true, progress: 0.4)])
        case "queued":
            return ConsoleBuilds(running: true, title: "", queue: [queueRow(driver, 3, status: "queue.status.running", active: true, progress: 0.4),
                                                                   queueRow(driver, 5, status: "queue.status.queued"), queueRow(driver, 9, status: "queue.status.queued")])
        case "finished":
            return ConsoleBuilds(queue: [queueRow(driver, 3, status: "queue.status.done", outcome: .success), queueRow(driver, 5, status: "queue.status.done", outcome: .success)])
        case "failed":
            return ConsoleBuilds(queue: [queueRow(driver, 3, status: "queue.status.failed", progress: 0.63, outcome: .failure), queueRow(driver, 5, status: "queue.status.queued")])
        default:
            return ConsoleBuilds()
        }
    }

    /// The console view with a pad focus the scene can show (`focus`: shown once the page has drawn, as after a press).
    func console(_ driver: MockConsoleDriver, focus: String? = nil) -> AnyView {
        AnyView(GalleryConsoleHost(driver: driver, lang: lang, focus: focus))
    }

    func consoleView(_ scene: GalleryScene) -> AnyView {
        let driver = consoleDriver(scene == .consoleEmpty ? .empty : scene == .consoleStarting || scene == .consoleStartingCloud ? .starting
                                   : scene == .consoleControllers || scene == .consoleControllersAssigned ? .controllers : .full)
        let first = "demo.0"   // ready, never played: the mock's first game
        let played = "demo.2"  // ready, played yesterday
        let unbuilt = "demo.3"
        func page(_ id: String, _ tab: ConsoleGameTab, _ change: (inout ConsoleGame) -> Void = { _ in }) {
            driver.openGamePage(id)
            driver.state.gameTab = tab
            if let i = driver.state.games.firstIndex(where: { $0.id == id }) { change(&driver.state.games[i]) }
        }
        func options(_ values: [String: String] = [:], _ change: (inout ConsoleGame) -> Void = { _ in }) {
            if let i = driver.state.games.firstIndex(where: { $0.id == played }) {
                change(&driver.state.games[i])
                for (key, value) in values { driver.state.games[i].values[key] = value }
            }
            driver.openOptions(played)
        }
        switch scene {
        case .consoleHomeBuilding:
            driver.state.builds = builds(driver, "queued")
        case .consoleHomeTV, .consoleHome, .consoleEmpty:
            break
        case .consoleAllGames:
            driver.openAllGames()
            return console(driver, focus: "console.lib." + (driver.state.libraryGames.first?.id ?? ""))
        case .consoleHomeAttention:   // in the one row, its chip says what it needs (#1458)
            driver.focus(unbuilt)
        case .consoleHomeAllGames:   // the row's last tile
            if let last = driver.state.homeOrder.last { driver.focus(last) }
            return console(driver, focus: ConsoleHome.allGamesID)
        case .consoleGamePage: page(played, .overview)
        case .consoleGameOverviewEmpty: page(unbuilt, .overview)
        case .consoleGameSaves: page(played, .saves) { $0.lastSave = driver.state.time.addingTimeInterval(-7200) }
        case .consoleGameSavesEmpty: page(first, .saves) { $0.save = nil; $0.lastSave = nil }
        case .consoleGameBuild: page(played, .build)
        case .consoleGameBuildEmpty: page(unbuilt, .build)
        case .consoleGameCheats: page(played, .cheats)
        case .consoleGameCheatsEmpty: page(played, .cheats) { $0.cheats = nil }
        case .consoleOptions: options()
        case .consoleOptionsMin: options(["DM_RENDER_SCALE": "0.5", "DM_FPS_TARGET": "30", "DM_LANG": "en"])
        case .consoleOptionsMax: options(["DM_RENDER_SCALE": "2", "DM_FPS_TARGET": "60", "DM_LANG": "ja"])
        case .consoleOptionsStepperFocus:
            options()
            return console(driver, focus: "console.option.DM_FPS_TARGET")
        case .consoleOptionsNavFocus:
            options()
            return console(driver, focus: "console.options.gamePad")
        case .consoleOptionsSingleLanguage:
            options { game in
                game.settings = game.settings.map { setting in
                    guard setting.env == "DM_LANG" else { return setting }
                    return LaunchSetting(env: setting.env, kind: setting.kind, label: setting.label, note: setting.note, def: "en", section: setting.section,
                                         options: [["en", L10n.string("console.english", lang)]], min: nil, max: nil, step: nil, on: nil, off: nil)
                }
            }
        case .consoleBuilds: driver.state.builds = builds(driver, "running"); driver.openBuilds()
        case .consoleBuildsQueued: driver.state.builds = builds(driver, "queued"); driver.openBuilds()
        case .consoleBuildsFinished: driver.state.builds = builds(driver, "finished"); driver.openBuilds()
        case .consoleBuildsFailed: driver.state.builds = builds(driver, "failed"); driver.openBuilds()
        case .consoleBuildsEmpty: driver.openBuilds()
        case .consoleControllers: break   // the scenario opens the page with player 3 waiting for a button
        case .consoleControllersAssigned:
            // what a press on the third controller does while player 3 waits (the preview driver's assignment, no control in the page)
            driver.assignPlayer(controllerID: "pad.3", player: 3)
        case .consoleSearch:
            driver.openSearch()
            driver.typeSearch(String((driver.state.games.first?.title ?? "a").prefix(3)))
        case .consoleQuickMenu: driver.openQuickMenu()
        case .consoleStarting: break
        case .consoleStartingCloud: driver.state.starting = .cloudSave(long: true)
        default: break
        }
        return console(driver)
    }
}

/// Hosts the console for a scene and, for a focus scene, shows the pad focus on one target once the page has drawn.
private struct GalleryConsoleHost: View {
    @ObservedObject var driver: MockConsoleDriver
    let lang: Lang
    let focus: String?
    @StateObject private var pad = PadFocus()
    var body: some View {
        ConsoleView(driver: driver, lang: lang, padFocus: pad)
            .onAppear {
                guard let focus else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { pad.show(default: focus); pad.focused = focus }
            }
    }
}
