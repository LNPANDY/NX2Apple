import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
import NXModel
@testable import NXLauncher

/// The script's early stops, turned into hints. The fixture holds the real message of every pattern, copied from the script
/// (Tests/Fixtures/build_failures.json, shared with the Qt front end's test).
@MainActor final class BuildFailureTests: IsolatedDefaultsTestCase {
    struct Fixture: Decodable {
        let id: String, kind: String, source: String, fragment: String, text: String
        let game: String?, folder: String?, gb: String?
    }

    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()   // the repository root
    /// The engine's files (scripts/, dm/): `engine/` after `python3 tools/engine.py sync` (the repository commits none, #214).
    static let engine = root.appendingPathComponent("engine")

    func fixtures() throws -> [Fixture] {
        let url = Self.root.appendingPathComponent("frontend/Tests/Fixtures/build_failures.json")
        return try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
    }

    func testEveryPatternHasItsRealMessageAndMatchesIt() throws {
        let fx = try fixtures()
        for row in BuildFailureClassifier.table {
            let f = try XCTUnwrap(fx.first { $0.id == row.id }, "no fixture for pattern \(row.id)")
            XCTAssertEqual(f.kind, row.kind.rawValue, row.id)
            XCTAssertNotNil(f.text.range(of: row.pattern, options: .regularExpression), "\(row.id) no longer matches its message")
            XCTAssertEqual(BuildFailureClassifier.classify(f.text).kind, row.kind, row.id)
        }
        XCTAssertEqual(Set(fx.map(\.id)), Set(BuildFailureClassifier.table.map(\.id)), "a fixture without a pattern")
    }

    func testEveryKindIsReachable() {
        let kinds = Set((BuildFailureClassifier.table + BuildFailureClassifier.extraTable).map(\.kind))
        for k in BuildFailureKind.allCases where k != .unknown && !Self.stateKinds.contains(k) { XCTAssertTrue(kinds.contains(k), "\(k)") }
    }

    /// The rows that no log line sets: the launcher's own state (a drive, a team) or the step that failed (the install).
    static let stateKinds: Set<BuildFailureKind> = [.driveMissing, .teamTaken, .noSigningAccount, .deviceTransfer, .devicePairing, .shellDataIncomplete, .engineOffline, .engineSync]

    /// A bump of the pin or a patch that rewords a message must fail here, not turn a hint into the raw last line.
    func testTheEnginesScriptsStillSayWhatThePatternsExpect() throws {
        for f in try fixtures() {
            if f.source == "errno" {   // the system's own text, not the script's
                XCTAssertEqual(String(cString: strerror(ENOSPC)), f.fragment, f.id)
                continue
            }
            if f.source == "errno45" {   // the system's text for ENOTSUP, which renamex_np answers on a volume without RENAME_SWAP (pack_app.py replace_app)
                XCTAssertEqual(String(cString: strerror(ENOTSUP)), f.fragment, f.id)
                continue
            }
            if f.source == "codesign" { continue }   // Apple's text, from a tool the script runs
            let source = try String(contentsOf: Self.engine.appendingPathComponent(f.source), encoding: .utf8)
            let there = source.contains(f.fragment)
            XCTAssertTrue(there, "\(f.id): \(f.source) no longer contains \"\(f.fragment)\": update the pattern and the fixture")
        }
    }

    /// #553: a profile kept from an earlier build that lacks the selected update stops the build and names the folder it kept.
    func testAStaleProvisionalProfileIsItsOwnStopWithItsFolder() throws {
        let f = try XCTUnwrap(fixtures().first { $0.id == "profile.stale" })
        let failure = BuildFailureClassifier.classify(f.text)
        XCTAssertEqual(failure.kind, .staleProfile)
        XCTAssertEqual(failure.detail, f.folder)
        XCTAssertNil(failure.kind.overrideFlag, "there is no way to build around it")
    }

    func testTheOlderSeveralGamesMessageStillClassifies() {   // the stable and experimental engine channels can still serve the text before the pin of cd859c38
        let log = "[RED] more than one game in the folder, keep one game per folder: 0100000000010000, 01006F8002326000"
        XCTAssertEqual(BuildFailureClassifier.classify(log).kind, .severalGames)
    }

