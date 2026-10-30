import XCTest
import SwiftUI
@testable import NSPortBuilder

/// When a build notification is posted and what it says (issue #64). Nothing here touches the notification center.
final class BuildNotificationsTests: XCTestCase {
    private func en(_ key: String) -> String { L10n.string(key, .en) }

    func testOnlyAFinishedOrFailedBuildInTheBackgroundIsNotified() {
        let failed = BuildNotice.Outcome.failed(reason: "Build failed (exit code 1)")
        XCTAssertTrue(BuildNotice.shouldNotify(.finished, enabled: true, appActive: false, hasBundleID: true))
        XCTAssertTrue(BuildNotice.shouldNotify(failed, enabled: true, appActive: false, hasBundleID: true))
        XCTAssertFalse(BuildNotice.shouldNotify(.finished, enabled: true, appActive: true, hasBundleID: true), "a build someone is watching")
        XCTAssertFalse(BuildNotice.shouldNotify(.stopped, enabled: true, appActive: false, hasBundleID: true), "Stop was pressed at the app")
        XCTAssertFalse(BuildNotice.shouldNotify(failed, enabled: false, appActive: false, hasBundleID: true), "switched off in Settings")
        XCTAssertFalse(BuildNotice.shouldNotify(.finished, enabled: true, appActive: false, hasBundleID: false), "swift run: no bundle, no notification center")
    }

    func testNotificationsAreOnUntilSwitchedOff() {
        let saved = UserDefaults.standard.object(forKey: BuildNotice.defaultsKey)
        defer { UserDefaults.standard.set(saved, forKey: BuildNotice.defaultsKey) }
        UserDefaults.standard.removeObject(forKey: BuildNotice.defaultsKey)
        XCTAssertTrue(BuildNotice.enabled)
        UserDefaults.standard.set(false, forKey: BuildNotice.defaultsKey)
        XCTAssertFalse(BuildNotice.enabled)
    }

    func testTheTextNamesTheGameAndTheTarget() {
        let mac = BuildNotice.text(.finished, game: "Metroid Dread", target: "mac-app", device: nil, en)
        XCTAssertEqual(mac.title, "Metroid Dread is built")
        XCTAssertEqual(mac.body, "For this Mac, in your library")
        XCTAssertEqual(BuildNotice.text(.finished, game: "Hades", target: "ios", device: nil, en).body, "For iPhone / iPad")
        XCTAssertEqual(BuildNotice.text(.finished, game: "Hades", target: "ios", device: "Jo’s iPhone", en).body, "Installed on Jo’s iPhone")
        let failed = BuildNotice.text(.failed(reason: "Extract · exit code 3"), game: "Hades", target: "ios", device: nil, en)
        XCTAssertEqual(failed.title, "Hades couldn’t be built")
        XCTAssertEqual(failed.body, "For iPhone / iPad\nExtract · exit code 3")
        let zh = BuildNotice.text(.failed(reason: ""), game: "Hades", target: "mac-app", device: nil) { L10n.string($0, .zh) }
        XCTAssertTrue(zh.title.contains("Hades") && !zh.title.contains("notify.") && !zh.body.contains("notify."), zh.title)
    }

    func testTheFailureReasonIsTheBuildsOwnLastWord() {
        var stage = Stage(id: 3, name: "Extract")
        stage.state = .failed
        stage.detail = "exit code 3"
        XCTAssertEqual(BuildNotice.failureReason(note: "", stages: [Stage(id: 1, name: "Survey", state: .done), stage]), "Extract · exit code 3")
        XCTAssertEqual(BuildNotice.failureReason(note: "Build failed: no Program NCA", stages: [stage]), "Build failed: no Program NCA")
        XCTAssertEqual(BuildNotice.failureReason(note: "", stages: []), "")
    }

    // MARK: Visual QA (matched by --filter testRenderLauncherForVisualQA)

    @MainActor func testRenderLauncherForVisualQANotificationSetting() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else { throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture native views") }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-notify-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let model = BuildModel()
        model.lang = CaptureLanguage.current(.en)
        model.depsChecked = true
        model.deps = [BuildModel.Dep(id: "test", name: "Xcode", hint: "", present: true, installCmd: [])]
        let library = GameLibrary(file: temporary.appendingPathComponent("preview.json"))
        let host = NSHostingView(rootView: ContentView(model: model, library: library, initialPage: .settings, performStartupChecks: false))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 1500), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("settings-notify.png"))
        window.orderOut(nil)
    }
}
