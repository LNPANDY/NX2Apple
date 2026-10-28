import AppKit
import SwiftUI

/// Copy diagnostics (#69): a short Markdown report for a bug report — the app, the Mac, the checkout and how far behind it
/// is, the Python and .NET the builds really use, the dependency check, and the last build's command line with the end of
/// its log. Written in English whatever the interface language, for whoever reads the issue.
///
/// Private by construction: the home folder is shown as ~, a log line that looks like key material (`name = <hex>`, the
/// form of prod.keys and title.keys) has its value replaced, and nothing comes from the environment. The checkout's
/// distance from main is what git already knows: nothing is fetched.
struct Diagnostics {
    struct Dependency: Equatable { var name: String; var present: Bool; var detail: String }

    struct Inputs {
        var appVersion: String
        var macOS: String
        var chip: String
        var repoPath: String
        var commit: String?                  // "<short hash> <subject>"
        var branch: String?
        var behind: [(ref: String, count: Int)] = []   // upstream/main, origin/main: the ones this checkout has
        var lastFetch: Date?
        var python: String
        var pythonVersion: String?
        var pythonIsVenv = false             // the launcher's own venv (BuildModel.venvDir)
        var dotnet: String
        var dotnetVersion: String?
        var depsChecked = true
        var deps: [Dependency] = []
        var lastCommand: [String] = []       // the last build's, this session
        var log = ""                         // the build log the Builds page shows
        var home = NSHomeDirectory()
    }

    static let logLines = 50

    static func report(_ i: Inputs) -> String {
        var out: [String] = ["### NX2Apple diagnostics", ""]
        out.append("- App: NX2Apple \(i.appVersion)")
        out.append("- macOS: \(i.macOS)")
        out.append("- Chip: \(i.chip)")
        out.append("- Repository: \(i.repoPath.isEmpty ? "not found" : i.repoPath)")
        if let commit = i.commit {
            var line = "- Commit: \(commit)" + (i.branch.map { " (branch \($0))" } ?? "")
            if !i.behind.isEmpty {
                line += "; " + i.behind.map { "\($0.count) behind \($0.ref)" }.joined(separator: ", ")
                if let fetched = i.lastFetch { line += " as of the last fetch, " + stamp(fetched) }
            }
            out.append(line)
        } else if !i.repoPath.isEmpty {
            out.append("- Commit: not a git checkout")
        }
        out.append("- Python: \(i.python.isEmpty ? "not found" : i.python)"
                   + parenthesized([i.pythonVersion, i.pythonIsVenv ? "the launcher's venv" : nil]))
        out.append("- .NET: \(i.dotnet.isEmpty ? "not found" : i.dotnet)" + parenthesized([i.dotnetVersion]))
        if !i.depsChecked {
            out.append("- Dependencies: not checked yet")
        } else {
            let missing = i.deps.filter { !$0.present }
            out.append("- Dependencies: " + (missing.isEmpty ? "all present" : "\(missing.count) missing"))
            for d in i.deps { out.append("  - \(d.present ? "ok" : "MISSING") \(d.name)" + (d.detail.isEmpty ? "" : ": \(d.detail)")) }
        }
        out.append("")
        out.append("#### Last build")
        out.append("")
        if i.lastCommand.isEmpty {
            out.append("No build in this session.")
        } else {
            out.append("````sh")
            out.append(i.lastCommand.map(quoted).joined(separator: " "))
            out.append("````")
        }
        let tail = tail(i.log)
        if !tail.isEmpty {
            out.append("")
            out.append("Last \(tail.count) log lines:")
            out.append("")
            out.append("````text")
            out += tail.map(redact)
            out.append("````")
        }
        return shortenHome(out.joined(separator: "\n") + "\n", home: i.home)
    }

