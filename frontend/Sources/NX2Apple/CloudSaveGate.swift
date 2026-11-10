import Foundation
import NXCore

/// What the check before a start (#957) needs of a Mac game with cloud saves: the cloud's file, this Mac's save, and whether the
/// game's engine follows the player's choice.
struct CloudSaveStart: Equatable {
    var titleID: String
    var gameName: String
    var cloudFile: URL
    /// `DM_SAVE`: its `.sync` (the save last synced) and its `-backups` (the save not chosen).
    var save: URL
    /// Where this Mac's save is read: `save`, or the ~/Library save that launcher.c copies into an empty library save at the start.
    var scanned: URL
    /// The engine reads `DM_SAVE_SYNC_CHOICE` (Info.plist `DMSaveSyncChoice`). An older build gets the download before its start,
    /// and no question it could not follow.
    var takesChoice: Bool

    var backups: URL { URL(fileURLWithPath: save.path + "-backups") }

    /// nil when the game starts without a check: cloud saves off, or no Mac app.
    static func plan(for game: LibraryGame, saves: GameCloudSaves? = nil) -> CloudSaveStart? {
        guard !game.appPath.isEmpty, FileManager.default.fileExists(atPath: game.appPath) else { return nil }
        let saves = saves ?? GameCloudSaves(titleID: game.titleID, appPath: game.appPath)
        guard let folder = saves.setting.folder else { return nil }
        let mac = SaveTransfer.macSave(titleID: game.titleID, appPath: game.appPath)
        var scanned = mac.save
        if let legacy = mac.legacy, CloudSaveCheck.localSave(save: mac.save)?.hash == nil, CloudSaveCheck.localSave(save: legacy)?.hash != nil { scanned = legacy }
        return CloudSaveStart(titleID: game.titleID, gameName: game.name,
                              cloudFile: URL(fileURLWithPath: CloudSaveSync.saveFile(folder: folder, titleID: game.titleID)),
                              save: mac.save, scanned: scanned, takesChoice: takesChoice(app: game.appPath))
    }

    static func takesChoice(app: String) -> Bool {
        let plist = URL(fileURLWithPath: app).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let marker = info["DMSaveSyncChoice"] as? NSNumber else { return false }
        return marker.intValue >= 1
    }
}

/// The question before the start: the two saves differ (both changed), or the cloud's could not be read.
struct CloudSaveQuestion: Equatable, Identifiable {
    var id = UUID()
    var gameName: String
    var outcome: CloudSaveCheck.Outcome
    var local: CloudSaveCheck.Save
    var cloud: CloudSaveCheck.Save?
    /// Why the cloud's could not be read.
    var reason: String?
    var backups: URL
}

enum CloudSaveStep: Equatable {
    /// The cloud's save is being brought onto this Mac. `long`: it has taken a while, so playing without it is offered too.
    case fetching(gameName: String, long: Bool)
    case asking(CloudSaveQuestion)
}

/// The check before a Mac game with cloud saves starts, for the desktop Play and the console mode alike: the cloud's save is
/// downloaded (with no time limit, the player can cancel), compared with this Mac's and the last synced one, and the game starts
/// at once when they agree. When they do not, `step` holds the question, and the game starts with the player's answer
/// (`DM_SAVE_SYNC_CHOICE`) or not at all.
@MainActor final class CloudSaveGate: ObservableObject {
    /// Set by the gate; visual QA sets it to draw a step.
    @Published var step: CloudSaveStep?
    private let fetcher: CloudFileFetching
    private let longWait: TimeInterval
    private var start: CloudSaveStart?
    private var proceed: (([String: String]) -> Void)?
    private var ended: (() -> Void)?
    private var cancelled: CancelFlag?
    private var cloudSave: CloudSaveCheck.Save?

    init(fetcher: CloudFileFetching = CoordinatedCloudFetch(), longWait: TimeInterval = 8) {
        self.fetcher = fetcher
        self.longWait = longWait
    }

    var isActive: Bool { step != nil }

