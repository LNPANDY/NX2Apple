import AppKit
import Combine
import ImageIO
import XCTest
@testable import NX2Apple
@testable import NXCore

/// A game, its library and an ArtworkEditorEnvironment that never leaves the temporary folder: the title list says what the test
/// scripts, the images are generated, and downloads can be held back.
@MainActor final class ArtworkFixture {
    let temporary: URL
    let artwork: URL
    let titleID = "0100535012974000"
    let gameID = UUID(uuidString: "6E1D2B64-0000-4000-8000-000000000001")!
    let library: GameLibrary
    /// What `media` answers, one per call: the last one again when the list runs out.
    var mediaResults: [ArtworkStore.MediaLoad] = []
    /// Every `retrying` flag `media` was called with.
    private(set) var retries: [Bool] = []
    var holdDownloads = false
    var failingScreenshots: Set<Int> = []
    var holdMedia = false
    /// `others` are more games in the library, each with a generated banner (the visual QA wants a row of cards).
    init(banner: Bool = true, screenshots: Int = 6, saved: String = "", others: [(titleID: String, name: String)] = []) throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-editor-" + UUID().uuidString)
        artwork = temporary.appendingPathComponent("artwork")
        try FileManager.default.createDirectory(at: artwork, withIntermediateDirectories: true)
        let file = temporary.appendingPathComponent("library.json")
        let more = others.enumerated().map { #",{"id":"6E1D2B64-0000-4000-8000-00000000010\#($0.offset)","titleID":"\#($0.element.titleID)","name":"\#($0.element.name)"}"# }.joined()
        try Data(#"{"games":[{"id":"\#(gameID.uuidString)","titleID":"\#(titleID)","name":"Hades"\#(saved)}\#(more)],"folder":""}"#.utf8).write(to: file)
        for (index, other) in others.enumerated() {
            try Self.picture(artwork.appendingPathComponent(other.titleID + ".jpg"), width: 1920, height: 1080, hue: 0.3 + 0.17 * CGFloat(index), label: other.name)
        }
        library = GameLibrary(file: file, artwork: artwork)
        if banner { try Self.picture(artwork.appendingPathComponent(titleID + ".jpg"), width: 1920, height: 1080, hue: 0.08, label: "Banner") }
        mediaResults = [.loaded(ArtworkStore.Media(screenshots: (0..<screenshots).map { "shot-\($0)" }))]
    }

    func cleanup() { try? FileManager.default.removeItem(at: temporary) }

    var game: LibraryGame { library.games[0] }
    var customDirectory: URL { ArtworkStore.customDirectory(for: gameID, in: artwork) }

    func environment() -> ArtworkEditorEnvironment {
        var env = ArtworkEditorEnvironment.live(store: ArtworkStore(directory: artwork, titleList: temporary.appendingPathComponent("none.json"), allowsFileURLs: true))
        env.media = { [unowned self] _, retrying in
            retries.append(retrying)
            while holdMedia && !Task.isCancelled { try? await Task.sleep(nanoseconds: 10_000_000) }
            return mediaResults.count > 1 ? mediaResults.removeFirst() : (mediaResults.first ?? .none)
        }
        env.candidate = { [unowned self] source, id in
            while holdDownloads { try await Task.sleep(nanoseconds: 10_000_000) }
            guard case .screenshot(let n) = source, !failingScreenshots.contains(n) else { throw URLError(.cannotConnectToHost) }
            let file = artwork.appendingPathComponent(id).appendingPathComponent("screenshot-\(n).jpg")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.picture(file, width: 1920, height: 1080, hue: 0.12 * CGFloat(n + 2), label: "Screenshot \(n + 1)")
            return file
        }
        return env
    }

    func editor(slot: ArtworkSlot = .hero, lang: Lang = .en) -> ArtworkEditor {
        ArtworkEditor(game: game, slot: slot, artworkDirectory: artwork, env: environment(), labels: { L10n.string($0, lang) })
    }

    /// A generated picture of exactly this many pixels: a colour and a label, never a real game's image.
    static func picture(_ url: URL, width: Int, height: Int, hue: CGFloat, label: String, type: NSBitmapImageRep.FileType = .jpeg) throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                 isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(hue: hue.truncatingRemainder(dividingBy: 1), saturation: 0.5, brightness: 0.55, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSColor(white: 1, alpha: 0.18).setFill()
        NSRect(x: CGFloat(width) * 0.55, y: 0, width: CGFloat(width) * 0.45, height: CGFloat(height)).fill()
        NSAttributedString(string: label, attributes: [.font: NSFont.boldSystemFont(ofSize: CGFloat(height) / 6), .foregroundColor: NSColor.white])
            .draw(at: NSPoint(x: CGFloat(width) * 0.06, y: CGFloat(height) * 0.4))
        NSGraphicsContext.restoreGraphicsState()
        try XCTUnwrap(rep.representation(using: type, properties: [:])).write(to: url)
    }

    func chosenImage(width: Int, height: Int? = nil, name: String = "mine.png", hue: CGFloat = 0.6) throws -> URL {
        let url = temporary.appendingPathComponent(name)
        try Self.picture(url, width: width, height: height ?? width * 9 / 16, hue: hue, label: "My image", type: .png)
        return url
    }
}

final class ArtworkEditorTests: XCTestCase {
    private var fixture: ArtworkFixture!

