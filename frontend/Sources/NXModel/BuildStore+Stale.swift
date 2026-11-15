import Foundation
import NXCore

// LNPANDY/NX2Apple#449: a build for the iPhone or iPad asks before the long steps when the shell folder holds frameworks of
// another shader chain than the engine this build uses. Stop leaves every file as it is. Continue deletes the stale frameworks
// (and their entries in the shell's library) and starts the build again. Without stale frameworks nothing is asked. A framework
// whose chain cannot be read is not decided here, build_shell.sh's own check at the last step stays for it.

extension BuildStore {
    /// The stale frameworks of the shared app for the engine this build runs, nothing when the check cannot decide.
    package func staleFrameworkEntries(except excluded: Set<String>? = nil) -> [StaleFrameworks.Entry] {
        guard let chain = StaleFrameworks.currentChain(engineRoot: EngineLayout.root(repo.path)) else { return [] }
        let root = shellRoot
        let known = ShellLibrary.load(root: root).games.map { (titleID: $0.titleID, name: $0.name, framework: $0.framework) }
        let found = StaleFrameworks.find(root: root, chain: chain, known: known, except: excluded == nil ? buildKey : "")
        guard let excluded else { return found }
        let skip = Set(excluded.map { $0.uppercased() })
        return found.filter { !skip.contains($0.titleID.uppercased()) }
    }

    /// True when the build must wait for the player's answer: the prompt is showing (`staleFrameworks` is set).
    package func askAboutStaleFrameworks(except excluded: Set<String>? = nil, then after: (() -> Void)? = nil) -> Bool {
        let entries = staleFrameworkEntries(except: excluded)
        guard !entries.isEmpty else { return false }
        afterStaleFrameworks = after
        staleFrameworks = entries
        return true
    }

    /// Stop the build: nothing was touched.
    package func stopForStaleFrameworks() {
        afterStaleFrameworks = nil
        staleFrameworks = []
    }

    /// Continue: delete the stale frameworks, drop their games from the shell's library, and start the build.
    package func continueWithStaleFrameworks(then start: (() -> Void)? = nil) {
        let entries = staleFrameworks
        let continuation = start ?? afterStaleFrameworks
        afterStaleFrameworks = nil
        staleFrameworks = []
        let failed = Self.removeStaleFrameworks(entries, root: shellRoot)
        if !failed.isEmpty {
            done = false
            doneNote = String(format: t("stale.removeFailed"), failed.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))
            return
        }
        (continuation ?? runBuild)()
    }

    /// The folders of `entries` are deleted and the games leave `<root>/shell.json`. Returns the folders that could not be deleted.
    package static func removeStaleFrameworks(_ entries: [StaleFrameworks.Entry], root: String) -> [String] {
        let failed = StaleFrameworks.remove(entries)
        var library = ShellLibrary.load(root: root)
        let gone = Set(entries.map { $0.titleID.lowercased() })
        library.games.removeAll { gone.contains($0.titleID.lowercased()) }
        try? library.save(root: root)
        return failed
    }
}
