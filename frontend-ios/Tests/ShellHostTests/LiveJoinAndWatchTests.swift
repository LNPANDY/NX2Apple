import Foundation
import ShellUI
import Testing
#if canImport(UIKit)
import UIKit
#endif
@testable import ShellHost

private final class ConcurrentJoinTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let pausedSem = DispatchSemaphore(value: 0)
    private let releaseSem = DispatchSemaphore(value: 0)
    private var paused = false
    private var released = false
    private var activeCalls = 0
    private var maxConcurrentCalls = 0
    private var observedFiles: [String] = []

    func onProgress(_ progress: DataParts.Progress, pauseFile: String) {
        var shouldPause = false
        lock.lock()
        activeCalls += 1
        if activeCalls > maxConcurrentCalls {
            maxConcurrentCalls = activeCalls
        }
        observedFiles.append(progress.file)
        if !paused && progress.file == pauseFile && progress.doneBytes > 0 && progress.doneBytes < progress.totalBytes {
            paused = true
            shouldPause = true
        }
        lock.unlock()

        if shouldPause {
            pausedSem.signal()
            releaseSem.wait()
        }

        lock.lock()
        activeCalls -= 1
        lock.unlock()
    }

    func waitUntilPaused(timeout: TimeInterval = 5.0) async -> Bool {
        let sem = pausedSem
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: sem.wait(timeout: .now() + timeout) == .success)
            }
        }
    }

    func release() {
        lock.lock()
        let already = released
        released = true
        lock.unlock()
        if !already {
            releaseSem.signal()
        }
    }

    var peakConcurrency: Int {
        lock.lock()
        defer { lock.unlock() }
        return maxConcurrentCalls
    }

    var files: [String] {
        lock.lock()
        defer { lock.unlock() }
        return observedFiles
    }
}

private final class ActiveGameFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var id: String?

    init(_ initial: String? = nil) {
        self.id = initial
    }

    var current: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return id
        }
        set {
            lock.lock()
            id = newValue
            lock.unlock()
        }
    }
}

@MainActor @Suite(.serialized) struct LiveJoinAndWatchTests {
    private func stripBundledMSL(for id: String = Fixtures.orbit, in box: Sandbox) {
        let framework = box.games.appendingPathComponent(id + "/DmGame.framework")
        try? FileManager.default.removeItem(at: framework.appendingPathComponent("msl"))
    }

    private func installMatchedIdentity(for imgURL: URL, id: String = Fixtures.orbit, in box: Sandbox) throws {
        let identity = try #require(RomfsIdentity.ofImage(at: imgURL))
        let hex = String(format: "%016llx", identity.index)
        let manifestURL = box.games.appendingPathComponent(id).appendingPathComponent("game.manifest.json")
        let manifestText = try String(contentsOf: manifestURL, encoding: .utf8)
            .replacingOccurrences(of: "\"DMROMFSID1 fixture\"",
                                  with: "\"DMROMFSID1 title=\(id) version=1.0 build=v0 size=\(identity.size) index=\(hex)\"")
        try Data(manifestText.utf8).write(to: manifestURL)
    }

    private func writeSplitParts(_ data: Data, as fileName: String, partSize: Int, in dir: URL, only indices: [Int]? = nil) throws {
        let fm = FileManager.default
        let count = (data.count + partSize - 1) / partSize
        for i in indices ?? Array(0..<count) {
            let start = i * partSize
            let end = min(data.count, start + partSize)
            let chunk = Data(data[start..<end])
            let name = String(format: "%@.nxpart.%04d.%04d", fileName, i, count)
            let url = dir.appendingPathComponent(name)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try chunk.write(to: url, options: .atomic)
        }
    }

    private func partLeftovers(in dir: URL) -> [String] {
        ((FileManager.default.enumerator(atPath: dir.path)?.allObjects as? [String]) ?? [])
            .filter { $0.contains(".nxpart.") || $0.hasSuffix(".nxjoin") }
    }

