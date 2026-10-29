import XCTest
import SwiftUI
@testable import NSPortBuilder

final class IPAPackagingTests: XCTestCase {
    private var temporary: URL!
    private var saved: [(String, Any?)] = []
    private let titleID = "0100535012974000"

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-ipa-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        saved = ["repoPath", "buildTarget", "buildOutputDirectory", "installDevice", "signingTeam", "bundleIPA"]
            .map { ($0, UserDefaults.standard.object(forKey: $0)) }
    }

    override func tearDownWithError() throws {
        for (key, value) in saved { UserDefaults.standard.set(value, forKey: key) }
        try FileManager.default.removeItem(at: temporary)
    }

    @MainActor func testSlimIsTheDefaultAndBundlingIsRemembered() {
        UserDefaults.standard.removeObject(forKey: "bundleIPA")
        let model = BuildModel()
        XCTAssertFalse(model.bundleIPA)
        model.bundleIPA = true
        XCTAssertTrue(BuildModel().bundleIPA)
        model.bundleIPA = false
        XCTAssertFalse(BuildModel().bundleIPA)
    }

    /// Synthetic scripts exercise the process contract without keys, game data, Xcode or signing.
    @MainActor private func export(bundled: Bool, exitCode: Int = 0, makeIPA: Bool = true) throws -> (BuildModel, [String: Any]) {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw XCTSkip("System Python is required for the process fixture")
        }
        let model = BuildModel()
        model.repoPath = temporary.path
        model.target = "ios"
        model.outDir = temporary.path
        model.pythonPath = "/usr/bin/python3"
        model.dotnetPath = "/usr/bin/true"
        model.installDevice = ""
        model.signingTeam = ""
        model.bundleIPA = bundled
        model.archivePath = "/previous-build/archive"
        model.ipaPath = "/previous-build/game.ipa"
        for tool in ["dm/tools/nx_extract/Program.cs"] + BuildModel.requiredTools {
            let url = temporary.appendingPathComponent(tool)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        let calls = temporary.appendingPathComponent("calls.json")
        try """
        import sys, os, json, pathlib
        pathlib.Path('\(calls.path)').write_text(json.dumps({
            'args': sys.argv[1:],
            'copy': os.environ.get('DM_COPY_ROMFS', ''),
            'full': os.environ.get('DM_FULL_ROMFS', '')
        }))
        work = pathlib.Path(sys.argv[sys.argv.index('--work-dir') + 1])
        (work / 'extract/v0/RomFS').mkdir(parents=True)
        (work / 'extract/v0/RomFS/fixture.txt').write_text('synthetic fixture')
        (work / 'aoc').mkdir()
        (work / 'aoc/1.img').write_text('synthetic DLC fixture')
        if \(makeIPA ? "True" : "False"):
            pathlib.Path(sys.argv[sys.argv.index('-o') + 1]).write_bytes(b'synthetic IPA fixture')
        sys.exit(\(exitCode))
        """.write(to: temporary.appendingPathComponent(BuildModel.buildScript), atomically: true, encoding: .utf8)
        try """
        import sys, pathlib
        pathlib.Path('\(temporary.path)/packer-called').touch()
        pathlib.Path(sys.argv[3]).write_bytes(b'synthetic image fixture')
        """.write(to: temporary.appendingPathComponent(BuildModel.romfsImageTool), atomically: true, encoding: .utf8)
        let base = temporary.appendingPathComponent("Test [\(titleID)].nsp")
        let keys = temporary.appendingPathComponent("prod.keys")
        try Data().write(to: base); try Data().write(to: keys)
        model.slots[0].paths = [base.path]; model.slots[3].paths = [keys.path]
        model.startBuild()
        model.bundleIPA = !bundled   // An in-flight build keeps the choice it started with.
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !model.running }, object: nil)
        wait(for: [settled], timeout: 15)
        let data = try Data(contentsOf: calls)
        return (model, try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]))
    }

    @MainActor func testBundledExportSkipsTheSeparateArchive() throws {
        let (model, calls) = try export(bundled: true)
        let args = try XCTUnwrap(calls["args"] as? [String])
        let mode = try XCTUnwrap(args.firstIndex(of: "--romfs"))
        XCTAssertEqual(args[mode + 1], "bundle")
        XCTAssertFalse(args.contains("--keep-extracted"))
        XCTAssertEqual(calls["copy"] as? String, "YES")
        XCTAssertEqual(calls["full"] as? String, "1")
        XCTAssertTrue(model.done)
        XCTAssertTrue(model.bundledIPA)
        XCTAssertEqual(model.doneNote, model.t("msg.bundledDone"))
        XCTAssertEqual(model.archivePath, "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.appendingPathComponent("packer-called").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.appendingPathComponent("games").path))
        XCTAssertFalse(model.stages.contains { $0.id == 1000 })
        try capture(model, name: "ipa-bundled")
    }

    @MainActor func testSeparateExportKeepsExtractionAndPacksDataWithDLC() throws {
        let (model, calls) = try export(bundled: false)
        let args = try XCTUnwrap(calls["args"] as? [String])
        let mode = try XCTUnwrap(args.firstIndex(of: "--romfs"))
        XCTAssertEqual(args[mode + 1], "separate")
        XCTAssertTrue(args.contains("--keep-extracted"))
        XCTAssertEqual(calls["copy"] as? String, "NO")
        XCTAssertEqual(calls["full"] as? String, "")
        XCTAssertTrue(model.done)
        XCTAssertFalse(model.bundledIPA)
        XCTAssertEqual(model.doneNote, model.t("msg.done"))
        XCTAssertEqual(model.archivePath, temporary.appendingPathComponent("games/" + titleID).path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.archivePath + "/romfs.img"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.archivePath + "/aoc/1.img"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: temporary.appendingPathComponent("packer-called").path))
        try capture(model, name: "ipa-separate")
    }

    @MainActor func testFailedBundledBuildDoesNotReportSuccessOrPackAnArchive() throws {
        let (model, _) = try export(bundled: true, exitCode: 1)
        XCTAssertFalse(model.done)
        XCTAssertNotEqual(model.doneNote, model.t("msg.bundledDone"))
        XCTAssertEqual(model.archivePath, "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.appendingPathComponent("packer-called").path))
    }

    @MainActor func testBundledBuildMustProduceAnIPA() throws {
        let (model, _) = try export(bundled: true, makeIPA: false)
        XCTAssertFalse(model.done)
        XCTAssertEqual(model.doneNote, model.t("msg.ipaMissing"))
    }

    @MainActor private func capture(_ model: BuildModel, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else { return }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        model.devicesChecked = true
        model.bundleIPA = model.bundledIPA
        let library = GameLibrary(file: temporary.appendingPathComponent("library.json"))
        for language in [Lang.en, .zh] {
            model.lang = language
            let host = NSHostingView(rootView: ContentView(model: model, library: library, initialPage: .builds, performStartupChecks: false))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 1900), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent(name + "-" + language.rawValue + ".png"))
            window.orderOut(nil)
        }
    }
}
