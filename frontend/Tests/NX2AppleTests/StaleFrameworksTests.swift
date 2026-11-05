import XCTest
import SwiftUI
@testable import NX2Apple
@testable import NXCore
import NXModel

/// LNPANDY/NX2Apple#449: a shell folder with one framework of the current chain and one of the old chain.
@MainActor final class StaleFrameworksTests: IsolatedDefaultsTestCase {
    private let current = "b-b7cd656abd7c"
    private let old = "b-e65a4ebd3322"
    private let oldID = "0100A00019DE0000"
    private let newID = "0100B00000000000"
    private var tmp = ""

    override func setUpWithError() throws {
        tmp = NSTemporaryDirectory() + "stale-frameworks-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmp + "/engine/dm/gfx/nvn", withIntermediateDirectories: true)
        try "// Generated file\n#define DMSH_CHAIN \"b7cd656abd7c\"\n".write(toFile: tmp + "/engine/dm/gfx/nvn/dmsh_chain.h", atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: tmp) }

    private func framework(_ titleID: String, name: String, chain: String, loader: String = "FH") throws -> String {
        let fw = tmp + "/shell/frameworks/DmGame\(titleID).framework"
        try FileManager.default.createDirectory(atPath: fw, withIntermediateDirectories: true)
        let manifest = ["title_id": titleID, "name": name, "chain": chain, "loader": loader, "framework": "DmGame\(titleID).framework"]
        try JSONSerialization.data(withJSONObject: manifest).write(to: URL(fileURLWithPath: fw + "/game.manifest.json"))
        try "binary".write(toFile: fw + "/DmGame\(titleID)", atomically: true, encoding: .utf8)
        return fw
    }

    private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    private func shell() throws -> (stale: String, fresh: String) {
        let stale = try framework(oldID, name: "Old Game", chain: old, loader: "FR")
        let fresh = try framework(newID, name: "Fresh Game", chain: current, loader: "FH")
        var library = ShellLibrary()
        library.add(ShellLibrary.Game(titleID: oldID, name: "Old Game", framework: stale))
        library.add(ShellLibrary.Game(titleID: newID, name: "Fresh Game", framework: fresh))
        try library.save(root: tmp + "/shell")
        return (stale, fresh)
    }

    private func found(except: String? = nil) -> [StaleFrameworks.Entry] {
        let known = ShellLibrary.load(root: tmp + "/shell").games.map { (titleID: $0.titleID, name: $0.name, framework: $0.framework) }
        return StaleFrameworks.find(root: tmp + "/shell", chain: current, known: known, except: except)
    }

    func testTheEnginesChainIsTheHeadersWithBPrefix() {
        XCTAssertEqual(StaleFrameworks.currentChain(engineRoot: tmp + "/engine"), current)
        XCTAssertNil(StaleFrameworks.currentChain(engineRoot: tmp + "/nowhere"))
    }

