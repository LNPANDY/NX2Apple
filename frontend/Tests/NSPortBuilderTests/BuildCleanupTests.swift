import XCTest
import AppKit
import SwiftUI
@testable import NSPortBuilder

/// Cleaning up a game's build folder after a successful build: temporary folders only.
final class BuildCleanupTests: XCTestCase {
    private var temporary: URL!
    private let titleID = "01007EF00011E000"

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-cleanup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: temporary) }

    private var out: URL { temporary.appendingPathComponent("games folder") }
    private var build: URL { out.appendingPathComponent(titleID + "_build") }

    private func file(_ path: String, in dir: URL? = nil, kb: Int = 8) throws {
        let url = (dir ?? build).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: kb * 1024).write(to: url)
    }

    private func exists(_ path: String, in dir: URL? = nil) -> Bool {
        FileManager.default.fileExists(atPath: (dir ?? build).appendingPathComponent(path).path)
    }

    /// A finished build as the script leaves it, with the app, the IPA and the game data beside it.
    private func fixture() throws {
        for path in ["extract/v0/RomFS.img", "extract/v0/ExeFS/main", "exefs/x", "shader/package.bin", "shader/cache/b-0123456789ab/a.metallib",
                     "pso/mac/a.bin", "xcode/DmIOS.xcodeproj/project.pbxproj", "xcode-derived-data/Build/Products/Release-iphoneos/DmIOS.app/Info.plist",
                     "ipa/build/ios/pkg/Payload/DmIOS.app/x", "ipa/build/ios/pkg/out.ipa", "ipa/build/ios/pkg/out.ipa.idx", "ipa/build/ios/pkg/dd/a.o",
                     "tools/nx_extract/nx_extract", "tmp/x", "patched_v0/main.patched.bin", "aoc/1.img", "font/a.ttf",
                     "logs/split.log", "profile/\(titleID)/game.tsv", "run/save/save.bin", "nsp/game.nsp", "staging/Hades.nsp"] { try file(path) }
        try file(titleID + ".app/Contents/Info.plist", in: out)
        try file(titleID + ".ipa", in: out)
        try file("games/\(titleID)/romfs.img", in: out)
        try file("games/\(titleID)/aoc/1.img", in: out)
        try file("Hades [\(titleID)].nsp", in: out)
    }

    private func plan(keep: Bool, device: Bool = false, ipa: Bool = false) -> BuildCleanup.Plan {
        BuildCleanup.Plan(work: build.path, keepFiles: keep,
                          protecting: [out.appendingPathComponent(titleID + ".app").path, out.appendingPathComponent(titleID + ".ipa").path,
                                       out.appendingPathComponent("games/" + titleID).path, out.appendingPathComponent("Hades [\(titleID)].nsp").path],
                          deviceInstall: device, ipaWritten: ipa)
    }

    private func assertOutputsStay(file: StaticString = #filePath, line: UInt = #line) {
        for path in [titleID + ".app/Contents/Info.plist", titleID + ".ipa", "games/\(titleID)/romfs.img", "games/\(titleID)/aoc/1.img", "Hades [\(titleID)].nsp"] {
            XCTAssertTrue(exists(path, in: out), path, file: file, line: line)
        }
        for path in ["logs/split.log", "profile/\(titleID)/game.tsv", "run/save/save.bin", "nsp/game.nsp", "staging/Hades.nsp"] {
            XCTAssertTrue(exists(path), path, file: file, line: line)
        }
    }

    func testTheSettingIsOffByDefault() {
        let defaults = UserDefaults(suiteName: "nxnative-cleanup-" + UUID().uuidString)!
        XCTAssertFalse(BuildCleanup.keepBuildFiles(defaults))
        defaults.set(true, forKey: BuildCleanup.defaultsKey)
        XCTAssertTrue(BuildCleanup.keepBuildFiles(defaults))
    }

    func testWithTheSettingOffEveryPartGoesAndTheOutputsStay() throws {
        try fixture()
        let outcome = BuildCleanup.run(plan(keep: false, ipa: true))
        XCTAssertNil(outcome.failure)
        for path in ["extract", "exefs", "shader", "pso", "xcode", "xcode-derived-data", "ipa", "tools", "tmp", "patched_v0", "aoc", "font"] {
            XCTAssertFalse(exists(path), path)
        }
        assertOutputsStay()
        XCTAssertGreaterThan(outcome.freed, 0)
        XCTAssertEqual(Set(outcome.removed.compactMap(\.part)), [.extracted, .shaders, .xcode, .caches])
    }

    func testAnInstalledAppKeepsItsProjectAndDerivedDataForReinstallAndRenew() throws {
        try fixture()
        _ = BuildCleanup.run(plan(keep: false, device: true))
        XCTAssertTrue(exists("xcode/DmIOS.xcodeproj/project.pbxproj"))
        XCTAssertTrue(exists("xcode-derived-data/Build/Products/Release-iphoneos/DmIOS.app/Info.plist"))
        for path in ["extract", "shader", "pso", "ipa", "tmp", "aoc"] { XCTAssertFalse(exists(path), path) }
        assertOutputsStay()
    }

    func testTheGameDataImageAMacSideInstallReadsStays() throws {
        try fixture()
        var p = plan(keep: false)
        p.gameDataImage = build.appendingPathComponent("extract/v0/RomFS.img").path
        _ = BuildCleanup.run(p)
        XCTAssertTrue(exists("extract/v0/RomFS.img"))
        XCTAssertFalse(exists("extract/v0/ExeFS/main"))
        XCTAssertFalse(exists("shader"))
    }

    func testWithTheSettingOnOnlyWhatNothingNeedsGoes() throws {
        try fixture()
        let outcome = BuildCleanup.run(plan(keep: true, ipa: true))
        XCTAssertNil(outcome.failure)
        XCTAssertFalse(exists("tmp"))
        for path in ["ipa/build/ios/pkg/Payload", "ipa/build/ios/pkg/out.ipa", "ipa/build/ios/pkg/out.ipa.idx"] { XCTAssertFalse(exists(path), path) }
        for path in ["extract/v0/RomFS.img", "shader/package.bin", "pso/mac/a.bin", "xcode/DmIOS.xcodeproj/project.pbxproj", "ipa/build/ios/pkg/dd/a.o",
                     "tools/nx_extract/nx_extract", "patched_v0/main.patched.bin", "aoc/1.img"] { XCTAssertTrue(exists(path), path) }
        assertOutputsStay()
        XCTAssertEqual(outcome.removed.map(\.part), [nil])
    }

    func testThePackedIPACopyStaysWhenNoIPAWasWritten() throws {
        try fixture()
        _ = BuildCleanup.run(plan(keep: true, ipa: false))
        XCTAssertTrue(exists("ipa/build/ios/pkg/out.ipa"))
        XCTAssertFalse(exists("tmp"))
    }

    func testAFolderThatIsNotABuildFolderIsLeftAlone() throws {
        try file("extract/x", in: temporary)
        var p = plan(keep: false)
        p.work = temporary.path
        XCTAssertEqual(BuildCleanup.run(p), BuildCleanup.Outcome())
        XCTAssertTrue(exists("extract/x", in: temporary))
    }

    func testTheLogNamesWhatWasRemovedAndTheSpaceFreed() {
        let outcome = BuildCleanup.Outcome(removed: [.init(part: nil, bytes: 1_000_000), .init(part: .extracted, bytes: 14_000_000_000)], freed: 14_001_000_000)
        let lines = BuildCleanup.logLines(outcome) { L10n.string($0, .en) }
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("Extracted game files") && lines[0].contains("Temporary files") && lines[0].contains("Freed"), lines[0])
        XCTAssertTrue(BuildCleanup.logLines(BuildCleanup.Outcome()) { $0 }.isEmpty)
    }

    func testARebuildStartsFromScratchOnlyForAGameBuiltBeforeWithoutItsBuildFolder() throws {
        let outputs = [out.appendingPathComponent(titleID + ".app").path, out.appendingPathComponent("games/\(titleID)/romfs.img").path]
        XCTAssertFalse(BuildCleanup.rebuildsFromScratch(work: build.path, outputs: outputs), "a first build")
        try file("games/\(titleID)/romfs.img", in: out)
        XCTAssertTrue(BuildCleanup.rebuildsFromScratch(work: build.path, outputs: outputs))
        try file("logs/x.log")
        XCTAssertTrue(BuildCleanup.rebuildsFromScratch(work: build.path, outputs: outputs), "logs and the profile are not build files")
        try file("extract/v0/RomFS.img")
        XCTAssertFalse(BuildCleanup.rebuildsFromScratch(work: build.path, outputs: outputs))
    }

    func testTheNewStringsExistInEveryLanguageWithoutSemicolons() {
        for key in ["settings.keepBuild", "settings.keepBuildNote", "section.buildFiles", "settings.keepBuildOff", "settings.keepBuildOn", "build.rebuildLong", "cleanup.removed", "cleanup.item", "cleanup.scratch"] {
            for lang in [Lang.zh, .en, .sv] {
                let text = L10n.string(key, lang)
                XCTAssertNotEqual(text, key, "\(key) \(lang)")
                XCTAssertFalse(text.contains(";") || text.contains("；"), "\(key) \(lang)")
            }
        }
    }

    // MARK: The build's own flow

    /// A successful script arms the cleanup, a failed or stopped build never does, and a build that goes on (an install) is not cleaned up yet.
    @MainActor func testNothingIsRemovedForAFailedOrStoppedBuildAndTheCleanupWaitsForTheWholeBuild() throws {
        try fixture()
        let model = BuildModel()
        model.lang = .en
        model.effectiveWorkDir = build.path
        model.outDir = out.path
        let oldKeep = model.keepBuildFiles
        let oldOut = UserDefaults.standard.object(forKey: "buildOutputDirectory")
        defer { model.keepBuildFiles = oldKeep; UserDefaults.standard.set(oldOut, forKey: "buildOutputDirectory") }
        model.keepBuildFiles = false

        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.6)) }
        // failed: the script exited with an error, nothing armed
        model.running = true; model.running = false; settle()
        XCTAssertTrue(exists("extract/v0/RomFS.img"))
        // armed, then the build failed (a failed install): done stays false
        model.armCleanup(); model.running = true; model.running = false; settle()
        XCTAssertNil(model.cleanupPlan)
        XCTAssertTrue(exists("extract/v0/RomFS.img"))
        // armed and stopped
        model.armCleanup(); model.running = true; model.stopping = true; model.done = true; model.running = false; settle()
        XCTAssertTrue(exists("extract/v0/RomFS.img"))
        model.stopping = false
        // armed, the next step starts at once: still running, nothing removed
        model.armCleanup(); model.done = true; model.running = false; model.running = true; settle()
        XCTAssertTrue(exists("extract/v0/RomFS.img"))
        XCTAssertNotNil(model.cleanupPlan)
        // the whole build succeeded
        model.running = false; settle()
        XCTAssertFalse(exists("extract"))
        XCTAssertFalse(model.cleaningUp)
        XCTAssertTrue(model.logTail.contains("Cleaned up the build folder"), model.logTail)
        assertOutputsStay()
    }

    func testTheResignDoesNotReadTheBuildFoldersGameFilesAgain() {
        let command = BuildModel.resignCommand(xcrun: "/x", project: "/w/xcode/DmIOS.xcodeproj", scheme: "S", device: "U", derived: "/w/d", team: "T", bundle: "b")
        XCTAssertTrue(command.contains("DM_COPY_GAME_RESOURCES=NO"))
    }

    // MARK: Visual QA

    @MainActor func testRenderBuildCleanupForVisualQA() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else { throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture native views") }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        let model = BuildModel()
        let oldRepo = UserDefaults.standard.object(forKey: "repoPath")
        let oldOutput = UserDefaults.standard.object(forKey: "buildOutputDirectory")
        let oldKeep = model.keepBuildFiles
        defer {
            UserDefaults.standard.set(oldRepo, forKey: "repoPath"); UserDefaults.standard.set(oldOutput, forKey: "buildOutputDirectory")
            model.keepBuildFiles = oldKeep
        }
        model.repoPath = repo
        model.lang = .en
        model.outDir = out.path
        model.depsChecked = true
        model.deps = [BuildModel.Dep(id: "test", name: "Xcode", hint: "", present: true, installCmd: [])]
        let nsp = out.appendingPathComponent("The Legend of Zelda Breath of the Wild [\(titleID)][v0].nsp")
        let keys = out.appendingPathComponent("prod.keys")
        try file("games/\(titleID)/romfs.img", in: out)
        for f in [nsp, keys] { try Data([0]).write(to: f) }
        model.slots[0].paths = [nsp.path]; model.slots[3].paths = [keys.path]
        let library = GameLibrary(file: temporary.appendingPathComponent("preview.json"))
        func shot(_ name: String, _ page: LauncherPage, height: CGFloat) throws {
            let host = NSHostingView(rootView: ContentView(model: model, library: library, initialPage: page, performStartupChecks: false))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: height), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
            window.orderOut(nil)
        }
        model.keepBuildFiles = false
        try shot("settings-keep-off", .settings, height: 900)
        model.keepBuildFiles = true
        try shot("settings-keep-on", .settings, height: 900)
        try shot("build-rebuild-note", .builds, height: 1900)   // built before, no build folder
        try file("extract/v0/RomFS.img")
        try shot("build-no-note", .builds, height: 1900)        // the build folder is there
    }
}
