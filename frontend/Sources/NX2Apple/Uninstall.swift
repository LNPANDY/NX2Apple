import AppKit
import NXCore

/// Uninstalling the launcher (NX Play's Uninstall): everything the app put outside its bundle, with the
/// player's games and keys left alone. What goes:
///
/// - the state folder `~/Library/Application Support/NS Port Builder/` (settings, the venv, library file)
/// - engine trees this launcher installed (`~/Library/Application Support/NX2Apple/engine/`)
/// - the project checkout the launcher itself cloned (`~/NX2Apple`, only when it is the launcher's own
///   download; a checkout the player made by hand is not touched)
/// - the launcher's settings (its UserDefaults domain)
///
/// What stays: the games folder and everything in it, the build output folder, `prod.keys`, Homebrew, and the
/// app itself, which goes to the Trash when the player confirms — never deleted. A folder that holds the games
/// folder or the build output folder stays as a whole.
enum Uninstall {
    struct Plan: Equatable {
        var stateFolders: [String] = []
        var checkouts: [String] = []
        /// The UserDefaults domain with the launcher's settings, nil when there is none to remove.
        var defaultsDomain: String?
        /// Where the app lives now (goes to the Trash, not deleted).
        var app: String = Bundle.main.bundlePath
    }

    /// The paths this install would remove, computed before anything is offered: the launcher's state
    /// folders that exist, and a checkout that is the launcher's own download (the clone destination
    /// `cloneRepo` uses) rather than one the player picked from anywhere on disk.
    /// `home` is passed in (NSHomeDirectory() at the call site): a computed home is not testable.
    nonisolated static func plan(home: String, gamesFolder: String, outputFolder: String = "", checkouts: [String],
                                 defaultsDomain: String? = nil) -> Plan {
        let fm = FileManager.default
        var p = Plan(defaultsDomain: defaultsDomain)
        let kept = [gamesFolder, outputFolder].filter { !$0.isEmpty }
        let holdsPlayerFiles = { (folder: String) in kept.contains { contains(folder, $0) } }
        let state = home + "/Library/Application Support/NS Port Builder"
        if fm.fileExists(atPath: state), !holdsPlayerFiles(state) { p.stateFolders.append(state) }
        let engine = home + "/Library/Application Support/NX2Apple"
        if fm.fileExists(atPath: engine), !holdsPlayerFiles(engine) { p.stateFolders.append(engine) }
        let own = home + "/NX2Apple"
        for checkout in checkouts where fm.fileExists(atPath: checkout) {
            // The launcher's own clone sits at ~/NX2Apple and is a git checkout with origin = this repo.
            // A folder the player picked from anywhere else stays: we cannot know what else lives there.
            guard checkout == own, !holdsPlayerFiles(checkout) else { continue }
            if let origin = gitOrigin(checkout), origin.contains("LNPANDY/NX2Apple") { p.checkouts.append(checkout) }
        }
        return p
    }

    /// Whether `path` is `folder` or lies inside it, after resolving symbolic links and `..`.
    nonisolated static func contains(_ folder: String, _ path: String) -> Bool {
        let f = URL(fileURLWithPath: folder).resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let p = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return p.count >= f.count && Array(p.prefix(f.count)) == f
    }

    nonisolated static func gitOrigin(_ checkout: String, git: GitCheckout = SystemGitCheckout()) -> String? {
        guard git.binary != nil else { return nil }
        let r = git.run(checkout, ["remote", "get-url", "origin"])
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
        if let domain = plan.defaultsDomain {
            UserDefaults.standard.removePersistentDomain(forName: domain)
            UserDefaults.standard.synchronize()
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
