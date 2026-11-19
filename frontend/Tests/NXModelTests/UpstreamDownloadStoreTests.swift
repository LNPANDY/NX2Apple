import Combine
import Foundation
import XCTest
@testable import NXModel
@testable import NXCore

@MainActor final class UpstreamDownloadStoreTests: XCTestCase {
    private final class FakeRepo: RepoLocation {
        var path: String
        var isRepo = false
        var isGit = false
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
        func syncEngine(then: ((Bool) -> Void)?) -> Task<Void, Never> {
            then?(true)
            return Task {}
        }
    }

    private final class FakeDevices: InstallTarget {
        var installDevice = "device-ios-1"
        var signingTeam = "TEAM1"
        var exportIPA = false
        var exportOneGame = false
        var driveFolder = ""
        var devices: [AppleDevice] = []
        var xcrun = "/usr/bin/true"
        var readTeams: @Sendable () -> [SigningTeam] = { [] }
        func deviceName(_ udid: String) -> String { "iPhone" }
        nonisolated func askCopy(_ plan: ShellCopyPlan) -> ShellCopyDecision { .skip }
        nonisolated func setWaiting(_ on: Bool) {}
        nonisolated var waitCancelled: Bool { false }
        func copyEnded() {}
    }

    private final class StubTransport: EngineTransport, @unchecked Sendable {
        var archivesByURL: [URL: URL] = [:]
        var shouldSucceed = true

        func data(from url: URL) -> EngineFetch<Data> {
            .failed
        }

        func download(from url: URL, to destination: URL) -> Bool {
            download(from: url, to: destination, progress: nil)
        }

        func download(from url: URL, to destination: URL, progress: (@Sendable (Int64, Int64?) -> Void)?) -> Bool {
            guard shouldSucceed, let src = archivesByURL[url], let payload = try? Data(contentsOf: src) else {
                return false
            }
            let total = Int64(payload.count)
            progress?(total / 2, total)
            do {
                try payload.write(to: destination)
            } catch {
                return false
            }
            progress?(total, total)
            return true
        }
    }

    private var defaults: UserDefaults!
    private var temporary: URL!
    private var repo: FakeRepo!
    private let deps = FakeDeps()
    private let engine = FakeEngine()
    private let devices = FakeDevices()
    private let runner = FakeProcessRunner()
    private let localizer = Localizer(.en)
    private var originalMNGEnabled = true
    private var originalS2ArmEnabled = true

    override func setUpWithError() throws {
        originalMNGEnabled = MacNativeGamesBuilder.featureEnabled
        originalS2ArmEnabled = S2ArmBuilder.featureEnabled
        MacNativeGamesBuilder.featureEnabled = true
        S2ArmBuilder.featureEnabled = true
        defaults = TestDefaults.make("nxmodel-upstream-download-tests")
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("upstream-dl-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        repo = FakeRepo(path: temporary.appendingPathComponent("missing-repo").path)
    }

    override func tearDownWithError() throws {
        MacNativeGamesBuilder.featureEnabled = originalMNGEnabled
        S2ArmBuilder.featureEnabled = originalS2ArmEnabled
        try? FileManager.default.removeItem(at: temporary)
    }

    private func makeStore(transport: EngineTransport = StubTransport()) -> BuildStore {
        let store = BuildStore(
            localizer: localizer,
            runner: runner,
            repo: repo,
            deps: deps,
            engine: engine,
            devices: devices,
            defaults: defaults
        )
        store.home = temporary.path
        store.upstreamTransport = transport
        return store
    }

    private func makeZip(of folder: URL, name: String) throws -> URL {
        let out = temporary.appendingPathComponent(name)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = ["-c", "-k", "--keepParent", folder.path, out.path]
        try proc.run()
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0)
        return out
    }

    private func makeS2ArmZip() throws -> URL {
        let dir = temporary.appendingPathComponent("S2Arm-main", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("pack/jobs"), withIntermediateDirectories: true)
        try Data("#!/usr/bin/env python3\n".utf8).write(to: dir.appendingPathComponent("pack/jobs/main.py"))
        try fm.createDirectory(at: dir.appendingPathComponent("runtime/rewriter"), withIntermediateDirectories: true)
        try Data("/* rewriter */\n".utf8).write(to: dir.appendingPathComponent("runtime/rewriter/rewriter.c"))
        try fm.createDirectory(at: dir.appendingPathComponent("pack/oneclick"), withIntermediateDirectories: true)
        try Data("#!/bin/bash\n".utf8).write(to: dir.appendingPathComponent("pack/oneclick/oneclick.sh"))
        return try makeZip(of: dir, name: "s2arm-archive.zip")
    }

