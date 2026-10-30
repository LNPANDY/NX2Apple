import AppKit

/// Uninstalling the launcher (NX Play's Uninstall): everything the app put outside its bundle, with the
/// player's games and keys left alone. What goes:
///
/// - the state folder `~/Library/Application Support/NS Port Builder/` (settings, the venv, library file)
/// - engine trees this launcher installed (`~/Library/Application Support/NX2Apple/engine/`)
/// - the project checkout the launcher itself cloned (`~/NX2Apple`, only when it is the launcher's own
///   download; a checkout the player made by hand is not touched)
///
/// What stays: the games folder and everything in it, `prod.keys`, Homebrew, and the app itself, which
/// goes to the Trash when the player confirms — never deleted.
enum Uninstall {
    struct Plan: Equatable {
        var stateFolders: [String] = []
        var checkouts: [String] = []
        /// Where the app lives now (goes to the Trash, not deleted).
        var app: String = Bundle.main.bundlePath
    }

    /// The paths this install would remove, computed before anything is offered: the launcher's state
    /// folders that exist, and a checkout that is the launcher's own download (the clone destination
    /// `cloneRepo` uses) rather than one the player picked from anywhere on disk.
    /// `home` is passed in (NSHomeDirectory() at the call site): a computed home is not testable.
    nonisolated static func plan(home: String, gamesFolder: String, checkouts: [String]) -> Plan {
        let fm = FileManager.default
        var p = Plan()
        let state = home + "/Library/Application Support/NS Port Builder"
        if fm.fileExists(atPath: state) { p.stateFolders.append(state) }
        let engine = home + "/Library/Application Support/NX2Apple"
        if fm.fileExists(atPath: engine) { p.stateFolders.append(engine) }
        let own = home + "/NX2Apple"
        for checkout in checkouts where fm.fileExists(atPath: checkout) {
            // The launcher's own clone sits at ~/NX2Apple and is a git checkout with origin = this repo.
            // A folder the player picked from anywhere else stays: we cannot know what else lives there.
            guard checkout == own else { continue }
            if let origin = gitOrigin(checkout), origin.contains("LNPANDY/NX2Apple") { p.checkouts.append(checkout) }
        }
        return p
    }

    nonisolated static func gitOrigin(_ checkout: String) -> String? {
        guard let git = BuildModel.gitBinary() else { return nil }
        let r = BuildModel.runQuiet([git, "-C", checkout, "remote", "get-url", "origin"], env: BuildModel.gitEnv())
        let url = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.ok && !url.isEmpty ? url : nil
    }

    /// Remove the plan's folders. The games folder and the app are never touched here. Returns what was
    /// removed and what failed (in use, permissions), so the confirmation can say so honestly.
    nonisolated static func run(_ plan: Plan, movingAppToTrash: Bool = true) -> (removed: [String], failures: [String]) {
        let fm = FileManager.default
        var removed: [String] = [], failures: [String] = []
        for folder in plan.stateFolders + plan.checkouts {
            do { try fm.removeItem(atPath: folder); removed.append(folder) }
            catch { failures.append(folder + ": " + error.localizedDescription) }
        }
        if movingAppToTrash, plan.app.hasSuffix(".app"), plan.app.contains("/Applications/") {
            if !fm.fileExists(atPath: plan.app) { failures.append(plan.app + ": not found") }
            else if !trash(plan.app) { failures.append(plan.app + ": could not move to the Trash") }
        }
        return (removed, failures)
    }

    /// To the Trash, like the Finder's delete: recoverable, never `removeItem`.
    nonisolated static func trash(_ path: String) -> Bool {
        var url: NSURL?
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &url)
            return true
        } catch { return false }
    }
}
