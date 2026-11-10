import Foundation
import Testing
import ShellUI
@testable import ShellHost

/// A shared app keeps every game's shader library out of the IPA, because a library of several gigabytes stops the
/// installers (LNPANDY/NX2Apple#947). The shell reads it from the game's own folder instead, so a game whose library was
/// never copied in has to say so rather than offer Play.
@Suite struct ShaderLibraryStateTests {
    private let env = HostEnvironment(chain: "b-3f9a2c", osVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0))
    private let found = DataResolution(url: URL(fileURLWithPath: "/tmp/x"), source: .app, pickedIsStale: false)

    private func entry(_ id: String, in box: Sandbox) -> CatalogueEntry {
        GameCatalogue.read(directory: box.games.appendingPathComponent(id))
    }

    private func shaderFolders(_ id: String, in box: Sandbox) -> [URL] {
        var folders = [box.appData.appendingPathComponent(id, isDirectory: true).appendingPathComponent("msl", isDirectory: true)]
        if let framework = entry(id, in: box).frameworkURL {
            folders.append(framework.appendingPathComponent("msl", isDirectory: true))
        }
        return folders
    }

    /// The fixtures keep their library inside the framework, the way an IPA built before the move does. Taking it
    /// away stands for a game whose library is still sitting beside the IPA on the Mac.
    private func takeTheLibraryOutOfTheFramework(_ id: String, in box: Sandbox) throws {
        let msl = box.games.appendingPathComponent(id).appendingPathComponent("DmGame.framework/msl")
        try FileManager.default.removeItem(at: msl)
    }

    @Test func aGameWithDataButNoShadersNeedsShaders() throws {
        let box = try Sandbox()
        try box.giveAppData()
        try takeTheLibraryOutOfTheFramework(Fixtures.orbit, in: box)
        let state = GameStateResolver.state(for: entry(Fixtures.orbit, in: box), data: found, environment: env,
                                            shaderFolders: shaderFolders(Fixtures.orbit, in: box))
        #expect(state == .needsShaderLibrary)
    }

    @Test func theMslFolderFromTheIpaMakesItPlayable() throws {
        let box = try Sandbox()
        try box.giveAppData()
        try takeTheLibraryOutOfTheFramework(Fixtures.orbit, in: box)
        // The player copied the `msl` folder the app wrote beside the IPA into the game's folder.
        try box.write("", to: box.appData.appendingPathComponent(Fixtures.orbit).appendingPathComponent("msl/b-3f9a2c/fixture.metal"))
        let state = GameStateResolver.state(for: entry(Fixtures.orbit, in: box), data: found, environment: env,
                                            shaderFolders: shaderFolders(Fixtures.orbit, in: box))
        #expect(state == .playable)
    }

    @Test func onePackedImageIsEnoughToo() throws {
        let box = try Sandbox()
        try box.giveAppData()
        try takeTheLibraryOutOfTheFramework(Fixtures.orbit, in: box)
        try box.write("", to: box.appData.appendingPathComponent(Fixtures.orbit).appendingPathComponent("msl/b-3f9a2c.img"))
        let state = GameStateResolver.state(for: entry(Fixtures.orbit, in: box), data: found, environment: env,
                                            shaderFolders: shaderFolders(Fixtures.orbit, in: box))
        #expect(state == .playable)
    }

    @Test func theLibraryOfTheOtherChainDoesNotCount() throws {
        let box = try Sandbox()
        try box.giveAppData()
        try takeTheLibraryOutOfTheFramework(Fixtures.orbit, in: box)
        // The app was updated to a new shader chain: the old library cannot be read by it.
        try box.write("", to: box.appData.appendingPathComponent(Fixtures.orbit).appendingPathComponent("msl/b-0000ff/x.metal"))
        let state = GameStateResolver.state(for: entry(Fixtures.orbit, in: box), data: found, environment: env,
                                            shaderFolders: shaderFolders(Fixtures.orbit, in: box))
        #expect(state == .needsShaderLibrary)
    }

    @Test func aPackedLibraryInsideTheFrameworkStillPlays() throws {
        let box = try Sandbox()
        try box.giveAppData()
        let fw = box.games.appendingPathComponent(Fixtures.orbit).appendingPathComponent("DmGame.framework")
        try FileManager.default.removeItem(at: fw.appendingPathComponent("msl"))
        // An IPA from before the move carries `msl-<UUID>.aar` and the launcher unpacks it on the first play.
        try Data().write(to: fw.appendingPathComponent("msl-8E1F.aar"))
        let state = GameStateResolver.state(for: entry(Fixtures.orbit, in: box), data: found, environment: env,
                                            shaderFolders: shaderFolders(Fixtures.orbit, in: box))
        #expect(state == .playable)
    }

    @Test func askingWithoutFoldersKeepsTheOldAnswer() throws {
        let box = try Sandbox()
        try box.giveAppData()
        try takeTheLibraryOutOfTheFramework(Fixtures.orbit, in: box)
        // Callers that know nothing about shader folders (the demo, the tests of other rules) are unchanged.
        #expect(GameStateResolver.state(for: entry(Fixtures.orbit, in: box), data: found, environment: env) == .playable)
    }

    @Test func gameDataComesBeforeShaders() throws {
        let box = try Sandbox()
        try takeTheLibraryOutOfTheFramework(Fixtures.orbit, in: box)
        // Nothing copied in at all: the first thing to ask for is the game data, not the library.
        let state = GameStateResolver.state(for: entry(Fixtures.orbit, in: box), data: .missing, environment: env,
                                            shaderFolders: shaderFolders(Fixtures.orbit, in: box))
        #expect(state == .needsGameData)
    }

    @MainActor @Test func theModelShowsTheNewStateAndClearsItOnceTheLibraryArrives() async throws {
        let box = try Sandbox()
        try box.giveAppData()
        try takeTheLibraryOutOfTheFramework(Fixtures.orbit, in: box)
        let model = ShellHostModel(config: box.config())
        let before = try #require(model.details.first { $0.id == Fixtures.orbit })
        #expect(before.game.state == .needsShaderLibrary)
        try box.write("", to: box.appData.appendingPathComponent(Fixtures.orbit).appendingPathComponent("msl/b-3f9a2c.img"))
        model.refreshAll()
        let after = try #require(model.details.first { $0.id == Fixtures.orbit })
        #expect(after.game.state == .playable)
    }

    @MainActor @Test func aGameWithoutDataSaysDataFirstEvenWithTheLibraryMissing() async throws {
        let box = try Sandbox()
        try takeTheLibraryOutOfTheFramework(Fixtures.orbit, in: box)
        let model = ShellHostModel(config: box.config())
        let orbit = try #require(model.details.first { $0.id == Fixtures.orbit })
        #expect(orbit.game.state == .needsGameData)
    }
}
