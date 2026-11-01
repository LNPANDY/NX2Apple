import SwiftUI
import NXCore

// LNPANDY/NX2Apple#449: a build for the iPhone or iPad asks before the long steps when the shell folder holds frameworks of
// another shader chain than the engine this build uses. Stop leaves every file as it is. Continue deletes the stale frameworks
// (and their entries in the shell's library) and starts the build again. Without stale frameworks nothing is asked. A framework
// whose chain cannot be read is not decided here, build_shell.sh's own check at the last step stays for it.

extension BuildModel {
    /// The stale frameworks of the shared app for the engine this build runs, nothing when the check cannot decide.
    func staleFrameworkEntries() -> [StaleFrameworks.Entry] {
        guard let chain = StaleFrameworks.currentChain(engineRoot: EngineLayout.root(repoPath)) else { return [] }
        let root = shellRoot
        let known = ShellLibrary.load(root: root).games.map { (titleID: $0.titleID, name: $0.name, framework: $0.framework) }
        return StaleFrameworks.find(root: root, chain: chain, known: known, except: Self.buildKey(basePath))
    }

    /// True when the build must wait for the player's answer: the prompt is showing (`staleFrameworks` is set).
    func askAboutStaleFrameworks() -> Bool {
        let entries = staleFrameworkEntries()
        guard !entries.isEmpty else { return false }
        staleFrameworks = entries
        return true
    }

    /// Stop the build: nothing was touched.
    func stopForStaleFrameworks() { staleFrameworks = [] }

    /// Continue: delete the stale frameworks, drop their games from the shell's library, and start the build.
    func continueWithStaleFrameworks(then start: (() -> Void)? = nil) {
        let entries = staleFrameworks
        staleFrameworks = []
        let failed = Self.removeStaleFrameworks(entries, root: shellRoot)
        if !failed.isEmpty {
            done = false
            doneNote = String(format: t("stale.removeFailed"), failed.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))
            return
        }
        (start ?? startBuild)()
    }

    /// The folders of `entries` are deleted and the games leave `<root>/shell.json`. Returns the folders that could not be deleted.
    static func removeStaleFrameworks(_ entries: [StaleFrameworks.Entry], root: String) -> [String] {
        let failed = StaleFrameworks.remove(entries)
        var library = ShellLibrary.load(root: root)
        let gone = Set(entries.map { $0.titleID.lowercased() })
        library.games.removeAll { gone.contains($0.titleID.lowercased()) }
        try? library.save(root: root)
        return failed
    }
}

private struct StaleFrameworksPrompt: ViewModifier {
    @ObservedObject var m: BuildModel

    func body(content: Content) -> some View {
        content.alert(m.t("stale.title"), isPresented: Binding(get: { !m.staleFrameworks.isEmpty },
                                                                set: { if !$0 { m.stopForStaleFrameworks() } })) {
            Button(m.t("stale.go")) { m.continueWithStaleFrameworks() }
            Button(m.t("stale.stop"), role: .cancel) { m.stopForStaleFrameworks() }
        } message: {
            Text(String(format: m.t("stale.message"), StaleFrameworks.list(m.staleFrameworks)))
        }
    }
}

extension View {
    func staleFrameworksPrompt(_ m: BuildModel) -> some View { modifier(StaleFrameworksPrompt(m: m)) }
}
