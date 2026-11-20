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

    func testCheckUpstreamUpdatesCachesSuccessSkipsFailedCacheAndClearsAfterUpdate() async throws {
        final class VersionedTransport: EngineTransport, @unchecked Sendable {
            var dataByURL: [URL: EngineFetch<Data>] = [:]
            var archivesByURL: [URL: URL] = [:]
            private let lock = NSLock()
            var dataHits: [URL: Int] = [:]

            func data(from url: URL) -> EngineFetch<Data> {
                lock.lock()
                dataHits[url, default: 0] += 1
                let reply = dataByURL[url] ?? .failed
                lock.unlock()
                return reply
            }

            func download(from url: URL, to destination: URL) -> Bool {
                guard let src = archivesByURL[url], let payload = try? Data(contentsOf: src) else { return false }
                return (try? payload.write(to: destination)) != nil
            }
        }

        let oldSHA = "1111111111111111111111111111111111111111"
        let newSHA = "2222222222222222222222222222222222222222"
        let s2RefsURL = try XCTUnwrap(UpstreamVersion.infoRefsURL(for: .s2arm))
        let s2ArchiveURL = try XCTUnwrap(UpstreamEngineStore.archiveURL(for: .s2arm))

        // Build zip with EOCD comment = newSHA via python3
        let newZip = temporary.appendingPathComponent("s2arm-v058.zip")
        let s2Dir = temporary.appendingPathComponent("S2Arm-v058", isDirectory: true)
        try FileManager.default.createDirectory(at: s2Dir.appendingPathComponent("pack/jobs"), withIntermediateDirectories: true)
        try Data("#!/usr/bin/env python3\n".utf8).write(to: s2Dir.appendingPathComponent("pack/jobs/main.py"))
        try FileManager.default.createDirectory(at: s2Dir.appendingPathComponent("runtime/rewriter"), withIntermediateDirectories: true)
        try Data("/* rewriter */\n".utf8).write(to: s2Dir.appendingPathComponent("runtime/rewriter/rewriter.c"))
        try FileManager.default.createDirectory(at: s2Dir.appendingPathComponent("pack/oneclick"), withIntermediateDirectories: true)
        try Data("#!/bin/bash\n".utf8).write(to: s2Dir.appendingPathComponent("pack/oneclick/oneclick.sh"))
        let py = Process()
        py.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        py.arguments = ["-c", """
        import os, sys, zipfile
        src, dst, sha = sys.argv[1], sys.argv[2], sys.argv[3]
        with zipfile.ZipFile(dst, "w") as zf:
            for base, _, files in os.walk(src):
                for fn in files:
                    full = os.path.join(base, fn)
                    zf.write(full, os.path.join("S2Arm-main", os.path.relpath(full, src)))
            zf.comment = sha.encode("utf-8")
        """, s2Dir.path, newZip.path, newSHA]
        try py.run()
        py.waitUntilExit()
        XCTAssertEqual(py.terminationStatus, 0)

        let transport = VersionedTransport()
        transport.archivesByURL[s2ArchiveURL] = newZip

        let store = makeStore(transport: transport)
        let engineStore = UpstreamEngineStore(root: store.upstreamsRootURL)
        let installed = try engineStore.install(
            zip: try makeS2ArmZip(),
            kind: .s2arm,
            remoteInfo: UpstreamRemoteInfo(kind: .s2arm, commit: oldSHA, version: "v0.5.7", date: "2026.11.10")
        )
        store.s2armPath = installed.path

        // 1. Failed fetch must NOT be cached.
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        await store.checkUpstreamUpdates(kinds: [.s2arm], now: t0).value
        XCTAssertFalse(store.upstreamHasUpdate(.s2arm))
        XCTAssertEqual(transport.dataHits[s2RefsURL], 1)

        // 2. Subsequent call retries immediately and detects the update via Git Smart HTTP info/refs.
        transport.dataByURL[s2RefsURL] = .ok(Data((
            "001e# service=git-upload-pack\n"
            + "0000003d\(newSHA) refs/heads/main\n"
            + "003e\(newSHA) refs/tags/v0.5.8\n"
        ).utf8))
        await store.checkUpstreamUpdates(kinds: [.s2arm], now: t0.addingTimeInterval(5)).value
        XCTAssertEqual(transport.dataHits[s2RefsURL], 2)
        XCTAssertTrue(store.upstreamHasUpdate(.s2arm))
        XCTAssertEqual(store.upstreamVersionBadge(.s2arm), "v0.5.7 ↑")
        XCTAssertEqual(store.upstreamUpdateTooltip(.s2arm), "Update available: v0.5.8 (2222222)")

        // 3. Within 10-minute TTL, cached result avoids a repeat network call.
        await store.checkUpstreamUpdates(kinds: [.s2arm], now: t0.addingTimeInterval(300)).value
        XCTAssertEqual(transport.dataHits[s2RefsURL], 2)

        // 4. Updating S2Arm writes the new receipt and clears hasUpdate.
        await store.downloadUpstream(.s2arm).value
        XCTAssertFalse(store.upstreamHasUpdate(.s2arm))
        XCTAssertEqual(store.upstreamVersionBadge(.s2arm), "v0.5.8")
        XCTAssertNil(store.upstreamUpdateTooltip(.s2arm))

        // 5. Same-commit receipt whose version was a bare short SHA auto-upgrades to semantic tag and persists.
        let s2DirURL = URL(fileURLWithPath: store.s2armPath, isDirectory: true)
        try UpstreamVersion.writeReceipt(
            UpstreamVersionReceipt(commit: newSHA, version: "2222222", installedAt: "2026.11.19"),
            to: s2DirURL
        )
        store.refreshUpstreamLocalVersion(for: .s2arm)
        XCTAssertEqual(store.upstreamVersionBadge(.s2arm), "2222222")

        transport.dataByURL[s2RefsURL] = .ok(Data("003d\(newSHA) refs/heads/main\n003e\(oldSHA) refs/tags/v0.5.8\n".utf8))
        await store.checkUpstreamUpdates(kinds: [.s2arm], force: true, now: t0.addingTimeInterval(900)).value
        XCTAssertEqual(store.upstreamVersionBadge(.s2arm), "v0.5.8+")
        XCTAssertFalse(store.upstreamHasUpdate(.s2arm))
        let deadline = Date().addingTimeInterval(2)
        while UpstreamVersion.readReceipt(in: s2DirURL)?.version != "v0.5.8+" && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(UpstreamVersion.readReceipt(in: s2DirURL)?.version, "v0.5.8+")
    }
}