    func testOnlyTheFrameworkOfAnotherChainIsStaleAndItIsNamedByTheLibrary() throws {
        _ = try shell()
        let entries = found()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.titleID, oldID)
        XCTAssertEqual(entries.first?.name, "Old Game")
        XCTAssertEqual(entries.first?.chain, old)
    }

    func testNothingIsAskedWhenEveryFrameworkCarriesItsOwnHostEvenAcrossChains() throws {
        _ = try framework(oldID, name: "Old Chain Game", chain: old, loader: "FH")
        _ = try framework(newID, name: "Fresh Game", chain: current, loader: "FH")
        XCTAssertEqual(found(), [])
        XCTAssertEqual(StaleFrameworks.find(root: tmp + "/empty", chain: current, known: []), [])
    }

    func testTheGameBeingBuiltIsNotAskedAboutBecauseTheBuildReplacesIt() throws {
        _ = try shell()
        XCTAssertEqual(found(except: oldID.lowercased()), [])
    }

    func testAFrameworkWithoutAReadableManifestIsLeftToTheScriptsOwnCheck() throws {
        let fw = try framework(oldID, name: "Old Game", chain: old)
        try "not json".write(toFile: fw + "/game.manifest.json", atomically: true, encoding: .utf8)
        XCTAssertEqual(found(), [])
    }

    func testStopLeavesEveryFileAsItWas() throws {
        let (stale, fresh) = try shell()
        let before = try Data(contentsOf: URL(fileURLWithPath: ShellLibrary.stateFile(root: tmp + "/shell")))
        let modelStores = LauncherStores(defaults: testDefaults); let model = modelStores.build
        model.staleFrameworks = found()
        XCTAssertFalse(model.staleFrameworks.isEmpty)
        model.stopForStaleFrameworks()
        XCTAssertTrue(model.staleFrameworks.isEmpty)
        XCTAssertTrue(exists(stale))
        XCTAssertTrue(exists(fresh))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: ShellLibrary.stateFile(root: tmp + "/shell"))), before)
    }

    func testContinueRemovesTheStaleFrameworkAndKeepsTheCurrentOne() throws {
        let (stale, fresh) = try shell()
        let failed = BuildStore.removeStaleFrameworks(found(), root: tmp + "/shell")
        XCTAssertEqual(failed, [])
        XCTAssertFalse(exists(stale))
        XCTAssertTrue(exists(fresh))
        XCTAssertEqual(ShellLibrary.load(root: tmp + "/shell").games.map(\.titleID), [newID])
        XCTAssertEqual(found(), [], "the shared app now holds only games of the current chain")
    }

    /// v1.0.2-rc1: deleting a framework's shader files in place took a minute, and a launcher quit in that minute left half of it
    /// where shell.json pointed. Now the folder is renamed away in one step and its files go in the background.
    func testContinueTakesTheFrameworkAwayInOneStepAndLeavesNoHalfFramework() throws {
        let (stale, fresh) = try shell()
        for i in 0..<300 { try "shader".write(toFile: stale + "/msl-\(i).metallib", atomically: false, encoding: .utf8) }
        XCTAssertEqual(BuildStore.removeStaleFrameworks(found(), root: tmp + "/shell"), [])
        XCTAssertFalse(exists(stale))
        XCTAssertTrue(exists(fresh))
        let left = try FileManager.default.contentsOfDirectory(atPath: tmp + "/shell/frameworks")
        XCTAssertTrue(left.allSatisfy { $0 == "DmGame\(newID).framework" || $0.hasPrefix(ShellInstall.discardPrefix) }, "\(left)")
        XCTAssertFalse(left.contains { $0.hasPrefix(ShellInstall.discardPrefix) && $0.hasSuffix(".framework") })
        XCTAssertEqual(found(), [])
    }

    func testWhatACutOffDeleteLeftIsSweptAndNeverTakenForAFramework() throws {
        _ = try framework(newID, name: "Fresh Game", chain: current)
        let leftover = tmp + "/shell/frameworks/" + ShellInstall.discardPrefix + "cut-off"
        try FileManager.default.createDirectory(atPath: leftover + "/msl", withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["title_id": oldID, "chain": old]).write(to: URL(fileURLWithPath: leftover + "/game.manifest.json"))
        XCTAssertEqual(found(), [])
        ShellInstall.sweepDiscarded(in: tmp + "/shell/frameworks")
        let deadline = Date().addingTimeInterval(10)
        while exists(leftover), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertFalse(exists(leftover))
        XCTAssertTrue(exists(tmp + "/shell/frameworks/DmGame\(newID).framework"))
    }

    func testContinueStartsTheBuildAndTheModelEndsWithoutAPrompt() throws {
        _ = try shell()
        let modelStores = LauncherStores(defaults: testDefaults); let model = modelStores.build
        model.staleFrameworks = found()
        var started = false
        testDefaults.set(tmp + "/shell", forKey: "shellRoot")
        model.continueWithStaleFrameworks { started = true }
        XCTAssertTrue(started)
        XCTAssertTrue(model.staleFrameworks.isEmpty)
        XCTAssertEqual(found(), [])
    }

    func testAllFiveLanguagesHaveTheTextsAndNoneUsesASemicolon() {
        for lang in Lang.all {
            for key in ["stale.title", "stale.message", "stale.go", "stale.stop", "stale.removeFailed"] {
                let text = L10n.string(key, lang)
                XCTAssertNotEqual(text, key, "\(key) in \(lang)")
                XCTAssertFalse(text.contains(";") || text.contains("；") || text.contains("—"), "\(key) in \(lang)")
            }
            XCTAssertTrue(L10n.string("stale.message", lang).contains("%@"))
        }
        XCTAssertNotEqual(L10n.string("stale.go", .zh), L10n.string("stale.go", .en))
    }

    // MARK: Visual QA (matched by --filter testRenderStalePromptForVisualQA)

    /// The prompt's title, message and two buttons laid out like the system alert, for the pull request's screenshots.
    @MainActor func testRenderStalePromptForVisualQA() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else { throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture native views") }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let lang = ProcessInfo.processInfo.environment["NX_CAPTURE_LANG"].flatMap { Lang.find($0) } ?? .en
        let entries = [StaleFrameworks.Entry(titleID: oldID, name: "Super Mario Odyssey", chain: old, paths: []),
                       StaleFrameworks.Entry(titleID: newID, name: "Hades", chain: old, paths: [])]
        let alert = VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 36)).foregroundStyle(.yellow)
            Text(L10n.string("stale.title", lang)).font(.headline)
            Text(String(format: L10n.string("stale.message", lang), StaleFrameworks.list(entries)))
                .font(.callout).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Text(L10n.string("stale.stop", lang)).frame(maxWidth: .infinity).padding(.vertical, 6)
                    .background(Color.gray.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                Text(L10n.string("stale.go", lang)).frame(maxWidth: .infinity).padding(.vertical, 6)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(20).frame(width: 340).background(Color(white: 0.16)).environment(\.colorScheme, .dark)
        NSApplication.shared.setActivationPolicy(.accessory)
        let host = NSHostingView(rootView: alert)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = OffscreenWindow(size: host.frame.size)
        window.contentView = host
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("stale-frameworks-\(lang.code).png"))
        window.orderOut(nil)
    }
}
