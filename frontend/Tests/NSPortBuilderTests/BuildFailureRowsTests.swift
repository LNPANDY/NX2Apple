import XCTest
@testable import NSPortBuilder

/// The failure rows for keys, game files and the build's own steps (issue #141): what sets each one, that its text names the
/// action, and that its button does it. The log lines are the script's real messages (Tests/Fixtures/build_failures.json).
final class BuildFailureRowsTests: XCTestCase {
    func fixture(_ id: String) throws -> BuildFailureTests.Fixture {
        try XCTUnwrap(BuildFailureTests().fixtures().first { $0.id == id }, id)
    }

    func tempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nspb-rows-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // ---- what sets each row

    func testTheKeysFileMissingFromTheScriptsMessage() throws {
        let f = BuildFailureClassifier.classify(try fixture("keys.missing").text)
        XCTAssertEqual(f.kind, .keys)
        // only the script's own line: the words inside another line are not it
        XCTAssertEqual(BuildFailureClassifier.classify("copying: no such file: x").kind, .unknown)
    }

    func testTheKeysFileThatCannotBeReadIsKnownFromTheFileNotFromTheLog() throws {
        let dir = try tempFolder(), keys = dir.appendingPathComponent("prod.keys")
        try Data("header_key = 00".utf8).write(to: keys)
        let log = "[RED] nx_extract exit code 1 (full output: /w/extract.log)"
        var inputs = BuildFailureClassifier.Inputs(keysPath: keys.path, paths: [], volumes: dir.path)
        XCTAssertEqual(BuildFailureClassifier.classify(log, inputs: inputs).kind, .unknown, "a readable file is not the cause")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: keys.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keys.path) }
        if getuid() != 0 { XCTAssertEqual(BuildFailureClassifier.classify(log, inputs: inputs).kind, .keys) }
        inputs.isReadable = { _ in false }
        XCTAssertEqual(BuildFailureClassifier.classify(log, inputs: inputs).kind, .keys)
        XCTAssertEqual(BuildFailureClassifier.classify("[RED] the iOS SDK is not installed", inputs: inputs).kind, .iosSDK, "a known stop keeps its own row")
    }

    func testSeveralGamesAndNoTitleID() throws {
        XCTAssertEqual(BuildFailureClassifier.classify(try fixture("games.several").text).kind, .severalGames)
        let none = try fixture("games.noTitleID")
        // after the key check passed, with the script's skip notes above the stop (#177)
        let log = "skipping an empty file: a.nsp\nskipping b.nsp: neither an NSP (PFS0) nor an XCI (HEAD at 0x100)\n" + none.text + "\n"
        let f = BuildFailureClassifier.classify(log)
        XCTAssertEqual(f.kind, .noTitleID)
        XCTAssertEqual(f.detail, none.folder)
    }

    func testAFullDiskNamesTheSizeWhenTheScriptDoes() throws {
        let low = BuildFailureClassifier.classify(try fixture("disk.low").text)
        XCTAssertEqual(low, BuildFailure(kind: .diskFull, gameName: nil, detail: try fixture("disk.low").gb))
        XCTAssertEqual(BuildFailureClassifier.classify(try fixture("disk.full").text), BuildFailure(kind: .diskFull, gameName: nil, detail: nil))
        let m = BuildModel()
        XCTAssertTrue(m.failureWhat(low).contains("40 GB"), m.failureWhat(low))
        XCTAssertFalse(m.failureWhat(BuildFailure(kind: .diskFull, gameName: nil)).contains("GB"))
    }

    func testADriveThatIsNotConnectedComesBeforeTheMessagesItCauses() throws {
        let volumes = try tempFolder()
        let gone = volumes.path + "/Games/Zelda/zelda.nsp"
        let log = try fixture("games.noTitleID").text
        let f = BuildFailureClassifier.classify(log, inputs: .init(keysPath: "", paths: [gone], volumes: volumes.path))
        XCTAssertEqual(f, BuildFailure(kind: .driveMissing, gameName: nil, detail: "Games"))
        try FileManager.default.createDirectory(at: volumes.appendingPathComponent("Games"), withIntermediateDirectories: true)
        XCTAssertEqual(BuildFailureClassifier.classify(log, inputs: .init(keysPath: "", paths: [gone], volumes: volumes.path)).kind, .noTitleID, "the drive is there")
        XCTAssertEqual(BuildFailureClassifier.classify(log, inputs: .init(keysPath: "/Users/x/prod.keys", paths: ["/Users/x/g.nsp"], volumes: volumes.path)).kind, .noTitleID, "a path off /Volumes is no drive")
        XCTAssertTrue(BuildModel().failureWhat(f).contains("“Games”"))
    }

    func testTheInstallStepsThatFailedBecomeRows() {
        let taken = "error: Failed to register bundle identifier. The app identifier \"org.nxnative.x\" cannot be registered to your development team."
        XCTAssertEqual(BuildFailureClassifier.classifyInstall(.sign, error: taken, teamListed: true)?.kind, .teamTaken)
        XCTAssertEqual(BuildFailureClassifier.classifyInstall(.sign, error: "error: No profiles for 'org.nxnative.x' were found", teamListed: true)?.kind, .teamTaken)
        XCTAssertEqual(BuildFailureClassifier.classifyInstall(.sign, error: "error: something", teamListed: false)?.kind, .noSigningAccount)
        XCTAssertNil(BuildFailureClassifier.classifyInstall(.sign, error: "error: something", teamListed: true), "the tool's line stays")
        for step in [BuildFailureClassifier.InstallStep.install, .copy] {
            XCTAssertEqual(BuildFailureClassifier.classifyInstall(step, error: "ERROR: The device is not connected. (com.apple.dt.CoreDeviceError error 4)", teamListed: true)?.kind, .deviceTransfer)
        }
        XCTAssertEqual(BuildFailureClassifier.classifyInstall(.copy, error: "No space left on device", teamListed: true)?.kind, .diskFull)
    }

    // ---- the text names the action

    func testEveryRowSaysWhatToDoNext() {
        let next: [(BuildFailureKind, [String])] = [
            (.keys, ["Choose your prod.keys again", "build again"]),
            (.severalGames, ["Move the other games", "folder of their own"]),
            (.noTitleID, ["Rename the file", "0100XXXXXXXXXXXX", "exact package", ".nsp, .xci, .nsz or .xcz", ".00 or .rar", "iCloud", "Show folder"]),
            (.driveMissing, ["Connect the drive"]),
            (.diskFull, ["Free up space", "_build"]),
            (.teamTaken, ["Xcode > Settings > Accounts"]),
            (.noSigningAccount, ["Xcode > Settings > Accounts"]),
            (.deviceTransfer, ["Unlock", "Trust", "cable", "try again"]),
        ]
        for (kind, words) in next {
            let en = L10n.table[kind.nextKey]?.en ?? ""
            for w in words { XCTAssertTrue(en.contains(w), "\(kind): \"\(w)\" is not in \"\(en)\"") }
        }
    }

    func testTheNewRowsAreInAllThreeLanguagesWithoutSemicolonsOrTheProductName() {
        var keys = ["fail.showFolder", "fail.openXcode", "fail.retry", "fail.keys.button", "fail.driveMissing.whatNamed", "fail.diskFull.whatNeeds"]
        let kinds = BuildFailureTests.stateKinds.union([.keys, .severalGames, .noTitleID, .diskFull])
        for k in BuildFailureKind.allCases where kinds.contains(k) { keys += [k.whatKey, k.nextKey] }
        for key in keys {
            let row = L10n.table[key]
            XCTAssertNotNil(row, key)
            let sv = L10n.sv[key]
            XCTAssertNotNil(sv, "\(key) has no Swedish text")
            XCTAssertNotEqual(sv, row?.en, "\(key) has the English text in the Swedish column")
            for text in [row?.zh ?? "", row?.en ?? "", sv ?? ""] {
                XCTAssertFalse(text.isEmpty, key)
                XCTAssertFalse(text.contains(";") || text.contains("\u{FF1B}"), "\(key) has a semicolon")
                XCTAssertFalse(text.localizedCaseInsensitiveContains("NX2Apple"), key)
            }
            XCTAssertNotEqual(row?.zh, row?.en, key)
            XCTAssertTrue(row?.zh.unicodeScalars.contains { $0.value >= 0x4E00 } ?? false, "\(key) has no Chinese")
        }
    }

    // ---- the card and its buttons

    func testAFailedBuildShowsTheRowForItsLogLine() throws {
        for (id, kind) in [("keys.missing", BuildFailureKind.keys), ("games.several", .severalGames), ("games.noTitleID", .noTitleID), ("disk.low", .diskFull), ("disk.full", .diskFull)] {
            let m = BuildModel()
            m.logTail = try fixture(id).text + "\n"
            m.noteFailure()
            XCTAssertEqual(m.failure?.kind, kind, id)
            XCTAssertEqual(m.doneNote, m.failureWhat(m.failure!), id)
        }
    }

    func testTheKeysButtonOpensTheKeysPicker() {
        let m = BuildModel()
        var opened = 0
        m.chooseKeys = { opened += 1 }
        m.failure = BuildFailure(kind: .keys, gameName: nil)
        m.fixBuildFailure(.keys)
        XCTAssertEqual(opened, 1)
    }

    func testShowFolderRevealsTheGameFolderAndForAFullDiskTheBuildFolder() throws {
        let dir = try tempFolder()
        let m = BuildModel()
        var shown: [String] = []
        m.revealFolder = { shown.append($0.path) }
        m.gameDir = dir.path
        m.failure = BuildFailure(kind: .noTitleID, gameName: nil, detail: "/elsewhere")
        m.fixBuildFailure(.noTitleID)
        m.failure = BuildFailure(kind: .severalGames, gameName: nil)
        m.fixBuildFailure(.severalGames)
        XCTAssertEqual(shown, [dir.path, dir.path])
        shown = []
        m.failure = BuildFailure(kind: .diskFull, gameName: nil)
        m.fixBuildFailure(.diskFull)
        XCTAssertEqual(shown, [dir.path], "no build folder yet")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("0100F2C0115B6000_build"), withIntermediateDirectories: true)
        shown = []
        m.fixBuildFailure(.diskFull)
        XCTAssertEqual(shown, [dir.path + "/0100F2C0115B6000_build"])
        shown = []
        m.gameDir = ""
        m.failure = BuildFailure(kind: .noTitleID, gameName: nil, detail: "/Users/x/Games/Zelda")
        m.fixBuildFailure(.noTitleID)
        XCTAssertEqual(shown, ["/Users/x/Games/Zelda"], "the folder the message names")
    }

    func testAnInstallStepThatFailedShowsItsRow() {
        let m = BuildModel()
        m.signingTeam = "TEAM123456"
        m.teamsProvider = { [SigningTeam(id: "TEAM123456", identity: "")] }
        m.noteInstallFailure(.sign, error: "error: Failed to register bundle identifier: cannot be registered to your development team")
        XCTAssertEqual(m.failure?.kind, .teamTaken)
        XCTAssertEqual(m.doneNote, m.t("fail.teamTaken.what"))
        m.teamsProvider = { [] }
        m.noteInstallFailure(.sign, error: "error: x")
        XCTAssertEqual(m.failure?.kind, .noSigningAccount)
        m.noteInstallFailure(.install, error: "ERROR: The device is not connected.")
        XCTAssertEqual(m.failure?.kind, .deviceTransfer)
        m.teamsProvider = { [SigningTeam(id: "TEAM123456", identity: "")] }
        m.failure = BuildFailure(kind: .teamTaken, gameName: nil)
        m.noteInstallFailure(.sign, error: "error: x")
        XCTAssertNil(m.failure, "an unknown signing error leaves the tool's line")
    }

    func testTryAgainStartsANewBuildAndClearsTheCard() {
        let m = BuildModel()
        m.failure = BuildFailure(kind: .deviceTransfer, gameName: nil)
        m.fixBuildFailure(.deviceTransfer)   // no repository here: the build stops at once, but it has started and dropped the old card
        XCTAssertNil(m.failure)
    }

    func testTheXcodeButtonOpensXcodeWhenItIsInstalled() {
        let m = BuildModel()
        var opened: [URL] = []
        m.openApp = { opened.append($0) }
        m.failure = BuildFailure(kind: .teamTaken, gameName: nil)
        m.fixBuildFailure(.teamTaken)
        if let xcode = BuildModel.installedXcode() { XCTAssertEqual(opened, [URL(fileURLWithPath: xcode)]) } else { XCTAssertTrue(opened.isEmpty) }
    }
}
