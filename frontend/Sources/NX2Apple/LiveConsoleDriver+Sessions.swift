import AppKit
import Combine
import Darwin
import NXCore

/// What the console knows about the game it started, while it runs and once it has ended.
@MainActor final class ConsoleGameTracking {
    var gameID: String?
    var titleID = ""
    /// The game app's process (what NSWorkspace opened) and its host, the child that runs the game and posts its pause (#952).
    var appPID: Int32?
    var hostPID: Int32?
    var bundleID: String?
    /// The save folder the session used (DM_SAVE, else the app's own), for the newest save after a crash.
    var saveFolder: URL?
    var pausedSince: Date?
    var pausedSeconds: Double = 0
    var observers: [NSObjectProtocol] = []
    var observedPIDs: Set<Int32> = []
    var lookup: Task<Void, Never>?
    var lookupGeneration: UInt64 = 0
    var quitTimeout: Task<Void, Never>?
    var toolsChecked: [String] = []
    var observesSystem = true
    var runsChildLookup: Bool?
    /// Backoff intervals while waiting for `nxnative` to spawn `dmhost` on slow external drives or during first-run Gatekeeper scans.
    var lookupIntervals: [TimeInterval] = [0.25, 0.5, 1.0, 2.0] + Array(repeating: 4.0, count: 150)

    // What the system does, replaced by the tests.
    /// Posts a distributed notification to the game (org.nxnative.resume.<pid>, org.nxnative.quit.<pid>).
    var post: (String) -> Void = { name in
        DistributedNotificationCenter.default().postNotificationName(Notification.Name(name), object: nil, userInfo: nil, deliverImmediately: true)
    }
    /// Hands the front to the game, so it can take it when it resumes (an app may only activate itself when it was let).
    var yieldFront: (String?) -> Void = { bundleID in
        if #available(macOS 14, *), let bundleID { NSApp.yieldActivation(toApplicationWithBundleIdentifier: bundleID) }
    }
    private(set) var usesDefaultChildren = true
    var children: (Int32) -> [Int32] = { ProcessTree.children(of: $0) } {
        didSet { usesDefaultChildren = false }
    }
    var isProcessAlive: (Int32) -> Bool = { pid in
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }
    /// How the session ended, from the game's log (GameExit).
    var exit: (LibraryGame) -> GameExit = { game in
        guard let url = GameLog.latest(titleID: game.titleID, appPath: game.appPath), let lines = GameLog.tail(url, lines: 400) else { return .unknown }
        return GameExit.from(logTail: lines.joined(separator: "\n"))
    }
    var newestSave: (URL) -> Date? = { SaveTransfer.newest(in: $0) }
    var terminateApp: () -> Void = { NSApp.terminate(nil) }
    /// Shows console mode when a game pauses while the desktop is showing (ConsoleCoordinator.enter, set by the root view).
    var showConsole: () -> Void = {}
    var quitTimeoutSeconds: TimeInterval = 10
    /// Where the order of all games is kept: the desktop's own setting (LibrarySort), a suite of its own in tests.
    var sortDefaults: UserDefaults = .standard

    deinit {
        lookup?.cancel()
        quitTimeout?.cancel()
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
    }
}

/// #816 (Koshindai's concept): the play history and the screen after a crash. #952 (Haseenesss's idea, engine patch 0121): a game started
/// from console mode can be paused in the background from its Home menu, console mode shows it as paused and A resumes it, and starting
/// another game, leaving console mode or quitting the launcher asks before the paused game quits.
extension LiveConsoleDriver {
    // MARK: History

    /// A console game with what the history knows: when it was last played (the history's or the desktop's Recently played, whichever is
    /// newer), how long, and whether it was built with older tools.
    func withHistory(of game: LibraryGame, _ console: ConsoleGame) -> ConsoleGame {
        var console = console
        let record = sessions[game.titleID]
        console.lastPlayed = [record?.lastPlayed, game.lastPlayed].compactMap { $0 }.max()
        console.playSeconds = record?.seconds ?? 0
        console.olderTools = toolsAge.older.contains(game.id)
        return console
    }

