import CryptoKit
import Foundation

/// Where the engine of a checkout is, and whether it needs `tools/engine.py sync` (LNPANDY/NX2Apple#214).
///
/// Since #214 the engine is built into `<checkout>/engine/`: seedds/nxnative at `.upstream-ref` plus `patches/`, made by
/// `tools/engine.py sync`. Until the committed copy goes (step 2), a checkout has both, and one from before the switch has only the
/// committed copy. The rule, the same as the Qt front end's (frontend-qt/nspb_qt/engine.py):
///
/// - `engine/` when it is synced and current,
/// - else the committed tree (`dm/`, `scripts/` at the checkout's root) when the checkout has one,
/// - else `engine/` as it is (stale or missing: the build syncs it first).
///
/// `stampKey` is tools/engine.py's digest of the pin and the series, compared with the stamp sync wrote into engine/.git, so the
/// launcher tells a stale engine without starting Python. A release app carries the synced engine as `Resources/engine.git`
/// (build-mac-app.yml), the seed sync fetches from before it goes to the network.
enum EngineLayout {
    /// The file that tells an engine tree (BuildModel.isRepo always looked for it).
    static let marker = "dm/tools/nx_extract/Program.cs"

    static func hasEngineTool(_ repo: String) -> Bool {
        let fm = FileManager.default
        return !repo.isEmpty && fm.fileExists(atPath: repo + "/tools/engine.py") && fm.fileExists(atPath: repo + "/.upstream-ref")
    }

    static func series(_ repo: String) -> [String]? {
        guard let text = try? String(contentsOfFile: repo + "/patches/series", encoding: .utf8) else { return nil }
        return text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line in
            let s = (line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? "").trimmingCharacters(in: .whitespaces)
            return s.isEmpty ? nil : s
        }
    }

    static func hex(_ d: SHA256.Digest) -> String { d.map { String(format: "%02x", $0) }.joined() }

    /// tools/engine.py's stamp_key: sha256 of "pin <sha>\n", then "patch <name>\n<sha256 of the file>\n" for each patch in order.
    static func stampKey(_ repo: String) -> String? {
        guard let pin = try? String(contentsOfFile: repo + "/.upstream-ref", encoding: .utf8), let names = series(repo) else { return nil }
        var h = SHA256()
        h.update(data: Data(("pin " + pin.trimmingCharacters(in: .whitespacesAndNewlines) + "\n").utf8))
        for name in names {
            guard let data = FileManager.default.contents(atPath: repo + "/patches/" + name) else { return nil }
            h.update(data: Data(("patch " + name + "\n" + hex(SHA256.hash(data: data)) + "\n").utf8))
        }
        return hex(h.finalize())
    }

    /// HEAD of engine/ read from its files (no git process): the detached id, or the id its branch points to.
    static func head(_ eng: String) -> String {
        func read(_ p: String) -> String? { (try? String(contentsOfFile: eng + "/.git/" + p, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let h = read("HEAD") else { return "" }
        guard h.hasPrefix("ref: ") else { return h }
        let ref = String(h.dropFirst(5))
        if let id = read(ref) { return id }
        for line in (read("packed-refs") ?? "").split(separator: "\n") where line.hasSuffix(" " + ref) {
            return String(line.split(separator: " ").first ?? "")
        }
        return ""
    }

    /// True when the checkout can make engine/ and engine/ is missing or not built from the current pin and series.
    static func isStale(_ repo: String) -> Bool {
        guard hasEngineTool(repo) else { return false }
        let eng = repo + "/engine"
        guard let text = try? String(contentsOfFile: eng + "/.git/nx2apple-stamp", encoding: .utf8) else { return true }
        var stamp: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let kv = line.split(separator: " ", maxSplits: 1)
            if kv.count == 2 { stamp[String(kv[0])] = String(kv[1]) }
        }
        return stamp["key"] != stampKey(repo) || stamp["head"] != head(eng)
    }

    /// The folder holding dm/ and scripts/ for this checkout (see the rule above).
    static func root(_ repo: String) -> String {
        guard !repo.isEmpty else { return repo }
        let fm = FileManager.default
        if fm.fileExists(atPath: repo + "/engine/" + marker) && !isStale(repo) { return repo + "/engine" }
        if fm.fileExists(atPath: repo + "/" + marker) { return repo }
        return hasEngineTool(repo) ? repo + "/engine" : repo
    }

    /// A checkout the launcher can build from: the committed tree, a synced engine/, or tools/engine.py to make one.
    static func isCheckout(_ dir: String) -> Bool {
        let fm = FileManager.default
        return !dir.isEmpty && (fm.fileExists(atPath: dir + "/" + marker) || fm.fileExists(atPath: dir + "/engine/" + marker) || hasEngineTool(dir))
    }

    /// engine/ is the only engine and it is stale or missing (after step 2, or a checkout whose committed tree is gone).
    static func needsSyncBeforeBuild(_ repo: String) -> Bool {
        hasEngineTool(repo) && isStale(repo) && !FileManager.default.fileExists(atPath: repo + "/" + marker)
    }

    /// The engine a release app carries (build-mac-app.yml), when this is such an app.
    static func seed(in resources: URL? = BundledTools.resources) -> String? {
        guard let dir = resources?.appendingPathComponent("engine.git"), FileManager.default.fileExists(atPath: dir.path + "/HEAD") else { return nil }
        return dir.path
    }

    /// `python tools/engine.py [--seed <the app's engine.git>] sync`
    static func syncArguments(repo: String, python: String, seed: String? = EngineLayout.seed()) -> [String] {
        [python, repo + "/tools/engine.py"] + (seed.map { ["--seed", $0] } ?? []) + ["sync"]
    }

    /// Run the sync and stream its lines (blocking: call it off the main thread). git comes from the system's or Homebrew's PATH.
    static func runSync(repo: String, python: String, line: @escaping (String) -> Void) -> Bool {
        let env = ["PATH": BuildModel.toolPath("/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin", python: python), "HOME": NSHomeDirectory(),
                   "LANG": "en_US.UTF-8", "TMPDIR": NSTemporaryDirectory()].merging(BundledTools.environment(for: python)) { $1 }
        return BuildModel.runCaptured(syncArguments(repo: repo, python: python), env: env, line: line)
    }
}