    override func tearDown() async throws { await MainActor.run { fixture?.cleanup() } }

    @MainActor private func loaded(banner: Bool = true, slot: ArtworkSlot = .hero, saved: String = "") async throws -> ArtworkEditor {
        fixture = try ArtworkFixture(banner: banner, saved: saved)
        let editor = fixture.editor(slot: slot)
        await editor.load()
        return editor
    }


    @MainActor func testTheGridHoldsTheBannerTheScreenshotsAndTheDefaultHeroIsTheBanner() async throws {
        let editor = try await loaded()
        XCTAssertEqual(editor.loadState, .loaded)
        XCTAssertEqual(editor.tiles.map(\.id), ["banner"] + (0..<6).map { "screenshot.\($0)" })
        XCTAssertEqual(editor.tiles.filter(\.isSelected).map(\.id), ["banner"])
        XCTAssertTrue(editor.tiles.allSatisfy(\.isAvailable), "every screenshot has arrived")
        XCTAssertFalse(editor.isDirty)
    }

    @MainActor func testArrowsMoveByRowsOfThreeAndChooseWhatTheyLandOn() async throws {
        let editor = try await loaded()   // seven tiles: row one 0...2, row two 3...5, row three 6
        func at(_ index: Int) { XCTAssertEqual(editor.cursor, index); XCTAssertEqual(editor.draft.hero?.source, index == 0 ? .banner : .screenshot(index - 1), "tile \(index)") }
        editor.move(.down); at(3)
        editor.move(.right); at(4)
        editor.move(.right); at(5)
        editor.move(.right); at(5)   // the end of a row does not wrap onto the next
        editor.move(.down); at(5)   // 8 does not exist
        editor.move(.up); at(2)
        editor.move(.left); editor.move(.left); at(0)
        editor.move(.left); at(0)
        editor.move(.down); editor.move(.down); at(6)
        editor.move(.right); at(6)
        editor.move(.down); at(6)
        XCTAssertEqual(editor.tiles.filter(\.isSelected).count, 1)
    }

    @MainActor func testReturnAndSpaceChooseTheTileTheArrowsAreOn() async throws {
        let editor = try await loaded()
        editor.move(.right)   // the screenshot 1 is chosen already
        editor.reset(.hero)
        XCTAssertNil(editor.draft.hero)
        editor.selectCursor()
        XCTAssertEqual(editor.draft.hero?.source, .banner, "the cursor is back on the banner, and Return chooses it")
    }

    @MainActor func testWithNoBannerTheFirstScreenshotIsTheDefaultHero() async throws {
        let editor = try await loaded(banner: false)
        XCTAssertEqual(editor.tiles.map(\.id), (0..<6).map { "screenshot.\($0)" })
        XCTAssertEqual(editor.tiles.filter(\.isSelected).map(\.id), ["screenshot.0"])
        editor.slot = .thumbnail
        XCTAssertEqual(editor.tiles.filter(\.isHero).map(\.id), ["screenshot.0"], "the thumbnail follows it")
    }