    private func makeMNGZip() throws -> URL {
        let dir = temporary.appendingPathComponent("MacNativeGames-main", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("games/totk"), withIntermediateDirectories: true)
        try Data("#!/usr/bin/env python3\n".utf8).write(to: dir.appendingPathComponent("build_app.py"))
        return try makeZip(of: dir, name: "mng-archive.zip")
    }

    func testDefaultBuiltInNxnativeAndLockedUninstalledEngines() {
        let store = makeStore()
        XCTAssertEqual(store.buildUpstream, .nxnative)
        XCTAssertEqual(store.upstreamState(.nxnative), .builtIn)
        XCTAssertEqual(store.upstreamState(.macNativeGames), .notInstalled)
        XCTAssertEqual(store.upstreamState(.s2arm), .notInstalled)
        XCTAssertTrue(store.canSelectUpstream(.nxnative))
        XCTAssertFalse(store.canSelectUpstream(.macNativeGames))
        XCTAssertFalse(store.canSelectUpstream(.s2arm))

        store.selectUpstream(.s2arm)
        XCTAssertEqual(store.buildUpstream, .nxnative)
    }

    func testDownloadExtractAndAutoSwitchEngines() async throws {
        let transport = StubTransport()
        let s2URL = try XCTUnwrap(UpstreamEngineStore.archiveURL(for: .s2arm))
        let mngURL = try XCTUnwrap(UpstreamEngineStore.archiveURL(for: .macNativeGames))
        transport.archivesByURL[s2URL] = try makeS2ArmZip()
        transport.archivesByURL[mngURL] = try makeMNGZip()

        let store = makeStore(transport: transport)
        store.target = BuildTarget.ios
        XCTAssertEqual(store.upstreamAutoSwitchRevision, 0)

        await store.downloadUpstream(.s2arm).value
        XCTAssertTrue(store.s2armInstalled)
        XCTAssertEqual(store.upstreamState(.s2arm), .installed)
        XCTAssertTrue(store.canSelectUpstream(.s2arm))
        XCTAssertEqual(store.buildUpstream, .s2arm, "Completed download must auto-switch to the newly installed engine")
        XCTAssertEqual(store.upstreamAutoSwitchRevision, 1)
        XCTAssertEqual(store.target, BuildTarget.ios)
        XCTAssertTrue(store.usesExternalUpstreamRepo)

        await store.downloadUpstream(.macNativeGames).value
        XCTAssertTrue(store.macNativeGamesInstalled)
        XCTAssertEqual(store.upstreamState(.macNativeGames), .installed)
        XCTAssertEqual(store.buildUpstream, .macNativeGames)
        XCTAssertEqual(store.upstreamAutoSwitchRevision, 2)
        XCTAssertEqual(store.target, BuildTarget.mac)

        store.selectUpstream(.nxnative)
        XCTAssertEqual(store.buildUpstream, .nxnative)
    }

    func testDownloadCompletionWhileBuildRunningInstallsWithoutAutoSwitching() async throws {
        final class GatedTransport: EngineTransport, @unchecked Sendable {
            let sourceZip: URL
            let entered = DispatchSemaphore(value: 0)
            let proceed = DispatchSemaphore(value: 0)

            init(sourceZip: URL) {
                self.sourceZip = sourceZip
            }

            func data(from url: URL) -> EngineFetch<Data> { .failed }

            func download(from url: URL, to destination: URL) -> Bool {
                entered.signal()
                proceed.wait()
                guard let data = try? Data(contentsOf: sourceZip) else { return false }
                return (try? data.write(to: destination)) != nil
            }
        }

        let gated = GatedTransport(sourceZip: try makeS2ArmZip())
        let store = makeStore(transport: gated)
        let task = store.downloadUpstream(.s2arm)
        await Task.detached {
            _ = gated.entered.wait(timeout: .now() + 5)
        }.value

        store.running = true
        gated.proceed.signal()
        await task.value

        XCTAssertTrue(store.s2armInstalled)
        XCTAssertEqual(store.upstreamState(.s2arm), .installed)
        XCTAssertEqual(store.buildUpstream, .nxnative, "Must not switch active engine while a build is running")
        XCTAssertEqual(store.upstreamAutoSwitchRevision, 0)
    }