    /// The games built with older tools are found off the main thread (ToolsAge, as the desktop does); the console redraws once known.
    func watchTools() {
        toolsAge.$older.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }.store(in: &cancellables)
    }

    func checkTools(_ games: [LibraryGame]) {
        guard tracking.observesSystem else { return }
        let signature = games.map { $0.id.uuidString + $0.toolsCommit + $0.appPath }
        guard signature != tracking.toolsChecked else { return }
        tracking.toolsChecked = signature
        toolsAge.check(games: games, repo: repo())
    }

    // MARK: A session

    /// The game was opened: the session starts, and its pause and resume are listened for.
    func beginTracking(_ game: LibraryGame, pid: Int32, environment: [String: String]) {
        endObserving()
        tracking.gameID = game.id.uuidString
        tracking.titleID = game.titleID
        tracking.appPID = pid
        tracking.hostPID = nil
        tracking.bundleID = Bundle(url: URL(fileURLWithPath: game.appPath))?.bundleIdentifier
        tracking.saveFolder = environment["DM_SAVE"].map { URL(fileURLWithPath: $0) } ?? SaveTransfer.macSave(titleID: game.titleID, appPath: game.appPath).save
        tracking.pausedSince = nil
        tracking.pausedSeconds = 0
        sessions.started(titleID: game.titleID)
        observe(pid)
        guard tracking.runsChildLookup ?? tracking.observesSystem else { return }
        let generation = tracking.lookupGeneration
        let intervals = tracking.lookupIntervals
        // The host is the app's child and may take minutes on slow external drives or first-run Gatekeeper scans.
        tracking.lookup = Task { [weak self] in
            for seconds in intervals {
                let delay = UInt64(max(seconds, 0) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled,
                      let self,
                      self.tracking.lookupGeneration == generation,
                      self.tracking.appPID == pid,
                      self.tracking.gameID != nil else { return }
                if self.tracking.hostPID != nil {
                    self.tracking.lookup = nil
                    return
                }
                let children: [Int32]
                if self.tracking.usesDefaultChildren {
                    children = await Task.detached(priority: .utility) { ProcessTree.children(of: pid) }.value
                    guard !Task.isCancelled,
                          self.tracking.lookupGeneration == generation,
                          self.tracking.appPID == pid,
                          self.tracking.gameID != nil else { return }
                } else {
                    children = self.tracking.children(pid)
                }
                if !children.isEmpty {
                    children.forEach(self.observe)
                    if self.tracking.hostPID == nil {
                        self.tracking.hostPID = children.first
                    }
                    self.tracking.lookup = nil
                    return
                }
                if !self.tracking.isProcessAlive(pid) {
                    self.tracking.lookup = nil
                    return
                }
            }
            if let self, self.tracking.lookupGeneration == generation {
                self.tracking.lookup = nil
            }
        }
    }

    /// Listens for org.nxnative.paused.<pid> and org.nxnative.resumed.<pid> of a process of the game.
    func observe(_ pid: Int32) {
        guard tracking.observedPIDs.insert(pid).inserted, tracking.observesSystem else { return }
        let center = DistributedNotificationCenter.default()
        tracking.observers += [
            center.addObserver(forName: Notification.Name("org.nxnative.paused.\(pid)"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.gamePaused(hostPID: pid) }
            },
            center.addObserver(forName: Notification.Name("org.nxnative.resumed.\(pid)"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.gameResumed(hostPID: pid) }
            },
        ]
    }

    private func endObserving() {
        tracking.lookupGeneration &+= 1
        tracking.lookup?.cancel()
        tracking.lookup = nil
        tracking.observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        tracking.observers = []
        tracking.observedPIDs = []
    }

    /// The game chose Back to console mode in its Home menu: it is paused and hidden, the console shows it as paused.
    func gamePaused(hostPID: Int32) {
        guard let id = tracking.gameID else { return }
        tracking.hostPID = hostPID
        if tracking.pausedSince == nil { tracking.pausedSince = Date() }
        timeoutTask?.cancel()
        state.gamePaused(id)
        tracking.showConsole()
    }

    /// The game plays again (Resume here, the Dock, ⌘Tab): the paused time is not played time.
    func gameResumed(hostPID: Int32) {
        tracking.hostPID = hostPID
        if let since = tracking.pausedSince { tracking.pausedSeconds += Date().timeIntervalSince(since) }
        tracking.pausedSince = nil
        state.gameResumed()
    }

    /// Resume: the front goes to the game, which takes it and plays on.
    func resume(_ gameID: String) {
        guard state.pausedGameID == gameID, let pid = tracking.hostPID ?? tracking.appPID else { return }
        tracking.yieldFront(tracking.bundleID)
        tracking.post("org.nxnative.resume.\(pid)")
    }

    /// The answer Quit to "Quit <game>?": the game quits as after ⌘Q (its exit handlers write the save), and what waited for it runs
    /// once it has quit. A game that has not quit after a while stays paused, and the console says so.
    func quitPausedGame() {
        guard state.pausedGameID != nil, !state.quittingPaused, let pid = tracking.hostPID ?? tracking.appPID else { return }
        state.beginQuitPaused()
        tracking.post("org.nxnative.quit.\(pid)")
        let name = state.pausedGame?.title ?? ""
        tracking.quitTimeout?.cancel()
        tracking.quitTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.tracking.quitTimeoutSeconds ?? 10) * 1_000_000_000))
            guard !Task.isCancelled, let self, self.state.quittingPaused else { return }
            self.state.quittingPaused = false
            self.state.afterQuit = nil
            if self.state.presentedSheet == .confirmQuitPaused { self.state.back() }
            self.showToast(String(format: self.t("console.quitFailed"), name))
        }
    }

    /// The launcher is asked to quit: while a game is paused console mode asks first and the launcher quits once the game has.
    /// Returns whether the quit waits for that. Out of console mode the game is asked to quit with the launcher.
    func shouldDeferTermination(consoleShown: Bool) -> Bool {
        guard state.pausedGameID != nil, let pid = tracking.hostPID ?? tracking.appPID else { return false }
        guard consoleShown else { tracking.post("org.nxnative.quit.\(pid)"); return false }
        state.askQuitPaused(then: .terminate)
        return true
    }

    /// The game's process ended (GameReturnWatcher): the history, the screen after a crash, the Home button hint, and what waited for
    /// a paused game that was asked to quit.
    func gameSessionEnded(_ game: LibraryGame?) {
        tracking.quitTimeout?.cancel()
        endObserving()
        let wasPaused = state.pausedGameID != nil
        if let since = tracking.pausedSince { tracking.pausedSeconds += Date().timeIntervalSince(since) }
        let exit = game.map(tracking.exit) ?? .unknown
        let stopped = exit == .stoppedUnexpectedly
        if !tracking.titleID.isEmpty {
            sessions.ended(titleID: tracking.titleID, paused: tracking.pausedSeconds, unexpectedly: stopped)
        }
        let id = tracking.gameID, folder = tracking.saveFolder
        tracking.gameID = nil; tracking.appPID = nil; tracking.hostPID = nil; tracking.pausedSince = nil; tracking.pausedSeconds = 0
        let next = state.pausedGameEnded()
        if !wasPaused { state.returnFromGame() }   // a paused game's quit leaves the console as it is: the player is in it
        gameEnded()
        refresh()   // Continue playing and the play time
        switch next {
        case let .play(other)?: play(other); return
        case let .leave(selecting)?: if let selecting { openOnDesktop(selecting) } else { exitToDesktop() }; return
        case .terminate?: tracking.terminateApp(); return
        case nil: break
        }
        if stopped, let id { state.showStopped(id, lastSave: folder.flatMap(tracking.newestSave)); return }
        if let game { offerHomeButtonHint(after: game) }
    }
}
