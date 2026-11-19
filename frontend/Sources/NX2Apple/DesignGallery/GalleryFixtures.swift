import SwiftUI
import AppKit
import NXCore
import NXModel
import NXLauncher

/// Builds the GalleryScene catalogue with fixture data, for the state gallery (`--gallery`, GalleryApp.swift) and the design
/// captures (LauncherDesignCaptureTests), so both show the same views (LNPANDY/NX2Apple#1458, #1459). Nothing here reads or writes the
/// player's library, settings, engine or artwork, fetches anything or starts a process: each scene gets its own stores on a private
/// defaults suite, a runner that refuses to start any process, no release source, a library in a temporary folder and generated artwork.
/// Keep one alive while its views are shown: it owns the temporary folder and the defaults suites and removes them when released.
@MainActor final class GalleryFixtures {
    let lang: Lang
    let directory: URL
    private var suites: [String] = []

    init(lang: Lang = .en) {
        self.lang = lang
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("nx-gallery-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }   // the suites' own files, never the app's domain
    }

    /// Fictional games, so no title's art or name is shown.
    nonisolated static let games: [(titleID: String, name: String, hue: Double)] = [
        ("0100000000010000", "Marble Orchard", 0.58), ("0100000000020000", "Lantern Coast", 0.08),
        ("0100000000030000", "Paper Comet", 0.83), ("0100000000040000", "Tidewater Run", 0.47),
        ("0100000000050000", "Echo Garden", 0.30), ("0100000000060000", "Iron Meadow", 0.0),
        ("0100000000070000", "Night Ferry", 0.66), ("0100000000080000", "Saltglass", 0.13),
        ("0100000000090000", "Copper Lanterns", 0.04), ("01000000000A0000", "Glass Harbor", 0.52),
        ("01000000000B0000", "Moss and Mortar", 0.36), ("01000000000C0000", "Starling Road", 0.74),
        ("01000000000D0000", "Quiet Engines", 0.92), ("01000000000E0000", "Lighthouse Nine", 0.18),
    ]

    private var built: [String: AnyView] = [:]

    /// The gallery's live view of a scene: built once per scene and size, so redraws of the window keep its stores and state.
    func liveView(_ scene: GalleryScene, size: CGSize) -> AnyView {
        let key = "\(scene.id)-\(Int(size.width))x\(Int(size.height))"
        if let view = built[key] { return view }
        let view = self.view(scene, size: size)
        built[key] = view
        return view
    }

    func view(_ scene: GalleryScene, size: CGSize? = nil) -> AnyView {
        let (stores, defaults) = makeStores(widescreen: scene == .libraryWidescreen)
        let library = makeLibrary(count: scene.gameCount)
        let hero = library.games.first?.id
        let controls = ControlLayout(defaults: defaults)
        // the library's own artwork folder and no title list: the player's artwork and the network stay out of every scene
        let artworkStore = ArtworkStore(directory: library.artworkDirectory, titleList: directory.appendingPathComponent("no-titles.json"), fallbacks: [:])
        func launcher(_ page: LauncherPage, editor: Bool = false, search: String? = nil, olderTools: Set<UUID> = [],
                      assessments: [UUID: GameRefreshAssessment] = [:], launching: Bool = false, allGames: Bool = false,
                      category: SettingsCategory = .general, step: Int = 0) -> LauncherView {
            LauncherView(stores: stores, library: library, initialPage: page, initialBuildEditorOpen: editor, settingsCategory: category,
                         performStartupChecks: false, search: search, olderTools: olderTools, toolsAssessments: assessments,
                         controls: controls, qaLaunching: launching, artworkStore: artworkStore, allGamesOpen: allGames, buildStep: step)
        }
        func console(_ scenario: MockConsoleDriver.Scenario = .full, _ open: (MockConsoleDriver) -> Void = { _ in }) -> AnyView {
            let driver = MockConsoleDriver(scenario: scenario, lang: lang, animated: false)
            open(driver)
            return AnyView(ConsoleView(driver: driver, lang: lang))
        }
        let root: AnyView
        switch scene {
        case .libraryGames, .libraryFew, .libraryEmpty, .libraryNarrow, .libraryWidescreen:
            root = AnyView(launcher(.library))
        case .libraryEngineSyncing:
            stores.engineSync.showSyncingForGallery()
            root = AnyView(launcher(.library))
        case .libraryEngineUpdate:
            let assessments = hero.map { [$0: GameRefreshAssessment(heroState: .generalSync(fast: true), hasSpecificUpdate: false, versionLabel: "",
                                                                    canFastRefreshMac: true, canFastRefreshIOS: false, needsMissingImgGuideIOS: false,
                                                                    missingOriginalPackage: false, hasUsableSeed: true)] } ?? [:]
            root = AnyView(launcher(.library, olderTools: Set(library.games.prefix(3).map(\.id)), assessments: assessments))
        case .libraryNoticeWarning:
            library.skippedItems = [
                SkippedLibraryItem(path: "/Volumes/Games/update.nsp", name: "update.nsp", rootPath: "/Volumes/Games", reason: .orphanSupplement(titleID: "0100000000990800")),
                SkippedLibraryItem(path: "/Volumes/Games/game.rar", name: "game.rar", rootPath: "/Volumes/Games", reason: .unextractedArchiveOrSplit),
            ]
            root = AnyView(launcher(.library))
        case .libraryNoticeError:
            stores.engineSync.failure = BuildFailure(kind: .rosetta, gameName: nil)
            root = AnyView(launcher(.library))
        case .librarySwitch2:
            if var game = library.games.first {
                game.inputs["update"] = ["/Volumes/Games/\(game.name) Switch 2 Edition [\(game.titleID)].nsp"]
                library.upsert(game)
            }
            root = AnyView(launcher(.library))
        case .libraryGatekeeper:   // a built Mac game that is starting for the first time
            _ = makeMacApp(for: 0, in: library)
            root = AnyView(launcher(.library, launching: true))
        case .allGames:
            root = AnyView(launcher(.library, allGames: true))
        case .allGamesSearch:
            root = AnyView(launcher(.library, search: "Lantern"))
        case .allGamesNoResults:
            root = AnyView(launcher(.library, search: "Zebra Quest"))
        case .gameOptions:   // the launch options of a built widescreen game: the Picture row says it fills the screen natively
            let id = makeMacApp(for: 0, in: library)
            root = AnyView(LaunchOptionsView(m: stores.build, library: library, gameID: id ?? UUID(), widescreen: true)
                .environmentObject(stores.saveSettings).environmentObject(stores.players))
        case .addGame:
            root = AnyView(launcher(.builds, editor: true))
        case .gamePage:
            configureBuild(stores, library: library)
            root = AnyView(launcher(.builds, editor: true))
        case .wizardPlatform, .wizardInstall:
            configureBuild(stores, library: library)
            stores.build.target = BuildTarget.ios
            root = AnyView(launcher(.builds, editor: true, step: scene == .wizardPlatform ? 1 : 2))
        case .buildsIdle:
            root = AnyView(launcher(.builds))
        case .buildsRunning, .buildsQueued:
            configureBuild(stores, library: library)
            stores.build.buildingGame = true
            stores.build.running = true   // set first: the queue below waits for it and starts nothing
            stores.build.overallProgress = 0.42
            stores.build.stages = [Stage(id: 1, name: "Shaders", state: .running, detail: "20 / 50", percent: 40)]
            if scene == .buildsQueued {
                stores.queue.enqueue(library.games.dropFirst().prefix(4).map {
                    QueueEntry(game: $0, engineID: stores.engineSync.selection.engineID, target: BuildTarget.mac, batch: UUID(),
                               packageAfter: false, exportIPA: nil, exportFramework: nil)
                })
            }
            root = AnyView(launcher(.builds))
        case .buildsSetupHint:
            stores.dependencies.deps = [Dep(id: "xcode", name: "Xcode", hint: "", present: false, installCmd: [])]
            root = AnyView(launcher(.builds))
        case .buildFailed:
            configureBuild(stores, library: library)
            stores.build.failure = BuildFailure(kind: .diskFull, gameName: nil, detail: "12")
            root = AnyView(launcher(.builds, editor: true, step: 1))   // the last step, where the failure card shows
        case .buildFailure(let kind):
            configureBuild(stores, library: library)
            var failure = BuildFailure(kind: kind, gameName: kind == .a32Program ? Self.games[0].name : nil, detail: Self.detail(for: kind))
            if kind == .severalGames { failure.titleIDs = [Self.games[0].titleID, Self.games[1].titleID] }
            stores.build.failure = failure
            root = AnyView(launcher(.builds, editor: true, step: 1))
        case .settings:
            root = AnyView(launcher(.settings))
        case .settingsLibrary:
            root = AnyView(launcher(.settings, category: .library))
        case .settingsControls:
            root = AnyView(launcher(.settings, category: .controls))
        case .settingsTools:
            root = AnyView(launcher(.settings, category: .tools))
        case .settingsEngineError:
            stores.engineSync.failure = BuildFailure(kind: .engineOffline, gameName: nil)
            root = AnyView(launcher(.settings, category: .tools))
        case .deleteGame:
            let id = makeMacApp(for: 0, in: library)
            let game = library.games.first { $0.id == id } ?? LibraryGame(titleID: Self.games[0].titleID, name: Self.games[0].name)
            root = AnyView(DeleteGameSheet(game: game, shellRoot: directory.appendingPathComponent("shell").path, finished: { _ in }))
        case .controlsSheet:
            root = AnyView(ControlsView(layout: controls))
        case .controllersSheet:
            root = AnyView(ConsoleControllersSheet(driver: MockConsoleDriver(scenario: .controllers, lang: lang, animated: false), lang: lang, close: {}))
        case .onboarding(let scenario):
            root = AnyView(OnboardingDemoHost(scenario: scenario))
        case .consoleHome: root = console()
        case .consoleEmpty: root = console(.empty)
        case .consoleStarting: root = console(.starting)
        case .consoleGamePage: root = console { driver in driver.state.games.first.map { driver.openGamePage($0.id) } }
        case .consoleBuilds: root = console { $0.openBuilds() }
        case .consoleOptions: root = console { driver in driver.state.games.first.map { driver.openOptions($0.id) } }
        case .consoleControllers: root = console(.controllers) { $0.openControllers() }
        }
        let frame = size ?? scene.size
        return AnyView(root.environmentObject(PadFocus()).environmentObject(stores.localizer).launcherDropdownHost()
            .defaultAppStorage(defaults)   // @AppStorage in the views reads and writes the scene's suite, not the app's defaults
            .frame(width: frame.width, height: frame.height).background(LauncherPalette.background))
    }

    /// What a failure's message adds to its row, as a build would give it.
    private static func detail(for kind: BuildFailureKind) -> String? {
        switch kind {
        case .diskFull, .psoDiskFull: return "12"
        case .driveMissing: return "Games"
        case .noTitleID: return "/Volumes/Games/Unknown"
        default: return nil
        }
    }

    /// Stores with nothing of the player's: a private defaults suite, no process (GalleryProcessRunner), no release source.
    private func makeStores(widescreen: Bool = false) -> (LauncherStores, UserDefaults) {
        let suite = "nx.gallery." + UUID().uuidString
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite) ?? UserDefaults()
        let runner = GalleryProcessRunner()
        let stores = LauncherStores(localizer: Localizer(lang), runner: runner, gitCheckout: SystemGitCheckout(runner: runner),
                                    releases: GalleryReleases(), xcrun: "/usr/bin/false", volumesRoot: directory.appendingPathComponent("Volumes").path,
                                    defaults: defaults)
        let engine = directory.appendingPathComponent("engine-" + UUID().uuidString, isDirectory: true)
        let marker = engine.appendingPathComponent(EngineLayout.marker)
        try? FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data().write(to: marker)
        // a verified profile for every fixture game, the first one with a widescreen aspect in the widescreen scene
        for (index, game) in Self.games.enumerated() {
            let folder = engine.appendingPathComponent("dm/games/" + game.titleID, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let aspect = widescreen && index == 0 ? "screen_aspect\tauto\n" : ""
            try? "title_id\t\(game.titleID)\nname\t\(game.name)\n\(aspect)".write(to: folder.appendingPathComponent("game.tsv"), atomically: true, encoding: .utf8)
        }
        stores.repo.path = engine.path
        stores.dependencies.checked = true
        stores.dependencies.deps = [Dep(id: "xcode", name: "Xcode", hint: "", present: true, installCmd: [])]
        stores.deviceStore.checked = true
        return (stores, defaults)
    }

    private func makeLibrary(count: Int) -> GameLibrary {
        let folder = directory.appendingPathComponent("library-" + UUID().uuidString, isDirectory: true)
        let artwork = folder.appendingPathComponent("artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: artwork, withIntermediateDirectories: true)
        let library = GameLibrary(file: folder.appendingPathComponent("library.json"), artwork: artwork)
        library.applicationFolders = []
        guard count > 0 else { return library }
        for (index, game) in Self.games.prefix(count).enumerated() {
            Self.writeArtwork(for: game.titleID, hue: game.hue, in: artwork)
            var entry = LibraryGame(titleID: game.titleID, name: game.name)
            entry.inputs["base"] = ["/Volumes/Games/\(game.name) [\(game.titleID)].nsp"]
            entry.lastPlayed = Date(timeIntervalSince1970: 1_790_000_000 - Double(index) * 86_400)
            library.upsert(entry)
        }
        library.selectedID = library.games.first?.id
        return library
    }

    /// A stand-in Mac build of fixture game `index` (its executables point at /usr/bin/true, nothing runs), with a few launch options.
    private func makeMacApp(for index: Int, in library: GameLibrary) -> UUID? {
        let game = Self.games[index]
        let app = directory.appendingPathComponent("apps-" + UUID().uuidString + "/\(game.name).app")
        let dm = app.appendingPathComponent("Contents/Resources/dm")
        let fm = FileManager.default
        try? fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: dm, withIntermediateDirectories: true)
        for exe in ["nxnative", "dmhost"] {
            try? fm.createSymbolicLink(at: app.appendingPathComponent("Contents/MacOS/" + exe), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        }
        let info: [String: Any] = ["DMTitleID": game.titleID, "CFBundleDisplayName": game.name, "CFBundleExecutable": "nxnative",
                                   "CFBundleShortVersionString": "1.0.0", "CFBundleIdentifier": "org.nxnative.gallery." + UUID().uuidString]
        try? PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        let settings = [
            #"{"env": "DM_FULLSCREEN", "kind": "toggle", "label": "Full screen", "note": "", "default": "0", "section": "Game", "level": "basic"}"#,
            #"{"env": "DM_PICTURE_FIT", "kind": "choice", "label": "Picture", "note": "", "default": "fit", "section": "Game", "level": "basic", "options": [["fit", "Fit"], ["fill", "Fill"]]}"#,
            #"{"env": "DM_RUMBLE", "kind": "toggle", "label": "Rumble", "note": "", "default": "1", "section": "Game", "level": "basic"}"#,
            #"{"env": "DM_FPS_TARGET", "kind": "choice", "label": "Frame rate", "note": "", "default": "60", "section": "Performance", "level": "basic", "options": [["30", "30"], ["60", "60"]]}"#,
        ].joined(separator: ", ")
        try? #"{"game": "\#(game.titleID)", "settings": [\#(settings)]}"#.write(to: dm.appendingPathComponent("launcher.json"), atomically: true, encoding: .utf8)
        guard var entry = library.games.first(where: { $0.titleID == game.titleID }) else { return nil }
        entry.appPath = app.path
        entry.lastTarget = BuildTarget.mac
        library.upsert(entry)
        return entry.id
    }

    private func configureBuild(_ stores: LauncherStores, library: GameLibrary) {
        let game = Self.games[0]
        let package = directory.appendingPathComponent("\(game.name) [\(game.titleID)].nsp")
        try? Data().write(to: package)
        stores.build.target = BuildTarget.mac
        stores.build.outDir = "/Volumes/Games"
        stores.build.updateSlot("base") { $0.paths = [package.path] }
    }

    /// A banner and an icon for a fictional game: a soft two-tone gradient with a few shapes, drawn here, never fetched.
    private static func writeArtwork(for titleID: String, hue: Double, in folder: URL) {
        func image(_ size: NSSize, icon: Bool) -> Data? {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            guard let rep, let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            let rect = NSRect(origin: .zero, size: size)
            let top = NSColor(hue: hue, saturation: 0.55, brightness: 0.78, alpha: 1)
            let bottom = NSColor(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.75, brightness: 0.28, alpha: 1)
            NSGradient(starting: top, ending: bottom)?.draw(in: rect, angle: -70)
            for i in 0..<5 {
                let d = size.height * (0.25 + 0.12 * Double(i))
                let x = size.width * (0.15 + 0.18 * Double(i)), y = size.height * (0.2 + 0.11 * Double((i * 3) % 5))
                NSColor(hue: (hue + 0.5).truncatingRemainder(dividingBy: 1), saturation: 0.35, brightness: 0.95, alpha: 0.10 + 0.04 * Double(i)).setFill()
                NSBezierPath(ovalIn: NSRect(x: x - d / 2, y: y - d / 2, width: d, height: d)).fill()
            }
            if icon {
                NSColor.white.withAlphaComponent(0.85).setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: size.width * 0.3, dy: size.height * 0.3), xRadius: size.width * 0.08, yRadius: size.width * 0.08).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
            return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        }
        let id = titleID.uppercased()
        try? image(NSSize(width: 1280, height: 720), icon: false)?.write(to: folder.appendingPathComponent(id + ".jpg"))
        let iconFolder = folder.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: iconFolder, withIntermediateDirectories: true)
        try? image(NSSize(width: 256, height: 256), icon: true)?.write(to: iconFolder.appendingPathComponent("icon.jpg"))
    }
}
