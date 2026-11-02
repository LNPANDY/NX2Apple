import Foundation

/// What the launcher knows about a repository folder without running anything: whether it is one, which build tools it has, and
/// which checkout to use when the player has not chosen one. `RepoStore` calls these.
package enum RepoLayout {
    /// Every file of the repository the launcher itself runs by path: one list, next to the calls that use it
    /// (the build script in startBuild, the RomFS archive in the archive step). A copy older than this app lacks some of
    /// them (#87: romfs_image.py exists since v0.4.8, so a build ran 70 minutes and failed at its last step). A new
    /// tool the launcher calls goes into this list and is then checked before every build.
    package static let buildScript = "scripts/build_ipa_from_nsp.py"
    package static let romfsImageTool = "dm/tools/romfs_image.py"
    package static let requiredTools = [buildScript, romfsImageTool]

    /// Home shown as ~ (shorter in a one-line row, and it keeps the account name out of screenshots).
    package static func shortPath(_ path: String, home: String = NSHomeDirectory()) -> String {
        path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// A checkout with tools/engine.py, a synced engine/, or an engine tree (#214).
    package static func isRepo(_ dir: String) -> Bool {
        EngineLayout.isCheckout(dir)
    }

    /// The tools of `requiredTools` that `dir` does not have (empty: the build tools are as new as this app needs).
    package static func missingTools(in dir: String) -> [String] {
        let root = EngineLayout.root(dir)   // the checkout's engine/, or an engine tree itself
        return requiredTools.filter { !FileManager.default.fileExists(atPath: root + "/" + $0) }
    }

    /// Whether the checkout's build script has this fork's `--work-dir` (issue #5): an upstream
    /// nxnative checkout, or a ZIP of an older release, stops with "unrecognized arguments" when the
    /// app passes it. Read from the script's own argparse rather than assumed — the option is the
    /// fork's, not upstream's.
    package static func supportsWorkDir(_ dir: String) -> Bool {
        let script = EngineLayout.root(dir) + "/" + buildScript
        if !FileManager.default.fileExists(atPath: script), EngineLayout.hasEngineTool(dir) { return true }   // engine/ not made yet: the fork's engine has it
        guard let text = try? String(contentsOfFile: script, encoding: .utf8) else { return false }
        return text.contains("'--work-dir'") || text.contains("\"--work-dir\"")
    }

    /// The checkout of this repository the app drives. A released .app ships on its own,
    /// so the path is not known at build time: look next to the app bundle, walk up from
    /// it, then fall back to a saved choice. A repository is identified by
    /// dm/tools/nx_extract/Program.cs, which only exists in a real checkout.
    package static func find(defaults: UserDefaults = .standard, bundleURL: URL = Bundle.main.bundleURL,
                             currentDirectory: String = FileManager.default.currentDirectoryPath, home: String = NSHomeDirectory()) -> String {
        // A candidate that is merely a repository (an upstream nxnative clone) must lose to one
        // carrying this fork's `--work-dir`: building from an upstream checkout fails with
        // "unrecognized arguments" after the app has already picked it — and a saved path from an
        // earlier session pointed at exactly such a clone, so every build said 仓库不是最新版本
        // (the report's build log). The fork check is the script's own argparse, not a name match,
        // so a checkout under any folder name ranks correctly.
        let saved = defaults.string(forKey: "repoPath").flatMap { isRepo($0) ? $0 : nil }
        var seeds: [String] = []
        // the app bundle: …/frontend/NX2Apple.app/Contents/MacOS — the checkout it ships from wins
        let bundle = bundleURL.standardizedFileURL
        seeds.append(bundle.deletingLastPathComponent().path)
        seeds.append(bundle.deletingLastPathComponent().deletingLastPathComponent()
                         .deletingLastPathComponent().deletingLastPathComponent().path)
        seeds.append(currentDirectory)
        for base in ["/ZCodeProject/", "/", "/Documents/", "/Desktop/"] {
            seeds.append(home + base + "nxnative-romfs-archive")   // clones made before the rename still resolve
            seeds.append(home + base + "NX2Apple")
            seeds.append(home + base + "nxnative")                 // an upstream clone: last resort
        }
        var seen = Set<String>()
        var repos: [String] = []
        for s in seeds where !s.isEmpty && seen.insert(s).inserted {
            var d = s
            for _ in 0..<5 {                       // walk up a few levels from each seed
                if isRepo(d) { repos.append(d); break }
                let up = (d as NSString).deletingLastPathComponent
                if up == d || up == "/" { break }
                d = up
            }
        }
        let forks = repos.filter { supportsWorkDir($0) }
        if let saved, supportsWorkDir(saved) { return saved }   // the player's own fork checkout
        if let f = forks.first, f != saved {
            if let saved { fputs("launcher: using the fork checkout \(f); the saved repository \(saved) is an upstream clone without --work-dir\n", stderr) }
            return f
        }
        return saved ?? repos.first ?? ""
    }
}
