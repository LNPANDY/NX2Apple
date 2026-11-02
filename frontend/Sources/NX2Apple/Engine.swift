import CryptoKit
import Foundation
import NXCore
import NXLauncher

/// Where the engine of a checkout is, and whether it needs `tools/engine.py sync` (LNPANDY/NX2Apple#214).
///
/// The engine is not committed: it is built into `<checkout>/engine/` (seedds/nxnative at `.upstream-ref` plus `patches/`) by
/// `tools/engine.py sync`. The rule, the same as the Qt front end's (frontend-qt/nspb_qt/engine.py):
///
/// - a checkout of this repository (it has `tools/engine.py` and `.upstream-ref`): `engine/`, which the build syncs first when it is
///   stale or missing,
/// - else a folder that is an engine tree itself (`dm/` at its root: the engine a release carries or installs, #227, or a
///   seedds/nxnative clone): that folder,
/// - else `engine/` as it is.
///
/// `stampKey` is tools/engine.py's digest of the pin and the series, compared with the stamp sync wrote into engine/.git, so the
/// launcher tells a stale engine without starting Python. The sync is for a repository checkout (a developer's,
/// or one a launcher cloned): it downloads the pinned engine from GitHub (about 80 MB) and shows a failure row when that does not work.
/// A release app carries the engine tree instead (`Contents/Resources/engine`, built by `tools/engine.py tree`, #227) and takes updates
/// from the release's `latest.json`: no git, no sync.
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
        if hasEngineTool(repo) { return repo + "/engine" }
        if fm.fileExists(atPath: repo + "/" + marker) { return repo }
        return fm.fileExists(atPath: repo + "/engine/" + marker) ? repo + "/engine" : repo
    }

    /// A folder the launcher can build from: a checkout with tools/engine.py to make engine/, a synced engine/, or an engine tree.
    static func isCheckout(_ dir: String) -> Bool {
        let fm = FileManager.default
        return !dir.isEmpty && (fm.fileExists(atPath: dir + "/" + marker) || fm.fileExists(atPath: dir + "/engine/" + marker) || hasEngineTool(dir))
    }

    /// engine/ is the only engine and it is stale or missing: the build syncs it first.
    static func needsSyncBeforeBuild(_ repo: String) -> Bool {
        hasEngineTool(repo) && isStale(repo)
    }

    /// `python tools/engine.py sync`
    static func syncArguments(repo: String, python: String) -> [String] {
        [python, repo + "/tools/engine.py", "sync"]
    }

    /// What a failed sync was, from its output: the fetch of the pinned commit (no network, GitHub unreachable, a proxy) says
    /// "cannot fetch" (tools/engine.py), anything else is a sync that could not build the engine.
    static func failureKind(_ log: String) -> BuildFailureKind {
        log.contains("cannot fetch ") ? .engineOffline : .engineSync
    }

    /// Run the sync and stream its lines (blocking: call it off the main thread). git comes from the system's or Homebrew's PATH.
    static func runSync(repo: String, python: String, runner: ProcessRunner = SystemProcessRunner(), line: @escaping (String) -> Void) -> Bool {
        let env = ["PATH": BuildModel.toolPath("/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin", python: python), "HOME": NSHomeDirectory(),
                   "LANG": "en_US.UTF-8", "TMPDIR": NSTemporaryDirectory()].merging(BundledTools.environment(for: python)) { $1 }
        return runner.runCaptured(syncArguments(repo: repo, python: python), env: env, line: line)
    }
}
