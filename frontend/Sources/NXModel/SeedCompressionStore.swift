import Combine
import Darwin
import Foundation
@preconcurrency import NXCore

/// Manages startup/manual scanning and zstd compression of legacy `metal-sources/b-*.img` build seeds.
@MainActor package final class SeedCompressionStore: ObservableObject {
    package static let promptDismissedKey = "seedCompressionPromptDismissed"

    package enum ItemStatus: String, Equatable, CaseIterable, Sendable {
        case waiting
        case compressing
        case done
        case failed
    }

    package struct ItemProgress: Equatable, Identifiable, Sendable {
        package var titleID: String
        package var appName: String
        package var beforeBytes: Int64
        package var afterBytes: Int64
        package var savedBytes: Int64
        package var filesCompressed: Int
        package var status: ItemStatus
        package var error: String?

        package var id: String { titleID }

        package init(
            titleID: String,
            appName: String = "",
            beforeBytes: Int64,
            afterBytes: Int64 = 0,
            savedBytes: Int64 = 0,
            filesCompressed: Int = 0,
            status: ItemStatus = .waiting,
            error: String? = nil
        ) {
            self.titleID = titleID
            self.appName = appName
            self.beforeBytes = beforeBytes
            self.afterBytes = afterBytes
            self.savedBytes = savedBytes
            self.filesCompressed = filesCompressed
            self.status = status
            self.error = error
        }
    }

    package struct RunningState: Equatable, Sendable {
        package var totalGames: Int
        package var totalBytes: Int64
        package var processedBytes: Int64
        package var freedBytes: Int64
        package var currentIndex: Int
        package var currentTitleID: String
        package var currentName: String
        package var items: [ItemProgress]
        package var stopping: Bool

        package init(
            totalGames: Int,
            totalBytes: Int64,
            processedBytes: Int64 = 0,
            freedBytes: Int64 = 0,
            currentIndex: Int = 0,
            currentTitleID: String = "",
            currentName: String = "",
            items: [ItemProgress] = [],
            stopping: Bool = false
        ) {
            self.totalGames = totalGames
            self.totalBytes = totalBytes
            self.processedBytes = processedBytes
            self.freedBytes = freedBytes
            self.currentIndex = currentIndex
            self.currentTitleID = currentTitleID
            self.currentName = currentName
            self.items = items
            self.stopping = stopping
        }
    }

    package enum Phase: Equatable, Sendable {
        case prompt(SeedScanResult)
        case running(RunningState)
        case done(SeedCompressSummary)
    }

    package enum ScanState: Equatable, Sendable {
        case idle
        case scanning
        case ready(hasAnySeeds: Bool, scan: SeedScanResult)
        case failed(String)
    }

    @Published package var phase: Phase?
    @Published package private(set) var scanState: ScanState = .idle
    @Published package private(set) var isScanning = false
    @Published package private(set) var noneNoticeVisible = false
    @Published package private(set) var startError: String?

    package var promptDismissed: Bool {
        get { defaults.bool(forKey: Self.promptDismissedKey) }
        set { defaults.set(newValue, forKey: Self.promptDismissedKey) }
    }

    package var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    package var currentScan: SeedScanResult? {
        if case .ready(_, let scan) = scanState { return scan }
        return nil
    }

    package var hasUncompressedSeeds: Bool {
        currentScan?.hasUncompressed == true
    }

    package var zstdMissing: Bool {
        guard case .ready(_, let scan) = scanState else { return false }
        return !scan.zstdAvailable
    }

    private let runner: ProcessRunner
    private let repo: RepoLocation
    private let python: PythonLocation
    private let defaults: UserDefaults
    private let seedRoot: () -> String
    private let seedEnvironment: () -> [String: String]
    private let dotnetPath: () -> String
    private let buildRunning: () -> Bool
    private let canAutoPrompt: () -> Bool
    private let home: String
    private let findPython: @Sendable () -> String
    private let sendSignal: @Sendable (pid_t, Int32) -> Void

    private var scanGeneration: UInt64 = 0
    private var runGeneration: UInt64 = 0
    private var startupScanTriggered = false
    private var activeProcess: RunningProcess?
    private var stopRequested = false

    package init(
        runner: ProcessRunner,
        repo: RepoLocation,
        python: PythonLocation,
        defaults: UserDefaults = .standard,
        seedRoot: @escaping () -> String = { BuildSeedCache.defaultRoot() },
        seedEnvironment: @escaping () -> [String: String] = { [:] },
        dotnetPath: @escaping () -> String = { "" },
        buildRunning: @escaping () -> Bool = { false },
        canAutoPrompt: @escaping () -> Bool = { true },
        home: String = NSHomeDirectory(),
        findPython: (@Sendable () -> String)? = nil,
        sendSignal: (@Sendable (pid_t, Int32) -> Void)? = nil
    ) {
        self.runner = runner
        self.repo = repo
        self.python = python
        self.defaults = defaults
        self.seedRoot = seedRoot
        self.seedEnvironment = seedEnvironment
        self.dotnetPath = dotnetPath
        self.buildRunning = buildRunning
        self.canAutoPrompt = canAutoPrompt
        self.home = home
        self.findPython = findPython ?? { Toolchain.findPython().path }
        self.sendSignal = sendSignal ?? { pid, sig in _ = Darwin.kill(pid, sig) }
    }

    /// Triggers the startup scan at most once per store instance.
    package func scanOnStartupIfNeeded() {
        guard !startupScanTriggered else { return }
        startupScanTriggered = true
        _ = scan(autoPromptOnFind: true)
    }

    /// Scans `seedRoot` on a background queue; revalidates generation and active state before writing back.
    @discardableResult
    package func scan(autoPromptOnFind: Bool = false) -> Task<Void, Never> {
        scanGeneration &+= 1
        let gen = scanGeneration
        isScanning = true
        if case .idle = scanState {
            scanState = .scanning
        }
        noneNoticeVisible = false
        startError = nil

        let root = seedRoot()
        let repoPath = repo.path
        let py = resolvePython()
        let env = toolEnvironment(python: py)
        let runner = self.runner

        return Task { @MainActor [weak self] in
            let outcome: (hasAny: Bool, scan: SeedScanResult, error: String?) = await Task.detached(priority: .utility) {
                let fm = FileManager.default
                let hasAny = SeedCompression.hasAnySeedDirectory(in: root, fm: fm)
                let local = SeedCompression.quickScanLocal(seedRoot: root, zstdAvailable: false, fm: fm)

                if autoPromptOnFind && !local.hasUncompressed {
                    return (hasAny, local, nil)
                }

                let tool = SeedCompression.toolPath(repoPath: repoPath)
                guard !tool.isEmpty, fm.fileExists(atPath: tool), RepoLayout.supportsSeedCompression(repoPath) else {
                    return (hasAny, local, nil)
                }

                let args = SeedCompression.scanArguments(toolPath: tool, seedRoot: root)
                let res = runner.capture(ProcessLaunch(
                    executable: py,
                    arguments: args,
                    environment: env,
                    mergesErrors: false,
                    timeout: 30
                ))
                if res.ok, let parsed = SeedCompression.parseScanJSON(res.out) {
                    return (hasAny || parsed.totalGames > 0, parsed, nil)
                }
                let errText = res.err.trimmingCharacters(in: .whitespacesAndNewlines)
                let fallbackErr = errText.isEmpty ? res.out.trimmingCharacters(in: .whitespacesAndNewlines) : errText
                if local.hasUncompressed {
                    return (hasAny, local, nil)
                }
                return (hasAny, local, res.started ? nil : fallbackErr)
            }.value

            guard let self, gen == self.scanGeneration else { return }
            self.isScanning = false
            if let error = outcome.error, !error.isEmpty {
                self.scanState = .failed(error)
                return
            }
            self.scanState = .ready(hasAnySeeds: outcome.hasAny, scan: outcome.scan)

            if autoPromptOnFind,
               outcome.scan.hasUncompressed,
               outcome.scan.zstdAvailable,
               !self.promptDismissed,
               self.phase == nil,
               !self.buildRunning(),
               self.canAutoPrompt() {
                self.phase = .prompt(outcome.scan)
            }
        }
    }

    /// Opens the prompt manually from Settings even if "Don't ask again" was previously checked.
    @discardableResult
    package func openManualPrompt() -> Task<Void, Never>? {
        guard phase == nil, !buildRunning() else { return nil }
        noneNoticeVisible = false
        startError = nil

        if case .ready(_, let scan) = scanState, scan.hasUncompressed {
            if scan.zstdAvailable {
                phase = .prompt(scan)
            }
            return nil
        }

        scanGeneration &+= 1
        let gen = scanGeneration
        isScanning = true
        let root = seedRoot()
        let repoPath = repo.path
        let py = resolvePython()
        let env = toolEnvironment(python: py)
        let runner = self.runner

        return Task { @MainActor [weak self] in
            let outcome: (hasAny: Bool, scan: SeedScanResult) = await Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                let hasAny = SeedCompression.hasAnySeedDirectory(in: root, fm: fm)
                let local = SeedCompression.quickScanLocal(seedRoot: root, zstdAvailable: false, fm: fm)
                let tool = SeedCompression.toolPath(repoPath: repoPath)
                if !tool.isEmpty, fm.fileExists(atPath: tool), RepoLayout.supportsSeedCompression(repoPath) {
                    let args = SeedCompression.scanArguments(toolPath: tool, seedRoot: root)
                    let res = runner.capture(ProcessLaunch(
                        executable: py,
                        arguments: args,
                        environment: env,
                        mergesErrors: false,
                        timeout: 30
                    ))
                    if res.ok, let parsed = SeedCompression.parseScanJSON(res.out) {
                        return (hasAny || parsed.totalGames > 0, parsed)
                    }
                }
                return (hasAny, local)
            }.value

            guard let self, gen == self.scanGeneration else { return }
            self.isScanning = false
            self.scanState = .ready(hasAnySeeds: outcome.hasAny, scan: outcome.scan)
            guard self.phase == nil, !self.buildRunning() else { return }
            if outcome.scan.hasUncompressed {
                if outcome.scan.zstdAvailable {
                    self.phase = .prompt(outcome.scan)
                }
            } else {
                self.noneNoticeVisible = true
            }
        }
    }

    /// Dismisses the prompt sheet (persisting `dontAskAgain` when requested). Does nothing while running.
    package func dismissPrompt(dontAskAgain: Bool) {
        guard case .prompt = phase else { return }
        if dontAskAgain {
            promptDismissed = true
        }
        phase = nil
    }

    /// Closes the completion sheet and refreshes Settings scan state.
    package func finishDone() {
        guard case .done = phase else { return }
        phase = nil
        _ = scan(autoPromptOnFind: false)
    }

    /// Starts streaming `build_seed.py compress-seeds --progress json` for the prompted seeds.
    @discardableResult
    package func startCompression(level: Int = 3) -> Task<Void, Never> {
        guard case .prompt(let scan) = phase,
              scan.hasUncompressed,
              scan.zstdAvailable,
              !buildRunning() else {
            return Task {}
        }

        let tool = SeedCompression.toolPath(repoPath: repo.path)
        let fm = FileManager.default
        guard !tool.isEmpty, fm.fileExists(atPath: tool), RepoLayout.supportsSeedCompression(repo.path) else {
            return Task {}
        }

        runGeneration &+= 1
        let gen = runGeneration
        stopRequested = false
        activeProcess = nil
        startError = nil

        let items = scan.games.map { game in
            ItemProgress(
                titleID: game.titleID,
                appName: game.appName,
                beforeBytes: game.uncompressedBytes,
                status: .waiting
            )
        }
        let initial = RunningState(
            totalGames: scan.totalGames,
            totalBytes: scan.uncompressedBytes,
            items: items
        )
        phase = .running(initial)

        let root = scan.seedRoot.isEmpty ? seedRoot() : scan.seedRoot
        let py = resolvePython()
        let env = toolEnvironment(python: py)
        let args = SeedCompression.compressArguments(toolPath: tool, seedRoot: root, level: level)
        let runner = self.runner
        let signalFn = self.sendSignal

        return Task { @MainActor [weak self] in
            var capturedSummary: SeedCompressSummary?
            var capturedError: String?

            let result = await Task.detached(priority: .userInitiated) {
                var finalSummary: SeedCompressSummary?
                var finalError: String?
                let launch = ProcessLaunch(
                    executable: py,
                    arguments: args,
                    environment: env,
                    mergesErrors: false,
                    groupPython: py
                )
                let res = runner.streamLines(
                    launch,
                    started: { proc in
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                guard let self, gen == self.runGeneration else { return }
                                self.activeProcess = proc
                                if self.stopRequested, proc.processIdentifier > 1 {
                                    signalFn(proc.processIdentifier, SIGTERM)
                                }
                            }
                        }
                    },
                    line: { rawLine in
                        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        if let event = SeedCompression.parseEvent(line: trimmed) {
                            if case .done(let summary) = event { finalSummary = summary }
                            if case .error(let msg) = event { finalError = msg }
                            DispatchQueue.main.async {
                                MainActor.assumeIsolated {
                                    guard let self, gen == self.runGeneration else { return }
                                    self.ingest(event)
                                }
                            }
                        } else {
                            finalError = trimmed
                        }
                    }
                )
                return (res, finalSummary, finalError)
            }.value

            guard let self, gen == self.runGeneration else { return }
            self.activeProcess = nil
            capturedSummary = result.1
            capturedError = result.2

            if let summary = capturedSummary {
                self.phase = .done(summary)
                return
            }

            if case .running(let state) = self.phase {
                if let err = capturedError, !err.isEmpty {
                    self.startError = err
                } else if !result.0.started, !result.0.out.isEmpty {
                    self.startError = result.0.out
                }
                let fallback = self.syntheticSummary(from: state, stopped: self.stopRequested)
                self.phase = .done(fallback)
            }
        }
    }

    /// Sends SIGTERM to the running compression process and enters `.stopping` state.
    package func stopCompression() {
        guard case .running(var state) = phase, !state.stopping else { return }
        stopRequested = true
        state.stopping = true
        phase = .running(state)

        let gen = runGeneration
        guard let proc = activeProcess else { return }
        let pid = proc.processIdentifier
        guard pid > 1 else { return }
        sendSignal(pid, SIGTERM)

        let signalFn = self.sendSignal
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, gen == self.runGeneration, self.isRunning,
                          let current = self.activeProcess, current.isRunning, current.processIdentifier == pid else {
                        return
                    }
                    signalFn(pid, SIGKILL)
                }
            }
        }
    }

    /// Preview helper for DesignGallery scenes.
    package func setGalleryState(phase: Phase?, scanState: ScanState? = nil) {
        self.phase = phase
        if let scanState {
            self.scanState = scanState
        }
    }

    // MARK: - Private helpers

    private func ingest(_ event: SeedCompressEvent) {
        guard case .running(var state) = phase else { return }
        switch event {
        case .start(let totalGames, _, let totalBytes):
            if totalGames > 0 { state.totalGames = totalGames }
            if totalBytes > 0 { state.totalBytes = totalBytes }
        case .itemStart(let index, let totalGames, let titleID, _):
            if totalGames > 0 { state.totalGames = totalGames }
            state.currentIndex = index
            state.currentTitleID = titleID.uppercased()
            if let idx = state.items.firstIndex(where: { $0.titleID.caseInsensitiveCompare(titleID) == .orderedSame }) {
                state.items[idx].status = .compressing
                state.currentName = state.items[idx].appName
            }
        case .itemDone(_, _, let titleID, let beforeBytes, let afterBytes, let savedBytes, let filesCompressed):
            if let idx = state.items.firstIndex(where: { $0.titleID.caseInsensitiveCompare(titleID) == .orderedSame }) {
                state.items[idx].beforeBytes = beforeBytes
                state.items[idx].afterBytes = afterBytes
                state.items[idx].savedBytes = savedBytes
                state.items[idx].filesCompressed = filesCompressed
                state.items[idx].status = .done
            }
            state.processedBytes += beforeBytes
            state.freedBytes += savedBytes
        case .itemError(_, _, let titleID, let beforeBytes, let error):
            if let idx = state.items.firstIndex(where: { $0.titleID.caseInsensitiveCompare(titleID) == .orderedSame }) {
                state.items[idx].beforeBytes = beforeBytes
                state.items[idx].status = .failed
                state.items[idx].error = error
            }
            state.processedBytes += beforeBytes
        case .done(let summary):
            phase = .done(summary)
            return
        case .error(let message):
            startError = message
        }
        phase = .running(state)
    }

    private func syntheticSummary(from state: RunningState, stopped: Bool) -> SeedCompressSummary {
        var completed = 0
        var failed = 0
        var beforeTotal: Int64 = 0
        var afterTotal: Int64 = 0
        var results: [SeedCompressItemResult] = []
        for item in state.items {
            switch item.status {
            case .done:
                completed += 1
                beforeTotal += item.beforeBytes
                afterTotal += item.afterBytes
                results.append(SeedCompressItemResult(
                    titleID: item.titleID,
                    status: "completed",
                    beforeBytes: item.beforeBytes,
                    afterBytes: item.afterBytes,
                    savedBytes: item.savedBytes,
                    filesCompressed: item.filesCompressed
                ))
            case .failed:
                failed += 1
                beforeTotal += item.beforeBytes
                afterTotal += item.beforeBytes
                results.append(SeedCompressItemResult(
                    titleID: item.titleID,
                    status: "error",
                    beforeBytes: item.beforeBytes,
                    afterBytes: item.beforeBytes,
                    savedBytes: 0,
                    filesCompressed: 0,
                    error: item.error
                ))
            case .waiting, .compressing:
                continue
            }
        }
        let status: SeedCompressSummary.Status = stopped ? .stopped : (failed > 0 ? .partial : .completed)
        return SeedCompressSummary(
            status: status,
            completedGames: completed,
            failedGames: failed,
            beforeBytes: beforeTotal,
            afterBytes: afterTotal,
            savedBytes: max(0, beforeTotal - afterTotal),
            elapsedSec: 0,
            results: results
        )
    }

    private func resolvePython() -> String {
        let cached = python.pythonPath
        let isManagedMNG = MacNativeGamesBuilder.isManagedUVPython(cached, home: home)
            || MacNativeGamesBuilder.isManagedUVPython(cached)
        if !cached.isEmpty, !isManagedMNG {
            return cached
        }
        return findPython()
    }

    private func toolEnvironment(python py: String) -> [String: String] {
        var env: [String: String] = [
            "PATH": BuildCommands.toolPath("/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", python: py),
            "USER": NSUserName(),
            "HOME": home,
            "LANG": "en_US.UTF-8",
            "TMPDIR": NSTemporaryDirectory(),
        ]
        let dn = dotnetPath()
        if let droot = Toolchain.dotnetRoot(for: dn.isEmpty ? "dotnet" : dn) {
            env["DOTNET_ROOT"] = droot
            env["DOTNET_ROOT_ARM64"] = droot
        }
        env.merge(BundledTools.environment(for: py)) { $1 }
        env.merge(seedEnvironment()) { $1 }
        return ProxyEnvironment.merged(into: env)
    }
}
