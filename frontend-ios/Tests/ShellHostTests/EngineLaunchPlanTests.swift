import Foundation
import Testing
@testable import ShellHost

@Suite struct EngineLaunchPlanTests {
    /// A game over a temporary framework and app folders. Nothing in `gdir` or the data folder exists until a test adds it.
    struct Rig {
        let box: FrameworkBox
        let fw: URL
        let gdir: URL
        let data: URL
        var game: LaunchableGame

        init(environment: [String: String] = [:], cloud: URL? = nil) throws {
            box = try FrameworkBox()
            fw = try box.makeFramework()
            gdir = box.documents.appendingPathComponent("games/\(Fixtures.orbit)", isDirectory: true)
            data = box.root.appendingPathComponent("data", isDirectory: true)
            try box.makeFolder(data)
            let entry = try #require(GameCatalogue.scan(root: box.frameworks).first)
            game = LaunchableGame(titleID: entry.id, name: entry.title, manifest: try #require(entry.manifest), directory: fw, frameworkURL: fw,
                                  dataURL: data, appFolder: gdir, environment: environment, cloudSavesURL: cloud)
        }
        func plan(envFile: String? = nil) -> EngineLaunchPlan {
            EngineLaunchPlan.make(game: game, appResources: box.resources, documents: box.documents, envFileText: envFile)
        }
    }

    @Test func frameworkBuildEnvironmentReachesTheHostAndDocumentsCanOverrideIt() throws {
        let rig = try Rig()
        try rig.box.write("DM_PROF_TEX_BC_CPU=1\n", to: rig.fw.appendingPathComponent("dm/env.txt"))
        #expect(rig.plan().environment["DM_PROF_TEX_BC_CPU"] == "1")
        #expect(rig.plan().environment["DM_ENV_FILE_KEYS"] == "DM_PROF_TEX_BC_CPU")
        #expect(rig.plan(envFile: "DM_PROF_TEX_BC_CPU=0\n").environment["DM_PROF_TEX_BC_CPU"] == "0")
        try rig.box.write("DM_PROF_TEX_BC_CPU=0\n", to: rig.gdir.appendingPathComponent("env.txt"))
        #expect(rig.plan().environment["DM_PROF_TEX_BC_CPU"] == "0")
        let another = try Rig()
        #expect(another.plan().environment["DM_PROF_TEX_BC_CPU"] == nil)
    }

    @Test func defaultsPointIntoTheFramework() throws {
        let rig = try Rig()
        let env = rig.plan().environment
        #expect(env["DM_PROFILE"] == rig.fw.path + "/profile.tsv")
        #expect(env["DM_NVN_SHMAP"] == rig.fw.path + "/dm/shader_map.tsv")
        #expect(env["DM_MSL_DIR"] == rig.fw.path + "/msl")
        #expect(env["DM_PSO_BUNDLE"] == nil && env["DM_AOC_DIR"] == nil && env["DM_ROMFS"] == nil && env["DM_SAVE_SYNC"] == nil)
        #expect(env["DM_SAVE"] == rig.gdir.path + "/save" && env["DM_TEMP"] == rig.gdir.path + "/temp")
        #expect(env["DM_CHEATS"] == rig.gdir.path + "/cheats")
        #expect(env["DM_FONT_DIR"] == rig.box.resources.path + "/dm/font")
        #expect(env["DM_LAUNCHER"] == "0")
        #expect(env["DM_ENV_FILE_KEYS"] == "")
    }

    @Test func perGameFilesWinWhenPresent() throws {
        let rig = try Rig()
        try rig.box.write("x", to: rig.gdir.appendingPathComponent("profile.tsv"))
        try rig.box.makeFolder(rig.gdir.appendingPathComponent("msl"))
        try rig.box.makeFolder(rig.gdir.appendingPathComponent("pso"))
        try rig.box.makeFolder(rig.fw.appendingPathComponent("pso"))
        let env = rig.plan().environment
        #expect(env["DM_PROFILE"] == rig.gdir.path + "/profile.tsv")
        #expect(env["DM_MSL_DIR"] == rig.gdir.path + "/msl")
        #expect(env["DM_PSO_BUNDLE"] == rig.gdir.path + "/pso")
    }

    @Test func psoFallsBackToTheFramework() throws {
        let rig = try Rig()
        try rig.box.makeFolder(rig.fw.appendingPathComponent("pso"))
        #expect(rig.plan().environment["DM_PSO_BUNDLE"] == rig.fw.path + "/pso")
    }

