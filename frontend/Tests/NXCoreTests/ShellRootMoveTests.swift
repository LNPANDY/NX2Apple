import XCTest
@testable import NXCore

/// LNPANDY/NX2Apple#427, Move cache folder. Every test runs in a temporary folder with its own `home`, so the real Application
/// Support folder is never touched. The bug class is data loss: the old folder must survive every stop and every failure, and is
/// removed only after its copy was checked file by file. The copy to another volume is tested on one volume by setting
/// `sameVolume` to false in the plan, which takes the same code path as a real external drive.
final class ShellRootMoveTests: XCTestCase {
    private let fm = FileManager.default
    private var base: String!
    private var home: String { base + "/home" }
    private var source: String { home + "/Library/Application Support/NX2Apple/shell" }
    private var picked: String { base + "/Drive/Games" }
    private var destination: String { ShellRootMove.destination(inside: picked) }
    private var buildFramework: String { base + "/Out/build/DmGame0100BBBB.framework" }

    override func setUpWithError() throws {
        base = fm.temporaryDirectory.path + "/nspb-move-" + UUID().uuidString
        try fm.createDirectory(atPath: picked, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // a test makes a file unreadable: make everything removable again
        if let walker = fm.enumerator(atPath: base) {
            for case let path as String in walker { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: base + "/" + path) }
        }
        try? fm.removeItem(atPath: base)
    }

    /// A cache as the launcher makes it: a mirrored framework with an executable and a link (listed in shell.json), the project, the
    /// derived data and a framework in a build folder that is not inside the cache.
    private func makeCache(big: Int = 64 * 1024) throws {
        let mirror = source + "/frameworks/DmGame0100AAAA.framework"
        for dir in [mirror, source + "/project", source + "/derived-data/Build", buildFramework] {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        try Data((0..<big).map { UInt8($0 % 251) }).write(to: URL(fileURLWithPath: mirror + "/DmGame0100AAAA"))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mirror + "/DmGame0100AAAA")
        try Data("{\"manifest\":1}".utf8).write(to: URL(fileURLWithPath: mirror + "/game.manifest.json"))
        try fm.createSymbolicLink(atPath: mirror + "/Current", withDestinationPath: "DmGame0100AAAA")
        try Data("project".utf8).write(to: URL(fileURLWithPath: source + "/project/project.yml"))
        let json: [String: Any] = ["bundleID": "org.nxnative.shell.TEAM", "team": "TEAM", "futureKey": 7,
                                   "games": [["titleID": "0100AAAA", "name": "A", "framework": mirror],
                                             ["titleID": "0100BBBB", "name": "B", "framework": buildFramework]]]
        try JSONSerialization.data(withJSONObject: json).write(to: URL(fileURLWithPath: source + "/shell.json"))
    }

    /// Every entry under `root` with its kind and content, to see that a folder is exactly as it was.
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

