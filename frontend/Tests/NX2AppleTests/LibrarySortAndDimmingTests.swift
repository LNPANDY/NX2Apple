import AppKit
import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher
@testable import NXModel

@MainActor final class LibrarySortAndDimmingTests: IsolatedDefaultsTestCase {
    private var temporary: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nx-sort-dimming-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporary)
    }

    private func makeMacApp(titleID: String, name: String) throws -> URL {
        let app = temporary.appendingPathComponent(name + ".app")
        let executables = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: executables, withIntermediateDirectories: true)
        for binary in ["nxnative", "dmhost"] {
            try FileManager.default.createSymbolicLink(
                at: executables.appendingPathComponent(binary),
                withDestinationURL: URL(fileURLWithPath: "/usr/bin/true")
            )
        }
        let info: [String: Any] = [
            "DMTitleID": titleID,
            "CFBundleDisplayName": name,
            "CFBundleExecutable": "nxnative",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app
    }

    private func redArtworkImage() -> NSImage {
        NSImage(size: NSSize(width: 360, height: 200), flipped: false) { bounds in
            NSColor(srgbRed: 0.92, green: 0.14, blue: 0.14, alpha: 1).setFill()
            bounds.fill()
            return true
        }
    }

    private func sampleCenterPixel(in view: some View, scheme: ColorScheme) throws -> NSColor {
        let host = NSHostingView(
            rootView: view
                .environment(\.colorScheme, scheme)
                .preferredColorScheme(scheme)
                .transaction { $0.disablesAnimations = true }
        )
        let window = OffscreenWindow(size: NSSize(width: 320, height: 240), styleMask: [.borderless])
        window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        // Sample center of artwork band (avoiding top-leading status chip and bottom title)
        let x = rep.pixelsWide / 2
        let y = rep.pixelsHigh * 45 / 100
        return try XCTUnwrap(rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
    }

    func testLibrarySortPrioritizesBuiltTiersZeroThroughThree() throws {
        let macApp = try makeMacApp(titleID: "0100000000000001", name: "Zelda Mac")
        let brokenApp = temporary.appendingPathComponent("Broken.app")
        try FileManager.default.createDirectory(at: brokenApp, withIntermediateDirectories: true)
        let ipaFile = temporary.appendingPathComponent("Mobile.ipa")
        try Data("ipa".utf8).write(to: ipaFile)

        var unbuiltAlpha = LibraryGame(titleID: "0100000000000004", name: "Alpha Unbuilt")
        unbuiltAlpha.inputs = ["base": ["/tmp/alpha.nsp"]]
        unbuiltAlpha.lastPlayed = Date(timeIntervalSince1970: 5_000)

        var buildingBeta = LibraryGame(titleID: "0100000000000003", name: "Beta Building")
        buildingBeta.inputs = ["base": ["/tmp/beta.nsp"]]

        var brokenGamma = LibraryGame(titleID: "0100000000000005", name: "Gamma Broken")
        brokenGamma.appPath = brokenApp.path

        var iosDelta = LibraryGame(titleID: "0100000000000002", name: "Delta iOS")
        iosDelta.ipaPath = ipaFile.path

        var macPlayedOld = LibraryGame(titleID: "0100000000000006", name: "Omega Mac")
        macPlayedOld.appPath = try makeMacApp(titleID: "0100000000000006", name: "Omega Mac").path
        macPlayedOld.lastPlayed = Date(timeIntervalSince1970: 100)

        var macPlayedNew = LibraryGame(titleID: "0100000000000001", name: "Zelda Mac")
        macPlayedNew.appPath = macApp.path
        macPlayedNew.lastPlayed = Date(timeIntervalSince1970: 200)

        let unsorted = [unbuiltAlpha, brokenGamma, buildingBeta, iosDelta, macPlayedOld, macPlayedNew]
        let byRecent = LibrarySort.recent.ordered(unsorted, lang: .en, buildingID: buildingBeta.id)
        XCTAssertEqual(
            byRecent.map(\.id),
            [macPlayedNew.id, macPlayedOld.id, iosDelta.id, buildingBeta.id, brokenGamma.id, unbuiltAlpha.id],
            "Tier 0 (Mac ready, recent first) -> Tier 1 (iOS) -> Tier 2 (building/needs repair) -> Tier 3 (unbuilt)"
        )

        let byName = LibrarySort.name.ordered(unsorted, lang: .en, buildingID: buildingBeta.id)
        XCTAssertEqual(
            byName.map(\.id),
            [macPlayedOld.id, macPlayedNew.id, iosDelta.id, buildingBeta.id, brokenGamma.id, unbuiltAlpha.id],
            "Name sort also prioritizes built tiers before intra-tier alphabetical ordering"
        )

        let flatRecent = LibrarySort.recent.ordered(unsorted, lang: .en, builtFirst: false)
        XCTAssertEqual(flatRecent.first?.id, unbuiltAlpha.id)
    }

    func testColdStartAndRemovalSelectFirstOrderedBuiltGame() throws {
        let macApp = try makeMacApp(titleID: "0100000000000002", name: "Zelda")
        let ipaFile = temporary.appendingPathComponent("Mario.ipa")
        try Data("ipa".utf8).write(to: ipaFile)

        let unbuilt = LibraryGame(titleID: "0100000000000001", name: "Alpha Unbuilt")
        var iosGame = LibraryGame(titleID: "0100000000000003", name: "Mid iOS")
        iosGame.ipaPath = ipaFile.path
        var macGame = LibraryGame(titleID: "0100000000000002", name: "Zelda")
        macGame.appPath = macApp.path

        let file = temporary.appendingPathComponent("library.json")
        try JSONEncoder().encode([unbuilt, iosGame, macGame]).write(to: file)

        let library = GameLibrary(file: file)
        XCTAssertEqual(library.selectedID, macGame.id, "Cold start must select the leading built game")
        library.remove(macGame.id)
        XCTAssertEqual(library.selectedID, iosGame.id, "After removing the Mac game, selection moves to the iOS built game")
    }

    func testDesktopAndConsoleFilterPersistenceAreIsolatedAndReconcileUsesSearch() {
        LibraryFilter.built.save(testDefaults)
        XCTAssertEqual(LibraryFilter.load(testDefaults), .built)
        XCTAssertEqual(LibraryFilter.loadDesktop(testDefaults), .owned, "Console `.built` must not leak into desktop filter")

        LibraryFilter.mac.saveDesktop(testDefaults)
        XCTAssertEqual(LibraryFilter.loadDesktop(testDefaults), .mac)
        XCTAssertEqual(LibraryFilter.load(testDefaults), .built, "Desktop save must not clobber console `.onlyBuilt`")

        let alpha = LibraryGame(titleID: "0100000000000001", name: "Alpha")
        let zelda = LibraryGame(titleID: "0100000000000002", name: "Zelda")
        let reconciled = LibraryFilter.owned.reconcile(
            games: [alpha, zelda],
            selectedID: alpha.id,
            focused: "card." + alpha.id.uuidString,
            sort: .name,
            search: "zelda",
            lang: .en
        )
        XCTAssertEqual(reconciled.selectedID, zelda.id)
        XCTAssertNil(reconciled.focused)
    }

    func testPlan1CMutedCardsKeepGentleColorAndRestoreFullSaturationWhenSelected() throws {
        let image = redArtworkImage()
        let unbuiltState = LibraryArtworkState(mac: false, ios: false, attention: .notBuilt)
        let readyState = LibraryArtworkState(mac: true, ios: false, attention: .none)
        let loc = Localizer(.en)

        for scheme in [ColorScheme.light, .dark] {
            let mutedCard = LibraryGameCard(
                title: "Example",
                image: image,
                focus: .center,
                state: unbuiltState,
                width: 280,
                selected: false,
                select: {}
            )
            .environmentObject(loc)
            .frame(width: 300, height: 220)

            let selectedUnbuiltCard = LibraryGameCard(
                title: "Example",
                image: image,
                focus: .center,
                state: unbuiltState,
                width: 280,
                selected: true,
                select: {}
            )
            .environmentObject(loc)
            .frame(width: 300, height: 220)

            let readyCard = LibraryGameCard(
                title: "Example",
                image: image,
                focus: .center,
                state: readyState,
                width: 280,
                selected: false,
                select: {}
            )
            .environmentObject(loc)
            .frame(width: 300, height: 220)

            let muted = try sampleCenterPixel(in: mutedCard, scheme: scheme)
            let selected = try sampleCenterPixel(in: selectedUnbuiltCard, scheme: scheme)
            let ready = try sampleCenterPixel(in: readyCard, scheme: scheme)

            let mutedChroma = muted.redComponent - muted.greenComponent
            let selectedChroma = selected.redComponent - selected.greenComponent
            // Translucent muted tone (48% saturation + 50% artwork opacity) must NOT turn unbuilt cards grayscale (`R == G`).
            XCTAssertGreaterThan(mutedChroma, 0.10, "Muted card keeps warm red chroma in \(scheme)")
            // Selected unbuilt card restores full saturation & opacity matching the ready card.
            XCTAssertEqual(selected.redComponent, ready.redComponent, accuracy: 0.03)
            XCTAssertEqual(selected.greenComponent, ready.greenComponent, accuracy: 0.03)
            // Rest state must clearly step back in chroma compared to full-color selected/built cards.
            XCTAssertGreaterThan(selectedChroma, mutedChroma + 0.18, "Muted rest state clearly reduces chroma vs built/selected in \(scheme)")
        }
    }

    func testConsolePlayableOlderToolsAndIPhoneStayColorAndOlderToolsLeavesAttention() throws {
        var olderMac = ConsoleGame(id: "m", title: "Mario", version: "", platforms: [.mac], artwork: redArtworkImage(), status: .ready)
        olderMac.olderTools = true
        let sections = ConsoleHome.sections([olderMac])
        XCTAssertEqual(sections.first?.row, .ready, "Playable Mac game with older tools stays in Ready, not Attention")

        var iphoneOnly = ConsoleGame(id: "i", title: "Zelda", version: "", platforms: [.iphone], artwork: redArtworkImage(), status: .iphoneOnly)
        iphoneOnly.olderTools = false

        var unbuilt = ConsoleGame(id: "u", title: "Celeste", version: "", platforms: [.mac], artwork: redArtworkImage(), status: .needsBuild)

        for (game, selected, label) in [
            (olderMac, false, "olderTools"),
            (iphoneOnly, false, "iphoneOnly"),
            (unbuilt, true, "focused unbuilt"),
        ] {
            let tile = ConsoleGameTile(game: game, selected: selected, compact: false, lang: .en)
                .frame(width: 300, height: 220)
            let pixel = try sampleCenterPixel(in: tile, scheme: .dark)
            XCTAssertGreaterThan(pixel.redComponent, pixel.greenComponent + 0.25, "\(label) keeps full-color chroma")
        }

        let mutedTile = ConsoleGameTile(game: unbuilt, selected: false, compact: false, lang: .en)
            .frame(width: 300, height: 220)
        let mutedPixel = try sampleCenterPixel(in: mutedTile, scheme: .dark)
        XCTAssertGreaterThan(mutedPixel.redComponent, mutedPixel.greenComponent + 0.05, "Unfocused unbuilt console tile keeps muted color")
    }

    func testArtworkStateCacheAvoidsRepeatedDiskProbesAndInvalidatesOnActivation() throws {
        let app = try makeMacApp(titleID: "0100000000000001", name: "CachedGame")
        let plist = app.appendingPathComponent("Contents/Info.plist")
        let info: [String: Any] = ["DMTitleID": "0100000000000001", "CFBundleExecutable": "nxnative", "DMRomfsMarker": ""]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: plist)
        let romfs = app.appendingPathComponent("Contents/Resources/romfs")
        try FileManager.default.createDirectory(at: romfs, withIntermediateDirectories: true)

        var game = LibraryGame(titleID: "0100000000000001", name: "CachedGame")
        game.appPath = app.path
        let file = temporary.appendingPathComponent("library.json")
        try JSONEncoder().encode([game]).write(to: file)
        let library = GameLibrary(file: file)

        let first = library.artworkState(for: game)
        XCTAssertTrue(first.mac)
        XCTAssertEqual(first.attention, .none)

        // Remove romfs on disk without mutating `game`: cached state stays valid until invalidated.
        try FileManager.default.removeItem(at: romfs)
        XCTAssertTrue(library.artworkState(for: game).mac, "Cache hit must avoid re-probing disk on redraw")

        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let refreshed = library.artworkState(for: game)
        XCTAssertFalse(refreshed.mac)
        XCTAssertEqual(refreshed.attention, .missingData)
    }
}
