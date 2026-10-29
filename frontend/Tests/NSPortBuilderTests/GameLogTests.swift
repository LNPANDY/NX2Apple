import XCTest
@testable import NSPortBuilder

/// Show game log and the log in Copy diagnostics: where dm/mac/launcher.c puts a game's log, which file is the latest, and
/// that only the end of a large log is read.
final class GameLogTests: XCTestCase {
    private var temporary: URL!
    private let id = "0100535012974000"

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-gamelog-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }

    private var home: String { temporary.appendingPathComponent("home").path }
    private var library: URL { temporary.appendingPathComponent("Library folder") }

    @discardableResult
    private func write(_ url: URL, _ text: String = "x\n", age: TimeInterval = 0) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        return url
    }

    func testAnAppOutsideALibraryLogsUnderLibraryLogs() {
        let app = temporary.appendingPathComponent("Apps/Hades.app").path
        XCTAssertEqual(GameLog.folders(appPath: app, home: home).map(\.path), [home + "/Library/Logs/nxnative"])
        XCTAssertEqual(GameLog.folders(appPath: "", home: home).map(\.path), [home + "/Library/Logs/nxnative"])
    }

    func testAnAppInALibraryFolderWithTheMarkerLogsBesideItFirst() throws {
        try write(library.appendingPathComponent(GameLog.marker), "")
        let folders = GameLog.folders(appPath: library.appendingPathComponent("Hades.app").path, home: home)
        XCTAssertEqual(folders.map(\.path), [library.path + "/log", home + "/Library/Logs/nxnative"])
    }

    func testTheLatestLogIsTheNewestFileAndNilWhenThereIsNone() throws {
        let app = library.appendingPathComponent("Hades.app").path
        XCTAssertNil(GameLog.latest(titleID: id, appPath: app, home: home))
        try write(library.appendingPathComponent(GameLog.marker), "")
        let old = try write(URL(fileURLWithPath: home + "/Library/Logs/nxnative/\(id).log"), age: 500)
        XCTAssertEqual(GameLog.latest(titleID: id, appPath: app, home: home), old, "the log from before the folder moved")
        let prev = try write(library.appendingPathComponent("log/\(id).prev.log"), age: 100)
        XCTAssertEqual(GameLog.latest(titleID: id, appPath: app, home: home), prev)
        let current = try write(library.appendingPathComponent("log/\(id).log"), age: 10)
        XCTAssertEqual(GameLog.latest(titleID: id, appPath: app, home: home), current)
        XCTAssertNil(GameLog.latest(titleID: "0100000000010000", appPath: app, home: home), "another game's log is not this one's")
    }

    func testEqualDatesPreferTheCurrentLogToThePreviousOne() throws {
        let stamp = Date()
        let folder = URL(fileURLWithPath: home + "/Library/Logs/nxnative")
        let prev = try write(folder.appendingPathComponent("\(id).prev.log"))
        let current = try write(folder.appendingPathComponent("\(id).log"))
        for url in [prev, current] { try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path) }
        XCTAssertEqual(GameLog.latest(titleID: id, appPath: "", home: home), current)
    }

    func testTheTailIsCappedAtTheLineLimit() throws {
        let log = try write(temporary.appendingPathComponent("a.log"), (1...500).map { "line \($0)" }.joined(separator: "\n") + "\n\n")
        let lines = try XCTUnwrap(GameLog.tail(log))
        XCTAssertEqual(lines.count, GameLog.lines)
        XCTAssertEqual(lines.first, "line 301")
        XCTAssertEqual(lines.last, "line 500")
        XCTAssertEqual(try XCTUnwrap(GameLog.tail(log, lines: 3)), ["line 498", "line 499", "line 500"])
        XCTAssertNil(GameLog.tail(temporary.appendingPathComponent("missing.log")))
    }

    func testOnlyTheEndOfAHugeLogIsRead() throws {
        let log = try write(temporary.appendingPathComponent("big.log"), (1...20000).map { "line number \($0)" }.joined(separator: "\n") + "\n")
        let lines = try XCTUnwrap(GameLog.tail(log, lines: 100_000, readLimit: 1000))
        XCTAssertLessThan(lines.count, 100)
        XCTAssertEqual(lines.last, "line number 20000")
        XCTAssertTrue(lines.allSatisfy { $0.hasPrefix("line number ") }, "a cut first line is dropped")
    }

    func testTheGameSectionReadsTheBuiltAppAndItsLog() throws {
        let app = library.appendingPathComponent("Hades.app")
        try write(app.appendingPathComponent("Contents/Info.plist"), "")
        let info: [String: Any] = ["DMForkPatches": "runtime-profile,romfsarc"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        try write(library.appendingPathComponent(GameLog.marker), "")
        try write(library.appendingPathComponent("log/\(id).log"), "fork patches: runtime-profile,romfsarc\nlauncher: Hades\n")
        let game = LibraryGame(titleID: id, name: "Hades", appPath: app.path)
        let section = Diagnostics.gameInfo(game, home: home)
        XCTAssertEqual(section.builtForkPatches, "runtime-profile,romfsarc")
        XCTAssertEqual(section.logPath, library.path + "/log/\(id).log")
        XCTAssertEqual(section.log, ["fork patches: runtime-profile,romfsarc", "launcher: Hades"])
        let unbuilt = Diagnostics.gameInfo(LibraryGame(titleID: id, name: "Hades"), home: home + "-none")
        XCTAssertNil(unbuilt.builtForkPatches)
        XCTAssertNil(unbuilt.logPath)
    }
}