    private func frameworks(_ root: String) throws -> [String] {
        let data = try XCTUnwrap(fm.contents(atPath: root + "/shell.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["futureKey"] as? Int, 7, "a key this version does not know stays")
        return (json["games"] as? [[String: Any]] ?? []).compactMap { $0["framework"] as? String }
    }

    private func leftovers() throws -> [String] {
        try fm.contentsOfDirectory(atPath: picked).filter { $0.contains("-moving-") }
    }

    private func crossVolumePlan() -> ShellRootMove.Plan {
        var plan = ShellRootMove.plan(from: source, to: destination)
        plan.sameVolume = false
        return plan
    }

    // MARK: The moves

    func testOnTheSameVolumeTheFolderIsRenamedAndShellJsonNamesTheNewPlace() throws {
        try makeCache()
        let before = snapshot(source)
        let plan = ShellRootMove.plan(from: source, to: destination)
        XCTAssertNil(plan.problem)
        XCTAssertTrue(plan.sameVolume, "a temporary folder and its neighbour are on one volume")
        XCTAssertTrue(plan.sourceExists)
        XCTAssertGreaterThan(plan.bytes, 64 * 1024)
        XCTAssertEqual(ShellRootMove.run(plan), .moved)
        XCTAssertFalse(fm.fileExists(atPath: source))
        XCTAssertEqual(snapshot(destination).keys.sorted(), before.keys.sorted())
        XCTAssertEqual(try frameworks(destination), [destination + "/frameworks/DmGame0100AAAA.framework", buildFramework],
                       "the mirror moved with the cache, the build folder's framework did not")
    }

    func testOnAnotherVolumeEveryFileIsCopiedCheckedAndOnlyThenTheOldFolderGoes() throws {
        try makeCache()
        let before = snapshot(source)
        var phases: [ShellRootMove.Phase] = []
        let outcome = ShellRootMove.run(crossVolumePlan(), chunk: 4096, progress: { phase, _, _ in
            if phases.last != phase { phases.append(phase) }
        })
        XCTAssertEqual(outcome, .moved)
        XCTAssertEqual(phases, [.copying, .checking], "the copy is checked after it is made")
        XCTAssertFalse(fm.fileExists(atPath: source), "the old folder is removed after the checked copy took its place")
        var after = snapshot(destination), expected = before
        after["shell.json"] = nil; expected["shell.json"] = nil   // rewritten for the new place, checked below
        XCTAssertEqual(after, expected, "the same files, the same bytes, the link as a link")
        let binary = destination + "/frameworks/DmGame0100AAAA.framework/DmGame0100AAAA"
        XCTAssertEqual((try fm.attributesOfItem(atPath: binary)[.posixPermissions] as? NSNumber)?.intValue, 0o755, "the permissions are kept")
        XCTAssertEqual(try frameworks(destination), [destination + "/frameworks/DmGame0100AAAA.framework", buildFramework])
        XCTAssertEqual(try leftovers(), [], "no hidden copy is left")
    }

    func testAStopWhileCopyingLeavesTheOldFolderExactlyAsItWas() throws {
        try makeCache()
        let before = snapshot(source)
        var copied: Int64 = 0
        let outcome = ShellRootMove.run(crossVolumePlan(), chunk: 1024, progress: { phase, done, _ in if phase == .copying { copied = done } },
                                        stop: { copied > 8 * 1024 })
        XCTAssertEqual(outcome, .stopped)
        XCTAssertEqual(snapshot(source), before, "the old folder is untouched and stays valid")
        XCTAssertFalse(fm.fileExists(atPath: destination))
        XCTAssertEqual(try leftovers(), [], "the partial copy is removed")
    }

    func testAStopWhileCheckingLeavesTheOldFolderExactlyAsItWas() throws {
        try makeCache()
        let before = snapshot(source)
        var checking = false
        let outcome = ShellRootMove.run(crossVolumePlan(), chunk: 1024, progress: { phase, done, _ in if phase == .checking, done > 4096 { checking = true } },
                                        stop: { checking })
        XCTAssertEqual(outcome, .stopped)
        XCTAssertEqual(snapshot(source), before)
        XCTAssertFalse(fm.fileExists(atPath: destination))
        XCTAssertEqual(try leftovers(), [])
    }

    /// The bug class: a copy that is not the same as its original (a drive that wrote wrong bytes) must never cost the old folder.
    func testACopyThatDiffersFromTheOriginalKeepsTheOldFolderAndRemovesTheCopy() throws {
        try makeCache()
        let before = snapshot(source)
        let outcome = ShellRootMove.run(crossVolumePlan(), afterCopy: { staging in
            let binary = staging + "/frameworks/DmGame0100AAAA.framework/DmGame0100AAAA"
            var data = self.fm.contents(atPath: binary)!
            data[100] ^= 0xFF   // one wrong byte, the same size
            try? data.write(to: URL(fileURLWithPath: binary))
        })
        XCTAssertEqual(outcome, .failed(.mismatch("frameworks/DmGame0100AAAA.framework/DmGame0100AAAA")))
        XCTAssertEqual(snapshot(source), before, "nothing of the old folder was removed")
        XCTAssertFalse(fm.fileExists(atPath: destination))
        XCTAssertEqual(try leftovers(), [])
    }

    func testAMissingFileInTheCopyKeepsTheOldFolder() throws {
        try makeCache()
        let before = snapshot(source)
        let outcome = ShellRootMove.run(crossVolumePlan(), afterCopy: { try? self.fm.removeItem(atPath: $0 + "/project/project.yml") })
        XCTAssertEqual(outcome, .failed(.mismatch("project")))
        XCTAssertEqual(snapshot(source), before)
        XCTAssertFalse(fm.fileExists(atPath: destination))
    }

    func testAFileThatCannotBeReadStopsTheCopyAndKeepsTheOldFolder() throws {
        try makeCache()
        let unreadable = source + "/project/project.yml"
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable)
        let outcome = ShellRootMove.run(crossVolumePlan())
        guard case .failed(.io) = outcome else { return XCTFail("expected a failed copy, got \(outcome)") }
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable)
        XCTAssertEqual(fm.contents(atPath: unreadable), Data("project".utf8), "the old folder keeps its files")
        XCTAssertTrue(fm.fileExists(atPath: source + "/shell.json"))
        XCTAssertFalse(fm.fileExists(atPath: destination))
        XCTAssertEqual(try leftovers(), [])
    }

    func testWithNoCacheYetOnlyThePlaceChanges() throws {
        let plan = ShellRootMove.plan(from: source, to: destination)
        XCTAssertNil(plan.problem)
        XCTAssertFalse(plan.sourceExists)
        XCTAssertEqual(plan.bytes, 0)
        XCTAssertEqual(ShellRootMove.run(plan), .moved)
        XCTAssertFalse(fm.fileExists(atPath: destination), "the folder is made by the next install, as for a new player")
    }

