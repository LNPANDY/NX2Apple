import Foundation
import XCTest
@testable import NXCore

/// An app nxkit built without a game profile (v0lumehi/nxkit#54): the `build` object of its launcher.json, read tolerantly, and the
/// prefilled report its page opens.
final class NxkitBuildProfileTests: XCTestCase {
    private func parse(_ json: String) -> NxkitBuildProfile? { NxkitBuildProfile.parse(Data(json.utf8)) }

    func testANormalBuildShowsNothing() {
        XCTAssertNil(parse(#"{"schema":1,"settings":[]}"#), "no build object: a normal build")
        XCTAssertNil(parse(#"{"settings":[],"build":{"profile":"title","engine":"unreal","graphics":"nvn"}}"#))
        XCTAssertNil(parse(#"{"build":null}"#))
    }

    func testAGenericBuildWithEverything() {
        let profile = parse(#"{"settings":[],"build":{"profile":"generic","engine":"unreal","graphics":"vulkan","evidence":["UnrealEngine","vk*"]}}"#)
        XCTAssertEqual(profile, NxkitBuildProfile(engine: "unreal", graphics: "vulkan", evidence: ["UnrealEngine", "vk*"]))
        XCTAssertEqual(profile?.engineName, "Unreal Engine")
        XCTAssertEqual(profile?.graphicsName, "Vulkan")
    }

    func testAGenericBuildWithNothingDetected() {
        let profile = parse(#"{"build":{"profile":"generic","engine":null,"graphics":null}}"#)
        XCTAssertEqual(profile, NxkitBuildProfile())
        XCTAssertNil(profile?.engineName)
        XCTAssertNil(profile?.graphicsName)
        XCTAssertEqual(parse(#"{"build":{"profile":"GENERIC","engine":"  "}}"#), NxkitBuildProfile(), "case and blank values")
    }

    func testFieldsOfTheWrongTypeAreLeftOut() {
        let profile = parse(#"{"build":{"profile":"generic","engine":7,"graphics":["nvn"],"evidence":["a",1,null,"b"],"later":{"x":1}}}"#)
        XCTAssertEqual(profile, NxkitBuildProfile(engine: nil, graphics: nil, evidence: ["a", "b"]))
        XCTAssertEqual(parse(#"{"build":{"profile":"generic","evidence":"one"}}"#), NxkitBuildProfile())
    }

    func testWhatThisLauncherCannotReadShowsNothing() {
        XCTAssertNil(parse(#"{"build":{"profile":"partial"}}"#), "a profile value this launcher does not know")
        XCTAssertNil(parse(#"{"build":{"profile":1}}"#))
        XCTAssertNil(parse(#"{"build":"generic"}"#))
        XCTAssertNil(parse(#"{"build":{}}"#))
        XCTAssertNil(parse("not json"))
        XCTAssertNil(parse(#"["build"]"#))
    }

    func testUnknownIdsAreShownAsTheyAre() {
        let profile = NxkitBuildProfile(engine: "cocos", graphics: "metal")
        XCTAssertEqual(profile.engineName, "cocos")
        XCTAssertEqual(profile.graphicsName, "metal")
        XCTAssertEqual(NxkitBuildProfile(graphics: "opengl").graphicsName, "OpenGL")
        XCTAssertEqual(NxkitBuildProfile(graphics: "NVN").graphicsName, "NVN")
    }

    func testReadFromAnAppAndAgainWhenTheFileChanges() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("NxkitBuildProfileTests-\(UUID().uuidString)/Game.app")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        XCTAssertNil(NxkitBuildProfile.read(app: app.path), "no app")
        XCTAssertNil(NxkitBuildProfile.read(app: ""))
        let list = NxkitBuildProfile.listURL(app: app.path)
        XCTAssertEqual(list.path, app.path + "/Contents/Resources/nxkit/launcher.json")
        try FileManager.default.createDirectory(at: list.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"settings":[],"build":{"profile":"generic","graphics":"opengl"}}"#.utf8).write(to: list)
        XCTAssertEqual(NxkitBuildProfile.read(app: app.path), NxkitBuildProfile(graphics: "opengl"))
        // rebuilt with a game profile: a different size, read again
        try Data(#"{"settings":[],"build":{"profile":"title"}}"#.utf8).write(to: list)
        XCTAssertNil(NxkitBuildProfile.read(app: app.path))
    }

    func testTheReportIsPrefilledWithWhatTheLauncherKnows() throws {
        let url = NxkitFeedback.genericBuildReportURL(titleID: "0100abcd00010000", gameVersion: "1.2.0", nxkitVersion: "0.10.3",
                                                      macModel: "Mac15,8", macOSVersion: "26.1.0")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme! + "://" + components.host! + components.path, NxkitFeedback.newIssueURL)
        XCTAssertEqual(components.queryItems?.map(\.name), ["template", "title_id", "game_version", "nxkit_version", "mac_model", "macos_version"])
        let values = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(values["template"], "game_report.yml")
        XCTAssertEqual(values["title_id"], "0100ABCD00010000")
        XCTAssertEqual(values["game_version"], "1.2.0")
        XCTAssertEqual(values["nxkit_version"], "0.10.3")
        XCTAssertEqual(values["mac_model"], "Mac15,8")
        XCTAssertEqual(values["macos_version"], "26.1.0")
    }

    func testAnUnknownValueIsLeftOutOfTheReport() throws {
        let url = NxkitFeedback.genericBuildReportURL(titleID: "0100ABCD00010000", gameVersion: "", nxkitVersion: "", macModel: "", macOSVersion: "26.1.0")
        let names = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems).map(\.name)
        XCTAssertEqual(names, ["template", "title_id", "macos_version"])
    }
}
