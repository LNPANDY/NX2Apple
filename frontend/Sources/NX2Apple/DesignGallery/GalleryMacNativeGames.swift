import SwiftUI
import AppKit
import NXCore
import NXModel
import NXLauncher

/// The gallery's scenes of MacNativeGames (LNPANDY/NX2Apple#1473): a game it built (the MNG tag on the card and in the hero), the
/// recommendation on the Builds page for one of its five titles, the engine row of a title it does not maintain (MacNativeGames
/// dimmed in the pop-up), and its folder row with a newer version on GitHub. The engine is a stand-in folder with its two markers,
/// the version GitHub has is set directly: nothing runs, nothing is fetched. And the Download entry for it in Settings, and that
/// download part way.
extension GalleryFixtures {
    /// A title MacNativeGames maintains, for the scenes that need one. The game keeps the fixture's own name and cover.
    static let mngTitleID = "0100F2C0115B6000"
    /// A title MacNativeGames does not maintain, so `.mngBlocked` always shows the blocked state even with real covers.
    static let nonMNGTitleID = "0100152000022000"

    func macNativeGamesView(_ scene: GalleryDesktopScene, stores: LauncherStores, library: GameLibrary,
                            launcher: (GalleryLauncher) -> AnyView) -> AnyView {
        let build = stores.build
        let t = stores.localizer.t
        switch scene {
        case .mngLibrary:
            _ = makeMNGApp(for: 0, in: library)
            return launcher(GalleryLauncher())
        case .mngRecommend, .mngRecommendInstalled:
            if scene == .mngRecommendInstalled { build.macNativeGamesPath = makeMNGTree().path }
            configureMNGTitle(stores)
            return launcher(GalleryLauncher(page: .builds, editor: true))
        case .mngBlocked:
            build.macNativeGamesPath = makeMNGTree().path
            configureNonMNGTitle(stores)   // explicit non-MNG title ID (not one of the 12)
            return launcher(GalleryLauncher(page: .settings, category: .tools))
        case .mngUpdateAvailable:
            build.macNativeGamesPath = makeMNGTree(receipt: UpstreamVersionReceipt(commit: String(repeating: "a", count: 40), version: "2026-10-28",
                                                                                   installedAt: "2026-10-28")).path
            build.setUpstreamRemoteVersionForGallery(UpstreamRemoteInfo(kind: .macNativeGames, commit: String(repeating: "b", count: 40),
                                                                        version: "2026-11-18", date: "2026-11-18"))
            configureMNGTitle(stores)
            return launcher(GalleryLauncher(page: .settings, category: .tools))
        case .mngDownloadOffered:   // the engine pop-up's list in Settings with MacNativeGames not there: its Download entry
            let options = UpstreamBuilderRow.options(build, stores.localizer)
            return AnyView(LauncherDropdownList(options: options, selection: build.buildUpstream.rawValue, label: t("engine.title"),
                                                choose: { _ in }, close: {})
                .frame(width: 320).padding(DS.Space.xl).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
        case .mngDownloadingSettings:   // Download picked in Settings: the folder row says how far it is, with Cancel
            build.setUpstreamDownloadForGallery(.macNativeGames, .downloading(fraction: 0.42, progressText: "18.4 MB of 43.9 MB"))
            return launcher(GalleryLauncher(page: .settings, category: .tools))
        default:   // .mngDropdownDisabled: the engine pop-up's list for a title MacNativeGames does not maintain
            let options = [(value: EngineUpstreamKind.nxnative.rawValue, label: "nxnative"),
                           (value: EngineUpstreamKind.macNativeGames.rawValue, label: "MacNativeGames"),
                           (value: EngineUpstreamKind.nxkit.rawValue, label: t("nxkit.name"))]
            return AnyView(LauncherDropdownList(options: options, selection: EngineUpstreamKind.nxnative.rawValue, label: t("engine.title"),
                                                disabledValues: [EngineUpstreamKind.macNativeGames.rawValue], choose: { _ in }, close: {})
                .frame(width: 280).padding(DS.Space.xl).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
        }
    }

    /// A stand-in MacNativeGames checkout: its two markers and, when given, the version receipt an install writes.
    private func makeMNGTree(receipt: UpstreamVersionReceipt? = nil) -> URL {
        let tree = directory.appendingPathComponent("MacNativeGames-" + UUID().uuidString, isDirectory: true)
        let fm = FileManager.default
        try? fm.createDirectory(at: tree.appendingPathComponent("games/totk"), withIntermediateDirectories: true)
        fm.createFile(atPath: tree.appendingPathComponent("build_app.py").path, contents: Data("# stand-in\n".utf8))
        if let receipt { try? UpstreamVersion.writeReceipt(receipt, to: tree) }
        return tree
    }

    /// The build's game is fixture game 0 under a title MacNativeGames maintains, nxnative chosen.
    private func configureMNGTitle(_ stores: LauncherStores) {
        let game = catalog[0]
        let package = directory.appendingPathComponent("\(game.name) [\(Self.mngTitleID)].nsp")
        try? Data().write(to: package)
        stores.build.target = BuildTarget.mac
        stores.build.outDir = "/Volumes/Games"
        stores.build.updateSlot("base") { $0.paths = [package.path] }
        stores.build.selectUpstream(.nxnative)
    }

    /// The build's game is fixture game 0 under a title MacNativeGames does not maintain, so MNG stays blocked.
    private func configureNonMNGTitle(_ stores: LauncherStores) {
        let game = catalog[0]
        let package = directory.appendingPathComponent("\(game.name) [\(Self.nonMNGTitleID)].nsp")
        try? Data().write(to: package)
        stores.build.target = BuildTarget.mac
        stores.build.outDir = "/Volumes/Games"
        stores.build.updateSlot("base") { $0.paths = [package.path] }
        stores.build.selectUpstream(.nxnative)
    }

    /// A stand-in Mac app MacNativeGames built of fixture game `index` (DMUpstream says so, its executable points at /usr/bin/true).
    private func makeMNGApp(for index: Int, in library: GameLibrary) -> UUID? {
        let game = catalog[index]
        let app = directory.appendingPathComponent("mng-apps-" + UUID().uuidString + "/\(game.name).app")
        let fm = FileManager.default
        try? fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try? fm.createSymbolicLink(at: app.appendingPathComponent("Contents/MacOS/Game"), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        let info: [String: Any] = ["DMTitleID": game.titleID, "DMUpstream": "macnativegames", "CFBundleDisplayName": game.name,
                                   "CFBundleName": game.name, "CFBundleExecutable": "Game", "CFBundleShortVersionString": "1.0.0",
                                   "CFBundleIdentifier": "org.macnativegames.gallery." + UUID().uuidString.lowercased()]
        try? PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        guard var entry = library.games.first(where: { $0.titleID == game.titleID }) else { return nil }
        entry.appPath = app.path
        entry.lastTarget = BuildTarget.mac
        library.upsert(entry)
        return entry.id
    }
}
