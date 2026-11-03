import XCTest
@testable import NXCore

/// LNPANDY/NX2Apple#512 and #445: a Switch 2 game comes as a folder of its files (pack_dump.py's layout). The rules are the
/// script's, checked here on synthetic folders: an NPDM with only a program ID, empty RomFS folders, no game data.
final class GameFolderTests: XCTestCase {
    private var root = ""

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "gamefolder-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: root) }

    /// A minimal main.npdm: "META", the ACI0 offset and size at 0x70, "ACI0" with the program ID at +0x10.
    static func npdm(programID: UInt64) -> Data {
        var d = [UInt8](repeating: 0, count: 0x100)
        d.replaceSubrange(0..<4, with: Array("META".utf8))
        let off = 0x80, size = 0x40
        for i in 0..<4 { d[0x70 + i] = UInt8(off >> (8 * i) & 0xFF); d[0x74 + i] = UInt8(size >> (8 * i) & 0xFF) }
        d.replaceSubrange(off..<off + 4, with: Array("ACI0".utf8))
        for i in 0..<8 { d[off + 0x10 + i] = UInt8(programID >> (8 * UInt64(i)) & 0xFF) }
        return Data(d)
    }

    private func mkdir(_ rel: String) { try? FileManager.default.createDirectory(atPath: root + "/" + rel, withIntermediateDirectories: true) }
    private func write(_ rel: String, _ data: Data = Data([1])) {
        mkdir((rel as NSString).deletingLastPathComponent)
        FileManager.default.createFile(atPath: root + "/" + rel, contents: data)
    }

    /// Donkey Kong Bananza's layout (#512): base, one update, one DLC.
    private func makeGame(_ app: UInt64 = 0x040074A01BF12000) {
        write("base/exefs/main.npdm", Self.npdm(programID: app)); write("base/exefs/main"); mkdir("base/romfs")
        write("updates/458752/exefs/main.npdm", Self.npdm(programID: app)); mkdir("updates/458752/romfs")
        mkdir("dlc/040074a01bf13001/0/romfs")
    }

    func testTheLayoutOfTheScriptIsReadWithItsTitleIDUpdatesAndDLC() throws {
        makeGame()
        mkdir("updates/65536/romfs")
        XCTAssertTrue(GameFolder.isCandidate(root))
        let c = try GameFolder.scan(root).get()
        XCTAssertEqual(c.titleIDHex, "040074A01BF12000")
        XCTAssertEqual(c.updates.map(\.version), [65536, 458752])
        XCTAssertEqual(c.newestUpdate?.path, root + "/updates/458752")
        XCTAssertEqual(c.dlc.map(\.titleID), [0x040074A01BF13001])
        XCTAssertEqual(c.dlc.first?.path, root + "/dlc/040074a01bf13001")
        XCTAssertEqual(c.basePath, root + "/base")
    }

    func testAFolderOfPackagesIsNoCandidate() {
        write("Game [010015100B514000][v0].nsp")
        XCTAssertFalse(GameFolder.isCandidate(root))
    }

    func testTheMissingPieceIsNamed() {
        write("base/exefs/main.npdm", Self.npdm(programID: 0x040074A01BF12000))
        XCTAssertEqual(GameFolder.scan(root).failureValue, .missing("base/romfs"))
        try? FileManager.default.removeItem(atPath: root + "/base/exefs/main.npdm")
        mkdir("base/romfs")
        XCTAssertEqual(GameFolder.scan(root).failureValue, .missing("base/exefs/main.npdm"))
    }

    /// pack_dump.py at seedds/nxnative 641d148 takes a base without a RomFS when an update has its whole RomFS (Pokémon Pokopia).
    func testAnUpdateRomFSStandsInForTheBaseOne() throws {
        write("base/exefs/main.npdm", Self.npdm(programID: 0x0400A3A01EE4C000))
        mkdir("updates/655360/romfs")
        XCTAssertEqual(try GameFolder.scan(root).get().updates.map(\.version), [655360])
    }

    func testFilesOneLevelTooHighAskForABaseFolder() {
        write("exefs/main.npdm", Self.npdm(programID: 0x04007EF01F8AE000)); mkdir("romfs")
        XCTAssertTrue(GameFolder.isCandidate(root))
        XCTAssertEqual(GameFolder.scan(root).failureValue, .noBaseFolder)
    }

    /// build_ipa_from_nsp.py `dump_folder`: a package beside the folders is what the script builds, so the launcher refuses the mix.
    func testAPackageBesideTheFoldersIsNamed() {
        makeGame()
        write("Bananza.nsp")
        write("._Other.nsp")   // an AppleDouble file does not count
        XCTAssertEqual(GameFolder.scan(root).failureValue, .packageBeside("Bananza.nsp"))
    }

