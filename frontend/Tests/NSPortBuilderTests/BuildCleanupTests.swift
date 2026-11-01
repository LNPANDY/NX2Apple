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

    private func plan(keep: Bool, ipa: Bool = false) -> BuildCleanup.Plan {
        BuildCleanup.Plan(work: build.path, keepFiles: keep,
                          protecting: [out.appendingPathComponent(titleID + ".app").path, out.appendingPathComponent(titleID + ".ipa").path,
                                       out.appendingPathComponent("games/" + titleID).path, out.appendingPathComponent("Hades [\(titleID)].nsp").path],
                          ipaWritten: ipa)
    }

    private var shellRoot: URL { temporary.appendingPathComponent("shell folder") }
    private var mirror: String { ShellInstall.mirroredFramework(root: shellRoot.path, titleID: titleID) }

    /// The game's framework as the installer's mirror leaves it: the binary and the manifest.
    private func writeMirror(binary: Bool = true) throws {
        try file("DmGame\(titleID).framework/game.manifest.json", in: shellRoot.appendingPathComponent("frameworks"))
        if binary { try file("DmGame\(titleID).framework/DmGame\(titleID)", in: shellRoot.appendingPathComponent("frameworks")) }
    }

    private func iPhonePlan(keep: Bool = false) -> BuildCleanup.Plan {
        var p = plan(keep: keep)
        p.requiredMirror = mirror
        return p
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

    func testIPhoneBuildFolderIsRemovedWhenTheMirrorIsComplete() throws {
        try fixture()
        try writeMirror()
        let outcome = BuildCleanup.run(iPhonePlan())
        XCTAssertNil(outcome.keptForMirror)
        XCTAssertNil(outcome.failure)
        for path in ["extract", "shader", "xcode", "aoc"] { XCTAssertFalse(exists(path), path) }
        assertOutputsStay()
        XCTAssertTrue(FileManager.default.fileExists(atPath: mirror + "/DmGame\(titleID)"), "the mirror is never touched")
    }

    func testIPhoneBuildFolderStaysWhenTheMirrorIsMissing() throws {
        try fixture()
        let outcome = BuildCleanup.run(iPhonePlan())
        XCTAssertEqual(outcome.keptForMirror, mirror)
        for path in ["extract/v0/RomFS.img", "shader/package.bin", "xcode/DmIOS.xcodeproj/project.pbxproj", "aoc/1.img"] { XCTAssertTrue(exists(path), path) }
        assertOutputsStay()
        let lines = BuildCleanup.logLines(outcome) { L10n.string($0, .en) }
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].hasPrefix("Kept the build folder") && lines[0].contains(mirror), lines[0])
    }

    func testIPhoneBuildFolderStaysWhenTheMirrorHasNoBinary() throws {
        try fixture()
        try writeMirror(binary: false)
        let outcome = BuildCleanup.run(iPhonePlan())
        XCTAssertEqual(outcome.keptForMirror, mirror)
        XCTAssertTrue(exists("extract/v0/RomFS.img"))
        XCTAssertTrue(BuildCleanup.mirrorComplete(mirror) == false)
    }

    func testTheMacAppNeedsNoMirror() throws {
        try fixture()
        let outcome = BuildCleanup.run(plan(keep: false))
        XCTAssertNil(outcome.keptForMirror)
        XCTAssertFalse(exists("extract"))
    }

    func testWithTheSettingOnTheMirrorIsNotAskedFor() throws {
        try fixture()
        let outcome = BuildCleanup.run(iPhonePlan(keep: true))
        XCTAssertNil(outcome.keptForMirror)
        XCTAssertTrue(exists("extract/v0/RomFS.img"))
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
        for key in ["settings.keepBuild", "settings.keepBuildNote", "section.buildFiles", "settings.keepBuildOff", "settings.keepBuildOn", "build.rebuildLong", "cleanup.removed", "cleanup.item", "cleanup.scratch", "cleanup.keptNoMirror", "msg.workdirHint"] {
            for lang in [Lang.zh, .en, .sv, .de, .fr] {
                let text = L10n.string(key, lang)
                XCTAssertNotEqual(text, key, "\(key) \(lang)")
                XCTAssertFalse(text.contains(";") || text.contains("；"), "\(key) \(lang)")
            }
        }
    }

    func testTheBuildPageHintNoLongerPromisesReuse() {
        let hint = [Lang.zh, .en, .sv, .de, .fr].map { L10n.string("msg.workdirHint", $0) }
        XCTAssertTrue(hint[1].contains("Keep build files"))
        XCTAssertTrue(hint[2].contains("Behåll byggfiler"))
        XCTAssertTrue(hint[0].contains("保留构建文件"))
        XCTAssertTrue(hint[3].contains("Build-Dateien behalten"))
        XCTAssertTrue(hint[4].contains("Conserver les fichiers de compilation"))
        for lang in [Lang.zh, .en, .sv, .de, .fr] {
            XCTAssertFalse(L10n.string("msg.workdirHint", lang).contains(";"), "\(lang)")
        }
    }

    /// The cleanup's protected paths come from `BuildFolder.protectedPaths`: the installed app and the archive folder with its romfs.img are in.
    @MainActor func testTheCleanupSharesTheProtectedPathListWithTheFreeSpaceSheet() {
        let model = BuildModel()
        model.effectiveWorkDir = build.path
        let oldOut = UserDefaults.standard.object(forKey: "buildOutputDirectory")
        defer { UserDefaults.standard.set(oldOut, forKey: "buildOutputDirectory") }
        model.slots[0].paths = [out.path + "/Game [\(titleID)][v0].nsp"]
        model.outDir = out.path
        model.macAppPath = out.path + "/Game.app"
        model.installedAppPath = out.path + "/Installed.app"
        model.armCleanup()
        let plan = model.cleanupPlan
        let shared = BuildFolder.protectedPaths(app: model.macAppPath, ipa: "", iosApp: model.installedAppPath,
                                                archive: out.path + "/games/" + titleID, output: out.path, titleID: titleID, inputs: [])
        for path in shared { XCTAssertTrue(plan?.protecting.map(BuildFolder.resolved).contains(path) ?? false, path) }
        XCTAssertTrue(shared.contains(BuildFolder.resolved(out.path + "/games/" + titleID + "/romfs.img")))
        XCTAssertTrue(shared.contains(BuildFolder.resolved(out.path + "/Installed.app")))
    }

    func testOnlyTheScratchFolderIsAlwaysRemovedWithoutAnIPA() {
        XCTAssertEqual(BuildCleanup.alwaysRemoved(ipaWritten: false), ["tmp"])
    }

    // MARK: The build's own flow

    /// A successful script arms the cleanup, a failed or stopped build never does, and a build that goes on (an install) is not cleaned up yet.
    @MainActor func testNothingIsRemovedForAFailedOrStoppedBuildAndTheCleanupWaitsForTheWholeBuild() throws {
        try fixture()
        let model = BuildModel()
        model.lang = .en
        model.effectiveWorkDir = build.path
        model.outDir = out.path
        let oldKeep = model.keepBuildFiles, oldTarget = model.target
        let oldOut = UserDefaults.standard.object(forKey: "buildOutputDirectory")
        defer { model.keepBuildFiles = oldKeep; model.target = oldTarget; UserDefaults.standard.set(oldOut, forKey: "buildOutputDirectory") }
        model.keepBuildFiles = false
        model.target = BuildTarget.mac

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

    /// An iPhone or iPad build is cleaned up only once the install has mirrored the game's framework into the shell folder.
    @MainActor func testTheIPhoneBuildFolderGoesOnlyAfterTheMirrorExists() throws {
        try fixture()
        let defaults = UserDefaults.standard
        let old = ["buildOutputDirectory", "shellRoot", OnboardingDefaults.platform].map { ($0, defaults.object(forKey: $0)) }
        defaults.removeObject(forKey: OnboardingDefaults.platform)   // a target change would otherwise re-check the tools
        defaults.set(shellRoot.path, forKey: "shellRoot")
        let model = BuildModel()
        let oldKeep = model.keepBuildFiles, oldTarget = model.target
        defer {
            model.keepBuildFiles = oldKeep; model.target = oldTarget
            for (key, value) in old { defaults.set(value, forKey: key) }
        }
        model.lang = .en
        model.keepBuildFiles = false
        model.target = BuildTarget.ios
        model.effectiveWorkDir = build.path
        model.outDir = out.path
        model.slots[0].paths = [out.path + "/Hades [\(titleID)][v0].nsp"]
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.6)) }

        // the build succeeded but the framework was not mirrored: the folder stays and the log says why
        model.armCleanup()
        XCTAssertEqual(model.cleanupPlan?.requiredMirror, mirror)
        model.done = true; model.running = true; model.running = false; settle()
        XCTAssertTrue(exists("extract/v0/RomFS.img"))
        XCTAssertTrue(model.logTail.contains("Kept the build folder"), model.logTail)
        XCTAssertFalse(model.logTail.contains("Cleaned up"), model.logTail)

        // mirrored: the folder goes
        try writeMirror()
        model.armCleanup()
        model.running = true; model.running = false; settle()
        XCTAssertFalse(exists("extract"))
        XCTAssertTrue(model.logTail.contains("Cleaned up the build folder"), model.logTail)
        assertOutputsStay()
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