    func testOnlyTheEnginesSelectableBaseTitleIDsAreOffered() throws {
        let line = try XCTUnwrap(fixtures().first { $0.id == "games.several" }).text
        let filename = "Game [0100000000003000].xci"
        let contents = "\(filename) holds several titles: DLC 0100000000011001 v0, update 0100000000010800 v1"
        XCTAssertEqual(BuildFailureClassifier.classify(contents + "\n" + line).titleIDs,
                       ["0100000000010000", "01006F8002326000"])
        for malformed in [line.replacingOccurrences(of: "01006F8002326000", with: "123"),
                          line.replacingOccurrences(of: "01006F8002326000", with: "0100000000010000"),
                          "Running: " + line, contents,
                          "[RED] more than one game in the folder, keep one game per folder: 0100000000010000, 01006F8002326000"] {
            XCTAssertTrue(BuildFailureClassifier.classify(malformed).titleIDs.isEmpty, malformed)
        }
    }

    func testTheFailureIsFoundAboveTheLastLine() {
        let log = "[3/9] extract\n[RED] the NSP is damaged: 2 files fail the NCA's hash check (x)\n---- last lines of /w/extract.log ----\n[RED] nx_extract exit code 3 (full output: /w/extract.log)\n"
        XCTAssertEqual(BuildFailureClassifier.classify(log).kind, .damagedNSP)
    }

    func testUnknownOutputKeepsTodaysBehaviour() {
        for log in ["", "something odd happened", "[RED] the RomFS image failed",
                    "[RED] the NSP is damaged: 3 files written as read (--allow-damaged)",
                    "[RED] v131072: 3 file(s) whose bytes do not start as their names promise (a .zs file that is not a zstd stream), so the game files are damaged:\n  Tex/a.bntx.zs (216,015 bytes, starts 00000000)\npacked as they are (--allow-damaged)"] {   // the success note of a build that went on
            XCTAssertEqual(BuildFailureClassifier.classify(log), BuildFailure(kind: .unknown, gameName: nil), log)
        }
    }

    func testTheGameOfA32BitProgramIsNamedWhenTheMessageNamesIt() throws {
        let f = try XCTUnwrap(fixtures().first { $0.id == "arm32.program" })
        XCTAssertEqual(BuildFailureClassifier.classify(f.text).gameName, f.game)
        XCTAssertNil(BuildFailureClassifier.classify("[RED] ? (0100ABCD00000000) is a 32-bit ARM program (main.npdm)").gameName)
        XCTAssertNil(BuildFailureClassifier.classify("[RED] the shader translator does not run (x)").gameName)
    }

    // ---- hints

    func testOnlyThreeStopsOfferBuildAnyway() {
        let flags = Dictionary(uniqueKeysWithValues: BuildFailureKind.allCases.compactMap { k in k.overrideFlag.map { (k, $0) } })
        XCTAssertEqual(flags, [.otherMetal: "--allow-other-metal", .shaderRegression: "--allow-shader-regressions", .damagedNSP: "--allow-damaged"])
    }

    func testEveryHintIsInBothLanguagesWithoutSemicolons() {
        var keys = ["fail.section", "fail.buildAnyway", "fail.confirm.title", "fail.confirm.go", "fail.confirm.cancel", "fail.override.note",
                    "fail.a32Program.whatNamed", "fail.translator.button", "fail.iosSDK.button", "fail.cltSelected.button",
                    "macFail.metalToolchain.button", "macFail.metalToolchain.copy", "macFail.updateMismatch.button", "macFail.updateMismatch.whatVersions",
                    "dep.metal.other", "dep.fix.metalPin", "fail.showFolder", "fail.openXcode", "fail.retry", "fail.keys.button",
                    "fail.driveMissing.whatNamed", "fail.diskFull.whatNeeds"]
        for k in BuildFailureKind.allCases where k != .unknown {
            keys += [k.whatKey, k.nextKey]
            if k.overrideFlag != nil { keys.append("fail.\(k.rawValue).risk") }
        }
        for key in keys {
            let row = L10n.table[key]
            XCTAssertNotNil(row, key)
            for text in [row?.zh ?? "", row?.en ?? ""] {
                XCTAssertFalse(text.isEmpty, key)
                XCTAssertFalse(text.contains(";") || text.contains("\u{FF1B}"), "\(key) has a semicolon")
            }
            XCTAssertNotEqual(row?.zh, row?.en, "\(key) has the English text twice")
        }
    }

