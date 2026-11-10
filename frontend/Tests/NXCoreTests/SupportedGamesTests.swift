import XCTest
@testable import NXCore

final class SupportedGamesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("supported-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("dm/games"), withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func profile(_ id: String, tsv: String, readme: String? = nil) throws {
        let folder = root.appendingPathComponent("dm/games/" + id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try tsv.write(to: folder.appendingPathComponent("game.tsv"), atomically: true, encoding: .utf8)
        if let readme { try readme.write(to: folder.appendingPathComponent("README.md"), atomically: true, encoding: .utf8) }
    }

    func testReadsNameEditionVersionAndNotes() throws {
        try profile("0100000000010000", tsv: "# Super Mario Odyssey (Nintendo EPD's engine), update 1.4.1.\ntitle_id\t0100000000010000\nname\tSuper Mario Odyssey\npackage\tv393216\nbuild\tv393216\t1.4.1\tmain=aa\n",
                    readme: "# Super Mario Odyssey (`0100000000010000`)\n\nUpdate 1.4.1 (v393216) over the base game. See [the docs](x.md).\n\n## What it needs\n| a | b |\n")
        let game = try XCTUnwrap(SupportedGames.list(engineRoot: root.path).first)
        XCTAssertEqual(game.name, "Super Mario Odyssey")
        XCTAssertEqual(game.titleID, "0100000000010000")
        XCTAssertEqual(game.version, "1.4.1")
        XCTAssertEqual(game.edition, .unknown, "a first line that names no console says no edition")
        XCTAssertEqual(game.notes, "Update 1.4.1 (v393216) over the base game. See the docs.")
    }

    func testEditionComesFromTheProfileNotFromTheTitle() throws {
        try profile("040077201BE50000", tsv: "# Kirby Air Riders (Switch 2, update v458752, display version 1.3.3). Plays on the Mac\ntitle_id\t040077201BE50000\nname\tKirby Air Riders\npackage\tv458752\nbuild\tv458752\t1.3.3\tmain=a\n")
        try profile("01004D300C5AE000", tsv: "# Game profile of Kirby and the Forgotten Land (Switch, update 1.1.0 = v65536). Plays on the Mac\ntitle_id\t01004D300C5AE000\nname\tKirby and the Forgotten Land\npackage\tv65536\nbuild\tv65536\t?\tmain=b\n")
        let list = SupportedGames.list(engineRoot: root.path)
        XCTAssertEqual(list.map(\.name), ["Kirby Air Riders", "Kirby and the Forgotten Land"])
        XCTAssertEqual(list.map(\.edition), [.switch2, .switch1])
        XCTAssertEqual(list[1].version, "v65536", "an unknown display version shows the package id the profile states and nothing invented")
    }

    func testAFolderWithoutAProfileIsLeftOut() throws {
        try profile("0100AAAABBBBCCCC", tsv: "# notes only\n")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("dm/games/empty"), withIntermediateDirectories: true)
        XCTAssertEqual(SupportedGames.list(engineRoot: root.path), [])
        XCTAssertEqual(SupportedGames.list(engineRoot: ""), [])
    }

    func testLongNotesAreCutAtASentence() throws {
        let sentence = "This is one sentence about the profile. "
        let notes = String(repeating: sentence, count: 20)
        try profile("0100000000010000", tsv: "title_id\t0100000000010000\nname\tG\n", readme: "# G\n\n" + notes + "\n")
        let text = try XCTUnwrap(SupportedGames.list(engineRoot: root.path).first).notes
        XCTAssertLessThanOrEqual(text.count, SupportedGames.noteLimit)
        XCTAssertTrue(text.hasSuffix("profile."))
    }
}