    func testAnNPDMWithoutAProgramIDIsRefused() {
        write("base/exefs/main.npdm", Data("not an npdm".utf8)); mkdir("base/romfs")
        XCTAssertEqual(GameFolder.scan(root).failureValue, .unreadableNPDM)
        XCTAssertNil(GameFolder.programID(npdm: Data()))
    }

    func testAnUpdateProgramIDIsNoBase() {
        write("base/exefs/main.npdm", Self.npdm(programID: 0x040074A01BF12800)); mkdir("base/romfs")
        XCTAssertEqual(GameFolder.scan(root).failureValue, .notBaseTitle(0x040074A01BF12800))
    }

    /// pack_dump.py `scan`: a DLC title ID in hex, above the base by 0x1001 to 0x1000 + 2000, one <n>/romfs folder.
    func testDLCFoldersFollowTheScriptsRules() {
        makeGame()
        mkdir("dlc/extra/0/romfs")
        XCTAssertEqual(GameFolder.scan(root).failureValue, .dlcName("extra"))
        try? FileManager.default.removeItem(atPath: root + "/dlc/extra")
        mkdir("dlc/010015100B515001/0/romfs")
        XCTAssertEqual(GameFolder.scan(root).failureValue, .notDLC("010015100B515001", 0x010015100B515001))
        try? FileManager.default.removeItem(atPath: root + "/dlc/010015100B515001")
        mkdir("dlc/040074a01bf13002/0/romfs"); mkdir("dlc/040074a01bf13002/1/romfs")
        XCTAssertEqual(GameFolder.scan(root).failureValue, .dlcRomFS("040074a01bf13002", 2))
        try? FileManager.default.removeItem(atPath: root + "/dlc/040074a01bf13002/1")
        XCTAssertEqual((try? GameFolder.scan(root).get())?.dlc.count, 2)
        // a romfs folder straight in dlc/<title ID> is taken too
        mkdir("dlc/040074A01BF13003/romfs")
        XCTAssertEqual((try? GameFolder.scan(root).get())?.dlc.map(\.titleID), [0x040074A01BF13001, 0x040074A01BF13002, 0x040074A01BF13003])
    }

    func testUpdateFoldersWithoutADecimalNameAreLeftOut() throws {
        makeGame()
        mkdir("updates/latest/romfs")
        XCTAssertEqual(try GameFolder.scan(root).get().updates.map(\.version), [458752])
    }

    func testTheEngineChecksLookForThePackerAndTheProfile() {
        let engine = root + "/engine"
        XCTAssertFalse(GameFolder.engineBuildsFolders(engine))
        XCTAssertFalse(GameFolder.engineBuildsFolders(""))
        write("engine/scripts/pack_dump.py")
        XCTAssertTrue(GameFolder.engineBuildsFolders(engine))
        XCTAssertFalse(GameFolder.engineHasProfile(0x040074A01BF12000, engineRoot: engine))
        write("engine/dm/games/040074A01BF12000/game.tsv")
        XCTAssertTrue(GameFolder.engineHasProfile(0x040074A01BF12000, engineRoot: engine))
    }
}

extension GameFolderTests {
    /// No profile key says "Switch 2" yet: the first line of every Switch 2 profile at seedds/nxnative 641d148 does (#445).
    func testTheProfilesFirstLineTellsASwitch2Game() {
        let engine = root + "/engine"
        write("engine/dm/games/040074A01BF12000/game.tsv", Data("# Donkey Kong Bananza (Switch 2, update v458752). In bring-up\ntitle_id\t040074A01BF12000\n".utf8))
        write("engine/dm/games/0100F2C0115B6000/game.tsv", Data("# The Legend of Zelda: Tears of the Kingdom (update v1.4.2)\n# mentions (Switch 2 Edition) later\n".utf8))
        write("engine/dm/games/0100000000010000/game.tsv", Data("title_id\t0100000000010000\n# (Switch 2\n".utf8))
        XCTAssertTrue(GameFolder.profileIsSwitch2("040074A01BF12000", engineRoot: engine))
        XCTAssertTrue(GameFolder.profileIsSwitch2("040074a01bf12000", engineRoot: engine))
        XCTAssertFalse(GameFolder.profileIsSwitch2("0100F2C0115B6000", engineRoot: engine), "only the first line counts")
        XCTAssertFalse(GameFolder.profileIsSwitch2("0100000000010000", engineRoot: engine), "only a comment line counts")
        XCTAssertFalse(GameFolder.profileIsSwitch2("0400000000000000", engineRoot: engine), "no profile")
        XCTAssertFalse(GameFolder.profileIsSwitch2("040074A01BF12000", engineRoot: ""))
    }
}

extension Result {
    var failureValue: Failure? { if case .failure(let e) = self { return e }; return nil }
}
