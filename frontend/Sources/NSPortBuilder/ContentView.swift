import SwiftUI

// NS Port Builder: a macOS front end that walks a user through building a playable
// IPA from their own Switch game files. Not part of the host runtime; drives the
// repository's scripts (build_ipa_from_nsp.py, romfs_arc.py) as subprocesses.
//
// The four inputs are picked separately — base game, update, add-on content (DLC),
// prod.keys — because they are not always in one folder. When they are (the common
// case) the folder is passed straight to the script; otherwise a staging folder of
// symlinks is built and the script's --work-dir keeps the real build folder next to
// the base game.

// MARK: - Pieces

struct Stage: Identifiable {
    let id: Int          // k, the stage number in the script's own plan
    var name: String
    var state: StepState = .running
    var detail: String = ""
    var percent: Double? = nil
    var started: Date? = nil   // when the stage began here: its clock runs while the count may stand still
    var eta: Double? = nil     // the script's estimate of the seconds left, as of etaAt
    var etaAt: Date? = nil

    /// "3:42" since the stage began, then "1 min left" while the script's estimate, counted down from when it came,
    /// lasts: the estimate only arrives with a new count, so one taken as it was would stand still with the count.
    func clock(at now: Date, left: String) -> String {
        var parts: [String] = []
        if let started {
            let t = max(0, Int(now.timeIntervalSince(started)))
            parts.append(t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60))
        }
        if let eta, let etaAt {
            let remaining = eta - now.timeIntervalSince(etaAt)
            if remaining >= 1 { parts.append(String(format: left, BuildModel.duration(remaining))) }
        }
        return parts.joined(separator: " · ")
    }
}

enum StepState: Equatable {
    case pending, running, done, failed
    var icon: String {
        switch self {
        case .pending: return "circle"
        case .running: return "spinner"
        case .done: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }
    var color: Color {
        switch self {
        case .pending: return .gray
        case .running: return .yellow
        case .done: return .green
        case .failed: return .red
        }
    }
}

/// One of the four things the user points at.
enum InputKind { case base, update, dlc, keys }

struct Slot: Identifiable {
    let id: String
    let kind: InputKind
    let title: String
    let optional: Bool
    var paths: [String] = []
    var problem: String = ""
    var ok: Bool { paths.contains { FileManager.default.fileExists(atPath: $0) } }
    /// `problem` holds either a finished message or a key + arguments, resolved by the model
    /// (it needs the current language, which a struct cannot read).
    var problemText: String { problem }
    func summary(_ t: (String) -> String) -> String {
        if !problem.isEmpty { return problem.hasPrefix("data.") ? t(problem) : problem }
        if paths.isEmpty { return optional ? t("data.notSelectedOptional") : t("data.notSelected") }
        if paths.count == 1 { return (paths[0] as NSString).lastPathComponent }
        return String(format: t("data.files"), paths.count) + paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
    }
}

// MARK: - Model

final class BuildModel: ObservableObject {
    @Published var gameDir = ""
    @Published var slots: [Slot] = [
        Slot(id: "base", kind: .base, title: "data.base", optional: false),
        Slot(id: "update", kind: .update, title: "data.update", optional: true),
        Slot(id: "dlc", kind: .dlc, title: "data.dlc", optional: true),
        Slot(id: "keys", kind: .keys, title: "data.keys", optional: false),
    ]
    @Published var outDir = UserDefaults.standard.string(forKey: "buildOutputDirectory") ?? "" {
        didSet { UserDefaults.standard.set(outDir, forKey: "buildOutputDirectory") }
    }
    @Published var stages: [Stage] = []
    private var chainNoteShown = false   // the shader-chain notice shows once per build
    @Published var running = false
    @Published var stopping = false
    @Published var logTail = ""
    @Published var done = false
    @Published var doneNote = ""
    @Published var ipaPath = ""      // captured from the script's "output IPA:" line
    @Published var macAppPath = ""   // --platform mac-app: the .app this build produced
    /// 'ios' = an IPA for an iPhone; 'mac-app' = a double-clickable Mac app (upstream's
    /// --platform mac-app). A Mac app is a different output of the same pipeline, not a
    /// different pipeline: same extraction, rewrite and shaders, then dm/mac/pack_app.py.
    @Published var target = (UserDefaults.standard.string(forKey: "buildTarget") ?? "ios") {
        didSet { UserDefaults.standard.set(target, forKey: "buildTarget") }
    }
    /// Decode BC-compressed textures on the CPU. Only relevant for GPUs without BC support
    /// (A15/A16 and older): on a device that has it the GPU path is always better, so the switch
    /// is a compatibility option and defaults off. Passed as DM_TEX_BC_CPU through --env-file,
    /// which the host reads at start-up — no rebuild of the host needed.
    @Published var bcOnCPU = UserDefaults.standard.bool(forKey: "bcOnCPU") {
        didSet { UserDefaults.standard.set(bcOnCPU, forKey: "bcOnCPU") }
    }
    @Published var archivePath = ""  // the romfs folder the pack wrote
    /// Where this build's folder actually is: --work-dir when the checkout has it, else the script's
    /// default under the input folder (issue #5 — an upstream checkout has no --work-dir).
    var effectiveWorkDir = ""

    @Published var deps: [Dep] = []
    @Published var depsChecked = false
    /// Whether the dependency list is expanded. nil = not chosen yet: open while something is
    /// missing (that is when the rows matter), collapsed once everything is green — a set-up
    /// machine never needs the rows again. A manual toggle overrides and is remembered.
    @Published var depsExpanded: Bool? = UserDefaults.standard.object(forKey: "depsExpanded") as? Bool {
        didSet { if let v = depsExpanded { UserDefaults.standard.set(v, forKey: "depsExpanded") } }
    }
    var depsOpen: Bool { depsExpanded ?? !(depsChecked && allDepsPresent) }
    func toggleDeps() {
        depsExpanded = !(depsExpanded ?? !allDepsPresent)
    }
    @Published var pythonPath = ""
    @Published var dotnetPath = ""

    /// Interface language: the system's, read at every launch.
    @Published var lang: Lang = Lang.device()
    func t(_ key: String) -> String { L10n.string(key, lang) }

    private var proc: Process?
    private var lineBuf = ""
    private var staging: String?

    // ---- Process groups: Stop and quitting end the whole build ----
    // The script runs its tools as children (the shader split with its workers, dotnet, xcodebuild) and cleans
    // them up only on Ctrl-C: a SIGTERM to the script alone leaves them running, orphaned. So each build process
    // starts in a process group of its own, and Stop, quitting the app or a SIGTERM to it end the whole group.

    /// The groups of the builds running now (their leaders' PIDs).
    private static var groups = Set<pid_t>()
    private static let groupsLock = NSLock()
    private static let exitHandlers: Void = {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in endAllGroups() }
        signal(SIGTERM, SIG_IGN)   // handled below: end the builds, then exit
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        source.setEventHandler { endAllGroups(); exit(0) }
        source.resume()
        sigtermSource = source
    }()
    private static var sigtermSource: DispatchSourceSignal?

    /// Run `p` as the leader of a new process group: Python sets the group, then execs into the real command.
    /// It also restores SIGTERM and SIGINT to their defaults first: the app ignores SIGTERM (to end its builds before
    /// it exits), and an ignored signal is inherited across exec, which would make Stop's SIGTERM do nothing.
    nonisolated static func inOwnGroup(_ p: Process, python: String) {
        let command = p.executableURL?.path ?? python
        let start = "import os, signal, sys; signal.signal(signal.SIGTERM, signal.SIG_DFL); signal.signal(signal.SIGINT, signal.SIG_DFL); "
            + "os.setpgid(0, 0); os.execv(sys.argv[1], sys.argv[1:])"
        p.arguments = ["-c", start, command] + (p.arguments ?? [])
        p.executableURL = URL(fileURLWithPath: python)
    }

    private static func track(_ p: Process) {
        _ = exitHandlers
        groupsLock.lock(); groups.insert(p.processIdentifier); groupsLock.unlock()
    }

    private static func untrack(_ p: Process) {
        groupsLock.lock(); groups.remove(p.processIdentifier); groupsLock.unlock()
    }

    /// SIGTERM to every process of the group, SIGKILL 5 s later to whatever is left of it.
    nonisolated static func endGroup(_ leader: pid_t) {
        guard leader > 1 else { return }
        killpg(leader, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            if killpg(leader, 0) == 0 { killpg(leader, SIGKILL) }
        }
    }

    private static func endAllGroups() {
        groupsLock.lock(); let all = groups; groupsLock.unlock()
        for leader in all {
            killpg(leader, SIGTERM)
        }
        if !all.isEmpty {
            usleep(1_500_000)   // the app is about to exit: one grace period for the whole set, then kill what remains
            for leader in all where killpg(leader, 0) == 0 { killpg(leader, SIGKILL) }
        }
    }

    /// The checkout of this repository the app drives. A released .app ships on its own,
    /// so the path is not known at build time: look next to the app bundle, walk up from
    /// it, then fall back to a saved choice. A repository is identified by
    /// dm/tools/nx_extract/Program.cs, which only exists in a real checkout.
    @Published var repoPath: String = BuildModel.findRepo() {
        didSet { UserDefaults.standard.set(repoPath, forKey: "repoPath") }
    }

    nonisolated static func isRepo(_ dir: String) -> Bool {
        FileManager.default.fileExists(atPath: dir + "/dm/tools/nx_extract/Program.cs")
    }

    /// Whether the checkout's build script has this fork's `--work-dir` (issue #5): an upstream
    /// nxnative checkout, or a ZIP of an older release, stops with "unrecognized arguments" when the
    /// app passes it. Read from the script's own argparse rather than assumed — the option is the
    /// fork's, not upstream's.
    nonisolated static func repoSupportsWorkDir(_ dir: String) -> Bool {
        let script = dir + "/scripts/build_ipa_from_nsp.py"
        guard let text = try? String(contentsOfFile: script, encoding: .utf8) else { return false }
        return text.contains("'--work-dir'") || text.contains("\"--work-dir\"")
    }

    nonisolated static func findRepo() -> String {
        if let saved = UserDefaults.standard.string(forKey: "repoPath"), isRepo(saved) { return saved }
        var seeds: [String] = []
        // the app bundle: …/frontend/NS Port Builder.app/Contents/MacOS
        let bundle = Bundle.main.bundleURL.standardizedFileURL
        seeds.append(bundle.deletingLastPathComponent().path)
        seeds.append(bundle.deletingLastPathComponent().deletingLastPathComponent()
                         .deletingLastPathComponent().deletingLastPathComponent().path)
        seeds.append(FileManager.default.currentDirectoryPath)
        for base in ["/ZCodeProject/", "/", "/Documents/", "/Desktop/"] {
            seeds.append(NSHomeDirectory() + base + "nxnative")
            seeds.append(NSHomeDirectory() + base + "NX2Apple")
            seeds.append(NSHomeDirectory() + base + "nxnative-romfs-archive")   // clones made before the rename still resolve
        }
        var seen = Set<String>()
        for s in seeds where !s.isEmpty && seen.insert(s).inserted {
            var d = s
            for _ in 0..<5 {                       // walk up a few levels from each seed
                if isRepo(d) { return d }
                let up = (d as NSString).deletingLastPathComponent
                if up == d || up == "/" { break }
                d = up
            }
        }
        return ""
    }

    // ---- Repository download and updates (a clone is the scripts' home; not everyone has git habits) ----

    static let repoURL = "https://github.com/LNPANDY/NX2Apple.git"
    /// Clone/pull/check in flight; the buttons disable and the status line says what is happening.
    @Published var repoBusy = false
    @Published var repoStatus = ""
    /// nil = not checked yet, 0 = up to date, n = n commits behind origin/main.
    @Published var repoBehind: Int?

