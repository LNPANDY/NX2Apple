import XCTest
@testable import NSPortBuilder

/// #263: a build folder in iCloud Drive fails at the signing step ("resource fork, Finder information, or similar detritus not
/// allowed"). The launcher says so before the build starts, and reads the same words from a log.
final class CloudFolderTests: XCTestCase {
    private var home: URL!
    private var saved: [(String, Any?)] = []

    override func setUpWithError() throws {
        saved = ["repoPath", "buildOutputDirectory"].map { ($0, UserDefaults.standard.object(forKey: $0)) }
        home = FileManager.default.temporaryDirectory.appendingPathComponent("nspb-cloud-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for (key, value) in saved { UserDefaults.standard.set(value, forKey: key) }
        try? FileManager.default.removeItem(at: home)
    }

    private func folder(_ rel: String) throws -> String {
        let url = home.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    private func contains(_ path: String, synced: Bool = false) -> Bool {
        CloudFolder.contains(path, home: home.path, isSynced: { _ in synced })
    }

    // ---- by place

    func testICloudDriveAndFileProviderFoldersAreCloudFolders() throws {
        let drive = try folder("Library/Mobile Documents/com~apple~CloudDocs/Downloads")
        let provider = try folder("Library/CloudStorage/OneDrive-Personal")
        XCTAssertTrue(contains(drive))
        XCTAssertTrue(contains(drive + "/0100152000022000_build"), "a build folder that does not exist yet")
        XCTAssertTrue(contains(drive + "/a/b/c/0100152000022000_build"), "several levels that do not exist yet")
        XCTAssertTrue(contains(provider + "/Games"))
        XCTAssertTrue(contains(home.path + "/Library/Mobile Documents"), "the root itself")
    }

    func testOtherFoldersAreNot() throws {
        let games = try folder("Games")
        _ = try folder("Library/Mobile Documents")
        let lookalike = try folder("Library/Mobile Documents Backup")
        XCTAssertFalse(contains(games))
        XCTAssertFalse(contains(games + "/0100152000022000_build"))
        XCTAssertFalse(contains(lookalike), "only a folder inside the root counts")
        XCTAssertFalse(contains("/Volumes/NX/games/0100152000022000_build"))
        XCTAssertFalse(contains(""))
    }

    func testALinkIntoACloudFolderIsOne() throws {
        let target = try folder("Library/Mobile Documents/com~apple~CloudDocs/Games")
        let link = home.appendingPathComponent("Games")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target)
        XCTAssertTrue(contains(link.path + "/0100152000022000_build"))
        let outside = try folder("Elsewhere")
        let away = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Away")
        try FileManager.default.createSymbolicLink(atPath: away.path, withDestinationPath: outside)
        XCTAssertFalse(contains(away.path + "/x_build"), "a link out of iCloud Drive leads out of it")
    }

    // ---- by the system's answer (Desktop and Documents synced to iCloud)

    func testAFolderTheSystemSaysIsSyncedIsOne() throws {
        let documents = try folder("Documents/Games")
        XCTAssertFalse(contains(documents))
        XCTAssertTrue(contains(documents, synced: true))
        var asked: [String] = []
        XCTAssertFalse(CloudFolder.contains(documents + "/x_build", home: home.path, isSynced: { asked.append($0.path); return false }))
        XCTAssertEqual(asked.map { URL(fileURLWithPath: $0).standardizedFileURL.lastPathComponent }, ["Games"], "the nearest folder that exists is asked")
    }

    func testTheSystemAnswerForAnOrdinaryFolderIsNo() throws {
        XCTAssertFalse(CloudFolder.systemSyncs(URL(fileURLWithPath: try folder("Plain"))))
    }

    // ---- the log

    func testTheCodesignLineOfTheIssueIsTheCloudFolderStop() throws {
        let f = try XCTUnwrap(BuildFailureTests().fixtures().first { $0.id == "icloud.detritus" })
        XCTAssertEqual(BuildFailureClassifier.classify(f.text).kind, .cloudFolder)
        let log = "FAIL: ad-hoc signature with the entitlements\nCodeSign /Users/x/DmIOS.app\n/Users/x/DmIOS.app: resource fork, Finder information, or similar detritus not allowed\n"
        XCTAssertEqual(BuildFailureClassifier.classify(log).kind, .cloudFolder)
        XCTAssertEqual(BuildFailureClassifier.classify("FAIL: ad-hoc signature with the entitlements").kind, .unknown, "another signing failure keeps its note")
    }

    func testTheHintHasAllFourLanguagesAndNoSemicolons() {
        let keys = [BuildFailureKind.cloudFolder.whatKey, BuildFailureKind.cloudFolder.nextKey, "fail.cloudFolder.button"]
        for key in keys {
            let row = L10n.table[key]
            XCTAssertNotNil(row, key)
            let texts = [row?.zh ?? "", row?.en ?? "", L10n.sv[key] ?? "", L10n.de[key] ?? ""]
            for text in texts {
                XCTAssertFalse(text.isEmpty, key)
                XCTAssertFalse(text.contains(";") || text.contains("\u{FF1B}") || text.contains("\u{2014}"), "\(key) has a semicolon or a dash")
            }
            XCTAssertEqual(Set(texts).count, 4, "\(key) has a text twice")
        }
        XCTAssertTrue(L10n.table[BuildFailureKind.cloudFolder.nextKey]!.en.contains("iCloud Drive"))
    }

    // ---- before the build

    @MainActor func testABuildInACloudFolderStopsBeforeItStarts() throws {
        let repo = home.appendingPathComponent("repo")
        for f in BuildModel.requiredTools + ["dm/tools/nx_extract/Program.cs"] {
            let url = repo.appendingPathComponent(f)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "x".write(to: url, atomically: true, encoding: .utf8)
        }
        let m = BuildModel()
        m.target = BuildTarget.mac   // the iPhone / iPad target stops first, at the device check
        m.repoPath = repo.path
        m.outDir = ""
        m.updateSlot("base") { $0.paths = ["/Games/Game [0100152000022000].nsp"] }
        var asked: [String] = []
        m.cloudFolderCheck = { asked.append($0); return true }
        m.startBuild()
        XCTAssertEqual(asked, ["/Games/0100152000022000_build"], "the build folder next to the game files")
        XCTAssertFalse(m.running)
        XCTAssertEqual(m.failure?.kind, .cloudFolder)
        XCTAssertEqual(m.doneNote, m.t(BuildFailureKind.cloudFolder.whatKey))

        m.outDir = "/Volumes/NX/out"
        asked = []
        m.startBuild()
        XCTAssertEqual(asked, ["/Volumes/NX/out/0100152000022000_build"], "Save to wins when it is set")
    }
}
