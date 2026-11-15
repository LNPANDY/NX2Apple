import XCTest
import SwiftUI
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher
@testable import NXModel

/// A download the test decides: one answer per call, in order (the last one repeats). The file itself is written by the test.
private final class FakeFetch: CloudFileFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [CloudFetchResult]
    private(set) var calls = 0
    /// Holds the download until `release()`: a wait the player sees and cancels.
    var held = false
    init(_ answers: CloudFetchResult...) { self.answers = answers }
    func release() { lock.lock(); held = false; lock.unlock() }
    func fetch(_ file: URL, cancelled: @escaping @Sendable () -> Bool) -> CloudFetchResult {
        while true {
            lock.lock(); let wait = held; lock.unlock()
            if cancelled() { return .cancelled }
            if !wait { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        lock.lock(); defer { lock.unlock() }
        calls += 1
        return answers.count > 1 ? answers.removeFirst() : answers[0]
    }
}

/// #957: the check before a start, for the desktop Play and the console mode, over saves in a temporary folder.
@MainActor final class CloudSaveGateTests: IsolatedDefaultsTestCase {
    private var root: URL!
    private let titleID = "0100ABCDEF000000"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudSaveGateTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private var save: URL { root.appendingPathComponent("save/" + titleID) }
    private var cloudFile: URL { root.appendingPathComponent("Saves/" + titleID + "/save.dmsync") }
    private func plan(takesChoice: Bool = true) -> CloudSaveStart {
        CloudSaveStart(titleID: titleID, gameName: "Hades", cloudFile: cloudFile, save: save, scanned: save, takesChoice: takesChoice)
    }

    /// This Mac's save with one file, and its hash.
    @discardableResult private func local(_ text: String) throws -> String {
        try FileManager.default.createDirectory(at: save, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: save.appendingPathComponent("game.dat"))
        return try XCTUnwrap(CloudSaveCheck.localSave(save: save)?.hash)
    }
    private func synced(_ hash: String) throws {
        try FileManager.default.createDirectory(at: save.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "base\t\(hash)\n".write(toFile: save.path + ".sync", atomically: true, encoding: .utf8) }
    /// The cloud's file: a packed save's header with this hash (the gate reads no more of it).
    private func cloud(_ hash: String, device: String = "iPhone17,1", saved: Int64 = 1_700_000_000, title: String? = nil) throws {
        try FileManager.default.createDirectory(at: cloudFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data("DMSYNC1\n".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(1).littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: UInt32(1).littleEndian, Array.init))
        data.append(Data(hash.utf8))
        data.append(contentsOf: withUnsafeBytes(of: saved.littleEndian, Array.init))
        var t = Data((title ?? titleID).utf8); t.count = 24; data.append(t)
        var d = Data(device.utf8); d.count = 64; data.append(d)
        data.append(Data("DMSYNCE\n".utf8))
        try data.write(to: cloudFile)
    }
    private let other = "ffffffffffffffffffffffffffffffff", older = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"

    /// Runs the gate until it proceeds, asks or ends. Returns what it proceeded with (nil: it did not).
    private func run(_ gate: CloudSaveGate, plan: CloudSaveStart? = nil, ended: @escaping () -> Void = {}) async -> [String: String]? {
        var started: [String: String]?
        gate.begin(LibraryGame(titleID: titleID, name: "Hades"), plan: plan ?? self.plan(), proceed: { started = $0 }, ended: ended)
        await settle(gate) { started != nil }
        return started
    }
    private func settle(_ gate: CloudSaveGate, until done: () -> Bool) async {
        for _ in 0..<500 {
            if done() { return }
            if case .asking = gate.step { return }
            if gate.step == nil { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
    private func question(_ gate: CloudSaveGate) -> CloudSaveQuestion? { if case let .asking(q) = gate.step { return q }; return nil }

    // ---- the six cases ----

    func testTheSameSaveStartsAtOnce() async throws {
        try synced(try local("v1")); try cloud(try local("v1"))
        let started = await run(CloudSaveGate(fetcher: FakeFetch(.ready)))
        XCTAssertEqual(started, [:], "no choice: the engine finds them in step")
    }

    func testOnlyTheCloudsChangedStartsAndTheEngineBringsItIn() async throws {
        try synced(try local("v1")); try cloud(other)
        let started = await run(CloudSaveGate(fetcher: FakeFetch(.ready)))
        XCTAssertEqual(started, [:])
    }

    func testOnlyThisMacsChangedStartsAndTheEngineSendsIt() async throws {
        let v1 = try local("v1"); try synced(v1); try cloud(v1); try local("v2")
        let started = await run(CloudSaveGate(fetcher: FakeFetch(.ready)))
        XCTAssertEqual(started, [:])
    }

    func testNoSaveInTheCloudStarts() async throws {
        try local("v1")
        let started = await run(CloudSaveGate(fetcher: FakeFetch(.missing)))
        XCTAssertEqual(started, [:])
    }

    func testBothChangedAsksAndStartsWithTheChoice() async throws {
        try synced(older); try local("mine"); try cloud(other, device: "iPhone17,1")
        let gate = CloudSaveGate(fetcher: FakeFetch(.ready))
        var started = await run(gate)
        XCTAssertNil(started, "nothing starts, nothing is replaced, before the player answers")
        let q = try XCTUnwrap(question(gate))
        XCTAssertEqual(q.outcome, .bothChanged)
        XCTAssertEqual(q.cloud?.hash, other)
        XCTAssertEqual(CloudSaveText.device(q.cloud?.device), "iPhone")
        XCTAssertEqual(q.backups.path, save.path + "-backups")
        gate.begin(LibraryGame(titleID: titleID, name: "Hades"), plan: plan(), proceed: { _ in XCTFail("a second Play while asking does not start") })
        XCTAssertEqual(question(gate), q)
        gate.choose(.cloud)
        XCTAssertNil(gate.step)

        let again = CloudSaveGate(fetcher: FakeFetch(.ready))
        started = await run(again)
        XCTAssertNil(started)
        var local: [String: String]?
        // The same question, answered with this Mac's
        again.cancel()
        again.begin(LibraryGame(titleID: titleID, name: "Hades"), plan: plan(), proceed: { local = $0 })
        await settle(again) { local != nil }
        again.choose(.local)
        XCTAssertEqual(local, ["DM_SAVE_SYNC_CHOICE": "local:" + other])
    }

    func testTheCloudsChoiceNamesItsHash() async throws {
        try local("mine"); try cloud(other)   // this Mac never synced and both have a save
        let gate = CloudSaveGate(fetcher: FakeFetch(.ready))
        var started: [String: String]?
        gate.begin(LibraryGame(titleID: titleID, name: "Hades"), plan: plan(), proceed: { started = $0 })
        await settle(gate) { started != nil }
        XCTAssertEqual(question(gate)?.outcome, .bothChanged)
        gate.choose(.cloud)
        XCTAssertEqual(started, ["DM_SAVE_SYNC_CHOICE": "cloud:" + other])
    }

    func testTheCloudUnreadableAsksAndRetries() async throws {
        let fetch = FakeFetch(.failed("The Internet connection appears to be offline."), .ready)
        try synced(try local("v1")); try cloud(try local("v1"))
        let gate = CloudSaveGate(fetcher: fetch)
        var started: [String: String]?
        gate.begin(LibraryGame(titleID: titleID, name: "Hades"), plan: plan(), proceed: { started = $0 })
        await settle(gate) { started != nil }
        let q = try XCTUnwrap(question(gate))
        XCTAssertEqual(q.outcome, .unreadable)
        XCTAssertEqual(q.reason, "The Internet connection appears to be offline.")
        XCTAssertNil(started, "no time limit gives up for the player")
        gate.retry()
        await settle(gate) { started != nil }
        XCTAssertEqual(started, [:], "the second read finds them in step")
        XCTAssertEqual(fetch.calls, 2)
    }

    func testPlayingWithThisMacsSaveWhenTheCloudIsUnreadableSendsNothingUntilCompared() async throws {
        try local("v1")
        let gate = CloudSaveGate(fetcher: FakeFetch(.failed("offline")))
        var started: [String: String]?
        gate.begin(LibraryGame(titleID: titleID, name: "Hades"), plan: plan(), proceed: { started = $0 })
        await settle(gate) { started != nil }
        gate.choose(.local)
        XCTAssertNil(started, "with no cloud save read, this Mac's cannot be chosen over it")
        gate.choose(.offline)
        XCTAssertEqual(started, ["DM_SAVE_SYNC_CHOICE": "offline"])
    }

    func testAnotherGamesFileOrAWrongFileIsUnreadable() async throws {
        try local("v1"); try cloud(other, title: "0100000000010000")
        let gate = CloudSaveGate(fetcher: FakeFetch(.ready))
        _ = await run(gate)
        XCTAssertEqual(question(gate)?.outcome, .unreadable)
        gate.cancel()
        try Data("half a file".utf8).write(to: cloudFile)
        _ = await run(gate)
        XCTAssertEqual(question(gate)?.reason, "The file in the cloud is not a whole save.")
    }

    // ---- without a player's choice nothing is replaced ----

    func testCancelStartsNothing() async throws {
        try synced(older); try local("mine"); try cloud(other)
        let gate = CloudSaveGate(fetcher: FakeFetch(.ready))
        var ended = false
        let started = await run(gate) { ended = true }
        XCTAssertNotNil(question(gate))
        gate.cancel()
        XCTAssertTrue(ended)
        XCTAssertNil(started)
        XCTAssertNil(gate.step)
    }

    func testTheWaitShowsAndCanBeCancelledOrPlayedWithout() async throws {
        try local("v1"); try cloud(other)
        let fetch = FakeFetch(.ready); fetch.held = true
        let gate = CloudSaveGate(fetcher: fetch, longWait: 0.05)
        var started: [String: String]?, ended = false
        gate.begin(LibraryGame(titleID: titleID, name: "Hades"), plan: plan(), proceed: { started = $0 }, ended: { ended = true })
        XCTAssertEqual(gate.step, .fetching(gameName: "Hades", long: false))
        gate.choose(.cloud)
        XCTAssertNotNil(gate.step, "only playing without it answers the wait")
        let deadline = Date().addingTimeInterval(2.0)
        while gate.step != .fetching(gameName: "Hades", long: true) && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(gate.step, .fetching(gameName: "Hades", long: true), "a long wait offers playing without it")
        gate.cancel()
        XCTAssertTrue(ended); XCTAssertNil(started)
        fetch.release()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(gate.step, "a download that ends after Cancel changes nothing")

        let second = CloudSaveGate(fetcher: FakeFetch(.ready), longWait: 0.01)
        let slow = FakeFetch(.ready); slow.held = true
        let third = CloudSaveGate(fetcher: slow, longWait: 0.01)
        third.begin(LibraryGame(titleID: titleID, name: "Hades"), plan: plan(), proceed: { started = $0 })
        third.choose(.offline)
        XCTAssertEqual(started, ["DM_SAVE_SYNC_CHOICE": "offline"])
        slow.release()
        _ = second
    }

    func testAnOlderEngineGetsTheDownloadAndNoQuestion() async throws {
        try synced(older); try local("mine"); try cloud(other)
        let started = await run(CloudSaveGate(fetcher: FakeFetch(.ready)), plan: plan(takesChoice: false))
        XCTAssertEqual(started, [:])
    }

    func testAGameWithoutCloudSavesStartsAtOnce() {
        var started: [String: String]?
        let gate = CloudSaveGate(fetcher: FakeFetch(.ready))
        gate.begin(LibraryGame(titleID: titleID, name: "Hades"), proceed: { started = $0 })   // no app: no plan
        XCTAssertEqual(started, [:])
        XCTAssertNil(gate.step)
    }

    func testTheEngineSaysWhetherItTakesTheChoice() throws {
        let app = root.appendingPathComponent("Hades.app/Contents")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["DMSaveSyncChoice": 1], format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))
        XCTAssertTrue(CloudSaveStart.takesChoice(app: root.appendingPathComponent("Hades.app").path))
        try PropertyListSerialization.data(fromPropertyList: ["DMControllerMappings": 1], format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))
        XCTAssertFalse(CloudSaveStart.takesChoice(app: root.appendingPathComponent("Hades.app").path))
    }

    func testTheLogSaysTheGameWaitsForTheChoice() {
        let log = "[dm] save sync: on: /x/save.dmsync\n[dm] save sync: both changed: the cloud's save (from iPhone17,1, saved 2026-11-08 10:00:00) and this device's (saved 2026-11-08 11:00:00); playing on with this device's, and neither replaces the other until the player chooses at the next start\n"
        XCTAssertEqual(CloudSaveSync.state(fromLog: log), .waitingForChoice)
        XCTAssertEqual(CloudSaveSync.state(fromLog: "[dm] save sync: not sent: the cloud's save (from Mac14,2, saved x) changed since this device's last sync, and so did this one; neither replaces the other until the player chooses at the next start\n"), .waitingForChoice)
    }

    // ---- the console mode ----

    func testTheConsoleAsksWithAControllerAndStartsWithTheAnswer() async throws {
        let app = root.appendingPathComponent("Hades.app")
        let macos = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        for exe in ["nxnative", "dmhost"] { try FileManager.default.createSymbolicLink(at: macos.appendingPathComponent(exe), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true")) }
        let bundle = "org.nxnative.cloudsavegatetests"
        let info: [String: Any] = ["DMTitleID": titleID, "CFBundleDisplayName": "Hades", "CFBundleExecutable": "nxnative", "CFBundleIdentifier": bundle, "DMSaveSyncChoice": 1]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        try Data().write(to: root.appendingPathComponent(GameLog.marker))   // the save lives beside the app: root/save/<title ID>
        CFPreferencesSetAppValue(CloudSaveSync.preferenceKey as CFString, root.appendingPathComponent("Saves").path as CFString, bundle as CFString)
        CFPreferencesAppSynchronize(bundle as CFString)
        defer { CFPreferencesSetAppValue(CloudSaveSync.preferenceKey as CFString, nil, bundle as CFString); CFPreferencesAppSynchronize(bundle as CFString) }
        try synced(older); try local("mine"); try cloud(other)

        let library = GameLibrary(file: root.appendingPathComponent("library.json"))
        _ = try library.addApp(app)
        var launched: [[String: String]] = []
        let driver = LiveConsoleDriver(library: library, controls: ControlLayout(defaults: TestDefaults.make("CloudSaveGateTests")), repo: { "" }, lang: { .en },
                                       labels: { L10n.string($0, .en) }, launch: { _, env, done in launched.append(env); done(7, nil) },
                                       artwork: { _, _ in nil }, startingTimeout: 0.2, observeSystem: false)
        let fetch = FakeFetch(.ready); fetch.held = true
        driver.cloudGate = CloudSaveGate(fetcher: fetch)
        let id = try XCTUnwrap(driver.state.games.first?.id)
        driver.play(id)
        XCTAssertEqual(driver.state.starting, .cloudSave(long: false), "Starting shows the download")
        XCTAssertEqual(driver.state.startingGameID, id)
        fetch.release()
        for _ in 0..<400 where driver.state.presentedSheet == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        guard case let .cloudSave(q) = driver.state.presentedSheet else { return XCTFail("the question is a sheet") }
        XCTAssertEqual(q.outcome, .bothChanged)
        XCTAssertNil(driver.state.startingGameID)
        XCTAssertTrue(launched.isEmpty, "nothing starts before the answer")
        driver.back()   // B: Cancel
        XCTAssertNil(driver.state.presentedSheet)
        XCTAssertTrue(launched.isEmpty)

        driver.play(id)
        for _ in 0..<400 where driver.state.presentedSheet == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        driver.chooseCloudSave(.cloud)   // A on the first button
        XCTAssertEqual(launched.count, 1)
        XCTAssertEqual(launched.first?["DM_SAVE_SYNC_CHOICE"], "cloud:" + other)
    }

    // ---- visual QA ----

    /// The desktop sheet and the console's question for `NX_LAUNCHER_CAPTURE_DIR` (`NX_CAPTURE_LANG` for the language): the wait, the
    /// wait that takes long, both changed, and the cloud unreadable.
    func testRenderCloudSaveQuestionsForVisualQA() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else { throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture native views") }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        let localizer = LauncherStores(defaults: testDefaults).localizer
        let lang = CaptureLanguage.current(.en)
        localizer.lang = lang
        let now = Date()
        let differ = CloudSaveQuestion(gameName: "Hades", outcome: .bothChanged,
                                       local: .init(hash: "a", saved: now.addingTimeInterval(-20 * 60)),
                                       cloud: .init(hash: "b", saved: now.addingTimeInterval(-26 * 3600), device: "iPhone17,1"), reason: nil, backups: root)
        let unreadable = CloudSaveQuestion(gameName: "Hades", outcome: .unreadable, local: .init(hash: "a", saved: now), cloud: nil,
                                           reason: "The Internet connection appears to be offline.", backups: root)
        func write(_ name: String, _ view: some View, size: NSSize? = nil) throws {
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(origin: .zero, size: size ?? host.fittingSize)
            let window = OffscreenWindow(size: host.frame.size, styleMask: [.borderless])
            window.contentView = host
            window.orderBack(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("\(name)-\(lang.code).png"))
            window.orderOut(nil); window.contentView = nil; window.close()
        }
        let steps: [(String, CloudSaveStep)] = [("cloudsave-fetching", .fetching(gameName: "Hades", long: false)),
                                                 ("cloudsave-fetching-long", .fetching(gameName: "Hades", long: true)),
                                                 ("cloudsave-differ", .asking(differ)), ("cloudsave-unreadable", .asking(unreadable))]
        for (name, step) in steps {
            let gate = CloudSaveGate(fetcher: FakeFetch(.ready))
            gate.step = step
            try write(name, CloudSaveSheet(gate: gate).environmentObject(localizer).environmentObject(PadFocus()))
        }
        for (name, sheet, starting) in [("console-cloudsave-differ", ConsoleSheet.cloudSave(differ), nil),
                                        ("console-cloudsave-unreadable", ConsoleSheet.cloudSave(unreadable), nil),
                                        ("console-cloudsave-fetching", nil, ConsoleStarting.cloudSave(long: true))] as [(String, ConsoleSheet?, ConsoleStarting?)] {
            let driver = MockConsoleDriver(scenario: .full, lang: lang, animated: false)
            if let sheet { driver.state.sheets = [sheet] }
            if let starting, let id = driver.state.games.first?.id { driver.state.startingGameID = id; driver.state.starting = starting }
            try write(name, ConsoleView(driver: driver, lang: lang).transaction { $0.disablesAnimations = true }.frame(width: 1280, height: 800),
                      size: NSSize(width: 1280, height: 800))
        }
    }
}