    func testTheRiskTextStatesTheRiskAndThatItIsOneBuild() {
        for k in [BuildFailureKind.otherMetal, .shaderRegression, .damagedNSP] {
            let en = L10n.table["fail.\(k.rawValue).risk"]?.en ?? ""
            XCTAssertTrue(en.contains("untested"), "\(k)")
            XCTAssertTrue(en.contains("one build"), "\(k)")
        }
    }

    func testTheOtherMetalHintNamesXcode27() {
        XCTAssertTrue(L10n.table["fail.otherMetal.next"]!.en.contains("Xcode 27.2 (macOS 26.6 or later)"))
        XCTAssertTrue(L10n.table["fail.a32Program.what"]!.en.contains("32-bit and can't run on Apple silicon"))
    }

    // ---- the flag of "Build anyway"

    func testTheBuildArgumentsGetExactlyOneAllowFlag() {
        let base = ["/r/scripts/build_ipa_from_nsp.py", "/in", "-k", "/k", "--progress", "json"]
        XCTAssertEqual(BuildFailureClassifier.arguments(base, adding: nil), base)
        for k in [BuildFailureKind.otherMetal, .shaderRegression, .damagedNSP] {
            let args = BuildFailureClassifier.arguments(base, adding: k.overrideFlag)
            XCTAssertEqual(args.filter { $0.hasPrefix("--allow-") }, [k.overrideFlag!])
            XCTAssertEqual(Array(args.dropLast()), base)
        }
        XCTAssertEqual(BuildFailureClassifier.arguments(base + ["--allow-damaged"], adding: "--allow-other-metal").filter { $0.hasPrefix("--allow-") }, ["--allow-other-metal"])
        XCTAssertEqual(BuildFailureClassifier.arguments(base, adding: "--platform").count, base.count, "not an override")
    }

    func testNothingIsArmedUntilTheConfirmation() {
        let mStores = LauncherStores(defaults: testDefaults); let m = mStores.build
        m.failure = BuildFailure(kind: .otherMetal, gameName: nil)
        m.requestBuildAnyway()
        XCTAssertEqual(m.confirmingOverride, .otherMetal)
        XCTAssertNil(m.armedOverride)
        XCTAssertNil(m.takeOverrideFlag())
        m.cancelBuildAnyway()
        XCTAssertNil(m.confirmingOverride)
        XCTAssertNil(m.armedOverride)
    }

    func testAConfirmedOverrideServesOneBuildOnly() {
        let mStores = LauncherStores(defaults: testDefaults); let m = mStores.build
        m.target = BuildTarget.mac   // the iPhone / iPad target stops first, at the device check
        m.failure = BuildFailure(kind: .damagedNSP, gameName: nil)
        m.requestBuildAnyway()
        m.confirmBuildAnyway()   // starts a build: with no repository it stops at once, after taking the flag
        XCTAssertNil(m.armedOverride, "the build took it")
        XCTAssertNil(m.confirmingOverride)
        XCTAssertNil(m.takeOverrideFlag(), "the next build runs without it")
        XCTAssertNil(m.failure, "a new build clears the old stop")
    }

    func testAStopWithoutAnOverrideCannotBeBuiltAnyway() {
        let mStores = LauncherStores(defaults: testDefaults); let m = mStores.build
        for k in BuildFailureKind.allCases where k.overrideFlag == nil {
            m.failure = BuildFailure(kind: k, gameName: nil)
            m.requestBuildAnyway()
            XCTAssertNil(m.confirmingOverride, "\(k)")
        }
    }

    func testAFailedBuildShowsTheHintInsteadOfTheLastLine() {
        let mStores = LauncherStores(defaults: testDefaults); let m = mStores.build
        m.logTail = "[RED] the iOS SDK is not installed: install the iOS platform in Xcode\n"
        m.noteFailure()
        XCTAssertEqual(m.failure?.kind, .iosSDK)
        XCTAssertEqual(m.doneNote, m.t(BuildFailureKind.iosSDK.whatKey))
        m.logTail = "[RED] something else\n"; m.doneNote = "last line"
        m.noteFailure()
        XCTAssertNil(m.failure)
        XCTAssertEqual(m.doneNote, "last line", "unknown output keeps the note")
    }

    // ---- the Metal compiler row

