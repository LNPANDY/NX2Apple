import AppKit
import Combine
import NXCore
import NXModel
import UserNotifications

// A notification when a build finishes or fails (issue #64): a build takes long enough that people switch
// to something else, and the only sign it was done was the window they had left. In front or not (a finished or
// failed build always says so, a stop does not), and only when Settings leaves it on.
// Clicking it brings the app forward on the game in the library (finished) or the Builds page with the
// log open (failed).
//
// UNUserNotificationCenter needs an app bundle: an unbundled `swift run` has no bundle identifier and
// UNUserNotificationCenter.current() raises an exception there. So without a bundle identifier there are
// no notifications at all (and Settings says so); they work in the packaged NX2Apple.app.

/// The decisions and the text, kept apart from the notification center so they can be tested.
enum BuildNotice {
    enum Outcome: Equatable {
        case finished
        case failed(reason: String)
        case stopped
    }

    static let defaultsKey = "notifyBuilds"

    /// On unless switched off in Settings.
    static var enabled: Bool { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }

    static var hasBundleID: Bool { Bundle.main.bundleIdentifier != nil }

    /// A stopped build was stopped by someone at the app. The owner's rc8 report: a build that finishes while the
    /// launcher is in front must still say so — success and failure alike, only a stop stays silent.
    static func shouldNotify(_ outcome: Outcome, enabled: Bool, appActive: Bool, hasBundleID: Bool) -> Bool {
        outcome != .stopped && enabled && hasBundleID
    }

    /// Title and body: the game, the target, and for a failure the reason (the build's own last word).
    static func text(_ outcome: Outcome, game: String, target: String, device: String?, _ t: (String) -> String) -> (title: String, body: String) {
        let place = target == "mac-app" ? t("notify.forMac")
            : device.map { String(format: t("notify.installedOn"), $0) } ?? t("notify.forIOS")
        switch outcome {
        case .finished, .stopped: return (String(format: t("notify.doneTitle"), game), place)
        case .failed(let reason):
            return (String(format: t("notify.failedTitle"), game), reason.isEmpty ? place : place + "\n" + reason)
        }
    }

    /// What has ended, read once the handler that ended a run has set its verdict (the main queue's next turn after `running` went
    /// false or `done` went true). nil while nothing has: still running, or the iPhone chain between its script and the pack and install
    /// (`running` false, every stage done, no note). A failure keeps `done` false, so it is told by its note or a failed stage, not by `done`.
    static func ended(stopped: Bool, running: Bool, done: Bool, note: String, stages: [Stage]) -> Outcome? {
        if stopped { return .stopped }
        if running { return nil }
        if done { return .finished }
        guard !note.isEmpty || stages.contains(where: { $0.state == .failed }) else { return nil }
        return .failed(reason: failureReason(note: note, stages: stages))
    }

    /// What a failed build said last: its message, else the step that failed with its detail.
    static func failureReason(note: String, stages: [Stage]) -> String {
        if !note.isEmpty { return note }
        guard let s = stages.last(where: { $0.state == .failed }) else { return "" }
        return s.detail.isEmpty ? s.name : s.name + " · " + s.detail
    }
}

/// Watches the build model, posts the notification and turns a click on it into where the app should show.
final class BuildNotifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = BuildNotifier()

    struct Route: Equatable {
        var page: LauncherPage
        var game: UUID?
    }

    /// Where a clicked notification asks the window to go (LauncherView takes it and clears it).
    @Published var route: Route?
    /// The Builds page opens its log when this is set (BuildPage clears it through LogCard).
    @Published var showLog = false

    private var watching = Set<AnyCancellable>()
    /// The run that started last has had its notice (or its stop): a run posts one at most.
    private var announced = false

    /// Follows the model's builds: asks for permission when one starts, notifies when it ends. Only from the real
    /// app's window (not previews or tests), and only with a bundle identifier (see the top of this file).
    ///
    /// The end is read from both `running` going false and `done` going true, a turn of the main queue later (`BuildNotice.ended`):
    /// `done` alone never changes for a failure (it starts false and stays false), and the Mac target sets it while `running` is
    /// still true, so a `done`-only watch announced neither a failed build nor a finished Mac app.
    @MainActor func watch(_ m: BuildStore, library: GameLibrary) {
        guard watching.isEmpty, BuildNotice.hasBundleID else { return }
        UNUserNotificationCenter.current().delegate = self
        m.$running.removeDuplicates().dropFirst().sink { [weak self, weak m, weak library] running in MainActor.assumeIsolated {
            guard let self, let m, let library else { return }
            if running {
                self.announced = false
                // The first build is when someone has a reason to say yes; the system asks only once.
                if BuildNotice.enabled { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }
                return
            }
            let stopped = m.stopping   // the end handler clears it right after `running`
            DispatchQueue.main.async { MainActor.assumeIsolated { self.settle(m, library: library, stopped: stopped) } }
        } }.store(in: &watching)
        m.$done.removeDuplicates().dropFirst().filter { $0 }.sink { [weak self, weak m, weak library] _ in MainActor.assumeIsolated {
            guard let self, let m, let library else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.settle(m, library: library, stopped: false) } }
        } }.store(in: &watching)
    }

    /// Only a game's build is announced: a send, an install or a shell setup also runs the model, with `buildingGame` false.
    @MainActor private func settle(_ m: BuildStore, library: GameLibrary, stopped: Bool) {
        guard !announced, m.buildingGame, let outcome = BuildNotice.ended(stopped: stopped, running: m.running, done: m.done, note: m.doneNote, stages: m.stages) else { return }
        announced = true
        guard BuildNotice.shouldNotify(outcome, enabled: BuildNotice.enabled, appActive: NSApp.isActive, hasBundleID: true) else { return }
        post(outcome, m: m, library: library)
    }

    /// Shown while the launcher is in front too (the console mode fills the screen): without this the system drops a frontmost app's notification.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    @MainActor private func post(_ outcome: BuildNotice.Outcome, m: BuildStore, library: GameLibrary) {
        let titleID = m.gameTitleID ?? ""
        let game = library.games.first { $0.titleID == titleID }
        let name = game?.name ?? GameLibrary.title(for: m.gameFolder?.folder ?? m.basePath, repo: m.repo.path, titleID: titleID)
        let text = BuildNotice.text(outcome, game: name, target: m.runningTarget, device: m.installedOn.isEmpty ? nil : m.devices.deviceName(m.installedOn), m.t)
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.body
        content.sound = .default
        content.userInfo = ["page": outcome == .finished ? LauncherPage.library.rawValue : LauncherPage.builds.rawValue,
                            "game": game?.id.uuidString ?? ""]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "build-" + UUID().uuidString, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let page = LauncherPage(rawValue: info["page"] as? String ?? "") ?? .library
        let game = (info["game"] as? String).flatMap(UUID.init(uuidString:))
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
            if page == .builds { self.showLog = true }
            self.route = Route(page: page, game: game)
            completionHandler()
        }
    }
}