    @MainActor func testTheThumbnailTabsHeroTileIsBadgedAndSelectedUntilAnotherImageDetaches() async throws {
        let editor = try await loaded()
        editor.select(editor.tiles[2])   // the hero is the screenshot 2
        editor.slot = .thumbnail
        XCTAssertEqual(editor.tiles.filter(\.isHero).map(\.id), ["screenshot.1"])
        XCTAssertEqual(editor.tiles.filter(\.isSelected).map(\.id), ["screenshot.1"], "the thumbnail follows the hero")
        XCTAssertNil(editor.draft.thumbnail)
        XCTAssertFalse(editor.canReset(.thumbnail))

        editor.select(editor.tiles[4])
        XCTAssertEqual(editor.draft.thumbnail?.source, .screenshot(3))
        XCTAssertEqual(editor.tiles.filter(\.isSelected).map(\.id), ["screenshot.3"])
        XCTAssertEqual(editor.tiles.filter(\.isHero).map(\.id), ["screenshot.1"], "the badge stays on the hero's image")
        XCTAssertTrue(editor.canReset(.thumbnail))

        editor.select(editor.tiles[2])   // the hero's tile again
        XCTAssertNil(editor.draft.thumbnail, "choosing it makes the thumbnail follow the hero again")
        XCTAssertEqual(editor.draft.hero?.source, .screenshot(1))

        editor.slot = .hero
        XCTAssertTrue(editor.tiles.filter(\.isHero).isEmpty, "the badge is the thumbnail tab's")
    }

    @MainActor func testADraftIsDirtyAndEachSlotResetsOnItsOwn() async throws {
        let editor = try await loaded()
        XCTAssertFalse(editor.isDirty)
        XCTAssertFalse(editor.canReset(.hero))
        editor.select(editor.tiles[3])
        XCTAssertTrue(editor.isDirty)
        XCTAssertTrue(editor.canReset(.hero))
        editor.slot = .thumbnail
        editor.select(editor.tiles[5])
        XCTAssertTrue(editor.canReset(.thumbnail))
        editor.reset(.thumbnail)
        XCTAssertNil(editor.draft.thumbnail)
        XCTAssertNotNil(editor.draft.hero, "resetting the thumbnail leaves the hero")
        XCTAssertTrue(editor.isDirty)
        editor.reset(.hero)
        XCTAssertFalse(editor.isDirty, "back to what was saved")
        XCTAssertFalse(editor.canReset(.hero))
    }


    @MainActor func testSaveWritesTheDraftToTheLibraryAndItIsKept() async throws {
        let editor = try await loaded()
        editor.select(editor.tiles[3])
        editor.slot = .thumbnail
        editor.select(editor.tiles[5])
        XCTAssertEqual(fixture.library.games[0].artwork, GameArtwork(), "nothing is written before Save")
        XCTAssertTrue(editor.save(to: fixture.library))
        XCTAssertEqual(fixture.library.games[0].artwork.hero?.source, .screenshot(2))
        XCTAssertEqual(fixture.library.games[0].artwork.thumbnail?.source, .screenshot(4))
        XCTAssertFalse(editor.isDirty)
        let reloaded = GameLibrary(file: fixture.temporary.appendingPathComponent("library.json"), artwork: fixture.artwork)
        XCTAssertEqual(reloaded.games[0].artwork, fixture.library.games[0].artwork, "saved to the library file")
        XCTAssertFalse(editor.save(to: fixture.library), "nothing changed since")
    }

