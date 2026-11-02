import Foundation
import NXCore

// Where the shared app's folder lives (#492). The Settings row shows it before a game or output folder is chosen, so a
// look only previews the root; a build saves it. An empty parent, "/" or a relative one would have put it at
// /NX2Apple-shell, the root of the read-only system volume, where the write failed after the whole build; a saved value
// like that is repaired. A build also checks the folder before its long steps, not at the end.

extension BuildStore {
    /// The shell folder the cache row shows: the frameworks' mirror, shell.json and the banner cache live here.
    package var shellCachePath: String { ShellLibrary.previewRoot(defaults: defaults, parent: shellRootParent) }
    /// The folder a first shell root would sit in: the output folder, else the game's folder.
    package var shellRootParent: String { outDir.isEmpty ? (basePath as NSString).deletingLastPathComponent : outDir }
    /// The shell folder of the install: the saved one, else next to the output folder (or the game's folder).
    package var shellRoot: String { ShellLibrary.resolveRoot(defaults: defaults, parent: shellRootParent) }

    /// Why the shell folder cannot be written (`nil`: it can), before an hour of building rather than at the last step.
    package func shellRootProblem() -> String? {
        let root = shellRoot
        return ShellInstall.canWriteRoot(root) ? nil : String(format: t("shell.rootUnwritable"), shortPath(root))
    }
}
