import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXModel
@testable import NXLauncher

/// The Builds list replaced SwiftUI's Table (it cost twice the time to open the tab). These tests hold what it keeps from the
/// table: the keys, the row lines, the columns, the order, the lazy rows and the controller moving through a long list.
@MainActor final class BuildInventoryListTests: IsolatedDefaultsTestCase {
    func testArrowKeysMoveTheSelectionAndStopAtTheEnds() {
        let ids = (0..<4).map { _ in UUID() }
        XCTAssertEqual(BuildListKeys.moved(from: nil, by: 1, in: ids), ids[0], "down with no selection selects the first row")
        XCTAssertEqual(BuildListKeys.moved(from: nil, by: -1, in: ids), ids[3], "up with no selection selects the last row")
        XCTAssertEqual(BuildListKeys.moved(from: ids[1], by: 1, in: ids), ids[2])
        XCTAssertEqual(BuildListKeys.moved(from: ids[1], by: -1, in: ids), ids[0])
        XCTAssertEqual(BuildListKeys.moved(from: ids[3], by: 1, in: ids), ids[3])
        XCTAssertEqual(BuildListKeys.moved(from: ids[0], by: -1, in: ids), ids[0])
        XCTAssertEqual(BuildListKeys.moved(from: UUID(), by: 1, in: ids), ids[0], "a selection the filter hid starts over")
        XCTAssertNil(BuildListKeys.moved(from: nil, by: 1, in: []))
    }

    func testRowLinesSkipTheLastRowAndTheSelection() {
        XCTAssertEqual((0..<4).map { BuildColumns.separator(below: $0, selected: nil, count: 4) }, [true, true, true, false])
        XCTAssertEqual((0..<4).map { BuildColumns.separator(below: $0, selected: 2, count: 4) }, [true, false, false, false])
        XCTAssertEqual((0..<4).map { BuildColumns.separator(below: $0, selected: 0, count: 4) }, [false, true, true, false])
    }

    private func withBuilds(count: Int, height: CGFloat = 720,
                            check: (GameLibrary, PadFocus, [LibraryGame]) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("build-list-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Names out of order, so the list must sort them.
        let games = (0..<count).map { i in
            LibraryGame(titleID: String(format: "%016llX", UInt64(0x0100000000000000) + UInt64(i) * 0x2000),
                        name: String(format: "Game %03d", (i * 37) % count), inputs: ["base": [root.appendingPathComponent("Game\(i).nsp").path]])
        }
        for i in 0..<count { try Data().write(to: root.appendingPathComponent("Game\(i).nsp")) }
        let file = root.appendingPathComponent("library.json")
        try JSONEncoder().encode(games).write(to: file)
        let library = GameLibrary(file: file), stores = LauncherStores(defaults: testDefaults)
        let marker = root.appendingPathComponent(EngineLayout.marker)
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: marker)
        stores.repo.path = root.path
        stores.dependencies.checked = true
        stores.deviceStore.checked = true
        let focus = PadFocus()
        let window = OffscreenWindow(size: .init(width: 1100, height: height))
        window.contentView = NSHostingView(rootView: LauncherView(stores: stores, library: library, initialPage: .builds,
                                                                  performStartupChecks: false, padFocus: focus))
        window.orderFront(nil)
        defer { window.contentView = nil; window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        try check(library, focus, library.games.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }

    private func frame(_ id: String, _ focus: PadFocus) -> CGRect? { focus.frames["main"]?.first { $0.id == id }?.frame }

    func testRowsFollowTheNamesAndLineUpUnderTheColumns() throws {
        try withBuilds(count: 5, height: 900) { _, focus, games in
            let rows = try games.map { game in
                try ["builds.game.", "builds.platform.\(BuildTarget.mac).", "builds.platform.\(BuildTarget.ios).", "builds.manage."].map { prefix in
                    try XCTUnwrap(frame(prefix + game.id.uuidString, focus), prefix + game.name)
                }
            }
            for (above, below) in zip(rows, rows.dropFirst()) {
                XCTAssertLessThan(above[0].midY, below[0].midY, "the rows are in name order")
            }
            for row in rows {
                XCTAssertLessThan(row[0].maxX, row[1].minX)
                XCTAssertEqual(row[2].minX - row[1].minX, BuildColumns.mac + BuildColumns.spacing, accuracy: 0.5, "Mac is 100 points wide")
                XCTAssertEqual(row[3].midX - row[2].minX, BuildColumns.mobile + BuildColumns.spacing + BuildColumns.manage / 2, accuracy: 0.5,
                               "iOS is 160 points wide and Manage sits in the middle of its column")
                for column in 0..<4 { XCTAssertEqual(row[column].midY, row[0].midY, accuracy: 0.5, "a row's cells share its middle") }
                XCTAssertEqual(row[1].minX, rows[0][1].minX, accuracy: 0.5)
            }
        }
    }

    func testOnlyTheVisibleRowsAreBuilt() throws {
        try withBuilds(count: 120) { _, focus, _ in
            let built = focus.frames["main", default: []].filter { $0.id.hasPrefix("builds.game.") }.count
            XCTAssertGreaterThan(built, 3)
            XCTAssertLessThan(built, 40, "a list of 120 games builds the rows on screen, not all of them")
        }
    }

    func testControllerWalksTheManageColumnAndRevealsTheRows() throws {
        try withBuilds(count: 35) { library, focus, games in
            focus.show(default: "builds.manage." + games[0].id.uuidString)
            focus.focused = "builds.manage." + games[0].id.uuidString
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            for _ in 1..<games.count {
                focus.move(dx: 0, dy: 1)
                RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            XCTAssertEqual(focus.focused, "builds.manage." + games.last!.id.uuidString)
            XCTAssertEqual(library.selectedID, games.last?.id, "the controller's row is the selected one")
            let last = try XCTUnwrap(frame(focus.focused!, focus), "the last row was scrolled into view")
            XCTAssertLessThan(last.maxY, 720)
            for _ in 0..<3 { focus.move(dx: 0, dy: -1); RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            XCTAssertEqual(focus.focused, "builds.manage." + games[games.count - 4].id.uuidString)
            XCTAssertEqual(library.selectedID, games[games.count - 4].id)
        }
    }
}
