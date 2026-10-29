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
        var forkPatches: [String]?           // dm/fork_patches.txt of the checkout; nil when the file is not there
        var toolchain = Toolchain()
        var game: GameInfo?                  // the library's selected game
        var lastCommand: [String] = []       // the last build's, this session
        var log = ""                         // the build log the Builds page shows
        var home = NSHomeDirectory()
    }

    /// What Xcode and its compilers say, for the build-problem form. A nil is a tool that did not answer.
    struct Toolchain: Equatable {
        var xcodePath: String?
        var xcodeVersion: String?
        var metalMac: String?
        var metalIOS: String?
        var metalPinMac: String?             // dm/gfx/tools/dmsh_chain.lock
        var metalPinIOS: String?
        var iosSDK: String?
    }

    /// The selected game, for the game-problem form: what its app was built with and the end of its log.
    struct GameInfo: Equatable {
        var name: String
        var titleID: String
        var builtForkPatches: String?        // DMForkPatches of the built Mac app; nil when the app has none
        var logPath: String?                 // nil: the game was never run
        var log: [String] = []
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
                line += ", " + i.behind.map { "\($0.count) behind \($0.ref)" }.joined(separator: ", ")
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
        out.append("- Fork patches: " + patches(i.forkPatches))
        let t = i.toolchain
        out.append("- Xcode: " + (t.xcodePath ?? "not found") + parenthesized([t.xcodeVersion]))
        out.append("- Metal compiler (macOS): " + metal(t.metalMac, pin: t.metalPinMac))
        out.append("- Metal compiler (iOS): " + metal(t.metalIOS, pin: t.metalPinIOS))
        out.append("- iOS SDK: " + (t.iosSDK ?? "not installed"))
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
        if let g = i.game {
            out.append("")
            out.append("#### Selected game")
            out.append("")
            out.append("- Game: \(g.name) (\(g.titleID))")
            out.append("- Fork patches of the built app: " + (g.builtForkPatches.map { $0.isEmpty ? "none" : $0.replacingOccurrences(of: ",", with: ", ") } ?? "no Mac app built"))
            if g.logPath == nil {
                out.append("- Game log: none yet, the game was not run")
            } else {
                out.append("- Game log: \(g.logPath ?? "")")
                let lines = tailOf(g.log, GameLog.lines)
                if !lines.isEmpty {
                    out.append("")
                    out.append("Last \(lines.count) game log lines:")
                    out.append("")
                    out.append("````text")
                    out += lines.map(redact)
                    out.append("````")
                }
            }
        }
        return shortenHome(out.joined(separator: "\n") + "\n", home: i.home)
    }

    private static func tailOf(_ lines: [String], _ n: Int) -> [String] { Array(lines.suffix(n)) }

    private static func patches(_ list: [String]?) -> String {
        guard let list else { return "not found" }
        return list.isEmpty ? "none" : list.joined(separator: ", ")
    }

    /// A compiler's version beside the one the translation chain was built with.
    private static func metal(_ found: String?, pin: String?) -> String {
        guard let found else { return "not installed" + (pin.map { " (pin: \($0))" } ?? "") }
        guard let pin else { return found }
        return found + (found == pin ? " (matches the pin)" : " (pin: \(pin))")
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

    /// The checkout's fork patch names, one per line (dm/fork_patches.txt), blanks left out, as pack_app.py reads them.
    static func patchList(_ text: String) -> [String] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The Metal compiler versions the chain was built with: `metal_macosx` and `metal_iphoneos` of dmsh_chain.lock (tab-separated).
    static func chainPins(_ lock: String) -> (mac: String?, ios: String?) {
        var pins: [String: String] = [:]
        for line in lock.split(separator: "\n") where !line.hasPrefix("#") {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            if parts.count == 2 { pins[parts[0]] = parts[1].trimmingCharacters(in: .whitespaces) }
        }
        return (pins["metal_macosx"], pins["metal_iphoneos"])
    }

    /// A command's output when it exits 0, trimmed; nil when it fails or prints nothing. The tests stand in for BuildModel.runQuiet.
    typealias Probe = (_ args: [String]) -> String?

    static func probe(env: [String: String] = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin", "TMPDIR": NSTemporaryDirectory()]) -> Probe {
        { args in
            guard FileManager.default.isExecutableFile(atPath: args[0]) else { return nil }
            let r = BuildModel.runQuiet(args, env: env)
            let s = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
            return r.ok && !s.isEmpty ? s : nil
        }
    }

    /// Xcode's path and version, both Metal compilers and the iOS SDK, by the same tools the dependency check runs. Only the
    /// first line of a compiler's answer is kept: the rest names the toolchain's folder.
    static func toolchain(xcrun: String = "/usr/bin/xcrun", pins: (mac: String?, ios: String?) = (nil, nil), run: Probe) -> Toolchain {
        func first(_ s: String?) -> String? { s?.split(separator: "\n").first.map(String.init) }
        return Toolchain(
            xcodePath: first(run(["/usr/bin/xcode-select", "-p"])),
            xcodeVersion: run(["/usr/bin/xcodebuild", "-version"]).map { $0.split(separator: "\n").map(String.init).joined(separator: ", ") },
            metalMac: first(run([xcrun, "-sdk", "macosx", "metal", "--version"])),
            metalIOS: first(run([xcrun, "-sdk", "iphoneos", "metal", "--version"])),
            metalPinMac: pins.mac, metalPinIOS: pins.ios,
            iosSDK: first(run([xcrun, "--sdk", "iphoneos", "--show-sdk-version"])))
    }

    /// The selected game's section: the built app's DMForkPatches and the end of its latest log.
    static func gameInfo(_ game: LibraryGame, home: String = NSHomeDirectory(), lines: Int = GameLog.lines) -> GameInfo {
        let info = NSDictionary(contentsOfFile: game.appPath + "/Contents/Info.plist")
        let log = GameLog.latest(titleID: game.titleID, appPath: game.appPath, home: home)
        return GameInfo(name: game.name, titleID: game.titleID,
                        builtForkPatches: info.map { ($0["DMForkPatches"] as? String) ?? "" },
                        logPath: log?.path, log: log.flatMap { GameLog.tail($0, lines: lines) } ?? [])
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
    func diagnostics(game: LibraryGame? = nil, _ done: @escaping (String) -> Void) {
        let repo = repoOK ? repoPath : "", python = pythonPath.isEmpty ? Self.findPython().path : pythonPath, dotnet = dotnetPath
        let rows = depsChecked ? deps.map(Diagnostics.dependency) : [], checked = depsChecked
        let command = lastBuildCommand, log = logTail, xcrun = xcrunPath
        DispatchQueue.global(qos: .userInitiated).async {
            let git = Diagnostics.git(repo)
            let env = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin", "TMPDIR": NSTemporaryDirectory()]
            var dotnetEnv = env
            if !dotnet.isEmpty { dotnetEnv["DOTNET_ROOT"] = (dotnet as NSString).deletingLastPathComponent }
            let read = { (file: String) in try? String(contentsOfFile: repo + "/" + file, encoding: .utf8) }
            let pins = read("dm/gfx/tools/dmsh_chain.lock").map(Diagnostics.chainPins) ?? (nil, nil)
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
                depsChecked: checked, deps: rows,
                forkPatches: repo.isEmpty ? nil : read("dm/fork_patches.txt").map(Diagnostics.patchList),
                toolchain: Diagnostics.toolchain(xcrun: xcrun, pins: pins, run: Diagnostics.probe(env: env)),
                game: game.map { Diagnostics.gameInfo($0) },
                lastCommand: command, log: log)
            let report = Diagnostics.report(inputs)
            DispatchQueue.main.async { done(report) }
        }
    }
}

/// Settings' Copy diagnostics: the report goes to the clipboard and the button says Copied for a moment.
struct DiagnosticsButton: View {
    @ObservedObject var m: BuildModel
    var game: LibraryGame?   // the library's selected game: its log goes in the report
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
        m.diagnostics(game: game) { report in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report, forType: .string)
            busy = false
            withAnimation(.easeOut(duration: 0.15)) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { withAnimation(.easeOut(duration: 0.2)) { copied = false } }
        }
    }
}