    func testCancelUpstreamDownloadResetsStateImmediatelyAndCleansStaging() async throws {
        final class CancellableBlockingTransport: EngineTransport, @unchecked Sendable {
            let sourceZip: URL
            let entered = DispatchSemaphore(value: 0)
            let released = DispatchSemaphore(value: 0)

            init(sourceZip: URL) {
                self.sourceZip = sourceZip
            }

            func data(from url: URL) -> EngineFetch<Data> { .failed }

            func download(from url: URL, to destination: URL) -> Bool { false }

            func download(
                from url: URL,
                to destination: URL,
                progress: (@Sendable (Int64, Int64?) -> Void)?,
                shouldCancel: (@Sendable () -> Bool)?
            ) -> Bool {
                progress?(1024, 4096)
                entered.signal()
                released.wait()
                if shouldCancel?() == true {
                    return false
                }
                guard let data = try? Data(contentsOf: sourceZip) else { return false }
                return (try? data.write(to: destination)) != nil
            }
        }

        let blocking = CancellableBlockingTransport(sourceZip: try makeS2ArmZip())
        let store = makeStore(transport: blocking)
        let task = store.downloadUpstream(.s2arm)
        XCTAssertTrue(store.upstreamState(.s2arm).isBusy)

        await Task.detached {
            _ = blocking.entered.wait(timeout: .now() + 5)
        }.value

        store.cancelUpstreamDownload(.s2arm)
        XCTAssertEqual(store.upstreamState(.s2arm), .notInstalled, "Cancel must immediately reset UI state to .notInstalled")

        blocking.released.signal()
        await task.value

        XCTAssertFalse(store.s2armInstalled)
        XCTAssertEqual(store.upstreamState(.s2arm), .notInstalled)
        XCTAssertEqual(store.buildUpstream, .nxnative)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: store.upstreamsRootURL.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "Cancelled download must leave zero leftover staging files: \(leftovers)")
    }

    func testStaleGenerationDoesNotOverwriteRestartedDownload() async throws {
        final class TwoGenerationTransport: EngineTransport, @unchecked Sendable {
            let sourceZip: URL
            private let lock = NSLock()
            private var callIndex = 0
            let firstEntered = DispatchSemaphore(value: 0)
            let releaseFirst = DispatchSemaphore(value: 0)

            init(sourceZip: URL) {
                self.sourceZip = sourceZip
            }

            func data(from url: URL) -> EngineFetch<Data> { .failed }

            func download(from url: URL, to destination: URL) -> Bool {
                lock.lock()
                callIndex += 1
                let idx = callIndex
                lock.unlock()
                if idx == 1 {
                    firstEntered.signal()
                    releaseFirst.wait()
                    return false
                }
                guard let data = try? Data(contentsOf: sourceZip) else { return false }
                return (try? data.write(to: destination)) != nil
            }
        }

        let transport = TwoGenerationTransport(sourceZip: try makeS2ArmZip())
        let store = makeStore(transport: transport)
        let firstTask = store.downloadUpstream(.s2arm)
        await Task.detached {
            _ = transport.firstEntered.wait(timeout: .now() + 5)
        }.value

        store.cancelUpstreamDownload(.s2arm)
        let secondTask = store.downloadUpstream(.s2arm)
        await secondTask.value
        XCTAssertTrue(store.s2armInstalled)
        XCTAssertEqual(store.buildUpstream, .s2arm)

        transport.releaseFirst.signal()
        await firstTask.value
        XCTAssertTrue(store.s2armInstalled)
        XCTAssertEqual(store.upstreamState(.s2arm), .installed)
        XCTAssertEqual(store.buildUpstream, .s2arm)
    }

    func testFailedDownloadSetsRetryStateAndRecoversOnRetry() async throws {
        let transport = StubTransport()
        let s2URL = try XCTUnwrap(UpstreamEngineStore.archiveURL(for: .s2arm))
        transport.archivesByURL[s2URL] = try makeS2ArmZip()
        transport.shouldSucceed = false

        let store = makeStore(transport: transport)
        await store.downloadUpstream(.s2arm).value
        XCTAssertFalse(store.s2armInstalled)
        XCTAssertEqual(store.upstreamState(.s2arm), .failed(.download))
        XCTAssertFalse(store.canSelectUpstream(.s2arm))

        transport.shouldSucceed = true
        await store.downloadUpstream(.s2arm).value
        XCTAssertTrue(store.s2armInstalled)
        XCTAssertEqual(store.upstreamState(.s2arm), .installed)
        XCTAssertEqual(store.buildUpstream, .s2arm)
    }

    func testAdoptInstalledUpstreamsDiscoversManagedTreeAndResetsMissingSelection() throws {
        let store = makeStore()
        let engineStore = UpstreamEngineStore(root: store.upstreamsRootURL)
        let installedS2 = try engineStore.install(zip: try makeS2ArmZip(), kind: .s2arm)

        store.buildUpstream = .macNativeGames
        store.adoptInstalledUpstreams()

        XCTAssertEqual(store.buildUpstream, .nxnative)
        XCTAssertTrue(store.s2armInstalled)
        XCTAssertEqual(URL(fileURLWithPath: store.s2armPath).standardizedFileURL, installedS2.standardizedFileURL)
    }
}
