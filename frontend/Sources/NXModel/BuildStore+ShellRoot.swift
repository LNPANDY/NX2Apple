import Foundation
import NXCore

// Where the shared app's folder lives (#492). The Settings row shows it before a game or output folder is chosen, so a
// look only previews the root; a build saves it. An empty parent, "/" or a relative one would have put it at
// /NX2Apple-shell, the root of the read-only system volume, where the write failed after the whole build; a saved value
// like that is repaired. A build also checks the folder before its long steps, not at the end.
//
// Move cache folder (#427): the player moves the folder to another place, or back to the default one. The move runs on the
// build store's `running` flag, as the copy to a drive does, so no build, install or export starts while it runs, and it
// cannot start while one of them runs. The rules and the file work are ShellRootMove's.

/// The state of Move cache folder, as the cache row shows it.
package enum ShellMove: Equatable {
    case idle
    /// The confirmation: from where to where, the sizes, and what stops it.
    case confirm(ShellRootMove.Plan)
    case moving(phase: ShellRootMove.Phase, done: Int64, total: Int64)
    /// The cache is in its new place (the path).
    case moved(String)
    /// The cache is in its new place, but the old folder could not be removed fully (new place, old place).
    case movedOldStays(String, old: String)
    /// Stopped: the cache stays where it was (the path).
    case stopped(String)
    /// The move failed: the reason, and where the cache stays.
    case failed(String, stays: String)
}

extension BuildStore {
    /// The shell folder the cache row shows: the frameworks' mirror, shell.json and the banner cache live here.
    package var shellCachePath: String { ShellLibrary.previewRoot(defaults: defaults, parent: shellRootParent, home: home) }
    /// The folder a first shell root would sit in: the output folder, else the game's folder.
    package var shellRootParent: String { outDir.isEmpty ? inputFolder : outDir }
    /// The shell folder of the install: the saved one, else next to the output folder (or the game's folder).
    package var shellRoot: String { ShellLibrary.resolveRoot(defaults: defaults, parent: shellRootParent, home: home) }

    /// Why the shell folder cannot be written (`nil`: it can), before an hour of building rather than at the last step.
    package func shellRootProblem() -> String? {
        let root = shellRoot
        return ShellInstall.canWriteRoot(root) ? nil : String(format: t("shell.rootUnwritable"), shortPath(root))
    }

    // MARK: Move cache folder

    /// The cache is in the default place, so there is no way back to offer.
    package var shellCacheIsDefault: Bool { shellCachePath == ShellRootMigration.defaultRoot(home: home) }

    /// The confirmation for a move into `folder` (the cache goes into a new folder inside it).
    package func prepareShellMove(into folder: String) {
        prepareShellMove(to: ShellRootMove.destination(inside: folder))
    }

    /// The confirmation for the way back to `~/Library/Application Support/NX2Apple/shell`.
    package func prepareShellMoveToDefault() {
        prepareShellMove(to: ShellRootMigration.defaultRoot(home: home))
    }

    private func prepareShellMove(to destination: String) {
        if case .moving = shellMove { return }
        shellMove = .confirm(ShellRootMove.plan(from: shellCachePath, to: destination))
    }

    /// The confirmed move starts, off the main thread. Refused while a build, an install or an export runs.
    @discardableResult
    package func confirmShellMove() -> Task<Void, Never>? {
        guard !running, case .confirm(let shown) = shellMove else { return nil }
        // Plan again: a build may have written to the cache since the confirmation was shown
        let plan = ShellRootMove.plan(from: shellCachePath, to: shown.destination)
        guard plan.problem == nil else { shellMove = .confirm(plan); return nil }
        running = true
        shellMoveStop.set(false)
        shellMove = .moving(phase: .copying, done: 0, total: plan.bytes)
        let stop = shellMoveStop
        return Task { @MainActor in
            let outcome = await Task.detached(priority: .userInitiated) {
                ShellRootMove.run(plan, progress: { phase, done, total in
                    hop { [weak self] in if case .moving = self?.shellMove { self?.shellMove = .moving(phase: phase, done: done, total: total) } }
                }, stop: { stop.value })
            }.value
            self.finishShellMove(plan, outcome)
        }
    }

    /// Stop while the cache moves: the partial copy goes, the old folder stays as it was and keeps being used.
    package func stopShellMove() { shellMoveStop.set(true) }

    /// Back to the plain row, after the confirmation or the result.
    package func dismissShellMove() {
        if case .moving = shellMove { return }
        shellMove = .idle
    }

    private func finishShellMove(_ plan: ShellRootMove.Plan, _ outcome: ShellRootMove.Outcome) {
        running = false
        func saveRoot() {
            defaults.set(plan.destination, forKey: "shellRoot")
            if plan.destination == ShellRootMigration.defaultRoot(home: home) { defaults.removeObject(forKey: ShellRootMove.pickedKey) }
            else { defaults.set(true, forKey: ShellRootMove.pickedKey) }
        }
        switch outcome {
        case .moved:
            saveRoot()
            shellMove = .moved(plan.destination)
            say("Cache folder moved: \(plan.source) → \(plan.destination)")
        case .movedOldStays:
            saveRoot()
            shellMove = .movedOldStays(plan.destination, old: plan.source)
            say("Cache folder moved to \(plan.destination), the old folder \(plan.source) could not be removed fully")
        case .stopped:
            shellMove = .stopped(plan.source)
        case .failed(let failure):
            let why: String
            switch failure {
            case .io(let text): why = text.trimmingCharacters(in: CharacterSet(charactersIn: ".。 "))   // the text goes on after it
            case .mismatch(let path): why = String(format: t("shellCache.fail.mismatch"), path)
            case .ledger: why = t("shellCache.fail.ledger")
            }
            shellMove = .failed(why, stays: plan.source)
            say("Cache folder not moved (\(why)), it stays in \(plan.source)")
        }
    }
}
