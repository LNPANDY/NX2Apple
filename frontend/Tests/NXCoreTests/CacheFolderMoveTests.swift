import XCTest
@testable import NXCore

/// The generic cache move (CacheFolderMove) with the caches that have no index file: the nxkit work folder (one part) and the build
/// seeds (two parts, `build-seeds` and `refresh-builds`, which move together). The shell cache's own rules are ShellRootMoveTests'.
/// Every test runs in a temporary folder. The copy to another volume is tested on one volume by setting `sameVolume` to false in the
/// plan, which takes the same code path as a real external drive. The bug class is data loss: an old folder must survive every stop
/// and every failure, and goes only after its copy was checked.
final class CacheFolderMoveTests: XCTestCase {
    private let fm = FileManager.default
    private var base: String!
    private var home: String { base + "/home" }
    private var seeds: String { BuildCacheRoots.defaultSeedRoot(home: home) }
    private var refresh: String { BuildCacheRoots.refreshBuilds(seedRoot: seeds) }
    private var nxkit: String { BuildCacheRoots.defaultNxkitRoot(home: home) }
    private var picked: String { base + "/Drive/Games" }

    override func setUpWithError() throws {
        base = fm.temporaryDirectory.path + "/nspb-cache-move-" + UUID().uuidString
        try fm.createDirectory(atPath: picked, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(atPath: base) }

    private func write(_ path: String, _ bytes: Int = 16 * 1024) throws {
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data((0..<bytes).map { UInt8($0 % 251) }).write(to: URL(fileURLWithPath: path))
    }

    /// Seeds as the engine writes them (a folder per title ID, a hidden staging folder) and a Fast Refresh build beside them. The
    /// nxkit work folder: a folder per game. The saves of the nxnative folder sit beside the seeds and never move.
    private func makeCaches() throws {
        try write(seeds + "/0100AAAA00000000/seed.json", 512)
        try write(seeds + "/0100AAAA00000000/metal-sources/a.metal")
        try write(seeds + "/.0100BBBB00000000.staging.42/partial", 64)
        try write(refresh + "/0100AAAA00000000_build/work.bin")
        try write(refresh + "/Game.ipa", 2048)
        try write((seeds as NSString).deletingLastPathComponent + "/0100AAAA00000000/save/slot0", 128)
        try write(nxkit + "/01007EF00011E000/romfs/data.bin")
        try write(nxkit + "/01007EF00011E000/shaders/cache.bin", 4096)
    }

    private func snapshot(_ root: String) -> [String: String] {
        var out: [String: String] = [:]
        guard let walker = fm.enumerator(atPath: root) else { return out }
        for case let path as String in walker {
            let full = root + "/" + path
            if let link = try? fm.destinationOfSymbolicLink(atPath: full) { out[path] = "link:" + link; continue }
            var isDir: ObjCBool = false
            fm.fileExists(atPath: full, isDirectory: &isDir)
            out[path] = isDir.boolValue ? "dir" : (fm.contents(atPath: full)?.base64EncodedString() ?? "unreadable")
        }
        return out
    }

    private func seedPlan(to destination: String, otherVolume: Bool) -> CacheFolderMove.Plan {
        var plan = CacheFolderMove.plan(BuildCacheRoots.seedMoves(from: seeds, to: destination))
        if otherVolume { plan.sameVolume = false }
        return plan
    }

    private func leftovers(_ folder: String) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.contains("-moving-") }
    }

    // MARK: The build seeds: two parts as one tree

    func testSeedsAndRefreshBuildsMoveTogetherIntoOneFolderOnTheSameVolume() throws {
        try makeCaches()
        let (seedsBefore, refreshBefore) = (snapshot(seeds), snapshot(refresh))
        let destination = BuildCacheRoots.seedDestination(inside: picked)
        XCTAssertEqual(destination, picked + "/NX2Apple-build-seeds/build-seeds")
        let plan = seedPlan(to: destination, otherVolume: false)
        XCTAssertNil(plan.problem)
        XCTAssertTrue(plan.sameVolume)
        XCTAssertEqual(plan.parts.map(\.destination), [destination, picked + "/NX2Apple-build-seeds/refresh-builds"])
        XCTAssertEqual(plan.bytes, plan.parts.reduce(0) { $0 + $1.bytes }, "the size of both parts")
        XCTAssertEqual(CacheFolderMove.run(plan), .moved)
        XCTAssertEqual(snapshot(destination), seedsBefore)
        XCTAssertEqual(snapshot(BuildCacheRoots.refreshBuilds(seedRoot: destination)), refreshBefore, "refresh-builds follows the seed root")
        XCTAssertFalse(fm.fileExists(atPath: seeds))
        XCTAssertFalse(fm.fileExists(atPath: refresh))
        XCTAssertTrue(fm.fileExists(atPath: (seeds as NSString).deletingLastPathComponent + "/0100AAAA00000000/save/slot0"),
                      "the saves in the nxnative folder stay")
    }

    func testOnAnotherVolumeBothPartsAreCopiedCheckedAndTheWayBackRemovesTheLaunchersFolder() throws {
        try makeCaches()
        let (seedsBefore, refreshBefore) = (snapshot(seeds), snapshot(refresh))
        try write(picked + "/notes.txt", 8)
        let destination = BuildCacheRoots.seedDestination(inside: picked)
        var phases: [CacheFolderMove.Phase] = []
        XCTAssertEqual(CacheFolderMove.run(seedPlan(to: destination, otherVolume: true), chunk: 1024, progress: { phase, _, _ in
            if phases.last != phase { phases.append(phase) }
        }), .moved)
        XCTAssertEqual(phases, [.copying, .checking])
        XCTAssertEqual(snapshot(destination), seedsBefore)
        XCTAssertEqual(snapshot(BuildCacheRoots.refreshBuilds(seedRoot: destination)), refreshBefore)
        XCTAssertFalse(fm.fileExists(atPath: seeds))
        XCTAssertEqual(leftovers(picked + "/NX2Apple-build-seeds"), [])

        // back to the default place: the launcher's NX2Apple-build-seeds goes once it is empty, the player's folder and files stay
        var back = CacheFolderMove.plan(BuildCacheRoots.seedMoves(from: destination, to: seeds))
        back.sameVolume = false
        XCTAssertNil(back.problem)
        XCTAssertEqual(CacheFolderMove.run(back), .moved)
        XCTAssertEqual(snapshot(seeds), seedsBefore)
        XCTAssertEqual(snapshot(refresh), refreshBefore)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: picked), ["notes.txt"])
    }

    func testAStopWhileCopyingTheSecondPartLeavesBothOldFoldersAsTheyWere() throws {
        try makeCaches()
        let (seedsBefore, refreshBefore) = (snapshot(seeds), snapshot(refresh))
        let seedBytes = CacheFolderMove.plan(BuildCacheRoots.seedMoves(from: seeds, to: picked + "/x/build-seeds")).parts[0].bytes
        var copied: Int64 = 0
        let destination = BuildCacheRoots.seedDestination(inside: picked)
        let outcome = CacheFolderMove.run(seedPlan(to: destination, otherVolume: true), chunk: 512,
                                          progress: { phase, done, _ in if phase == .copying { copied = done } },
                                          stop: { copied > seedBytes + 1024 })
        XCTAssertEqual(outcome, .stopped)
        XCTAssertEqual(snapshot(seeds), seedsBefore)
        XCTAssertEqual(snapshot(refresh), refreshBefore)
        XCTAssertFalse(fm.fileExists(atPath: destination))
        XCTAssertEqual(leftovers(picked + "/NX2Apple-build-seeds"), [], "both partial copies are removed")
    }

    func testAMismatchInTheSecondPartKeepsBothOldFoldersAndNamesTheFile() throws {
        try makeCaches()
        let (seedsBefore, refreshBefore) = (snapshot(seeds), snapshot(refresh))
        let destination = BuildCacheRoots.seedDestination(inside: picked)
        let outcome = CacheFolderMove.run(seedPlan(to: destination, otherVolume: true), afterCopy: { staging in
            guard staging.contains(".refresh-builds-moving-") else { return }
            let file = staging + "/Game.ipa"
            var data = self.fm.contents(atPath: file)!
            data[10] ^= 0xFF
            try? data.write(to: URL(fileURLWithPath: file))
        })
        XCTAssertEqual(outcome, .failed(.mismatch("refresh-builds/Game.ipa")))
        XCTAssertEqual(snapshot(seeds), seedsBefore, "the first part, already copied and checked, stays too")
        XCTAssertEqual(snapshot(refresh), refreshBefore)
        XCTAssertFalse(fm.fileExists(atPath: destination))
        XCTAssertEqual(leftovers(picked + "/NX2Apple-build-seeds"), [])
    }

    func testWithoutRefreshBuildsOnlyTheSeedsMoveAndWithNothingOnlyThePlaceChanges() throws {
        try write(seeds + "/0100AAAA00000000/seed.json", 512)
        let destination = BuildCacheRoots.seedDestination(inside: picked)
        let plan = seedPlan(to: destination, otherVolume: true)
        XCTAssertEqual(plan.parts.map(\.exists), [true, false])
        XCTAssertEqual(CacheFolderMove.run(plan), .moved)
        XCTAssertTrue(fm.fileExists(atPath: destination + "/0100AAAA00000000/seed.json"))
        XCTAssertFalse(fm.fileExists(atPath: BuildCacheRoots.refreshBuilds(seedRoot: destination)), "nothing to make for a missing part")

        let empty = CacheFolderMove.plan(BuildCacheRoots.nxkitMoves(from: nxkit, to: BuildCacheRoots.nxkitDestination(inside: picked)))
        XCTAssertFalse(empty.sourceExists)
        XCTAssertNil(empty.problem)
        XCTAssertEqual(CacheFolderMove.run(empty), .moved)
    }

    // MARK: The nxkit work folder and the content rule

    func testTheNxkitWorkFolderMovesIntoItsOwnFolderOnAnotherVolume() throws {
        try makeCaches()
        let before = snapshot(nxkit)
        let destination = BuildCacheRoots.nxkitDestination(inside: picked)
        XCTAssertEqual(destination, picked + "/NX2Apple-nxkit")
        var plan = CacheFolderMove.plan(BuildCacheRoots.nxkitMoves(from: nxkit, to: destination))
        plan.sameVolume = false
        XCTAssertEqual(CacheFolderMove.run(plan), .moved)
        XCTAssertEqual(snapshot(destination), before)
        XCTAssertFalse(fm.fileExists(atPath: nxkit))
        XCTAssertTrue(fm.fileExists(atPath: (nxkit as NSString).deletingLastPathComponent), "the Caches/NX2Apple folder above stays")
    }

    /// A cache without an index file is the launcher's when every visible entry is a plain folder (one per game or title ID).
    func testAFileOrALinkAtTheTopIsNotTheLaunchersAndStopsTheMove() throws {
        try makeCaches()
        let destination = BuildCacheRoots.nxkitDestination(inside: picked)
        try write(nxkit + "/.DS_Store", 4)
        XCTAssertNil(CacheFolderMove.plan(BuildCacheRoots.nxkitMoves(from: nxkit, to: destination)).problem, "hidden entries are fine")
        try write(nxkit + "/notes.txt", 4)
        XCTAssertEqual(CacheFolderMove.plan(BuildCacheRoots.nxkitMoves(from: nxkit, to: destination)).problem, .unknownContent)
        try fm.removeItem(atPath: nxkit + "/notes.txt")
        try fm.createSymbolicLink(atPath: nxkit + "/elsewhere", withDestinationPath: base)
        XCTAssertEqual(CacheFolderMove.plan(BuildCacheRoots.nxkitMoves(from: nxkit, to: destination)).problem, .unknownContent)
        try fm.removeItem(atPath: nxkit + "/elsewhere")

        try write(seeds + "/stray.txt", 4)
        XCTAssertEqual(seedPlan(to: BuildCacheRoots.seedDestination(inside: picked), otherVolume: false).problem, .unknownContent)
        try fm.removeItem(atPath: seeds + "/stray.txt")
        try write(refresh + "/loose.txt", 4)
        XCTAssertNil(seedPlan(to: BuildCacheRoots.seedDestination(inside: picked), otherVolume: false).problem,
                     "refresh-builds holds whatever a build leaves")
    }

    func testTheSafetyRulesHoldForEveryPart() throws {
        try makeCaches()
        XCTAssertEqual(seedPlan(to: seeds, otherVolume: false).problem, .same)
        XCTAssertEqual(seedPlan(to: seeds + "/0100AAAA00000000/build-seeds", otherVolume: false).problem, .insideCache)
        XCTAssertEqual(seedPlan(to: refresh + "/NX2Apple-build-seeds/build-seeds", otherVolume: false).problem, .insideCache,
                       "inside the second part too")
        let destination = BuildCacheRoots.seedDestination(inside: picked)
        try write(BuildCacheRoots.refreshBuilds(seedRoot: destination) + "/someone.txt", 4)
        XCTAssertEqual(seedPlan(to: destination, otherVolume: false).problem, .destinationTaken, "the second part's place is taken")
        let link = base + "/linked"
        try fm.createSymbolicLink(atPath: link, withDestinationPath: nxkit)
        XCTAssertEqual(CacheFolderMove.plan(BuildCacheRoots.nxkitMoves(from: link, to: BuildCacheRoots.nxkitDestination(inside: picked))).problem, .notPlain)
        XCTAssertEqual(CacheFolderMove.run(seedPlan(to: destination, otherVolume: false)), .failed(.io("the move cannot start")))
        XCTAssertTrue(fm.fileExists(atPath: seeds + "/0100AAAA00000000/seed.json"))
    }
}