    @Test(arguments: [false, true]) func sharedEnvCanDisableADiscoveredPipelineArchive(perGameArchive: Bool) throws {
        let rig = try Rig()
        try rig.box.makeFolder(rig.fw.appendingPathComponent("pso"))
        if perGameArchive { try rig.box.makeFolder(rig.gdir.appendingPathComponent("pso")) }
        let env = rig.plan(envFile: "DM_PSO_BUNDLE=off\n").environment
        #expect(env["DM_PSO_BUNDLE"] == "off")
        #expect(env["DM_ENV_FILE_KEYS"] == "DM_PSO_BUNDLE")
    }

    @Test func gameArchiveOverrideWinsOverSharedFileAndStaysWithItsGame() throws {
        let rig = try Rig()
        try rig.box.makeFolder(rig.fw.appendingPathComponent("pso"))
        try rig.box.write("DM_PSO_BUNDLE=off\n", to: rig.gdir.appendingPathComponent("env.txt"))
        let env = rig.plan(envFile: "DM_PSO_BUNDLE=/shared/archive\n").environment
        #expect(env["DM_PSO_BUNDLE"] == "off")
        #expect(env["DM_ENV_FILE_KEYS"] == "DM_PSO_BUNDLE")
        var other = rig.game
        other.appFolder = rig.box.documents.appendingPathComponent("games/0100000000000000")
        let otherPlan = EngineLaunchPlan.make(game: other, appResources: rig.box.resources, documents: rig.box.documents, envFileText: nil)
        #expect(otherPlan.environment["DM_PSO_BUNDLE"] == rig.fw.path + "/pso")
        #expect(otherPlan.environment["DM_ENV_FILE_KEYS"] == "")
    }

    @Test func explicitLaunchArchiveWinsOverEnvFilesAndDiscoveredArchives() throws {
        let rig = try Rig(environment: ["DM_PSO_BUNDLE": "/launch/archive"])
        try rig.box.makeFolder(rig.fw.appendingPathComponent("pso"))
        try rig.box.write("DM_PSO_BUNDLE=off\n", to: rig.gdir.appendingPathComponent("env.txt"))
        let env = rig.plan(envFile: "DM_PSO_BUNDLE=/shared/archive\n").environment
        #expect(env["DM_PSO_BUNDLE"] == "/launch/archive")
        #expect(env["DM_ENV_FILE_KEYS"] == "")
    }

    @Test func romfsImageIsMatchedCaseInsensitively() throws {
        let rig = try Rig()
        try rig.box.write("x", to: rig.data.appendingPathComponent("Romfs.IMG"))
        try rig.box.write("", to: rig.data.appendingPathComponent("fixture.marker"))
        let found = try #require(rig.plan().environment["DM_ROMFS"])
        #expect(found.lowercased() == rig.data.path.lowercased() + "/romfs.img", "the image wins over the marker in the same folder")
    }

    @Test func emptyImageFallsThroughToTheTree() throws {
        let rig = try Rig()
        try rig.box.write("", to: rig.data.appendingPathComponent("romfs.img"))
        try rig.box.write("", to: rig.data.appendingPathComponent("romfs/fixture.marker"))
        #expect(rig.plan().environment["DM_ROMFS"] == rig.data.path + "/romfs")
    }

    @Test func dataFolderItselfWithTheMarker() throws {
        let rig = try Rig()
        #expect(rig.plan().environment["DM_ROMFS"] == nil)
        try rig.box.write("", to: rig.data.appendingPathComponent("fixture.marker"))
        #expect(rig.plan().environment["DM_ROMFS"] == rig.data.path)
    }

    @Test func aocFromDataThenFromTheAppFolder() throws {
        let rig = try Rig()
        try rig.box.makeFolder(rig.gdir.appendingPathComponent("aoc"))
        #expect(rig.plan().environment["DM_AOC_DIR"] == rig.gdir.path + "/aoc")
        try rig.box.makeFolder(rig.data.appendingPathComponent("aoc"))
        #expect(rig.plan().environment["DM_AOC_DIR"] == rig.data.path + "/aoc")
    }

    @Test func settingsAndCloudFolderAreSet() throws {
        let cloud = URL(fileURLWithPath: "/tmp/cloud-saves/", isDirectory: true)
        let rig = try Rig(environment: ["DM_LANG": "de", "DM_SHOW_FPS": "1"], cloud: cloud)
        let env = rig.plan().environment
        #expect(env["DM_LANG"] == "de" && env["DM_SHOW_FPS"] == "1")
        #expect(env["DM_SAVE_SYNC"] == "/tmp/cloud-saves")
    }