    nonisolated static func gitBinary() -> String? {
        for c in ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]
            where FileManager.default.isExecutableFile(atPath: c) { return c }
        return nil
    }
    nonisolated static func gitEnv() -> [String: String] {
        ["PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin", "HOME": NSHomeDirectory()]
    }

    /// Run a command with all output captured (no streaming; fetch / rev-list / pull print little).
    nonisolated static func runQuiet(_ args: [String], env: [String: String]) -> (ok: Bool, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: args[0])
        p.arguments = Array(args.dropFirst())
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (false, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus == 0, String(data: data, encoding: .utf8) ?? "")
    }

    /// First-time flow: clone the project to ~/nxnative (the discovery seeds cover it) and select it.
    func cloneRepo() {
        guard !running, !repoBusy else { return }
        guard let git = Self.gitBinary() else { repoStatus = t("repo.gitMissing"); return }
        let dest = NSHomeDirectory() + "/nxnative"
        if FileManager.default.fileExists(atPath: dest) {
            if Self.isRepo(dest) { repoPath = dest; repoStatus = ""; checkRepoUpdates() }
            else { repoStatus = String(format: t("repo.destBusy"), shortPath(dest)) }
            return
        }
        repoBusy = true; repoStatus = t("repo.downloading")
        append("git clone --depth 1 \(Self.repoURL) \(dest)\n")
        DispatchQueue.global().async {
            // Shallow: a quarter of the bytes and a third of the time of a full clone, and fetch /
            // pull keep working on it (verified); the history is of no use to someone who wants to build.
            let ok = Self.runCaptured([git, "clone", "--depth", "1", "--single-branch", "--progress", Self.repoURL, dest], env: Self.gitEnv()) {
                line in DispatchQueue.main.async { self.append(line + "\n") }
            }
            DispatchQueue.main.async {
                self.repoBusy = false
                if ok && Self.isRepo(dest) {
                    self.repoPath = dest
                    self.repoStatus = String(format: self.t("repo.downloadDone"), self.shortPath(dest))
                } else {
                    self.repoStatus = self.t("repo.downloadFail")
                    try? FileManager.default.removeItem(atPath: dest)   // a failed clone leaves an empty folder
                }
            }
        }
    }

    /// Compare the checkout with origin/main. `silent` is the launch-time check: no status text, no
    /// error noise when offline — it only fills repoBehind when it can.
    func checkRepoUpdates(silent: Bool = false) {
        guard repoOK, repoIsGit else { return }
        guard !running, !repoBusy, let git = Self.gitBinary() else {
            if !silent, Self.gitBinary() == nil { repoStatus = t("repo.gitMissing") }
            return
        }
        repoBusy = true
        if !silent { repoStatus = t("repo.checking") }
        let dir = repoPath
        DispatchQueue.global().async {
            let fetched = Self.runQuiet([git, "-C", dir, "fetch", "origin", "main"], env: Self.gitEnv())
            var behind = -1
            if fetched.ok {
                let count = Self.runQuiet([git, "-C", dir, "rev-list", "--count", "HEAD..origin/main"], env: Self.gitEnv())
                if count.ok { behind = Int(count.out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1 }
            }
            DispatchQueue.main.async {
                self.repoBusy = false
                if behind >= 0 {
                    self.repoBehind = behind
                    if !silent { self.repoStatus = behind == 0 ? self.t("repo.upToDate") : String(format: self.t("repo.behind"), behind) }
                } else if !silent {
                    self.repoStatus = self.t("repo.netFail")
                }
            }
        }
    }

    /// Fast-forward the checkout to origin/main. The build keeps everything it needs under
    /// <id>_build/ outside the repository, so a pull never disturbs a previous build's files.
    func pullRepo() {
        guard !running, !repoBusy, repoOK, repoIsGit, let git = Self.gitBinary() else { return }
        repoBusy = true; repoStatus = t("repo.pulling")
        let dir = repoPath
        DispatchQueue.global().async {
            let r = Self.runQuiet([git, "-C", dir, "pull", "--ff-only", "origin", "main"], env: Self.gitEnv())
            DispatchQueue.main.async {
                self.repoBusy = false
                if r.ok {
                    self.repoBehind = 0; self.repoStatus = self.t("repo.pulled")
                    if !r.out.isEmpty { self.append(r.out + "\n") }
                } else {
                    self.repoStatus = self.t("repo.pullFail")
                    self.append(r.out + "\n")
                }
            }
        }
    }

    /// A ZIP copy has no .git: adopt it into git in place (init, remote, fetch, checkout) so the
    /// update buttons work and the folder keeps its path. A ZIP copy carries no local changes, and
    /// the checkout resets it to origin/main — the build's own files live outside the repository.
    func adoptRepoAsGit() {
        guard !running, !repoBusy, repoOK, !repoIsGit, let git = Self.gitBinary() else { return }
        repoBusy = true; repoStatus = t("repo.adopting")
        let dir = repoPath
        DispatchQueue.global().async {
            var out = "", ok = true
            for args in [["init"], ["remote", "add", "origin", Self.repoURL],
                         ["fetch", "--depth", "1", "origin", "main"],
                         ["checkout", "-f", "-B", "main", "origin/main"]] {
                let r = Self.runQuiet([git, "-C", dir] + args, env: Self.gitEnv())
                out += "$ git \(args.joined(separator: " "))\n\(r.out)\n"
                if !r.ok { ok = false; break }
            }
            if ok { _ = Self.runQuiet([git, "-C", dir, "branch", "--set-upstream-to=origin/main", "main"], env: Self.gitEnv()) }   // checkout -B usually set it
            DispatchQueue.main.async {
                self.repoBusy = false
                self.append(out + "\n")
                if self.repoIsGit {
                    self.repoStatus = self.t("repo.adopted")
                    self.checkRepoUpdates()
                } else {
                    self.repoStatus = self.t("repo.adoptFail")
                }
            }
        }
    }

    // ---- App self-update (GitHub Releases) ----

    /// Bump together with each release tag; the update check compares it with the latest release.
    static let appVersion = "0.4.7"
    @Published var appUpdate: (tag: String, url: String)?
    @Published var appBusy = false
    @Published var appStatus = ""

    nonisolated static func isNewer(_ tag: String, than current: String) -> Bool {
        func nums(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0.filter { $0.isNumber }) ?? 0 } }
        let a = nums(tag), b = nums(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Ask GitHub for the latest release. `silent` (the launch check) only surfaces a found update;
    /// "up to date" and network failures stay quiet. A slow or blocked network just times out.
    func checkAppUpdate(silent: Bool = false) {
        guard !appBusy else { return }
        appBusy = true
        if !silent { appStatus = t("app.checking") }
        URLSession.shared.dataTask(with: URL(string: "https://api.github.com/repos/LNPANDY/NX2Apple/releases/latest")!) { data, _, _ in
            var found: (String, String)?
            if let d = data, let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                let tag = obj["tag_name"] as? String ?? ""
                if Self.isNewer(tag, than: Self.appVersion),
                   let assets = obj["assets"] as? [[String: Any]] {
                    // nxnative-macOS-arm64.zip; releases from before the rename name it NS-Port-Builder-macOS-arm64.zip
                    for name in ["nxnative-macOS-arm64.zip", "NS-Port-Builder-macOS-arm64.zip"] where found == nil {
                        for a in assets where (a["name"] as? String) == name {
                            if let u = a["browser_download_url"] as? String { found = (tag, u) }
                        }
                    }
                }
            }
            DispatchQueue.main.async {
                self.appBusy = false
                if let f = found {
                    self.appUpdate = f
                    self.appStatus = String(format: self.t("app.found"), f.0)
                } else if !silent {
                    self.appStatus = data == nil ? self.t("app.netFail") : self.t("app.upToDate")
                }
            }
        }.resume()
    }

    /// Download the new release, unzip it beside the running app, swap it in and relaunch. The old
    /// bundle goes to the Trash; a failure at any step leaves the current app running.
    func performAppUpdate() {
        guard let upd = appUpdate, let url = URL(string: upd.url), !appBusy else { return }
        appBusy = true; appStatus = t("app.downloading")
        DispatchQueue.global().async {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("nspb-update.zip")
            try? FileManager.default.removeItem(at: tmp)
            let sem = DispatchSemaphore(value: 0)
            URLSession.shared.downloadTask(with: url) { local, _, _ in
                if let local = local { try? FileManager.default.moveItem(at: local, to: tmp) }
                sem.signal()
            }.resume()
            sem.wait()
            guard FileManager.default.fileExists(atPath: tmp.path) else {
                DispatchQueue.main.async { self.appBusy = false; self.appStatus = self.t("app.netFail") }
                return
            }
            DispatchQueue.main.async { self.appStatus = self.t("app.installing") }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nspb-update", isDirectory: true)
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-x", "-k", tmp.path, dir.path]
            try? unzip.run(); unzip.waitUntilExit()
            // The archive holds one app: nxnative.app, or NS Port Builder.app in a release from before the rename
            let newApp = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .first { $0.pathExtension == "app" } ?? dir.appendingPathComponent("nxnative.app")
            guard unzip.terminationStatus == 0, FileManager.default.fileExists(atPath: newApp.path) else {
                DispatchQueue.main.async { self.appBusy = false; self.appStatus = self.t("app.netFail") }
                return
            }
            // Copy the new bundle in beside the running one first: from there on every step is a
            // same-volume move, and a failure anywhere leaves a working app on disk.
            let cur = Bundle.main.bundleURL
            let staging = cur.deletingLastPathComponent().appendingPathComponent("nxnative (new).app")
            try? FileManager.default.removeItem(at: staging)
            do {
                try FileManager.default.copyItem(at: newApp, to: staging)
                var trash: NSURL?
                try FileManager.default.trashItem(at: cur, resultingItemURL: &trash)
                try FileManager.default.moveItem(at: staging, to: cur)
            } catch {
                DispatchQueue.main.async {
                    self.appBusy = false
                    self.appStatus = String(format: self.t("app.installFail"), error.localizedDescription)
                }
                return
            }
            let x = Process()   // no Gatekeeper prompt on the swapped-in copy's first launch
            x.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            x.arguments = ["-dr", "com.apple.quarantine", cur.path]
            try? x.run(); x.waitUntilExit()
            DispatchQueue.main.async {
                self.appStatus = String(format: self.t("app.relaunching"), upd.tag)
                NSWorkspace.shared.openApplication(at: cur, configuration: NSWorkspace.OpenConfiguration())
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { exit(0) }
            }
        }
    }

    var basePath: String { slot("base").paths.first ?? "" }
    var keysPath: String { slot("keys").paths.first ?? "" }
    var updatePath: String { slot("update").paths.first ?? "" }
    var dlcPaths: [String] { slot("dlc").paths }

    func slot(_ id: String) -> Slot { slots.first { $0.id == id } ?? slots[0] }
    private func updateSlot(_ id: String, _ body: (inout Slot) -> Void) {
        if let i = slots.firstIndex(where: { $0.id == id }) { body(&slots[i]) }
    }

    // MARK: Inputs

    /// Fill every slot from a folder: NSP/XCI classified by title ID (…000 base,
    /// …800 update, anything above base+0x1000 add-on content), plus prod.keys.
    /// Subfolders are scanned too — a dump usually arrives as 本体/ 更新/ DLC/ folders —
    /// pruning the build folders this pipeline itself writes so a rescan is not slow.
    func scan(folder: String) {
        gameDir = folder
        let fm = FileManager.default
        var base: [(String, Int)] = [], update: [(String, Int, Int)] = [], dlc: [String] = []
        var keys: String?
        var seen = 0
        let enumerator = fm.enumerator(atPath: folder)
        while let rel = enumerator?.nextObject() as? String {
            if seen > 8000 { break }   // a pathological tree should not hang the picker
            seen += 1
            let name = (rel as NSString).lastPathComponent
            if name.hasPrefix(".") { continue }
            let path = folder + "/" + rel
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir) else { continue }
            let low = name.lowercased()
            if isDir.boolValue {
                // the pipeline's own output, and anything hidden: never walk back into those
                if low == "archive" || low == "xcode" || low.hasSuffix("_build") || low.hasSuffix("_survey") { enumerator?.skipDescendants() }
                continue
            }
            if keys == nil && (low == "prod.keys" || low.hasSuffix(".keys")) { keys = path; continue }
            guard low.hasSuffix(".nsp") || low.hasSuffix(".xci") else { continue }
            let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int ?? 0
            guard size > 0 else { continue }   // an incomplete download leaves 0-byte files behind
            guard let tid = Self.titleID(name) else { continue }   // a name without [title ID] cannot be classified
            switch tid & 0xFFF {
            case 0: base.append((path, size))
            case 0x800: update.append((path, size, Self.updateVersion(name)))
            default: dlc.append(path)
            }
        }
        // several bases happen when a folder holds a repack beside the original: the largest wins
        updateSlot("base") {
            $0.paths = base.sorted { $0.1 > $1.1 }.prefix(1).map(\.0)
            $0.problem = base.isEmpty ? "data.noBase" : ""
        }
        // several updates: the newest [vN] is the one a profile would pack
        updateSlot("update") {
            $0.paths = update.sorted { $0.2 > $1.2 }.prefix(1).map(\.0)
            $0.problem = ""
        }
        updateSlot("dlc") { $0.paths = dlc.sorted(); $0.problem = "" }
        updateSlot("keys") { $0.paths = keys.map { [$0] } ?? []; $0.problem = "" }
        if base.isEmpty && update.isEmpty && dlc.isEmpty {
            updateSlot("base") { $0.problem = "data.noNsp" }
        }
    }

    /// The [vN] in a file name, 0 when absent — used to pick the newest of several updates.
    nonisolated static func updateVersion(_ name: String) -> Int {
        guard let re = try? NSRegularExpression(pattern: #"\[v(\d+)\]"#) else { return 0 }
        let ns = name as NSString
        guard let m = re.firstMatch(in: name, range: NSRange(location: 0, length: ns.length)),
              let v = Int(ns.substring(with: m.range(at: 1))) else { return 0 }
        return v
    }

    func pickFiles(kind: InputKind) {
        let p = NSOpenPanel()
        p.canChooseDirectories = false
        p.canChooseFiles = true
        p.allowsMultipleSelection = (kind == .dlc)
        switch kind {
        case .base, .update: p.allowedFileTypes = ["nsp", "xci"]
        case .dlc: p.allowedFileTypes = ["nsp"]
        case .keys: p.allowedFileTypes = ["keys"]
        }
        guard p.runModal() == .OK, !p.urls.isEmpty else { return }
        let id = kind == .base ? "base" : kind == .update ? "update" : kind == .dlc ? "dlc" : "keys"
        let picked = p.urls.map(\.path)
        updateSlot(id) { s in
            s.paths = kind == .dlc ? Array(Set(s.paths + picked)).sorted() : Array(picked.prefix(1))
            s.problem = ""
        }
        if kind == .base, !picked.isEmpty { gameDir = (picked[0] as NSString).deletingLastPathComponent }
    }

    func clear(_ id: String) { updateSlot(id) { $0.paths = []; $0.problem = "" } }

    /// The title ID in a file name: [0100F2C0115B6000]
    nonisolated static func titleID(_ name: String) -> UInt64? {
        guard let re = try? NSRegularExpression(pattern: #"\[([0-9A-Fa-f]{16})\]"#) else { return nil }
        let ns = name as NSString
        guard let m = re.firstMatch(in: name, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return UInt64(ns.substring(with: m.range(at: 1)), radix: 16)
    }

    var repoOK: Bool { Self.isRepo(repoPath) }
    /// A clone has .git; a GitHub "Download ZIP" copy does not (everything builds, but there is
    /// nothing to fetch or pull — the update buttons hide and the note says to re-download instead).
    var repoIsGit: Bool { FileManager.default.fileExists(atPath: repoPath + "/.git") }
    var canBuild: Bool { repoOK && slot("base").ok && slot("keys").ok && allDepsPresent && !running }

    // MARK: Build

    func startBuild() {
        guard !running else { return }
        stopping = false
        running = true; done = false; doneNote = ""; stages = []; logTail = ""; lineBuf = ""; chainNoteShown = false
        guard repoOK else {
            fail(repoPath.isEmpty ? t("msg.repoInvalidEmpty") : String(format: t("msg.repoInvalid"), shortPath(repoPath)))
            return
        }
        let py = pythonPath.isEmpty ? "/usr/bin/python3" : pythonPath

        // One folder when everything lives together; otherwise a staging folder of symlinks. A folder
        // that holds other games too (a ROMs folder with one file per game) is staged as well: the
        // script takes one game per folder and refuses one with several ("more than one game in the
        // folder"), even when only the base game was picked.
        let baseDir = (basePath as NSString).deletingLastPathComponent
        let allPaths = [basePath, updatePath] + dlcPaths
        let dirs = Set(allPaths.filter { !$0.isEmpty }.map { ($0 as NSString).deletingLastPathComponent })
        let picked = Set(allPaths.filter { !$0.isEmpty }.map { ($0 as NSString).lastPathComponent })
        let unpicked = ((try? FileManager.default.contentsOfDirectory(atPath: baseDir)) ?? []).filter {
            ["nsp", "xci", "nsz", "xcz"].contains(($0 as NSString).pathExtension.lowercased()) && !picked.contains($0)
        }
        // Staged, the folder's own update and add-on content would be left behind, where the script
        // used to find them unpicked: bring along those whose file name carries this game's title ID
        // (base + 0x800 the update, unless one was picked; base + 0x1000 + n add-on content).
        var staged = allPaths
        if let base = Self.titleID((basePath as NSString).lastPathComponent) {
            for f in unpicked {
                guard let tid = Self.titleID(f), tid > base else { continue }
                let d = tid - base
                if (d == 0x800 && updatePath.isEmpty) || (d >= 0x1000 && d < 0x2000) { staged.append(baseDir + "/" + f) }
            }
        }
        var inputDir = baseDir
        if dirs.count > 1 || !unpicked.isEmpty {
            let tmp = NSTemporaryDirectory() + "nsport-\(UUID().uuidString.prefix(8))"
            try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
            var linked = 0
            for f in staged where !f.isEmpty {
                let dst = tmp + "/" + (f as NSString).lastPathComponent
                if (try? FileManager.default.createSymbolicLink(atPath: dst, withDestinationPath: f)) != nil { linked += 1 }
            }
            if linked == 0 { fail(t("msg.stagingFailed")); return }
            staging = tmp; inputDir = tmp
        } else { staging = nil }

        let tidHex = Self.titleID(basePath).map { String(format: "%016llX", $0) } ?? "game"
        let workDir = (outDir.isEmpty ? baseDir : outDir) + "/" + tidHex + "_build"
        // This fork's --work-dir keeps the build folder (extracted files, shader cache, the romfs
        // archive) outside the NSPs' folder. An upstream checkout or an older ZIP does not have the
        // option and would stop with "unrecognized arguments" (issue #5), so ask the script; without
        // it the script's own default (<input>/<title ID>_build) is used and the archive step follows
        // whatever folder the build reports.
        let hasWorkDir = Self.repoSupportsWorkDir(repoPath)
        if !hasWorkDir {
            say(t("msg.noWorkDir"))
        }
        // A compressed dump (NSZ / XCZ) needs nsz in the interpreter the build runs under; it is not
        // part of the dependency probe (most builds never see one), so install it here, once, only
        // when such a file is actually selected — otherwise the build stops with "pip install nsz".
        let compressed = ([basePath, updatePath] + dlcPaths).contains {
            let e = ($0 as NSString).pathExtension.lowercased()
            return e == "nsz" || e == "xcz"
        }
        if compressed, !Self.runOK(py, ["-c", "import nsz"]) {
            say(t("msg.installingNsz"))
            let r = Self.runCaptured([py, "-m", "pip", "install", "nsz"],
                                     env: ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
                                           "HOME": NSHomeDirectory()]) { line in
                DispatchQueue.main.async { self.append(line + "\n") }
            }
            if !r {
                fail(String(format: t("msg.nszFailed"), py))
                return
            }
        }
        var args = [repoPath + "/scripts/build_ipa_from_nsp.py", inputDir, "-k", keysPath,
                    "--progress", "json"]
        // A compatibility switch the player turned on: written to a small env file the pipeline
        // copies into the app bundle (main.m sets one variable per line at boot). Only for an IPA;
        // a Mac app runs on this Mac's GPU, which always has BC support.
        if bcOnCPU && target != "mac-app" {
            let envPath = NSTemporaryDirectory() + "nspb-env-\(UUID().uuidString.prefix(8)).txt"
            do {
                try "DM_TEX_BC_CPU=1\n".write(toFile: envPath, atomically: true, encoding: .utf8)
                args += ["--env-file", envPath]
                say(t("msg.bcOn"))
            } catch {
                say(String(format: t("msg.bcEnvFailed"), error.localizedDescription))
            }
        }
        if hasWorkDir { args += ["--work-dir", workDir] }
        let macApp = target == "mac-app"
        if macApp {
            // -o names the .app; the RomFS goes inside it, so the archive step is skipped below.
            args += ["--platform", "mac-app"]
            macAppPath = (outDir.isEmpty ? baseDir : outDir) + "/" + tidHex + ".app"
            args += ["-o", macAppPath]
        } else if !outDir.isEmpty {
            ipaPath = outDir + "/" + tidHex + ".ipa"
            args += ["-o", ipaPath]
        }
        // The archive step packs whatever folder the build reported; without --work-dir that is the
        // script's default, which is the same workDir unless a separate output folder was chosen.
        effectiveWorkDir = hasWorkDir ? workDir : (inputDir as NSString).appendingPathComponent(tidHex + "_build")
        say(String(format: t("msg.running"), py) + " " + args.joined(separator: " "))

        let p = Process()
        p.executableURL = URL(fileURLWithPath: py)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: repoPath)
        // The root of the runtime the apphost looks for: derived from the detected installation,
        // not assumed to be ~/.dotnet (Homebrew keeps it in …/opt/dotnet/libexec). Only set when the
        // derivation actually answered — a wrong root is worse than none, and the pipeline derives
        // and verifies its own (DOTNET_ROOT, build_ipa_from_nsp.py) when this is absent.
        var denv: [String: String] = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                                      "USER": NSUserName(), "HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8"]
        if let droot = Self.dotnetRoot(for: dotnetPath.isEmpty ? "dotnet" : dotnetPath) {
            denv["DOTNET_ROOT"] = droot   // both variables carry the same root, as the apphost checks the arch-specific one first
            denv["DOTNET_ROOT_ARM64"] = droot
        }
        p.environment = denv
        Self.inOwnGroup(p, python: py)
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        p.terminationHandler = { [weak self] status in
            Self.untrack(status)
            DispatchQueue.main.async {
                guard let self else { return }
                self.running = false
                self.flushLines()
                if self.stopping {
                    self.stopping = false
                    self.resetProgress()
                    self.doneNote = self.t("msg.stopped")
                    self.cleanupStaging()
                    return
                }
                if status.terminationStatus == 0 {
                    self.markAllDone()
                    if self.target == "mac-app" {
                        // A Mac app carries its RomFS inside, so the archive step would be wasted
                        // work; the .app's existence is the real check (the script can exit 0
                        // without writing it, e.g. when pack_app.py is missing from the checkout).
                        let made = !self.macAppPath.isEmpty &&
                                   FileManager.default.fileExists(atPath: self.macAppPath)
                        self.done = made
                        self.doneNote = self.t(made ? "msg.macAppDone" : "msg.macAppMissing")
                        self.running = false
                        self.cleanupStaging()
                    } else {
                        self.packArchive(workDir: self.effectiveWorkDir)   // keeps running=true until the archive is done
                    }
                } else {
                    if let i = self.stages.lastIndex(where: { $0.state == .running }) {
                        self.stages[i].state = .failed
                        self.stages[i].detail = String(format: self.t("msg.exitCode"), status.terminationStatus)
                    } else { self.doneNote = String(format: self.t("msg.buildFailed"), status.terminationStatus) }
                    self.cleanupStaging()
                }
            }
        }
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.ingest(s) }
        }
        proc = p
        do { try p.run(); Self.track(p) } catch { fail(String(format: t("msg.launchFailed"), error.localizedDescription)) }
    }

    /// The build's last step is done either way: release the button and show the outcome.
    func finishBuild(ok: Bool, note: String) {
        running = false
        done = ok
        doneNote = note
        if ok { installAfterBuild() }
    }

    // MARK: Install on a device

    /// scripts/install_ios.py signs the IPA with this Mac's development certificate, installs it over
    /// the cable and copies the romfs archive into the app's Documents. Nothing about the account is
    /// kept here but the team the user picked; the script reads the certificate and the device itself.
    struct Device: Identifiable, Hashable { let id: String; let name: String; let model: String }
    struct Identity: Identifiable, Hashable { var id: String { team }; let team: String; let name: String }
    @Published var devices: [Device] = []
    @Published var identities: [Identity] = []
    @Published var deviceID = UserDefaults.standard.string(forKey: "installDevice") ?? "" {
        didSet { UserDefaults.standard.set(deviceID, forKey: "installDevice") }
    }
    @Published var team = UserDefaults.standard.string(forKey: "installTeam") ?? "" {
        didSet { UserDefaults.standard.set(team, forKey: "installTeam") }
    }
    @Published var autoInstall = UserDefaults.standard.object(forKey: "autoInstall") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoInstall, forKey: "autoInstall") }
    }
    @Published var installing = false
    @Published var devicesChecked = false

    var hasInstaller: Bool { FileManager.default.fileExists(atPath: repoPath + "/scripts/install_ios.py") }
    var canInstall: Bool {
        hasInstaller && !running && devices.contains { $0.id == deviceID } && FileManager.default.fileExists(atPath: ipaPath)
            && (identities.count <= 1 || identities.contains { $0.team == team })
    }

    func refreshDevices() {
        guard hasInstaller else { return }
        let py = pythonPath.isEmpty ? "/usr/bin/python3" : pythonPath, script = repoPath + "/scripts/install_ios.py"
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process(); p.executableURL = URL(fileURLWithPath: py); p.arguments = [script, "--list"]
            p.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory()]
            let out = Pipe(); p.standardOutput = out; p.standardError = Pipe(); p.standardInput = FileHandle.nullDevice
            var devs: [Device] = [], ids: [Identity] = []
            if (try? p.run()) != nil {
                let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
                if let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    for d in j["devices"] as? [[String: Any]] ?? [] where d["paired"] as? Bool ?? false {
                        devs.append(Device(id: d["udid"] as? String ?? "", name: d["name"] as? String ?? "", model: d["model"] as? String ?? ""))
                    }
                    var seen = Set<String>()
                    for i in j["identities"] as? [[String: Any]] ?? [] {
                        let t = i["team"] as? String ?? ""
                        if seen.insert(t).inserted { ids.append(Identity(team: t, name: i["name"] as? String ?? t)) }
                    }
                }
            }
            DispatchQueue.main.async {
                self.devices = devs; self.identities = ids; self.devicesChecked = true
                if !devs.contains(where: { $0.id == self.deviceID }) { self.deviceID = devs.count == 1 ? devs[0].id : "" }
                if !ids.contains(where: { $0.team == self.team }) { self.team = ids.count == 1 ? ids[0].team : "" }
            }
        }
    }

    private func installAfterBuild() {
        if autoInstall, target == "ios", canInstall { startInstall() }
    }

    func startInstall() {
        guard canInstall else { return }
        let dev = devices.first { $0.id == deviceID }?.name ?? deviceID
        running = true; installing = true
        doneNote = String(format: t("inst.running"), dev)
        stages.removeAll { $0.id > 2000 }
        var args = [repoPath + "/scripts/install_ios.py", ipaPath, "--device", deviceID, "--progress", "lines", "--first-stage", "2001"]
        if !archivePath.isEmpty { args += ["--romfs", archivePath] }
        if !team.isEmpty { args += ["--team", team] }
        let py = pythonPath.isEmpty ? "/usr/bin/python3" : pythonPath
        say(String(format: t("msg.running"), py) + " " + args.joined(separator: " "))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: py)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: repoPath)
        p.environment = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                         "USER": NSUserName(), "HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8"]
        Self.inOwnGroup(p, python: py)   // Stop ends devicectl and xcodebuild with it
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.ingest(s) }
        }
        p.terminationHandler = { [weak self] st in Self.untrack(st); DispatchQueue.main.async {
            guard let self else { return }
            self.flushLines()
            self.running = false; self.installing = false
            if self.stopping {
                self.stopping = false
                self.doneNote = self.t("msg.stopped")
            } else if st.terminationStatus == 0 {
                self.doneNote = String(format: self.t("inst.done"), dev)
            } else {
                if let i = self.stages.lastIndex(where: { $0.id > 2000 && $0.state == .running }) { self.stages[i].state = .failed }
                let why = self.logTail.components(separatedBy: "\n").last { $0.hasPrefix("[RED] ") }.map { String($0.dropFirst(6)) }
                self.doneNote = String(format: self.t("inst.failed"), why ?? String(format: self.t("msg.exitCode"), st.terminationStatus))
            }
        }}
        proc = p
        do { try p.run(); Self.track(p) } catch { running = false; installing = false; doneNote = String(format: t("inst.failed"), error.localizedDescription) }
    }

    /// (file count, bytes) of a RomFS tree — the reuse fingerprint's content part.
    nonisolated static func treeStats(_ dir: String) -> (count: Int, bytes: Int)? {
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: dir) else { return nil }
        var count = 0, bytes = 0
        while let rel = en.nextObject() as? String {
            let s = ((try? fm.attributesOfItem(atPath: dir + "/" + rel))?[.size] as? Int) ?? 0
            count += 1; bytes += s
        }
        return (count, bytes)
    }

    nonisolated static func writeStamp(source: String, version: String, to path: String) {
        guard let s = treeStats(source) else { return }
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        try? "\(version)\t\(s.count)\t\(s.bytes)".write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// The stamped (version, count, bytes) versus the source tree's now: nil = pack again.
    nonisolated static func archiveReusable(source: String, version: String, stamp: String) -> Int? {
        guard let s = treeStats(source) else { return nil }
        let parts = stamp.split(separator: "\t")
        guard parts.count == 3, parts[0] == version,
              Int(parts[1]) == s.count, Int(parts[2]) == s.bytes else { return nil }
        return s.count
    }

    private func fail(_ why: String) { running = false; doneNote = why; say("✗ " + why); cleanupStaging() }

    func stop() {
        guard running, !stopping, let proc, proc.isRunning else { return }
        stopping = true
        Self.endGroup(proc.processIdentifier)   // the script and every tool it started
    }

    private func cleanupStaging() {
        if let s = staging { try? FileManager.default.removeItem(atPath: s); staging = nil }
    }

    /// A stopped build leaves no half-finished stages behind: the progress starts empty again.
    private func resetProgress() { stages = []; logTail = ""; lineBuf = "" }

    private func markAllDone() { for i in stages.indices where stages[i].state != .failed { stages[i].state = .done } }

    // MARK: Output parsing

    private func say(_ s: String) { append(s + "\n") }
    private func append(_ s: String) {
        logTail += s
        if logTail.count > 12000 { logTail = String(logTail.suffix(9000)) }
    }

    /// Split into lines (the pipe delivers arbitrary chunks) and turn the script's progress into the stage list.
    /// `--progress json` writes one event per line (stage, step, progress with done / total / frac / eta, stage_end,
    /// say), a count change at most every half second; anything else on the pipe (a tool's traceback) is log text.
    /// The older `--progress lines` form is still understood:
    ///   [12:00:01] [2/7] extract v720896 …
    ///   [12:00:20] ✓ [2/7] extract v720896 (0:19): 30,000 files, 3.4 GB
    private func ingest(_ chunk: String) {
        lineBuf += chunk
        while let i = lineBuf.firstIndex(of: "\n") {
            let line = String(lineBuf[..<i]).replacingOccurrences(of: "\r", with: "")
            lineBuf = String(lineBuf[lineBuf.index(after: i)...])
            handle(line)
        }
    }

    private func flushLines() {
        guard !lineBuf.isEmpty else { return }
        handle(lineBuf); lineBuf = ""
    }

    private func handle(_ line: String) {
        if line.hasPrefix("{"), let data = line.data(using: .utf8),
           let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let kind = event["ev"] as? String {
            return handleEvent(kind, event)
        }
        append(line + "\n")
        noteChainChange(line)
        if let range = line.range(of: "output IPA: ") {
            ipaPath = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let s = Self.parseStage(line) else { return }
        if let i = stages.firstIndex(where: { $0.id == s.k }) {
            if !s.name.isEmpty { stages[i].name = s.name }
            if s.state != .pending { stages[i].state = s.state }
            if !s.detail.isEmpty { stages[i].detail = s.detail }
            stages[i].percent = s.percent
        } else if s.state != .pending {
            stages.append(Stage(id: s.k, name: s.name, state: s.state, detail: s.detail, percent: s.percent, started: Date()))
            stages.sort { $0.id < $1.id }
        }
    }

    /// The script marks a shader-chain bump with this tag: the cached libraries cannot be
    /// reused and this build recompiles them. An alert, not a log line — the report's question
    /// ("why is it building shaders again, the artifacts are on the drive") came from exactly
    /// this moment passing unnoticed. Once per build: the pipe delivers arbitrary chunks.
    /// (A plain line, or the message of a `say` event in `--progress json`.)
    private func noteChainChange(_ text: String) {
        guard text.contains("[NOTE] chain-changed"), !chainNoteShown else { return }
        chainNoteShown = true
        let a = NSAlert()
        a.messageText = t("msg.chainChanged")
        a.alertStyle = .informational
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    /// One event of `--progress json`: the stage list follows it, and the log gets a readable line (no count updates).
    private func handleEvent(_ kind: String, _ e: [String: Any]) {
        let k = (e["k"] as? NSNumber)?.intValue ?? 0
        func stage(_ update: (inout Stage) -> Void) {
            if let i = stages.firstIndex(where: { $0.id == k }) { update(&stages[i]) }
            else { var s = Stage(id: k, name: e["name"] as? String ?? ""); update(&s); stages.append(s); stages.sort { $0.id < $1.id } }
        }
        switch kind {
        case "stage":
            let name = e["name"] as? String ?? "", step = e["step"] as? String ?? ""
            let n = (e["n"] as? NSNumber)?.intValue ?? 0
            append("[\(k)/\(n)] \(name)" + (step.isEmpty ? "" : " · \(step)") + " …\n")
            stage { $0.name = name; $0.state = .running; $0.detail = step; $0.percent = nil; $0.started = Date(); $0.eta = nil }
        case "step":
            let step = e["step"] as? String ?? ""
            append("    · \(step)\n")
            stage { $0.detail = step; $0.percent = nil; $0.eta = nil }
        case "progress":
            let fraction = (e["frac"] as? NSNumber)?.doubleValue
            let detail = Self.progressDetail(e)
            let eta = (e["eta"] as? NSNumber)?.doubleValue
            stage { $0.percent = fraction.map { $0 * 100 }; $0.detail = detail; $0.eta = eta; $0.etaAt = eta == nil ? nil : Date() }
        case "stage_end":
            let ok = e["ok"] as? Bool ?? true, summary = e["summary"] as? String ?? ""
            let elapsed = Self.duration((e["elapsed"] as? NSNumber)?.doubleValue ?? 0)
            append("\(ok ? "✓" : "✗") \(e["name"] as? String ?? "") (\(elapsed))" + (summary.isEmpty ? "" : ": \(summary)") + "\n")
            stage { $0.state = ok ? .done : .failed; $0.detail = summary; $0.percent = ok ? 100 : $0.percent; $0.eta = nil }
        case "say":
            let msg = e["msg"] as? String ?? ""
            append(msg + "\n")
            noteChainChange(msg)
            if let range = msg.range(of: "output IPA: ") {
                ipaPath = String(msg[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        default: break
        }
    }

    /// "splitting · 1.2 / 3.4 GB", "1,203 / 19,592 shaders", "2,301 files": the step and the count (the time left is the Stage's clock).
    nonisolated static func progressDetail(_ e: [String: Any]) -> String {
        let step = e["step"] as? String ?? "", unit = e["unit"] as? String ?? "", note = e["note"] as? String ?? ""
        let done = (e["done"] as? NSNumber)?.doubleValue, total = (e["total"] as? NSNumber)?.doubleValue
        let estimate = (e["est"] as? Bool ?? false) ? "~" : ""
        var count = ""
        if let done {
            if unit == "B" {
                let bytes = { (v: Double) in ByteCountFormatter.string(fromByteCount: Int64(v), countStyle: .file) }
                count = total.map { "\(bytes(done)) / \(estimate)\(bytes($0))" } ?? bytes(done)
            } else {
                let number = { (v: Double) in NumberFormatter.localizedString(from: NSNumber(value: Int(v)), number: .decimal) }
                count = (total.map { "\(number(done)) / \(estimate)\(number($0))" } ?? number(done)) + (unit.isEmpty ? "" : " \(unit)")
            }
        }
        return [step, count, note].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    nonisolated static func duration(_ seconds: Double) -> String {
        // Formatted by hand, not DateComponentsFormatter: the formatter follows the system
        // locale, so a Chinese macOS wrote "4秒" into a log whose every other line was English
        // (and the test that pinned "4s" failed on any non-English machine). The abbreviations
        // are the interface language's, via the same string table as everything else.
        let s = max(Int(seconds.rounded(.up)), 1)
        if s >= 3600 {
            let h = s / 3600, m = (s % 3600) / 60
            return h > 0 && m > 0 ? "\(h)h \(m)m" : "\(h)h"
        }
        if s >= 60 {
            let m = s / 60, sec = s % 60
            return sec > 0 ? "\(m)m \(sec)s" : "\(m)m"
        }
        return "\(s)s"
    }

    nonisolated static func parseStage(_ line: String) -> (k: Int, name: String, state: StepState, detail: String, percent: Double?)? {
        guard let re = try? NSRegularExpression(pattern: #"\[(\d+)/(\d+)\] (.+)$"#) else { return nil }
        let ns = line as NSString
        guard let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        guard let k = Int(ns.substring(with: m.range(at: 1))) else { return nil }
        var rest = ns.substring(with: m.range(at: 3))

        if let pct = rest.range(of: #"(\d+)%"#, options: .regularExpression) {
            let v = Double(rest[pct].dropLast()) ?? 0
            var name = String(rest[..<pct.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: " :·"))
            if let dot = name.range(of: " · ", options: .backwards) { name = String(name[..<dot.lowerBound]) }
            let after = String(rest[pct.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: ", :"))
            return (k, name, .running, after, v)
        }
        let ok = line.contains("✓"), bad = line.contains("✗")
        if ok || bad {
            var detail = ""
            if let r = rest.range(of: "): ") { detail = String(rest[r.upperBound...]); rest = String(rest[..<r.lowerBound]) + ")" }
            if let r = rest.range(of: " (", options: .backwards) { rest = String(rest[..<r.lowerBound]) }
            return (k, rest, bad ? .failed : .done, detail, 100)
        }
        if rest.hasSuffix(" …") { rest = String(rest.dropLast(2)) }
        if let dot = rest.range(of: " · ", options: .backwards), !rest.hasPrefix("survey") { rest = String(rest[..<dot.lowerBound]) }
        return (k, rest, .running, "", nil)
    }

    // MARK: Archive

    /// Pack the extracted RomFS into a ROMFSARC archive. The extracted folder is
    /// <work>/extract/v<N>/RomFS where N is the profile's package version, so take
    /// the highest v* that actually has a RomFS instead of hardcoding one game.
    private func packArchive(workDir: String) {
        running = true
        let fm = FileManager.default
        let extract = workDir + "/extract"
        let vers = ((try? fm.contentsOfDirectory(atPath: extract)) ?? [])
            .filter { $0.hasPrefix("v") && fm.fileExists(atPath: extract + "/" + $0 + "/RomFS") }
            .sorted { (Int($0.dropFirst()) ?? 0) < (Int($1.dropFirst()) ?? 0) }
        guard let v = vers.last else {
            stages.append(Stage(id: 1000, name: t("prog.archiveShort"), state: .failed, detail: t("prog.noRomfs")))
            doneNote = String(format: t("msg.archiveSkipped"), extract)
            running = false; cleanupStaging(); return
        }
        let romfs = extract + "/" + v + "/RomFS"
        // The output is Documents/games/<title ID>/romfs — the per-game layout the iOS app looks for
        // first. Copying the whole `games` folder onto the phone (or into a folder the Files app
        // exposes on an external drive) then needs no renaming, and several games' folders can sit
        // side by side in one app.
        let gamesRoot = (outDir.isEmpty ? (basePath as NSString).deletingLastPathComponent : outDir) + "/games"
        let tid = Self.titleID(basePath).map { String(format: "%016llX", $0) } ?? "game"
        let dest = gamesRoot + "/" + tid + "/romfs"
        try? fm.createDirectory(atPath: dest, withIntermediateDirectories: true)
        // Reuse: packing is a multi-GB write, and the extracted RomFS is itself reused by the
        // script — so when the source tree's (version, file count, bytes) matches the stamp left
        // in the folder, the shards are already correct and the pack is skipped. A different
        // version changes the extract; a same-version re-extract of the same NSPs reproduces the
        // same tree.
        let stampPath = dest + "/.packstamp"
        if let stamp = try? String(contentsOfFile: stampPath, encoding: .utf8), !stamp.isEmpty,
           let reused = Self.archiveReusable(source: romfs, version: v, stamp: stamp) {
            archivePath = dest
            stages.append(Stage(id: 1000, name: t("prog.archive"), state: .done,
                                detail: String(format: t("prog.archiveReused"), reused)))
            say(String(format: t("msg.archiveReused"), dest))
            cleanupStaging()
            finishBuild(ok: true, note: t("msg.done"))
            return
        }
        // a previous pack's shards must not survive a smaller new pack (the index names its own
        // shards, but stale higher-numbered files would sit there confusingly)
        for old in ((try? fm.contentsOfDirectory(atPath: dest)) ?? [])
        where old == "romfs.idx" || (old.hasPrefix("romfs.") && old.dropFirst(6).allSatisfy(\.isNumber)) {
            try? fm.removeItem(atPath: dest + "/" + old)
        }
        let idx = 1000
        stages.append(Stage(id: idx, name: t("prog.archive"), state: .running, detail: v))
        say(String(format: t("msg.archiveLog"), romfs, dest))

        let p = Process()
        p.executableURL = URL(fileURLWithPath: pythonPath.isEmpty ? "/usr/bin/python3" : pythonPath)
        // base = dest + "/romfs": the pack writes romfs.idx + romfs.NN INSIDE the folder
        // (base = dest would leave them as siblings of an empty folder)
        p.arguments = [repoPath + "/dm/tools/romfs_arc.py", "pack", romfs, dest + "/romfs", "--shard-mib", "200"]
        p.environment = ["PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin", "PYTHONPATH": repoPath + "/dm/tools"]
        Self.inOwnGroup(p, python: p.executableURL!.path)
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.append(s) }
        }
        p.terminationHandler = { [weak self] st in Self.untrack(st); DispatchQueue.main.async {
            guard let self else { return }
            self.cleanupStaging()
            let cancelled = self.stopping
            let succeeded = st.terminationStatus == 0 && !cancelled
            self.stopping = false
            if succeeded {
                self.archivePath = dest
                Self.writeStamp(source: romfs, version: v, to: dest + "/.packstamp")
            }
            if let i = self.stages.firstIndex(where: { $0.id == idx }) {
                self.stages[i].state = succeeded ? .done : .failed
                self.stages[i].detail = succeeded
                    ? String(format: self.t("prog.archiveDone"), dest)
                    : String(format: self.t("msg.archiveFailed"), st.terminationStatus)
            }
            self.running = false
            self.done = succeeded
            if cancelled { self.resetProgress() }
            self.doneNote = cancelled ? self.t("msg.stopped") : (succeeded ? self.t("msg.done") : self.t("msg.archiveIpaOnly"))
            if succeeded && !cancelled { self.installAfterBuild() }
        }}
        proc = p
        do { try p.run(); Self.track(p) } catch {
            if let i = stages.firstIndex(where: { $0.id == idx }) {
                stages[i].state = .failed; stages[i].detail = t("msg.archiveNoStart")
            }
            running = false; doneNote = t("msg.archiveIpaOnly"); cleanupStaging()
        }
    }

    // MARK: Dependencies

    struct Dep: Identifiable {
        let id: String
        let name: String      // an L10n key
        let hint: String      // an L10n key
        var present: Bool
        var installing = false
        var detail = ""
        let installCmd: [String]      // run via bash; empty = manual (Xcode from the App Store)
    }

    /// A GUI app does not inherit the shell's PATH, so look where the tools actually
    /// live instead of trusting `which` — that is why .NET (in ~/.dotnet) and the
    /// Python packages (in /usr/local/bin/python3, not /usr/bin/python3) used to show
    /// as missing while a terminal could see them.
    nonisolated static func runOK(_ tool: String, _ args: [String], env: [String: String]? = nil) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        if let env { p.environment = env }
        p.standardOutput = Pipe(); p.standardError = Pipe()
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    nonisolated static func firstExisting(_ paths: [String]) -> String? {
        paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The Python that actually has lz4/capstone/fontTools/backports.zstd — the one
    /// the build must run under, not whatever /usr/bin/python3 happens to be.
    /// The minimum the build scripts need. /usr/bin/python3 is 3.9 on a stock Mac and has none of
    /// the packages; picking it made a build fail with a syntax error deep inside the script
    /// (an f-string only 3.12 can parse) instead of a clear message here.
    nonisolated static let minPython = (3, 9)

    /// The interpreter probe: lz4 / capstone / fontTools always, and zstd from either source —
    /// `compression.zstd` is built in from Python 3.14 and `backports.zstd` (which declares
    /// Python < 3.14) is the only option before that. Requiring the backport unconditionally
    /// rejected an otherwise working Homebrew Python 3.15 (issue #1).
    /// nsz is deliberately not required here: it is only needed for NSZ / XCZ dumps, and the
    /// pipeline says so by name when one shows up. The venv installs it anyway so that a player
    /// who downloads a compressed dump never meets that error.
    nonisolated static let importProbe = """
        import lz4, capstone, fontTools
        try:
            from compression import zstd
        except ImportError:
            from backports import zstd
        """

    /// The interpreter the packages are installed into when no system Python has them. A venv
    /// rather than `pip install --user`: Homebrew's Python is externally managed (PEP 668) and
    /// refuses --user, and this leaves the user's environment untouched. Injectable so tests can
    /// use a scratch directory.
    nonisolated static var venvDir = NSHomeDirectory() + "/Library/Application Support/NS Port Builder/venv"

    nonisolated static func venvPython() -> String { venvDir + "/bin/python3" }

    nonisolated static func importsOK(_ py: String) -> Bool { runOK(py, ["-c", importProbe]) }

    /// The architecture this Mac runs natively. An Intel Homebrew under /usr/local on an Apple
    /// silicon Mac has an x86_64-only Python that runs under Rosetta, and every child it starts
    /// prefers the x86_64 slice too: the shader translator's apphost (a universal binary) then
    /// looks for an x86_64 .NET, finds only the arm64 one, prints nothing, and the build stops at
    /// the iOS shader step with "xlate_source: lock … / actual" (empty). Such an interpreter is
    /// never picked, and a venv made from one is made again from a native one.
    nonisolated static let nativeArch: String = {
        var v: Int32 = 0; var n = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &v, &n, nil, 0) == 0 && v == 1 ? "arm64" : "x86_64"
    }()

    /// platform.machine() of an interpreter: "x86_64" for one under Rosetta. nil when it cannot run.
    nonisolated static func pythonArch(_ path: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["-c", "import platform; print(platform.machine())"]
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = Pipe()
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func isNative(_ py: String) -> Bool { pythonArch(py) == nativeArch }

    /// backports.zstd declares Python < 3.14, so it is only installed where it is needed.
    /// nsz is always installed: NSZ / XCZ dumps are accepted by the pipeline now, and a player who
    /// downloads one should not have to run pip by hand (it is a few hundred KB).
    nonisolated static func pipPackages(_ version: (Int, Int)) -> [String] {
        version < (3, 14) ? ["lz4", "capstone", "fonttools", "backports.zstd", "nsz"]
                          : ["lz4", "capstone", "fonttools", "nsz"]
    }

    /// Create the venv (reusing an existing one) and install the packages into it. Returns the
    /// combined output so a failure can be shown instead of swallowed — the pip output used to go
    /// to a pipe nobody read, and `externally-managed-environment` never reached the user.
    nonisolated static func makeVenv(base: String) -> (ok: Bool, log: String) {
        var log = ""
        func run(_ exe: String, _ args: [String]) -> Bool {
            let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
            let out = Pipe(), err = Pipe()
            p.standardOutput = out; p.standardError = err; p.standardInput = FileHandle.nullDevice
            p.environment = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "HOME": NSHomeDirectory()]
            do { try p.run() } catch { log += "could not start \(exe): \(error.localizedDescription)\n"; return false }
            // both pipes are drained on this thread (before waitUntilExit, so the child cannot
            // block on a full pipe), and the log string keeps a single owner
            let outData = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            log += String(data: outData, encoding: .utf8) ?? ""
            log += String(data: errData, encoding: .utf8) ?? ""
            return p.terminationStatus == 0
        }
        let vpy = venvPython()
        if FileManager.default.isExecutableFile(atPath: vpy) && !isNative(vpy) {
            log += "\(vpy) is \(pythonArch(vpy) ?? "?"), not \(nativeArch): making the venv again\n"
            try? FileManager.default.removeItem(atPath: venvDir)
        }
        // The base must be native too, and it cannot be the venv's own interpreter (just removed)
        let base = (base != vpy && isNative(base)) ? base : (nativeBase() ?? base)
        if !FileManager.default.isExecutableFile(atPath: vpy) {
            log += "$ \(base) -m venv \(venvDir)\n"
            try? FileManager.default.createDirectory(atPath: (venvDir as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            guard run(base, ["-m", "venv", venvDir]) else { return (false, log + "venv creation failed\n") }
        }
        let pkgs = pipPackages(pythonVersion(vpy) ?? minPython).joined(separator: " ")
        log += "$ \(vpy) -m pip install \(pkgs)\n"
        let ok = run(vpy, ["-m", "pip", "install"] + pipPackages(pythonVersion(vpy) ?? minPython))
        return (ok && importsOK(vpy), log)
    }

    /// "3.12.4" → (3, 12). nil when the interpreter cannot be run.
    nonisolated static func pythonVersion(_ path: String) -> (Int, Int)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["-c", "import sys; print('%d.%d' % sys.version_info[:2])"]
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = Pipe()
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let parts = out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".")
        guard parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]) else { return nil }
        return (a, b)
    }

    /// Every native python3 on this Mac, newest-looking first, each tried for a usable version and
    /// the packages. Returns the one to build with, plus why the others were rejected for the message.
    nonisolated static func findPython() -> (path: String, ok: Bool) {
        var seen = Set<String>()
        var fallback: (String, (Int, Int))? = nil   // newest with an acceptable version but no packages
        for c in pythonCandidates() where !c.isEmpty && seen.insert(c).inserted {
            guard FileManager.default.isExecutableFile(atPath: c), let v = pythonVersion(c) else { continue }
            guard v >= minPython, isNative(c) else { continue }
            if importsOK(c) { return (c, true) }
            if fallback == nil || v > fallback!.1 { fallback = (c, v) }
        }
        // No system interpreter has the packages: the venv (existing, or created by 安装) is next.
        let vpy = venvPython()
        if FileManager.default.isExecutableFile(atPath: vpy) {
            if importsOK(vpy) && isNative(vpy) { return (vpy, true) }
            return (vpy, false)   // incomplete, or under Rosetta: 安装 finishes or remakes it
        }
        return (fallback?.0 ?? vpy, false)
    }

    /// The newest native interpreter new enough to make the venv from, packages or not.
    nonisolated static func nativeBase() -> String? {
        var seen = Set<String>(), best: (String, (Int, Int))? = nil
        for c in pythonCandidates() where !c.isEmpty && c != venvPython() && seen.insert(c).inserted {
            guard FileManager.default.isExecutableFile(atPath: c), let v = pythonVersion(c), v >= minPython, isNative(c) else { continue }
            if best == nil || v > best!.1 { best = (c, v) }
        }
        return best?.0
    }

    /// Every python3 on this Mac, newest-looking first.
    nonisolated static func pythonCandidates() -> [String] {
        var cands: [String] = []
        let fw = "/Library/Frameworks/Python.framework/Versions"
        if let vers = try? FileManager.default.contentsOfDirectory(atPath: fw) {
            for v in vers.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
                cands.append(fw + "/" + v + "/bin/python3")
            }
        }
        cands += ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        p.arguments = ["-a", "python3"]
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = Pipe()
        p.standardInput = FileHandle.nullDevice
        if (try? p.run()) != nil {
            p.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            cands += out.split(separator: "\n").map(String.init)
        }
        return cands
    }

    /// The runtime root of a dotnet installation, parsed from `dotnet --list-runtimes`. It cannot
    /// be assumed to be the binary's directory: Homebrew's /opt/homebrew/bin/dotnet is a symlink
    /// into Cellar, and the runtime lives in …/libexec, so a hardcoded ~/.dotnet left the apphost
    /// without a runtime and nx_extract died with exit code 131 (issue #2).
    nonisolated static func parseDotnetRoot(_ listRuntimes: String) -> String? {
        for ln in listRuntimes.split(separator: "\n") {
            guard ln.hasPrefix("Microsoft.NETCore.App"), let a = ln.firstIndex(of: "["), let b = ln.lastIndex(of: "]") else { continue }
            let p = String(ln[ln.index(after: a)..<b])
            for suffix in ["/shared/Microsoft.NETCore.App", "\\shared\\Microsoft.NETCore.App"] where p.hasSuffix(suffix) {
                return String(p.dropLast(suffix.count))
            }
            return p
        }
        return nil
    }

    nonisolated static func dotnetRoot(for dotnet: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: dotnet)
        p.arguments = ["--list-runtimes"]
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = Pipe(); p.standardInput = FileHandle.nullDevice
        p.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"]
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        // No directory fallback: for Homebrew's symlink layout the binary's directory is not the root,
        // and a wrong DOTNET_ROOT is worse than none (the apphost stops searching once it is set).
        // When this returns nil the pipeline derives and verifies a root itself.
        return parseDotnetRoot(out)
    }

    nonisolated static func findDotnet() -> (path: String, ok: Bool) {
        let cands = [NSHomeDirectory() + "/.dotnet/dotnet",
                     "/usr/local/share/dotnet/dotnet",
                     "/opt/homebrew/bin/dotnet",
                     "/usr/local/bin/dotnet"]
        if let d = firstExisting(cands) {
            // the extractor targets net10.0, so an SDK (not just a runtime) is needed
            let ok = runOK(d, ["--list-sdks"], env: ["DOTNET_ROOT": (d as NSString).deletingLastPathComponent,
                                                      "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()])
            return (d, ok)
        }
        return ("dotnet", false)
    }

    /// Whether the selected developer directory exists (`xcode-select -p`), which is the same
    /// source of truth xcodebuild and xcrun use — so an Xcode beta, a custom location, or a
    /// Command Line Tools-only setup is reported for what it is instead of "no Xcode".
    nonisolated static func developerDirExists() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        p.arguments = ["-p"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let dir = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !dir.isEmpty else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) && isDir.boolValue
    }

    nonisolated static func detectDepsSync() -> [Dep] {
        var out: [Dep] = []

        // Xcode.app alone is not enough: since Xcode 15 the iOS platform ships as a separate
        // download, so a fresh install has xcodebuild but no iOS SDK and the build dies deep in
        // xcodebuild. Ask for the SDK version itself — that is the check that matches the name.
        // And ask xcode-select where Xcode is, not a fixed path: a beta lives at
        // /Applications/Xcode-beta.app and the hard-coded check called that "no Xcode" (#21).
        let xcodePresent = Self.developerDirExists()
            && FileManager.default.isExecutableFile(atPath: "/usr/bin/xcodebuild")
        let iosSDK = xcodePresent && runOK("/usr/bin/xcrun", ["--sdk", "iphoneos", "--show-sdk-version"])
        out.append(Dep(id: "xcode", name: "dep.xcode", hint: "dep.xcode.hint",
                       present: iosSDK,
                       detail: iosSDK ? "" : (xcodePresent ? "dep.xcode.noSDK" : ""),
                       installCmd: iosSDK ? [] : (xcodePresent
                            ? ["/usr/bin/xcodebuild", "-downloadPlatform", "iOS"]
                            : [])))

        let mt = runOK("/usr/bin/xcrun", ["-sdk", "macosx", "metal", "--version"])
        out.append(Dep(id: "metal", name: "dep.metal", hint: "dep.metal.hint",
                       present: mt, installCmd: ["xcodebuild", "-downloadComponent", "MetalToolchain"]))

        let brew = firstExisting(["/opt/homebrew/bin/brew", "/usr/local/bin/brew"])
        out.append(Dep(id: "brew", name: "dep.brew", hint: "dep.brew.hint", present: brew != nil,
                       installCmd: ["/bin/bash", "-c",
                         "NONINTERACTIVE=1 /bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""]))
        for (pkg, key) in [("xcodegen", "dep.xcodegen"), ("zstd", "dep.zstd"), ("spirv-cross", "dep.spirv")] {
            let path = firstExisting(["/opt/homebrew/bin/\(pkg)", "/usr/local/bin/\(pkg)"])
            out.append(Dep(id: "brew:" + pkg, name: key, hint: key + ".hint", present: path != nil,
                           detail: path ?? "",
                           installCmd: [(brew ?? "/opt/homebrew/bin/brew"), "install", pkg]))
        }

        let (dn, dnOK) = findDotnet()
        out.append(Dep(id: "dotnet", name: "dep.dotnet", hint: "dep.dotnet.hint",
                       present: dnOK, detail: dnOK ? dn : "dep.dotnet.missing",
                       installCmd: ["/bin/bash", "-c",
                         "curl -sSL https://dot.net/v1/dotnet-install.sh -o /tmp/di.sh && chmod +x /tmp/di.sh && /tmp/di.sh --channel 10.0 --install-dir $HOME/.dotnet"]))

        let (py, pyOK) = findPython()
        let pyVer = pythonVersion(py).map { "\($0.0).\($0.1)" } ?? "?"
        // A too-old interpreter is a different problem from a missing package: say which one it is,
        // because the fix differs (install a newer Python vs pip install into this one).
        let pyDetail = pyOK ? py
            : (pythonArch(py).map { $0 != nativeArch } ?? false)
                ? "dep.python.rosetta:\(py)"
            : (pythonVersion(py).map { $0 >= minPython } ?? false)
                ? "dep.python.missing:\(py) (\(pyVer))"
                : "dep.python.old:\(pyVer):\(minPython.0).\(minPython.1)"
        out.append(Dep(id: "python", name: "dep.python", hint: "dep.python.hint",
                       present: pyOK, detail: pyDetail,
                       installCmd: [py, "-m", "pip", "install", "--user", "lz4", "capstone", "fonttools", "backports.zstd"]))
        return out
    }

    func checkDeps() {
        depsChecked = false
        DispatchQueue.global(qos: .userInitiated).async {
            let d = Self.detectDepsSync()
            let (py, _) = Self.findPython()
            let (dn, _) = Self.findDotnet()
            DispatchQueue.main.async {
                self.deps = d
                self.pythonPath = py                     // the interpreter the build runs under
                self.dotnetPath = FileManager.default.isExecutableFile(atPath: dn) ? dn : ""
                self.depsChecked = true
            }
        }
    }

    func installDep(_ dep: Dep) {
        guard !dep.installCmd.isEmpty else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/App Store.app"))
            return   // Xcode comes from the App Store; the user re-checks when it is done
        }
        guard let i = deps.firstIndex(where: { $0.id == dep.id }) else { return }
        deps[i].installing = true
        let cmd = dep.installCmd
        DispatchQueue.global(qos: .userInitiated).async {
            var ok = true
            if dep.id == "python" {
                // A venv of our own rather than pip --user: Homebrew's Python is externally
                // managed (PEP 668) and refuses --user, which used to fail silently.
                let r = Self.makeVenv(base: self.pythonPath)
                DispatchQueue.main.async { self.append("\n--- 安装输出 ---\n" + r.log) }
                ok = r.ok
            } else {
                ok = Self.runCaptured(["/bin/bash", "-c",
                     cmd.map { $0.contains(" ") ? "'" + $0 + "'" : $0 }.joined(separator: " ")],
                     env: ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                           "HOME": NSHomeDirectory(), "NONINTERACTIVE": "1", "USER": NSUserName()])
                { line in DispatchQueue.main.async { self.append(line + "\n") } }
            }
            DispatchQueue.main.async {
                if let j = self.deps.firstIndex(where: { $0.id == dep.id }) { self.deps[j].installing = false }
                if !ok { self.doneNote = String(format: self.t("dep.install.fail"), 1) }
                self.checkDeps()
            }
        }
    }

    /// Run a command, streaming its output line by line to `line`. Returns success.
    nonisolated static func runCaptured(_ args: [String], env: [String: String], line: @escaping (String) -> Void) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: args[0])
        p.arguments = Array(args.dropFirst())
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err; p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { line("could not start \(args[0]): \(error.localizedDescription)"); return false }
        for h in [out.fileHandleForReading, err.fileHandleForReading] {
            h.readabilityHandler = { hd in
                if let s = String(data: hd.availableData, encoding: .utf8) {
                    for l in s.split(separator: "\n") { line(String(l)) }
                }
            }
        }
        p.waitUntilExit()
        out.fileHandleForReading.readabilityHandler = nil; err.fileHandleForReading.readabilityHandler = nil
        return p.terminationStatus == 0
    }

    var allDepsPresent: Bool { depsChecked && deps.allSatisfy { $0.present } }

    /// Home shown as ~ (shorter in a one-line row, and it keeps the account name out of
    /// screenshots).
    func shortPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// A dependency row's second column: a path when there is one, else the translated hint.
    /// `detail` carries either a real path, an L10n key, or "key:argument".
    func depDetail(_ d: Dep) -> String {
        let raw = d.detail
        if raw.isEmpty { return t(d.hint) }
        if raw.hasPrefix("/") || raw.hasPrefix("~") { return raw }
        if let colon = raw.firstIndex(of: ":") {
            let key = String(raw[..<colon]), arg = String(raw[raw.index(after: colon)...])
            if L10n.table[key] != nil { return String(format: t(key), shortPath(arg)) }
        }
        if L10n.table[raw] != nil { return t(raw) }
        return raw
    }
}

// MARK: - View

struct BuilderView: View {
    @ObservedObject var m: BuildModel
    @ObservedObject var library: GameLibrary
    var settings = false
    var onViewGame: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    var onChooseLibraryFolder: () -> Void = {}
    @State private var extrasOpen = false
    @State private var logOpen = false

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 34) {
                if settings { settingsPage } else { buildPage }
            }
            .padding(.horizontal, 40).padding(.top, 40).padding(.bottom, 48)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(LauncherSecondaryButtonStyle())
    }

    // ---- shared pieces: the library's and the launch options' look ----

    private func pageHeading(_ title: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.manrope(44, .heavy)).tracking(-1.3)
            Text(note).font(.manrope(15)).foregroundStyle(.secondary)
        }
    }

    /// A titled group: a small tracked label over one card of rows.
    private func group<Content: View>(_ label: String, footnote: String = "", @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label).font(.manrope(15, .semibold)).foregroundStyle(.secondary)
                .padding(.leading, 2)
            VStack(spacing: 0, content: content)
                .background(LauncherPalette.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.06)))
            if !footnote.isEmpty {
                Text(footnote).font(.manrope(12)).foregroundStyle(.secondary).padding(.leading, 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// One line of a card: a status dot (its place kept when there is none, so every title starts on one line),
    /// the title (with a disclosure chevron beside it when `open` is given), a secondary detail, and its controls,
    /// whose right edges line up across the card.
    private func row<Trailing: View>(_ title: String, detail: String = "", dot: Color? = nil, help: String = "", open: Bool? = nil,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            Circle().fill(dot ?? .clear).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.manrope(14))
                    if let open {
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(open ? 90 : 0))
                    }
                }
                if !detail.isEmpty {
                    // A path is technical text: the system's monospaced face; everything else Manrope
                    Text(detail).font(detail.hasPrefix("/") || detail.hasPrefix("~") ? .mono(12) : .manrope(12.5)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(help.isEmpty ? detail : help)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 18).padding(.vertical, 13)
        .frame(minHeight: 52)
    }

    private var divider: some View { Divider().opacity(0.25).padding(.leading, 18) }

    /// A row that opens the rows under it.
    private func disclosure(_ title: String, detail: String = "", isOpen: Bool, toggle: @escaping () -> Void) -> some View {
        Button(action: { withAnimation(.easeInOut(duration: 0.18)) { toggle() } }) {
            row(title, detail: detail, open: isOpen) { EmptyView() }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    // ---- Build game ----

    @ViewBuilder private var buildPage: some View {
        pageHeading(m.t("build.heading"), note: m.t("build.intro"))
        if !m.repoOK || !m.allDepsPresent {
            group(m.t("section.setup")) {
                row(m.t("library.setupHint"), dot: LauncherPalette.building) {
                    Button(m.t("build.setup"), action: onOpenSettings)
                }
            }
        }
        files.disabled(m.running)
        target
        if m.target != "mac-app" && m.hasInstaller { installGroup }
        action
        outcome
        progress
    }

    private var files: some View {
        // The report's own mistake, and a reasonable one: the output folder silently decides where
        // the build cache lives, so changing it threw away a finished build. Say it under Save to, all the time.
        group(m.t("section.files"), footnote: m.t("msg.workdirHint")) {
            Button(action: pickFolder) {
                row(m.t(m.gameDir.isEmpty ? "build.folderCTA" : "build.folderSelected"),
                    detail: m.gameDir.isEmpty ? m.t("build.folderNote") : m.shortPath(m.gameDir), help: m.gameDir) {
                    Text(m.t(m.gameDir.isEmpty ? "data.choose" : "data.change"))
                        .font(.manrope(13, .semibold)).foregroundStyle(.black)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(LauncherPalette.cream, in: Capsule())
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            ForEach(m.slots.filter { !$0.optional }, id: \.id) { s in divider; slotRow(s) }
            divider
            disclosure(m.t("build.options"), isOpen: extrasOpen) { extrasOpen.toggle() }
            if extrasOpen {
                ForEach(m.slots.filter(\.optional), id: \.id) { s in divider; slotRow(s) }
            }
            divider
            row(m.t("build.saveTo"), detail: m.outDir.isEmpty ? m.t("build.saveDefault") : m.shortPath(m.outDir), help: m.outDir) {
                Button(m.t("data.change")) {
                    let d = NSOpenPanel(); d.canChooseDirectories = true; d.canChooseFiles = false
                    if d.runModal() == .OK, let u = d.url { m.outDir = u.path }
                }
            }
        }
    }

    private func slotRow(_ s: Slot) -> some View {
        // An empty prod.keys row says where the file comes from.
        row(m.t(s.title), detail: s.id == "keys" && s.paths.isEmpty ? m.t("build.keyHint") : s.summary(m.t), dot: s.ok ? LauncherPalette.ready : LauncherPalette.unbuilt,
            help: s.paths.joined(separator: "\n")) {
            if !s.paths.isEmpty {
                Button(m.t("data.clear")) { m.clear(s.id) }.buttonStyle(.plain)
                    .font(.manrope(13)).foregroundStyle(.secondary)
            }
            Button(s.paths.isEmpty ? m.t("data.choose") : m.t("data.change")) { m.pickFiles(kind: s.kind) }
        }
    }

    private func pickFolder() {
        let d = NSOpenPanel()
        d.canChooseDirectories = true; d.canChooseFiles = false
        if d.runModal() == .OK, let u = d.url { m.scan(folder: u.path) }
    }

    private var target: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(m.t("section.target")).font(.manrope(15, .semibold)).foregroundStyle(.secondary)
                .padding(.leading, 2)
            HStack(spacing: 14) {
                targetCard("mac-app", symbol: "desktopcomputer", title: "build.mac", note: "build.macNote")
                targetCard("ios", symbol: "iphone", title: "build.ios", note: "build.iosNote")
            }
            // A Mac app runs on this Mac's GPU, which always decodes BC textures: the switch is the iPhone's only.
            if m.target != "mac-app" {
                VStack(spacing: 0) {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(m.t("opt.bc")).font(.manrope(14))
                            Text(m.t("opt.bc.note")).font(.manrope(12.5)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 12)
                        Toggle("", isOn: $m.bcOnCPU).toggleStyle(LauncherSwitchStyle()).labelsHidden().disabled(m.running)
                    }
                    .padding(.horizontal, 18).padding(.vertical, 14)
                }
                .background(LauncherPalette.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.06)))
                .padding(.top, 4)
            }
        }
    }

    private func targetCard(_ value: String, symbol: String, title: String, note: String) -> some View {
        let selected = m.target == value
        return Button { m.target = value } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    Image(systemName: symbol).font(.system(size: 26, weight: .light))
                        .foregroundStyle(selected ? LauncherPalette.cream : .secondary)
                    Spacer()
                    Circle().strokeBorder(selected ? LauncherPalette.cream : Color.white.opacity(0.25), lineWidth: selected ? 5 : 1.5)
                        .frame(width: 18, height: 18)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(m.t(title)).font(.manrope(16, .semibold))
                    Text(m.t(note)).font(.manrope(12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? LauncherPalette.cream.opacity(0.05) : LauncherPalette.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? LauncherPalette.cream.opacity(0.7) : Color.white.opacity(0.06), lineWidth: selected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain).disabled(m.running)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var outcome: some View {
        if m.done && m.target == "mac-app" {
            group(m.t("section.done")) {
                row(m.t("library.ready"), detail: m.shortPath(m.macAppPath), dot: LauncherPalette.ready, help: m.macAppPath) {
                    Button(m.t("install.reveal")) { reveal(m.macAppPath) }
                    Button(m.t("build.showLibrary"), action: onViewGame)
                }
            }
        }
        if m.done && m.target != "mac-app" {
            group(m.t("install.title")) {
                VStack(alignment: .leading, spacing: 10) {
                    guideRow(m.t("install.step1")); guideRow(m.t("install.step2")); guideRow(m.t("install.step3"))
                }
                .padding(.horizontal, 18).padding(.vertical, 16)
                divider
                row("IPA", detail: m.shortPath(m.ipaPath), dot: LauncherPalette.ready, help: m.ipaPath) {
                    Button(m.t("install.reveal")) { reveal(m.ipaPath) }
                }
                divider
                row("RomFS", detail: m.shortPath(m.archivePath), dot: LauncherPalette.ready, help: m.archivePath) {
                    Button(m.t("install.reveal")) { reveal(m.archivePath) }
                }
                if m.hasInstaller {
                    divider
                    row(m.t("inst.title"), detail: m.devices.first { $0.id == m.deviceID }?.name ?? m.t("inst.pick")) {
                        Button(m.t("inst.now")) { m.startInstall() }.disabled(!m.canInstall)
                    }
                }
            }
        }
    }

    /// Sign and install on a connected iPhone / iPad (scripts/install_ios.py): after the build, or with Install now.
    private var installGroup: some View {
        group(m.t("inst.title"), footnote: m.devicesChecked && m.identities.isEmpty ? m.t("inst.noCert") : m.t("inst.note")) {
            row(m.t("inst.auto"), detail: m.devices.isEmpty ? m.t(m.devicesChecked ? "inst.noDevice" : "inst.looking") : "") {
                Toggle("", isOn: $m.autoInstall).toggleStyle(LauncherSwitchStyle()).labelsHidden().disabled(m.running)
            }
            divider
            row(m.t("inst.device")) {
                if !m.devices.isEmpty {
                    Picker("", selection: $m.deviceID) {
                        if !m.devices.contains(where: { $0.id == m.deviceID }) { Text(m.t("inst.pick")).tag("") }
                        ForEach(m.devices) { d in Text(d.model.isEmpty ? d.name : "\(d.name) · \(d.model)").tag(d.id) }
                    }.labelsHidden().frame(maxWidth: 260).disabled(m.running)
                }
                Button(m.t("inst.refresh")) { m.refreshDevices() }.disabled(m.running)
            }
            if m.identities.count > 1 {
                divider
                row(m.t("inst.team"), help: m.t("inst.teamTip")) {
                    Picker("", selection: $m.team) {
                        if !m.identities.contains(where: { $0.team == m.team }) { Text(m.t("inst.pickTeam")).tag("") }
                        ForEach(m.identities) { i in Text("\(i.team) · \(i.name)").tag(i.team) }
                    }.labelsHidden().frame(maxWidth: 260).disabled(m.running)
                }
            }
        }
        .onAppear { if !m.devicesChecked { m.refreshDevices() } }
    }

    private func guideRow(_ s: String) -> some View {
        // "1\t…": the tab splits the step number from the text
        let parts = s.split(separator: "\t", maxSplits: 1)
        let num = parts.first.map(String.init) ?? ""
        let text = parts.count > 1 ? String(parts[1]) : s
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(num).font(.manrope(13, .bold)).foregroundStyle(LauncherPalette.cream).frame(width: 14)
            Text(text).font(.manrope(14)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    /// The script's own stages once a build has run, and its log behind a disclosure.
    @ViewBuilder private var progress: some View {
        if m.running || !m.stages.isEmpty {
            group(m.t("section.progress")) {
                ForEach(Array(m.stages.enumerated()), id: \.element.id) { index, s in
                    if index > 0 { divider }
                    HStack(spacing: 12) {
                        if s.state == .running { ProgressView().controlSize(.small).frame(width: 14) }
                        else { Circle().fill(s.state.color).frame(width: 7, height: 7).frame(width: 14) }
                        Text(s.name).font(.manrope(14)).lineLimit(1)
                        Spacer(minLength: 12)
                        if s.state == .running {
                            TimelineView(.periodic(from: Date(), by: 1)) { context in
                                Text([s.detail, s.clock(at: context.date, left: m.t("prog.eta"))].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.manrope(12)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                            }
                        } else if !s.detail.isEmpty { Text(s.detail).font(.manrope(12)).foregroundStyle(.secondary).lineLimit(1) }
                        if s.state == .running {
                            LauncherProgressBar(value: s.percent.map { $0 / 100 }, height: 6).frame(width: 180)
                            Text(s.percent.map { "\(Int($0))%" } ?? "").font(.manrope(13, .semibold)).monospacedDigit()
                                .foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                        }
                    }
                    .padding(.horizontal, 18).padding(.vertical, 12)
                }
                if m.stages.isEmpty && m.running {
                    row(m.t("library.preparing")) { ProgressView().controlSize(.small) }
                }
                divider
                disclosure(m.t("build.log"), isOpen: logOpen) { logOpen.toggle() }
                if logOpen { logView.padding(.horizontal, 14).padding(.bottom, 14) }
            }
        }
    }

    private var logView: some View {
        ScrollViewReader { sp in
            ScrollView {
                Text(m.logTail.isEmpty ? m.t("log.placeholder") : m.logTail)
                    .font(.mono(11))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .id("end")
            }
            .frame(height: 220)
            .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            .onChange(of: m.logTail) { _ in sp.scrollTo("end", anchor: .bottom) }
            .onAppear { sp.scrollTo("end", anchor: .bottom) }
        }
    }

    /// The page's conclusion, at the end of its column: what is still missing, and the button.
    private var action: some View {
        HStack(spacing: 18) {
            statusText
            Spacer(minLength: 12)
            Button {
                m.running ? m.stop() : m.startBuild()
            } label: {
                Label(m.running ? m.t(m.stopping ? "library.stopping" : "btn.stop") : (m.done ? m.t("btn.rebuild") : m.t("build.startGame")),
                      systemImage: m.running ? "stop.fill" : "hammer.fill")
                    .font(.manrope(15, .semibold)).padding(.horizontal, 24).padding(.vertical, 13)
                    .foregroundStyle(.black).background(m.running ? LauncherPalette.building : LauncherPalette.cream, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(m.stopping || (!m.running && !m.canBuild))
            .opacity(m.stopping || (!m.running && !m.canBuild) ? 0.4 : 1)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.top, 2)
    }

    @ViewBuilder private var statusText: some View {
        if !m.doneNote.isEmpty {
            Text(m.doneNote).font(.manrope(13))
                .foregroundStyle(m.done ? LauncherPalette.ready : LauncherPalette.building).lineLimit(2)
        } else if !m.depsChecked {
            Text(m.t("status.checkingDeps")).font(.manrope(13)).foregroundStyle(.secondary)
        } else if !m.allDepsPresent {
            Text(m.t("status.installFirst")).font(.manrope(13)).foregroundStyle(LauncherPalette.building)
        } else if !m.repoOK {
            Text(m.t("status.chooseRepo")).font(.manrope(13)).foregroundStyle(LauncherPalette.building)
        } else if !m.slot("base").ok || !m.slot("keys").ok {
            Text(m.t("status.needInputs")).font(.manrope(13)).foregroundStyle(.secondary)
        } else {
            Text(String(format: m.t("status.output"), m.shortPath(m.outDir.isEmpty ? (m.basePath as NSString).deletingLastPathComponent : m.outDir)))
                .font(.manrope(13)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
        }
    }

    // ---- Settings ----

    @ViewBuilder private var settingsPage: some View {
        pageHeading(m.t("settings.heading"), note: m.t("settings.note"))
        group(m.t("section.library"), footnote: m.t("library.folderHint")) {
            row(m.t("library.folderTitle"), detail: library.folder.isEmpty ? m.t("library.folderUnset") : m.shortPath(library.folder),
                dot: library.folder.isEmpty ? LauncherPalette.unbuilt : LauncherPalette.ready, help: library.folder) {
                if library.scanning { ProgressView().controlSize(.small) }
                if !library.folder.isEmpty {
                    Button(m.t("library.rescan")) { library.discover() }.disabled(library.scanning)
                }
                Button(m.t("library.chooseFolder"), action: onChooseLibraryFolder)
            }
        }
        tools
        group(m.t("section.app"), footnote: m.appStatus) {
            row("nxnative", detail: String(format: m.t("app.version"), BuildModel.appVersion)) {
                if let u = m.appUpdate {
                    Button(String(format: m.t("app.updateBtn"), u.tag)) { m.performAppUpdate() }.disabled(m.appBusy)
                } else {
                    Button(m.t("repo.check")) { m.checkAppUpdate() }.disabled(m.appBusy)
                }
            }
        }
    }

    private var tools: some View {
        group(m.t("section.tools"), footnote: m.repoStatus.isEmpty ? (m.repoOK ? "" : m.t("repo.firstHint")) : m.repoStatus) {
            row(m.t("repo.title"),
                detail: m.repoOK ? m.shortPath(m.repoPath)
                    : (m.repoPath.isEmpty ? m.t("repo.notFound") : String(format: m.t("repo.notRepo"), m.shortPath(m.repoPath))),
                dot: m.repoOK ? LauncherPalette.ready : LauncherPalette.building, help: m.repoPath) {
                if m.repoBusy { ProgressView().controlSize(.small) }
                if m.repoOK {
                    if m.repoIsGit {
                        if let n = m.repoBehind, n > 0 {
                            Button(m.t("repo.pull")) { m.pullRepo() }.disabled(m.repoBusy || m.running)
                        }
                        Button(m.t("repo.check")) { m.checkRepoUpdates() }.disabled(m.repoBusy || m.running)
                    } else {
                        Button(m.t("repo.adopt")) { m.adoptRepoAsGit() }.disabled(m.repoBusy || m.running)
                    }
                } else {
                    Button(m.t("repo.choose")) { pickRepo() }
                    Button(m.t("repo.download")) { m.cloneRepo() }.disabled(m.repoBusy || m.running)
                }
            }
            if !m.repoOK {
                // GitHub does not load everywhere: the manual route (Code → Download ZIP → unzip →
                // Choose repository) needs no git at all, and the note says which folder to pick.
                HStack(spacing: 4) {
                    Text(m.t("repo.manualHint")).foregroundStyle(.secondary)
                    Link("github.com/LNPANDY/NX2Apple", destination: URL(string: BuildModel.repoURL.replacingOccurrences(of: ".git", with: ""))!)
                    Text(m.t("repo.manualHint2")).foregroundStyle(.secondary)
                }
                .font(.manrope(12)).padding(.horizontal, 18).padding(.bottom, 12)
            }
            if m.repoOK, !m.repoIsGit {
                Text(m.t("repo.noGit")).font(.manrope(12)).foregroundStyle(.secondary)
                    .padding(.horizontal, 18).padding(.bottom, 12)
            }
            divider
            Button(action: { withAnimation(.easeInOut(duration: 0.18)) { m.toggleDeps() } }) {
                row(m.t("dep.title"),
                    detail: !m.depsChecked ? m.t("dep.checking")
                        : (m.allDepsPresent ? m.t("dep.allReady") : String(format: m.t("dep.missing"), m.deps.filter { !$0.present }.count)),
                    dot: !m.depsChecked ? LauncherPalette.unbuilt : (m.allDepsPresent ? LauncherPalette.ready : LauncherPalette.building),
                    open: m.depsOpen) {
                    if !m.depsChecked { ProgressView().controlSize(.small) }
                    Button(m.t("dep.recheck")) { m.checkDeps() }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if m.depsOpen {
                ForEach(m.deps, id: \.id) { d in
                    divider
                    row(m.t(d.name), detail: m.shortPath(m.depDetail(d)), dot: d.present ? LauncherPalette.ready : LauncherPalette.building,
                        help: m.t(d.hint)) {
                        if d.installing {
                            ProgressView().controlSize(.small)
                            Text(m.t("dep.installing")).font(.manrope(12)).foregroundStyle(LauncherPalette.building)
                        } else if !d.present {
                            Button(d.installCmd.isEmpty ? m.t("dep.openAppStore") : m.t("dep.install")) { m.installDep(d) }
                        }
                    }
                }
            }
        }
    }

    private func pickRepo() {
        let d = NSOpenPanel()
        d.canChooseDirectories = true; d.canChooseFiles = false
        d.message = m.t("repo.pickMessage")
        if d.runModal() == .OK, let u = d.url { m.repoPath = u.path }
    }
}