    private func prepareStaleRomfsSandbox() throws -> (box: Sandbox, gameDir: URL, staleImage: Data, freshImage: Data, partSize: Int) {
        let box = try Sandbox()
        stripBundledMSL(in: box)
        let base = ShellDataFolderTests.dmromfs(ShellDataFolderTests.indexA)
        let staleImage = ShellDataFolderTests.dmromfsWithTrailer(base, gfxAPI: 1, chain: "b-stale0")
        let freshImage = ShellDataFolderTests.dmromfsWithTrailer(base, gfxAPI: 1, chain: "b-3f9a2c")
        let gameDir = box.appData.appendingPathComponent(Fixtures.orbit, isDirectory: true)
        try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)
        let imgURL = gameDir.appendingPathComponent("romfs.img")
        try staleImage.write(to: imgURL)
        try installMatchedIdentity(for: imgURL, in: box)
        let partSize = (freshImage.count + 1) / 2
        return (box, gameDir, staleImage, freshImage, partSize)
    }

    /// Case 1: Calling `reload()` after cold start joins `.nxpart` split files, atomically replaces a stale `romfs.img`,
    /// cleans up parts, and updates game state from `.needsDataUpdate(staleChain: true)` to `.playable`.
    @Test func reloadAfterStartupJoinsSplitPartsAndReplacesStaleRomfsImage() async throws {
        let env = try prepareStaleRomfsSandbox()
        var cfg = env.box.config()
        cfg.joinPartSize = Int64(env.partSize)
        let launcher = RecordingLauncher()

        let model = ShellHostModel(config: cfg, launcher: launcher)
        await model.waitForStartupTasks()
        await model.waitForDataChecks()

        let initial = try #require(model.details.first { $0.id == Fixtures.orbit })
        #expect(initial.game.state == .needsDataUpdate(staleChain: true))

        try writeSplitParts(env.freshImage, as: "romfs.img", partSize: env.partSize, in: env.gameDir)
        model.reload()
        await model.waitForStartupTasks()
        await model.waitForDataChecks()

        let imgURL = env.gameDir.appendingPathComponent("romfs.img")
        #expect(partLeftovers(in: env.gameDir).isEmpty)
        #expect(try Data(contentsOf: imgURL) == env.freshImage)
        let updated = try #require(model.details.first { $0.id == Fixtures.orbit })
        #expect(updated.game.state == .playable)
        #expect(updated.dataNote.isEmpty)

        await model.playNow(Fixtures.orbit)
        let launched = try #require(launcher.launched.first)
        #expect(launched.usesEmbeddedShaderTrailer)
    }

    /// Case 2: While staying on the library screen without calling `reload()`, writing part 0 leaves the stale image
    /// untouched, and writing the final part triggers automatic debounced join + UI refresh to `.playable`.
    @Test func foregroundDirectoryWatcherAutoJoinsPartsWithoutManualReload() async throws {
        let env = try prepareStaleRomfsSandbox()
        var cfg = env.box.config()
        cfg.joinPartSize = Int64(env.partSize)

        let model = ShellHostModel(config: cfg)
        await model.waitForStartupTasks()
        await model.waitForDataChecks()
        #expect(model.details.first { $0.id == Fixtures.orbit }?.game.state == .needsDataUpdate(staleChain: true))

        let imgURL = env.gameDir.appendingPathComponent("romfs.img")

        // Write only the first part (0000 of 0002): watcher fires after debounce, joinAll skips incomplete set safely.
        try writeSplitParts(env.freshImage, as: "romfs.img", partSize: env.partSize, in: env.gameDir, only: [0])
        try await Task.sleep(nanoseconds: 900_000_000)
        await model.waitForStartupTasks()

        #expect(model.details.first { $0.id == Fixtures.orbit }?.game.state == .needsDataUpdate(staleChain: true))
        #expect(try Data(contentsOf: imgURL) == env.staleImage)
        #expect(FileManager.default.fileExists(atPath: env.gameDir.appendingPathComponent("romfs.img.nxpart.0000.0002").path))

        // Write the final part (0001 of 0002) without calling reload(): watcher auto-joins and refreshes state.
        try writeSplitParts(env.freshImage, as: "romfs.img", partSize: env.partSize, in: env.gameDir, only: [1])

        for _ in 0..<250 {
            if model.details.first(where: { $0.id == Fixtures.orbit })?.game.state == .playable { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        await model.waitForStartupTasks()

        #expect(model.details.first { $0.id == Fixtures.orbit }?.game.state == .playable)
        #expect(partLeftovers(in: env.gameDir).isEmpty)
        #expect(try Data(contentsOf: imgURL) == env.freshImage)
    }

    /// Case 3: Rapid `reload()` calls and new split files arriving mid-join never launch concurrent `DataParts.joinAll`
    /// runs; the active `.nxjoin` completes intact and pending work drains serially right after.
    @Test func serialJoinPipelinePreventsConcurrentReentrancyAndDrainsPendingWork() async throws {
        let env = try prepareStaleRomfsSandbox()
        let romfsPartSize = max(1, (env.freshImage.count + 3) / 4)
        let aocData = Data(repeating: 0x5A, count: romfsPartSize + 17) // 2 parts with romfsPartSize

        let tracker = ConcurrentJoinTracker()
        defer { tracker.release() }

        var cfg = env.box.config()
        cfg.joinPartSize = Int64(romfsPartSize)
        cfg.onJoinProgress = { progress in
            tracker.onProgress(progress, pauseFile: "romfs.img")
        }

        let model = ShellHostModel(config: cfg)
        await model.waitForStartupTasks()
        await model.waitForDataChecks()
        #expect(model.details.first { $0.id == Fixtures.orbit }?.game.state == .needsDataUpdate(staleChain: true))

        // Start a join pass for romfs.img and hold it mid-flight while .nxjoin is open.
        try writeSplitParts(env.freshImage, as: "romfs.img", partSize: romfsPartSize, in: env.gameDir)
        model.reload()

        let pausedMidway = await tracker.waitUntilPaused()
        #expect(pausedMidway)
        #expect(tracker.peakConcurrency == 1)

        // While the first join pass is mid-flight, hammer reload() and drop another split file set (aoc/1.img).
        try writeSplitParts(aocData, as: "aoc/1.img", partSize: romfsPartSize, in: env.gameDir)
        for _ in 0..<5 {
            model.reload()
        }
        try await Task.sleep(nanoseconds: 150_000_000)

        // No second concurrent join pass may have started; aoc/1.img must wait for the pending serial pass.
        #expect(tracker.peakConcurrency == 1)
        #expect(!tracker.files.contains("1.img"))
        #expect(!FileManager.default.fileExists(atPath: env.gameDir.appendingPathComponent("aoc/1.img").path))

        // Release the first pass; the pending pass must run right after and finish aoc/1.img cleanly.
        tracker.release()
        await model.waitForStartupTasks()
        await model.waitForDataChecks()

        #expect(tracker.peakConcurrency == 1)
        #expect(partLeftovers(in: env.gameDir).isEmpty)
        #expect(try Data(contentsOf: env.gameDir.appendingPathComponent("romfs.img")) == env.freshImage)
        #expect(try Data(contentsOf: env.gameDir.appendingPathComponent("aoc/1.img")) == aocData)

        let detail = try #require(model.details.first { $0.id == Fixtures.orbit })
        #expect(detail.game.state == .playable)
        #expect(detail.dlc == hostText("1 additional content pack"))
    }

    /// Case 4: Watcher pauses background join while a game is running and resumes joining upon returning to the library.
    @Test func watcherDefersJoinWhileGameIsRunningAndJoinsOnReturnToLibrary() async throws {
        let env = try prepareStaleRomfsSandbox()
        let activeGame = ActiveGameFlag(Fixtures.orbit)
        var cfg = env.box.config()
        cfg.joinPartSize = Int64(env.partSize)
        cfg.activeRunningGameID = { activeGame.current }

        let model = ShellHostModel(config: cfg)
        await model.waitForStartupTasks()
        #expect(model.details.first { $0.id == Fixtures.orbit }?.game.state == .needsDataUpdate(staleChain: true))

        // Drop complete parts while a game is actively running -> must stay deferred.
        try writeSplitParts(env.freshImage, as: "romfs.img", partSize: env.partSize, in: env.gameDir)
        try await Task.sleep(nanoseconds: 900_000_000)
        #expect(FileManager.default.fileExists(atPath: env.gameDir.appendingPathComponent("romfs.img.nxpart.0000.0002").path))
        #expect(model.details.first { $0.id == Fixtures.orbit }?.game.state == .needsDataUpdate(staleChain: true))

        // Exit the game and notify return to library -> deferred join runs automatically.
        activeGame.current = nil
        NotificationCenter.default.post(name: ShellHostModel.didReturnToLibraryNotification, object: nil)

        for _ in 0..<200 {
            if model.details.first(where: { $0.id == Fixtures.orbit })?.game.state == .playable { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        await model.waitForStartupTasks()

        #expect(model.details.first { $0.id == Fixtures.orbit }?.game.state == .playable)
        #expect(partLeftovers(in: env.gameDir).isEmpty)
        #expect(try Data(contentsOf: env.gameDir.appendingPathComponent("romfs.img")) == env.freshImage)
    }

    /// Case 5: Dropping a hot-pushed staged framework with `.ready` under `Documents/Frameworks/` triggers automatic
    /// foreground promotion and refreshes the game title without manual `reload()`.
    @Test func foregroundWatcherAutoPromotesReadyHotFramework() async throws {
        let box = try Sandbox()
        let hotRoot = box.root.appendingPathComponent("Documents/Frameworks", isDirectory: true)
        try FileManager.default.createDirectory(at: hotRoot, withIntermediateDirectories: true)

        var cfg = box.config()
        cfg.hotFrameworksRoot = hotRoot

        let model = ShellHostModel(config: cfg)
        await model.waitForStartupTasks()
        #expect(model.details.first { $0.id == Fixtures.orbit }?.game.title == "Orbit Fixture")

        // Stage a newer hot framework and write `.ready` last without calling reload().
        let staging = hotRoot.appendingPathComponent(".staging-\(Fixtures.orbit)-live", isDirectory: true)
        let fwName = "DmGame\(Fixtures.orbit).framework"
        let exeName = "DmGame\(Fixtures.orbit)"
        let stagedFW = staging.appendingPathComponent(fwName, isDirectory: true)
        let bundledDir = box.games.appendingPathComponent(Fixtures.orbit)
        try FileManager.default.createDirectory(at: stagedFW.appendingPathComponent("dm", isDirectory: true), withIntermediateDirectories: true)
        let manifest = try String(contentsOf: bundledDir.appendingPathComponent("game.manifest.json"), encoding: .utf8)
            .replacingOccurrences(of: "\"schema\": 1,", with: "\"schema\": 1,\n  \"built_at\": \"2099-01-01T00:00:00Z\",")
            .replacingOccurrences(of: "Orbit Fixture", with: "Orbit Live Hot")
            .replacingOccurrences(of: "\"DmGame.framework\"", with: "\"\(fwName)\"")
            .replacingOccurrences(of: "\"DmGame\"", with: "\"\(exeName)\"")
        try Data(manifest.utf8).write(to: stagedFW.appendingPathComponent("game.manifest.json"))
        try FileManager.default.copyItem(at: bundledDir.appendingPathComponent("launcher.json"),
                                         to: stagedFW.appendingPathComponent("dm/launcher.json"))
        try Data("macho".utf8).write(to: stagedFW.appendingPathComponent(exeName))
        let footprint = try #require(GameCatalogue.frameworkFootprint(at: stagedFW))
        let ready = HotFrameworkReady(titleID: Fixtures.orbit, files: footprint.files, bytes: footprint.bytes)
        try JSONEncoder().encode(ready).write(to: staging.appendingPathComponent(HotFrameworkReady.fileName), options: .atomic)

        for _ in 0..<250 {
            if model.details.first(where: { $0.id == Fixtures.orbit })?.game.title == "Orbit Live Hot" { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        await model.waitForStartupTasks()

        #expect(model.details.first { $0.id == Fixtures.orbit }?.game.title == "Orbit Live Hot")
        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }

    /// Case 6: `GameDirectoryWatcher` dynamically tracks child directory creation/removal and releases every descriptor on stop.
    @Test func directoryWatcherTracksDynamicSubdirectoriesAndClosesAllDescriptorsOnStop() async throws {
        let box = try Sandbox()
        let watcher = GameDirectoryWatcher(appDataRoot: box.appData, hotFrameworksRoot: nil, debounceInterval: 0.05) { _ in }
        watcher.start()
        await watcher.waitUntilReady()

        let baseCount = watcher.activeDescriptorCount
        #expect(baseCount >= 2) // Documents/ and Documents/games/

        let child = box.appData.appendingPathComponent(Fixtures.orbit, isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        for _ in 0..<100 where watcher.activeDescriptorCount <= baseCount {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(watcher.activeDescriptorCount == baseCount + 1)

        try FileManager.default.removeItem(at: child)
        for _ in 0..<100 where watcher.activeDescriptorCount != baseCount {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(watcher.activeDescriptorCount == baseCount)

        watcher.stop()
        await watcher.waitUntilReady()
        #expect(watcher.activeDescriptorCount == 0)
    }

    #if canImport(UIKit)
    /// Case 7 (iOS UIKit): Posting `UIApplication.willEnterForegroundNotification` triggers reload + serial join
    /// when returning from background with newly landed `.nxpart` files.
    @Test func willEnterForegroundNotificationJoinsSplitPartsAndRefreshesState() async throws {
        let env = try prepareStaleRomfsSandbox()
        var cfg = env.box.config()
        cfg.joinPartSize = Int64(env.partSize)

        let model = ShellHostModel(config: cfg)
        await model.waitForStartupTasks()
        await model.waitForDataChecks()
        #expect(model.details.first { $0.id == Fixtures.orbit }?.game.state == .needsDataUpdate(staleChain: true))

        try writeSplitParts(env.freshImage, as: "romfs.img", partSize: env.partSize, in: env.gameDir)
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        await model.waitForStartupTasks()
        await model.waitForDataChecks()

        #expect(partLeftovers(in: env.gameDir).isEmpty)
        #expect(try Data(contentsOf: env.gameDir.appendingPathComponent("romfs.img")) == env.freshImage)
        #expect(model.details.first { $0.id == Fixtures.orbit }?.game.state == .playable)
    }
    #endif
}