    /// The folder the player picks is never the launcher's: the cache goes into a folder of its own inside it, and moving the cache
    /// away again removes only that folder, never the player's other files.
    func testThePickedFolderAndItsOtherFilesStayWhenTheCacheMovesAwayAgain() throws {
        try makeCache()
        try Data("mine".utf8).write(to: URL(fileURLWithPath: picked + "/notes.txt"))
        XCTAssertEqual(destination, picked + "/NX2Apple-shell")
        XCTAssertEqual(ShellRootMove.run(crossVolumePlan()), .moved)
        var back = ShellRootMove.plan(from: destination, to: source)
        back.sameVolume = false
        XCTAssertNil(back.problem)
        XCTAssertEqual(ShellRootMove.run(back), .moved)
        XCTAssertEqual(fm.contents(atPath: picked + "/notes.txt"), Data("mine".utf8))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: picked), ["notes.txt"])
        XCTAssertEqual(try frameworks(source), [source + "/frameworks/DmGame0100AAAA.framework", buildFramework])
    }

    func testAnEmptyFolderAtTheDestinationIsTakenOver() throws {
        try makeCache()
        try fm.createDirectory(atPath: destination, withIntermediateDirectories: true)
        try Data().write(to: URL(fileURLWithPath: destination + "/.DS_Store"))
        XCTAssertNil(ShellRootMove.plan(from: source, to: destination).problem)
        XCTAssertEqual(ShellRootMove.run(crossVolumePlan()), .moved)
        XCTAssertTrue(fm.fileExists(atPath: destination + "/shell.json"))
    }

    // MARK: What stops a move before it starts

    func testTheSafetyRulesOfTheMigrationHold() throws {
        try makeCache()
        XCTAssertEqual(ShellRootMove.plan(from: source, to: source).problem, .same)
        XCTAssertEqual(ShellRootMove.plan(from: source, to: source + "/frameworks/NX2Apple-shell").problem, .insideCache)

        try fm.createDirectory(atPath: destination + "/frameworks", withIntermediateDirectories: true)
        XCTAssertEqual(ShellRootMove.plan(from: source, to: destination).problem, .destinationTaken, "a folder with content is never overwritten")
        try fm.removeItem(atPath: destination)
        try fm.createSymbolicLink(atPath: destination, withDestinationPath: base)
        XCTAssertEqual(ShellRootMove.plan(from: source, to: destination).problem, .destinationTaken, "a link at the destination is not free")
        try fm.removeItem(atPath: destination)

        try Data("{not json".utf8).write(to: URL(fileURLWithPath: source + "/shell.json"))
        XCTAssertEqual(ShellRootMove.plan(from: source, to: destination).problem, .unreadableLedger)
        try fm.removeItem(atPath: source + "/shell.json")
        XCTAssertEqual(ShellRootMove.plan(from: source, to: destination).problem, .unknownContent, "files and no shell.json: not a cache we know")

        let link = base + "/linked-shell"
        try fm.createSymbolicLink(atPath: link, withDestinationPath: source)
        XCTAssertEqual(ShellRootMove.plan(from: link, to: destination).problem, .notPlain)
        // a plan with a problem never runs, even when a caller skips the check
        XCTAssertEqual(ShellRootMove.run(ShellRootMove.plan(from: link, to: destination)), .failed(.io("the move cannot start")))
        XCTAssertTrue(fm.fileExists(atPath: source + "/project/project.yml"))
    }

    // MARK: The saved root

    /// A cache the player moved into `<folder>/NX2Apple-shell` is named like an old one in an output folder. The migration at
    /// launch must not move it back to Application Support.
    func testAPickedRootIsNotMigratedBackAtLaunch() throws {
        try makeCache()
        XCTAssertEqual(ShellRootMove.run(ShellRootMove.plan(from: source, to: destination)), .moved)
        let defaults = TestDefaults.make("nspb-move")
        defaults.set(destination, forKey: "shellRoot")
        defaults.set(true, forKey: ShellRootMove.pickedKey)
        ShellRootMigration.migrateSavedRoot(defaults: defaults, home: home)
        XCTAssertEqual(ShellLibrary.resolveRoot(defaults: defaults, parent: base + "/Out", home: home), destination)
        XCTAssertTrue(fm.fileExists(atPath: destination + "/shell.json"))
        XCTAssertFalse(fm.fileExists(atPath: source))

        defaults.removeObject(forKey: ShellRootMove.pickedKey)   // the same folder from an older version still moves
        XCTAssertEqual(ShellLibrary.resolveRoot(defaults: defaults, parent: base + "/Out", home: home), source)
        XCTAssertTrue(fm.fileExists(atPath: source + "/shell.json"))
    }
}
