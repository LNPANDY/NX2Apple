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

    func testIncludeMacNativeGamesCompletesAllThirteenWithoutDuplicates() throws {
        try profile(
            "0100F2C0115B6000",
            tsv: "# The Legend of Zelda: Tears of the Kingdom (Switch, update 1.4.3).\ntitle_id\t0100F2C0115B6000\nname\tThe Legend of Zelda: Tears of the Kingdom\npackage\tv720896\nbuild\tv720896\t1.4.3\tmain=aa\n",
            readme: "# TOTK\n\nExisting upstream profile notes.\n"
        )
        try profile(
            "0100000000010000",
            tsv: "# Super Mario Odyssey (Switch).\ntitle_id\t0100000000010000\nname\tSuper Mario Odyssey\n",
            readme: "# SMO\n\nOdyssey notes.\n"
        )
        try profile(
            "0100152000022000",
            tsv: "# Mario Kart 8 Deluxe (Switch).\ntitle_id\t0100152000022000\nname\tMario Kart 8 Deluxe\n",
            readme: "# MK8D\n\nMK8D notes.\n"
        )

        let raw = SupportedGames.list(engineRoot: root.path, includeMacNativeGames: false)
        XCTAssertEqual(Set(raw.map(\.titleID)), ["0100F2C0115B6000", "0100000000010000", "0100152000022000"])

        let completed = SupportedGames.list(engineRoot: root.path, includeMacNativeGames: true)
        let ids = completed.map(\.titleID)
        XCTAssertEqual(ids.count, Set(ids).count, "must not duplicate existing profiles")
        XCTAssertEqual(Set(ids), MacNativeGamesBuilder.supportedTitleIDs.union(["0100152000022000"]))
        XCTAssertEqual(ids.count, 14)

        let totk = try XCTUnwrap(completed.first { $0.titleID == "0100F2C0115B6000" })
        XCTAssertEqual(totk.version, "1.4.3")
        XCTAssertEqual(totk.notes, "Existing upstream profile notes.")

        let odyssey = try XCTUnwrap(completed.first { $0.titleID == "0100000000010000" })
        XCTAssertEqual(odyssey.notes, "Odyssey notes.", "existing dm/games entry must not be overwritten")

        let worldend = try XCTUnwrap(completed.first { $0.titleID == "010048900CF64000" })
        XCTAssertEqual(worldend.name, "WORLDEND SYNDROME")
        XCTAssertEqual(worldend.edition, .switch1)

        let tmnt = try XCTUnwrap(completed.first { $0.titleID == "0100FE701475A000" })
        XCTAssertEqual(tmnt.name, "Teenage Mutant Ninja Turtles: Shredder's Revenge")
        XCTAssertEqual(tmnt.edition, .switch1)

        let oot = try XCTUnwrap(completed.first { $0.titleID == "0400486024DEC000" })
        XCTAssertEqual(oot.name, "The Legend of Zelda: Ocarina of Time")
        XCTAssertEqual(oot.edition, .switch2)
        XCTAssertFalse(oot.notes.isEmpty)

        let pokopia = try XCTUnwrap(completed.first { $0.titleID == "0400A3A01EE4C000" })
        XCTAssertEqual(pokopia.edition, .switch2)
        XCTAssertFalse(pokopia.notes.isEmpty)
    }
}
