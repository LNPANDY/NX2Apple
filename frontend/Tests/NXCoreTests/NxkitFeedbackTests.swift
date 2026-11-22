import Foundation
import XCTest
@testable import NXCore

/// The game report "Did it work?" opens (LNPANDY/NX2Apple#1460): the field ids of nxkit's issue form (v0lumehi/nxkit#34), the encoding,
/// the length cap, and no paths, user names or keys in it.
final class NxkitFeedbackTests: XCTestCase {
    private let home = "/Users/zijad"
    private let user = "zijad"

    private func report(_ result: NxkitFeedback.Result = .works, log: String = "", name: String = "Super Mario Odyssey", exit: Int32? = nil) -> NxkitFeedback.Report {
        NxkitFeedback.Report(gameName: name, titleID: "0100000000010000", gameVersion: "1.3.0", nxkitVersion: "0.10.2",
                             engineBuild: "e01c6312144767845a60021bc69fb597dd0c6f4eec353ae6739e9e586e5e374b", result: result,
                             exitCode: exit, log: log, macModel: "Mac15,8", macOSVersion: "26.1.0")
    }

    private func query(_ url: URL) -> [String: String] {
        var out: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] { out[item.name] = item.value }
        return out
    }

    func testTheFormsFieldIds() {
        XCTAssertEqual([NxkitFeedback.Field.titleID, NxkitFeedback.Field.gameVersion, NxkitFeedback.Field.result, NxkitFeedback.Field.nxkitVersion,
                        NxkitFeedback.Field.engineBuild, NxkitFeedback.Field.exitCode, NxkitFeedback.Field.macModel, NxkitFeedback.Field.macOSVersion,
                        NxkitFeedback.Field.log],
                       ["title_id", "game_version", "result", "nxkit_version", "engine_build", "exit_code", "mac_model", "macos_version", "log"])
        XCTAssertEqual(NxkitFeedback.Result.allCases.map(\.rawValue), ["Works", "Problems", "Does not start"], "the dropdown's option texts exactly")
    }

    func testTheURLIsTheIssueFormPrefilled() throws {
        let url = NxkitFeedback.issueURL(report(.doesNotStart, log: "line one\nline two", exit: 3), home: home, user: user)
        XCTAssertTrue(url.absoluteString.hasPrefix("https://github.com/v0lumehi/nxkit/issues/new?template=game_report.yml&"))
        let q = query(url)
        XCTAssertEqual(q["title"], "[Game] Super Mario Odyssey")
        XCTAssertEqual(q["title_id"], "0100000000010000")
        XCTAssertEqual(q["game_version"], "1.3.0")
        XCTAssertEqual(q["result"], "Does not start")
        XCTAssertEqual(q["nxkit_version"], "0.10.2")
        XCTAssertEqual(q["engine_build"], "e01c6312144767845a60021bc69fb597dd0c6f4eec353ae6739e9e586e5e374b")
        XCTAssertEqual(q["exit_code"], "3")
        XCTAssertEqual(q["mac_model"], "Mac15,8")
        XCTAssertEqual(q["macos_version"], "26.1.0")
        XCTAssertEqual(q["log"], "line one\nline two")
        XCTAssertNil(q["description"], "left for the player")
        XCTAssertNil(query(NxkitFeedback.issueURL(report(), home: home, user: user))["exit_code"])
    }

    func testEveryValueIsPercentEncoded() {
        let url = NxkitFeedback.issueURL(report(.doesNotStart, log: "a & b = c + d #1 ?", name: "Pokémon Scarlet & Violet"), home: home, user: user).absoluteString
        XCTAssertTrue(url.contains("result=Does%20not%20start"))
        XCTAssertTrue(url.contains("title=%5BGame%5D%20Pok%C3%A9mon%20Scarlet%20%26%20Violet"))
        XCTAssertTrue(url.contains("log=a%20%26%20b%20%3D%20c%20%2B%20d%20%231%20%3F"), url)
        XCTAssertEqual(query(URL(string: url)!)["log"], "a & b = c + d #1 ?")
    }

    func testTheURLStaysUnder8KBByCuttingTheLogFromTheTop() {
        let lines = (1...200).map { "line \($0) " + String(repeating: "x", count: 80) }
        let url = NxkitFeedback.issueURL(report(log: lines.joined(separator: "\n")), home: home, user: user)
        XCTAssertLessThanOrEqual(url.absoluteString.count, NxkitFeedback.maxURLLength)
        let log = query(url)["log"] ?? ""
        XCTAssertTrue(log.hasSuffix("line 200 " + String(repeating: "x", count: 80)), "the end of the log is kept")
        XCTAssertFalse(log.contains("line 1 "), "the top is cut")
        // only the last 200 lines are ever taken
        let many = (1...500).map { "l\($0)" }.joined(separator: "\n")
        let short = query(NxkitFeedback.issueURL(report(log: many), home: home, user: user))["log"] ?? ""
        XCTAssertEqual(short.split(separator: "\n").count, 200)
        XCTAssertTrue(short.hasPrefix("l301\n"))
    }

    func testNoPathsUserNamesOrKeys() {
        let log = """
        {"ev":"say","msg":"reading /Users/zijad/Games/Switch/Zelda [01007EF00011E000].nsp","t":1}
        keys: /Users/zijad/.switch/prod.keys
        output -o /Volumes/NX/out/01007EF00011E000.app done
        work dir ~/Library/Caches/NX2Apple/nxkit/01007EF00011E000
        user zijad started it
        header_key = 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
        master_key_0b=00112233445566778899aabbccddeeff
        title 01007EF00011E000 stays
        """
        let url = NxkitFeedback.issueURL(report(log: log), home: home, user: user)
        let text = query(url)["log"] ?? ""
        for leak in ["/Users", "zijad", "/Volumes", "Games/Switch", ".switch", "Library/Caches", "0123456789abcdef0123456789abcdef", "00112233445566778899aabbccddeeff"] {
            XCTAssertFalse(text.contains(leak), "\(leak) in \(text)")
            XCTAssertFalse(url.absoluteString.contains(leak), leak)
        }
        XCTAssertTrue(text.contains("prod.keys"), "the file's name stays, its folders go")
        XCTAssertTrue(text.contains("01007EF00011E000.app"))
        XCTAssertTrue(text.contains("user user started it"))
        XCTAssertTrue(text.contains("title 01007EF00011E000 stays"), "a title ID is not a key")
        XCTAssertTrue(text.contains("[hex]"))
    }

    func testTheGameNameHasNoPathEither() {
        let q = query(NxkitFeedback.issueURL(report(name: "/Users/zijad/Games/Zelda"), home: home, user: user))
        XCTAssertEqual(q["title"], "[Game] Zelda")
    }

    func testThisMacsModelAndVersion() {
        XCTAssertFalse(NxkitFeedback.macModel.isEmpty)
        XCTAssertTrue(NxkitFeedback.macModel.hasPrefix("Mac") || NxkitFeedback.macModel.contains(","), NxkitFeedback.macModel)
        XCTAssertEqual(NxkitFeedback.macOSVersion.split(separator: ".").count, 3)
    }

    func testSendFeedbackOpensTheFormWithOnlyWhatThisMacKnows() {
        let url = NxkitFeedback.feedbackURL(nxkitVersion: "0.10.2", engineBuild: "abc 1", macModel: "Mac15,8", macOSVersion: "26.1.0")
        XCTAssertTrue(url.absoluteString.hasPrefix(NxkitFeedback.newIssueURL + "?"))
        XCTAssertEqual(url.host, "github.com")
        XCTAssertEqual(url.path, "/v0lumehi/nxkit/issues/new", "feedback goes to v0lumehi/nxkit, never to NX2Apple")
        let q = query(url)
        XCTAssertEqual(q["template"], "game_report.yml")
        XCTAssertEqual(q["nxkit_version"], "0.10.2")
        XCTAssertEqual(q["engine_build"], "abc 1")
        XCTAssertEqual(q["mac_model"], "Mac15,8")
        XCTAssertEqual(q["macos_version"], "26.1.0")
        XCTAssertNil(q["title"], "the player names the game")
        XCTAssertNil(q["result"], "the player picks the result")
        XCTAssertNil(q["log"])
        let bare = query(NxkitFeedback.feedbackURL(nxkitVersion: "", engineBuild: "", macModel: "Mac15,8", macOSVersion: "26.1.0"))
        XCTAssertNil(bare["nxkit_version"], "an empty field is left out")
        XCTAssertNil(bare["engine_build"])
    }
}
