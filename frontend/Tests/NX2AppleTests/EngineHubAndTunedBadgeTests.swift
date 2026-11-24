import AppKit
import CoreText
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
        // Switch 2 .nup guard in BuildSelectedSheet: Pokopia .nup falls back to nxnative and hides MNG tuned pill
        // until generic NUP routing (tools/nup_input.py) is available, while Ocarina of Time .nup stays enabled.
        XCTAssertEqual(
            BuildSelectedSheet.rowEngineTag(for: "0400A3A01EE4C000", selectedTarget: BuildTarget.mac, activeUpstream: .macNativeGames, isNUP: true, supportsGenericNUP: false),
            .nxnative
        )
        XCTAssertEqual(
            BuildSelectedSheet.rowEngineTag(for: "0400A3A01EE4C000", selectedTarget: BuildTarget.mac, activeUpstream: .macNativeGames, isNUP: true, supportsGenericNUP: true),
            .macNativeGames
        )
        XCTAssertEqual(
            BuildSelectedSheet.rowAvailableTunedEngines(for: "0400A3A01EE4C000", activeUpstream: .nxnative, isNUP: true, supportsGenericNUP: false),
            []
        )
        XCTAssertEqual(
            BuildSelectedSheet.rowAvailableTunedEngines(for: "0400A3A01EE4C000", activeUpstream: .nxnative, isNUP: true, supportsGenericNUP: true),
            [.macNativeGames]
        )
        XCTAssertEqual(
            BuildSelectedSheet.rowAvailableTunedEngines(for: "0400486024DEC000", activeUpstream: .nxnative, isNUP: true, supportsGenericNUP: false),
            [.kidWithSword, .macNativeGames]
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

        // Variant build work folders are discovered by BuildFiles and FreeSpace cleanup.
        XCTAssertEqual(BuildFiles.orphanTitleID(folderName: "0400486024DEC000_kidwithsword_build"), "0400486024DEC000")
        XCTAssertEqual(BuildFiles.orphanTitleID(folderName: "0400C3F00006E000_nolagkart_build"), "0400C3F00006E000")
        var sampleGame = LibraryGame(titleID: "0400C3F00006E000", name: "Mario Kart World")
        sampleGame.outputDirectory = "/tmp/out"
        let candidates = BuildFolder.candidates(for: sampleGame)
        XCTAssertTrue(candidates.contains("/tmp/out/0400C3F00006E000_build"))
        XCTAssertTrue(candidates.contains("/tmp/out/0400C3F00006E000_nolagkart_build"))

        // LiveConsoleDriver exposes full "MacNativeGames" name (never "MNG") for built MNG bundles.
        let mngApp = temporary.appendingPathComponent("TOTK.app")
        try? FileManager.default.createDirectory(at: mngApp.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try? FileManager.default.createSymbolicLink(at: mngApp.appendingPathComponent("Contents/MacOS/totk"), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        let plist: [String: Any] = [
            "DMTitleID": "0100F2C0115B6000",
            "DMUpstream": "macnativegames",
            "CFBundleExecutable": "totk",
            "CFBundleIdentifier": "org.macnativegames.totk",
            "CFBundlePackageType": "APPL",
        ]
        if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
            try? data.write(to: mngApp.appendingPathComponent("Contents/Info.plist"))
        }
        let libFile = temporary.appendingPathComponent("console-mng-lib.json")
        let lib = GameLibrary(file: libFile)
        var mngGame = LibraryGame(titleID: "0100F2C0115B6000", name: "Tears of the Kingdom")
        mngGame.appPath = mngApp.path
        lib.upsert(mngGame)
        let d = TestDefaults.make("console-mng-driver")
        let driver = LiveConsoleDriver(
            library: lib,
            controls: ControlLayout(defaults: d),
            repo: { "" },
            lang: { .en },
            labels: { L10n.string($0, .en) },
            observeSystem: false
        )
        XCTAssertEqual(driver.state.games.first?.builtTunedEngineName, EngineUpstreamKind.macNativeGames.displayName)
        XCTAssertNotEqual(driver.state.games.first?.builtTunedEngineName, "MNG")
    }

    func testAvailableTunedBadgesShowUnifiedLabelWhilePreservingBuiltEngineAttribution() throws {
        // 1. All 10 languages define a non-empty, semicolon-free unified label.
        XCTAssertEqual(L10n.string("library.chip.tunedAvailable", .en), "Tuned available")
        XCTAssertEqual(L10n.string("library.chip.tunedAvailable", .zh), "有特调")
        for lang in Lang.all {
            let text = L10n.string("library.chip.tunedAvailable", lang)
            XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(lang.code) missing library.chip.tunedAvailable")
            XCTAssertFalse(text.contains(";") || text.contains("\u{FF1B}"), "\(lang.code) contains semicolon")
        }

        // 2. Desktop LibraryGameCard distinguishes built-with-tuned from available-tuned.
        let builtState = LibraryArtworkState(mac: true, ios: false, attention: .none, macUpstream: .macNativeGames, tunedEngines: [.macNativeGames])
        let builtBadgeEN = try XCTUnwrap(LibraryGameCard.tunedBadge(for: builtState, t: { L10n.string($0, .en) }))
        XCTAssertEqual(builtBadgeEN.title, "MacNativeGames")
        XCTAssertTrue(builtBadgeEN.isBuilt)

        let generalState = LibraryArtworkState(mac: true, ios: false, attention: .none, macUpstream: .nxnative, tunedEngines: [.kidWithSword, .macNativeGames])
        let availBadgeEN = try XCTUnwrap(LibraryGameCard.tunedBadge(for: generalState, t: { L10n.string($0, .en) }))
        XCTAssertEqual(availBadgeEN.title, "Tuned available")
        XCTAssertFalse(availBadgeEN.isBuilt)
        XCTAssertTrue(availBadgeEN.help.contains("Kid with Sword"))
        XCTAssertTrue(availBadgeEN.help.contains("MacNativeGames"))
        let availBadgeZH = try XCTUnwrap(LibraryGameCard.tunedBadge(for: generalState, t: { L10n.string($0, .zh) }))
        XCTAssertEqual(availBadgeZH.title, "有特调")

        let plainState = LibraryArtworkState(mac: true, ios: false, attention: .none, macUpstream: .nxnative, tunedEngines: [])
        XCTAssertNil(LibraryGameCard.tunedBadge(for: plainState, t: { L10n.string($0, .en) }))

        // 3. Desktop Hero metadata badge keeps real built provenance and uses unified label for available tuned.
        let kwsApp = temporary.appendingPathComponent("Ocarina.app", isDirectory: true)
        try FileManager.default.createDirectory(at: kwsApp.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: kwsApp.appendingPathComponent("Contents/MacOS/Game"), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        try FileManager.default.createSymbolicLink(at: kwsApp.appendingPathComponent("Contents/MacOS/dmhost"), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        let kwsPlist: [String: Any] = [
            "CFBundlePackageType": "APPL",
            "CFBundleExecutable": "Game",
            "CFBundleIdentifier": "org.nxnative.0400486024dec000",
            "CFBundleName": "Ocarina of Time",
            "DMTitleID": "0400486024DEC000",
            "DMUpstream": "kidwithsword",
        ]
        try PropertyListSerialization.data(fromPropertyList: kwsPlist, format: .xml, options: 0)
            .write(to: kwsApp.appendingPathComponent("Contents/Info.plist"))

        var heroBuilt = LibraryGame(titleID: "0400486024DEC000", name: "Ocarina of Time")
        heroBuilt.appPath = kwsApp.path
        let heroBuiltBadge = try XCTUnwrap(LauncherView.tunedMetadataBadge(for: heroBuilt, t: { L10n.string($0, .en) }))
        XCTAssertEqual(heroBuiltBadge.title, "Kid with Sword")
        XCTAssertTrue(heroBuiltBadge.isBuilt)

        let heroAvail = LibraryGame(titleID: "01006F8002326000", name: "Animal Crossing: New Horizons")
        let heroAvailBadgeEN = try XCTUnwrap(LauncherView.tunedMetadataBadge(for: heroAvail, t: { L10n.string($0, .en) }))
        XCTAssertEqual(heroAvailBadgeEN.title, "Tuned available")
        XCTAssertFalse(heroAvailBadgeEN.isBuilt)
        let heroAvailBadgeZH = try XCTUnwrap(LauncherView.tunedMetadataBadge(for: heroAvail, t: { L10n.string($0, .zh) }))
        XCTAssertEqual(heroAvailBadgeZH.title, "有特调")

        // 4. SupportedGamesSheet & ConsoleSupportedGamesPage use unified label instead of engine names.
        let acnhSupported = SupportedGame(titleID: "01006F8002326000", name: "Animal Crossing: New Horizons", edition: .switch1, version: "2.0.6", notes: "")
        XCTAssertEqual(SupportedGamesSheet.tunedBadgeTitle(for: acnhSupported, t: { L10n.string($0, .en) }), "Tuned available")
        XCTAssertEqual(SupportedGamesSheet.tunedBadgeTitle(for: acnhSupported, t: { L10n.string($0, .zh) }), "有特调")
        let mk8Supported = SupportedGame(titleID: "0100152000022000", name: "Mario Kart 8 Deluxe", edition: .switch1, version: "3.0.3", notes: "")
        XCTAssertNil(SupportedGamesSheet.tunedBadgeTitle(for: mk8Supported, t: { L10n.string($0, .en) }))

        // 5. ConsoleView.gameTags and live ConsoleGameTile / ConsoleArtColumn render unified label for available-tuned and keep built provenance.
        let driver = MockConsoleDriver(scenario: .full, animated: false)
        let consoleEN = ConsoleView(driver: driver, lang: .en)
        let cAvail = ConsoleGame(
            id: "c-avail",
            title: "Animal Crossing: New Horizons",
            version: "2.0.6",
            platforms: [.mac],
            status: .ready,
            builtTunedEngineName: nil,
            tunedEngineNames: ["MacNativeGames"]
        )
        let cBuilt = ConsoleGame(
            id: "c-built",
            title: "Ocarina of Time",
            version: "1.1.1",
            platforms: [.mac],
            status: .ready,
            builtTunedEngineName: "Kid with Sword",
            tunedEngineNames: ["Kid with Sword", "MacNativeGames"]
        )
        let availTags = consoleEN.gameTags(cAvail)
        XCTAssertEqual(availTags.filter(\.emphasized).map(\.title), ["Tuned available"])
        let builtTags = consoleEN.gameTags(cBuilt)
        XCTAssertEqual(builtTags.filter(\.emphasized).map(\.title), ["Kid with Sword"])

        func renderedTexts<V: View>(_ view: V) -> Set<String> {
            NSApplication.shared.setActivationPolicy(.accessory)
            let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
            let previous = NSApplication.shared.accessibilityAttributeValue(enhanced)
            NSApplication.shared.accessibilitySetValue(true, forAttribute: enhanced)
            defer { NSApplication.shared.accessibilitySetValue(previous ?? false, forAttribute: enhanced) }
            let window = OffscreenWindow(size: NSSize(width: 720, height: 320))
            let host = NSHostingView(rootView: view.environmentObject(Localizer(.en)))
            window.contentView = host
            window.orderFront(nil)
            defer { window.contentView = nil; window.orderOut(nil); window.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            host.layoutSubtreeIfNeeded()
            var found: Set<String> = []
            func visit(_ node: NSObject) {
                for selName in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"] {
                    let sel = NSSelectorFromString(selName)
                    if node.responds(to: sel), let value = node.perform(sel)?.takeUnretainedValue() as? String {
                        found.insert(value)
                    }
                }
                let childrenSel = NSSelectorFromString("accessibilityChildren")
                if node.responds(to: childrenSel), let kids = node.perform(childrenSel)?.takeUnretainedValue() as? [NSObject] {
                    kids.forEach(visit)
                }
            }
            visit(window)
            return found
        }

        let tileAvailTexts = renderedTexts(ConsoleGameTile(game: cAvail, selected: false, compact: false, lang: .en))
        XCTAssertTrue(tileAvailTexts.contains("Tuned available"))
        XCTAssertFalse(tileAvailTexts.contains("MacNativeGames"))

        let tileBuiltTexts = renderedTexts(ConsoleGameTile(game: cBuilt, selected: false, compact: false, lang: .en))
        XCTAssertTrue(tileBuiltTexts.contains("Kid with Sword"))
        XCTAssertFalse(tileBuiltTexts.contains("Tuned available"))
    }

    func testFixedPillWidthsFitAllEnginesAndLocalizedLabels() throws {
        func measure(_ text: String, size: CGFloat, weight: Font.Weight) throws -> CGFloat {
            let font = try XCTUnwrap(Typography.manropeFont(size: size, weight: weight))
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
            return CTLineGetTypographicBounds(line, nil, nil, nil)
        }

        let engineLabels = [
            EngineUpstreamKind.macNativeGames.displayName,
            EngineUpstreamKind.kidWithSword.displayName,
            EngineUpstreamKind.noLagKart.displayName,
        ] + Lang.all.map { L10n.string("library.chip.tuned", $0) }
        let platformLabels = Lang.all.flatMap { lang in
            [L10n.string("switch2.badge", lang), L10n.string("console.platform.mac", lang), L10n.string("console.platform.iphone", lang)]
        }

        let dsEngineRoom = DSTag.engineWidth - 2 * DS.Space.xs
        for label in engineLabels {
            let w = try measure(label, size: DS.Font.footnoteSize, weight: .regular)
            XCTAssertLessThanOrEqual(w, dsEngineRoom, "DSTag.engineWidth too narrow for \(label): \(w) > \(dsEngineRoom)")
        }
        let dsPlatformRoom = DSTag.platformWidth - 2 * DS.Space.xs
        for label in platformLabels {
            let w = try measure(label, size: DS.Font.footnoteSize, weight: .regular)
            XCTAssertLessThanOrEqual(w, dsPlatformRoom, "DSTag.platformWidth too narrow for \(label): \(w) > \(dsPlatformRoom)")
        }

        for compact in [false, true] {
            let size: CGFloat = compact ? 12 : 13
            let pad: CGFloat = compact ? 8 : 10
            let engineRoom = ConsoleTag.engineWidth(compact: compact) - 2 * pad
            for label in engineLabels {
                let w = try measure(label, size: size, weight: .semibold)
                XCTAssertLessThanOrEqual(w, engineRoom, "ConsoleTag.engineWidth(compact: \(compact)) too narrow for \(label): \(w) > \(engineRoom)")
            }
            let platformRoom = ConsoleTag.platformWidth(compact: compact) - 2 * pad
            for label in platformLabels {
                let w = try measure(label, size: size, weight: .semibold)
                XCTAssertLessThanOrEqual(w, platformRoom, "ConsoleTag.platformWidth(compact: \(compact)) too narrow for \(label): \(w) > \(platformRoom)")
            }
        }
    }

    func testCaptureEngineHubScreenshotsWhenRequested() throws {
        let env = ProcessInfo.processInfo.environment
        guard let outDir = (env["NX_CAPTURE_ENGINE_HUB"].flatMap { $0.isEmpty ? nil : $0 })
            ?? (env["NX_LAUNCHER_CAPTURE_DIR"].flatMap { $0.isEmpty ? nil : $0 }) else {
            return
        }
        let outURL = URL(fileURLWithPath: outDir, isDirectory: true)
        try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)

        func renderPNG<V: View>(_ view: V, size: CGSize, fitHeight: Bool = false, file: String) throws {
            let wasStatic = LauncherGlass.forceStatic
            LauncherGlass.forceStatic = true
            defer { LauncherGlass.forceStatic = wasStatic }
            let sizedView: AnyView = fitHeight
                ? AnyView(view.frame(width: size.width).fixedSize(horizontal: false, vertical: true).launcherAppearance())
                : AnyView(view.frame(width: size.width, height: size.height).launcherAppearance())
            let host = NSHostingView(rootView: sizedView)
            let finalSize: CGSize
            if fitHeight {
                host.frame = NSRect(origin: .zero, size: CGSize(width: size.width, height: max(size.height, 2000)))
                host.layoutSubtreeIfNeeded()
                let fitted = host.fittingSize
                finalSize = CGSize(width: size.width, height: max(size.height, ceil(fitted.height)))
            } else {
                finalSize = size
            }
            host.frame = NSRect(origin: .zero, size: finalSize)
            let window = NSWindow(
                contentRect: NSRect(origin: NSPoint(x: -100_000, y: -100_000), size: finalSize),
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
        let mkwFile = temporary.appendingPathComponent("Mario Kart World [0400C3F00006E000].nsp")
        let botwFile = temporary.appendingPathComponent("Breath of the Wild [01007EF00011E000].nsp")
        let mk8File = temporary.appendingPathComponent("Mario Kart 8 Deluxe [0100152000022000].nsp")
        for f in [ootFile, mkwFile, botwFile, mk8File] { try Data([0]).write(to: f) }

        // Create a real synthetic Mac app built with Kid with Sword so Library Hero badges resolve live.
        let kwsApp = temporary.appendingPathComponent("Ocarina.app", isDirectory: true)
        try FileManager.default.createDirectory(at: kwsApp.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: kwsApp.appendingPathComponent("Contents/MacOS/Game"), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        try FileManager.default.createSymbolicLink(at: kwsApp.appendingPathComponent("Contents/MacOS/dmhost"), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        let kwsPlist: [String: Any] = [
            "CFBundlePackageType": "APPL",
            "CFBundleExecutable": "Game",
            "CFBundleIdentifier": "org.nxnative.0400486024dec000",
            "CFBundleName": "Ocarina of Time",
            "DMTitleID": "0400486024DEC000",
            "DMUpstream": "kidwithsword",
        ]
        try PropertyListSerialization.data(fromPropertyList: kwsPlist, format: .xml, options: 0)
            .write(to: kwsApp.appendingPathComponent("Contents/Info.plist"))

        for lang in CaptureLanguage.all([Lang.en, Lang.zh]) {
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

            // 2. EngineSwitcherCard recommendation + Kid with Sword iOS Standalone InstallCard (auto-fitted height, zero clipping)
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
                .background(LauncherPalette.background)
                .environmentObject(loc)
                .environmentObject(pad),
                size: CGSize(width: 980, height: 680),
                fitHeight: true,
                file: "02_builds_recommend_and_ios_standalone_\(suffix).png"
            )

            // 3. LibraryGameCard badges: built with Kid with Sword / built with No Lag Kart / unbuilt multi-tuned / built with MacNativeGames
            try renderPNG(
                HStack(spacing: 18) {
                    LibraryGameCard(
                        title: lang == .zh ? "塞尔达传说：时之笛" : "Ocarina of Time (Switch 2)",
                        image: nil,
                        focus: .center,
                        state: LibraryArtworkState(mac: true, ios: false, attention: .none, macUpstream: .kidWithSword, tunedEngines: [.kidWithSword, .macNativeGames]),
                        width: 220,
                        selected: true,
                        select: {}
                    )
                    LibraryGameCard(
                        title: lang == .zh ? "马里奥赛车：世界" : "Mario Kart World",
                        image: nil,
                        focus: .center,
                        state: LibraryArtworkState(mac: true, ios: false, attention: .none, macUpstream: .noLagKart, tunedEngines: [.noLagKart]),
                        width: 220,
                        selected: false,
                        select: {}
                    )
                    LibraryGameCard(
                        title: lang == .zh ? "时之笛（通用构建）" : "Ocarina of Time",
                        image: nil,
                        focus: .center,
                        state: LibraryArtworkState(mac: true, ios: false, attention: .none, macUpstream: .nxnative, tunedEngines: [.kidWithSword, .macNativeGames]),
                        width: 220,
                        selected: false,
                        select: {}
                    )
                    LibraryGameCard(
                        title: lang == .zh ? "塞尔达传说：旷野之息" : "Breath of the Wild",
                        image: nil,
                        focus: .center,
                        state: LibraryArtworkState(mac: true, ios: false, attention: .none, macUpstream: .macNativeGames, tunedEngines: [.macNativeGames]),
                        width: 220,
                        selected: false,
                        select: {}
                    )
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(LauncherPalette.background)
                .environmentObject(loc),
                size: CGSize(width: 1020, height: 230),
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

            // 5. Desktop Library Hero Detail Badges (built with Kid with Sword vs general build with Tuned available)
            let d5 = TestDefaults.make("shot-hero-\(suffix)")
            let s5 = LauncherStores(defaults: d5)
            s5.localizer.lang = lang
            let heroLib = GameLibrary(file: temporary.appendingPathComponent("hero-lib-\(suffix).json"))
            var heroBuiltKWS = LibraryGame(titleID: "0400486024DEC000", name: lang == .zh ? "塞尔达传说：时之笛 (Switch 2)" : "Ocarina of Time (Switch 2)")
            heroBuiltKWS.appPath = kwsApp.path
            let heroHasTuned = LibraryGame(titleID: "0400C3F00006E000", name: lang == .zh ? "马里奥赛车：世界" : "Mario Kart World")
            heroLib.upsert(heroBuiltKWS)
            heroLib.upsert(heroHasTuned)
            let launcherProbe = LauncherView(
                stores: s5,
                library: heroLib,
                initialPage: .library,
                performStartupChecks: false,
                controls: ControlLayout(defaults: d5),
                gamepad: LauncherGamepad(steam: nil, observeSystem: false),
                padFocus: pad
            )
            try renderPNG(
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(heroBuiltKWS.name).font(DS.Font.title).foregroundStyle(DS.Color.textPrimary)
                        launcherProbe.libraryMetadataBadges(heroBuiltKWS)
                        Text(String(format: loc.t("library.tunedBuilt.help"), EngineUpstreamKind.kidWithSword.displayName))
                            .font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LauncherPalette.surface, in: RoundedRectangle(cornerRadius: 14))

                    VStack(alignment: .leading, spacing: 8) {
                        Text(heroHasTuned.name).font(DS.Font.title).foregroundStyle(DS.Color.textPrimary)
                        launcherProbe.libraryMetadataBadges(heroHasTuned)
                        Text(String(format: loc.t("library.tuned.help"), EngineUpstreamKind.noLagKart.displayName))
                            .font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LauncherPalette.surface, in: RoundedRectangle(cornerRadius: 14))
                }
                .padding(24)
                .background(LauncherPalette.background)
                .environmentObject(loc)
                .environmentObject(pad),
                size: CGSize(width: 720, height: 300),
                fitHeight: true,
                file: "05_library_hero_badges_\(suffix).png"
            )

            // 6. Console Mode Game Library Tiles & Detail Subtitles (ConsoleArtColumn with platform + engine pills)
            let cKWS = ConsoleGame(
                id: "c-kws",
                title: lang == .zh ? "塞尔达传说：时之笛" : "Ocarina of Time (Switch 2)",
                version: "1.1.1",
                platforms: [.mac, .iphone],
                status: .ready,
                builtTunedEngineName: EngineUpstreamKind.kidWithSword.displayName,
                tunedEngineNames: [EngineUpstreamKind.kidWithSword.displayName, EngineUpstreamKind.macNativeGames.displayName]
            )
            let cNLK = ConsoleGame(
                id: "c-nlk",
                title: lang == .zh ? "马里奥赛车：世界" : "Mario Kart World",
                version: "1.8.0",
                platforms: [.mac],
                status: .ready,
                builtTunedEngineName: EngineUpstreamKind.noLagKart.displayName,
                tunedEngineNames: [EngineUpstreamKind.noLagKart.displayName]
            )
            let cTuned = ConsoleGame(
                id: "c-tuned",
                title: lang == .zh ? "塞尔达传说：旷野之息" : "Breath of the Wild",
                version: "1.6.0",
                platforms: [.mac],
                status: .ready,
                builtTunedEngineName: nil,
                tunedEngineNames: [EngineUpstreamKind.macNativeGames.displayName]
            )
            let consoleDetailContext = ConsolePageContext(
                title: cKWS.title,
                subtitle: [L10n.string(cKWS.status.labelKey, lang), String(format: L10n.string("console.version", lang), cKWS.version)].joined(separator: " \u{00b7} "),
                tags: cKWS.platforms.map { ConsoleContextTag(title: L10n.string($0.labelKey, lang), emphasized: false, width: .platform) }
                    + [ConsoleContextTag(title: EngineUpstreamKind.kidWithSword.displayName, emphasized: true, width: .engine)]
            )
            try renderPNG(
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 18) {
                        ConsoleGameTile(game: cKWS, selected: true, compact: false, lang: lang)
                        ConsoleGameTile(game: cNLK, selected: false, compact: false, lang: lang)
                        ConsoleGameTile(game: cTuned, selected: false, compact: false, lang: lang)
                    }
                    ConsoleArtColumn(context: consoleDetailContext)
                        .frame(height: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(24)
                .background(LauncherPalette.background)
                .environmentObject(loc),
                size: CGSize(width: 900, height: 520),
                fitHeight: true,
                file: "06_console_tiles_and_detail_\(suffix).png"
            )

            // 7. BuildSelectedSheet (batch build selector with Tuned filter & split Tuned + engine pills)
            let batchLib = GameLibrary(file: temporary.appendingPathComponent("batch-lib-\(suffix).json"))
            batchLib.upsert(LibraryGame(titleID: "0400486024DEC000", name: "The Legend of Zelda: Ocarina of Time", inputs: ["base": [ootFile.path]]))
            batchLib.upsert(LibraryGame(titleID: "0400C3F00006E000", name: "Mario Kart World", inputs: ["base": [mkwFile.path]]))
            batchLib.upsert(LibraryGame(titleID: "01007EF00011E000", name: "The Legend of Zelda: Breath of the Wild", inputs: ["base": [botwFile.path]]))
            batchLib.upsert(LibraryGame(titleID: "0100152000022000", name: "Mario Kart 8 Deluxe", inputs: ["base": [mk8File.path]]))
            let batchQueue = BuildQueueStore(file: nil, engineID: { "main" }, busy: { false }, start: { _ in nil })
            try renderPNG(
                BuildSelectedSheet(
                    library: batchLib,
                    queue: batchQueue,
                    engineID: "main",
                    target: BuildTarget.mac,
                    packagesSharedApp: false,
                    exportsFramework: false,
                    macOnlyNoteKey: nil,
                    macNativeGamesSelected: false,
                    activeUpstream: .nxnative,
                    close: {}
                )
                .environmentObject(loc)
                .environmentObject(pad),
                size: CGSize(width: 680, height: 560),
                file: "07_build_selected_sheet_tuned_\(suffix).png"
            )

            // 8. ConsoleSupportedGamesPage (console mode supported games with platform + engine pills, no Improved in 1.5 pill)
            let consoleDriver = MockConsoleDriver(scenario: .full, animated: false)
            consoleDriver.state.openSupportedGames(sampleSupported, owned: [:])
            try renderPNG(
                ConsoleSupportedGamesPage(driver: consoleDriver, lang: lang, glyphs: .current(), compact: true, embedded: true)
                    .environmentObject(pad)
                    .environmentObject(loc),
                size: CGSize(width: 720, height: 860),
                file: "08_console_supported_games_\(suffix).png"
            )
        }
    }
}
