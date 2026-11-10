import CryptoKit
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

    func testTheSurveyWithoutAProfileIsFoundInTheBuildScript() {
        let engine = root + "/engine"
        XCTAssertFalse(GameFolder.engineSurveysWithoutProfile(engine))
        XCTAssertFalse(GameFolder.engineSurveysWithoutProfile(""))
        write("engine/scripts/build_ipa_from_nsp.py", Data("def survey_dump(src, out):\n    pass\n".utf8))
        XCTAssertFalse(GameFolder.engineSurveysWithoutProfile(engine), "the NUP survey is the mark")
        write("engine/scripts/build_ipa_from_nsp.py", Data("def survey_dump(src, out):\n    pass\ndef survey_nup(n, k, base, out):\n    pass\n".utf8))
        XCTAssertTrue(GameFolder.engineSurveysWithoutProfile(engine))
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

/// A NUP's header and package table (SPEC v1), as pack_nup.py reads them: enough for `readNUP`, no folders, files or data.
/// packages: (kind 0 base / 1 update / 2 add-on, title ID, version).
func syntheticNUP(_ packages: [(kind: UInt8, titleID: UInt64, version: UInt32)], size: Int? = nil, tocSHA: [UInt8]? = nil) -> Data {
    func put(_ d: inout [UInt8], _ o: Int, _ v: UInt64, _ n: Int) { for i in 0..<n { d[o + i] = UInt8(v >> (8 * UInt64(i)) & 0xFF) } }
    let total = 0x80 + 0x30 + packages.count * 0x40
    var d = [UInt8](repeating: 0, count: total)
    d.replaceSubrange(0..<4, with: [0x4E, 0x55, 0x50, 0x01])   // "NUP" version 1
    put(&d, 0x04, 0x80, 2); put(&d, 0x08, 0x80, 8); put(&d, 0x10, UInt64(0x30 + packages.count * 0x40), 8)
    put(&d, 0x40, UInt64(size ?? total), 8); put(&d, 0x48, UInt64(packages.count), 4)
    d.replaceSubrange(0x80..<0x84, with: [0x54, 0x4F, 0x43, 0x01])   // "TOC" 1
    put(&d, 0x84, UInt64(packages.count), 4)
    for (i, p) in packages.enumerated() {
        let o = 0x80 + 0x30 + i * 0x40
        put(&d, o, p.titleID, 8); put(&d, o + 20, UInt64(p.version), 4); d[o + 24] = p.kind
    }
    let sha = tocSHA?.count == 32 ? tocSHA! : Array(SHA256.hash(data: Data(d[0x80..<total])))
    d.replaceSubrange(0x18..<0x38, with: sha)
    return Data(d)
}

extension GameFolderTests {
    /// seedds/nxnative 423a674: a game in one NUP file (Hyrule Warriors: Age of Imprisonment is played this way). The launcher
    /// reads its title ID, updates and DLC from the package table.
    func testANUPFileIsReadFromItsPackageTable() throws {
        write("Bananza.nup", syntheticNUP([(0, 0x040074A01BF12000, 0), (1, 0x040074A01BF12800, 458752), (1, 0x040074A01BF12800, 65536), (2, 0x040074A01BF13001, 0)]))
        let path = root + "/Bananza.nup"
        XCTAssertTrue(GameFolder.isCandidate(path))
        XCTAssertTrue(GameFolder.isCandidate(root), "a folder that holds one")
        let c = try GameFolder.scan(path).get()
        XCTAssertEqual(c.titleIDHex, "040074A01BF12000")
        XCTAssertEqual(c.updates.map(\.version), [65536, 458752])
        XCTAssertEqual(c.dlc.map(\.titleID), [0x040074A01BF13001])
        XCTAssertEqual(c.scriptInput, path, "the script is given the file")
        XCTAssertEqual(c.folder, root)
        XCTAssertEqual(try GameFolder.scan(root).get(), c, "the folder that holds it reads the same")
    }

    /// pack_nup.py: a base may be an empty placeholder with title ID 0 when an update holds the whole game (Pokémon Pokopia).
    func testAPlaceholderBaseTakesTheUpdatesTitleID() throws {
        write("Pokopia.nup", syntheticNUP([(0, 0, 0), (1, 0x0400A3A01EE4C800, 655360)]))
        XCTAssertEqual(try GameFolder.scan(root + "/Pokopia.nup").get().titleIDHex, "0400A3A01EE4C000")
        write("None.nup", syntheticNUP([(0, 0, 0)]))
        let none = try GameFolder.readNUP(root + "/None.nup").get()
        XCTAssertFalse(none.hasTitleID, "left to the script, which reads it from the code")
    }

    func testABrokenNUPIsNamed() {
        write("Other.nup", Data("not a nup at all, just some bytes".utf8))
        XCTAssertEqual(GameFolder.scan(root + "/Other.nup").failureValue, .notNUP("Other.nup"))
        write("Half.nup", syntheticNUP([(0, 0x040074A01BF12000, 0)], size: 1 << 30))
        XCTAssertEqual(GameFolder.scan(root + "/Half.nup").failureValue, .nupPartial("Half.nup"))
        write("Damaged.nup", syntheticNUP([(0, 0x040074A01BF12000, 0)], tocSHA: [UInt8](repeating: 0xAA, count: 32)))
        XCTAssertEqual(GameFolder.scan(root + "/Damaged.nup").failureValue, .nupDamaged("Damaged.nup"))
        XCTAssertEqual(GameFolder.scan(root).failureValue, .severalNUPs(3))
    }

    /// build_ipa_from_nsp.py `nup_file`: a NUP in the folder is built before any game folders beside it, a package beside it is not.
    func testANUPBesideTheFoldersIsWhatTheScriptBuilds() throws {
        makeGame()
        write("Bananza.nup", syntheticNUP([(0, 0x040074A01BF12000, 0)]))
        XCTAssertEqual(try GameFolder.scan(root).get().nup, root + "/Bananza.nup")
        write("Game.nsp")
        XCTAssertEqual(GameFolder.scan(root).failureValue, .packageBeside("Game.nsp"))
    }

    func testOuterWrapperFoldersAndInnerSubfoldersResolveToTheGameFolder() throws {
        let game = root + "/Outer/Donkey Kong Bananza"
        write("Outer/Donkey Kong Bananza/base/exefs/main.npdm", Self.npdm(programID: 0x040074A01BF12000))
        mkdir("Outer/Donkey Kong Bananza/base/romfs")
        mkdir("Outer/Donkey Kong Bananza/updates/458752/romfs")
        mkdir("Outer/Donkey Kong Bananza/dlc/040074a01bf13001/0/romfs")

        for picked in [
            root,
            root + "/Outer",
            game + "/base",
            game + "/base/exefs",
            game + "/base/romfs",
            game + "/updates",
            game + "/updates/458752",
            game + "/updates/458752/romfs",
            game + "/dlc",
            game + "/dlc/040074a01bf13001",
            game + "/dlc/040074a01bf13001/0/romfs"
        ] {
            XCTAssertEqual(GameFolder.resolve(picked), game, "failed for \(picked)")
            XCTAssertTrue(GameFolder.isCandidate(picked), "failed for \(picked)")
            let c = try GameFolder.scan(picked).get()
            XCTAssertEqual(c.folder, game)
            XCTAssertEqual(c.titleIDHex, "040074A01BF12000")
            XCTAssertEqual(c.updates.map(\.version), [458752])
            XCTAssertEqual(c.dlc.map(\.titleID), [0x040074A01BF13001])
        }

        // An outer folder that also holds an NSP or a second game folder (at the same level or a mixed depth) is not unwrapped.
        write("Outer/Other [010015100B514000][v0].nsp")
        XCTAssertFalse(GameFolder.isCandidate(root + "/Outer"))
        try? FileManager.default.removeItem(atPath: root + "/Outer/Other [010015100B514000][v0].nsp")
        write("Outer/SecondGame/base/exefs/main.npdm", Self.npdm(programID: 0x0400C3F00006E000))
        mkdir("Outer/SecondGame/base/romfs")
        XCTAssertFalse(GameFolder.isCandidate(root + "/Outer"))

        // Mixed-depth collection: GameA at Collection/GameA/base (level 1) and GameB at Collection/Wrapper/GameB/base (level 2).
        let collection = root + "/Collection"
        write("Collection/GameA/base/exefs/main.npdm", Self.npdm(programID: 0x040074A01BF12000))
        mkdir("Collection/GameA/base/romfs")
        write("Collection/Wrapper/GameB/base/exefs/main.npdm", Self.npdm(programID: 0x0400A3A01EE4C000))
        mkdir("Collection/Wrapper/GameB/base/romfs")
        XCTAssertEqual(GameFolder.resolve(collection), collection, "a mixed-depth collection of two games must not pick GameA")
        XCTAssertFalse(GameFolder.isCandidate(collection))
        XCTAssertEqual(GameFolder.scan(collection).failureValue, .missing("base/exefs/main.npdm"))
        XCTAssertEqual(GameFolder.resolve(collection + "/Wrapper"), collection + "/Wrapper/GameB", "the single-game wrapper inside the collection still resolves")

        // A parent above a collection holding GameA.nup beside DumpB/base must not unwrap through Collection to DumpB.
        let nupParent = root + "/NupCollectionParent"
        let nupCollection = nupParent + "/Collection"
        write("NupCollectionParent/Collection/GameA.nup", syntheticNUP([(0, 0x040074A01BF12000, 0)]))
        write("NupCollectionParent/Collection/DumpB/base/exefs/main.npdm", Self.npdm(programID: 0x0400A3A01EE4C000))
        mkdir("NupCollectionParent/Collection/DumpB/base/romfs")
        for dir in [nupParent, nupCollection] {
            XCTAssertEqual(GameFolder.resolve(dir), dir, "failed for \(dir)")
            XCTAssertFalse(GameFolder.isCandidate(dir), "failed for \(dir)")
        }
        XCTAssertEqual(GameFolder.resolve(nupCollection + "/DumpB"), nupCollection + "/DumpB")
        XCTAssertTrue(GameFolder.isCandidate(nupCollection + "/DumpB"))
    }

    func testAnUpdateOnlyDumpWithoutABaseFolderIsAccepted() throws {
        write("updates/131072/exefs/main.npdm", Self.npdm(programID: 0x040074A01BF12000))
        XCTAssertTrue(GameFolder.isCandidate(root))
        XCTAssertEqual(GameFolder.scan(root).failureValue, .missing("updates/131072/romfs"))
        mkdir("updates/131072/romfs")
        let c = try GameFolder.scan(root).get()
        XCTAssertEqual(c.titleIDHex, "040074A01BF12000")
        XCTAssertEqual(c.basePath, root + "/updates/131072")
        XCTAssertEqual(c.updates.map(\.version), [131072])
    }
}

extension Result {
    var failureValue: Failure? { if case .failure(let e) = self { return e }; return nil }
}
