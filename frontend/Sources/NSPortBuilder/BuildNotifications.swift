import AppKit
import Combine
import UserNotifications

// A notification when a build finishes or fails (issue #64): a build takes long enough that people switch
// to something else, and the only sign it was done was the window they had left. Only while the app is not
// frontmost (a build someone is watching needs no notification), and only when Settings leaves it on.
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

    /// A stopped build was stopped by someone at the app; a build in front of someone needs no notification.
    static func shouldNotify(_ outcome: Outcome, enabled: Bool, appActive: Bool, hasBundleID: Bool) -> Bool {
        outcome != .stopped && enabled && !appActive && hasBundleID
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

    /// Where a clicked notification asks the window to go (ContentView takes it and clears it).
    @Published var route: Route?
    /// The Builds page opens its log when this is set (BuilderView clears it).
    @Published var showLog = false

    private var watching: AnyCancellable?

    /// Follows the model's builds: asks for permission when one starts, notifies when it ends. Only from the real
    /// app's window (not previews or tests), and only with a bundle identifier (see the top of this file).
    func watch(_ m: BuildModel, library: GameLibrary) {
        guard watching == nil, BuildNotice.hasBundleID else { return }
        UNUserNotificationCenter.current().delegate = self
        watching = m.$done.removeDuplicates().dropFirst().sink { [weak self, weak m, weak library] done in
            guard let self, let m, let library else { return }
            if m.running { return }   // a reset between builds: done flips false while nothing has ended yet
            // `done` is the chain's own verdict: the Mac target sets it when the .app exists, the iPhone target
            // when the pack-install chain finished (its script ends earlier, with `running` false while work goes
            // on — a `running`-based notice read that window as a failure, and a done-based one missed nothing).
            let stopped = m.stopping
            DispatchQueue.main.async {
                let outcome: BuildNotice.Outcome = stopped ? .stopped
                    : done ? .finished : .failed(reason: BuildNotice.failureReason(note: m.doneNote, stages: m.stages))
                guard BuildNotice.shouldNotify(outcome, enabled: BuildNotice.enabled, appActive: NSApp.isActive, hasBundleID: true) else { return }
                self.post(outcome, m: m, library: library)
            }
        }
    }

    private func post(_ outcome: BuildNotice.Outcome, m: BuildModel, library: GameLibrary) {
        let titleID = BuildModel.titleID(m.basePath).map { String(format: "%016llX", $0) } ?? ""
        let game = library.games.first { $0.titleID == titleID }
        let name = game?.name ?? GameLibrary.title(for: m.basePath, repo: m.repoPath, titleID: titleID)
        let text = BuildNotice.text(outcome, game: name, target: m.target, device: m.installedOn.isEmpty ? nil : m.deviceName(m.installedOn), m.t)
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
