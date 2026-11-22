import AppKit
import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher
@testable import NXModel

@MainActor final class EngineHubAndTunedBadgeTests: XCTestCase {
    private var temporary: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("engine-hub-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporary)
    }

    func testSupportedGamesTunedFilterAndSearchCoverAllSpecializedEngines() {
        let games = [
            SupportedGame(titleID: "0400486024DEC000", name: "The Legend of Zelda: Ocarina of Time", edition: .switch2, version: "1.1.1", notes: ""),
            SupportedGame(titleID: "0400C3F00006E000", name: "Mario Kart World", edition: .switch2, version: "1.8.0", notes: ""),
            SupportedGame(titleID: "01007EF00011E000", name: "The Legend of Zelda: Breath of the Wild", edition: .switch1, version: "1.6.0", notes: ""),
            SupportedGame(titleID: "0100152000022000", name: "Mario Kart 8 Deluxe", edition: .switch1, version: "3.0.3", notes: ""),
        ]

        let tunedOnly = SupportedGamesSheet.filterGames(
            games,
            upstreamFilter: .tuned,
            needle: "",
            ownedName: { _ in "" },
            improvedName: { _ in "" }
        )
        XCTAssertEqual(tunedOnly.map(\.titleID), ["0400486024DEC000", "0400C3F00006E000", "01007EF00011E000"])

        XCTAssertEqual(SupportedGamesSheet.tunedEngines(for: games[0]), [.kidWithSword, .macNativeGames])
        XCTAssertEqual(SupportedGamesSheet.tunedEngines(for: games[1]), [.noLagKart])
        XCTAssertEqual(SupportedGamesSheet.tunedEngines(for: games[2]), [.macNativeGames])
        XCTAssertEqual(SupportedGamesSheet.tunedEngines(for: games[3]), [])

        // Search by "tuned", "特调", and fork display names.
        XCTAssertTrue(SupportedGamesSheet.matchesSearch(games[0], needle: "Kid with Sword", ownedName: ""))
        XCTAssertTrue(SupportedGamesSheet.matchesSearch(games[1], needle: "No Lag Kart", ownedName: ""))
        XCTAssertTrue(SupportedGamesSheet.matchesSearch(games[1], needle: "tuned", ownedName: ""))
        XCTAssertTrue(SupportedGamesSheet.matchesSearch(games[1], needle: "特调", ownedName: ""))
        XCTAssertFalse(SupportedGamesSheet.matchesSearch(games[3], needle: "tuned", ownedName: ""))
    }

    func testBuildSelectedSheetRowTagsAndTunedHints() {
        XCTAssertEqual(
            BuildSelectedSheet.rowEngineTag(for: "0400486024DEC000", selectedTarget: BuildTarget.ios, activeUpstream: .kidWithSword),
            .kidWithSword
        )
        XCTAssertEqual(
            BuildSelectedSheet.rowEngineTag(for: "0400C3F00006E000", selectedTarget: BuildTarget.mac, activeUpstream: .noLagKart),
            .noLagKart
        )
        XCTAssertEqual(
            BuildSelectedSheet.rowEngineTag(for: "0400C3F00006E000", selectedTarget: BuildTarget.ios, activeUpstream: .noLagKart),
            .nxnative
        )
        XCTAssertNil(
            BuildSelectedSheet.rowEngineTag(for: "0400486024DEC000", selectedTarget: BuildTarget.mac, activeUpstream: .nxnative)
        )
        XCTAssertEqual(
            BuildSelectedSheet.rowAvailableTunedEngines(for: "0400486024DEC000", activeUpstream: .nxnative),
            [.kidWithSword, .macNativeGames]
        )
        XCTAssertEqual(
            BuildSelectedSheet.rowAvailableTunedEngines(for: "0400C3F00006E000", activeUpstream: .nxnative),
            [.noLagKart]
        )
        XCTAssertEqual(
            BuildSelectedSheet.rowAvailableTunedEngines(for: "0100152000022000", activeUpstream: .nxnative),
            []
        )
    }