    static let lock = "# fingerprints\ndmsh_xlate.dll\tdbc483247a4cb22d\nmetal_macosx\tApple metal version 32023.921 (metalfe-32023.921.6)\nmetal_iphoneos\tApple metal version 32023.921 (metalfe-32023.921.6)\n"
    static let pinned = "Apple metal version 32023.921 (metalfe-32023.921.6)"
    static let other = "Apple metal version 32023.883 (metalfe-32023.883.5)"
    static let newer = "Apple metal version 32023.922 (metalfe-32023.922.4)"
    static let foreign = "Apple metal version 32024.100 (metalfe-32024.100.1)"

    func testThePinIsReadFromTheLock() {
        XCTAssertEqual(MetalPin.pins(lock: Self.lock)["metal_macosx"], Self.pinned)
        XCTAssertEqual(MetalPin.pins(lock: Self.lock)["metal_iphoneos"], Self.pinned)
        XCTAssertNil(MetalPin.pins(lock: Self.lock)["# fingerprints"])
    }

    func testTheRepositorysOwnLockHasTheTwoPins() throws {
        let lock = try String(contentsOf: Self.engine.appendingPathComponent(MetalPin.lockPath), encoding: .utf8)
        XCTAssertNotNil(MetalPin.pins(lock: lock)["metal_macosx"])
        XCTAssertNotNil(MetalPin.pins(lock: lock)["metal_iphoneos"])
    }

    func testTheTestedCompilerIsNoWarning() {
        let dep = DependencyCheck.metalDep(runs: true, lock: Self.lock, now: ["macosx": Self.pinned, "iphoneos": Self.pinned], needsIOS: true)
        XCTAssertTrue(dep.present)
        XCTAssertFalse(dep.warning)
        XCTAssertTrue(dep.lastError.isEmpty)
    }

    func testANewerCompilerOfTheGenerationIsNoWarning() {   // Xcode 27.2's auto-update: the engine's gate builds with a note, so the row stays green
        XCTAssertTrue(MetalPin.mismatches(lock: Self.lock, now: ["macosx": Self.newer, "iphoneos": Self.newer], iOS: true).isEmpty)
        XCTAssertFalse(DependencyCheck.metalDep(runs: true, lock: Self.lock, now: ["macosx": Self.newer], needsIOS: true).warning)
    }

    func testAnOlderOrForeignGenerationStaysAWarning() {
        for found in [Self.other, Self.foreign, "Apple metal 32023.922"] {
            let m = MetalPin.mismatches(lock: Self.lock, now: ["macosx": found], iOS: false)
            XCTAssertEqual(m.map(\.sdk), ["macosx"], found)
        }
        let v = MetalPin.version(Self.pinned)
        XCTAssertEqual(v?.0, 32023); XCTAssertEqual(v?.1, 921); XCTAssertEqual(v?.2, 6)
        XCTAssertNil(MetalPin.version("Apple metal 32023.922"))
        XCTAssertFalse(MetalPin.buildsOn(tested: Self.pinned, found: Self.other))
        XCTAssertTrue(MetalPin.buildsOn(tested: Self.pinned, found: Self.newer))
        XCTAssertFalse(MetalPin.buildsOn(tested: Self.pinned, found: Self.foreign))
    }

    func testAnotherCompilerIsAWarningAndNotABlocker() {
        let dep = DependencyCheck.metalDep(runs: true, lock: Self.lock, now: ["macosx": Self.other, "iphoneos": nil], needsIOS: false)
        XCTAssertTrue(dep.present, "a warning never blocks")
        XCTAssertTrue(dep.warning)
        XCTAssertEqual(dep.fixHint, "dep.fix.metalPin")
        XCTAssertEqual(dep.lastError, "metal_macosx: " + Self.other)
        XCTAssertEqual(dep.detail, "dep.metal.other:" + Self.other + ":" + Self.pinned)
    }

    func testTheIPhoneCompilerCountsOnlyForAnIPhoneBuild() {
        let now: [String: String?] = ["macosx": Self.pinned, "iphoneos": Self.other]
        XCTAssertFalse(DependencyCheck.metalDep(runs: true, lock: Self.lock, now: now, needsIOS: false).warning)
        let ios = DependencyCheck.metalDep(runs: true, lock: Self.lock, now: now, needsIOS: true)
        XCTAssertTrue(ios.warning)
        XCTAssertTrue(ios.lastError.hasPrefix("metal_iphoneos:"))
    }

    func testAMissingCompilerKeepsTheInstallRow() {
        let dep = DependencyCheck.metalDep(runs: false, lock: Self.lock, now: ["macosx": nil, "iphoneos": nil], needsIOS: true)
        XCTAssertFalse(dep.present)
        XCTAssertFalse(dep.warning)
        XCTAssertEqual(dep.installCmd, Toolchain.metalToolchainCmd)
    }

