import XCTest
@testable import NXModel
@testable import NXCore

/// LNPANDY/NX2Apple#512 and #445: a Switch 2 game chosen as a folder of its files. The rows, the keys that are not needed, the
/// engine checks and the script's command, on a synthetic folder and a stand-in engine tree (no game data, nothing is built).
@MainActor final class GameFolderStoreTests: XCTestCase {
    private final class FakeRepo: RepoLocation {
        var path = ""
        var isRepo = true
        var isGit = true
    }

    private final class FakeDeps: DependencyInstalling {
        var pythonPath = "/usr/bin/python3"
        var dotnetPath = "/usr/bin/true"
        var checked = true
        var allPresent = true
        var deps: [Dep] = []
        func isInstalling(_ id: String) -> Bool { false }
        func install(_ dep: Dep) -> Task<Void, Never> { Task {} }
    }

    private final class FakeEngine: EngineSyncing {
        func syncEngine(then: ((Bool) -> Void)?) -> Task<Void, Never> { then?(true); return Task {} }
    }

    private final class FakeDevices: InstallTarget {
        var installDevice = ""
        var signingTeam = ""
        var exportIPA = false
        var exportOneGame = false
        var driveFolder = ""
        var devices: [AppleDevice] = []
        var xcrun = "/usr/bin/true"
        var readTeams: @Sendable () -> [SigningTeam] = { [] }
        func deviceName(_ udid: String) -> String { "iPhone" }
        nonisolated func askCopy(_ plan: ShellCopyPlan) -> ShellCopyDecision { .skip }
        nonisolated func setWaiting(_ on: Bool) {}
        nonisolated var waitCancelled: Bool { false }
        func copyEnded() {}
    }