    func testLibraryArtworkStateDistinguishesBuiltTunedEngineFromAvailableTunedEngine() {
        let builtKWS = LibraryArtworkState(
            mac: true,
            ios: false,
            attention: .none,
            macUpstream: .kidWithSword,
            tunedEngines: [.kidWithSword, .macNativeGames]
        )
        XCTAssertEqual(builtKWS.builtTunedEngine, .kidWithSword)
        XCTAssertTrue(builtKWS.hasTunedEngine)

        let generalBuildWithTunedAvailable = LibraryArtworkState(
            mac: true,
            ios: false,
            attention: .none,
            macUpstream: .nxnative,
            tunedEngines: [.noLagKart]
        )
        XCTAssertNil(generalBuildWithTunedAvailable.builtTunedEngine)
        XCTAssertTrue(generalBuildWithTunedAvailable.hasTunedEngine)

        let plainGame = LibraryArtworkState(mac: true, ios: false, attention: .none, macUpstream: .nxnative, tunedEngines: [])
        XCTAssertNil(plainGame.builtTunedEngine)
        XCTAssertFalse(plainGame.hasTunedEngine)
    }

    func testCaptureEngineHubScreenshotsWhenRequested() throws {
        guard let outDir = ProcessInfo.processInfo.environment["NX_CAPTURE_ENGINE_HUB"], !outDir.isEmpty else {
            return
        }
        let outURL = URL(fileURLWithPath: outDir, isDirectory: true)
        try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)