    /// The home folder as ~ wherever it starts a path, and only there: /Users/jo becomes ~, /Users/joanna stays.
    static func shortenHome(_ text: String, home: String) -> String {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard home.count > 1, let re = try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: home) + "(?=/|$|[^A-Za-z0-9._-])",
                                                               options: [.anchorsMatchLines]) else { return text }
        return re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "~")
    }

    /// A line that carries key material — `name = <16 or more hex digits>`, as in prod.keys and title.keys — keeps its
    /// name and loses its value. A build ID or hash printed with a colon stays: it identifies the build, not a secret.
    static func redact(_ line: String) -> String {
        guard let re = try? NSRegularExpression(pattern: #"([A-Za-z0-9_\-]+\s*=\s*)(0x)?[0-9A-Fa-f]{16,}"#) else { return line }
        return re.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "$1[redacted]")
    }

    /// The log's last lines, without the trailing blank one.
    static func tail(_ log: String, lines n: Int = logLines) -> [String] {
        var lines = log.components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return Array(lines.suffix(n))
    }

    static func quoted(_ arg: String) -> String {
        arg.isEmpty || arg.contains(where: { " '\"$\\".contains($0) }) ? "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'" : arg
    }

    private static func parenthesized(_ parts: [String?]) -> String {
        let p = parts.compactMap { $0 }.filter { !$0.isEmpty }
        return p.isEmpty ? "" : " (" + p.joined(separator: ", ") + ")"
    }

    private static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    /// A dependency row in English: its name and what the check said (a path, or a message with its argument).
    static func dependency(_ d: BuildModel.Dep) -> Dependency {
        let en = { (key: String) in L10n.string(key, .en) }
        var detail = d.detail
        if let colon = detail.firstIndex(of: ":"), !detail.hasPrefix("/"), L10n.table[String(detail[..<colon])] != nil {
            // The remainder carries one argument per ":"-separated part, as the UI's depDetail
            // reads it: passing it whole left every format after the first %@ with "(null)"
            // ("install one (brew install python@(null))" in a copied diagnostics block).
            let args = detail[detail.index(after: colon)...].components(separatedBy: ":").map { $0 as CVarArg }
            detail = String(format: en(String(detail[..<colon])), arguments: args)
        } else if L10n.table[detail] != nil {
            detail = en(detail)
        }
        return Dependency(name: en(d.name), present: d.present, detail: detail)
    }

    // ---- what the report is made of, read from this Mac (in the background: git, python and dotnet each run once) ----

    static func chip() -> String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: buffer)
    }

    /// The commit, branch and distance from main of a checkout, from its own refs.
    static func git(_ repo: String) -> (commit: String?, branch: String?, behind: [(ref: String, count: Int)], lastFetch: Date?) {
        guard !repo.isEmpty, FileManager.default.fileExists(atPath: repo + "/.git"), let git = BuildModel.gitBinary() else { return (nil, nil, [], nil) }
        func run(_ args: [String]) -> String? {
            let r = BuildModel.runQuiet([git, "-C", repo] + args, env: BuildModel.gitEnv())
            let s = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
            return r.ok && !s.isEmpty ? s : nil
        }
        let commit = run(["log", "-1", "--format=%h %s"])
        let branch = run(["rev-parse", "--abbrev-ref", "HEAD"])
        let behind = ["upstream/main", "origin/main"].compactMap { ref -> (ref: String, count: Int)? in
            guard run(["rev-parse", "--verify", "--quiet", ref]) != nil, let n = run(["rev-list", "--count", "HEAD.." + ref]).flatMap({ Int($0) }) else { return nil }
            return (ref, n)
        }
        let fetchHead = run(["rev-parse", "--git-path", "FETCH_HEAD"]).map { $0.hasPrefix("/") ? $0 : repo + "/" + $0 }   // a worktree keeps it elsewhere
        let fetched = fetchHead.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date }
        return (commit, branch, behind, fetched)
    }

    /// What a tool prints for its version, nil when it does not run.
    static func version(_ tool: String, _ args: [String], env: [String: String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: tool) else { return nil }
        let r = BuildModel.runQuiet([tool] + args, env: env)
        let s = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.ok && !s.isEmpty ? String(s.split(separator: "\n").last ?? "") : nil
    }
}

extension BuildModel {
    /// The report, read in the background and handed back on the main thread.
    func diagnostics(_ done: @escaping (String) -> Void) {
        let repo = repoOK ? repoPath : "", python = pythonPath.isEmpty ? Self.findPython().path : pythonPath, dotnet = dotnetPath
        let rows = depsChecked ? deps.map(Diagnostics.dependency) : [], checked = depsChecked
        let command = lastBuildCommand, log = logTail
        DispatchQueue.global(qos: .userInitiated).async {
            let git = Diagnostics.git(repo)
            let env = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin", "TMPDIR": NSTemporaryDirectory()]
            var dotnetEnv = env
            if !dotnet.isEmpty { dotnetEnv["DOTNET_ROOT"] = (dotnet as NSString).deletingLastPathComponent }
            let inputs = Diagnostics.Inputs(
                appVersion: Self.appVersion,
                macOS: ProcessInfo.processInfo.operatingSystemVersionString,
                chip: Diagnostics.chip(),
                repoPath: repo, commit: git.commit, branch: git.branch, behind: git.behind, lastFetch: git.lastFetch,
                python: python,
                pythonVersion: Diagnostics.version(python, ["-c", "import sys; print(sys.version.split()[0])"], env: env),
                pythonIsVenv: python == Self.venvPython(),
                dotnet: dotnet,
                dotnetVersion: dotnet.isEmpty ? nil : Diagnostics.version(dotnet, ["--version"], env: dotnetEnv),
                depsChecked: checked, deps: rows, lastCommand: command, log: log)
            let report = Diagnostics.report(inputs)
            DispatchQueue.main.async { done(report) }
        }
    }
}

/// Settings' Copy diagnostics: the report goes to the clipboard and the button says Copied for a moment.
struct DiagnosticsButton: View {
    @ObservedObject var m: BuildModel
    let width: CGFloat
    var showCopied = false   // the visual QA's confirmation
    @State private var busy = false
    @State private var copied = false

    var body: some View {
        Button(action: copy) {
            if copied || showCopied { Label(m.t("diag.copied"), systemImage: "checkmark") } else { Text(m.t("diag.copy")) }
        }
        .buttonStyle(LauncherSecondaryButtonStyle(accent: copied || showCopied ? LauncherPalette.ready : nil, minWidth: width))
        .disabled(busy)
        .padTarget("set.diagnostics", scope: "main") { if !busy { copy() } }
    }

    private func copy() {
        busy = true
        m.diagnostics { report in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report, forType: .string)
            busy = false
            withAnimation(.easeOut(duration: 0.15)) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { withAnimation(.easeOut(duration: 0.2)) { copied = false } }
        }
    }
}
