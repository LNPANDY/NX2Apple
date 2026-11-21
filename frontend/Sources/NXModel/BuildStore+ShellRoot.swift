import Foundation
import NXCore

// Where the shared app's folder lives (#492). The Settings row shows it before a game or output folder is chosen, so a
// look only previews the root; a build saves it. An empty parent, "/" or a relative one would have put it at
// /NX2Apple-shell, the root of the read-only system volume, where the write failed after the whole build; a saved value
// like that is repaired. A build also checks the folder before its long steps, not at the end.
//
// Move cache folder (#427): the player moves the folder to another place, or back to the default one. The move is one of the
// cache folder moves (BuildStore+CacheFolders.swift), these are its names from before.

extension BuildStore {
    /// The shell folder the cache row shows: the frameworks' mirror, shell.json and the banner cache live here.
    package var shellCachePath: String { ShellLibrary.previewRoot(defaults: defaults, parent: shellRootParent, home: home) }
    /// The folder a first shell root would sit in: the output folder, else the game's folder.
    package var shellRootParent: String { effectiveOutputFolder }
    /// The shell folder of the install: the saved one, else next to the output folder (or the game's folder).
    package var shellRoot: String { ShellLibrary.resolveRoot(defaults: defaults, parent: shellRootParent, home: home) }

    /// Why the shell folder cannot be written (`nil`: it can), before an hour of building rather than at the last step.
    package func shellRootProblem() -> String? {
        let root = shellRoot
        return ShellInstall.canWriteRoot(root) ? nil : String(format: t("shell.rootUnwritable"), shortPath(root))
    }

    // MARK: Move cache folder

    /// The cache is in the default place, so there is no way back to offer.
    package var shellCacheIsDefault: Bool { cacheIsDefault(.shell) }

    /// The confirmation for a move into `folder` (the cache goes into a new folder inside it).
    package func prepareShellMove(into folder: String) { prepareCacheMove(.shell, into: folder) }

    /// The confirmation for the way back to `~/Library/Application Support/NX2Apple/shell`.
    package func prepareShellMoveToDefault() { prepareCacheMoveToDefault(.shell) }

    /// The confirmed move starts, off the main thread. Refused while a build, an install or an export runs.
    @discardableResult
    package func confirmShellMove() -> Task<Void, Never>? { confirmCacheMove(.shell) }

    /// Stop while the cache moves: the partial copy goes, the old folder stays as it was and keeps being used.
    package func stopShellMove() { stopCacheMove() }

    /// Back to the plain row, after the confirmation or the result.
    package func dismissShellMove() { dismissCacheMove(.shell) }
}
