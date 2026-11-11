import XCTest
@testable import NX2Apple
@testable import NXCore
import NXModel
@testable import NXLauncher

/// The failure rows for keys, game files and the build's own steps (issue #141): what sets each one, that its text names the
/// action, and that its button does it. The log lines are the script's real messages (Tests/Fixtures/build_failures.json).
@MainActor final class BuildFailureRowsTests: IsolatedDefaultsTestCase {
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

    func testAMissingZbicPackageIsItsOwnRowWithAnInstallButton() throws {
        let log = "[3/9] extract\n" + (try fixture("zbic.missing").text) + "\n"
        XCTAssertEqual(BuildFailureClassifier.classify(log).kind, .zbic)
        XCTAssertEqual(BuildFailureClassifier.classify("[RED] the zbic package decoded it").kind, .unknown)
        XCTAssertTrue(L10n.table["fail.zbic.next"]?.en.contains("pip install zbic") ?? false)
        XCTAssertEqual(L10n.table["fail.zbic.button"]?.en, "Install zbic")
        let mStores = LauncherStores(defaults: testDefaults); let m = mStores.build
        m.logTail = log
        m.noteFailure()
        XCTAssertEqual(m.failure?.kind, .zbic)
        XCTAssertFalse(m.fixBusy(.zbic))
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
        let mStores = LauncherStores(defaults: testDefaults); let m = mStores.build
        m.lang = .en   // the English text, whatever the Mac's language
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
        let mStores = LauncherStores(defaults: testDefaults); let m = mStores.build
        m.lang = .en   // the quotes are English ones whatever the device language is
        XCTAssertTrue(m.failureWhat(f).contains("“Games”"))
    }

    func testOfflinePipelinesExplainLowSpaceAndKeepTheEngineEstimate() throws {
        let stores = LauncherStores(defaults: testDefaults)
        stores.build.lang = .en
        for (id, gb) in [("pso.low", "3"), ("pso.merge", "2.5"), ("pso.failed", nil)] {
            let message = try fixture(id).text
            let failure = BuildFailureClassifier.classify(message)
            XCTAssertEqual(failure.kind.rawValue, "psoDiskFull", id)
            XCTAssertEqual(failure.detail, gb, id)
            if let gb { XCTAssertTrue(stores.build.failureWhat(failure).contains(gb + " GB"), id) }
        }
        for lang in Lang.all {
            stores.build.lang = lang
            let failure = BuildFailureClassifier.classify(try fixture("pso.low").text)
            XCTAssertTrue(stores.build.failureWhat(failure).contains("3"), lang.code)
            XCTAssertFalse(stores.build.failureWhat(failure).contains("%@"), lang.code)
            XCTAssertNotEqual(stores.build.t(failure.kind.nextKey), failure.kind.nextKey, lang.code)
        }
        XCTAssertEqual(BuildFailureClassifier.classify("[RED] pso_offline: metal-tt failed for applegpu_g18p (exit 1): compiler error").kind, .unknown)
        XCTAssertEqual(BuildFailureClassifier.classify("pso_offline: applegpu_g18p: batch 1/2: ready (compiled)").kind, .unknown)
    }

