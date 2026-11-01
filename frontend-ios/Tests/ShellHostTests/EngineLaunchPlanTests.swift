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
