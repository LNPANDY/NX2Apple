import AppKit
import CoreText
import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXModel
@testable import NXLauncher

@MainActor final class MacTransferAndQueueUXTests: IsolatedDefaultsTestCase {
    private var temporary: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporary = fm.temporaryDirectory.appendingPathComponent("nx-mac-ux-\(UUID().uuidString)")
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporary { try? fm.removeItem(at: temporary) }
        try super.tearDownWithError()
    }

    private final class NoopRunningProcess: RunningProcess {
        var processIdentifier: Int32 { 0 }
        var isRunning: Bool { false }
    }

    private final class ImmediateSuccessRunner: ProcessRunner, @unchecked Sendable {
        func capture(_ launch: ProcessLaunch) -> ProcessResult { ProcessResult(status: 0, out: "") }
        func stream(_ launch: ProcessLaunch, line: @escaping (String) -> Void) -> Bool { true }
        func streamLines(_ launch: ProcessLaunch, started: @escaping (RunningProcess) -> Void, line: @escaping (String) -> Void) -> ProcessResult {
            ProcessResult(status: 0, out: "")
        }
        func start(_ launch: ProcessLaunch, onOutput: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) throws -> RunningProcess {
            if let outIdx = launch.arguments.firstIndex(of: "-o"), outIdx + 1 < launch.arguments.count {
                let appPath = launch.arguments[outIdx + 1]
                try? FileManager.default.createDirectory(atPath: appPath + "/Contents/MacOS", withIntermediateDirectories: true)
            }
            DispatchQueue.global(qos: .userInitiated).async { onExit(0) }
            return NoopRunningProcess()
        }
    }

    private func makeMacApp(titleID: String, name: String) throws -> String {
        let app = temporary.appendingPathComponent(name + ".app")
        let exeDir = app.appendingPathComponent("Contents/MacOS")
        try fm.createDirectory(at: exeDir, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: exeDir.appendingPathComponent("nxnative"), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        try fm.createSymbolicLink(at: exeDir.appendingPathComponent("dmhost"), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        let info: [String: Any] = [
            "DMTitleID": titleID,
            "CFBundleDisplayName": name,
            "CFBundleExecutable": "nxnative",
            "CFBundleIdentifier": "org.example.test." + titleID.lowercased(),
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app.path
    }

    // MARK: 2.1 Unstarted TOTK draft does not leak into or return after batch fast refresh

    func testBatchRefreshIsolatesPriorUnstartedDraftAndShowsCleanFinishedQueueSummary() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let stores = LauncherStores(runner: ImmediateSuccessRunner(), xcrun: "/usr/bin/true", defaults: testDefaults)
        let repo = temporary.appendingPathComponent("repo")
        let marker = repo.appendingPathComponent(EngineLayout.marker)
        try fm.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: marker)
        let buildScript = URL(fileURLWithPath: EngineLayout.root(repo.path)).appendingPathComponent("scripts/build_ipa_from_nsp.py")
        try fm.createDirectory(at: buildScript.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("parser.add_argument(\"--from-seed\")\n".utf8).write(to: buildScript)
        stores.repo.path = repo.path
        stores.build.cloudFolderCheck = { _ in false }
        stores.build.spaceAvailable = { _ in 100_000_000_000 }
        stores.dependencies.checked = true
        stores.dependencies.deps = [Dep(id: "xcode", name: "dep.xcode", hint: "", present: true, installCmd: [])]

        // 1. User configured TOTK as an unstarted single-game build draft AND left a stale waiting queue draft
        let totkNsp = temporary.appendingPathComponent("Tears of the Kingdom [0100F2C0115B6000].nsp")
        try Data("nsp".utf8).write(to: totkNsp)
        var totk = LibraryGame(titleID: "0100F2C0115B6000", name: "Tears of the Kingdom")
        totk.inputs = ["base": [totkNsp.path]]
        totk.sourceFolder = temporary.path

        var mk8 = LibraryGame(titleID: "0100152000022000", name: "Mario Kart 8 Deluxe")
        mk8.appPath = try makeMacApp(titleID: "0100152000022000", name: "Mario Kart 8 Deluxe")
        mk8.outputDirectory = temporary.path

        let library = GameLibrary(file: temporary.appendingPathComponent("library.json"))
        library.upsert(totk)
        library.upsert(mk8)

        // Simulate prior configureBuild(totk) without starting
        stores.build.updateSlot("base") { $0.paths = [totkNsp.path] }
        stores.build.gameDir = temporary.path
        stores.build.applyKnownTitleID(totk.titleID)
        // Plus a stale unstarted queued draft for TOTK
        stores.queue.enqueue([
            QueueEntry(
                titleID: totk.titleID, name: totk.name, target: BuildTarget.mac,
                inputs: ["base": [totkNsp.path]], outputDirectory: temporary.path,
                engineID: stores.engineSync.selection.engineID
            )
        ])
        XCTAssertEqual(stores.build.gameTitleID, totk.titleID)
        XCTAssertEqual(stores.queue.entries.count, 1)

        // 2. Confirm batch fast refresh for MK8 from the library
        let fastAssessment = GameRefreshAssessment(
            heroState: .specificFast(version: "1.5.0"),
            hasSpecificUpdate: true,
            versionLabel: "1.5.0",
            canFastRefreshMac: true,
            canFastRefreshIOS: false,
            needsMissingImgGuideIOS: false,
            missingOriginalPackage: true,
            expectedRomfsIdentity: nil
        )
        let toolsAge = ToolsAge(older: [mk8.id], assessments: [mk8.id: fastAssessment])
        let pad = PadFocus()
        var confirmed = false
        let sheet = BatchRefreshSheet(
            library: library,
            toolsAge: toolsAge,
            stores: stores,
            onConfirmed: { confirmed = true },
            close: {}
        )
        .environmentObject(stores.localizer)
        .environmentObject(pad)

        let sheetWindow = OffscreenWindow(size: NSSize(width: 720, height: 640))
        sheetWindow.contentView = NSHostingView(rootView: sheet)
        sheetWindow.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        pad.focused = "batchRefresh.confirm"
        pad.activate()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        sheetWindow.orderOut(nil)

        XCTAssertTrue(confirmed)
        // Stale TOTK draft must be cleared from both BuildStore and BuildQueueStore
        XCTAssertEqual(stores.build.basePath, "", "TOTK single-game draft must be cleared on batch refresh")
        XCTAssertEqual(stores.build.gameDir, "")
        XCTAssertNil(stores.build.hintedTitleID)
        XCTAssertEqual(stores.queue.entries.map(\.titleID), ["0100152000022000"], "TOTK stale queue draft must not mix into refresh batch")

        // 3. Run the refresh batch end-to-end and verify BuildPage shows a clean finished queue summary without blank form cards
        stores.build.preflightApp = nil
        stores.build.startBuildOrQueue()
        let finishDeadline = Date().addingTimeInterval(5)
        while (stores.build.running || stores.queue.active || stores.queue.running != nil) && Date() < finishDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }

        XCTAssertFalse(stores.build.running)
        XCTAssertFalse(stores.queue.active)
        XCTAssertEqual(stores.queue.entries.map(\.status), [.done], "fast refresh entry should settle as done")
        XCTAssertEqual(stores.build.basePath, "", "TOTK draft must not resurface after fast refresh finishes")
        XCTAssertNil(stores.build.gameTitleID)

        let pageFocus = PadFocus()
        var editingResult = false
        let buildPage = BuildPage(
            library: library,
            fetchMetadata: false,
            step: .constant(0),
            build: stores.build,
            running: false,
            repo: stores.repo,
            dependencies: stores.dependencies,
            devices: stores.deviceStore,
            queue: stores.queue,
            transfers: stores.transfers,
            extrasOpen: .constant(false),
            logOpen: .constant(false),
            confirmingCancel: .constant(false),
            editingResult: Binding(get: { editingResult }, set: { editingResult = $0 })
        )
        .environmentObject(stores.localizer)
        .environmentObject(pageFocus)
        .padScope("main", pageFocus)

        let pageWindow = OffscreenWindow(size: NSSize(width: 1100, height: 1400))
        pageWindow.contentView = NSHostingView(rootView: buildPage)
        pageWindow.orderFront(nil)
        defer { pageWindow.orderOut(nil); pageWindow.contentView = nil; pageWindow.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))

        let ids = Set(pageFocus.frames["main", default: []].map(\.id))
        XCTAssertTrue(ids.contains("set.build.queue.clear"), "finished queue summary keeps Clear completed button")
        XCTAssertTrue(ids.contains("set.build.queue.newBuild"), "finished queue summary provides New build action")
        XCTAssertFalse(ids.contains("set.build.file.base"), "blank single-game file form must not mix above finished refresh queue")

        // 4. Clearing finished queue must also clear orphaned build completion state so page resets cleanly to empty build form
        pageFocus.focused = "set.build.queue.clear"
        pageFocus.activate()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        XCTAssertTrue(stores.queue.isEmpty)
        XCTAssertNil(stores.build.completionStatus, "clearing finished queue must reset orphaned completionStatus")
        XCTAssertFalse(stores.build.done, "clearing finished queue must reset orphaned done flag")
        XCTAssertTrue(stores.build.macAppPath.isEmpty)
        let afterClearIDs = Set(pageFocus.frames["main", default: []].map(\.id))
        XCTAssertTrue(afterClearIDs.contains("set.build.file.base"), "clearing finished queue restores clean single-game form")
        XCTAssertFalse(afterClearIDs.contains("set.build.done.library"), "old OutcomeCard must not linger after queue is cleared")
    }

    // MARK: 2.3 Centered ShellCopySheet controls & all-language dropdown widths

    func testShellCopySheetWaitForCableTransitionsWithoutSelfCancelling() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let stores = LauncherStores(runner: ImmediateSuccessRunner(), xcrun: "/usr/bin/true", defaults: testDefaults)
        let devices = stores.deviceStore
        let pad = PadFocus()

        let usb2Plan = ShellCopyPlan(
            files: 2,
            bytes: 15_000_000_000,
            connection: .wired,
            linkProfile: .usb2(bps: 480_000_000),
            deviceName: "Andy's iPhone",
            sizeText: "Game data to copy: 15.0 GB in 2 files.",
            connectionText: "Connected over USB 2.0 (480 Mbps): copying 15.0 GB takes about 7 to 9 minutes."
        )

        final class Box: @unchecked Sendable { var decision: ShellCopyDecision? }
        let box = Box()
        let answered = expectation(description: "waitForCable answered")
        DispatchQueue.global().async {
            box.decision = devices.askCopy(usb2Plan)
            answered.fulfill()
        }
        let deadline = Date().addingTimeInterval(5)
        while devices.shellCopy == nil && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }

        let sheet = ShellCopySheet(devices: devices)
            .environmentObject(stores.localizer)
            .environmentObject(pad)
        let window = OffscreenWindow(size: NSSize(width: 600, height: 500))
        window.contentView = NSHostingView(rootView: sheet)
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))

        // Activate "Wait for high-speed cable"
        pad.focused = "set.build.copy.wait"
        pad.activate()
        wait(for: [answered], timeout: 5)
        XCTAssertEqual(box.decision, .waitForCable)
        XCTAssertNil(devices.shellCopy)
        XCTAssertTrue(devices.shellWaiting, "sheet must remain in waiting state continuously")
        XCTAssertFalse(devices.waitCancelled, "waiting must not be self-cancelled during transition")

        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        let waitingIDs = Set(pad.frames["shellCopy", default: []].map(\.id))
        XCTAssertTrue(waitingIDs.contains("set.build.copy.stopWaiting"), "waiting view must expose Stop waiting button")

        // Activate "Stop waiting" and verify immediate dismissal
        pad.focused = "set.build.copy.stopWaiting"
        pad.activate()
        XCTAssertTrue(devices.waitCancelled)
        XCTAssertFalse(devices.shellWaiting)
    }

    func testShellCopySheetRegistersButtonsAndAnswersDecisions() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let stores = LauncherStores(runner: ImmediateSuccessRunner(), xcrun: "/usr/bin/true", defaults: testDefaults)
        let devices = stores.deviceStore
        let pad = PadFocus()

        let usb2Plan = ShellCopyPlan(
            files: 2,
            bytes: 15_000_000_000,
            connection: .wired,
            linkProfile: .usb2(bps: 480_000_000),
            deviceName: "Andy's iPhone",
            sizeText: "Game data to copy: 15.0 GB in 2 files.",
            connectionText: "Connected over USB 2.0 (480 Mbps): copying 15.0 GB takes about 7 to 9 minutes."
        )

        final class Box: @unchecked Sendable { var decision: ShellCopyDecision? }
        let box = Box()
        let answered = expectation(description: "sheet answered")
        DispatchQueue.global().async {
            box.decision = devices.askCopy(usb2Plan)
            answered.fulfill()
        }
        let deadline = Date().addingTimeInterval(5)
        while devices.shellCopy == nil && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }

        let sheet = ShellCopySheet(devices: devices)
            .environmentObject(stores.localizer)
            .environmentObject(pad)
        let window = OffscreenWindow(size: NSSize(width: 600, height: 500))
        window.contentView = NSHostingView(rootView: sheet)
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))

        let ids = Set(pad.frames["shellCopy", default: []].map(\.id))
        XCTAssertTrue(ids.contains("set.build.copy.start"))
        XCTAssertTrue(ids.contains("set.build.copy.wait"), "USB 2.0 offers Wait for high-speed cable")
        XCTAssertTrue(ids.contains("set.build.copy.skip"))

        pad.focused = "set.build.copy.start"
        pad.activate()
        wait(for: [answered], timeout: 5)
        XCTAssertEqual(box.decision, .copy)
        XCTAssertNil(devices.shellCopy)
    }

    func testAllTransferModeDropdownChoicesFitEveryLanguage() throws {
        let font = try XCTUnwrap(Typography.manropeFont(size: 13, weight: .semibold))
        for lang in Lang.all {
            for mode in PostBuildTransferMode.allCases {
                let text = L10n.string("dev.transferMode." + mode.rawValue, lang)
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
                let width = CTLineGetTypographicBounds(line, nil, nil, nil)
                XCTAssertLessThanOrEqual(
                    width,
                    LauncherControl.choiceWidth,
                    "\(lang.code) dev.transferMode.\(mode.rawValue) (\(text)) needs \(width) pt > \(LauncherControl.choiceWidth) pt"
                )
            }
        }
    }
}
