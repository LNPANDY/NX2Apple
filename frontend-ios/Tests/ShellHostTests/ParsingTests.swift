import Foundation
import Testing
@testable import ShellHost

@Suite struct ParsingTests {
    private func fixture(_ id: String, _ file: String) throws -> Data {
        try Data(contentsOf: Fixtures.gamesURL.appendingPathComponent(id).appendingPathComponent(file))
    }

    @Test func parsesTheManifest() throws {
        let m = try GameManifest.parse(fixture(Fixtures.orbit, "game.manifest.json"))
        #expect(m.titleID == Fixtures.orbit)
        #expect(m.name == "Orbit Fixture")
        #expect(m.chain == "b-3f9a2c")
        #expect(m.modules == ["main", "sdk"])
        #expect(m.framework == "DmGame.framework")
        #expect(m.romfsMarker == "fixture.marker")
        #expect(m.icon == nil)
    }

    @Test func malformedManifestsGiveReadableReasons() throws {
        func problem(_ text: String) -> GameProblem? {
            do { _ = try GameManifest.parse(Data(text.utf8)); return nil } catch { return error }
        }
        let truncated = try #require(problem(String(decoding: fixture(Fixtures.badManifest, "game.manifest.json"), as: UTF8.self)))
        #expect(truncated.detail.contains("not valid JSON"))
        let missing = try #require(problem(String(decoding: fixture(Fixtures.missingKey, "game.manifest.json"), as: UTF8.self)))
        #expect(missing.detail.contains("display_version") || missing.detail.contains("\"") )
        #expect(missing.reason == "Game files damaged")
        #expect(problem("[]") != nil)
        #expect(problem("")?.detail.contains("game.manifest.json") == true)
    }

    @Test func manifestValidation() throws {
        let good = String(decoding: try fixture(Fixtures.orbit, "game.manifest.json"), as: UTF8.self)
        func broken(_ from: String, _ to: String) -> GameProblem? {
            do { _ = try GameManifest.parse(Data(good.replacingOccurrences(of: from, with: to).utf8)); return nil } catch { return error }
        }
        #expect(broken("\"schema\": 1", "\"schema\": 2")?.reason == "Manifest not supported")
        #expect(broken("\"title_id\": \"0100000000010000\"", "\"title_id\": \"zz\"")?.detail.contains("16 hex") == true)
        #expect(broken("\"b-3f9a2c\"", "\"3f9a2c\"")?.detail.contains("b-<hex>") == true)
        #expect(broken("\"FR\"", "\"XX\"")?.detail.contains("loader") == true)
        #expect(broken("\"DmGame.framework\"", "\"../x\"")?.detail.contains(".framework") == true)
        #expect(broken("\"main\",\n    \"sdk\"", "")?.detail.contains("no modules") == true)
    }

    @Test func parsesTheLauncherProfile() throws {
        let p = try LauncherProfile.parse(fixture(Fixtures.orbit, "launcher.json"))
        #expect(p.game == Fixtures.orbit)
        #expect(p.settings.map(\.env) == ["DM_OPMODE", "DM_SHOW_FPS", "DM_UPSCALER", "DM_UPSCALER_SHARPNESS", "DM_RENDER_SCALE"])
        #expect(p.settings[0].level == "basic")
        #expect(p.settings[3].needs == "DM_UPSCALER=fsr")
    }

    @Test func malformedLauncherJSONGivesReadableReasons() throws {
        func problem(_ text: String) -> GameProblem? {
            do { _ = try LauncherProfile.parse(Data(text.utf8)); return nil } catch { return error }
        }
        let noOptions = String(decoding: try fixture(Fixtures.badSettings, "launcher.json"), as: UTF8.self)
        #expect(problem(noOptions)?.detail.contains("DM_X is a choice without") == true)
        #expect(problem("{")?.detail.contains("not valid JSON") == true)
        #expect(problem("{\"game\":\"0100000000010000\"}")?.detail.contains("settings") == true)
        #expect(problem("{\"game\":\"1\",\"settings\":[]}")?.detail.contains("16 hex") == true)
        #expect(problem("{\"schema\":2,\"game\":\"0100000000010000\",\"settings\":[]}")?.reason == "Settings list not supported")
        let row = "{\"env\":\"DM_A\",\"kind\":\"toggle\",\"section\":\"Game\",\"label\":\"A\",\"note\":\"\",\"default\":\"0\"}"
        #expect(problem("{\"game\":\"0100000000010000\",\"settings\":[\(row),\(row)]}")?.detail.contains("twice") == true)
        #expect(problem("{\"game\":\"0100000000010000\",\"settings\":[\(row.replacingOccurrences(of: "DM_A", with: "path"))]}")?.detail.contains("not a DM_ switch") == true)
        #expect(problem("{\"game\":\"0100000000010000\",\"settings\":[\(row.replacingOccurrences(of: "toggle", with: "dial"))]}")?.detail.contains("unknown kind") == true)
        let range = "{\"env\":\"DM_R\",\"kind\":\"range\",\"section\":\"Game\",\"label\":\"R\",\"note\":\"\",\"default\":\"1\",\"min\":0,\"max\":2}"
        #expect(problem("{\"game\":\"0100000000010000\",\"settings\":[\(range)]}")?.detail.contains("min, max and step") == true)
        #expect(problem("{\"game\":\"0100000000010000\",\"settings\":[]}") == nil)
    }

    @Test func settingRules() throws {
        let p = try LauncherProfile.parse(fixture(Fixtures.orbit, "launcher.json"))
        let scale = try #require(p.settings.first { $0.env == "DM_RENDER_SCALE" })
        #expect(scale.isDefault("1.00") && !scale.isDefault("1.05"))
        #expect(scale.accepts("0.5") && !scale.accepts("2") && !scale.accepts("0x1") && !scale.accepts("x"))
        let mode = p.settings[0]
        #expect(mode.accepts("0") && !mode.accepts("2"))
        let fps = p.settings[1]
        #expect(fps.accepts("1") && fps.accepts("0") && !fps.accepts("yes"))
        #expect(fps.defaultsKey == "launcher.DM_SHOW_FPS")
    }

    @Test func versionHelpers() {
        #expect(parseVersion("26.0")?.majorVersion == 26)
        #expect(parseVersion("26.1.2")?.patchVersion == 2)
        #expect(parseVersion("x") == nil)
        let v26 = OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        #expect(isVersion(OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0), atLeast: v26))
        #expect(!isVersion(OperatingSystemVersion(majorVersion: 18, minorVersion: 9, patchVersion: 0), atLeast: v26))
    }
}
