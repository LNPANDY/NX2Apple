import XCTest
@testable import NXModel
@testable import NXCore

@MainActor final class TransferModeAndDraftIsolationTests: XCTestCase {
    private final class FakeRepo: RepoLocation {
        var path: String
        var isRepo = true
        var isGit = true
        init(path: String) { self.path = path }
    }

    private final class FakeDeps: DependencyInstalling {
        var pythonPath = "/usr/bin/python3"
        var dotnetPath = "/usr/bin/true"
        var checked = true
        var allPresent = true
        var deps: [Dep] = []
        func isInstalling(_ id: String) -> Bool { false }
        func install(_ dep: Dep) -> Task<Void, Never> { Task {} }
    }

    private final class FakeEngine: EngineSyncing {
        func syncEngine(then: ((Bool) -> Void)?) -> Task<Void, Never> { then?(true); return Task {} }
    }

    private var defaults: UserDefaults!
    private var tempDir: URL!

    override func setUpWithError() throws {
        defaults = TestDefaults.make("nxmodel-transfer-draft-tests")
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("nxmodel-td-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    // MARK: 2.3 DeviceStore USB speed & PostBuildTransferMode

    func testDeviceStoreTransferModeDefaultsToAskAndPersists() {
        let runner = FakeProcessRunner()
        let store = DeviceStore(runner: runner, defaults: defaults, listDevices: { _ in [] }, readTeams: { [] }, usbSpeedLookup: { _ in nil })
        XCTAssertEqual(store.postBuildTransferMode, .ask)
        XCTAssertEqual(store.currentPostBuildTransferMode, .ask)

        store.postBuildTransferMode = .auto
        XCTAssertEqual(defaults.string(forKey: DeviceStore.postBuildTransferModeKey), "auto")
        XCTAssertEqual(store.currentPostBuildTransferMode, .auto)

        let reloaded = DeviceStore(runner: runner, defaults: defaults, listDevices: { _ in [] }, readTeams: { [] }, usbSpeedLookup: { _ in nil })
        XCTAssertEqual(reloaded.postBuildTransferMode, .auto)

        reloaded.postBuildTransferMode = .skip
        XCTAssertEqual(defaults.string(forKey: DeviceStore.postBuildTransferModeKey), "skip")
        XCTAssertEqual(reloaded.currentPostBuildTransferMode, .skip)
    }

    func testDeviceStoreRefreshQueriesInjectedUSBSpeedLookup() async {
        let runner = FakeProcessRunner()
        let wiredPhone = AppleDevice(id: "00008150-000660C01447801C", name: "Andy's iPhone", model: "iPhone 17 Pro Max", os: "27.0", reachable: true, transport: "wired")
        let wifiPhone = AppleDevice(id: "WIFI-PHONE", name: "Living Room iPad", model: "iPad Pro", os: "27.0", reachable: true, transport: "localNetwork")
        let offlinePhone = AppleDevice(id: "OFFLINE-PHONE", name: "Old iPhone", model: "iPhone 15", os: "26.0", reachable: false, transport: "")

        let store = DeviceStore(
            runner: runner,
            defaults: defaults,
            listDevices: { _ in [wiredPhone, wifiPhone, offlinePhone] },
            readTeams: { [] },
            usbSpeedLookup: { udid in
                udid == wiredPhone.id ? 10_000_000_000 : nil
            }
        )
        store.installDevice = wiredPhone.id
        await store.refresh().value
        XCTAssertEqual(store.selectedDeviceLinkProfile, .highSpeedUSB(bps: 10_000_000_000))
        XCTAssertEqual(store.linkProfile(for: wifiPhone.id), .wifi)
        XCTAssertEqual(store.linkProfile(for: offlinePhone.id), .disconnected)

        // Switch cable to USB 2.0 (480 Mbps) and refresh again
        store.usbSpeedLookup = { udid in udid == wiredPhone.id ? 480_000_000 : nil }
        await store.refresh().value
        XCTAssertEqual(store.selectedDeviceLinkProfile, .usb2(bps: 480_000_000))
    }

    func testMakeInstallerDecideCopyRespectsTransferModeAndOfflineFallback() {
        let runner = FakeProcessRunner()
        let deviceStore = DeviceStore(runner: runner, defaults: defaults, listDevices: { _ in [] }, readTeams: { [] }, usbSpeedLookup: { _ in 10_000_000_000 })
        deviceStore.installDevice = "UDID-1"
        deviceStore.signingTeam = "ABCDE12345"

        let build = BuildStore(
            localizer: Localizer(.en),
            runner: runner,
            repo: FakeRepo(path: tempDir.path),
            deps: FakeDeps(),
            engine: FakeEngine(),
            devices: deviceStore,
            defaults: defaults
        )

        let onlinePlan = ShellCopyPlan(
            files: 1, bytes: 1_000_000_000, connection: .wired,
            linkProfile: .highSpeedUSB(bps: 10_000_000_000),
            deviceName: "iPhone", sizeText: "1.0 GB", connectionText: "10 Gbps"
        )
        let usb2Plan = ShellCopyPlan(
            files: 1, bytes: 1_000_000_000, connection: .wired,
            linkProfile: .usb2(bps: 480_000_000),
            deviceName: "iPhone", sizeText: "1.0 GB", connectionText: "480 Mbps"
        )
        let wifiPlan = ShellCopyPlan(
            files: 1, bytes: 1_000_000_000, connection: .network,
            linkProfile: .wifi,
            deviceName: "iPhone", sizeText: "1.0 GB", connectionText: "Wi-Fi"
        )
        let offlinePlan = ShellCopyPlan(
            files: 1, bytes: 1_000_000_000, connection: .notConnected,
            linkProfile: .disconnected,
            deviceName: "iPhone", sizeText: "1.0 GB", connectionText: "Offline"
        )

        let installer = build.makeInstaller(respectSkipMode: true)

        // 1. `.skip` skips immediately without blocking or showing shellCopy
        deviceStore.postBuildTransferMode = .skip
        XCTAssertEqual(installer.decideCopy(onlinePlan), .skip)
        XCTAssertNil(deviceStore.shellCopy)

        // 2. `.auto` transfers immediately when online (highSpeedUSB, usb2, wifi)
        deviceStore.postBuildTransferMode = .auto
        XCTAssertEqual(installer.decideCopy(onlinePlan), .copy)
        XCTAssertEqual(installer.decideCopy(usb2Plan), .copy)
        XCTAssertEqual(installer.decideCopy(wifiPlan), .copy)
        XCTAssertNil(deviceStore.shellCopy)

        // 3. `.auto` falls back to asking the user when device is disconnected
        final class Box: @unchecked Sendable { var value: ShellCopyDecision? }
        let offlineBox = Box()
        let offlineAsked = expectation(description: "offline fallback asks user")
        DispatchQueue.global().async {
            offlineBox.value = installer.decideCopy(offlinePlan)
            offlineAsked.fulfill()
        }
        let deadline = Date().addingTimeInterval(5)
        while deviceStore.shellCopy == nil && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(deviceStore.shellCopy, offlinePlan, ".auto must fall back to askCopy when offline")
        deviceStore.answerCopy(.waitForCable)
        wait(for: [offlineAsked], timeout: 5)
        XCTAssertEqual(offlineBox.value, .waitForCable)

        // 4. `.ask` (default) always prompts the user even when online
        deviceStore.postBuildTransferMode = .ask
        let askBox = Box()
        let onlineAsked = expectation(description: "ask mode prompts user")
        DispatchQueue.global().async {
            askBox.value = installer.decideCopy(onlinePlan)
            onlineAsked.fulfill()
        }
        let deadline2 = Date().addingTimeInterval(5)
        while deviceStore.shellCopy == nil && Date() < deadline2 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(deviceStore.shellCopy, onlinePlan)
        deviceStore.answerCopy(.copy)
        wait(for: [onlineAsked], timeout: 5)
        XCTAssertEqual(askBox.value, .copy)

        // 5. Manual retry (`respectSkipMode: false`) prompts even when stored preference is `.skip`
        deviceStore.postBuildTransferMode = .skip
        let retryInstaller = build.makeInstaller(respectSkipMode: false)
        let retryBox = Box()
        let retryAsked = expectation(description: "manual retry prompts even in skip mode")
        DispatchQueue.global().async {
            retryBox.value = retryInstaller.decideCopy(onlinePlan)
            retryAsked.fulfill()
        }
        let deadline3 = Date().addingTimeInterval(5)
        while deviceStore.shellCopy == nil && Date() < deadline3 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(deviceStore.shellCopy, onlinePlan)
        deviceStore.answerCopy(.copy)
        wait(for: [retryAsked], timeout: 5)
        XCTAssertEqual(retryBox.value, .copy)
    }

    // MARK: 2.1 Draft and refresh queue isolation

    func testClearUnstartedDraftResetsSingleGameInputsOnlyWhenIdle() {
        let runner = FakeProcessRunner()
        let deviceStore = DeviceStore(runner: runner, defaults: defaults, listDevices: { _ in [] }, readTeams: { [] }, usbSpeedLookup: { _ in nil })
        let build = BuildStore(
            localizer: Localizer(.en),
            runner: runner,
            repo: FakeRepo(path: tempDir.path),
            deps: FakeDeps(),
            engine: FakeEngine(),
            devices: deviceStore,
            defaults: defaults
        )

        build.gameDir = "/Games/TOTK"
        build.updateSlot("base") { $0.paths = ["/Games/TOTK/Tears of the Kingdom [0100F2C0115B6000].nsp"]; $0.problem = "warn"; $0.note = "note" }
        build.updateSlot("update") { $0.paths = ["/Games/TOTK/update.nsp"] }
        build.applyKnownTitleID("0100F2C0115B6000")
        build.selectedTitleID = "0100F2C0115B6000"

        // Guarded while running
        build.running = true
        build.clearUnstartedDraft()
        XCTAssertFalse(build.basePath.isEmpty, "clearUnstartedDraft must not wipe inputs while a build is running")

        // Clears cleanly when idle
        build.running = false
        build.clearUnstartedDraft()
        XCTAssertEqual(build.basePath, "")
        XCTAssertEqual(build.updatePath, "")
        XCTAssertEqual(build.gameDir, "")
        XCTAssertNil(build.gameFolder)
        XCTAssertNil(build.hintedTitleID)
        XCTAssertNil(build.selectedTitleID)
        XCTAssertTrue(build.slots.allSatisfy { $0.paths.isEmpty && $0.problem.isEmpty && $0.note.isEmpty })
    }

    func testPrepareForRefreshBatchDropsStaleDraftsAndHistoryWithoutDisturbingActiveQueue() {
        var started: [QueueEntry] = []
        let queue = BuildQueueStore(
            file: nil,
            engineID: { "eng-1" },
            busy: { false },
            start: { started.append($0); return nil }
        )

        let staleDraft = QueueEntry(
            titleID: "0100F2C0115B6000", name: "Tears of the Kingdom", target: BuildTarget.mac,
            inputs: ["base": ["/Games/totk.nsp"]], outputDirectory: tempDir.path, engineID: "eng-1"
        )
        queue.enqueue([staleDraft])
        XCTAssertEqual(queue.queued.count, 1)
        XCTAssertFalse(queue.active)

        // Idle queue: prepareForRefreshBatch clears stale unstarted draft so refresh batch is pure
        queue.prepareForRefreshBatch()
        XCTAssertTrue(queue.entries.isEmpty)

        // Run a batch and let it settle
        let firstRefresh = QueueEntry(
            titleID: "0100152000022000", name: "Mario Kart 8", target: BuildTarget.mac,
            inputs: [:], outputDirectory: tempDir.path, engineID: "eng-1"
        )
        queue.enqueue([firstRefresh])
        queue.start()
        XCTAssertEqual(started.count, 1)
        XCTAssertTrue(queue.active)

        // While active, prepareForRefreshBatch must NOT clear running or active entries
        queue.prepareForRefreshBatch()
        XCTAssertEqual(queue.entries.count, 1)

        // Once finished and idle, prepareForRefreshBatch clears settled history
        queue.buildEnded(succeeded: true)
        XCTAssertFalse(queue.active)
        XCTAssertEqual(queue.entries.count, 1)
        queue.prepareForRefreshBatch()
        XCTAssertTrue(queue.entries.isEmpty)
    }

    func testStartBuildOrQueueClearsUnstartedSingleGameDraftBeforeStartingQueue() {
        let runner = FakeProcessRunner()
        let deviceStore = DeviceStore(runner: runner, defaults: defaults, listDevices: { _ in [] }, readTeams: { [] }, usbSpeedLookup: { _ in nil })
        let build = BuildStore(
            localizer: Localizer(.en),
            runner: runner,
            repo: FakeRepo(path: tempDir.path),
            deps: FakeDeps(),
            engine: FakeEngine(),
            devices: deviceStore,
            defaults: defaults
        )
        var startedEntries: [QueueEntry] = []
        let queue = BuildQueueStore(
            file: nil,
            engineID: { "eng-1" },
            busy: { build.running },
            start: { entry in
                startedEntries.append(entry)
                return nil
            }
        )
        build.queue = queue

        // User previously clicked Build on TOTK (leaves unstarted draft in BuildStore)
        build.gameDir = "/Games/TOTK"
        build.updateSlot("base") { $0.paths = ["/Games/TOTK/totk [0100F2C0115B6000].nsp"] }
        build.applyKnownTitleID("0100F2C0115B6000")

        // Now user starts a queued fast refresh for Mario Kart 8
        var mk8 = QueueEntry(
            titleID: "0100152000022000", name: "Mario Kart 8", target: BuildTarget.mac,
            inputs: [:], outputDirectory: tempDir.path, engineID: "eng-1"
        )
        mk8.fastRefresh = true
        queue.enqueue([mk8])

        build.startBuildOrQueue()
        XCTAssertEqual(startedEntries.count, 1)
        XCTAssertEqual(startedEntries.first?.titleID, "0100152000022000")
        XCTAssertEqual(build.basePath, "", "unstarted TOTK draft must be cleared when queue starts")
        XCTAssertEqual(build.gameDir, "")
        XCTAssertNil(build.hintedTitleID)
    }

    func testWaitForCableKeepsSheetPresentedContinuouslyAndCancelWaitClearsImmediately() {
        let runner = FakeProcessRunner()
        let store = DeviceStore(runner: runner, defaults: defaults, listDevices: { _ in [] }, readTeams: { [] }, usbSpeedLookup: { _ in nil })
        let usb2Plan = ShellCopyPlan(
            files: 1, bytes: 2_000_000_000, connection: .wired,
            linkProfile: .usb2(bps: 480_000_000),
            deviceName: "Andy's iPhone", sizeText: "2.0 GB", connectionText: "USB 2.0"
        )

        final class Box: @unchecked Sendable { var decision: ShellCopyDecision? }
        let box = Box()
        let answered = expectation(description: "waitForCable answered")
        DispatchQueue.global().async {
            box.decision = store.askCopy(usb2Plan)
            answered.fulfill()
        }
        let deadline = Date().addingTimeInterval(5)
        while store.shellCopy == nil && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertNotNil(store.shellCopy)
        XCTAssertFalse(store.shellWaiting)

        // Transition to waiting must set shellWaiting = true synchronously before shellCopy becomes nil so sheet never dismisses
        store.answerCopy(.waitForCable)
        XCTAssertNil(store.shellCopy)
        XCTAssertTrue(store.shellWaiting, "shellWaiting must already be true synchronously to keep modal presented")
        XCTAssertTrue(store.shellWaitingForHighSpeed)
        XCTAssertFalse(store.waitCancelled, "sheet must not self-cancel on transition")
        wait(for: [answered], timeout: 5)
        XCTAssertEqual(box.decision, .waitForCable)

        // Clicking Stop waiting clears shellWaiting synchronously and ignores any late background setWaiting(true)
        store.cancelWait()
        XCTAssertTrue(store.waitCancelled)
        XCTAssertFalse(store.shellWaiting)
        XCTAssertFalse(store.shellWaitingForHighSpeed)

        store.setWaiting(true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(store.shellWaiting, "late setWaiting(true) after cancelWait must not reopen the waiting sheet")
    }

    func testAskCopyRechecksCancellationOnMainActorWithoutShowingPromptOrClearingWaitCancel() {
        let runner = FakeProcessRunner()
        let store = DeviceStore(runner: runner, defaults: defaults, listDevices: { _ in [] }, readTeams: { [] }, usbSpeedLookup: { _ in nil })
        let plan = ShellCopyPlan(
            files: 1, bytes: 1_000_000_000, connection: .wired,
            linkProfile: .highSpeedUSB(bps: 10_000_000_000),
            deviceName: "Andy's iPhone", sizeText: "1.0 GB", connectionText: "10 Gbps"
        )

        // Simulate TOCTOU: first pre-check returns false, then Stop sets cancelled = true before main-actor block runs
        final class RaceFlag: @unchecked Sendable {
            private let lock = NSLock()
            var checks = 0
            func next() -> Bool {
                lock.lock(); defer { lock.unlock() }
                checks += 1
                return checks > 1
            }
        }
        let race = RaceFlag()
        store.cancelWait()
        XCTAssertTrue(store.waitCancelled)

        final class Box: @unchecked Sendable { var decision: ShellCopyDecision? }
        let box = Box()
        let done = expectation(description: "cancelled askCopy returns immediately")
        DispatchQueue.global().async {
            box.decision = store.askCopy(plan, isCancelled: { race.next() })
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(box.decision, .skip)
        XCTAssertNil(store.shellCopy, "cancelled askCopy must not present ShellCopySheet")
        XCTAssertTrue(store.waitCancelled, "cancelled askCopy must not reset waitCancelled")
    }

    func testBatchInstallSkippedDataPreservesAllGamesForRetryThenClearsAfterTransfer() throws {
        let fm = FileManager.default
        let shellRoot = tempDir.appendingPathComponent("shell-root").path
        defaults.set(shellRoot, forKey: "shellRoot")
        try fm.createDirectory(atPath: shellRoot + "/derived-data/Build/Products/Release-iphoneos/DmShell.app", withIntermediateDirectories: true)
        var lib = ShellLibrary()
        lib.bundleID = "org.nxnative.shell.test"
        try lib.save(root: shellRoot)

        func makeGameFixture(_ tid: String, _ name: String) throws -> DeferredShellGame {
            let fw = tempDir.appendingPathComponent("DmGame\(tid).framework").path
            let archive = tempDir.appendingPathComponent("archive-\(tid)").path
            try fm.createDirectory(atPath: fw, withIntermediateDirectories: true)
            try fm.createDirectory(atPath: archive, withIntermediateDirectories: true)
            try Data("DMROMFS1-\(tid)".utf8).write(to: URL(fileURLWithPath: archive + "/romfs.img"))
            return DeferredShellGame(framework: fw, titleID: tid, name: name, archive: archive)
        }
        let game1 = try makeGameFixture("0100152000022000", "Mario Kart 8")
        let game2 = try makeGameFixture("0100F2C0115B6000", "Tears of the Kingdom")

        let wiredJSON = """
        {"result":{"devices":[{"hardwareProperties":{"reality":"physical","platform":"iOS","udid":"UDID-1","marketingName":"iPhone 17 Pro Max"},"deviceProperties":{"name":"Andy's iPhone","osVersionNumber":"27.0"},"connectionProperties":{"pairingState":"paired","transportType":"wired"}}]}}
        """
        final class CopyLog: @unchecked Sendable {
            private let lock = NSLock()
            var copiedDestinations: [String] = []
            func record(_ dest: String) { lock.lock(); copiedDestinations.append(dest); lock.unlock() }
        }
        let copyLog = CopyLog()

        let runner = FakeProcessRunner()
        runner.answer = { launch in
            if let idx = launch.arguments.firstIndex(of: "--json-output"), idx + 1 < launch.arguments.count {
                try? Data(wiredJSON.utf8).write(to: URL(fileURLWithPath: launch.arguments[idx + 1]))
            }
            return ProcessResult(status: 0, out: "")
        }
        runner.streamAnswer = { launch in
            if launch.arguments.contains("copy"), launch.arguments.contains("to"),
               let destIdx = launch.arguments.firstIndex(of: "--destination"),
               destIdx + 1 < launch.arguments.count {
                copyLog.record(launch.arguments[destIdx + 1])
            }
            return ([], true)
        }

        let deviceStore = DeviceStore(
            runner: runner,
            defaults: defaults,
            listDevices: { _ in [AppleDevice(id: "UDID-1", name: "Andy's iPhone", model: "iPhone 17 Pro Max", os: "27.0", reachable: true, transport: "wired")] },
            readTeams: { [] },
            usbSpeedLookup: { _ in 10_000_000_000 }
        )
        deviceStore.installDevice = "UDID-1"
        deviceStore.signingTeam = "ABCDE12345"

        let build = BuildStore(
            localizer: Localizer(.en),
            runner: runner,
            repo: FakeRepo(path: tempDir.path),
            deps: FakeDeps(),
            engine: FakeEngine(),
            devices: deviceStore,
            defaults: defaults
        )

        // 1. Batch data install skipped (user clicked "Not now"): must retain all 2 games in shellBatchRetry
        deviceStore.postBuildTransferMode = .ask
        build.installShellBatch([game1, game2], dataOnly: true)
        let askDeadline = Date().addingTimeInterval(5)
        while deviceStore.shellCopy == nil && Date() < askDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertNotNil(deviceStore.shellCopy)
        deviceStore.answerCopy(.skip)
        let endDeadline1 = Date().addingTimeInterval(5)
        while build.running && Date() < endDeadline1 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(build.done)
        XCTAssertEqual(build.installedDataComplete, false)
        XCTAssertEqual(build.shellBatchRetry?.map(\.titleID), [game1.titleID, game2.titleID],
                       "skipping batch transfer must keep every game in shellBatchRetry for subsequent retry")
        XCTAssertTrue(copyLog.copiedDestinations.isEmpty)

        // 2. User later clicks Retry -> transfers BOTH games and clears shellBatchRetry on completion
        deviceStore.postBuildTransferMode = .auto
        build.retryShellData()
        let endDeadline2 = Date().addingTimeInterval(5)
        while build.running && Date() < endDeadline2 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(build.done)
        XCTAssertEqual(build.installedDataComplete, true)
        XCTAssertNil(build.shellBatchRetry, "completed batch retry clears shellBatchRetry")
        XCTAssertTrue(copyLog.copiedDestinations.contains("Documents/games/\(game1.titleID)/romfs.img"))
        XCTAssertTrue(copyLog.copiedDestinations.contains("Documents/games/\(game2.titleID)/romfs.img"))
    }

    func testCancelCopyThenCopyEndedAndSubsequentAutoAndSendGameDataResetWaitCancelled() throws {
        // 1. DataSend.after must distinguish wait-cancelled skip from not-connected device
        var waitCancelledOutcome = ShellInstaller.Outcome(ok: false, message: "Skipped copying to Andy's iPhone", copySkipped: true)
        waitCancelledOutcome.waitWasCancelled = true
        XCTAssertEqual(
            DataSend.after(waitCancelledOutcome, notConnected: "Andy's iPhone is not connected"),
            .failed("Skipped copying to Andy's iPhone")
        )
        let absentDeviceOutcome = ShellInstaller.Outcome(ok: false, message: "Skipped copying to Andy's iPhone", copySkipped: true)
        XCTAssertEqual(
            DataSend.after(absentDeviceOutcome, notConnected: "Andy's iPhone is not connected"),
            .failed("Andy's iPhone is not connected")
        )

        // 2. DeviceStore.copyEnded() clears waitCancelled immediately
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("nx-cancel-reset-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let shellRoot = tempDir.appendingPathComponent("shell-root").path
        defaults.set(shellRoot, forKey: "shellRoot")
        try FileManager.default.createDirectory(atPath: shellRoot + "/derived-data/Build/Products/Release-iphoneos/DmShell.app", withIntermediateDirectories: true)
        var lib = ShellLibrary()
        lib.bundleID = "org.nxnative.shell.test"
        try lib.save(root: shellRoot)

        let fw = tempDir.appendingPathComponent("DmGame.framework").path
        try FileManager.default.createDirectory(atPath: fw, withIntermediateDirectories: true)
        let archive = tempDir.appendingPathComponent("games/0100999900001111")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try Data("DMROMFS1-romfs-payload".utf8).write(to: archive.appendingPathComponent("romfs.img"))

        final class CopyRecorder: @unchecked Sendable {
            private let lock = NSLock()
            var copiedCount = 0
            func record() { lock.lock(); copiedCount += 1; lock.unlock() }
        }
        let recorder = CopyRecorder()

        let bundleID = ShellLibrary.defaultBundleID
        let wiredAndAppsJSON = """
        {"result":{"devices":[{"hardwareProperties":{"reality":"physical","platform":"iOS","udid":"UDID-1","marketingName":"iPhone 17 Pro Max"},"deviceProperties":{"name":"Andy's iPhone","osVersionNumber":"27.0"},"connectionProperties":{"pairingState":"paired","transportType":"wired"}}],"apps":[{"bundleIdentifier":"\(bundleID)","name":"NXShell","url":"file:///var/mobile/Containers/Bundle/Application/1/NXShell.app/"}]}}
        """

        let runner = FakeProcessRunner()
        runner.answer = { launch in
            if let idx = launch.arguments.firstIndex(of: "--json-output"), idx + 1 < launch.arguments.count {
                try? Data(wiredAndAppsJSON.utf8).write(to: URL(fileURLWithPath: launch.arguments[idx + 1]))
            }
            return ProcessResult(status: 0, out: "")
        }
        runner.streamAnswer = { launch in
            if let idx = launch.arguments.firstIndex(of: "--json-output"), idx + 1 < launch.arguments.count {
                try? Data(wiredAndAppsJSON.utf8).write(to: URL(fileURLWithPath: launch.arguments[idx + 1]))
            }
            if launch.arguments.contains("copy"), launch.arguments.contains("to") {
                recorder.record()
            }
            return ([], true)
        }

        let deviceStore = DeviceStore(
            runner: runner,
            defaults: defaults,
            listDevices: { _ in [AppleDevice(id: "UDID-1", name: "Andy's iPhone", model: "iPhone 17 Pro Max", os: "27.0", reachable: true, transport: "wired")] },
            readTeams: { [] },
            usbSpeedLookup: { _ in 10_000_000_000 }
        )
        deviceStore.installDevice = "UDID-1"
        deviceStore.signingTeam = "ABCDE12345"

        deviceStore.cancelCopy()
        XCTAssertTrue(deviceStore.waitCancelled)
        deviceStore.copyEnded()
        XCTAssertFalse(deviceStore.waitCancelled, "copyEnded() must clear waitCancel so future auto/manual transfers are not skipped")

        let build = BuildStore(
            localizer: Localizer(.en),
            runner: runner,
            repo: FakeRepo(path: tempDir.path),
            deps: FakeDeps(),
            engine: FakeEngine(),
            devices: deviceStore,
            defaults: defaults
        )
        build.archivePath = archive.path
        build.exportedIPAPath = tempDir.appendingPathComponent("NXShell.ipa").path
        try Data("ipa".utf8).write(to: URL(fileURLWithPath: build.exportedIPAPath))

        // 3. Even if waitCancel was left true before sendGameData(), sendGameData() must reset it and succeed (never report notConnected)
        deviceStore.cancelWait()
        XCTAssertTrue(deviceStore.waitCancelled)
        build.sendGameData()
        XCTAssertFalse(deviceStore.waitCancelled, "sendGameData() must reset any stale waitCancel before starting")
        let sendDeadline = Date().addingTimeInterval(5)
        while build.running && Date() < sendDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(build.send, .sent(app: "NXShell"))
        XCTAssertEqual(recorder.copiedCount, 1)

        // 4. Same guarantee for subsequent .auto batch installData even if waitCancel was left true
        deviceStore.postBuildTransferMode = .auto
        deviceStore.cancelWait()
        XCTAssertTrue(deviceStore.waitCancelled)
        let game = DeferredShellGame(framework: fw, titleID: "0100999900001111", name: "Test", archive: archive.path)
        build.installShellBatch([game], dataOnly: true)
        XCTAssertFalse(deviceStore.waitCancelled, "installShellBatch() must reset stale waitCancel before starting")
        let batchDeadline = Date().addingTimeInterval(5)
        while build.running && Date() < batchDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(build.done)
        XCTAssertEqual(build.installedDataComplete, true)
        XCTAssertEqual(recorder.copiedCount, 2)
    }
}
