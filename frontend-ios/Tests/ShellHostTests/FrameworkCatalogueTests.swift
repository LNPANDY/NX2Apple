import Foundation
import Testing
@testable import ShellHost

@Suite struct FrameworkCatalogueTests {
    @Test func listsAGameFrameworkWithItsManifestName() throws {
        let box = try FrameworkBox()
        let fw = try box.makeFramework()
        let entries = GameCatalogue.scan(root: box.frameworks)
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.id == Fixtures.orbit && entry.title == "Orbit Fixture")
        #expect(entry.problem == nil && entry.profile != nil)
        #expect(entry.directory.path == fw.path && entry.frameworkURL?.path == fw.path)
    }

    @Test func skipsFrameworksWithoutAManifest() throws {
        let box = try FrameworkBox()
        try box.makeFolder(box.frameworks.appendingPathComponent("libswiftCore.framework"))
        try box.makeFramework()
        #expect(GameCatalogue.scan(root: box.frameworks).map(\.id) == [Fixtures.orbit])
    }

    @Test func aDamagedManifestStaysListedWithTheFolderName() throws {
        let box = try FrameworkBox()
        try box.write("{", to: box.frameworks.appendingPathComponent("Broken.framework/game.manifest.json"))
        let entry = try #require(GameCatalogue.scan(root: box.frameworks).first)
        #expect(entry.id == "Broken" && entry.problem != nil && entry.frameworkURL == nil)
    }

    @Test func aNameMismatchIsBroken() throws {
        let box = try FrameworkBox()
        try box.makeFramework(folder: "Renamed.framework", manifestFramework: "DmGame.framework")
        let entry = try #require(GameCatalogue.scan(root: box.frameworks).first)
        #expect(entry.problem?.reason == "Game files damaged")
        #expect(entry.problem?.detail.contains("Renamed.framework") == true && entry.problem?.detail.contains("DmGame.framework") == true)
    }

    @Test func theSecondFrameworkWithATitleIDIsBroken() throws {
        let box = try FrameworkBox()
        try box.makeFramework(folder: "A.framework")
        try box.makeFramework(folder: "B.framework")
        let entries = GameCatalogue.scan(root: box.frameworks)
        #expect(entries.count == 2)
        let a = try #require(entries.first { $0.directory.lastPathComponent == "A.framework" })
        let b = try #require(entries.first { $0.directory.lastPathComponent == "B.framework" })
        #expect(a.problem == nil && a.id == Fixtures.orbit)
        #expect(b.problem?.reason == "Game files damaged" && b.problem?.detail.contains("A.framework") == true)
        #expect(a.id != b.id)
    }

    @Test func launcherFileFallbackAndPicturesAreFoundInsideTheFramework() throws {
        let box = try FrameworkBox()
        let fw = try box.makeFramework(launcherAt: "launcher.json")
        try box.write("x", to: fw.appendingPathComponent("icon.png"))
        try box.write("x", to: fw.appendingPathComponent("banner.jpg"))
        let entry = try #require(GameCatalogue.scan(root: box.frameworks).first)
        #expect(entry.problem == nil)
        #expect(entry.iconURL?.lastPathComponent == "icon.png" && entry.bannerURL?.lastPathComponent == "banner.jpg")
        #expect(entry.iconURL?.deletingLastPathComponent().path == fw.path)
    }

    @Test func launcherJSONInsideDmIsFound() throws {
        let box = try FrameworkBox()
        try box.makeFramework(launcherAt: "dm/launcher.json")
        #expect(GameCatalogue.scan(root: box.frameworks).first?.problem == nil)
    }

    @Test func theGamesFolderLayoutStillSetsTheFrameworkURL() throws {
        let entry = GameCatalogue.read(directory: Fixtures.gamesURL.appendingPathComponent(Fixtures.orbit))
        #expect(entry.frameworkURL?.lastPathComponent == "DmGame.framework")
        #expect(entry.frameworkURL?.deletingLastPathComponent().lastPathComponent == Fixtures.orbit)
    }
}
