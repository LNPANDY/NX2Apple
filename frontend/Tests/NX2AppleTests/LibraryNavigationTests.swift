import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXModel
@testable import NXLauncher

@MainActor final class LibraryNavigationTests: IsolatedDefaultsTestCase {
    private func settle(_ seconds: Double = 0.3) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    func testResponsiveLibraryGridWrapsAndNavigatesAtMultipleWidths() throws {
        for width in [CGFloat(900), 1257, 1900] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let games = (0..<18).map { LibraryGame(titleID: String(format: "%016llX", UInt64(0x0100000000000000) + UInt64($0) * 0x2000), name: "Game \($0)") }
            let file = root.appendingPathComponent("library.json")
            try JSONEncoder().encode(games).write(to: file)
            let library = GameLibrary(file: file), stores = LauncherStores(defaults: testDefaults), focus = PadFocus()
            let window = OffscreenWindow(size: .init(width: width, height: 900))
            window.contentView = NSHostingView(rootView: LauncherView(stores: stores, library: library, performStartupChecks: false, padFocus: focus))
            window.orderFront(nil)
            defer { window.contentView = nil; window.orderOut(nil) }
            settle(0.5)
            let cards = focus.frames["main", default: []].filter { $0.id.hasPrefix("card.") }.sorted {
                abs($0.frame.minY - $1.frame.minY) < 1 ? $0.frame.minX < $1.frame.minX : $0.frame.minY < $1.frame.minY
            }
            let columns = LibraryCardLayout.columns(in: width)
            XCTAssertGreaterThanOrEqual(cards.count, columns * 2)
            let first = try XCTUnwrap(cards.first)
            let below = cards[columns]
            XCTAssertGreaterThan(below.frame.minY, first.frame.maxY)
            XCTAssertEqual(first.frame.minX, below.frame.minX, accuracy: 1)
            XCTAssertEqual(first.frame.width, LibraryCardLayout.width(in: width) + 12, accuracy: 1)
            XCTAssertLessThanOrEqual(cards[columns - 1].frame.maxX, width - 30)
            focus.show(default: first.id); settle()
            focus.move(dx: 0, dy: 1); settle()
            XCTAssertEqual(focus.focused, below.id)
            focus.move(dx: 0, dy: -1); settle()
            XCTAssertEqual(focus.focused, first.id)
            if let output = ProcessInfo.processInfo.environment["NX_GRID_CAPTURE_DIR"], let view = window.contentView {
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let folder = URL(fileURLWithPath: output)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("grid-\(Int(width)).png"))
            }
        }
    }

    func testBackgroundBuildHandoffsPreserveLibrarySelectionAndControllerFocus() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let games = (0..<3).map { LibraryGame(titleID: String(format: "%016llX", UInt64(0x0100000000000000) + UInt64($0) * 0x2000), name: "Game \($0)") }
        let file = root.appendingPathComponent("library.json")
        try JSONEncoder().encode(games).write(to: file)
        let library = GameLibrary(file: file), stores = LauncherStores(defaults: testDefaults), focus = PadFocus()
        stores.repo.path = root.path; stores.deviceStore.checked = true
        let window = OffscreenWindow(size: .init(width: 1100, height: 720))
        window.contentView = NSHostingView(rootView: LauncherView(stores: stores, library: library, performStartupChecks: false, padFocus: focus))
        window.orderFront(nil)
        defer { window.contentView = nil; window.orderOut(nil); stores.build.running = false }
        settle(0.5)
        let target = "card." + games[0].id.uuidString
        library.selectedID = games[0].id; focus.show(default: target); settle()
        for game in games.dropFirst() {
            let slot = try XCTUnwrap(stores.build.slots.firstIndex { $0.id == "base" })
            stores.build.slots[slot].paths = [root.appendingPathComponent("Game [\(game.titleID)].nsp").path]
            stores.build.target = BuildTarget.mac; stores.build.runningTarget = BuildTarget.mac
            stores.build.running = true; settle()
            XCTAssertEqual(library.selectedID, games[0].id)
            XCTAssertEqual(focus.focused, target)
            stores.build.running = false; settle()
            XCTAssertEqual(library.selectedID, games[0].id)
            XCTAssertEqual(focus.focused, target)
        }
    }

    func testManageSpaceActivatesHighlightedRowAndSkipsDisabledControllerTargets() throws {
        let focus = PadFocus()
        var chosen: [String] = []
        let items = [ManageItem(id: "disabled", symbol: "hammer", title: "Disabled", enabled: false, run: {}),
                     ManageItem(id: "options", symbol: "slider.horizontal.3", title: "Options", run: { chosen.append("options") }),
                     ManageItem(id: "saves", symbol: "folder", title: "Saves", run: { chosen.append("saves") })]
        let window = OffscreenWindow(size: .init(width: 300, height: 200))
        window.contentView = NSHostingView(rootView: ManageMenuPanel(items: items, label: "Manage", close: {})
            .environmentObject(focus))
        window.orderFront(nil)
        defer { window.contentView = nil; window.orderOut(nil) }
        settle()
        XCTAssertFalse(focus.frames["manage", default: []].contains { $0.id == "manage.disabled" })
        for (code, text) in [(UInt16(125), "\u{F701}"), (UInt16(49), " ")] {
            NSApp.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text,
                isARepeat: false, keyCode: code)))
        }
        XCTAssertEqual(chosen, ["options"])
    }

    func testEveryManageSheetConsumesBackgroundActionsAndRestoresTheMenuButton() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let game = LibraryGame(titleID: "0100000000000000", name: "Routing fixture", inputs: ["base": [root.appendingPathComponent("Game.nsp").path]])
        let file = root.appendingPathComponent("library.json")
        try JSONEncoder().encode([game]).write(to: file)
        let library = GameLibrary(file: file), stores = LauncherStores(defaults: testDefaults)
        let focus = PadFocus(), gamepad = LauncherGamepad()
        let window = OffscreenWindow(size: .init(width: 1000, height: 680))
        window.contentView = NSHostingView(rootView: LauncherView(stores: stores, library: library,
            performStartupChecks: false, gamepad: gamepad, padFocus: focus))
        window.orderFront(nil)
        defer { window.contentView = nil; window.orderOut(nil) }
        settle(0.5)
        for (item, scope, target) in [("options", "launch", "opt.done"), ("saves", "saves", "saves.done"),
                                     ("cheats", "cheats", "cheats.done"), ("rename", "rename", "rename.cancel"),
                                     ("delete", "delete", "delete.cancel"), ("remove", "remove", "remove.cancel")] {
            focus.focused = nil; focus.show(default: "hero.manage")
            gamepad.perform(.a); settle()
            XCTAssertEqual(focus.scope, "manage", item)
            focus.focused = nil; focus.show(default: "manage." + item)
            XCTAssertEqual(focus.focused, "manage." + item)
            gamepad.perform(.a); settle(0.6)
            XCTAssertEqual(focus.scope, scope, item)
            for action in [LauncherGamepad.Action.x, .y, .l, .r] { gamepad.perform(action) }
            settle()
            XCTAssertEqual(focus.scope, scope, "background shortcuts must stay behind " + item)
            focus.focused = nil; focus.show(default: target)
            XCTAssertEqual(focus.focused, target)
            gamepad.perform(.a); settle(0.6)
            XCTAssertEqual(focus.scope, "main", item)
            XCTAssertEqual(focus.focused, "hero.manage", "closing " + item + " must restore its origin")
            XCTAssertEqual(library.games.count, 1)
            XCTAssertTrue(stores.build.basePath.isEmpty, "no hidden build action should fire")
        }
    }

    func testArtworkControllerFocusScrollsWithinShortPanelAndCannotActivateLibrary() async throws {
        let fixture = try ArtworkFixture(screenshots: 12)
        var environment = fixture.environment()
        let media = fixture.mediaResults[0]
        environment.media = { _, _ in media }
        let artwork = fixture.artwork
        environment.candidate = { source, id in
            guard case .screenshot(let n) = source else { throw URLError(.fileDoesNotExist) }
            return artwork.appendingPathComponent(id).appendingPathComponent("screenshot-\(n).jpg")
        }
        let editor = ArtworkEditor(game: fixture.game, slot: .hero, artworkDirectory: artwork, env: environment, labels: { L10n.string($0, .en) })
        defer { editor.cancel(); settle(); fixture.cleanup() }
        await editor.load()
        editor.setFocus(.init(x: 0.7, y: 0.5))
        await editor.measureSelected()
        let focus = PadFocus(), gamepad = LauncherGamepad(), stores = LauncherStores(defaults: testDefaults)
        let window = OffscreenWindow(size: .init(width: 1000, height: 680))
        window.contentView = NSHostingView(rootView: LauncherView(stores: stores, library: fixture.library,
            performStartupChecks: false, gamepad: gamepad, padFocus: focus, artworkEditor: editor))
        window.orderFront(nil)
        defer { window.contentView = nil; window.orderOut(nil) }
        settle(0.5)
        focus.scope = "artwork"
        let target = "artwork.framing.center"
        focus.focused = nil; focus.show(default: target)
        settle(0.5)
        let frame = try XCTUnwrap(focus.frames["artwork"]?.first { $0.id == target }?.frame, "framing=\(editor.needsFraming), centered=\(editor.isCentered), frames=\(focus.frames)")
        XCTAssertGreaterThanOrEqual(frame.minY, 0)
        XCTAssertLessThan(frame.maxY, 500, "the focused framing control must be above the fixed panel footer")
        for action in [LauncherGamepad.Action.x, .y, .l, .r] { gamepad.perform(action) }
        XCTAssertEqual(focus.scope, "artwork")
        gamepad.perform(.b); settle()
        XCTAssertEqual(focus.scope, "main")
        XCTAssertEqual(fixture.library.games[0].artwork, GameArtwork(), "Back discards the preview")
    }

    func testTestedValuesConfirmationBackClosesOnlyTheNestedQuestion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("Game.app"), dm = root.appendingPathComponent("Game.app/Contents/Resources/dm")
        let exe = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: exe, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dm, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["nxnative", "dmhost"] {
            try FileManager.default.createSymbolicLink(at: exe.appendingPathComponent(name), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        }
        let domain = TestPreferences.domain(in: root, "navigation")
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": domain, "CFBundleExecutable": "nxnative", "DMTitleID": "0100000000000000"], format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        try #"{"settings":[{"env":"DM_RUMBLE","kind":"toggle","label":"Rumble","note":"","default":"1","on":"1","off":"0","section":"Game"}]}"#
            .write(to: dm.appendingPathComponent("launcher.json"), atomically: true, encoding: .utf8)
        let library = GameLibrary(file: root.appendingPathComponent("library.json"))
        library.selectedID = try library.addApp(app)
        let focus = PadFocus(), gamepad = LauncherGamepad(), stores = LauncherStores(defaults: testDefaults)
        let window = OffscreenWindow(size: .init(width: 1100, height: 800))
        window.contentView = NSHostingView(rootView: LauncherView(stores: stores, library: library,
            performStartupChecks: false, gamepad: gamepad, padFocus: focus))
        window.orderFront(nil)
        defer { window.contentView = nil; window.orderOut(nil) }
        settle()
        gamepad.perform(.x); settle(0.6)
        focus.focused = nil; focus.show(default: "opt.DM_RUMBLE"); gamepad.perform(.a); settle()
        focus.focused = nil; focus.show(default: "opt.useTested"); gamepad.perform(.a); settle(0.6)
        XCTAssertEqual(focus.scope, "tested")
        gamepad.perform(.b); settle(0.6)
        XCTAssertEqual(focus.scope, "launch", "Back must leave Launch options open")
        XCTAssertTrue(focus.frames["launch", default: []].contains { $0.id == "opt.done" })
        gamepad.perform(.b); settle(0.6)
        XCTAssertEqual(focus.scope, "main")
    }

    func testRawControllerPacketsScrollLongGridAndKeepMenusModal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let games = (0..<20).map { LibraryGame(titleID: String(format: "%016llX", UInt64(0x0100000000000000) + UInt64($0) * 0x2000), name: String(format: "Game %02d", $0)) }
        let file = root.appendingPathComponent("library.json")
        try JSONEncoder().encode(games).write(to: file)
        let library = GameLibrary(file: file), stores = LauncherStores(defaults: testDefaults)
        let focus = PadFocus(), dropdowns = LauncherDropdownState(), source = SteamLinkGamepads(observeSystem: false)
        let gamepad = LauncherGamepad(steam: source, observeSystem: false, appIsActive: { true })
        var consoleEntries = 0
        let window = OffscreenWindow(size: .init(width: 1000, height: 680))
        window.contentView = NSHostingView(rootView: LauncherView(stores: stores, library: library,
            performStartupChecks: false, enterConsole: { consoleEntries += 1 }, gamepad: gamepad, padFocus: focus, dropdowns: dropdowns))
        window.orderFront(nil)
        defer { window.contentView = nil; window.orderOut(nil); gamepad.deactivate() }
        func press(_ usage: Int) {
            var packet = SteamVirtualGamepad()
            _ = packet.update(page: 9, usage: usage, value: 1, min: 0, max: 1)
            for state in [packet, SteamVirtualGamepad()] {
                NotificationCenter.default.post(name: .steamLinkPadInput, object: source,
                    userInfo: ["input": SteamLinkGamepads.Input(id: "library-test", state: state)])
                settle(0.04)
            }
        }
        settle()
        focus.show(default: "card." + games[0].id.uuidString)
        for _ in 1..<games.count {
            press(15)
            for _ in 0..<25 where focus.focused.flatMap({ focus.frame(of: $0) }) == nil { settle(0.02) }
        }
        settle(0.5)
        XCTAssertEqual(library.selectedID, games.last?.id)
        let frame = try XCTUnwrap(focus.frames["main"]?.first { $0.id == "card." + games.last!.id.uuidString }?.frame)
        XCTAssertGreaterThanOrEqual(frame.minX, 0)
        XCTAssertLessThanOrEqual(frame.maxX, 1000, "the selected card must scroll into view")
        XCTAssertGreaterThanOrEqual(frame.minY, 0)
        XCTAssertLessThanOrEqual(frame.maxY, 680)
        press(4); settle()
        XCTAssertEqual(focus.scope, "manage")
        press(10)
        XCTAssertEqual(consoleEntries, 0, "Select must not open console mode behind a menu")
        press(2); settle()
        XCTAssertEqual(focus.scope, "main")

        var picked: String?
        focus.focused = "library.sort"; settle(0.5)
        let sort = try XCTUnwrap(focus.frames["main"]?.first { $0.id == "library.sort" }?.frame)
        let point = CGPoint(x: sort.midX, y: window.contentView!.bounds.height - sort.midY)
        for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
        }
        settle()
        XCTAssertNotNil(dropdowns.request, "open the actual sort face")
        if let request = dropdowns.request {
            dropdowns.request = .init(id: request.id, options: request.options, selection: request.selection, label: request.label,
                choose: { picked = $0 })
        }
        press(13); settle(); press(1); settle()
        XCTAssertNotNil(picked)
        XCTAssertNil(dropdowns.request)
        XCTAssertEqual(focus.scope, "main")
        XCTAssertTrue(stores.build.basePath.isEmpty)
    }

    func testHeaderPlayerPickerCanBeChangedWithoutAPointer() throws {
        let stores = LauncherStores(defaults: testDefaults), focus = PadFocus()
        let first = stores.players.activeID
        let second = try XCTUnwrap(stores.players.create(name: "Second player"))
        stores.players.select(first)
        let window = OffscreenWindow(size: .init(width: 300, height: 80))
        window.contentView = NSHostingView(rootView: PlayerPicker(players: stores.players)
            .environmentObject(stores.localizer).environmentObject(focus).padScope("main", focus))
        window.orderFront(nil)
        defer { window.contentView = nil; window.orderOut(nil) }
        settle()
        focus.show(default: "top.player")
        XCTAssertEqual(focus.focused, "top.player")
        focus.horizontal(1); settle()
        XCTAssertEqual(stores.players.activeID, second.id)
        focus.activate(); settle()
        XCTAssertEqual(stores.players.activeID, first)
    }

    func testFreeSpaceQuestionCancelsWithinItsParentWithoutRemovingFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sentinel = root.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sentinel)
        let stores = LauncherStores(defaults: testDefaults), focus = PadFocus()
        let game = LibraryGame(titleID: "0100000000000000", name: "Free space fixture")
        let survey = BuildFolderSurvey(folder: root.path, sizes: [.extracted: 1000], kept: 100)
        let window = OffscreenWindow(size: .init(width: 560, height: 690))
        window.contentView = NSHostingView(rootView: FreeSpaceView(m: stores.build, game: game, survey: survey, chosen: [.extracted])
            .environmentObject(stores.localizer).environmentObject(focus))
        window.orderFront(nil)
        defer { window.contentView = nil; window.orderOut(nil) }
        focus.scope = "free"
        settle()
        focus.show(default: "free.remove"); focus.activate(); settle(0.5)
        XCTAssertEqual(focus.scope, "freeconfirm")
        focus.show(default: nil)
        XCTAssertEqual(focus.focused, "freeconfirm.cancel", "destructive confirmation starts on Cancel")
        XCTAssertTrue(focus.cancel()); settle(0.5)
        XCTAssertEqual(focus.scope, "free")
        XCTAssertEqual(focus.focused, "free.remove")
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "keep")
    }

    func testNativeModalWindowBlocksUnderlyingControllerActivation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("library.json")
        try JSONEncoder().encode([LibraryGame(titleID: "0100000000000000", name: "Modal fixture", inputs: ["base": ["/fixture/Game.nsp"]])]).write(to: file)
        let stores = LauncherStores(defaults: testDefaults), focus = PadFocus(), gamepad = LauncherGamepad()
        let window = OffscreenWindow(size: .init(width: 1000, height: 680))
        window.contentView = NSHostingView(rootView: LauncherView(stores: stores, library: GameLibrary(file: file),
            performStartupChecks: false, gamepad: gamepad, padFocus: focus))
        window.orderFront(nil)
        defer { window.contentView = nil; window.orderOut(nil) }
        settle()
        focus.show(default: "hero.play")
        let modal = OffscreenWindow(size: .init(width: 200, height: 100))
        DispatchQueue.main.async { gamepad.perform(.a); NSApp.stopModal() }
        NSApp.runModal(for: modal)
        modal.orderOut(nil)
        XCTAssertTrue(stores.build.basePath.isEmpty, "native pickers and modal dialogs must own input")
    }

    func testCarouselPagingStatePublishesAfterTheScrollLayoutFinishes() {
        let scroll = NSScrollView(frame: .init(x: 0, y: 0, width: 200, height: 100))
        scroll.documentView = NSView(frame: .init(x: 0, y: 0, width: 1000, height: 100))
        let row = RowScroller()
        row.attach(scroll)
        XCTAssertFalse(row.canBack)
        scroll.contentView.setBoundsOrigin(.init(x: 300, y: 0))
        XCTAssertFalse(row.canBack, "scroll layout must not publish SwiftUI state synchronously")
        settle(0.1)
        XCTAssertTrue(row.canBack)
        XCTAssertTrue(row.canForward)
    }
}
