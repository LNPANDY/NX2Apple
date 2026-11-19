import SwiftUI
import AppKit
import NXCore
import NXModel
import NXLauncher

/// Named states of the launcher's main window with fixture data, for the design captures (LauncherDesignCaptureTests) and a
/// later state gallery in the app (LNPANDY/NX2Apple#1458). Nothing here reads the player's library, settings or artwork, fetches
/// anything or runs the engine: each scene gets its own stores on a private defaults suite and a library in a temporary folder,
/// with generated artwork. Not shown anywhere in the app yet.
enum GalleryScene: String, CaseIterable, Identifiable {
    /// The library: more games than the Recently played row holds (Show all), fewer (no Show all), none, the narrowest window,
    /// each notice tone, and the All games grid.
    case libraryGames, libraryFew, libraryEmpty, libraryNarrow, libraryEngineUpdate, libraryNoticeWarning, libraryNoticeError, libraryWidescreen, allGames
    /// The build wizard's steps (game files, platform, install), the launch options, the Builds page, each part of Settings, the console.
    case gamePage, wizardPlatform, wizardInstall, gameOptions, buildsIdle, buildsRunning, buildFailed
    case settings, settingsLibrary, settingsControls, settingsTools, consoleHome

    var id: String { rawValue }
    /// The launcher's ideal width at a common laptop height, and its minimum window for the narrow scene.
    static let size = CGSize(width: 1280, height: 800)
    var size: CGSize {
        switch self {
        case .libraryNarrow: return CGSize(width: 900, height: 680)
        case .gameOptions: return CGSize(width: 680, height: 720)   // a sheet
        default: return Self.size
        }
    }
    /// How many of the fixture games the scene's library holds.
    var gameCount: Int {
        switch self {
        case .libraryEmpty: return 0
        case .libraryFew: return 6
        default: return GalleryFixtures.games.count
        }
    }
}

/// Builds the scenes. Keep one alive while its view is shown: it owns the temporary folder and removes it when released.
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
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
    }

    /// Fictional games, so no title's art or name is shown.
    static let games: [(titleID: String, name: String, hue: Double)] = [
        ("0100000000010000", "Marble Orchard", 0.58), ("0100000000020000", "Lantern Coast", 0.08),
        ("0100000000030000", "Paper Comet", 0.83), ("0100000000040000", "Tidewater Run", 0.47),
        ("0100000000050000", "Echo Garden", 0.30), ("0100000000060000", "Iron Meadow", 0.0),
        ("0100000000070000", "Night Ferry", 0.66), ("0100000000080000", "Saltglass", 0.13),
        ("0100000000090000", "Copper Lanterns", 0.04), ("01000000000A0000", "Glass Harbor", 0.52),
        ("01000000000B0000", "Moss and Mortar", 0.36), ("01000000000C0000", "Starling Road", 0.74),
        ("01000000000D0000", "Quiet Engines", 0.92), ("01000000000E0000", "Lighthouse Nine", 0.18),
    ]

    func view(_ scene: GalleryScene) -> AnyView {
        let stores = makeStores(widescreen: scene == .libraryWidescreen)
        let library = makeLibrary(count: scene.gameCount)
        let hero = library.games.first?.id
        // the library's own artwork folder and no title list: the player's artwork and the network stay out of every scene
        let artworkStore = ArtworkStore(directory: library.artworkDirectory, titleList: directory.appendingPathComponent("no-titles.json"), fallbacks: [:])
        func launcher(_ page: LauncherPage, editor: Bool = false, olderTools: Set<UUID> = [], assessments: [UUID: GameRefreshAssessment] = [:],
                      allGames: Bool = false, category: SettingsCategory = .general, step: Int = 0) -> LauncherView {
            LauncherView(stores: stores, library: library, initialPage: page, initialBuildEditorOpen: editor, settingsCategory: category,
                         performStartupChecks: false, olderTools: olderTools, toolsAssessments: assessments, artworkStore: artworkStore,
                         allGamesOpen: allGames, buildStep: step)
        }
        let root: AnyView
        switch scene {
        case .libraryGames, .libraryFew, .libraryEmpty, .libraryNarrow, .libraryWidescreen:
            root = AnyView(launcher(.library))
        case .allGames:
            root = AnyView(launcher(.library, allGames: true))
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
        case .gamePage:
            configureBuild(stores, library: library)
            root = AnyView(launcher(.builds, editor: true))
        case .wizardPlatform, .wizardInstall:
            configureBuild(stores, library: library)
            stores.build.target = BuildTarget.ios
            root = AnyView(launcher(.builds, editor: true, step: scene == .wizardPlatform ? 1 : 2))
        case .buildsIdle:
            root = AnyView(launcher(.builds))
        case .buildsRunning:
            configureBuild(stores, library: library)
            stores.build.buildingGame = true
            stores.build.running = true
            stores.build.overallProgress = 0.42
            stores.build.stages = [Stage(id: 1, name: "Shaders", state: .running, detail: "20 / 50", percent: 40)]
            root = AnyView(launcher(.builds))
        case .buildFailed:
            configureBuild(stores, library: library)
            stores.build.failure = BuildFailure(kind: .diskFull, gameName: nil, detail: "12")
            root = AnyView(launcher(.builds, editor: true))
        case .gameOptions:   // the launch options of a built widescreen game: the Picture row says it fills the screen natively
            let id = makeMacApp(for: 0, in: library)
            root = AnyView(LaunchOptionsView(m: stores.build, library: library, gameID: id ?? UUID(), widescreen: true)
                .environmentObject(stores.saveSettings).environmentObject(stores.players))
        case .settings:
            root = AnyView(launcher(.settings))
        case .settingsLibrary:
            root = AnyView(launcher(.settings, category: .library))
        case .settingsControls:
            root = AnyView(launcher(.settings, category: .controls))
        case .settingsTools:
            root = AnyView(launcher(.settings, category: .tools))
        case .consoleHome:
            root = AnyView(ConsoleView(driver: MockConsoleDriver(scenario: .full, lang: lang, animated: false), lang: lang))
        }
        return AnyView(root.environmentObject(PadFocus()).environmentObject(stores.localizer).launcherDropdownHost()
            .frame(width: scene.size.width, height: scene.size.height).background(LauncherPalette.background))
    }

    private func makeStores(widescreen: Bool = false) -> LauncherStores {
        let suite = "nx.gallery." + UUID().uuidString
        suites.append(suite)
        let stores = LauncherStores(localizer: Localizer(lang), defaults: UserDefaults(suiteName: suite) ?? .standard)
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
        return stores
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
