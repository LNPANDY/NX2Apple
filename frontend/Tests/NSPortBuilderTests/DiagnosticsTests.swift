import XCTest
@testable import NSPortBuilder

/// Issue #69: Copy diagnostics. Every input is a stand-in; nothing reads this Mac's checkout, tools or keys.
final class DiagnosticsTests: XCTestCase {
    private let home = "/Users/jo"

    private func inputs() -> Diagnostics.Inputs {
        var log = (1...80).map { "line \($0)" }
        log[70] = "header_key = 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        log[71] = "[keys]   key_area_key_application_00 =ABCDEF0123456789ABCDEF0123456789"
        log[72] = "main build ID: 3CA12DFB0123456789ABCDEF0123456789ABCDEF"
        return Diagnostics.Inputs(
            appVersion: "0.4.8", macOS: "Version 26.1 (Build 25B78)", chip: "Apple M3 Pro",
            repoPath: "/Users/jo/repos/NX2Apple", commit: "d66e4ddd CI: the legacy zip names are hyphenated", branch: "main",
            behind: [(ref: "upstream/main", count: 3), (ref: "origin/main", count: 0)],
            lastFetch: DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 10, day: 27, hour: 9, minute: 5).date,
            python: "/Users/jo/Library/Application Support/NS Port Builder/venv/bin/python3", pythonVersion: "3.13.1", pythonIsVenv: true,
            dotnet: "/Users/jo/.dotnet/dotnet", dotnetVersion: "10.0.100",
            deps: [.init(name: "Xcode and the iOS SDK", present: true, detail: ""),
                   .init(name: "spirv-cross", present: false, detail: "")],
            lastCommand: ["/Users/jo/Library/Application Support/NS Port Builder/venv/bin/python3", "scripts/build_ipa_from_nsp.py",
                          "--keys", "/Users/jo/Switch/prod.keys", "/Volumes/Games/Hades [0100535012974000].nsp"],
            log: log.joined(separator: "\n") + "\n\n", home: home)
    }

    func testTheReportHoldsTheAppTheMacTheCheckoutAndTheTools() {
        let report = Diagnostics.report(inputs())
        XCTAssertTrue(report.hasPrefix("### NX2Apple diagnostics\n"))
        for expected in [
            "- App: NX2Apple 0.4.8",
            "- macOS: Version 26.1 (Build 25B78)",
            "- Chip: Apple M3 Pro",
            "- Repository: ~/repos/NX2Apple",
            "- Commit: d66e4ddd CI: the legacy zip names are hyphenated (branch main), 3 behind upstream/main, 0 behind origin/main as of the last fetch, 2026-10-27 09:05",
            "- Python: ~/Library/Application Support/NS Port Builder/venv/bin/python3 (3.13.1, the launcher's venv)",
            "- .NET: ~/.dotnet/dotnet (10.0.100)",
            "- Dependencies: 1 missing",
            "  - ok Xcode and the iOS SDK",
            "  - MISSING spirv-cross",
            "'~/Library/Application Support/NS Port Builder/venv/bin/python3' scripts/build_ipa_from_nsp.py --keys ~/Switch/prod.keys '/Volumes/Games/Hades [0100535012974000].nsp'",
        ] {
            XCTAssertTrue(report.contains(expected + "\n"), expected)
        }
        XCTAssertFalse(report.contains(home + "/"), "no home path")
    }

    func testTheLogIsItsLast50LinesWithKeysRedacted() {
        let report = Diagnostics.report(inputs())
        XCTAssertTrue(report.contains("Last 50 log lines:"))
        XCTAssertFalse(report.contains("line 30\n"))
        XCTAssertTrue(report.contains("````text\nline 31\n"))
        XCTAssertTrue(report.contains("line 80\n````\n"))
        XCTAssertTrue(report.contains("header_key = [redacted]\n"))
        XCTAssertTrue(report.contains("key_area_key_application_00 =[redacted]\n"))
        XCTAssertFalse(report.contains("0123456789abcdef0123456789abcdef"))
        XCTAssertTrue(report.contains("main build ID: 3CA12DFB0123456789ABCDEF0123456789ABCDEF"), "a build ID is not a key")
    }

    func testTheTailKeepsTheLastLinesWithoutTrailingBlanks() {
        XCTAssertEqual(Diagnostics.tail("a\nb\nc\n\n  \n", lines: 2), ["b", "c"])
        XCTAssertEqual(Diagnostics.tail("a\nb", lines: 50), ["a", "b"])
        XCTAssertEqual(Diagnostics.tail(""), [])
        XCTAssertEqual(Diagnostics.tail((1...120).map(String.init).joined(separator: "\n")).count, 50)
    }

    func testRedactionTakesKeyLinesOnly() {
        XCTAssertEqual(Diagnostics.redact("titlekek_00 = 0x0123456789ABCDEF0123456789ABCDEF"), "titlekek_00 = [redacted]")
        XCTAssertEqual(Diagnostics.redact("  master_key_0a=00112233445566778899aabbccddeeff  "), "  master_key_0a=[redacted]  ")
        XCTAssertEqual(Diagnostics.redact("01007EF00011E000 = 0123456789abcdef0123456789abcdef"), "01007EF00011E000 = [redacted]", "a title key")
        XCTAssertEqual(Diagnostics.redact("DM_FPS_TARGET=60"), "DM_FPS_TARGET=60")
        XCTAssertEqual(Diagnostics.redact("[2/7] extract v720896: 30,000 files"), "[2/7] extract v720896: 30,000 files")
        XCTAssertEqual(Diagnostics.redact("commit 0123456789abcdef0123"), "commit 0123456789abcdef0123")
    }

    func testHomeBecomesATildeOnlyWhereItStartsAPath() {
        XCTAssertEqual(Diagnostics.shortenHome("/Users/jo/a and /Users/jo", home: home), "~/a and ~")
        XCTAssertEqual(Diagnostics.shortenHome("/Users/joanna/a", home: home), "/Users/joanna/a")
        XCTAssertEqual(Diagnostics.shortenHome("'/Users/jo/My Games/x'", home: home + "/"), "'~/My Games/x'")
        XCTAssertEqual(Diagnostics.shortenHome("/Users/jo.backup/x", home: home), "/Users/jo.backup/x")
    }

    func testAReportWithoutABuildOrACheckout() {
        var i = inputs()
        i.lastCommand = []; i.log = ""; i.commit = nil; i.repoPath = ""; i.depsChecked = false; i.dotnet = ""; i.dotnetVersion = nil
        let report = Diagnostics.report(i)
        XCTAssertTrue(report.contains("- Repository: not found\n"))
        XCTAssertFalse(report.contains("- Commit:"))
        XCTAssertTrue(report.contains("- .NET: not found\n"))
        XCTAssertTrue(report.contains("- Dependencies: not checked yet\n"))
        XCTAssertTrue(report.contains("No build in this session.\n"))
        XCTAssertFalse(report.contains("log lines"))
        i.repoPath = "/Users/jo/NX2Apple-main"
        XCTAssertTrue(Diagnostics.report(i).contains("- Commit: not a git checkout\n"), "a ZIP download")
    }

    func testADependencyIsDescribedInEnglish() {
        let python = BuildModel.Dep(id: "python", name: "dep.python", hint: "dep.python.hint", present: false,
                                    detail: "dep.python.old:3.9:3.12", installCmd: [])
        let row = Diagnostics.dependency(python)
        XCTAssertEqual(row.name, L10n.string("dep.python", .en))
        // One argument per ":"-separated part: the report names both versions ("3.9" and "3.12");
        // passing the remainder whole printed "3.9:3.12" for the first %@ and "(null)" for the second.
        XCTAssertEqual(row.detail, String(format: L10n.string("dep.python.old", .en), "3.9", "3.12"))
        XCTAssertFalse(row.detail.contains("(null)"))
        let zstd = BuildModel.Dep(id: "brew:zstd", name: "dep.zstd", hint: "dep.zstd.hint", present: true, detail: "/opt/homebrew/bin/zstd", installCmd: [])
        XCTAssertEqual(Diagnostics.dependency(zstd).detail, "/opt/homebrew/bin/zstd")
    }

    // ---- fork patches, Xcode and Metal, and the selected game's log ----

    private func fakeProbe(_ answers: [String: String]) -> Diagnostics.Probe {
        { args in answers[args.joined(separator: " ")] }
    }

    private let metal = "Apple metal version 32023.921 (metalfe-32023.921.6)"
    private let probes = [
        "/usr/bin/xcode-select -p": "/Applications/Xcode.app/Contents/Developer\n",
        "/usr/bin/xcodebuild -version": "Xcode 26.1\nBuild version 17B55\n",
        "/usr/bin/xcrun -sdk macosx metal --version": "Apple metal version 32023.921 (metalfe-32023.921.6)\nTarget: air64-apple-darwin25.1.0\nInstalledDir: /Users/jo/x",
        "/usr/bin/xcrun -sdk iphoneos metal --version": "Apple metal version 32023.800 (metalfe-32023.800.1)\nTarget: air64",
        "/usr/bin/xcrun --sdk iphoneos --show-sdk-version": "26.1\n",
    ]

    func testTheToolchainComesFromTheProbesAndKeepsOnlyTheCompilersFirstLine() {
        let t = Diagnostics.toolchain(pins: (metal, metal), run: fakeProbe(probes))
        XCTAssertEqual(t.xcodePath, "/Applications/Xcode.app/Contents/Developer")
        XCTAssertEqual(t.xcodeVersion, "Xcode 26.1, Build version 17B55")
        XCTAssertEqual(t.metalMac, metal)
        XCTAssertEqual(t.metalIOS, "Apple metal version 32023.800 (metalfe-32023.800.1)")
        XCTAssertEqual(t.iosSDK, "26.1")
        XCTAssertEqual(Diagnostics.toolchain(run: fakeProbe([:])), Diagnostics.Toolchain(), "nothing answers: nothing is invented")
    }

    func testTheReportNamesForkPatchesXcodeMetalAgainstThePinAndTheSDK() {
        var i = inputs()
        i.forkPatches = Diagnostics.patchList("runtime-profile\nromfsarc\n\n")
        i.toolchain = Diagnostics.toolchain(pins: (metal, metal), run: fakeProbe(probes))
        let report = Diagnostics.report(i)
        for expected in [
            "- Fork patches: runtime-profile, romfsarc",
            "- Xcode: /Applications/Xcode.app/Contents/Developer (Xcode 26.1, Build version 17B55)",
            "- Metal compiler (macOS): \(metal) (matches the pin)",
            "- Metal compiler (iOS): Apple metal version 32023.800 (metalfe-32023.800.1) (pin: \(metal))",
            "- iOS SDK: 26.1",
        ] { XCTAssertTrue(report.contains(expected + "\n"), expected) }
    }

    func testTheReportSaysWhatIsMissing() {
        let report = Diagnostics.report(inputs())   // nothing probed
        XCTAssertTrue(report.contains("- Fork patches: not found\n"))
        XCTAssertTrue(report.contains("- Xcode: not found\n"))
        XCTAssertTrue(report.contains("- Metal compiler (macOS): not installed\n"))
        XCTAssertTrue(report.contains("- iOS SDK: not installed\n"))
        var i = inputs()
        i.forkPatches = []
        XCTAssertTrue(Diagnostics.report(i).contains("- Fork patches: none\n"))
        XCTAssertFalse(report.contains("#### Selected game"), "no game selected")
    }

    func testThePinsAreReadFromTheChainLock() {
        let lock = "# Translation chain\ndmsh_xlate.dll\tdbc483247a4cb22d\nmetal_macosx\t\(metal)\nmetal_iphoneos\tApple metal version 1 (x)\n"
        XCTAssertEqual(Diagnostics.chainPins(lock).mac, metal)
        XCTAssertEqual(Diagnostics.chainPins(lock).ios, "Apple metal version 1 (x)")
        XCTAssertNil(Diagnostics.chainPins("dmsh_xlate.dll\tabc").mac)
    }

    func testTheSelectedGamesSectionHasItsBuiltPatchesAndARedactedLogTail() {
        var i = inputs()
        var lines = (1...300).map { "game line \($0)" }
        lines[299] = "title_key = 0123456789abcdef0123456789abcdef"
        i.game = Diagnostics.GameInfo(name: "Hades", titleID: "0100535012974000", builtForkPatches: "runtime-profile,romfsarc",
                                      logPath: "/Users/jo/Library/Logs/nxnative/0100535012974000.log", log: lines)
        let report = Diagnostics.report(i)
        XCTAssertTrue(report.contains("- Game: Hades (0100535012974000)\n"))
        XCTAssertTrue(report.contains("- Fork patches of the built app: runtime-profile, romfsarc\n"))
        XCTAssertTrue(report.contains("- Game log: ~/Library/Logs/nxnative/0100535012974000.log\n"))
        XCTAssertTrue(report.contains("Last 200 game log lines:"))
        XCTAssertTrue(report.contains("````text\ngame line 101\n"))
        XCTAssertFalse(report.contains("game line 100\n"))
        XCTAssertTrue(report.contains("title_key = [redacted]\n"))
        XCTAssertFalse(report.contains("0123456789abcdef0123456789abcdef"))
        i.game?.logPath = nil; i.game?.log = []; i.game?.builtForkPatches = nil
        let none = Diagnostics.report(i)
        XCTAssertTrue(none.contains("- Game log: none yet, the game was not run\n"))
        XCTAssertTrue(none.contains("- Fork patches of the built app: no Mac app built\n"))
    }

    func testNoNewReportTextHasASemicolonInAnUserFacingString() {
        for key in ["diag.note", "library.showLog", "library.showLog.none"] {
            for lang in [Lang.en, .zh] {
                let text = L10n.string(key, lang)
                XCTAssertFalse(text.contains(";") || text.contains("\u{FF1B}"), "\(key) \(lang)")
            }
        }
    }
}