    func testTheInstallStepsThatFailedBecomeRows() {
        let taken = "error: Failed to register bundle identifier. The app identifier \"org.nxnative.x\" cannot be registered to your development team."
        XCTAssertEqual(BuildFailureClassifier.classifyInstall(.sign, error: taken, teamListed: true)?.kind, .teamTaken)
        XCTAssertEqual(BuildFailureClassifier.classifyInstall(.sign, error: "error: No profiles for 'org.nxnative.x' were found", teamListed: true)?.kind, .teamTaken)
        // The team's own variant has no profile for another reason (the retry under it ran already): not "registered to another team"
        XCTAssertNil(BuildFailureClassifier.classifyInstall(.sign, error: "error: No profiles for 'org.nxnative.shell.TEAM123456' were found", teamListed: true))
        XCTAssertFalse(BuildFailureClassifier.signingTeamTaken("error: No profiles for 'org.nxnative.shell.TEAM123456' were found"))
        XCTAssertTrue(BuildFailureClassifier.signingTeamTaken("error: No profiles for 'org.nxnative.shell' were found"))
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
        var keys = ["fail.showFolder", "fail.openXcode", "fail.retry", "fail.keys.button", "fail.driveMissing.whatNamed", "fail.diskFull.whatNeeds", "fail.cloudFolder.button", "engine.syncing"]
        let kinds = BuildFailureTests.stateKinds.union([.keys, .severalGames, .noTitleID, .diskFull, .cloudFolder])
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
            let mStores = LauncherStores(defaults: testDefaults); let m = mStores.build
            m.logTail = try fixture(id).text + "\n"
            m.noteFailure()
            XCTAssertEqual(m.failure?.kind, kind, id)
            XCTAssertEqual(m.doneNote, m.failureWhat(m.failure!), id)
        }
    }

    func testTheKeysButtonOpensTheKeysPicker() {
        let mStores = LauncherStores(defaults: testDefaults); let m = mStores.build
        var opened = 0
        m.chooseKeys = { opened += 1 }
        m.failure = BuildFailure(kind: .keys, gameName: nil)
        m.fixBuildFailure(.keys)
        XCTAssertEqual(opened, 1)
    }

    func testShowFolderRevealsTheGameFolderAndForAFullDiskTheBuildFolder() throws {
        let dir = try tempFolder()
        let mStores = LauncherStores(defaults: testDefaults); let m = mStores.build
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

    @MainActor func testAnInstallStepThatFailedShowsItsRow() {
        let mStores = LauncherStores(defaults: testDefaults); let m = mStores.build
        mStores.deviceStore.signingTeam = "TEAM123456"
        mStores.deviceStore.readTeams = { [SigningTeam(id: "TEAM123456", identity: "")] }
        m.noteInstallFailure(.sign, error: "error: Failed to register bundle identifier: cannot be registered to your development team")
        XCTAssertEqual(m.failure?.kind, .teamTaken)
        XCTAssertEqual(m.doneNote, m.t("fail.teamTaken.what"))
        mStores.deviceStore.readTeams = { [] }
        m.noteInstallFailure(.sign, error: "error: x")
        XCTAssertEqual(m.failure?.kind, .noSigningAccount)
        m.noteInstallFailure(.install, error: "ERROR: The device is not connected.")
        XCTAssertEqual(m.failure?.kind, .deviceTransfer)
        mStores.deviceStore.readTeams = { [SigningTeam(id: "TEAM123456", identity: "")] }
        m.failure = BuildFailure(kind: .teamTaken, gameName: nil)
        m.noteInstallFailure(.sign, error: "error: x")
        XCTAssertNil(m.failure, "an unknown signing error leaves the tool's line")
    }

    func testTryAgainStartsANewBuildAndClearsTheCard() {
        let mStores = LauncherStores(defaults: testDefaults); let m = mStores.build
        m.target = BuildTarget.mac   // the iPhone / iPad target stops first, at the device check
        m.failure = BuildFailure(kind: .deviceTransfer, gameName: nil)
        m.fixBuildFailure(.deviceTransfer)   // no repository here: the build stops at once, but it has started and dropped the old card
        XCTAssertNil(m.failure)
    }

    func testTheXcodeButtonOpensXcodeWhenItIsInstalled() {
        let mStores = LauncherStores(defaults: testDefaults); let m = mStores.build
        var opened: [URL] = []
        m.openApp = { opened.append($0) }
        m.failure = BuildFailure(kind: .teamTaken, gameName: nil)
        m.fixBuildFailure(.teamTaken)
        if let xcode = Toolchain.installedXcode() { XCTAssertEqual(opened, [URL(fileURLWithPath: xcode)]) } else { XCTAssertTrue(opened.isEmpty) }
    }

    @MainActor func testAppIDLimit9120AndLookalikes() throws {
        let real9120 = """
        /tmp/shell/project/DmShell.xcodeproj: error: Failed to register bundle identifier: The app identifier "org.nxnative.shell" cannot be registered to your development team because it is not available. (9120) (in target 'DmShell' from project 'DmShell')
        /tmp/shell/project/DmShell.xcodeproj: error: No profiles for 'org.nxnative.shell' were found: Xcode couldn't find any iOS App Development provisioning profiles matching 'org.nxnative.shell'. (in target 'DmShell' from project 'DmShell')
        """
        XCTAssertTrue(BuildFailureClassifier.appIDLimitReached(real9120))
        XCTAssertFalse(ShellInstall.retryUnderTeamVariant(real9120, attempted: "org.nxnative.shell", variant: "org.nxnative.shell.TEAM123"))
        XCTAssertEqual(BuildFailureClassifier.classify(real9120).kind, .appIDLimit)
        XCTAssertNil(BuildFailureClassifier.classify(real9120).detail)
        XCTAssertEqual(BuildFailureClassifier.classifyInstall(.sign, error: real9120, teamListed: true)?.kind, .appIDLimit)

        let portal9120WithReset = """
        Error Domain=DVTPortalServiceErrorDomain Code=9120 "Your maximum App ID limit has been reached. You may create up to 10 App IDs every 7 days. The oldest App ID expires on 2026-11-18."
        """
        let classifiedWithReset = BuildFailureClassifier.classify(portal9120WithReset)
        XCTAssertEqual(classifiedWithReset.kind, .appIDLimit)
        XCTAssertEqual(classifiedWithReset.detail, "2026-11-18")

        // Lookalike logs that must NOT be misclassified as Apple error 9120
        let lookalikes = [
            "[240/9120] Compiling App ID shader pipeline...",
            "Communication with Apple failed on port 9120: connection reset by peer",
            "error: clang frontend command failed with exit code 1 (pid 9120)",
            "error: Failed to register bundle identifier (91200)",
            "error: Failed to register bundle identifier: The app identifier \"org.nxnative.shell\" cannot be registered to your development team because it is not available.",
            "error: No profiles for 'org.nxnative.shell' were found",
            "ERROR: This device has reached the maximum number of installed apps using a free developer profile (code -36607).",
        ]
        for log in lookalikes {
            XCTAssertFalse(BuildFailureClassifier.appIDLimitReached(log), "false positive on lookalike: \(log)")
            XCTAssertNotEqual(BuildFailureClassifier.classify(log).kind, .appIDLimit, "false positive classify on: \(log)")
        }
        // Plain taken bundle ID without 9120 still classifies as .teamTaken and still retries team variant
        let plainTaken = lookalikes[4]
        XCTAssertTrue(ShellInstall.retryUnderTeamVariant(plainTaken, attempted: "org.nxnative.shell", variant: "org.nxnative.shell.TEAM123"))
        XCTAssertEqual(BuildFailureClassifier.classifyInstall(.sign, error: plainTaken, teamListed: true)?.kind, .teamTaken)

        // BuildStore recovers 9120 + reset date from logTail even when `error` only holds the trailing "No profiles" line
        let mStores = LauncherStores(defaults: testDefaults); let m = mStores.build
        mStores.deviceStore.signingTeam = "TEAM123456"
        mStores.deviceStore.readTeams = { [SigningTeam(id: "TEAM123456", identity: "Apple Development")] }
        m.logTail = portal9120WithReset + "\nerror: No profiles for 'org.nxnative.shell' were found\n"
        m.noteInstallFailure(.sign, error: "Signing failed: error: No profiles for 'org.nxnative.shell' were found")
        XCTAssertEqual(m.failure?.kind, .appIDLimit)
        XCTAssertEqual(m.failure?.detail, "2026-11-18")
        XCTAssertTrue(m.doneNote.contains("2026-11-18"), m.doneNote)

        // AppSignature.oldestFreeAppIDExpiry only reports when all 10 7-day App IDs for the team are cached locally
        let home = try tempFolder()
        let profDir = home.appendingPathComponent("Library/MobileDevice/Provisioning Profiles")
        try FileManager.default.createDirectory(at: profDir, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        for idx in 0..<10 {
            let created = now.addingTimeInterval(Double(-6 + idx % 5) * 86_400 + Double(idx) * 3600)
            let expires = created.addingTimeInterval(7 * 86_400)
            let plist: [String: Any] = [
                "TeamIdentifier": ["TEAM123456"],
                "CreationDate": created,
                "ExpirationDate": expires,
                "Entitlements": ["application-identifier": "TEAM123456.org.nxnative.game\(idx)"],
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            if idx < 9 {
                try data.write(to: profDir.appendingPathComponent("p\(idx).mobileprovision"))
            } else {
                XCTAssertNil(AppSignature.oldestFreeAppIDExpiry(forTeam: "TEAM123456", lang: .en, home: home.path, now: now))
                try data.write(to: profDir.appendingPathComponent("p\(idx).mobileprovision"))
            }
        }
        XCTAssertNotNil(AppSignature.oldestFreeAppIDExpiry(forTeam: "TEAM123456", lang: .en, home: home.path, now: now))

        // Every launcher language provides non-empty, semicolon-free, product-name-free strings for all three keys
        for lang in Lang.all {
            for key in ["fail.appIDLimit.what", "fail.appIDLimit.whatUntil", "fail.appIDLimit.next"] {
                let text = L10n.string(key, lang)
                XCTAssertNotEqual(text, key, "\(lang.code): missing \(key)")
                XCTAssertFalse(text.isEmpty, "\(lang.code): empty \(key)")
                XCTAssertFalse(text.contains(";") || text.contains("\u{FF1B}"), "\(lang.code): semicolon in \(key)")
                XCTAssertFalse(text.localizedCaseInsensitiveContains("NX2Apple"), "\(lang.code): mentions NX2Apple in \(key)")
                if key == "fail.appIDLimit.whatUntil" {
                    XCTAssertTrue(text.contains("%@"), "\(lang.code): missing placeholder in \(key)")
                }
            }
        }
    }
}
