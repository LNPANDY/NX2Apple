import Foundation

/// Where the engine of a checkout is: the part of `EngineLayout` that needs only the file system (the rest, the stale check and the
/// sync, is in the app target, `Engine.swift`, which explains the rule). `RepoLayout` and `RepoStore` need these.
package enum EngineLayout {
    /// The file that tells an engine tree.
    package static let marker = "dm/tools/nx_extract/Program.cs"

    package static func hasEngineTool(_ repo: String) -> Bool {
        let fm = FileManager.default
        return !repo.isEmpty && fm.fileExists(atPath: repo + "/tools/engine.py") && fm.fileExists(atPath: repo + "/.upstream-ref")
    }

    /// The folder holding dm/ and scripts/ for this checkout: its `engine/` when it can make one, else the folder when it is an
    /// engine tree itself, else `engine/` as it is.
    package static func root(_ repo: String) -> String {
        guard !repo.isEmpty else { return repo }
        let fm = FileManager.default
        if hasEngineTool(repo) { return repo + "/engine" }
        if fm.fileExists(atPath: repo + "/" + marker) { return repo }
        return fm.fileExists(atPath: repo + "/engine/" + marker) ? repo + "/engine" : repo
    }

    /// A folder the launcher can build from: a checkout with tools/engine.py to make engine/, a synced engine/, or an engine tree.
    package static func isCheckout(_ dir: String) -> Bool {
        let fm = FileManager.default
        return !dir.isEmpty && (fm.fileExists(atPath: dir + "/" + marker) || fm.fileExists(atPath: dir + "/engine/" + marker) || hasEngineTool(dir))
    }
}