    func testWithoutALockThereIsNothingToCompare() {
        XCTAssertFalse(DependencyCheck.metalDep(runs: true, lock: nil, now: ["macosx": Self.other], needsIOS: true).warning)
        XCTAssertTrue(MetalPin.mismatches(lock: "", now: ["macosx": Self.other], iOS: true).isEmpty)
    }

    @MainActor func testTheMetalRowsDetailReadsInTheLauncher() {
        let mStores = LauncherStores(defaults: testDefaults); let m = mStores.build
        let dep = DependencyCheck.metalDep(runs: true, lock: Self.lock, now: ["macosx": Self.other], needsIOS: false)
        XCTAssertTrue(mStores.dependencies.detail(of: dep).contains(Self.other), mStores.dependencies.detail(of: dep))
        XCTAssertTrue(mStores.dependencies.detail(of: dep).contains(Self.pinned), mStores.dependencies.detail(of: dep))
    }

    /// Opt-in native rendering for pull request screenshots (NX_LAUNCHER_CAPTURE_DIR), the way LibraryTests renders the launcher.
    @MainActor func testRenderBuildFailureStatesForScreenshots() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else { throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture native views") }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        func capture(_ name: String, width: CGFloat, height: CGFloat, _ view: some View) throws {
            let host = NSHostingView(rootView: view.preferredColorScheme(.dark).frame(width: width, height: height))
            let window = OffscreenWindow(size: NSSize(width: width, height: height))
            window.contentView = host
            window.appearance = NSAppearance(named: .darkAqua)
            window.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
            window.orderOut(nil)
        }
        for (name, kind, lang) in [("hint-other-metal", BuildFailureKind.otherMetal, Lang.en), ("hint-ios-sdk", .iosSDK, .en), ("hint-damaged-nsp", .damagedNSP, .en),
                                   ("hint-other-metal-zh", .otherMetal, .zh)]
                                  + [BuildFailureKind.keys, .keysOld, .severalGames, .noTitleID, .driveMissing, .diskFull, .volumeFormat, .teamTaken, .noSigningAccount, .deviceTransfer].flatMap { k in
                                      [("row-\(k.rawValue)", k, Lang.en), ("row-\(k.rawValue)-zh", k, Lang.zh)] } {
            let mStores = LauncherStores(defaults: testDefaults); let m = mStores.build
            m.lang = CaptureLanguage.current(lang)
            m.failure = BuildFailure(kind: kind, gameName: nil, detail: kind == .diskFull ? "40" : kind == .driveMissing ? "Games" : nil)
            m.doneNote = m.failureWhat(m.failure!)
            try capture(name, width: 760, height: kind == .noTitleID ? 380 : 250, ZStack(alignment: .top) {
                LauncherPalette.background
                BuildFailureCard(m: m).environmentObject(mStores.localizer).padding(24)
            })
        }
        let multiGame = try XCTUnwrap(fixtures().first { $0.id == "games.several" })
        let files = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: files) }
        let cartridge = files.appendingPathComponent("Collection.xci"), keys = files.appendingPathComponent("test.keys")
        try Data().write(to: cartridge)
        try Data().write(to: keys)
        for lang in Lang.all {
            let stores = LauncherStores(defaults: testDefaults)
            stores.repo.path = Self.engine.path
            stores.dependencies.checked = true
            stores.dependencies.deps = [Dep(id: "test", name: "test", hint: "", present: true, installCmd: [])]
            stores.build.take(picked: [cartridge.path], kind: .base)
            stores.build.take(picked: [keys.path], kind: .keys)
            stores.build.lang = lang
            stores.build.logTail = multiGame.text
            stores.build.noteFailure()
            try capture("multi-game-\(lang.code)", width: 760, height: 250, ZStack(alignment: .top) {
                LauncherPalette.background
                BuildFailureCard(m: stores.build).environmentObject(stores.localizer).padding(24)
            })
        }
        // Replay the real low-space stop through the classifier, including the raw-note fallback before a hint exists.
        for lang in Lang.all {
            let stores = LauncherStores(defaults: testDefaults)
            let build = stores.build
            build.lang = lang
            build.doneNote = try XCTUnwrap(fixtures().first { $0.id == "pso.low" }).text
            build.logTail = build.doneNote
            build.noteFailure()
            try capture("pso-low-\(lang.code)", width: 760, height: 360, ZStack(alignment: .top) {
                LauncherPalette.background
                VStack(alignment: .leading, spacing: 20) {
                    ActionCard(build: build, dependencies: stores.dependencies, repo: stores.repo)
                    BuildFailureCard(m: build)
                }.environmentObject(stores.localizer).padding(24)
            })
        }
        let mStores = LauncherStores(defaults: testDefaults); let m = mStores.build
        m.lang = .en
        MainActor.assumeIsolated { mStores.dependencies.checked = true }
        MainActor.assumeIsolated { mStores.dependencies.deps = [Dep(id: "xcode", name: "dep.xcode", hint: "dep.xcode.hint", present: true, installCmd: []),
                  DependencyCheck.metalDep(runs: true, lock: Self.lock, now: ["macosx": Self.other, "iphoneos": Self.other], needsIOS: true)] }
        try capture("deps-metal-warning", width: 760, height: 260, ZStack(alignment: .top) {
            LauncherPalette.background
            MetalRowPreview(dependencies: mStores.dependencies, t: m.t).padding(24)
        })
    }

    /// Opt-in native rendering for Apple error 9120 screenshots across all 10 languages (NX_LAUNCHER_CAPTURE_DIR).
    @MainActor func testRenderAppIDLimitForVisualQA() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else { throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture native views") }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        func capture(_ name: String, width: CGFloat, height: CGFloat, _ view: some View) throws {
            let host = NSHostingView(rootView: view.preferredColorScheme(.dark).frame(width: width, height: height))
            let window = OffscreenWindow(size: NSSize(width: width, height: height))
            window.contentView = host
            window.appearance = NSAppearance(named: .darkAqua)
            window.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
            window.orderOut(nil)
        }
        let log9120 = """
        /tmp/shell/project/DmShell.xcodeproj: error: Failed to register bundle identifier: The app identifier "org.nxnative.shell" cannot be registered to your development team because it is not available. (9120) (in target 'DmShell' from project 'DmShell')
        /tmp/shell/project/DmShell.xcodeproj: error: No profiles for 'org.nxnative.shell' were found: Xcode couldn't find any iOS App Development provisioning profiles matching 'org.nxnative.shell'. (in target 'DmShell' from project 'DmShell')
        """
        let errLine = "error: Failed to register bundle identifier: The app identifier \"org.nxnative.shell\" cannot be registered to your development team because it is not available. (9120)"
        for lang in Lang.all {
            let stores = LauncherStores(defaults: testDefaults)
            let build = stores.build
            stores.localizer.lang = lang
            build.lang = lang
            stores.deviceStore.signingTeam = "TEAM123456"
            stores.deviceStore.readTeams = { [SigningTeam(id: "TEAM123456", identity: "Apple Development")] }
            build.logTail = log9120
            build.finishInstall(String(format: build.t("dev.signFailed"), errLine))
            build.noteInstallFailure(.sign, error: build.doneNote)
            try capture("mac-9120-\(lang.code)", width: 780, height: 420, ZStack(alignment: .top) {
                LauncherPalette.background
                VStack(alignment: .leading, spacing: 20) {
                    ActionCard(build: build, dependencies: stores.dependencies, repo: stores.repo)
                    BuildFailureCard(m: build)
                }.environmentObject(stores.localizer).padding(24)
            })
        }
    }
}

/// The dependency panel's rows as the Settings card draws them, for the screenshot (the card itself is ToolsCard in NXLauncher).
private struct MetalRowPreview: View {
    @ObservedObject var dependencies: DependencyStore
    let t: (String) -> String
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(dependencies.deps, id: \.id) { d in
                HStack(alignment: .top, spacing: 12) {
                    Circle().fill(d.present && !d.warning ? LauncherPalette.ready : LauncherPalette.building).frame(width: 7, height: 7).padding(.top, 6)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(t(d.name)).font(.manrope(14, .semibold))
                        Text(dependencies.detail(of: d)).font(.manrope(12.5)).foregroundStyle(.secondary)
                        if !d.lastError.isEmpty {
                            Text(d.lastError).font(.mono(11)).foregroundStyle(LauncherPalette.building)
                            Text(t(d.fixHint)).font(.manrope(11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                }.padding(.vertical, 10).padding(.horizontal, 18)
            }
        }
        .background(LauncherPalette.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
    }
}