    /// Checks `game`, then calls `proceed` with what to add to its start environment. `ended` when the player cancelled.
    /// A game without cloud saves proceeds at once, before this returns.
    func begin(_ game: LibraryGame, plan: CloudSaveStart? = nil, proceed: @escaping ([String: String]) -> Void, ended: @escaping () -> Void = {}) {
        guard step == nil else { return }   // a check is running or asking: a second Play waits for its answer
        guard let start = plan ?? CloudSaveStart.plan(for: game) else { proceed([:]); return }
        self.start = start; self.proceed = proceed; self.ended = ended
        run()
    }

    private func run() {
        guard let start else { return }
        let flag = CancelFlag()
        cancelled = flag
        step = .fetching(gameName: start.gameName, long: false)
        let fetcher = fetcher
        Task { [weak self, longWait] in
            try? await Task.sleep(nanoseconds: UInt64(longWait * 1_000_000_000))
            guard let self, !flag.isSet, case .fetching(let name, false) = self.step else { return }
            self.step = .fetching(gameName: name, long: true)
        }
        Task.detached {
            let fetched = fetcher.fetch(start.cloudFile) { flag.isSet }
            let found = Self.compare(start, fetched: fetched)
            await MainActor.run { [weak self] in
                guard let self, !flag.isSet, self.cancelled === flag else { return }
                self.finish(found)
            }
        }
    }

    /// What the check found: the outcome, this Mac's save, the cloud's (nil: unreadable) and why it could not be read.
    nonisolated static func compare(_ start: CloudSaveStart, fetched: CloudFetchResult)
        -> (outcome: CloudSaveCheck.Outcome, local: CloudSaveCheck.Save?, cloud: CloudSaveCheck.Save?, reason: String?)? {
        var cloud: CloudSaveCheck.Save?, reason: String?
        switch fetched {
        case .cancelled: return nil
        case .missing: cloud = CloudSaveCheck.Save.empty
        case .failed(let why): reason = why
        case .ready:
            cloud = CloudSaveCheck.cloudSave(file: start.cloudFile)
            if cloud == nil { reason = "The file in the cloud is not a whole save." }
            else if CloudSaveCheck.cloudTitle(file: start.cloudFile).uppercased() != start.titleID.uppercased() { cloud = nil; reason = "The file in the cloud is another game’s save." }
        }
        let local = CloudSaveCheck.localSave(save: start.scanned)
        return (CloudSaveCheck.decide(local: local ?? .empty, base: CloudSaveCheck.base(save: start.save), cloud: cloud), local, cloud, reason)
    }

    private func finish(_ found: (outcome: CloudSaveCheck.Outcome, local: CloudSaveCheck.Save?, cloud: CloudSaveCheck.Save?, reason: String?)?) {
        guard let start else { return }
        guard let found else { cancel(); return }
        // This Mac's save cannot be read (the engine turns cloud saves off for the session), or an older engine that cannot follow a choice: start as before
        guard found.outcome.asks, let local = found.local, start.takesChoice else { go([:]); return }
        cloudSave = found.cloud
        step = .asking(CloudSaveQuestion(gameName: start.gameName, outcome: found.outcome, local: local, cloud: found.cloud,
                                         reason: found.reason, backups: start.backups))
    }

    /// The player's answer to the question, or "play with this Mac's save" while the download takes long. Only an answer the
    /// question offers counts: a cloud save that was not read can neither be brought in nor chosen against.
    func choose(_ choice: CloudSaveCheck.Choice) {
        switch step {
        case .fetching: guard choice == .offline else { return }; cancelled?.set()
        case let .asking(q): guard (q.outcome == .unreadable) == (choice == .offline) else { return }
        case nil: return
        }
        go(CloudSaveCheck.environment(choice, cloud: cloudSave))
    }

    func retry() {
        guard case .asking = step else { return }
        run()
    }

    func cancel() {
        guard step != nil else { return }
        cancelled?.set()
        let ended = self.ended
        reset()
        ended?()
    }

    private func go(_ environment: [String: String]) {
        let proceed = self.proceed
        reset()
        proceed?(environment)
    }

    private func reset() { step = nil; start = nil; proceed = nil; ended = nil; cancelled = nil; cloudSave = nil }
}

/// Set once, read from any thread.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}