    private var root = ""
    private var defaults: UserDefaults!
    private let repo = FakeRepo()
    private let runner = FakeProcessRunner()

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "gamefolder-store-" + UUID().uuidString
        defaults = TestDefaults.make("nxmodel-gamefolder")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func write(_ path: String, _ data: Data = Data([1])) {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: data)
    }

    private func mkdir(_ path: String) { try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true) }

    /// A minimal main.npdm with only the program ID.
    private func npdm(_ programID: UInt64) -> Data {
        var d = [UInt8](repeating: 0, count: 0x100)
        d.replaceSubrange(0..<4, with: Array("META".utf8))
        d[0x70] = 0x80; d[0x74] = 0x40
        d.replaceSubrange(0x80..<0x84, with: Array("ACI0".utf8))
        for i in 0..<8 { d[0x90 + i] = UInt8(programID >> (8 * UInt64(i)) & 0xFF) }
        return Data(d)
    }

    /// An engine tree (its marker, the build tools, pack_dump.py unless `packer` is false, a profile unless `profile` is false) and a game folder.
    private func makeStore(profile: Bool = true, packer: Bool = true) -> (BuildStore, String) {
        let engine = root + "/engine", game = root + "/Bananza"
        write(engine + "/" + EngineLayout.marker)
        for tool in RepoLayout.requiredTools { write(engine + "/" + tool, Data("ap.add_argument('--work-dir')".utf8)) }
        if packer { write(engine + "/scripts/pack_dump.py"); write(engine + "/scripts/pack_nup.py") }
        if profile { write(engine + "/dm/games/040074A01BF12000/game.tsv", Data("name\tDonkey Kong Bananza\n".utf8)) }
        write(game + "/base/exefs/main.npdm", npdm(0x040074A01BF12000)); mkdir(game + "/base/romfs")
        mkdir(game + "/updates/458752/romfs"); mkdir(game + "/updates/65536/romfs")
        mkdir(game + "/dlc/040074a01bf13001/0/romfs")
        repo.path = engine
        let store = BuildStore(localizer: Localizer(.en), runner: runner, repo: repo, deps: FakeDeps(), engine: FakeEngine(), devices: FakeDevices(),
                               defaults: defaults)
        store.cloudFolderCheck = { _ in false }
        store.target = BuildTarget.mac
        return (store, game)
    }

    func testAGameFolderFillsTheRowsAndNeedsNoKeys() {
        let (store, game) = makeStore()
        store.scan(folder: game)
        XCTAssertEqual(store.gameFolder?.titleIDHex, "040074A01BF12000")
        XCTAssertEqual(store.basePath, game + "/base")
        XCTAssertEqual(store.updatePath, game + "/updates/458752", "the newest update, as the script packs it")
        XCTAssertEqual(store.dlcPaths, [game + "/dlc/040074a01bf13001"])
        XCTAssertTrue(store.keysPath.isEmpty)
        XCTAssertTrue(store.canBuild, "no prod.keys for a game folder")
        XCTAssertEqual(store.gameFolderRowText("keys"), store.t("folder.keys"))
        XCTAssertEqual(store.gameFolderRowText("update"), String(format: store.t("folder.updates"), 458752, 2))
        XCTAssertEqual(store.gameFolderRowText("base"), String(format: store.t("folder.base"), "040074A01BF12000"))
        XCTAssertEqual(store.buildKey, "040074A01BF12000")
        XCTAssertEqual(store.inputFolder, game)
        XCTAssertEqual(store.gameName, "Donkey Kong Bananza", "the profile's name: a game folder has no control data")
    }

    func testTheScriptGetsTheFolderAndNoKeys() {
        let (store, game) = makeStore()
        store.scan(folder: game)
        store.startBuild()
        let args = store.lastBuildCommand
        XCTAssertEqual(args.dropFirst(2).first, game, "the folder is the script's input, not a staging folder")
        XCTAssertFalse(args.contains("-k"))
        XCTAssertEqual(args.firstIndex(of: "--work-dir").map { args[$0 + 1] }, game + "/040074A01BF12000_build")
        XCTAssertEqual(args.firstIndex(of: "-o").map { args[$0 + 1] }, game + "/040074A01BF12000_build/040074A01BF12000.app")
        XCTAssertTrue(args.contains("mac-app"))
    }

    /// #749: with nxb on, the same arguments go to `nxb build` and the script is not run.
    func testTheExperimentalBuilderGivesTheScriptsArgumentsToNxbBuildAndIsNamedInTheLog() {
        let (store, game) = makeStore()
        store.scan(folder: game)
        store.experimentalBuilder = false
        store.startBuild()
        let standard = store.lastBuildCommand
        XCTAssertFalse(store.log.text.contains("nxb"))
        let nxb = root + "/nxbuild/nxb"
        write(nxb)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: nxb)
        runner.answer = { _ in ProcessResult(status: 0, out: "nxb 0.6.3\n") }
        store.experimentalBuilder = true; store.experimentalBuilderPath = nxb
        store.startBuild()
        XCTAssertEqual(store.lastBuildCommand, [nxb, "build"] + standard.dropFirst(2), "nxb build in place of the interpreter and the script, the same options after")
        XCTAssertTrue(store.log.text.contains(String(format: store.t("msg.builderOn"), nxb)))
    }

    func testWithoutAProfileTheFolderIsRefusedWithTheTitleID() {
        let (store, game) = makeStore(profile: false)
        store.scan(folder: game)
        XCTAssertNil(store.gameFolder)
        XCTAssertTrue(store.gameFolderRefused)
        XCTAssertEqual(store.slot("base").problem, String(format: store.t("folder.noProfile"), "040074A01BF12000"))
        XCTAssertFalse(store.canBuild)
    }

    func testAnEngineWithoutThePackerSaysToUpdateIt() {
        let (store, game) = makeStore(packer: false)
        store.scan(folder: game)
        XCTAssertEqual(store.slot("base").problem, store.t("folder.engineOld"))
        XCTAssertFalse(store.canBuild)
    }

    func testABrokenFolderNamesTheMissingPiece() {
        let (store, game) = makeStore()
        try? FileManager.default.removeItem(atPath: game + "/base/romfs")
        try? FileManager.default.removeItem(atPath: game + "/updates")
        store.scan(folder: game)
        XCTAssertEqual(store.slot("base").problem, String(format: store.t("folder.problem.missing"), "base/romfs"))
        XCTAssertFalse(store.canBuild)
    }

    func testAPackageAfterAGameFolderStartsOverAndClearingClearsTheFolder() {
        let (store, game) = makeStore()
        store.scan(folder: game)
        let nsp = root + "/Game [0100000000001000].nsp"
        write(nsp)
        store.take(picked: [nsp], kind: .base)
        XCTAssertNil(store.gameFolder)
        XCTAssertEqual(store.basePath, nsp)
        XCTAssertTrue(store.updatePath.isEmpty, "the folder's update does not stay beside a package")
        XCTAssertFalse(store.canBuild, "a package needs the keys again")
        store.scan(folder: game)
        store.clear("base")
        XCTAssertNil(store.gameFolder)
        XCTAssertTrue(store.slots.allSatisfy(\.paths.isEmpty))
    }

    /// A NUP file (seedds/nxnative 423a674): one game, no keys, the file is the script's input, the build folder beside it.
    func testANUPFileIsOneGameAndTheScriptGetsTheFile() throws {
        let (store, _) = makeStore()
        let nup = root + "/Games/Bananza.nup"
        write(nup, nupData())
        store.take(picked: [nup], kind: .base)
        XCTAssertEqual(store.gameFolder?.nup, nup)
        XCTAssertEqual(store.gameFolderRowText("base"), String(format: store.t("folder.nupBase"), "040074A01BF12000"))
        XCTAssertEqual(store.gameFolderRowText("update"), String(format: store.t("folder.update"), 458752))
        XCTAssertEqual(store.gameDir, root + "/Games")
        XCTAssertTrue(store.canBuild)
        store.startBuild()
        let args = store.lastBuildCommand
        XCTAssertEqual(args.dropFirst(2).first, nup)
        XCTAssertFalse(args.contains("-k"))
        XCTAssertEqual(args.firstIndex(of: "--work-dir").map { args[$0 + 1] }, root + "/Games/040074A01BF12000_build")
        // dropped, and its folder chosen, it is the same game
        store.running = false
        store.leaveGameFolder()
        store.take(dropped: [nup])
        XCTAssertEqual(store.gameFolder?.nup, nup)
        store.scan(folder: root + "/Games")
        XCTAssertEqual(store.gameFolder?.nup, nup)
    }

    func testAnEngineWithoutTheNUPPackerSaysToUpdateIt() throws {
        let (store, _) = makeStore()
        try FileManager.default.removeItem(atPath: root + "/engine/scripts/pack_nup.py")
        let nup = root + "/Bananza.nup"
        write(nup, nupData())
        store.scan(folder: nup)
        XCTAssertEqual(store.slot("base").problem, store.t("folder.engineOldNUP"))
    }

    /// An old engine (no survey in the script) refuses a NUP of a game it has no profile for, one with the survey builds it.
    func testANUPOfAGameWithoutAProfileNeedsTheSurveyInTheEngine() throws {
        let (store, _) = makeStore(profile: false)
        let nup = root + "/Bananza.nup"
        write(nup, nupData())
        write(root + "/engine/scripts/build_ipa_from_nsp.py", Data("def survey_dump(src, out):\n    pass\n".utf8))
        store.scan(folder: nup)
        XCTAssertEqual(store.slot("base").problem, String(format: store.t("folder.noProfile"), "040074A01BF12000"))
        XCTAssertFalse(store.canBuild)
        write(root + "/engine/scripts/build_ipa_from_nsp.py", Data("def survey_nup(n, k, base, out):\n    pass\n".utf8))
        store.scan(folder: nup)
        XCTAssertEqual(store.gameFolder?.nup, nup)
        XCTAssertEqual(store.slot("base").problem, "")
        XCTAssertTrue(store.canBuild)
    }

    func testAGameFolderOfAGameWithoutAProfileNeedsTheSurveyInTheEngine() {
        let (store, game) = makeStore(profile: false)
        write(root + "/engine/scripts/build_ipa_from_nsp.py", Data("def survey_nup(n, k, base, out):\n    pass\n".utf8))
        store.scan(folder: game)
        XCTAssertNotNil(store.gameFolder)
        XCTAssertTrue(store.canBuild)
    }

    /// A NUP's header and package table: base, one update, no data (as syntheticNUP in NXCoreTests).
    private func nupData() -> Data {
        func put(_ d: inout [UInt8], _ o: Int, _ v: UInt64, _ n: Int) { for i in 0..<n { d[o + i] = UInt8(v >> (8 * UInt64(i)) & 0xFF) } }
        var d = [UInt8](repeating: 0, count: 0x80 + 0x30 + 2 * 0x40)
        d.replaceSubrange(0..<4, with: [0x4E, 0x55, 0x50, 0x01])
        put(&d, 0x08, 0x80, 8); put(&d, 0x40, UInt64(d.count), 8); put(&d, 0x48, 2, 4)
        d.replaceSubrange(0x80..<0x84, with: [0x54, 0x4F, 0x43, 0x01])
        put(&d, 0xB0, 0x040074A01BF12000, 8)
        put(&d, 0xF0, 0x040074A01BF12800, 8); put(&d, 0xF0 + 20, 458752, 4); d[0xF0 + 24] = 1
        return Data(d)
    }

    func testAFolderOfPackagesIsScannedAsBefore() {
        let (store, _) = makeStore()
        let folder = root + "/Mario"
        write(folder + "/Mario [010015100B514000][v0].nsp")
        store.scan(folder: folder)
        XCTAssertNil(store.gameFolder)
        XCTAssertEqual((store.basePath as NSString).lastPathComponent, "Mario [010015100B514000][v0].nsp")
        XCTAssertEqual(store.buildKey, "010015100B514000")
    }

    func testNestedWrapperAndBaseSubfolderResolveToTheGameFolderWithoutKeys() {
        let (store, game) = makeStore()
        let nested = root + "/Unzipped/Wrapper/Donkey Kong Bananza"
        try? FileManager.default.createDirectory(atPath: (nested as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? FileManager.default.moveItem(atPath: game, toPath: nested)

        for picked in [root + "/Unzipped", root + "/Unzipped/Wrapper", nested + "/base", nested + "/base/exefs"] {
            store.scan(folder: picked)
            XCTAssertEqual(store.gameDir, nested, "failed for \(picked)")
            XCTAssertEqual(store.gameFolder?.folder, nested, "failed for \(picked)")
            XCTAssertTrue(store.canBuild, "no prod.keys needed for \(picked)")
            XCTAssertTrue(store.keysPath.isEmpty)
        }
    }
}
