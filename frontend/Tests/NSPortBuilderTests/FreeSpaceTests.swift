import XCTest
@testable import NSPortBuilder

/// Free space (#67): a synthetic <title ID>_build folder in a temporary directory, laid out as build_ipa_from_nsp.py
/// leaves it, with the finished app, the IPA and the game data archive beside it.
final class FreeSpaceTests: XCTestCase {
    private var temporary: URL!
    private let titleID = "0100535012974000"

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-free-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporary)
    }

    private var out: URL { temporary.appendingPathComponent("games folder") }
    private var build: URL { out.appendingPathComponent(titleID + "_build") }

    private func file(_ path: String, in dir: URL? = nil, kb: Int = 64) throws {
        let url = (dir ?? build).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: kb * 1024).write(to: url)
    }

    private func exists(_ path: String, in dir: URL? = nil) -> Bool {
        FileManager.default.fileExists(atPath: (dir ?? build).appendingPathComponent(path).path)
    }

    /// The build folder of a game that was built for the Mac and installed on a device (its app in xcode-derived-data).
    private func fixture() throws -> LibraryGame {
        for path in ["extract/v0/RomFS/data.bin", "extract/v0/ExeFS/main", "extract.partial/x", "exefs.partial/x",
                     "shader/package.bin", "shader/cache/b-1/a_b.metallib", "pso/mac/a.bin",
                     "xcode/DmIOS.xcodeproj/project.pbxproj", "xcode-derived-data/Build/Intermediates.noindex/a.o", "ipa/Payload/x",
                     "tools/nx_extract/nx_extract", "tmp/x", "patched_v0/main.patched.bin", "nro_v0/nro.tsv", "aoc/1.img", "font/nintendo_ext.ttf",
                     "logs/split.log", "profile/\(titleID)/game.tsv", "run/save/save.bin", "nsp/game.nsp"] { try file(path) }
        for path in ["patched_v0.key", "aoc.key"] { try file(path, kb: 1) }
        try file("xcode-derived-data/Build/Products/Release-iphoneos/DmIOS.app/Info.plist")
        try file(titleID + ".app/Contents/Info.plist", in: out)
        try file(titleID + ".ipa", in: out)
        try file("games/\(titleID)/romfs.img", in: out)
        try file("Hades [\(titleID)].nsp", in: out)
        var game = LibraryGame(titleID: titleID, name: "Hades")
        game.outputDirectory = out.path
        game.inputs = ["base": [out.appendingPathComponent("Hades [\(titleID)].nsp").path]]
        game.appPath = out.appendingPathComponent(titleID + ".app").path
        game.ipaPath = out.appendingPathComponent(titleID + ".ipa").path
        game.archivePath = out.appendingPathComponent("games/" + titleID).path
        game.iosAppPath = build.appendingPathComponent("xcode-derived-data/Build/Products/Release-iphoneos/DmIOS.app").path
        game.installedDevice = "00008150-AAAA"
        return game
    }

    func testTheFolderIsFoundInTheOutputFolderOrBesideTheNSPs() throws {
        let game = try fixture()
        XCTAssertEqual(BuildFolder.location(for: game), build.path)
        var beside = game
        beside.outputDirectory = temporary.appendingPathComponent("elsewhere").path   // a checkout without --work-dir
        XCTAssertEqual(BuildFolder.location(for: beside), build.path)
        beside.inputs = [:]
        XCTAssertNil(BuildFolder.location(for: beside))
    }

    func testThePartsAreSizedAndWhatStaysIsNotOffered() throws {
        let game = try fixture()
        let survey = BuildFolder.survey(build.path, protecting: BuildFolder.protectedPaths(for: game))
        XCTAssertEqual(survey.parts, BuildFolderPart.allCases.filter { $0 != .oldShaders }, "no chain given: no shader version is old")
        let kb: Int64 = 1024
        XCTAssertGreaterThanOrEqual(survey.sizes[.extracted] ?? 0, 4 * 64 * kb)
        XCTAssertGreaterThanOrEqual(survey.sizes[.shaders] ?? 0, 3 * 64 * kb)
        // the installed app inside xcode-derived-data is kept, not counted with the Xcode files
        XCTAssertGreaterThanOrEqual(survey.sizes[.xcode] ?? 0, 3 * 64 * kb)
        XCTAssertLessThan(survey.sizes[.xcode] ?? 0, 4 * 64 * kb + 16 * kb)
        XCTAssertGreaterThanOrEqual(survey.kept, 5 * 64 * kb, "logs, profile, saves, converted NSPs and the installed app")
    }

    /// Two old chain versions and the current one, as build_shaders leaves them (Mac and iPhone libraries, their keys), and
    /// what must never count as old: the Metal compile cache, a short or longer name, a key of another form.
    private func shaderVersions() throws {
        let current = "b-f3ceca86cac5"
        for chain in ["b-157e1b96c8da", "b-a78f966a7b38", current] {
            try file("shader/cache/\(chain)/k_b.metallib", kb: chain == current ? 128 : 100)
            try file("shader/ios/\(chain)/k_b.metallib", kb: chain == current ? 128 : 50)
            try file("shader/ios/\(chain).key", kb: 1); try file("shader/mac-\(chain).key", kb: 1)
        }
        for path in ["shader/cache/cas/metallib/ab/x.metallib", "shader/cache/b-notahexchain/x", "shader/cache/b-157e1b96c8dag/x", "shader/ios/vk/vk_shaders.metallib",
                     "shader/ios/b-157e1b96c8da.keep", "shader/pkg/b-a78f966a7b38.key"] { try file(path) }
    }

    func testTheCurrentChainIsReadAsTheScriptReadsIt() throws {
        let repo = temporary.appendingPathComponent("repo")
        XCTAssertNil(BuildFolder.currentChain(repo: repo.path))
        try file("dm/gfx/nvn/dmsh_chain.h", in: repo)
        XCTAssertNil(BuildFolder.currentChain(repo: repo.path), "a header without a version")
        try "// the host loads only <library dir>/b-<V>/\n#define DMSH_CHAIN \"f3ceca86cac5\"\n".write(to: repo.appendingPathComponent("dm/gfx/nvn/dmsh_chain.h"), atomically: true, encoding: .utf8)
        XCTAssertEqual(BuildFolder.currentChain(repo: repo.path), "f3ceca86cac5")
        XCTAssertNil(BuildFolder.currentChain(repo: ""))
    }

    func testOldShaderVersionsAreListedWithTheirSizesAndTheCurrentOneIsKept() throws {
        let game = try fixture(); try shaderVersions()
        let survey = BuildFolder.survey(build.path, protecting: BuildFolder.protectedPaths(for: game), chain: "f3ceca86cac5")
        XCTAssertEqual(survey.oldShaders.map(\.name), ["b-157e1b96c8da", "b-a78f966a7b38"])
        let kb: Int64 = 1024
        for version in survey.oldShaders { XCTAssertGreaterThanOrEqual(version.bytes, 152 * kb, version.name + " holds the Mac and iPhone libraries") }
        XCTAssertEqual(survey.sizes[.oldShaders], survey.oldShaders.reduce(0) { $0 + $1.bytes })
        XCTAssertGreaterThan(survey.sizes[.shaders] ?? 0, survey.sizes[.oldShaders] ?? 0, "part of the shader output, which stays whole")
        XCTAssertTrue(survey.parts.contains(.oldShaders))
        let current = BuildFolder.survey(build.path, protecting: [], chain: "157e1b96c8da")
        XCTAssertEqual(current.oldShaders.map(\.name), ["b-a78f966a7b38", "b-f3ceca86cac5"], "whichever chain is current is the one kept")
    }

    func testRemovingOldShaderVersionsKeepsTheCurrentLibrariesAndEverythingElse() throws {
        let game = try fixture(); try shaderVersions()
        let freed = try BuildFolder.remove([.oldShaders], in: build.path, protecting: BuildFolder.protectedPaths(for: game), buildRunning: false, chain: "f3ceca86cac5")
        XCTAssertGreaterThanOrEqual(freed, 2 * 152 * 1024)
        for old in ["b-157e1b96c8da", "b-a78f966a7b38"] {
            for path in ["shader/cache/\(old)", "shader/ios/\(old)", "shader/ios/\(old).key", "shader/mac-\(old).key"] { XCTAssertFalse(exists(path), path) }
        }
        for path in ["shader/cache/b-f3ceca86cac5/k_b.metallib", "shader/ios/b-f3ceca86cac5/k_b.metallib", "shader/ios/b-f3ceca86cac5.key", "shader/mac-b-f3ceca86cac5.key",
                     "shader/cache/cas/metallib/ab/x.metallib", "shader/cache/b-notahexchain/x", "shader/cache/b-157e1b96c8dag/x", "shader/ios/vk/vk_shaders.metallib",
                     "shader/ios/b-157e1b96c8da.keep", "shader/pkg/b-a78f966a7b38.key", "shader/package.bin", "shader/cache/b-1/a_b.metallib", "pso/mac/a.bin", "extract/v0/RomFS/data.bin"] {
            XCTAssertTrue(exists(path), path)
        }
        XCTAssertEqual(BuildFolder.survey(build.path, protecting: [], chain: "f3ceca86cac5").oldShaders, [])
    }

    func testOldShaderVersionsNeedTheCurrentChainAndAFinishedBuild() throws {
        let game = try fixture(); try shaderVersions()
        let protected = BuildFolder.protectedPaths(for: game)
        XCTAssertEqual(try BuildFolder.remove([.oldShaders], in: build.path, protecting: protected, buildRunning: false), 0, "without a chain nothing is old")
        XCTAssertTrue(exists("shader/cache/b-157e1b96c8da/k_b.metallib"))
        XCTAssertThrowsError(try BuildFolder.remove([.oldShaders], in: build.path, protecting: protected, buildRunning: true, chain: "f3ceca86cac5")) {
            XCTAssertEqual($0 as? FreeSpaceError, .buildRunning)
        }
        XCTAssertTrue(exists("shader/cache/b-157e1b96c8da/k_b.metallib"))
    }

    func testShaderOutputStillRemovesEverythingIncludingTheOldVersions() throws {
        let game = try fixture(); try shaderVersions()
        try BuildFolder.remove([.shaders, .oldShaders], in: build.path, protecting: BuildFolder.protectedPaths(for: game), buildRunning: false, chain: "f3ceca86cac5")
        XCTAssertFalse(exists("shader")); XCTAssertTrue(exists("extract/v0/RomFS/data.bin"))
    }

    func testRemovingOnePartLeavesTheRest() throws {
        let game = try fixture()
        let freed = try BuildFolder.remove([.extracted], in: build.path, protecting: BuildFolder.protectedPaths(for: game), buildRunning: false)
        XCTAssertGreaterThanOrEqual(freed, 4 * 64 * 1024)
        XCTAssertFalse(exists("extract")); XCTAssertFalse(exists("extract.partial")); XCTAssertFalse(exists("exefs.partial"))
        for path in ["shader/package.bin", "pso", "xcode", "tools", "patched_v0", "logs"] { XCTAssertTrue(exists(path), path) }
    }

    func testTheFinishedAppTheArchiveAndTheNSPsAreNeverRemoved() throws {
        let game = try fixture()
        try BuildFolder.remove(Set(BuildFolderPart.allCases), in: build.path, protecting: BuildFolder.protectedPaths(for: game), buildRunning: false)
        for path in ["extract", "shader", "pso", "xcode", "ipa", "tools", "tmp", "patched_v0", "patched_v0.key", "nro_v0", "aoc", "aoc.key", "font",
                     "xcode-derived-data/Build/Intermediates.noindex"] {
            XCTAssertFalse(exists(path), path)
        }
        for path in ["logs/split.log", "profile/\(titleID)/game.tsv", "run/save/save.bin", "nsp/game.nsp",
                     "xcode-derived-data/Build/Products/Release-iphoneos/DmIOS.app/Info.plist"] {
            XCTAssertTrue(exists(path), path)
        }
        for path in [titleID + ".app/Contents/Info.plist", titleID + ".ipa", "games/\(titleID)/romfs.img", "Hades [\(titleID)].nsp"] {
            XCTAssertTrue(exists(path, in: out), path)
        }
        let after = BuildFolder.survey(build.path, protecting: BuildFolder.protectedPaths(for: game))
        XCTAssertEqual(after.parts, [], "nothing left to offer")
    }

    /// Even where the app or the game data archive lies inside a part, it is neither offered nor removed.
    func testAProtectedFileInsideAPartStays() throws {
        var game = try fixture()
        try file("tmp/Hades.app/Contents/Info.plist")
        try file("tmp/games/\(titleID)/romfs.img", kb: 256)
        game.appPath = build.appendingPathComponent("tmp/Hades.app").path
        game.archivePath = build.appendingPathComponent("tmp/games/" + titleID).path
        let protected = BuildFolder.protectedPaths(for: game)
        let before = BuildFolder.survey(build.path, protecting: protected)
        XCTAssertLessThan(before.sizes[.caches] ?? 0, 8 * 64 * 1024 + 64 * 1024, "the 256 KB archive is not counted as a cache")
        try BuildFolder.remove([.caches], in: build.path, protecting: protected, buildRunning: false)
        XCTAssertTrue(exists("tmp/Hades.app/Contents/Info.plist"))
        XCTAssertTrue(exists("tmp/games/\(titleID)/romfs.img"))
        XCTAssertFalse(exists("tmp/x"))
        XCTAssertFalse(exists("tools"))
    }

    func testRefusedWhileABuildRuns() throws {
        let game = try fixture()
        XCTAssertThrowsError(try BuildFolder.remove(Set(BuildFolderPart.allCases), in: build.path, protecting: BuildFolder.protectedPaths(for: game), buildRunning: true)) {
            XCTAssertEqual($0 as? FreeSpaceError, .buildRunning)
        }
        XCTAssertTrue(exists("extract/v0/RomFS/data.bin"))
        XCTAssertTrue(exists("shader/package.bin"))
    }

    func testOnlyABuildFolderIsTouched() throws {
        try file("extract/x", in: out)
        XCTAssertThrowsError(try BuildFolder.remove([.extracted], in: out.path, protecting: [], buildRunning: false)) {
            XCTAssertEqual($0 as? FreeSpaceError, .notABuildFolder(self.out.path))
        }
        XCTAssertTrue(exists("extract/x", in: out))
    }

    func testWhichPartAnEntryBelongsTo() {
        XCTAssertEqual(BuildFolderPart.of("extract"), .extracted)
        XCTAssertEqual(BuildFolderPart.of("exefs.partial"), .extracted)
        XCTAssertEqual(BuildFolderPart.of("shader"), .shaders)
        XCTAssertEqual(BuildFolderPart.of("xcode-derived-data"), .xcode)
        XCTAssertEqual(BuildFolderPart.of("patched_v65536.key"), .caches)
        XCTAssertEqual(BuildFolderPart.of("nro_v0"), .caches)
        for kept in ["logs", "profile", "profile.derived.key", "run", "nsp", "survey.md", "unknown"] { XCTAssertNil(BuildFolderPart.of(kept), kept) }
    }
}