    @MainActor func testCancelLeavesTheLibraryAloneAndRemovesAnImportThatWasNotSaved() async throws {
        let editor = try await loaded()
        await editor.importFile(try fixture.chosenImage(width: 2400))
        let copies = try FileManager.default.contentsOfDirectory(atPath: fixture.customDirectory.path)
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(editor.draft.hero?.source, .imported(copies[0]))
        editor.cancel()
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: fixture.customDirectory.path)) ?? [], [], "the copy made in this session is gone")
        XCTAssertEqual(fixture.library.games[0].artwork, GameArtwork())
    }

    @MainActor func testCancelKeepsTheCopyTheSavedArtworkUses() async throws {
        let first = try ArtworkFixture()
        fixture = first
        let prepared = try ArtworkImport.prepare(try first.chosenImage(width: 2400), kind: .hero, into: first.customDirectory)
        first.library.setArtwork(GameArtwork(hero: ArtworkChoice(source: .imported(prepared.url.lastPathComponent))), for: first.gameID)
        let editor = first.editor()
        await editor.load()
        XCTAssertEqual(editor.tiles.filter { if case .imported = $0.source { return true } else { return false } }.count, 1, "the saved image is a tile")
        XCTAssertEqual(editor.tiles.filter(\.isSelected).map(\.id), ["imported." + prepared.url.lastPathComponent])
        await editor.importFile(try first.chosenImage(width: 2400))   // the same pixels again: the same file
        editor.select(editor.tiles[0])
        editor.cancel()
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.url.path), "the saved artwork still uses it")
    }

    @MainActor func testSavingRemovesTheCopiesNoSlotUsesAnyMore() async throws {
        let editor = try await loaded()
        await editor.importFile(try fixture.chosenImage(width: 2400, name: "a.png", hue: 0.2))
        await editor.importFile(try fixture.chosenImage(width: 2400, name: "b.png", hue: 0.7))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.customDirectory.path).count, 2)
        XCTAssertTrue(editor.save(to: fixture.library))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.customDirectory.path).count, 1, "only the one the hero uses")
    }


    @MainActor func testOfflineShowsWhatThereIsAndTryAgainLoadsTheScreenshots() async throws {
        fixture = try ArtworkFixture()
        fixture.mediaResults = [.offline, .loaded(ArtworkStore.Media(screenshots: ["a", "b"]))]
        let editor = fixture.editor()
        await editor.load()
        XCTAssertEqual(editor.loadState, .offline)
        XCTAssertEqual(editor.tiles.map(\.id), ["banner"], "the banner and the player's own files stay")
        await editor.importFile(try fixture.chosenImage(width: 2400))
        XCTAssertEqual(editor.tiles.count, 2, "Choose file works offline")
        await editor.load(retrying: true)
        XCTAssertEqual(editor.loadState, .loaded)
        XCTAssertEqual(editor.tiles.map(\.id).filter { $0.hasPrefix("screenshot") }, ["screenshot.0", "screenshot.1"])
        XCTAssertEqual(fixture.retries, [false, true])
    }

    @MainActor func testATitleWithNothingElseKeepsTheBannerAndTheFileChoice() async throws {
        fixture = try ArtworkFixture()
        fixture.mediaResults = [.none]
        let editor = fixture.editor()
        await editor.load()
        XCTAssertEqual(editor.loadState, .none)
        XCTAssertEqual(editor.tiles.map(\.id), ["banner"])
    }

    @MainActor func testAScreenshotIsAPlaceholderUntilItsFileArrivesAndCannotBeChosenBefore() async throws {
        fixture = try ArtworkFixture()
        fixture.holdDownloads = true
        let editor = fixture.editor()
        let loading = Task { await editor.load() }
        for _ in 0..<50 where editor.tiles.count < 7 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(editor.tiles.count, 7)
        XCTAssertEqual(editor.tiles.filter(\.isAvailable).map(\.id), ["banner"], "the screenshots are listed, not downloaded")
        XCTAssertFalse(editor.select(editor.tiles[1]))
        XCTAssertFalse(editor.isDirty)
        var changes = 0   // the view redraws as each screenshot arrives, not once at the end
        let watching = editor.objectWillChange.sink { changes += 1 }
        fixture.holdDownloads = false
        await loading.value
        watching.cancel()
        XCTAssertGreaterThanOrEqual(changes, 6)
        XCTAssertTrue(editor.tiles.allSatisfy(\.isAvailable))
        XCTAssertTrue(editor.select(editor.tiles[1]))
    }

    @MainActor func testAFailedDownloadStaysAnEmptyTileAndTheOthersArrive() async throws {
        fixture = try ArtworkFixture()
        fixture.failingScreenshots = [1]
        let editor = fixture.editor()
        await editor.load()
        XCTAssertEqual(editor.tiles.filter { !$0.isAvailable }.map(\.id), ["screenshot.1"])
        XCTAssertTrue(editor.tiles[2].isFailed)
        XCTAssertFalse(editor.select(editor.tiles[2]))
        XCTAssertTrue(editor.select(editor.tiles[3]))
    }


    @MainActor func testAnImportedFileIsChosenForTheTabItWasMadeOn() async throws {
        let editor = try await loaded()
        editor.slot = .thumbnail
        await editor.importFile(try fixture.chosenImage(width: 2400))
        guard case .imported(let name)? = editor.draft.thumbnail?.source else { return XCTFail("the thumbnail takes the file") }
        XCTAssertNil(editor.draft.hero)
        XCTAssertEqual(editor.tiles.last?.id, "imported." + name)
        XCTAssertEqual(editor.tiles.filter(\.isSelected).map(\.id), ["imported." + name])
        XCTAssertNil(editor.notice)
    }

    @MainActor func testAFileThatIsNoImageIsAnErrorForTheUIAndLeavesTheChoice() async throws {
        let editor = try await loaded()
        let text = fixture.temporary.appendingPathComponent("notes.png")
        try Data("not an image".utf8).write(to: text)
        await editor.importFile(text)
        XCTAssertEqual(editor.notice, .error(L10n.string("artwork.error.notImage", .en)))
        XCTAssertFalse(editor.isDirty)
        XCTAssertEqual(editor.tiles.count, 7)
    }

    @MainActor func testASmallImageIsChosenWithAWarningAndABadge() async throws {
        let editor = try await loaded()
        await editor.importFile(try fixture.chosenImage(width: 1000))
        XCTAssertEqual(editor.notice, .warning("This image is 1000 px wide. It may look soft."))
        XCTAssertTrue(editor.isDirty)
        XCTAssertTrue(try XCTUnwrap(editor.tiles.last).isLowResolution)
        editor.select(editor.tiles[0])
        XCTAssertNil(editor.notice, "the next choice clears it")
        editor.slot = .thumbnail
        XCTAssertFalse(try XCTUnwrap(editor.tiles.last).isLowResolution, "1000 px is plenty for a thumbnail")
    }

    @MainActor func testAnImportThatFinishesAfterTheEditorClosedIsNotKept() async throws {
        let editor = try await loaded()
        let image = try fixture.chosenImage(width: 2400)
        let importing = Task { await editor.importFile(image) }
        editor.cancel()
        await importing.value
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: fixture.customDirectory.path)) ?? [], [])
        XCTAssertNil(editor.draft.hero)
    }


    @MainActor func testTilesAreLabelledForVoiceOverWithTheirBadges() async throws {
        let editor = try await loaded()
        XCTAssertEqual(editor.label(for: editor.tiles[0]), "eShop banner")
        XCTAssertEqual(editor.label(for: editor.tiles[1]), "Screenshot 1")
        editor.slot = .thumbnail
        XCTAssertEqual(editor.label(for: editor.tiles[0]), "eShop banner, Hero")
        await editor.importFile(try fixture.chosenImage(width: 1000))
        XCTAssertEqual(editor.label(for: try XCTUnwrap(editor.tiles.last)), "Your image")
        XCTAssertEqual(editor.gridLabel, "Thumbnail choices")
    }


    @MainActor func testFramingIsOfferedOnlyWhenTheBandCutsFivePercentOrMore() async throws {
        let editor = try await loaded()   // 16:9 screenshots
        XCTAssertFalse(editor.needsFraming, "the size has not been read")
        await editor.measureSelected()
        XCTAssertTrue(editor.needsFraming, "the 2.4:1 hero cuts a quarter of a 16:9 image")
        editor.slot = .thumbnail
        await editor.measureSelected()
        XCTAssertFalse(editor.needsFraming, "the 1.8:1 card cuts about 1 % of it")
        editor.slot = .hero
        await editor.importFile(try fixture.chosenImage(width: 2400, height: 1000))
        await editor.measureSelected()
        XCTAssertEqual(editor.framingImageSize, CGSize(width: 2400, height: 1000))
        XCTAssertFalse(editor.needsFraming, "an image of the band's own proportions is not cropped")
    }

    @MainActor func testSetFocusClampsAndNudgeMovesByAStep() async throws {
        let editor = try await loaded()
        XCTAssertTrue(editor.isCentered)
        editor.setFocus(ArtworkFocus(x: 1.7, y: -3))
        XCTAssertEqual(editor.focus, ArtworkFocus(x: 1, y: 0))
        editor.recenter()
        XCTAssertEqual(editor.focus, .center)
        XCTAssertFalse(editor.isDirty, "back to the centre of the default hero: nothing to save, no Reset")
        XCTAssertFalse(editor.canReset(.hero))
        editor.nudge(.right); editor.nudge(.down)
        XCTAssertEqual(editor.focus, ArtworkFocus(x: 0.55, y: 0.55))
        editor.nudge(.left); editor.nudge(.left); editor.nudge(.up)
        XCTAssertEqual(editor.focus, ArtworkFocus(x: 0.45, y: 0.5))
        for _ in 0..<30 { editor.nudge(.right) }
        XCTAssertEqual(editor.focus.x, 1)
        XCTAssertEqual(editor.draft.hero?.source, .banner, "the default hero became the choice the point belongs to")
    }

    @MainActor func testAThumbnailPointDetachesItFromTheHeroButAHeroPointLeavesItAlone() async throws {
        let editor = try await loaded()
        editor.select(editor.tiles[2])
        editor.setFocus(ArtworkFocus(x: 0.2, y: 0.5))   // the hero's point
        XCTAssertNil(editor.draft.thumbnail)
        editor.slot = .thumbnail
        XCTAssertEqual(editor.focus.x, 0.2, "the thumbnail follows the hero's point too")
        editor.setFocus(ArtworkFocus(x: 0.9, y: 0.5))
        XCTAssertEqual(editor.draft.thumbnail, ArtworkChoice(source: .screenshot(1), focus: ArtworkFocus(x: 0.9, y: 0.5)), "with the hero's image")
        XCTAssertEqual(editor.draft.hero?.focus, ArtworkFocus(x: 0.2, y: 0.5), "the hero keeps its own")
        editor.slot = .hero
        editor.setFocus(ArtworkFocus(x: 0.4, y: 0.5))
        XCTAssertEqual(editor.draft.thumbnail?.focus, ArtworkFocus(x: 0.9, y: 0.5), "a hero point never moves a detached thumbnail")
    }

    @MainActor func testChoosingAnotherTileCentresThePointAgain() async throws {
        let editor = try await loaded()
        editor.select(editor.tiles[2])
        editor.setFocus(ArtworkFocus(x: 0.1, y: 0.5))
        editor.select(editor.tiles[2])
        XCTAssertEqual(editor.focus.x, 0.1, "the same image keeps its point")
        editor.select(editor.tiles[3])
        XCTAssertTrue(editor.isCentered)
    }

    @MainActor func testSaveWritesThePointAndCancelDoesNot() async throws {
        let editor = try await loaded()
        editor.select(editor.tiles[1])
        editor.setFocus(ArtworkFocus(x: 0.3, y: 0.5))
        XCTAssertTrue(editor.isDirty)
        XCTAssertEqual(fixture.library.games[0].artwork, GameArtwork(), "nothing is written before Save")
        editor.cancel()
        XCTAssertEqual(fixture.library.games[0].artwork, GameArtwork())
        XCTAssertTrue(editor.save(to: fixture.library))
        XCTAssertEqual(fixture.library.games[0].artwork.hero, ArtworkChoice(source: .screenshot(0), focus: ArtworkFocus(x: 0.3, y: 0.5)))
    }


    /// The library's folder read-only, the game's artwork folder writable: a Save that resets an imported hero fails, keeps the copy and
    /// the file as they were, and leaves the panel able to save once the folder is writable again.
    @MainActor func testASaveTheLibraryCannotWriteKeepsTheOldPictureAndCanBeRetried() async throws {
        let first = try await loaded()
        await first.importFile(try fixture.chosenImage(width: 2400))
        XCTAssertTrue(first.save(to: fixture.library))
        guard case .imported(let name)? = fixture.game.artwork.hero?.source else { return XCTFail("the hero is the imported file") }
        let copy = fixture.customDirectory.appendingPathComponent(name)
        let file = fixture.temporary.appendingPathComponent("library.json")
        let written = try Data(contentsOf: file)

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fixture.temporary.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.temporary.path) }
        let editor = fixture.editor()
        await editor.load()
        editor.reset(.hero)
        XCTAssertFalse(editor.save(to: fixture.library))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path), "the old picture is kept")
        XCTAssertEqual(try Data(contentsOf: file), written)
        XCTAssertEqual(fixture.game.artwork.hero?.source, .imported(name), "the library in memory is as it was too")
        guard case .error? = editor.notice else { return XCTFail("the panel says the save failed") }
        XCTAssertTrue(editor.isDirty)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.temporary.path)
        XCTAssertTrue(editor.save(to: fixture.library), "Save again once the folder is writable")
        XCTAssertNil(fixture.game.artwork.hero)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path), "removed once the new state is on disk")
    }

    /// A file being prepared when the tab changes still goes to the tab it was chosen on.
    @MainActor func testAnImportGoesToTheTabItStartedOnWhenTheTabChangesMeanwhile() async throws {
        fixture = try ArtworkFixture()
        var env = fixture.environment()
        let started = expectation(description: "preparing"), gate = DispatchSemaphore(value: 0), prepare = env.prepare
        env.prepare = { file, kind, directory in
            started.fulfill()
            gate.wait()
            return try prepare(file, kind, directory)
        }
        let editor = ArtworkEditor(game: fixture.game, slot: .hero, artworkDirectory: fixture.artwork, env: env, labels: { L10n.string($0, .en) })
        await editor.load()
        let file = try fixture.chosenImage(width: 2400)
        let importing = Task { await editor.importFile(file) }
        await fulfillment(of: [started], timeout: 5)
        editor.slot = .thumbnail
        gate.signal()
        await importing.value
        guard case .imported? = editor.draft.hero?.source else { return XCTFail("the hero gets the file") }
        XCTAssertNil(editor.draft.thumbnail, "the thumbnail still follows the hero")
    }

    /// No banner and one screenshot: the panel, the library's hero and card (which the preview and console mode draw) all show the
    /// screenshot, and Reset after an imported hero goes back to it.
    @MainActor func testWithNoBannerTheFirstScreenshotIsTheDefaultEverywhereAndAfterAReset() async throws {
        fixture = try ArtworkFixture(banner: false, screenshots: 1)
        let editor = fixture.editor()
        await editor.load()
        let shot = try XCTUnwrap(editor.selectedFile)
        XCTAssertEqual(editor.tiles.first { $0.isSelected }?.source, .screenshot(0))
        func shown(_ slot: ArtworkSlot) -> URL? { GameLibrary.artworkURLs(for: fixture.game, slot: slot, repo: "", banners: fixture.artwork).first }
        XCTAssertEqual(shown(.hero), shot)
        XCTAssertEqual(shown(.thumbnail), shot)

        await editor.importFile(try fixture.chosenImage(width: 2400))
        XCTAssertTrue(editor.save(to: fixture.library))
        XCTAssertNotEqual(shown(.hero), shot)
        let again = fixture.editor()
        await again.load()
        again.reset(.hero)
        XCTAssertEqual(again.tiles.first { $0.isSelected }?.source, .screenshot(0))
        XCTAssertTrue(again.save(to: fixture.library))
        XCTAssertEqual(shown(.hero), shot)
        XCTAssertEqual(shown(.thumbnail), shot)
    }

    /// VoiceOver's increment and decrement move the point along the axis the band crops: up and down for a 16:9 picture in the wider
    /// hero, sideways for a picture wider than the band.
    @MainActor func testVoiceOverAdjustsTheAxisTheBandCrops() async throws {
        let editor = try await loaded()
        editor.heroAspect = 2.4
        editor.select(editor.tiles[0])   // the 16:9 banner
        await editor.measureSelected()
        XCTAssertFalse(editor.cropsWidth)
        editor.adjustFocus(increment: true)
        XCTAssertEqual(editor.focus.x, 0.5)
        XCTAssertEqual(editor.focus.y, 0.5 + ArtworkEditor.nudgeStep, accuracy: 0.001)
        editor.adjustFocus(increment: false)
        XCTAssertEqual(editor.focus, .center)

        await editor.importFile(try fixture.chosenImage(width: 3000, height: 800, name: "wide.png"))   // 3.75 : 1, wider than the band
        await editor.measureSelected()
        XCTAssertTrue(editor.cropsWidth)
        editor.adjustFocus(increment: true)
        XCTAssertEqual(editor.focus.x, 0.5 + ArtworkEditor.nudgeStep, accuracy: 0.001)
        XCTAssertEqual(editor.focus.y, 0.5)
    }


    func testTheCopyIsInEveryLanguageAndFollowsTheRules() {
        let keys = ["title", "tab.hero", "tab.thumbnail", "banner", "screenshot", "yours", "heroBadge", "lowResBadge", "chooseFile", "dropHint.hero", "dropHint.thumbnail",
                    "loading", "offline", "retry", "reset.hero", "reset.thumbnail", "cancel", "save", "lowResWarning", "grid.hero", "grid.thumbnail", "framing", "framing.center", "framing.point", "framing.hint", "saveFailed",
                    ].map { "artwork." + $0 }
        for key in keys {
            let en = L10n.string(key, .en)
            for lang in Lang.all {
                let text = L10n.string(key, lang)
                XCTAssertNotEqual(text, key, "\(key) in \(lang)")
                XCTAssertFalse(text.isEmpty || text.contains(";") || text.contains("\u{FF1B}") || text.contains("..."), "\(key) in \(lang)")
                XCTAssertEqual(text.contains("%d"), en.contains("%d"), "\(key) in \(lang)")
            }
        }
    }
}