    @Test func envFileParsing() {
        let text = "# comment\n\n  DM_A=1  \nnoequals\n=novalue\nDM_B=x=y\r\n  # indented comment\nDM_C=\n"
        let pairs = EngineLaunchPlan.parseEnvFile(text)
        #expect(pairs.map(\.key) == ["DM_A", "DM_B", "DM_C"])
        #expect(pairs.map(\.value) == ["1", "x=y", ""])
        #expect(EngineLaunchPlan.parseEnvFile("").isEmpty)
    }

    @Test func envFileNeverOverridesAndListsItsKeys() throws {
        let rig = try Rig(environment: ["DM_LANG": "de"])
        let env = rig.plan(envFile: "DM_LANG=fr\nDM_SAVE=/elsewhere\nDM_LAUNCHER=1\nDM_TRACE=2\nDM_OTHER=3\n").environment
        #expect(env["DM_LANG"] == "de" && env["DM_SAVE"] == rig.gdir.path + "/save" && env["DM_LAUNCHER"] == "0")
        #expect(env["DM_TRACE"] == "2" && env["DM_OTHER"] == "3")
        #expect(env["DM_ENV_FILE_KEYS"] == "DM_TRACE DM_OTHER")
    }

    /// #557: a mod's `DM_ROMFS_OVERLAY` in the shared file reached every game. The game's own file stays with the game.
    @Test func gameEnvFileWinsOverTheSharedOneAndIsReadFromTheGamesFolder() throws {
        let rig = try Rig(environment: ["DM_LANG": "de"])
        try FileManager.default.createDirectory(at: rig.gdir, withIntermediateDirectories: true)
        try "# this game\nDM_ROMFS_OVERLAY=/mods/orbit\nDM_TRACE=9\nDM_LANG=fr\nDM_SAVE=/elsewhere\n".write(to: rig.gdir.appendingPathComponent("env.txt"), atomically: true, encoding: .utf8)
        let env = rig.plan(envFile: "DM_ROMFS_OVERLAY=/mods/other\nDM_TRACE=1\nDM_OTHER=3\n").environment
        #expect(env["DM_ROMFS_OVERLAY"] == "/mods/orbit")
        #expect(env["DM_TRACE"] == "9")
        #expect(env["DM_OTHER"] == "3", "the shared file still applies to what the game's file does not set")
        #expect(env["DM_LANG"] == "de" && env["DM_SAVE"] == rig.gdir.path + "/save", "the launch environment wins over both files")
        #expect(env["DM_ENV_FILE_KEYS"] == "DM_ROMFS_OVERLAY DM_TRACE DM_OTHER")
    }

    @Test func anotherGameDoesNotSeeTheFirstGamesEnvFile() throws {
        let rig = try Rig()
        try FileManager.default.createDirectory(at: rig.gdir, withIntermediateDirectories: true)
        try "DM_ROMFS_OVERLAY=/mods/orbit\n".write(to: rig.gdir.appendingPathComponent("env.txt"), atomically: true, encoding: .utf8)
        var other = rig.game
        other.appFolder = rig.box.documents.appendingPathComponent("games/0100000000000000", isDirectory: true)
        let env = EngineLaunchPlan.make(game: other, appResources: rig.box.resources, documents: rig.box.documents, envFileText: nil).environment
        #expect(env["DM_ROMFS_OVERLAY"] == nil)
        #expect(env["DM_ENV_FILE_KEYS"] == "")
    }

    @Test func withoutAGameEnvFileOnlyTheSharedOneApplies() throws {
        let rig = try Rig()
        let env = rig.plan(envFile: "DM_TRACE=1\n").environment
        #expect(env["DM_TRACE"] == "1" && env["DM_ENV_FILE_KEYS"] == "DM_TRACE")
    }

    // MARK: the game's mods folder (#557)