        func renderPNG<V: View>(_ view: V, size: CGSize, file: String) throws {
            let wasStatic = LauncherGlass.forceStatic
            LauncherGlass.forceStatic = true
            defer { LauncherGlass.forceStatic = wasStatic }
            let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).launcherAppearance())
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(
                contentRect: NSRect(origin: NSPoint(x: -100_000, y: -100_000), size: size),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1)
            window.contentView = host
            window.orderFront(nil)
            defer { window.orderOut(nil); window.contentView = nil; window.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.35))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                XCTFail("Failed to allocate bitmap rep for \(file)")
                return
            }
            host.cacheDisplay(in: host.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else {
                XCTFail("Failed to encode PNG for \(file)")
                return
            }
            try png.write(to: outURL.appendingPathComponent(file))
        }

        let fakeMNG = temporary.appendingPathComponent("mng-shot", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeMNG.appendingPathComponent("games/totk"), withIntermediateDirectories: true)
        try Data("# mng\n".utf8).write(to: fakeMNG.appendingPathComponent("build_app.py"))
        let fakeKWS = temporary.appendingPathComponent("kws-shot", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeKWS.appendingPathComponent("dm/tools/nx_extract"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fakeKWS.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try Data("// cs\n".utf8).write(to: fakeKWS.appendingPathComponent("dm/tools/nx_extract/Program.cs"))
        try Data("# \"--progress\" \"--work-dir\" \"--bundle-id\"\n".utf8).write(to: fakeKWS.appendingPathComponent("scripts/build_ipa_from_nsp.py"))
        let ootFile = temporary.appendingPathComponent("Ocarina of Time [0400486024DEC000].nsp")
        try Data([0]).write(to: ootFile)

        for lang in [Lang.en, Lang.zh] {
            let suffix = lang.code
            let pad = PadFocus()
            let loc = Localizer(lang)

            // 1. Grouped Engine Dropdown Guide (with OoT recommendation banner at top)
            let d1 = TestDefaults.make("shot-dropdown-\(suffix)")
            let s1 = LauncherStores(defaults: d1)
            s1.localizer.lang = lang
            s1.build.upstreamChanged = {}
            s1.build.macNativeGamesPath = fakeMNG.path
            s1.build.kidWithSwordPath = fakeKWS.path
            s1.build.buildUpstream = .nxnative
            s1.build.updateSlot("base") { $0.paths = [ootFile.path] }
            try renderPNG(
                ZStack {
                    LauncherPalette.background
                    EngineDropdownPanel(build: s1.build, maxHeight: 560, close: {})
                        .frame(width: EngineSwitcherCard.panelWidth)
                        .background(LauncherPalette.surface, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(LauncherPalette.secondaryBorder))
                        .padding(24)
                }
                .environmentObject(loc)
                .environmentObject(pad),
                size: CGSize(width: 560, height: 600),
                file: "01_engine_dropdown_\(suffix).png"
            )

            // 2. EngineSwitcherCard recommendation + Kid with Sword iOS Standalone InstallCard
            let d2 = TestDefaults.make("shot-switcher-\(suffix)")
            let s2 = LauncherStores(defaults: d2)
            s2.localizer.lang = lang
            s2.build.upstreamChanged = {}
            s2.build.kidWithSwordPath = fakeKWS.path
            s2.build.updateSlot("base") { $0.paths = [ootFile.path] }
            s2.build.buildUpstream = .nxnative
            s2.build.target = BuildTarget.ios

            let d2b = TestDefaults.make("shot-install-\(suffix)")
            let s2b = LauncherStores(defaults: d2b)
            s2b.localizer.lang = lang
            s2b.build.upstreamChanged = {}
            s2b.build.kidWithSwordPath = fakeKWS.path
            s2b.build.updateSlot("base") { $0.paths = [ootFile.path] }
            s2b.build.target = BuildTarget.ios
            s2b.build.selectUpstream(.kidWithSword)

            try renderPNG(
                VStack(spacing: 20) {
                    EngineSwitcherCard(build: s2.build)
                    InstallCard(devices: s2b.deviceStore, build: s2b.build)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(LauncherPalette.background)
                .environmentObject(loc)
                .environmentObject(pad),
                size: CGSize(width: 980, height: 660),
                file: "02_builds_recommend_and_ios_standalone_\(suffix).png"
            )

            // 3. LibraryGameCard badges: built with Kid with Sword / built with No Lag Kart / general build with Tuned badge
            try renderPNG(
                HStack(spacing: 20) {
                    LibraryGameCard(
                        title: lang == .zh ? "塞尔达传说：时之笛" : "Ocarina of Time (Switch 2)",
                        image: nil,
                        focus: .center,
                        state: LibraryArtworkState(mac: true, ios: false, attention: .none, macUpstream: .kidWithSword, tunedEngines: [.kidWithSword, .macNativeGames]),
                        width: 240,
                        selected: true,
                        select: {}
                    )
                    LibraryGameCard(
                        title: lang == .zh ? "马里奥赛车：世界" : "Mario Kart World",
                        image: nil,
                        focus: .center,
                        state: LibraryArtworkState(mac: true, ios: false, attention: .none, macUpstream: .noLagKart, tunedEngines: [.noLagKart]),
                        width: 240,
                        selected: false,
                        select: {}
                    )
                    LibraryGameCard(
                        title: lang == .zh ? "塞尔达传说：旷野之息" : "Breath of the Wild",
                        image: nil,
                        focus: .center,
                        state: LibraryArtworkState(mac: true, ios: false, attention: .none, macUpstream: .nxnative, tunedEngines: [.macNativeGames]),
                        width: 240,
                        selected: false,
                        select: {}
                    )
                }
                .padding(28)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(LauncherPalette.background)
                .environmentObject(loc),
                size: CGSize(width: 840, height: 240),
                file: "03_library_tuned_cards_\(suffix).png"
            )

            // 4. SupportedGamesSheet filtered to Tuned
            let sampleSupported = [
                SupportedGame(titleID: "0400486024DEC000", name: "The Legend of Zelda: Ocarina of Time", edition: .switch2, version: "1.1.1", notes: "Tuned fork available: Kid with Sword (60fps, Mods, Amiibo) and MacNativeGames."),
                SupportedGame(titleID: "0400C3F00006E000", name: "Mario Kart World", edition: .switch2, version: "1.8.0", notes: "Tuned fork available: No Lag Kart (full-speed split-screen on Mac)."),
                SupportedGame(titleID: "01007EF00011E000", name: "The Legend of Zelda: Breath of the Wild", edition: .switch1, version: "1.6.0", notes: "Supported by MacNativeGames for macOS native builds."),
                SupportedGame(titleID: "0100F2C0115B6000", name: "The Legend of Zelda: Tears of the Kingdom", edition: .switch1, version: "1.2.1", notes: "Supported by MacNativeGames for macOS native builds."),
                SupportedGame(titleID: "0100152000022000", name: "Mario Kart 8 Deluxe", edition: .switch1, version: "3.0.3", notes: "Standard nxnative profile."),
            ]
            try renderPNG(
                SupportedGamesSheet(
                    games: sampleSupported,
                    owned: { _ in nil },
                    covers: .saved(in: self.temporary, maxPixel: SupportedGamesSheet.coverPixels),
                    showInLibrary: { _ in },
                    initialFilter: .tuned
                )
                .environmentObject(loc)
                .environmentObject(pad),
                size: CGSize(width: 680, height: 520),
                file: "04_supported_games_tuned_\(suffix).png"
            )
        }
    }
}
