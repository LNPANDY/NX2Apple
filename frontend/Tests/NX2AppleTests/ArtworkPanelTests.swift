import AppKit
import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher

/// The artwork panel drawn in the launcher, for visual QA. Opt-in (`NX_LAUNCHER_CAPTURE_DIR`), like testRenderLauncherForVisualQA:
/// the images are generated, the library and the artwork folder are temporary, and nothing reaches the network.
final class ArtworkPanelTests: XCTestCase {
    private var fixture: ArtworkFixture!

    override func tearDown() async throws { await MainActor.run { fixture?.cleanup() } }

    @MainActor private func render<V: View>(_ name: String, in output: URL, size: NSSize = NSSize(width: 1440, height: 1024), _ view: V) throws {
        let host = NSHostingView(rootView: view)
        let window = OffscreenWindow(size: size)
        window.contentView = host
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
        window.orderOut(nil)
    }

    @MainActor func testRenderArtworkPanelForVisualQA() async throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else { throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture native views") }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        let lang = CaptureLanguage.current(.en)
        let stores = LauncherStores()
        stores.localizer.lang = lang

        fixture = try ArtworkFixture(others: [("01007EF00011E000", "The Legend of Zelda: Breath of the Wild"), ("0100000000010000", "Super Mario Odyssey"),
                                              ("010093801237C000", "Metroid Dread")])
        stores.build.outDir = fixture.temporary.path
        fixture.library.selectedID = fixture.gameID
        let store = ArtworkStore(directory: fixture.artwork, titleList: fixture.temporary.appendingPathComponent("none.json"), allowsFileURLs: true)

        func capture(_ name: String, slot: ArtworkSlot = .hero, prepare: (ArtworkEditor) async throws -> Void = { _ in }) async throws {
            let editor = fixture.editor(slot: slot, lang: lang)
            try await prepare(editor)
            let view = LauncherView(stores: stores, library: fixture.library, performStartupChecks: false, artworkEditor: editor, artworkStore: store)
            try render(name, in: output, view)
            editor.cancel()   // a copy made for the capture is removed
        }

        try await capture("artwork-hero") { editor in
            await editor.load()
            editor.select(editor.tiles[3])
        }
        try await capture("artwork-thumbnail") { editor in
            await editor.load()
            editor.select(editor.tiles[2])
            editor.slot = .thumbnail
            editor.select(editor.tiles[5])
        }
        try await capture("artwork-thumbnail-follows", slot: .thumbnail) { await $0.load() }   // the badge on the hero's tile, which is chosen

        try await capture("artwork-framing") { editor in   // a 4:3 image the hero crops, the point off centre so Center is offered
            await editor.load()
            await editor.importFile(try fixture.chosenImage(width: 1920, height: 1440, name: "square.png"))
            await editor.measureSelected()
            editor.setFocus(ArtworkFocus(x: 0.5, y: 0.85))
        }
        try await capture("artwork-framing-thumbnail", slot: .thumbnail) { editor in   // a tall image: a card crops its height
            await editor.load()
            await editor.importFile(try fixture.chosenImage(width: 1200, height: 1400, name: "tall.png"))
            await editor.measureSelected()
            editor.setFocus(ArtworkFocus(x: 0.5, y: 0.2))
        }

        fixture.holdMedia = true
        try await capture("artwork-loading")   // the list has not arrived: skeleton tiles
        fixture.holdMedia = false

        fixture.mediaResults = [.offline]
        try await capture("artwork-offline") { await $0.load() }
        fixture.mediaResults = [.loaded(ArtworkStore.Media(screenshots: (0..<6).map { "shot-\($0)" }))]

        try await capture("artwork-import-error") { editor in
            await editor.load()
            let broken = fixture.temporary.appendingPathComponent("notes.png")
            try Data("not an image".utf8).write(to: broken)
            await editor.importFile(broken)
        }
        try await capture("artwork-lowres") { editor in
            await editor.load()
            await editor.importFile(try fixture.chosenImage(width: 1000))
        }
        try await capture("artwork-yours") { editor in
            await editor.load()
            await editor.importFile(try fixture.chosenImage(width: 2400))
        }

        // A narrow window, as small as the launcher goes
        let small = fixture.editor(lang: lang)
        await small.load()
        try render("artwork-small", in: output, size: NSSize(width: 900, height: 680),
                   LauncherView(stores: stores, library: fixture.library, performStartupChecks: false, artworkEditor: small, artworkStore: store))

        // A file dragged over the panel
        let dropping = fixture.editor(slot: .thumbnail, lang: lang)
        await dropping.load()
        try render("artwork-drop", in: output, size: NSSize(width: ArtworkPanel.width, height: 760),
                   ArtworkPanel(editor: dropping, labels: { L10n.string($0, lang) }, dropped: true, save: {}, cancel: {}).environmentObject(PadFocus()))
    }


    /// With the panel open the library behind it is a preview: the hero and the selected card draw the draft.
    @MainActor func testThePanelPreviewsTheDraftWithoutWritingIt() async throws {
        fixture = try ArtworkFixture()
        let editor = fixture.editor()
        await editor.load()
        editor.select(editor.tiles[4])
        let drawn = GameLibrary.artwork(for: displayed(editor), slot: .hero, repo: "", banners: fixture.artwork)
        let saved = GameLibrary.artwork(for: fixture.game, slot: .hero, repo: "", banners: fixture.artwork)
        XCTAssertNotNil(drawn)
        XCTAssertNotNil(saved)
        XCTAssertNotEqual(drawn?.tiffRepresentation, saved?.tiffRepresentation, "the draft's screenshot is not the banner")
        XCTAssertEqual(fixture.library.games[0].artwork, GameArtwork(), "nothing is written before Save")
    }

    @MainActor private func displayed(_ editor: ArtworkEditor) -> LibraryGame {
        var shown = fixture.game
        shown.artwork = editor.draft
        return shown
    }
}