    @Test func modsFolderSetsTheOverlayOnlyWhenItExistsAndHoldsAUsableMod() throws {
        let rig = try Rig()
        #expect(rig.plan().environment["DM_ROMFS_OVERLAY"] == nil)
        let mods = rig.gdir.appendingPathComponent("mods")
        try rig.box.makeFolder(mods)
        #expect(rig.plan().environment["DM_ROMFS_OVERLAY"] == nil, "an empty mods folder")
        try rig.box.makeFolder(mods.appendingPathComponent("code/exefs"))
        try rig.box.makeFolder(mods.appendingPathComponent(".hidden/romfs"))
        try rig.box.write("x", to: mods.appendingPathComponent("loose-file.txt"))
        #expect(rig.plan().environment["DM_ROMFS_OVERLAY"] == nil, "code only, hidden and plain files do not count")
        try rig.box.makeFolder(mods.appendingPathComponent("b/romfs"))
        try rig.box.makeFolder(mods.appendingPathComponent("a/atmosphere/contents/\(Fixtures.orbit)/romfs"))
        try rig.box.write("x", to: mods.appendingPathComponent("c/data.bin"))
        let env = rig.plan().environment
        #expect(env["DM_ROMFS_OVERLAY"] == [mods.path + "/a/atmosphere/contents/\(Fixtures.orbit)/romfs", mods.path + "/b/romfs", mods.path + "/c"].joined(separator: ":"))
        #expect(env["DM_ENV_FILE_KEYS"] == "", "the mods folder is not an env file")
    }

    @Test func modsOfOneGameDoNotReachAnother() throws {
        let rig = try Rig()
        try rig.box.makeFolder(rig.gdir.appendingPathComponent("mods/m/romfs"))
        var other = rig.game
        other.appFolder = rig.box.documents.appendingPathComponent("games/0100000000000000", isDirectory: true)
        let env = EngineLaunchPlan.make(game: other, appResources: rig.box.resources, documents: rig.box.documents, envFileText: nil).environment
        #expect(env["DM_ROMFS_OVERLAY"] == nil)
        #expect(rig.plan().environment["DM_ROMFS_OVERLAY"] == rig.gdir.path + "/mods/m/romfs")
    }

    @Test func overlayPrecedenceIsLaunchEnvironmentThenGameEnvFileThenModsThenSharedFile() throws {
        let shared = "DM_ROMFS_OVERLAY=/shared\n"
        // mods beat the shared file
        var rig = try Rig()
        try rig.box.makeFolder(rig.gdir.appendingPathComponent("mods/m/romfs"))
        #expect(rig.plan(envFile: shared).environment["DM_ROMFS_OVERLAY"] == rig.gdir.path + "/mods/m/romfs")
        #expect(rig.plan(envFile: shared).environment["DM_ENV_FILE_KEYS"] == "")
        // the game's env file beats the mods folder
        try rig.box.write("DM_ROMFS_OVERLAY=/own\n", to: rig.gdir.appendingPathComponent("env.txt"))
        #expect(rig.plan(envFile: shared).environment["DM_ROMFS_OVERLAY"] == "/own")
        // the launch environment beats the game's env file
        rig = try Rig(environment: ["DM_ROMFS_OVERLAY": "/launch"])
        try rig.box.makeFolder(rig.gdir.appendingPathComponent("mods/m/romfs"))
        try rig.box.write("DM_ROMFS_OVERLAY=/own\n", to: rig.gdir.appendingPathComponent("env.txt"))
        #expect(rig.plan(envFile: shared).environment["DM_ROMFS_OVERLAY"] == "/launch")
        // without a mods folder the shared file still applies
        let plain = try Rig()
        #expect(plain.plan(envFile: shared).environment["DM_ROMFS_OVERLAY"] == "/shared")
    }

    @Test func argumentsExecutableAndLocations() throws {
        let rig = try Rig()
        let plan = rig.plan()
        #expect(plan.arguments == ["dmhost", rig.fw.path + "/dm", "main", "sdk"])
        #expect(plan.frameworkExecutable.path == rig.fw.path + "/DmGame")
        #expect(plan.imageMarker == "dmgame_image_marker")
        #expect(plan.logURL.path == rig.box.documents.path + "/log.txt")
        #expect(plan.workingDirectory.path == rig.box.documents.path)
        #expect(plan.foldersToCreate.map(\.path) == [rig.gdir.path + "/save", rig.gdir.path + "/temp"])
    }

    @Test func makingThePlanCreatesNothingButCreateFoldersDoes() throws {
        let rig = try Rig()
        let plan = rig.plan()
        #expect(!FileManager.default.fileExists(atPath: rig.gdir.path))
        try plan.createFolders()
        for url in plan.foldersToCreate { #expect(FileManager.default.fileExists(atPath: url.path)) }
        #expect(!FileManager.default.fileExists(atPath: rig.gdir.path + "/cheats"))
        try plan.createFolders()
    }
}
