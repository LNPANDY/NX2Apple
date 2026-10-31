import SwiftUI
import XCTest
@testable import NSPortBuilder

/// The script's early stops, turned into hints. The fixture holds the real message of every pattern, copied from the script
/// (Tests/Fixtures/build_failures.json, shared with the Qt front end's test).
final class BuildFailureTests: XCTestCase {
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
        let kinds = Set(BuildFailureClassifier.table.map(\.kind))
        for k in BuildFailureKind.allCases where k != .unknown && !Self.stateKinds.contains(k) { XCTAssertTrue(kinds.contains(k), "\(k)") }
    }

    /// The rows that no log line sets: the launcher's own state (a drive, a team) or the step that failed (the install).
    static let stateKinds: Set<BuildFailureKind> = [.driveMissing, .teamTaken, .noSigningAccount, .deviceTransfer, .engineOffline, .engineSync]

    /// A bump of the pin or a patch that rewords a message must fail here, not turn a hint into the raw last line.
    func testTheEnginesScriptsStillSayWhatThePatternsExpect() throws {
        for f in try fixtures() {
            if f.source == "errno" {   // the system's own text, not the script's
                XCTAssertEqual(String(cString: strerror(ENOSPC)), f.fragment, f.id)
                continue
            }
            if f.source == "codesign" { continue }   // Apple's text, from a tool the script runs
            let source = try String(contentsOf: Self.engine.appendingPathComponent(f.source), encoding: .utf8)
            let there = source.contains(f.fragment)
            XCTAssertTrue(there, "\(f.id): \(f.source) no longer contains \"\(f.fragment)\": update the pattern and the fixture")
        }
    }

    func testTheFailureIsFoundAboveTheLastLine() {
        let log = "[3/9] extract\n[RED] the NSP is damaged: 2 files fail the NCA's hash check (x)\n---- last lines of /w/extract.log ----\n[RED] nx_extract exit code 3 (full output: /w/extract.log)\n"
        XCTAssertEqual(BuildFailureClassifier.classify(log).kind, .damagedNSP)
    }

    func testUnknownOutputKeepsTodaysBehaviour() {
        for log in ["", "something odd happened", "[RED] the RomFS image failed",
                    "[RED] the NSP is damaged: 3 files written as read (--allow-damaged)"] {   // the success note of a build that went on
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
        XCTAssertTrue(L10n.table["fail.otherMetal.next"]!.en.contains("Xcode 27.1 (macOS 26.6 or later)"))
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
        let m = BuildModel()
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
        let m = BuildModel()
        m.failure = BuildFailure(kind: .damagedNSP, gameName: nil)
        m.requestBuildAnyway()
        m.confirmBuildAnyway()   // starts a build: with no repository it stops at once, after taking the flag
        XCTAssertNil(m.armedOverride, "the build took it")
        XCTAssertNil(m.confirmingOverride)
        XCTAssertNil(m.takeOverrideFlag(), "the next build runs without it")
        XCTAssertNil(m.failure, "a new build clears the old stop")
    }

    func testAStopWithoutAnOverrideCannotBeBuiltAnyway() {
        let m = BuildModel()
        for k in BuildFailureKind.allCases where k.overrideFlag == nil {
            m.failure = BuildFailure(kind: k, gameName: nil)
            m.requestBuildAnyway()
            XCTAssertNil(m.confirmingOverride, "\(k)")
        }
    }

    func testAFailedBuildShowsTheHintInsteadOfTheLastLine() {
        let m = BuildModel()
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
        let dep = BuildModel.metalDep(runs: true, lock: Self.lock, now: ["macosx": Self.pinned, "iphoneos": Self.pinned], needsIOS: true)
        XCTAssertTrue(dep.present)
        XCTAssertFalse(dep.warning)
        XCTAssertTrue(dep.lastError.isEmpty)
    }

    func testANewerCompilerOfTheGenerationIsNoWarning() {   // Xcode 27.2's auto-update: the engine's gate builds with a note, so the row stays green
        XCTAssertTrue(MetalPin.mismatches(lock: Self.lock, now: ["macosx": Self.newer, "iphoneos": Self.newer], iOS: true).isEmpty)
        XCTAssertFalse(BuildModel.metalDep(runs: true, lock: Self.lock, now: ["macosx": Self.newer], needsIOS: true).warning)
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
        let dep = BuildModel.metalDep(runs: true, lock: Self.lock, now: ["macosx": Self.other, "iphoneos": nil], needsIOS: false)
        XCTAssertTrue(dep.present, "a warning never blocks")
        XCTAssertTrue(dep.warning)
        XCTAssertEqual(dep.fixHint, "dep.fix.metalPin")
        XCTAssertEqual(dep.lastError, "metal_macosx: " + Self.other)
        XCTAssertEqual(dep.detail, "dep.metal.other:" + Self.other + ":" + Self.pinned)
    }

    func testTheIPhoneCompilerCountsOnlyForAnIPhoneBuild() {
        let now: [String: String?] = ["macosx": Self.pinned, "iphoneos": Self.other]
        XCTAssertFalse(BuildModel.metalDep(runs: true, lock: Self.lock, now: now, needsIOS: false).warning)
        let ios = BuildModel.metalDep(runs: true, lock: Self.lock, now: now, needsIOS: true)
        XCTAssertTrue(ios.warning)
        XCTAssertTrue(ios.lastError.hasPrefix("metal_iphoneos:"))
    }

    func testAMissingCompilerKeepsTheInstallRow() {
        let dep = BuildModel.metalDep(runs: false, lock: Self.lock, now: ["macosx": nil, "iphoneos": nil], needsIOS: true)
        XCTAssertFalse(dep.present)
        XCTAssertFalse(dep.warning)
        XCTAssertEqual(dep.installCmd, BuildModel.metalToolchainCmd)
    }

    func testWithoutALockThereIsNothingToCompare() {
        XCTAssertFalse(BuildModel.metalDep(runs: true, lock: nil, now: ["macosx": Self.other], needsIOS: true).warning)
        XCTAssertTrue(MetalPin.mismatches(lock: "", now: ["macosx": Self.other], iOS: true).isEmpty)
    }

    func testTheMetalRowsDetailReadsInTheLauncher() {
        let m = BuildModel()
        let dep = BuildModel.metalDep(runs: true, lock: Self.lock, now: ["macosx": Self.other], needsIOS: false)
        XCTAssertTrue(m.depDetail(dep).contains(Self.other), m.depDetail(dep))
        XCTAssertTrue(m.depDetail(dep).contains(Self.pinned), m.depDetail(dep))
    }

    // ---- extended virtual addressing (issue 247): the build path, not a classifier row

    func testExtendedVirtualAddressingIsOptInOnTheBuildPath() {
        let alias: UInt64 = 0x118000000
        let paid = try! ExtendedVA.plan(ios: true, bcOnCPU: false, enabled: true, personalTeam: false,
                                         sizeText: "0x400000000", profileAlias: alias).get()
        XCTAssertEqual(paid.alias, 0x400000000)
        XCTAssertFalse(paid.usesProfileAlias)
        XCTAssertEqual(paid.envBody, "DM_ALIAS_SIZE=0x400000000\n")
        XCTAssertFalse(paid.envBody!.contains("DM_PROF_"))
        XCTAssertFalse(paid.envBody!.contains("APP_POOL"))
        let xml = try! XCTUnwrap(paid.entitlements)
        let increased = try! XCTUnwrap(xml.range(of: ExtendedVA.increasedMemory))
        let extended = try! XCTUnwrap(xml.range(of: ExtendedVA.entitlement))
        XCTAssertLessThan(increased.lowerBound, extended.lowerBound)
        var args = ["script", "in"]
        var env = ["PATH": "x"]
        ExtendedVA.apply(args: &args, environment: &env, plan: paid, envPath: "/tmp/e.txt", plistPath: "/tmp/p.plist")
        XCTAssertEqual(args, ["script", "in", "--env-file", "/tmp/e.txt"])
        XCTAssertEqual(env["DM_ENTITLEMENTS"], "/tmp/p.plist")

        let off = try! ExtendedVA.plan(ios: true, bcOnCPU: false, enabled: false, personalTeam: false,
                                        sizeText: "0x400000000", profileAlias: alias).get()
        XCTAssertNil(off.envBody)
        XCTAssertNil(off.entitlements)
        XCTAssertTrue(off.usesProfileAlias)
        XCTAssertEqual(off.alias, alias)
        var offArgs = ["script", "in"]
        var offEnv = ["PATH": "x"]
        ExtendedVA.apply(args: &offArgs, environment: &offEnv, plan: off, envPath: "/tmp/e.txt", plistPath: "/tmp/p.plist")
        XCTAssertEqual(offArgs, ["script", "in"])
        XCTAssertEqual(offEnv, ["PATH": "x"])

        let bc = try! ExtendedVA.plan(ios: true, bcOnCPU: true, enabled: false, personalTeam: false,
                                       sizeText: "0x400000000", profileAlias: alias).get()
        XCTAssertEqual(bc.envBody, "DM_TEX_BC_CPU=1\n")
        XCTAssertNil(bc.entitlements)
        let both = try! ExtendedVA.plan(ios: true, bcOnCPU: true, enabled: true, personalTeam: false,
                                         sizeText: "0x400000000", profileAlias: alias).get()
        XCTAssertEqual(both.envBody, "DM_TEX_BC_CPU=1\nDM_ALIAS_SIZE=0x400000000\n")
        XCTAssertFalse(both.envBody!.contains("APP_POOL"))

        let mac = try! ExtendedVA.plan(ios: false, bcOnCPU: true, enabled: true, personalTeam: false,
                                        sizeText: "0x400000000", profileAlias: alias).get()
        XCTAssertNil(mac.envBody)
        XCTAssertNil(mac.entitlements)
        XCTAssertTrue(mac.usesProfileAlias)

        let marked = LaunchSetting.memoryProfile(in: "mem_alias\t0x118000000\nextended_va\t0x300000000\n")
        XCTAssertEqual(marked.memAlias, alias)
        XCTAssertTrue(marked.extendedVA)
        XCTAssertEqual(marked.extendedSize, 0x300000000)
        XCTAssertEqual(ExtendedVA.choice(saved: nil, profile: marked), ExtendedVA.Choice(enabled: true, sizeText: "0x300000000"))
        let onFlag = LaunchSetting.memoryProfile(in: "extended_va\ton\nmem_alias\t0x10000000\n")
        XCTAssertTrue(onFlag.extendedVA)
        XCTAssertNil(onFlag.extendedSize)
        XCTAssertEqual(ExtendedVA.choice(saved: nil, profile: onFlag).sizeText, "0x400000000")
        for flag in ["off", "0", "no", "false"] {
            let row = LaunchSetting.memoryProfile(in: "mem_alias\t0x118000000\nextended_va\t\(flag)\n")
            XCTAssertFalse(row.extendedVA, flag)
            XCTAssertEqual(row.memAlias, alias)
        }
        XCTAssertFalse(LaunchSetting.memoryProfile(in: "mem_alias\t0x118000000\n").extendedVA)
        let savedOff = ExtendedVA.choice(saved: ExtendedVA.Saved(enabled: false, sizeText: "0x400000000"), profile: marked)
        XCTAssertFalse(savedOff.enabled)
        XCTAssertNil(ExtendedVA.Saved.decode(nil))
        XCTAssertNil(ExtendedVA.Saved.decode("maybe"))

        XCTAssertFalse(SigningTeam(id: "PERSONAL00", identity: "", personal: true).allowsExtendedVirtualAddressing)
        XCTAssertTrue(SigningTeam(id: "PAIDTEAM01", identity: "Apple Development: Name (PAIDTEAM01)").allowsExtendedVirtualAddressing)
        let blocked = try! ExtendedVA.plan(ios: true, bcOnCPU: true, enabled: true, personalTeam: true,
                                            sizeText: "0x400000000", profileAlias: alias).get()
        XCTAssertTrue(blocked.blockedForPersonalTeam)
        XCTAssertNil(blocked.entitlements)
        XCTAssertEqual(blocked.envBody, "DM_TEX_BC_CPU=1\n")
        XCTAssertEqual(blocked.alias, alias)
        XCTAssertFalse(blocked.envBody!.contains("DM_ALIAS_SIZE"))

        XCTAssertEqual(ExtendedVA.parseSize(""), .failure(.empty))
        XCTAssertEqual(ExtendedVA.parseSize("  "), .failure(.empty))
        XCTAssertEqual(ExtendedVA.parseSize("0x"), .failure(.empty))
        for bad in ["12g", "xyz", "nope", "0x12g"] { XCTAssertEqual(ExtendedVA.parseSize(bad), .failure(.nonHex), bad) }
        XCTAssertEqual(ExtendedVA.parseSize("0x10000001"), .failure(.unaligned))
        XCTAssertEqual(ExtendedVA.parseSize("0xFFFC000"), .failure(.belowMinimum))
        XCTAssertEqual(ExtendedVA.parseSize("0x1000004000"), .failure(.overSupported))
        XCTAssertEqual(try! ExtendedVA.parseSize("0x10000000").get(), 0x10000000)
        XCTAssertEqual(try! ExtendedVA.parseSize("0x1000000000").get(), 0x1000000000)
        XCTAssertEqual(try! ExtendedVA.parseSize("0x400000000").get(), 0x400000000)

        let resized = try! ExtendedVA.plan(ios: true, bcOnCPU: false, enabled: true, personalTeam: false,
                                            sizeText: "0x800000000", profileAlias: alias).get()
        XCTAssertEqual(resized.envBody, "DM_ALIAS_SIZE=0x800000000\n")
        XCTAssertFalse(resized.envBody!.contains("DM_PROF_"))
        XCTAssertFalse(resized.envBody!.contains("APP_POOL"))
        XCTAssertNotEqual(resized.alias, paid.alias)

        XCTAssertTrue(ExtendedVA.entitlementDropped(signature: ExtendedVA.increasedMemory, provision: nil))
        XCTAssertFalse(ExtendedVA.entitlementDropped(signature: xml, provision: nil))
        XCTAssertFalse(ExtendedVA.entitlementDropped(signature: xml, provision: xml))
        XCTAssertTrue(ExtendedVA.entitlementDropped(signature: xml, provision: ExtendedVA.increasedMemory))
        XCTAssertTrue(ExtendedVA.entitlementDropped(signature: xml, provision: ""))
        let dropped = "the signature dropped \(ExtendedVA.entitlement): the provisioning profile or the sideloading tool has to keep this entitlement"
        XCTAssertTrue(ExtendedVA.logReportsDroppedEntitlement(dropped))
        XCTAssertFalse(ExtendedVA.logReportsDroppedEntitlement("entitlements: \(ExtendedVA.increasedMemory) only"))
        let note = L10n.table["opt.eva.dropped"]?.en ?? ""
        XCTAssertTrue(note.contains(ExtendedVA.entitlement))
        XCTAssertTrue(note.contains("provisioning profile"))
        XCTAssertTrue(note.lowercased().contains("sideload"))
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
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: false)
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
                                  + [BuildFailureKind.keys, .severalGames, .noTitleID, .driveMissing, .diskFull, .teamTaken, .noSigningAccount, .deviceTransfer].flatMap { k in
                                      [("row-\(k.rawValue)", k, Lang.en), ("row-\(k.rawValue)-zh", k, Lang.zh)] } {
            let m = BuildModel()
            m.lang = CaptureLanguage.current(lang)
            m.failure = BuildFailure(kind: kind, gameName: nil, detail: kind == .diskFull ? "40" : kind == .driveMissing ? "Games" : nil)
            m.doneNote = m.failureWhat(m.failure!)
            try capture(name, width: 760, height: kind == .noTitleID ? 380 : 250, ZStack(alignment: .top) {
                LauncherPalette.background
                BuildFailureCard(m: m).padding(24)
            })
        }
        let m = BuildModel()
        m.lang = .en
        m.depsChecked = true
        m.deps = [BuildModel.Dep(id: "xcode", name: "dep.xcode", hint: "dep.xcode.hint", present: true, installCmd: []),
                  BuildModel.metalDep(runs: true, lock: Self.lock, now: ["macosx": Self.other, "iphoneos": Self.other], needsIOS: true)]
        try capture("deps-metal-warning", width: 760, height: 260, ZStack(alignment: .top) {
            LauncherPalette.background
            MetalRowPreview(m: m).padding(24)
        })
    }
}

/// The dependency panel's rows as the Settings card draws them, for the screenshot (the card itself is private to BuilderView).
private struct MetalRowPreview: View {
    @ObservedObject var m: BuildModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(m.deps, id: \.id) { d in
                HStack(alignment: .top, spacing: 12) {
                    Circle().fill(d.present && !d.warning ? LauncherPalette.ready : LauncherPalette.building).frame(width: 7, height: 7).padding(.top, 6)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(m.t(d.name)).font(.manrope(14, .semibold))
                        Text(m.depDetail(d)).font(.manrope(12.5)).foregroundStyle(.secondary)
                        if !d.lastError.isEmpty {
                            Text(d.lastError).font(.mono(11)).foregroundStyle(LauncherPalette.building)
                            Text(m.t(d.fixHint)).font(.manrope(11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                }.padding(.vertical, 10).padding(.horizontal, 18)
            }
        }
        .background(LauncherPalette.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
    }
}
