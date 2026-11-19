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
    case libraryGames, libraryEmpty, libraryEngineUpdate, libraryNoticeWarning, libraryNoticeError
    case gamePage, buildsIdle, buildsRunning, buildFailed, settings, consoleHome

    var id: String { rawValue }
    /// The window size of every scene: the launcher's ideal width at a common laptop height.
    static let size = CGSize(width: 1280, height: 800)
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
    ]

    func view(_ scene: GalleryScene) -> AnyView {
        let stores = makeStores()
        let library = makeLibrary(empty: scene == .libraryEmpty)
        let hero = library.games.first?.id
        // the library's own artwork folder and no title list: the player's artwork and the network stay out of every scene
        let artworkStore = ArtworkStore(directory: library.artworkDirectory, titleList: directory.appendingPathComponent("no-titles.json"), fallbacks: [:])
        func launcher(_ page: LauncherPage, editor: Bool = false, olderTools: Set<UUID> = [], assessments: [UUID: GameRefreshAssessment] = [:]) -> LauncherView {
            LauncherView(stores: stores, library: library, initialPage: page, initialBuildEditorOpen: editor, settingsCategory: .general,
                         performStartupChecks: false, olderTools: olderTools, toolsAssessments: assessments, artworkStore: artworkStore)
        }
        let root: AnyView
        switch scene {
        case .libraryGames, .libraryEmpty:
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
        case .gamePage:
            configureBuild(stores, library: library)
            root = AnyView(launcher(.builds, editor: true))
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
        case .settings:
            root = AnyView(launcher(.settings))
        case .consoleHome:
            root = AnyView(ConsoleView(driver: MockConsoleDriver(scenario: .full, lang: lang, animated: false), lang: lang))
        }
        return AnyView(root.environmentObject(PadFocus()).environmentObject(stores.localizer).launcherDropdownHost()
            .frame(width: GalleryScene.size.width, height: GalleryScene.size.height).background(LauncherPalette.background))
    }

    private func makeStores() -> LauncherStores {
        let suite = "nx.gallery." + UUID().uuidString
        suites.append(suite)
        let stores = LauncherStores(localizer: Localizer(lang), defaults: UserDefaults(suiteName: suite) ?? .standard)
        let engine = directory.appendingPathComponent("engine-" + UUID().uuidString, isDirectory: true)
        let marker = engine.appendingPathComponent(EngineLayout.marker)
        try? FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data().write(to: marker)
        stores.repo.path = engine.path
        stores.dependencies.checked = true
        stores.dependencies.deps = [Dep(id: "xcode", name: "Xcode", hint: "", present: true, installCmd: [])]
        stores.deviceStore.checked = true
        return stores
    }

    private func makeLibrary(empty: Bool) -> GameLibrary {
        let folder = directory.appendingPathComponent("library-" + UUID().uuidString, isDirectory: true)
        let artwork = folder.appendingPathComponent("artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: artwork, withIntermediateDirectories: true)
        let library = GameLibrary(file: folder.appendingPathComponent("library.json"), artwork: artwork)
        library.applicationFolders = []
        guard !empty else { return library }
        for (index, game) in Self.games.enumerated() {
            Self.writeArtwork(for: game.titleID, hue: game.hue, in: artwork)
            var entry = LibraryGame(titleID: game.titleID, name: game.name)
            entry.inputs["base"] = ["/Volumes/Games/\(game.name) [\(game.titleID)].nsp"]
            entry.lastPlayed = Date(timeIntervalSince1970: 1_790_000_000 - Double(index) * 86_400)
            library.upsert(entry)
        }
        library.selectedID = library.games.first?.id
        return library
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
