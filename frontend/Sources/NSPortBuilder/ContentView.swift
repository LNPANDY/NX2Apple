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
        didSet {
            UserDefaults.standard.set(target, forKey: "buildTarget")
            // A Mac-only setup needs no iOS SDK for a Mac build, but does for an iPhone one (needsIOSPlatform)
            if oldValue != target, UserDefaults.standard.string(forKey: OnboardingDefaults.platform) == "mac" { checkDeps() }
        }
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
    var lastBuildCommand: [String] = []   // this session's last build, for Copy diagnostics (Diagnostics.swift)

    // ---- Installing on an iPhone or iPad (Xcode with a development certificate) ----
    // Optional: with a paired device and a signing team chosen, the script prepares the game's Xcode project
    // (--prepare-xcode, the route its README gives developers), xcodebuild signs it for that device with the
    // team (Xcode makes the provisioning profile) without the game files, devicectl installs it and copies the game's
    // folder (romfs.img, aoc/) into its Documents, as a sideloaded copy has it. Without a device or a team the build stays an unsigned IPA, as before.
    @Published var devices: [AppleDevice] = []
    @Published var teams: [SigningTeam] = []
    @Published var devicesChecked = false
    @Published var installDevice = UserDefaults.standard.string(forKey: "installDevice") ?? "" {
        didSet { UserDefaults.standard.set(installDevice, forKey: "installDevice") }
    }
    @Published var signingTeam = UserDefaults.standard.string(forKey: "signingTeam") ?? "" {
        didSet { UserDefaults.standard.set(signingTeam, forKey: "signingTeam") }
    }
    @Published var installedOn = ""       // the device the last build went to (its UDID)
    @Published var installedAppPath = ""  // the signed app that went there
    @Published var transferAsk = false    // the transfer-the-game-files question is up: USB from the Mac is slow, so copying is the player's call
    private var transferHandler: ((Bool) -> Void)?

    /// Asks whether to copy the game files to the device now, and runs `then` with the answer on the main queue.
    func askTransfer(_ then: @escaping (Bool) -> Void) {
        transferHandler = then
        transferAsk = true
    }

    func transferAnswer(_ ok: Bool) {
        guard let then = transferHandler else { return }
        transferHandler = nil
        then(ok)
    }
    private var bundleID = ""             // from the script's "bundle ID:" line
    var xcrunPath = "/usr/bin/xcrun"      // tests stand in for xcodebuild and devicectl

    /// This iPhone build goes straight to a device.
    var installsDirectly: Bool { target != "mac-app" && !installDevice.isEmpty && !signingTeam.isEmpty }

    func deviceName(_ udid: String) -> String { devices.first { $0.id == udid }?.name ?? "iPhone" }

    /// The paired devices and the signing teams, read in the background (devicectl can take a few seconds).
    func refreshDevices() {
        let xcrun = xcrunPath
        DispatchQueue.global(qos: .userInitiated).async {
            let devices = DeviceTools.devices(xcrun: xcrun), teams = DeviceTools.teams()
            DispatchQueue.main.async {
                self.devices = devices; self.teams = teams; self.devicesChecked = true
                if !teams.contains(where: { $0.id == self.signingTeam }) { self.signingTeam = teams.first?.id ?? "" }
            }
        }
    }

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
    @Published var lang: Lang = Lang.initial()
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

    /// A build's process group is still running (the app update waits for it: its relaunch would end the build).
    static var buildProcessesAlive: Bool {
        groupsLock.lock(); defer { groupsLock.unlock() }
        return groups.contains { killpg($0, 0) == 0 }
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

    /// Every file of the repository the launcher itself runs by path: one list, next to the calls that use it
    /// (the build script in startBuild, the RomFS archive in the archive step). A copy older than this app lacks some of
    /// them (#87: romfs_image.py exists since v0.4.8, so a build ran 70 minutes and failed at its last step). A new
    /// tool the launcher calls goes into this list and is then checked before every build.
    nonisolated static let buildScript = "scripts/build_ipa_from_nsp.py"
    nonisolated static let romfsImageTool = "dm/tools/romfs_image.py"
    nonisolated static let requiredTools = [buildScript, romfsImageTool]

    /// The tools of `requiredTools` that `dir` does not have (empty: the build tools are as new as this app needs).
    nonisolated static func missingTools(in dir: String) -> [String] {
        requiredTools.filter { !FileManager.default.fileExists(atPath: dir + "/" + $0) }
    }

    /// Whether the checkout's build script has this fork's `--work-dir` (issue #5): an upstream
    /// nxnative checkout, or a ZIP of an older release, stops with "unrecognized arguments" when the
    /// app passes it. Read from the script's own argparse rather than assumed — the option is the
    /// fork's, not upstream's.
    nonisolated static func repoSupportsWorkDir(_ dir: String) -> Bool {
        let script = dir + "/" + buildScript
        guard let text = try? String(contentsOfFile: script, encoding: .utf8) else { return false }
        return text.contains("'--work-dir'") || text.contains("\"--work-dir\"")
    }

    nonisolated static func findRepo() -> String {
        // A candidate that is merely a repository (an upstream nxnative clone) must lose to one
        // carrying this fork's `--work-dir`: building from an upstream checkout fails with
        // "unrecognized arguments" after the app has already picked it — and a saved path from an
        // earlier session pointed at exactly such a clone, so every build said 仓库不是最新版本
        // (the report's build log). The fork check is the script's own argparse, not a name match,
        // so a checkout under any folder name ranks correctly.
        let saved = UserDefaults.standard.string(forKey: "repoPath").flatMap { isRepo($0) ? $0 : nil }
        var seeds: [String] = []
        // the app bundle: …/frontend/NX2Apple.app/Contents/MacOS — the checkout it ships from wins
        let bundle = Bundle.main.bundleURL.standardizedFileURL
        seeds.append(bundle.deletingLastPathComponent().path)
        seeds.append(bundle.deletingLastPathComponent().deletingLastPathComponent()
                         .deletingLastPathComponent().deletingLastPathComponent().path)
        seeds.append(FileManager.default.currentDirectoryPath)
        for base in ["/ZCodeProject/", "/", "/Documents/", "/Desktop/"] {
            seeds.append(NSHomeDirectory() + base + "nxnative-romfs-archive")   // clones made before the rename still resolve
            seeds.append(NSHomeDirectory() + base + "NX2Apple")
            seeds.append(NSHomeDirectory() + base + "nxnative")                 // an upstream clone: last resort
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
        let forks = repos.filter { repoSupportsWorkDir($0) }
        if let saved, repoSupportsWorkDir(saved) { return saved }   // the player's own fork checkout
        if let f = forks.first, f != saved {
            if let saved { fputs("launcher: using the fork checkout \(f); the saved repository \(saved) is an upstream clone without --work-dir\n", stderr) }
            return f
        }
        return saved ?? repos.first ?? ""
    }

    // ---- Repository download and updates (a clone is the scripts' home; not everyone has git habits) ----

    static let repoURL = "https://github.com/LNPANDY/NX2Apple.git"
    /// Clone/pull/check in flight; the buttons disable and the status line says what is happening.
    @Published var repoBusy = false
    @Published var repoStatus = ""
    /// nil = not checked yet, 0 = up to date, n = n commits behind origin/main.
    @Published var repoBehind: Int?
    /// Pull origin/main by itself when the app opens (Settings; on by default), so the build tools are the current ones:
    /// a checkout days behind built with tools main had already fixed (spirv-cross without its x bit, #41).
    @Published var autoUpdateRepo = UserDefaults.standard.object(forKey: "autoUpdateRepo") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoUpdateRepo, forKey: "autoUpdateRepo") }
    }
    /// The commits the automatic update brought when the app opened; the library's activity line names them. nil: none.
    @Published var autoPulled: Int?
    /// A copy without .git was connected to git and brought to the current version when the app opened (adoptAtLaunch).
    @Published var autoAdopted = false

    nonisolated static func gitBinary() -> String? {
        for c in ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]
            where FileManager.default.isExecutableFile(atPath: c) { return c }
        return nil
    }
    nonisolated static func gitEnv() -> [String: String] {
        ["PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin", "HOME": NSHomeDirectory()]
    }

    /// The PATH of the processes that run the build, installing packages and writing the RomFS image: the bundled tools in front of
    /// `base` (BundledTools.swift), which is Homebrew's folders and the system's. One place, so that no environment forgets the bundle.
    nonisolated static func toolPath(_ base: String = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", python: String? = nil) -> String {
        BundledTools.path(base, python: python)
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
        let dest = NSHomeDirectory() + "/NX2Apple"
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
                    else if behind > 0 && self.autoUpdateRepo { self.autoPull(behind) }   // the check when the app opens
                } else if !silent {
                    self.repoStatus = self.t("repo.netFail")
                }
            }
        }
    }

    /// Fast-forward the checkout to origin/main. The build keeps everything it needs under
    /// <id>_build/ outside the repository, so a pull never disturbs a previous build's files.
    /// The status line for a failed pull. A diverged checkout ("Not possible to fast-forward") has its
    /// own commit history — a clone someone worked in, or an old upstream checkout — and no amount of
    /// pulling fixes that; the actionable answer is the repository picker, which is always offered now.
    func pullFailureMessage(_ gitOutput: String) -> String {
        let diverged = gitOutput.contains("fast-forward") || gitOutput.contains("Diverging")
        return t(diverged ? "repo.pullDiverged" : "repo.pullFail")
    }

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
                    self.repoStatus = self.pullFailureMessage(r.out)
                    self.append(r.out + "\n")
                }
            }
        }
    }

    /// The automatic update when the app opens: a fast-forward to origin/main, only for a checkout on main with no changes
    /// to its tracked files and no build running, so a checkout someone works in is never touched. Settings says what
    /// happened (or why not), and the library's activity line names the new commits.
    func autoPull(_ behind: Int) {
        guard !running, !repoBusy, repoOK, repoIsGit, let git = Self.gitBinary() else { return }
        repoBusy = true
        let dir = repoPath
        DispatchQueue.global().async {
            let branch = Self.runQuiet([git, "-C", dir, "rev-parse", "--abbrev-ref", "HEAD"], env: Self.gitEnv())
            let status = Self.runQuiet([git, "-C", dir, "status", "--porcelain", "--untracked-files=no"], env: Self.gitEnv())
            let allowed = branch.ok && status.ok && Self.autoPullAllowed(branch: branch.out, status: status.out)
            let pulled = allowed ? Self.runQuiet([git, "-C", dir, "pull", "--ff-only", "origin", "main"], env: Self.gitEnv()) : nil
            DispatchQueue.main.async {
                self.repoBusy = false
                guard let pulled else { self.repoStatus = self.t("repo.autoSkipped"); return }
                if pulled.ok {
                    self.repoBehind = 0; self.autoPulled = behind
                    self.repoStatus = String(format: self.t("repo.autoPulled"), behind)
                } else {
                    self.repoStatus = self.pullFailureMessage(pulled.out)
                    self.append(pulled.out + "\n")
                }
            }
        }
    }

    /// A checkout the automatic update may move: on main, with no changes to tracked files (untracked files stay; a pull
    /// that would overwrite one fails as a fast-forward and says so).
    nonisolated static func autoPullAllowed(branch: String, status: String) -> Bool {
        branch.trimmingCharacters(in: .whitespacesAndNewlines) == "main" && status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The local branch that keeps a ZIP copy as it was when it is connected to git.
    nonisolated static func zipCopyBranch(date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return "zip-copy-" + f.string(from: date)
    }

    /// What the launch does with the configured repository when it is a copy without .git (#87: a ZIP copy never updated
    /// itself, so its build tools were older than the app).
    enum ZipAdoption: Equatable { case notNeeded, adopt, waitsForBuild, autoUpdateOff }

    /// Pure: adopt a valid checkout without .git into git, but never while a build runs (or another repository task),
    /// and not when the player turned the automatic update off.
    nonisolated static func zipAdoption(isRepo: Bool, isGit: Bool, buildRunning: Bool, repoBusy: Bool, autoUpdate: Bool) -> ZipAdoption {
        guard isRepo, !isGit else { return .notNeeded }
        if buildRunning || repoBusy { return .waitsForBuild }
        return autoUpdate ? .adopt : .autoUpdateOff
    }

    /// The launch-time step for a ZIP copy; a git checkout is left to checkRepoUpdates. Settings and the library's
    /// activity line say what happened.
    func adoptAtLaunch(remote: String = BuildModel.repoURL) {
        switch Self.zipAdoption(isRepo: repoOK, isGit: repoIsGit, buildRunning: running, repoBusy: repoBusy, autoUpdate: autoUpdateRepo) {
        case .notNeeded: break
        case .waitsForBuild: repoStatus = t("repo.zipWaits")
        case .autoUpdateOff: break   // Settings says so next to the repository (repo.zipNoAuto): the player chose this
        case .adopt:
            if Self.gitBinary() == nil { repoStatus = t("repo.gitMissing") }
            else { adoptRepoAsGit(automatic: true, remote: remote) }
        }
    }

    /// A ZIP copy has no .git: adopt it into git in place (init, remote, fetch, checkout) so the
    /// update buttons work and the folder keeps its path. The copy may hold the player's own edits (a tweaked game
    /// profile), and the checkout resets every tracked file to origin/main, so the copy is recorded first: after the
    /// fetch, the files of the copy that origin/main also has are committed on the local branch `zip-copy-<date>`
    /// (fixed local author, no git identity needed). Only those paths: a build folder or any other file that origin/main
    /// does not track is never committed (and the checkout leaves such files where they are). The build's own files live
    /// outside the repository.
    /// `automatic`: the launch-time adoption (adoptAtLaunch); `remote` is GitHub unless a test points it at a local repository.
    func adoptRepoAsGit(automatic: Bool = false, remote: String = BuildModel.repoURL) {
        guard !running, !repoBusy, repoOK, !repoIsGit, let git = Self.gitBinary() else { return }
        repoBusy = true; repoStatus = t("repo.adopting")
        let dir = repoPath
        DispatchQueue.global().async {
            var out = "", ok = true
            let branch = Self.zipCopyBranch()
            func run(_ args: [String]) -> (ok: Bool, out: String) {
                let r = Self.runQuiet([git, "-C", dir] + args, env: Self.gitEnv())
                out += "$ git \(args.joined(separator: " "))\n\(r.out)\n"
                return r
            }
            // Nothing in the folder changes before the fetch has worked, so an offline failure leaves the copy as it was.
            ok = run(["init"]).ok && run(["remote", "add", "origin", remote]).ok && run(["fetch", "--depth", "1", "origin", "main"]).ok
            if ok {
                let tree = run(["ls-tree", "-r", "-z", "--name-only", "origin/main"])
                let present = tree.out.split(separator: "\0").map(String.init).filter { FileManager.default.fileExists(atPath: dir + "/" + $0) }
                let list = NSTemporaryDirectory() + "nspb-zip-paths-\(UUID().uuidString.prefix(8)).txt"
                defer { try? FileManager.default.removeItem(atPath: list) }
                let identity = ["-c", "user.name=NX2Apple", "-c", "user.email=nx2apple@localhost", "-c", "commit.gpgsign=false"]
                ok = tree.ok
                    && run(["symbolic-ref", "HEAD", "refs/heads/" + branch]).ok
                    && ((try? Data(present.joined(separator: "\0").utf8).write(to: URL(fileURLWithPath: list))) != nil)
                    && run(["add", "--pathspec-from-file=" + list, "--pathspec-file-nul"]).ok
                    && run(identity + ["commit", "--allow-empty", "-m", "The ZIP copy as it was before it was connected to git"]).ok
                    && run(["checkout", "-f", "-B", "main", "origin/main"]).ok
            }
            if ok { _ = Self.runQuiet([git, "-C", dir, "branch", "--set-upstream-to=origin/main", "main"], env: Self.gitEnv()) }   // checkout -B usually set it
            // A failed adoption (offline) must not leave the .git that `git init` made: the copy would count as a
            // checkout from then on, and neither the launch nor the button would try again. The guard above
            // means there was no .git before, so this removes only what this call created.
            if !ok { try? FileManager.default.removeItem(atPath: dir + "/.git") }
            DispatchQueue.main.async {
                self.repoBusy = false
                self.append(out + "\n")
                if ok && self.repoIsGit {
                    // the checkout is origin/main as just fetched: up to date, nothing left to pull
                    self.repoBehind = 0
                    self.repoStatus = String(format: self.t(automatic ? "repo.adoptedAuto" : "repo.adopted"), branch)
                    if automatic { self.autoAdopted = true }
                } else {
                    self.repoStatus = self.t(automatic ? "repo.adoptFailAuto" : "repo.adoptFail")
                }
            }
        }
    }

    // ---- App self-update (GitHub Releases) ----
    // The rules (what is verified, which copies replace themselves, never during a build) are in AppUpdate.swift.

    /// Bump together with each release tag; the update check compares it with the latest release.
    static let appVersion = "0.6.0"
    /// The update checkAppUpdate found: the tag, the asset to download, its digest, and the release
    /// notes the sheet shows. The notes are why the sheet exists — "update available" alone told a
    /// user nothing about what they would get.
    @Published var appUpdate: AppUpdate.Release?
    @Published var appBusy = false
    /// Whether the "a new version is out" sheet is up: opened by the launch check and by Check for
    /// updates, so a user learns what changed before deciding, not after downloading.
    @Published var showUpdateSheet = false
    @Published var appStatus = ""
    /// Set when the last update attempt was refused (a release this macOS cannot open, a bad download); the update sheet shows it.
    @Published var appUpdateBlocked: String?
    /// Download a new release by itself and install it when the app quits (Settings; on by default). Off, the
    /// Update button in Settings works as before: download, swap in, relaunch.
    @Published var autoUpdateApp = UserDefaults.standard.object(forKey: "autoUpdateApp") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoUpdateApp, forKey: "autoUpdateApp")
            if autoUpdateApp, appStaged == nil, let u = appUpdate { stageAppUpdate(u, automatic: true) }
        }
    }
    /// The release that is downloaded, verified and unpacked: it goes in when the app quits, or with Restart now.
    @Published var appStaged: AppUpdate.Staged?
    /// Where a rename-era install put the new app (the old bundle name is gone): Settings shows it,
    /// because the Dock entry pointing at the old path is stale until the player re-pins it.
    static var noteRenamedInstall: String?
    /// Whether this copy may replace itself; a launcher built from the repository never does (tests set it).
    var appInstallability = AppUpdate.installability(Bundle.main.bundleURL, appVersion: BuildModel.appVersion)
    private var quitObserver: NSObjectProtocol?

    /// The download names this build accepts, newest first. Every release must carry at least one of
    /// them or an install from that era cannot update itself: NX2Apple is current, nxnative is for
    /// installs from before the rename to NX2Apple, NS-Port-Builder for installs before that.
    nonisolated static let appAssetNames = ["NX2Apple-macOS-arm64.zip", "nxnative-macOS-arm64.zip",
                                           "NS-Port-Builder-macOS-arm64.zip"]

    nonisolated static func isNewer(_ tag: String, than current: String) -> Bool {
        func nums(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0.filter { $0.isNumber }) ?? 0 } }
        let a = nums(tag), b = nums(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// The release's asset this app installs, with its digest: NX2Apple-macOS-arm64.zip, or the zip under an older
    /// name (releases from before each rename).
    nonisolated static func appRelease(fromJSON obj: [String: Any]) -> AppUpdate.Release? {
        let tag = obj["tag_name"] as? String ?? ""
        guard let assets = obj["assets"] as? [[String: Any]] else { return nil }
        for name in ["NX2Apple-macOS-arm64.zip", "nxnative-macOS-arm64.zip", "NS-Port-Builder-macOS-arm64.zip"] {
            for a in assets where (a["name"] as? String) == name {
                if let u = a["browser_download_url"] as? String { return AppUpdate.Release(tag: tag, url: u, digest: a["digest"] as? String) }
            }
        }
        return nil
    }

    /// Ask GitHub for the latest release. `silent` (the launch check) only surfaces a found update;
    /// "up to date" and network failures stay quiet. A slow or blocked network just times out.
    /// With automatic updates on, a found release is downloaded and staged in the background.
    func checkAppUpdate(silent: Bool = false) {
        guard !appBusy else { return }
        appBusy = true
        if !silent { appStatus = t("app.checking") }
        URLSession.shared.dataTask(with: URL(string: "https://api.github.com/repos/LNPANDY/NX2Apple/releases/latest")!) { data, _, _ in
            var found: AppUpdate.Release?
            // A newer release whose download this build cannot name is NOT "up to date". That
            // distinction is the difference between a user who updates and one who sits on 0.4.6
            // for ever: 0.4.6 and 0.4.7 look for exactly "NS-Port-Builder-macOS-arm64.zip", and if a
            // release ever ships without that name they report "已是最新" and stop.
            var newerTag: String?
            if let d = data, let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                let tag = obj["tag_name"] as? String ?? ""
                if Self.isNewer(tag, than: Self.appVersion) {
                    newerTag = tag
                    if var r = Self.appRelease(fromJSON: obj) {
                        r.notes = (obj["body"] as? String) ?? ""
                        found = r
                    }
                }
            }
            DispatchQueue.main.async {
                self.appBusy = false
                if let f = found {
                    self.appUpdate = f
                    switch self.appInstallability {
                    case .developer: self.appStatus = String(format: self.t("app.devBuild"), f.tag)
                    case .readOnly: self.appStatus = String(format: self.t("app.readOnly"), f.tag)
                    case .ok:
                        if self.appStaged?.release == f { self.appStatus = String(format: self.t("app.ready"), f.tag) }
                        else if self.autoUpdateApp { self.stageAppUpdate(f, automatic: true) }
                        else { self.appStatus = String(format: self.t("app.found"), f.tag) }
                        // The sheet opens either way: it is the only place the release notes appear,
                        // and "a new version is out" without saying what changed is what made people
                        // press Update blindly or not at all. In automatic mode it is also where
                        // Restart now lives, and it says the download is already running.
                        self.showUpdateSheet = true
                    }
                } else if !silent {
                    if data == nil {
                        self.appStatus = self.t("app.netFail")
                    } else if let tag = newerTag {
                        // The release exists; this app just cannot find its own asset name in it.
                        self.appStatus = String(format: self.t("app.noAsset"), tag)
                        self.appUpdate = nil
                    } else {
                        self.appStatus = self.t("app.upToDate")
                    }
                }
            }
        }.resume()
    }

    /// Download the release, check it against its digest, unpack it and check the app inside, all in the background;
    /// the result waits in appStaged. `automatic` (the switch) refuses a release whose digest GitHub did not give;
    /// the Update button accepts it, as before. `then` gets the staged copy (the button installs it at once).
    func stageAppUpdate(_ release: AppUpdate.Release, automatic: Bool, then: ((AppUpdate.Staged) -> Void)? = nil) {
        guard !appBusy, appInstallability == .ok, let url = URL(string: release.url) else { return }
        appBusy = true
        appUpdateBlocked = nil
        appStatus = String(format: t(automatic ? "app.staging" : "app.downloading"), release.tag)
        let expectedID = Bundle.main.bundleIdentifier ?? ""
        DispatchQueue.global().async {
            let result = Self.downloadAndStage(release, from: url, expectedID: expectedID, requireDigest: automatic)
            DispatchQueue.main.async {
                self.appBusy = false
                switch result {
                case .success(let staged):
                    self.appStaged = staged
                    self.appStatus = String(format: self.t("app.ready"), release.tag)
                    self.installAtQuit()
                    then?(staged)
                case .failure(let why):
                    if case .needsNewerMacOS(let min) = why {
                        // Nothing was installed: the running version stays, and says why
                        let now = AppUpdate.describe(ProcessInfo.processInfo.operatingSystemVersion)
                        self.appStatus = String(format: self.t(why.key), release.tag, min, now)
                    } else {
                        self.appStatus = String(format: self.t(why.key), release.tag)
                    }
                    self.appUpdateBlocked = self.appStatus
                }
            }
        }
    }

    /// Why staging stopped: each case is the localization key of its message (a format with the release's tag).
    enum StageFailure: Error, Equatable {
        case network, noDigest, mismatch, unpack, notOurApp
        /// The release's LSMinimumSystemVersion is above the running macOS (the string is that minimum).
        case needsNewerMacOS(String)

        var key: String {
            switch self {
            case .network: return "app.stageNetFail"
            case .noDigest: return "app.noDigest"
            case .mismatch: return "app.digestMismatch"
            case .unpack: return "app.unpackFail"
            case .notOurApp: return "app.notOurApp"
            case .needsNewerMacOS: return "app.needsNewerMacOS"
            }
        }
    }

    /// The background part of staging, in a folder of its own in the temporary directory (emptied first).
    nonisolated static func downloadAndStage(_ release: AppUpdate.Release, from url: URL, expectedID: String,
                                             requireDigest: Bool) -> Result<AppUpdate.Staged, StageFailure> {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("nspb-update", isDirectory: true)
        try? fm.removeItem(at: root)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        let zip = root.appendingPathComponent("update.zip")
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.downloadTask(with: url) { local, response, _ in
            if let local, (response as? HTTPURLResponse)?.statusCode ?? 200 == 200 { try? FileManager.default.moveItem(at: local, to: zip) }
            sem.signal()
        }.resume()
        sem.wait()
        guard fm.fileExists(atPath: zip.path) else { return .failure(.network) }
        return stage(zip: zip, release: release, in: root, expectedID: expectedID, requireDigest: requireDigest)
    }

    /// A downloaded zip to a staged app: its digest first, then unzip (ditto, as the release was packed), then the app inside.
    nonisolated static func stage(zip: URL, release: AppUpdate.Release, in root: URL, expectedID: String,
                                  requireDigest: Bool,
                                  runningOS: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> Result<AppUpdate.Staged, StageFailure> {
        let fm = FileManager.default
        switch AppUpdate.checkDigest(zip, expected: release.digest) {
        case .match: break
        case .mismatch: try? fm.removeItem(at: zip); return .failure(.mismatch)
        case .missing: if requireDigest { try? fm.removeItem(at: zip); return .failure(.noDigest) }
        }
        let dir = root.appendingPathComponent("app", isDirectory: true)
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip.path, dir.path]
        do { try unzip.run() } catch { return .failure(.unpack) }
        unzip.waitUntilExit()
        try? fm.removeItem(at: zip)
        // The archive holds one app: NX2Apple.app, or the bundle under an older name in a release from before a rename
        guard unzip.terminationStatus == 0,
              let app = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).first(where: { $0.pathExtension == "app" })
        else { return .failure(.unpack) }
        if AppUpdate.bundleProblem(app, expectedID: expectedID, tag: release.tag) != nil {
            try? fm.removeItem(at: dir)
            return .failure(.notOurApp)
        }
        // Not a release this Mac cannot open: it would replace a launcher that works with an app that will not start
        if let min = AppUpdate.minimumOSAbove(runningOS, app: app) {
            try? fm.removeItem(at: dir)
            return .failure(.needsNewerMacOS(min))
        }
        return .success(AppUpdate.Staged(release: release, app: app))
    }

    /// No build of this app is running: none in the model, and no process group of one still alive (a stopped
    /// build's tools can take a moment to go).
    var mayInstallAppUpdate: Bool { !running && !Self.buildProcessesAlive }

    /// Swap the staged app in. `relaunch` (Restart now, the Update button) opens the new copy and exits; at quit
    /// the next launch is the new version. Refused while a build runs.
    @discardableResult
    func installStagedUpdate(relaunch: Bool, at current: URL = Bundle.main.bundleURL) -> Bool {
        guard let staged = appStaged, appInstallability == .ok else { return false }
        let placed: URL
        do {
            placed = try AppUpdate.install(staged.app, over: current, buildRunning: !mayInstallAppUpdate)
        } catch AppUpdate.InstallError.failed(let why) {
            appStatus = String(format: t("app.installFail"), why)
            return false
        } catch {
            appStatus = t("app.waitForBuild")
            return false
        }
        appStaged = nil
        // A rename era (nxnative → NS Port Builder → NX2Apple) installs under the release's own
        // bundle name; the Dock entry pointing at the old path goes stale once, so the log says
        // where the new copy landed instead of leaving the player to find it.
        if placed != current {
            fputs("launcher: the update was installed as \(placed.lastPathComponent) (the app was renamed); "
                + "the previous \(current.lastPathComponent) was removed — re-pin it in the Dock\n", stderr)
            Self.noteRenamedInstall = placed.path
        }
        if relaunch {
            appStatus = String(format: t("app.relaunching"), staged.release.tag)
            NSWorkspace.shared.openApplication(at: placed, configuration: NSWorkspace.OpenConfiguration())
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { exit(0) }
        }
        return true
    }

    /// Restart now (Settings, the library's activity line): install and relaunch, never during a build.
    func restartToUpdate() {
        guard appStaged != nil else { return }
        guard mayInstallAppUpdate else { appStatus = t("app.waitForBuild"); return }
        installStagedUpdate(relaunch: true)
    }

    /// The staged update goes in as the app quits, so the next launch is the new version without interrupting
    /// anyone. A build running at that moment is being ended by the same quit (exitHandlers): the swap then waits
    /// for a later quit (the next launch stages the release again) rather than run while the build's tools are alive.
    private func installAtQuit() {
        guard quitObserver == nil else { return }
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self, self.autoUpdateApp, self.appStaged != nil, self.mayInstallAppUpdate else { return }
            self.installStagedUpdate(relaunch: false)
        }
    }

    /// The Update button (automatic updates off, or a release they would not take): download and verify, swap in,
    /// relaunch. A staged copy of the same release goes in as it is. Not during a build: the relaunch would end it.
    func performAppUpdate() {
        guard let upd = appUpdate, !appBusy, appInstallability == .ok else { return }
        guard mayInstallAppUpdate else { appStatus = t("app.waitForBuild"); return }
        if appStaged?.release == upd { installStagedUpdate(relaunch: true); return }
        stageAppUpdate(upd, automatic: false) { [weak self] _ in
            guard let self else { return }
            self.appStatus = self.t("app.installing")
            self.installStagedUpdate(relaunch: true)
        }
    }

    var basePath: String { slot("base").paths.first ?? "" }
    var keysPath: String { slot("keys").paths.first ?? "" }
    var updatePath: String { slot("update").paths.first ?? "" }
    var dlcPaths: [String] { slot("dlc").paths }

    func slot(_ id: String) -> Slot { slots.first { $0.id == id } ?? slots[0] }
    func updateSlot(_ id: String, _ body: (inout Slot) -> Void) {
        if let i = slots.firstIndex(where: { $0.id == id }) { body(&slots[i]) }
    }

    // MARK: Inputs

    /// Fill every slot from a folder: NSP/XCI classified by title ID (…000 base,
    /// …800 update, anything above base+0x1000 add-on content), plus prod.keys.
    /// Subfolders are scanned too — a dump usually arrives as 本体/ 更新/ DLC/ folders —
    /// pruning the build folders this pipeline itself writes so a rescan is not slow.
    func scan(folder: String) {
        gameDir = folder
        let found = Self.classify(Self.inputFiles(in: folder))
        updateSlot("base") { $0.paths = found.base.map { [$0] } ?? []; $0.problem = found.base == nil ? "data.noBase" : "" }
        updateSlot("update") { $0.paths = found.update.map { [$0] } ?? []; $0.problem = "" }
        updateSlot("dlc") { $0.paths = found.dlc; $0.problem = "" }
        updateSlot("keys") { $0.paths = found.keys.map { [$0] } ?? []; $0.problem = "" }
        if !found.anyGame {
            updateSlot("base") { $0.problem = "data.noNsp" }
        }
    }

    /// What a set of files holds for the four slots (`classify`).
    struct FoundInputs: Equatable {
        var base: String?
        var update: String?
        var dlc: [String] = []
        var keys: String?
        var anyGame: Bool { base != nil || update != nil || !dlc.isEmpty }
    }

    /// The files under a folder, pruning the build folders this pipeline itself writes so a rescan is not slow.
    nonisolated static func inputFiles(in folder: String) -> [String] {
        let fm = FileManager.default
        var files: [String] = []
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
            files.append(path)
        }
        return files
    }

    /// NSP/XCI (and their compressed NSZ/XCZ) sorted by the title ID in the file name, plus the first prod.keys.
    /// Shared by Choose game folder and files dropped on the Builds page.
    nonisolated static func classify(_ files: [String]) -> FoundInputs {
        var base: [(String, Int)] = [], update: [(String, Int, Int)] = [], dlc: [String] = []
        var found = FoundInputs()
        for path in files {
            let name = (path as NSString).lastPathComponent
            let low = name.lowercased()
            if name.hasPrefix("._") { continue }   // an AppleDouble file macOS writes beside every real file on exFAT/FAT drives: its name carries the same [title ID], so counting it made one update read as two
            if found.keys == nil && (low == "prod.keys" || low.hasSuffix(".keys")) { found.keys = path; continue }
            guard ["nsp", "xci", "nsz", "xcz"].contains((low as NSString).pathExtension) else { continue }
            let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int ?? 0
            guard size > 0 else { continue }   // an incomplete download leaves 0-byte files behind
            guard let tid = titleID(name) else { continue }   // a name without [title ID] cannot be classified
            switch tid & 0xFFF {
            case 0: base.append((path, size))
            case 0x800: update.append((path, size, updateVersion(name)))
            default: dlc.append(path)
            }
        }
        // several bases happen when a folder holds a repack beside the original: the largest wins
        found.base = base.sorted { $0.1 > $1.1 }.first?.0
        // several updates: the newest [vN] is the one a profile would pack
        found.update = update.sorted { $0.2 > $1.2 }.first?.0
        found.dlc = dlc.sorted()
        return found
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
        installedOn = ""; installedAppPath = ""; bundleID = ""
        guard repoOK else {
            fail(repoPath.isEmpty ? t("msg.repoInvalidEmpty") : String(format: t("msg.repoInvalid"), shortPath(repoPath)))
            return
        }
        // Resolve the interpreter here if the dependency check has not landed yet. checkDeps()
        // runs on a background queue and startBuild() can beat it — for a moment pythonPath is
        // empty, and the old fallback was Apple's /usr/bin/python3 (3.9), which the script then
        // rejected with "require Python 3.12 or newer" whatever the machine actually had (#53).
        let py = pythonPath.isEmpty ? Self.findPython().path : pythonPath
        // The tools this app runs, before a build that takes an hour finds one missing at its last step (#87)
        let missing = Self.missingTools(in: repoPath)
        if !missing.isEmpty {
            fail(String(format: t("msg.toolsOld"), missing.joined(separator: ", ")))
            return
        }

        // One folder when everything lives together; otherwise a staging folder of symlinks. A folder
        // that holds other games too (a ROMs folder with one file per game) is staged as well: the
        // script takes one game per folder and refuses one with several ("more than one game in the
        // folder"), even when only the base game was picked (issue #58; ufooer's PR #31).
        let baseDir = (basePath as NSString).deletingLastPathComponent
        let allPaths = [basePath, updatePath] + dlcPaths
        let dirs = Set(allPaths.filter { !$0.isEmpty }.map { ($0 as NSString).deletingLastPathComponent })
        let picked = Set(allPaths.filter { !$0.isEmpty }.map { ($0 as NSString).lastPathComponent })
        let unpicked = ((try? FileManager.default.contentsOfDirectory(atPath: baseDir)) ?? []).filter {
            ["nsp", "xci", "nsz", "xcz"].contains(($0 as NSString).pathExtension.lowercased()) && !picked.contains($0)
        }
        // Staged, the folder's own update and add-on content would be left behind, where the script
        // used to find them unpicked: bring along those whose file name carries this game's title ID
        // exactly as build_ipa_from_nsp.py:445 reads it: the low 12 bits are 0x000 for a base game,
        // 0x800 for its update, and anything else is add-on content below the base.
        var staged = allPaths
        if let base = Self.titleID((basePath as NSString).lastPathComponent) {
            let app = base & ~0xFFF
            for f in unpicked {
                guard let tid = Self.titleID(f) else { continue }
                let low = tid & 0xFFF
                let owner = low == 0 ? tid : (low == 0x800 ? tid & ~0xFFF : (tid & ~0xFFF) - 0x1000)
                guard owner == app else { continue }
                if low == 0x800 && !updatePath.isEmpty { continue }   // the update was picked already
                if low != 0 && low != 0x800 && tid <= app { continue }   // add-on content sits above its base
                staged.append(baseDir + "/" + f)
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
            if !unpicked.isEmpty {
                say(String(format: t("msg.stagedFromSharedFolder"), (basePath as NSString).lastPathComponent))
            }
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
                                     env: ["PATH": Self.toolPath(python: py),
                                           "HOME": NSHomeDirectory()].merging(BundledTools.environment(for: py)) { $1 }) { line in
                DispatchQueue.main.async { self.append(line + "\n") }
            }
            if !r {
                fail(String(format: t("msg.nszFailed"), py))
                return
            }
        }
        var args = [repoPath + "/" + Self.buildScript, inputDir, "-k", keysPath,
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
        } else if installsDirectly {
            // The game's Xcode project instead of an IPA, signed for the device after the script (signAndInstall)
            args += ["--prepare-xcode", "--keep-extracted", "--team-id", signingTeam]
        } else if !outDir.isEmpty {
            ipaPath = outDir + "/" + tidHex + ".ipa"
            args += ["-o", ipaPath]
        }
        // The archive step packs whatever folder the build reported; without --work-dir that is the
        // script's default, which is the same workDir unless a separate output folder was chosen.
        effectiveWorkDir = hasWorkDir ? workDir : (inputDir as NSString).appendingPathComponent(tidHex + "_build")
        say(String(format: t("msg.running"), py) + " " + args.joined(separator: " "))
        lastBuildCommand = [py] + args

        let p = Process()
        p.executableURL = URL(fileURLWithPath: py)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: repoPath)
        // The root of the runtime the apphost looks for: derived from the detected installation,
        // not assumed to be ~/.dotnet (Homebrew keeps it in …/opt/dotnet/libexec). Only set when the
        // derivation actually answered — a wrong root is worse than none, and the pipeline derives
        // and verifies its own (DOTNET_ROOT, build_ipa_from_nsp.py) when this is absent.
        // TMPDIR as well: .NET 10 on macOS keeps the named mutex its first-run configure takes
        // (NuGet-Migrations) under $TMPDIR/.dotnet/shm, and with no TMPDIR it stats "" and dies with
        // 'NuGet-Migrations' + lstat("") == ENOENT before any project is read. NSTemporaryDirectory()
        // is the per-user temp folder whether or not the app's own environment carries one.
        var denv: [String: String] = ["PATH": Self.toolPath("/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", python: py),
                                      "USER": NSUserName(), "HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8",
                                      "TMPDIR": NSTemporaryDirectory()]
        if let droot = Self.dotnetRoot(for: dotnetPath.isEmpty ? "dotnet" : dotnetPath) {
            denv["DOTNET_ROOT"] = droot   // both variables carry the same root, as the apphost checks the arch-specific one first
            denv["DOTNET_ROOT_ARM64"] = droot
        }
        // The bundled Python lives inside the signed app: a .pyc written there would change what the signature seals
        // (the packages are compiled at bundle time), and a user site must not shadow its pinned packages.
        denv.merge(BundledTools.environment(for: py)) { $1 }
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
                        // The .app is self-contained (its RomFS is inside), and the marker file
                        // beside it (.nx2apple-library, a dot file the Finder hides) tells the
                        // game's launcher that this folder is a library: its saves and log live
                        // here, and they follow the folder if it moves. No image copy — the .app
                        // already carries one, and a second multi-GB file was pure duplication.
                        let made = !self.macAppPath.isEmpty &&
                                   FileManager.default.fileExists(atPath: self.macAppPath)
                        self.done = made
                        self.doneNote = self.t(made ? "msg.macAppDone" : "msg.macAppMissing")
                        if made {
                            try? Data().write(to: URL(fileURLWithPath:
                                (self.macAppPath as NSString).deletingLastPathComponent +
                                "/.nx2apple-library"))
                        }
                        self.running = false
                        self.cleanupStaging()
                    } else if self.installsDirectly {
                        // The same archive as for sideloading, then the app without the game files, then the archive into its Documents
                        self.packArchive(workDir: self.effectiveWorkDir) { self.signAndInstall(archive: $0) }
                    } else {
                        self.packArchive(workDir: self.effectiveWorkDir)   // keeps running=true until the archive is done
                    }
                } else {
                    if let i = self.stages.lastIndex(where: { $0.state == .running }) {
                        self.stages[i].state = .failed
                        self.stages[i].detail = String(format: self.t("msg.exitCode"), status.terminationStatus)
                    } else {
                        // The last real line says more than the exit code alone, and the message
                        // points at the log: "Build failed (exit code 1)" with nothing else sent a
                        // reporter looking for a log that a short window had below the fold (#52)
                        self.doneNote = String(format: self.t("msg.buildFailed"), status.terminationStatus)
                        if let last = Self.lastMeaningfulLine(self.logTail) {
                            self.doneNote = String(format: self.t("msg.buildFailedReason"), last)
                        }
                    }
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
    /// The newest version folder the extraction wrote, or nil when it wrote none.
    ///
    /// Either shape counts: RomFS/ from the older tools, RomFS.img from the current ones (the
    /// rewriter packs the game files itself — build_ipa_from_nsp.py:876 tests for the image).
    /// Looking only for the folder made every 0.4.8 build report "archive skipped" after a
    /// successful extraction (issue #73).
    nonisolated static func extractedVersion(in extract: String) -> String? {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: extract)) ?? [])
            .filter { $0.hasPrefix("v") && (fm.fileExists(atPath: extract + "/" + $0 + "/RomFS") ||
                                            fm.fileExists(atPath: extract + "/" + $0 + "/RomFS.img")) }
            .sorted { (Int($0.dropFirst()) ?? 0) < (Int($1.dropFirst()) ?? 0) }
            .last
    }

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

    /// The last line of the log that says something: not blank, not a progress event. Used for the
    /// failure note, where the exit code on its own is not actionable (issue #52).
    static func lastMeaningfulLine(_ log: String) -> String? {
        for line in log.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            let s = line.trimmingCharacters(in: .whitespaces)
            if s.isEmpty || s.hasPrefix("{") { continue }   // a --progress json event
            return String(s.prefix(200))
        }
        return nil
    }

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
        noteBundleID(line)
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

    /// The script's "app name: …; version: …; bundle ID: org.nxnative.…" line: the app to open on the device.
    private func noteBundleID(_ text: String) {
        guard let range = text.range(of: #"bundle ID: [A-Za-z0-9.\-]+"#, options: .regularExpression) else { return }
        bundleID = String(text[range].dropFirst("bundle ID: ".count))
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
            noteBundleID(msg)
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
    /// `then` continues the build with the archive's folder (installing on a device) instead of ending it.
    private func packArchive(workDir: String, then: ((String) -> Void)? = nil) {
        running = true
        let fm = FileManager.default
        let extract = workDir + "/extract"
        // The extraction writes either a RomFS folder (older tools) or RomFS.img, one image file
        // (the rewriter packs it now: build_ipa_from_nsp.py:876 tests for exactly that). Looking
        // only for the folder made every 0.4.8 build end with "archive skipped" on a machine where
        // the extraction had in fact succeeded (issue #73). extractedVersion is the one authority:
        // an inline copy of its predicate here drifted back to folder-only during a merge, and the
        // archive skipped again while the test — which drives the function — stayed green.
        guard let v = Self.extractedVersion(in: extract) else {
            stages.append(Stage(id: 1000, name: t("prog.archiveShort"), state: .failed, detail: t("prog.noRomfs")))
            doneNote = String(format: t("msg.archiveSkipped"), extract)
            running = false; cleanupStaging(); return
        }
        let romfs = extract + "/" + v + "/RomFS"
        let romfsImage = extract + "/" + v + "/RomFS.img"
        // The output is Documents/games/<title ID>/romfs — the per-game layout the iOS app looks for
        // first. Copying the whole `games` folder onto the phone (or into a folder the Files app
        // exposes on an external drive) then needs no renaming, and several games' folders can sit
        // side by side in one app.
        let gamesRoot = (outDir.isEmpty ? (basePath as NSString).deletingLastPathComponent : outDir) + "/games"
        let tid = Self.titleID(basePath).map { String(format: "%016llX", $0) } ?? "game"
        // games/<id>/ holds romfs.img and aoc/ side by side: main.m's per-game lookup takes the
        // image, and the host mounts DLC from aoc/<index>.img (hle_fs.c aoc_dir). One folder, which
        // the user copies to the phone or keeps on an external drive as a whole.
        let gameDir = gamesRoot + "/" + tid
        let dest = gameDir
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
            if let then { return then(dest) }
            cleanupStaging()
            finishBuild(ok: true, note: t("msg.done"))
            return
        }
        // One romfs.img instead of a ROMFSARC shard set: upstream reads the image directly
        // (hle_fs.c), one file copies to a phone at full speed where 300,000 did not, and it fits
        // an external drive. A shard set from an earlier build of this game is removed first —
        // main.m takes Documents/games/<id>/romfs.img before romfs/, so a stale archive would sit
        // there confusingly.
        for old in ((try? fm.contentsOfDirectory(atPath: dest)) ?? [])
        where old == "romfs.img" || old == "romfs.idx" || (old.hasPrefix("romfs.") && old.dropFirst(6).allSatisfy(\.isNumber)) {
            try? fm.removeItem(atPath: dest + "/" + old)
        }
        let idx = 1000
        stages.append(Stage(id: idx, name: t("prog.archive"), state: .running, detail: v))
        say(String(format: t("msg.archiveLog"), romfs, dest))

        // The extraction may already have packed the image (RomFS.img beside the code modules): then
        // this is a copy, not a pack. Packing it again from a folder that no longer exists was the
        // other half of issue #73.
        if fm.fileExists(atPath: romfsImage) {
            let to = dest + "/romfs.img"
            // Reuse by the image's own identity: copying a multi-GB file on every build of an
            // unchanged game is the cost this avoids. Size and modification date are enough — the
            // extraction rewrites the file whenever the game's data changes.
            if let src = try? fm.attributesOfItem(atPath: romfsImage),
               let have = try? fm.attributesOfItem(atPath: to),
               let a = src[.size] as? Int64, let b = have[.size] as? Int64, a == b,
               let da = src[.modificationDate] as? Date, let db = have[.modificationDate] as? Date,
               abs(da.timeIntervalSince(db)) < 1 {
                stages.append(Stage(id: idx, name: t("prog.archive"), state: .done,
                                    detail: String(format: t("prog.archiveReused"), 1)))
                say(String(format: t("msg.archiveReused"), dest))
                archivePath = dest
                if let then { return then(dest) }
                cleanupStaging()
                finishBuild(ok: true, note: t("msg.done"))
                return
            }
            try? fm.removeItem(atPath: to)
            do {
                try fm.copyItem(atPath: romfsImage, toPath: to)
                // The running stage is updated in place: there is no process here whose progress
                // events would move it, and appending a second stage of the same name read as a
                // duplicate in the stage list.
                if let i = stages.firstIndex(where: { $0.id == idx }) {
                    stages[i].state = .done; stages[i].detail = v
                }
                say(String(format: t("msg.archiveLog"), romfsImage, dest))
                archivePath = dest
                if let then { return then(dest) }
                cleanupStaging()
                finishBuild(ok: true, note: t("msg.done"))
            } catch {
                if let i = stages.firstIndex(where: { $0.id == idx }) {
                    stages[i].state = .failed; stages[i].detail = error.localizedDescription
                }
                doneNote = String(format: t("msg.archiveFailed"), 1)
                running = false; cleanupStaging()
            }
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: pythonPath.isEmpty ? "/usr/bin/python3" : pythonPath)
        // dest/romfs.img: one file, which main.m's per-game lookup takes before any folder.
        p.arguments = [repoPath + "/" + Self.romfsImageTool, "--reuse", romfs, dest + "/romfs.img"]
        let romfsPy = p.executableURL!.path
        p.environment = ["PATH": Self.toolPath("/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin", python: romfsPy), "PYTHONPATH": repoPath + "/dm/tools"]
            .merging(BundledTools.environment(for: romfsPy)) { $1 }
        Self.inOwnGroup(p, python: p.executableURL!.path)
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.append(s) }
        }
        p.terminationHandler = { [weak self] st in Self.untrack(st); DispatchQueue.main.async {
            guard let self else { return }
            let cancelled = self.stopping
            let succeeded = st.terminationStatus == 0 && !cancelled
            self.stopping = false
            if succeeded {
                self.archivePath = dest
                Self.writeStamp(source: romfs, version: v, to: dest + "/.packstamp")
                // The DLC images ride along: with the slim default the build script leaves them in
                // the work folder instead of packing them into the IPA, and the host mounts them
                // from DM_AOC_DIR/<index>.img — so they belong in this game's folder.
                let aocSrc = workDir + "/aoc"
                let aocDst = dest + "/aoc"
                if fm.fileExists(atPath: aocSrc) {
                    try? fm.removeItem(atPath: aocDst)
                    try? fm.copyItem(atPath: aocSrc, toPath: aocDst)
                    let n = ((try? fm.contentsOfDirectory(atPath: aocDst)) ?? []).count
                    if n > 0 { self.say(String(format: self.t("msg.aocCopied"), n)) }
                }
            }
            if let i = self.stages.firstIndex(where: { $0.id == idx }) {
                self.stages[i].state = succeeded ? .done : .failed
                self.stages[i].detail = succeeded
                    ? String(format: self.t("prog.archiveDone"), dest)
                    : String(format: self.t("msg.archiveFailed"), st.terminationStatus)
            }
            if succeeded, let then { return then(dest) }
            self.cleanupStaging()
            self.running = false
            self.done = succeeded
            if cancelled { self.resetProgress() }
            self.doneNote = cancelled ? self.t("msg.stopped") : (succeeded ? self.t("msg.done") : self.t("msg.archiveIpaOnly"))
        }}
        proc = p
        do { try p.run(); Self.track(p) } catch {
            if let i = stages.firstIndex(where: { $0.id == idx }) {
                stages[i].state = .failed; stages[i].detail = t("msg.archiveNoStart")
            }
            running = false; doneNote = t("msg.archiveIpaOnly"); cleanupStaging()
        }
    }

    // MARK: Installing on a device

    /// After the script prepared the Xcode project and the game data is packed: sign the app for the device without the
    /// game files (DM_COPY_ROMFS=NO), install it, then copy the game's folder (romfs.img, aoc/) into its
    /// Documents/games/<title ID>/, where the app looks first (main.m), as a sideloaded copy has it. devicectl skips files
    /// that did not change, so a reinstall sends the code and shaders, not the game again.
    /// Install the app xcodebuild produced, then copy the game data into it. Shared by the plain
    /// sign flow and the team-variant retry.
    private func installBuiltApp(app: String, archive: String, device: String, xcrun: String) {
        let name = deviceName(device)
        guard FileManager.default.fileExists(atPath: app) else { return finishInstall(String(format: t("dev.noProject"), shortPath(app))) }
        runTool(id: 1002, name: String(format: t("dev.installStage"), name),
                [xcrun, "devicectl", "device", "install", "app", "--device", device, app], step: Self.installStep) { error in
            if let error { return self.finishInstall(String(format: self.t("dev.installFailed"), error)) }
            guard let bundle = NSDictionary(contentsOfFile: app + "/Info.plist")?["CFBundleIdentifier"] as? String else {
                return self.finishInstall(String(format: self.t("dev.noProject"), self.shortPath(app + "/Info.plist")))
            }
            let tid = Self.titleID(self.basePath).map { String(format: "%016llX", $0) } ?? "game"
            // Copying the game files over USB is the slowest part of an install and the player may
            // rather hand the data to the device themselves (a fast external drive in Files), so it
            // is their call. Without game files there is nothing to ask about.
            let copy = {
                self.runTool(id: 1003, name: String(format: self.t("dev.copyStage"), name),
                             Self.archiveCopy(xcrun: xcrun, device: device, bundle: bundle, archive: archive, titleID: tid), step: Self.installStep) { error in
                    if let error { return self.finishInstall(String(format: self.t("dev.copyFailed"), error)) }
                    self.installedOn = device
                    self.installedAppPath = app
                    self.finishInstall(nil)
                }
            }
            guard FileManager.default.fileExists(atPath: archive + "/romfs.img") else { return copy() }
            self.askTransfer { ok in
                guard ok else {
                    self.installedOn = device
                    self.installedAppPath = app
                    self.running = false
                    self.done = true
                    self.doneNote = String(format: self.t("dev.copySkipped"), name)
                    self.cleanupStaging()
                    return
                }
                copy()
            }
        }
    }

    private func signAndInstall(archive: String) {
        let work = effectiveWorkDir, project = work + "/xcode/DmIOS.xcodeproj", derived = work + "/xcode-derived-data"
        let device = installDevice, team = signingTeam, name = deviceName(device), xcrun = xcrunPath
        guard FileManager.default.fileExists(atPath: project) else { return finishInstall(String(format: t("dev.noProject"), shortPath(project))) }
        DispatchQueue.global(qos: .userInitiated).async {
            let scheme = Self.scheme(of: project, xcrun: xcrun)
            DispatchQueue.main.async {
                guard let scheme else { return self.finishInstall(String(format: self.t("dev.noProject"), self.shortPath(project))) }
                // The app's own bundle ID can be taken: App IDs are global and register to the first
                // team that uses one, so a game built before with another Apple ID fails here for
                // ever after. The retry appends this team to the identifier — a stable per-team
                // variant — as a command-line setting, which overrides the project's.
                func sign(_ extra: [String] = []) -> [String] {
                    [xcrun, "xcodebuild", "-project", project, "-scheme", scheme, "-configuration", "Release",
                     "-destination", "id=\(device)", "-derivedDataPath", derived, "-allowProvisioningUpdates",
                     "DEVELOPMENT_TEAM=\(team)", "DM_COPY_ROMFS=NO"] + extra + ["build"]
                }
                let appID = "org.nxnative." + (Self.titleID(self.basePath).map { String(format: "%016llX", $0) } ?? "game").lowercased()
                let teamVariant = "org.nxnative." + appID.split(separator: ".").last!.appending(".\(team)")
                func taken(_ e: String?) -> Bool {
                    guard let e else { return false }
                    return e.contains("cannot be registered to your development team") || e.contains("No profiles for 'org.nxnative.")
                }
                self.runTool(id: 1001, name: String(format: self.t("dev.signStage"), name), sign(), step: Self.xcodeStep) { firstError in
                    if let firstError, taken(firstError) {
                        // Once more under this team's own identifier, and the log says why the first try failed.
                        fputs("signing: " + appID + " is registered to another team; retrying as " + teamVariant + "\n", stderr)
                        self.runTool(id: 1001, name: String(format: self.t("dev.signStage"), name), sign(["PRODUCT_BUNDLE_IDENTIFIER=" + teamVariant]), step: Self.xcodeStep) { retryError in
                            if let retryError, !retryError.isEmpty {
                                self.finishInstall(String(format: self.t("dev.signFailed"), retryError))
                            } else {
                                self.installBuiltApp(app: derived + "/Build/Products/Release-iphoneos/DmIOS.app", archive: archive, device: device, xcrun: xcrun)
                            }
                        }
                        return
                    }
                    if let firstError, !firstError.isEmpty {
                        self.finishInstall(String(format: self.t("dev.signFailed"), firstError))
                    } else {
                        self.installBuiltApp(app: derived + "/Build/Products/Release-iphoneos/DmIOS.app", archive: archive, device: device, xcrun: xcrun)
                    }
                }
            }
        }
    }

    private func finishInstall(_ failure: String?, note: String? = nil) {
        running = false
        done = failure == nil
        doneNote = failure ?? note ?? String(format: t("dev.installed"), deviceName(installDevice))
        cleanupStaging()
    }

    /// Reinstall the signed app that is already in derived data, without unpacking, signing or packing again: the
    /// device keeps the app's Documents (game data and saves), as the bundle ID does not change. A reinstall that
    /// fails on an expired signature says so in devicectl's words; signing again is not this button's job.
    func reinstallOnDevice(then: (() -> Void)? = nil) {
        let device = installedOn, app = installedAppPath
        guard !device.isEmpty, !app.isEmpty else { then?(); return }
        guard FileManager.default.fileExists(atPath: app) else {
            doneNote = String(format: t("dev.reinstallMissing"), shortPath(app))
            then?(); return
        }
        running = true
        runTool(id: 1004, name: String(format: t("dev.reinstallStage"), deviceName(device)),
                Self.reinstallCommand(xcrun: xcrunPath, device: device, app: app), step: Self.installStep) { error in
            if let error {
                // The app is still on the device: a failed reinstall is a note, not a failed build
                self.running = false
                self.doneNote = String(format: self.t("dev.reinstallFailed"), error)
            } else {
                self.finishInstall(nil, note: String(format: self.t("dev.reinstalled"), self.deviceName(device)))
            }
            then?()
        }
    }

    nonisolated static func reinstallCommand(xcrun: String, device: String, app: String) -> [String] {
        [xcrun, "devicectl", "device", "install", "app", "--device", device, app]
    }

    /// Renew an installed app's signature (a free Apple ID's profile lasts 7 days). The same xcodebuild parameters as
    /// the install, run on the cached project and derived data: Xcode reuses the compiled products and only signs
    /// again, then devicectl installs the app over itself. PRODUCT_BUNDLE_IDENTIFIER is the installed app's own, so the
    /// device keeps that app's Documents (game data, saves); a retry under another identifier would lose them.
    func resignOnDevice(app: String, device: String, then: (() -> Void)? = nil) {
        guard !device.isEmpty, !app.isEmpty else { then?(); return }
        guard !signingTeam.isEmpty else {
            doneNote = t("dev.resignNoTeam")
            then?(); return
        }
        guard let bundle = NSDictionary(contentsOfFile: app + "/Info.plist")?["CFBundleIdentifier"] as? String else {
            doneNote = String(format: t("dev.noProject"), shortPath(app + "/Info.plist"))
            then?(); return
        }
        guard let paths = Self.buildPaths(ofApp: app), FileManager.default.fileExists(atPath: paths.project) else {
            doneNote = String(format: t("dev.resignNoProject"), shortPath(Self.buildPaths(ofApp: app)?.project ?? app))
            then?(); return
        }
        let xcrun = xcrunPath, team = signingTeam, name = deviceName(device)
        DispatchQueue.global(qos: .userInitiated).async {
            let scheme = Self.scheme(of: paths.project, xcrun: xcrun)
            DispatchQueue.main.async {
                guard let scheme else {
                    self.doneNote = String(format: self.t("dev.noProject"), self.shortPath(paths.project))
                    then?(); return
                }
                self.running = true
                self.runTool(id: 1006, name: String(format: self.t("dev.resignStage"), name),
                             Self.resignCommand(xcrun: xcrun, project: paths.project, scheme: scheme, device: device,
                                                derived: paths.derived, team: team, bundle: bundle), step: Self.xcodeStep) { error in
                    if let error, !error.isEmpty {
                        self.running = false
                        self.doneNote = String(format: self.t("dev.resignFailed"), error)
                        then?(); return
                    }
                    self.runTool(id: 1007, name: String(format: self.t("dev.installStage"), name),
                                 Self.reinstallCommand(xcrun: xcrun, device: device, app: app), step: Self.installStep) { installError in
                        self.running = false
                        if let installError {
                            self.doneNote = String(format: self.t("dev.installFailed"), installError)
                        } else {
                            self.installedOn = device
                            self.installedAppPath = app
                            self.doneNote = String(format: self.t("dev.resigned"), name)
                        }
                        then?()
                    }
                }
            }
        }
    }

    /// The xcodebuild parameters of a re-sign: signAndInstall's, plus the installed app's own identifier. The same
    /// derived data is what keeps Xcode from rebuilding the game's code.
    nonisolated static func resignCommand(xcrun: String, project: String, scheme: String, device: String, derived: String,
                                          team: String, bundle: String) -> [String] {
        [xcrun, "xcodebuild", "-project", project, "-scheme", scheme, "-configuration", "Release",
         "-destination", "id=\(device)", "-derivedDataPath", derived, "-allowProvisioningUpdates",
         "DEVELOPMENT_TEAM=\(team)", "DM_COPY_ROMFS=NO", "PRODUCT_BUNDLE_IDENTIFIER=\(bundle)", "build"]
    }

    /// The cached project and derived data an installed app came from, from the app's own path
    /// (<work>/xcode-derived-data/Build/Products/Release-iphoneos/DmIOS.app): a re-sign must run there to reuse them.
    nonisolated static func buildPaths(ofApp app: String) -> (project: String, derived: String)? {
        guard let marker = app.range(of: "/Build/Products/") else { return nil }
        let derived = String(app[..<marker.lowerBound])
        let work = (derived as NSString).deletingLastPathComponent
        return (work + "/xcode/DmIOS.xcodeproj", derived)
    }

    /// Ask where to write the .ipa, then pack the signed app there.
    func saveIPAPanel() {
        let p = NSSavePanel()
        p.title = t("dev.saveIPATitle")
        p.allowedFileTypes = ["ipa"]
        p.nameFieldStringValue = defaultIPAName()
        p.canCreateDirectories = true
        guard p.runModal() == .OK, let url = p.url else { return }
        saveIPA(to: url)
    }

    /// The signed app as an .ipa (Payload/<name>.app, the layout iOS and the sideloaders install): useful while the
    /// signature lasts, and the thing to re-sign when it expires. The game data is not in it — it stays in the app's
    /// Documents (romfs.img), as a normal iOS build has it.
    func saveIPA(to url: URL, then: (() -> Void)? = nil) {
        let app = installedAppPath, fm = FileManager.default
        guard !app.isEmpty, fm.fileExists(atPath: app) else {
            doneNote = String(format: t("dev.saveNeedsApp"), shortPath(app))
            then?(); return
        }
        let stage = fm.temporaryDirectory.appendingPathComponent("nspb-ipa-" + UUID().uuidString)
        let payload = stage.appendingPathComponent("Payload")
        do {
            try fm.createDirectory(at: payload, withIntermediateDirectories: true)
            try fm.copyItem(atPath: app, toPath: payload.appendingPathComponent((app as NSString).lastPathComponent).path)
        } catch {
            try? fm.removeItem(at: stage)
            doneNote = String(format: t("dev.saveFailed"), error.localizedDescription)
            then?(); return
        }
        running = true
        runTool(id: 1005, name: t("dev.saveStage"), Self.ipaCommand(payload: payload.path, ipa: url.path), step: { _ in nil }) { error in
            try? fm.removeItem(at: stage)
            self.running = false
            self.doneNote = error.map { String(format: self.t("dev.saveFailed"), $0) }
                ?? String(format: self.t("dev.savedIPA"), self.shortPath(url.path))
            then?()
        }
    }

    /// ditto writes the archive the way Finder's "compress" does; the IPA's root must be Payload/, and --norsrc keeps
    /// __MACOSX out (the signature itself lives in _CodeSignature inside the app).
    nonisolated static func ipaCommand(payload: String, ipa: String) -> [String] {
        ["/usr/bin/ditto", "-c", "-k", "--norsrc", "--keepParent", payload, ipa]
    }

    /// The name the save panel offers: the app's display name, so two games' IPAs do not collide. A slash or colon in a
    /// game's name would split the file name or show as a folder in Finder.
    func defaultIPAName() -> String {
        let plist = NSDictionary(contentsOfFile: installedAppPath + "/Info.plist")
        let name = (plist?["CFBundleDisplayName"] as? String) ?? (plist?["CFBundleExecutable"] as? String) ?? "DmIOS"
        return name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_") + ".ipa"
    }

    /// The game's folder (romfs.img, aoc/) into the installed app's Documents, where main.m looks for this game's files first.
    nonisolated static func archiveCopy(xcrun: String, device: String, bundle: String, archive: String, titleID: String) -> [String] {
        [xcrun, "devicectl", "device", "copy", "to", "--device", device, "--source", archive,
         "--destination", "Documents/games/\(titleID)", "--domain-type", "appDataContainer", "--domain-identifier", bundle]
    }

    /// The scheme the script made for the game ("<name> (<profile>)"), from `xcodebuild -list`.
    nonisolated static func scheme(of project: String, xcrun: String) -> String? {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: xcrun)
        p.arguments = ["xcodebuild", "-list", "-json", "-project", project]
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let start = data.firstIndex(of: UInt8(ascii: "{")) ?? data.startIndex   // xcodebuild may print a line before the JSON
        guard let root = try? JSONSerialization.jsonObject(with: data[start...]) as? [String: Any],
              let schemes = (root["project"] as? [String: Any])?["schemes"] as? [String] else { return nil }
        return schemes.first { $0 != "DmIOS" } ?? schemes.first
    }

    /// What xcodebuild is doing, from the actions it prints.
    nonisolated static func xcodeStep(_ line: String) -> (detail: String, percent: Double?)? {
        let actions = [("CompileC ", "compiling"), ("SwiftCompile ", "compiling"), ("Ld ", "linking"),
                       ("PhaseScriptExecution ", "copying resources"), ("CodeSign ", "signing"), ("ProcessProductPackaging ", "provisioning")]
        return actions.first { line.hasPrefix($0.0) }.map { ($0.1, nil) }
    }

    /// devicectl's install progress ("… 45%").
    nonisolated static func installStep(_ line: String) -> (detail: String, percent: Double?)? {
        guard let range = line.range(of: #"(\d{1,3})%"#, options: .regularExpression), let n = Double(line[range].dropLast()) else { return nil }
        return ("installing", min(n, 100))
    }

    /// One of Xcode's tools as a stage of the build: in its own process group (Stop ends it), its output in the log,
    /// its progress in the stage. `then` gets nil on success, else the last error line.
    private func runTool(id: Int, name: String, _ command: [String], step: @escaping (String) -> (detail: String, percent: Double?)?,
                         then: @escaping (String?) -> Void) {
        // A stage that runs again (the team-variant signing retry uses the same id) keeps its row:
        // a second row with that id would never see an update again — every lookup takes the first
        // match — and would spin for ever after the build moved on.
        if let i = stages.firstIndex(where: { $0.id == id }) {
            stages[i] = Stage(id: id, name: name, state: .running, started: Date())
        } else {
            stages.append(Stage(id: id, name: name, state: .running, started: Date()))
        }
        append("[\(name)] \(command.joined(separator: " "))\n")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: command[0])
        p.arguments = Array(command.dropFirst())
        p.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "USER": NSUserName(), "LANG": "en_US.UTF-8"]
        Self.inOwnGroup(p, python: pythonPath.isEmpty ? "/usr/bin/python3" : pythonPath)
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        var buffer = "", lastError = ""
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let chunk = String(data: d, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                buffer += chunk
                while let nl = buffer.firstIndex(of: "\n") {
                    let line = String(buffer[..<nl]); buffer = String(buffer[buffer.index(after: nl)...])
                    self.append(line + "\n")
                    if line.contains("error:") || line.hasPrefix("ERROR:") { lastError = line.trimmingCharacters(in: .whitespaces) }
                    if let s = step(line), let i = self.stages.firstIndex(where: { $0.id == id }) {
                        self.stages[i].detail = s.detail
                        if let percent = s.percent { self.stages[i].percent = percent }
                    }
                }
            }
        }
        p.terminationHandler = { [weak self] status in
            Self.untrack(status)
            DispatchQueue.main.async {
                guard let self else { return }
                pipe.fileHandleForReading.readabilityHandler = nil
                if self.stopping {
                    self.stopping = false; self.running = false
                    self.resetProgress(); self.doneNote = self.t("msg.stopped"); self.cleanupStaging()
                    return
                }
                let ok = status.terminationStatus == 0
                if let i = self.stages.firstIndex(where: { $0.id == id }) {
                    self.stages[i].state = ok ? .done : .failed
                    if ok { self.stages[i].percent = 100; self.stages[i].detail = "" }
                }
                then(ok ? nil : (lastError.isEmpty ? String(format: self.t("msg.exitCode"), status.terminationStatus) : lastError))
            }
        }
        proc = p
        do { try p.run(); Self.track(p) } catch { then(error.localizedDescription) }
    }

    /// Start the game on the device it was installed on.
    func openOnDevice(udid: String, app: String, completion: @escaping (String?) -> Void) {
        let info = NSDictionary(contentsOfFile: app + "/Info.plist")
        guard let bundle = info?["CFBundleIdentifier"] as? String else { return completion(String(format: t("dev.noProject"), shortPath(app))) }
        let xcrun = xcrunPath
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process(), out = Pipe()
            p.executableURL = URL(fileURLWithPath: xcrun)
            p.arguments = ["devicectl", "device", "process", "launch", "--device", udid, bundle]
            p.standardOutput = out; p.standardError = out
            var message: String?
            do {
                try p.run()
                let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                p.waitUntilExit()
                if p.terminationStatus != 0 { message = text.split(separator: "\n").last(where: { $0.contains("rror") }).map(String.init) ?? text }
            } catch { message = error.localizedDescription }
            DispatchQueue.main.async { completion(message) }
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
        var lastError = ""   // the tool's own first error line after a failed install (brew's, pip's)
        var fixHint = ""     // an L10n key: what to type or click, chosen from that line
        var actionLabel = "" // an L10n key for the button when the action is not a plain install ("Fix")
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
    ///
    /// 3.12 is the script's own floor, not a guess: build_ipa_from_nsp.py:1911 raises "Direct
    /// RomFS image builds require Python 3.12 or newer". This said 3.9 — the comment above even
    /// said 3.12 — so findPython() was happy to return Apple's 3.9 and the build then died inside
    /// the script with a message the user could not act on (issue #53).
    nonisolated static let minPython = (3, 12)

    /// The Homebrew formulae the dependency check offers, with the localization key of each row. The repo-root
    /// Brewfile lists the same formulae (BrewfileTests keeps the two equal).
    /// `binary` is the file the formula puts in the Homebrew bin folder (glslang installs glslangValidator, which the
    /// NSP script's environment check requires).
    nonisolated static let brewDeps: [(formula: String, binary: String, key: String)] = [
        ("xcodegen", "xcodegen", "dep.xcodegen"),
        ("zstd", "zstd", "dep.zstd"),
        ("spirv-cross", "spirv-cross", "dep.spirv"),
        ("glslang", "glslangValidator", "dep.glslang"),
    ]

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

    nonisolated static func importsOK(_ py: String) -> Bool {
        runOK(py, ["-c", importProbe], env: ProcessInfo.processInfo.environment.merging(BundledTools.environment(for: py)) { $1 })
    }

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
            p.environment = ["PATH": toolPath(python: base), "HOME": NSHomeDirectory()].merging(BundledTools.environment(for: base)) { $1 }
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
        p.environment = ProcessInfo.processInfo.environment.merging(BundledTools.environment(for: path)) { $1 }
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

    /// Every python3 on this Mac, newest-looking first, each tried for a usable version and the
    /// packages. Returns the one to build with, plus why the others were rejected for the message.
    nonisolated static func findPython(resources: URL? = BundledTools.resources) -> (path: String, ok: Bool) {
        // The release app's own Python (BundledTools.swift) has every package and is the one the build is tested with: it wins over
        // any Python on this Mac and needs no venv. One that does not run (a damaged copy) falls through to the search below.
        if let bundled = BundledTools.python(in: resources), pythonVersion(bundled).map({ $0 >= minPython }) == true, importsOK(bundled) {
            return (bundled, true)
        }
        var cands: [String] = []
        let fw = "/Library/Frameworks/Python.framework/Versions"
        if let vers = try? FileManager.default.contentsOfDirectory(atPath: fw) {
            for v in vers.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
                cands.append(fw + "/" + v + "/bin/python3")
            }
        }
        cands += ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        // Homebrew's python@3.x is always python3.x, but the bare python3 link exists only for
        // the formula that is linked: a 3.12 beside an unlinked default would go unseen.
        for dir in ["/opt/homebrew/bin", "/usr/local/bin"] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            cands += names.filter { $0.range(of: #"^python3\.\d+$"#, options: .regularExpression) != nil }
                .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
                .map { dir + "/" + $0 }
        }
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
        var seen = Set<String>()
        var fallback: (String, (Int, Int))? = nil   // newest with an acceptable version but no packages
        for c in cands where !c.isEmpty && seen.insert(c).inserted {
            guard FileManager.default.isExecutableFile(atPath: c), let v = pythonVersion(c) else { continue }
            guard v >= minPython else { continue }
            if importsOK(c) { return (c, true) }
            if fallback == nil || v > fallback!.1 { fallback = (c, v) }
        }
        // No system interpreter has the packages: the venv (existing, or created by 安装) is next.
        let vpy = venvPython()
        if FileManager.default.isExecutableFile(atPath: vpy) {
            if importsOK(vpy) { return (vpy, true) }
            return (vpy, false)   // exists but incomplete: 安装 finishes it
        }
        return (fallback?.0 ?? vpy, false)
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
        p.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin", "TMPDIR": NSTemporaryDirectory()]
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
                                                      "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(),
                                                      "TMPDIR": NSTemporaryDirectory()])
            return (d, ok)
        }
        return ("dotnet", false)
    }

    /// Whether the selected developer directory exists (`xcode-select -p`), which is the same
    /// source of truth xcodebuild and xcrun use — so an Xcode beta, a custom location, or a
    /// Command Line Tools-only setup is reported for what it is instead of "no Xcode".
    nonisolated static func developerDir() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        p.arguments = ["-p"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let dir = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !dir.isEmpty else { return nil }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) && isDir.boolValue ? dir : nil
    }

    nonisolated static func developerDirExists() -> Bool { developerDir() != nil }

    /// An Xcode.app that is installed but not selected: an App Store download arrives as
    /// /Applications/Xcode.app and stays unused until someone opens it or points xcode-select at
    /// it, so `xcode-select -p` keeps saying CommandLineTools and xcodebuild fails later.
    nonisolated static func installedXcode() -> String? {
        for app in ["/Applications/Xcode.app", "/Applications/Xcode-beta.app"]
        where FileManager.default.isExecutableFile(atPath: app + "/Contents/Developer/usr/bin/xcodebuild") {
            return app
        }
        let apps = (try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? []
        for name in apps.sorted() where name.hasPrefix("Xcode") && name.hasSuffix(".app") {
            let app = "/Applications/" + name
            if FileManager.default.isExecutableFile(atPath: app + "/Contents/Developer/usr/bin/xcodebuild") { return app }
        }
        return nil
    }

    /// What the Xcode row is looking at: the selected developer directory, the Xcode that is only
    /// installed, and whether the iOS SDK answers. Pure, so the four cases are tested.
    enum XcodeState: Equatable {
        case ready
        case noIOSSDK(selected: String)              // Xcode selected, its iOS platform not downloaded
        case commandLineToolsOnly(xcode: String)     // Xcode.app installed, xcode-select still on the CLT
        case notInstalled
    }

    nonisolated static func xcodeState(selected: String?, xcodeApp: String?, iosSDK: Bool) -> XcodeState {
        if let selected, selected.contains(".app/Contents/Developer") {
            return iosSDK ? .ready : .noIOSSDK(selected: selected)
        }
        if let xcodeApp { return .commandLineToolsOnly(xcode: xcodeApp) }
        return iosSDK ? .ready : .notInstalled   // a CLT whose xcrun does answer the SDK is usable
    }

    /// The commands that fetch Xcode's two downloadable parts; the setup panel and the guided setup run the same ones.
    nonisolated static let metalToolchainCmd = ["/usr/bin/xcodebuild", "-downloadComponent", "MetalToolchain"]
    nonisolated static let iosPlatformCmd = ["/usr/bin/xcodebuild", "-downloadPlatform", "iOS"]

    /// Whether the xcode row asks for the iOS SDK. Always, as before, unless the guided setup stored a Mac-only choice
    /// and builds are for the Mac: upstream no longer needs the iOS SDK for a Mac build (c464cb24).
    nonisolated static func needsIOSPlatform(defaults: UserDefaults = .standard) -> Bool {
        if OnboardingDefaults.sessionPlatform == "mac" { return false }   // a forced run's choice, not stored yet
        guard defaults.string(forKey: OnboardingDefaults.platform) == "mac" else { return true }
        return (defaults.string(forKey: "buildTarget") ?? "ios") != "mac-app"
    }


    /// The rows for the build tools (xcodegen, zstd, spirv-cross, glslangValidator) and the Homebrew row they may need.
    /// A tool the app carries counts as present and says "bundled"; otherwise Homebrew's copy counts (`installed` answers
    /// a binary name with its path in a Homebrew folder, or nil). The Homebrew row appears only when some tool is neither
    /// bundled nor installed (with a bundle; with none the row stays, as before): it is the way to get that one.
    nonisolated static func toolDeps(resources: URL?, installed: (String) -> String?, brew: String?) -> [Dep] {
        var rows: [Dep] = []
        var needsBrew = false, anyBundled = false
        for (pkg, binary, key) in brewDeps {
            let bundled = BundledTools.tool(binary, in: resources) != nil
            let path = bundled ? nil : installed(binary)
            if !bundled && path == nil { needsBrew = true }
            if bundled { anyBundled = true }
            // A bundled tool is named by the tool; "brew: …" says where a Homebrew copy comes from, so it stays for the rows that
            // refer to one (installed there, or missing with the install button)
            rows.append(Dep(id: "brew:" + pkg, name: bundled ? "dep.tool." + binary : key, hint: key + ".hint", present: bundled || path != nil,
                            detail: bundled ? "dep.bundled" : (path ?? ""),
                            installCmd: [(brew ?? "/opt/homebrew/bin/brew"), "install", pkg]))
        }
        guard needsBrew || !anyBundled else { return rows }   // without a bundle the row is always there, as it was
        return [Dep(id: "brew", name: "dep.brew", hint: "dep.brew.hint", present: brew != nil,
                    installCmd: ["/bin/bash", "-c",
                      "NONINTERACTIVE=1 /bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""])] + rows
    }

    nonisolated static func detectDepsSync(needsIOS: Bool = BuildModel.needsIOSPlatform()) -> [Dep] {
        var out: [Dep] = []

        // Xcode.app alone is not enough: since Xcode 15 the iOS platform ships as a separate
        // download, so a fresh install has xcodebuild but no iOS SDK and the build dies deep in
        // xcodebuild. Ask for the SDK version itself — that is the check that matches the name.
        // And ask xcode-select where Xcode is, not a fixed path: a beta lives at
        // /Applications/Xcode-beta.app and the hard-coded check called that "no Xcode" (#21).
        let selected = Self.developerDir()
        let xcodeApp = Self.installedXcode()
        let sdkenv = runOK("/usr/bin/xcrun", ["--sdk", "iphoneos", "--show-sdk-version"])
        // A Mac-only setup does not need the iOS platform (onboarding's platform choice, #120); a
        // Mac build still needs a selected Xcode, so the CommandLineTools state is reported either way.
        switch Self.xcodeState(selected: selected, xcodeApp: xcodeApp, iosSDK: !needsIOS || sdkenv) {
        case .ready:
            out.append(Dep(id: "xcode", name: "dep.xcode", hint: "dep.xcode.hint", present: true, installCmd: []))
        case .noIOSSDK:
            out.append(Dep(id: "xcode", name: "dep.xcode", hint: "dep.xcode.hint", present: false,
                           detail: "dep.xcode.noSDK", installCmd: iosPlatformCmd))
        case .commandLineToolsOnly(let xcode):
            // One admin prompt runs both steps: switch the toolchain, then let Xcode finish its
            // first launch (license and components) - a fresh App Store download has neither.
            let script = "xcode-select -s '" + xcode + "/Contents/Developer' && xcodebuild -runFirstLaunch"
            let apple = "do shell script \"" + script.replacingOccurrences(of: "\"", with: "\\\"") + "\" with administrator privileges"
            out.append(Dep(id: "xcode", name: "dep.xcode", hint: "dep.xcode.hint", present: false,
                           detail: "dep.xcode.notSelected", actionLabel: "dep.xcode.fix",
                           installCmd: ["/usr/bin/osascript", "-e", apple]))
        case .notInstalled:
            out.append(Dep(id: "xcode", name: "dep.xcode", hint: "dep.xcode.hint", present: false, installCmd: []))
        }

        let mt = runOK("/usr/bin/xcrun", ["-sdk", "macosx", "metal", "--version"])
        out.append(Dep(id: "metal", name: "dep.metal", hint: "dep.metal.hint",
                       present: mt, installCmd: metalToolchainCmd))

        out += toolDeps(resources: BundledTools.resources,
                        installed: { firstExisting(["/opt/homebrew/bin/\($0)", "/usr/local/bin/\($0)"]) },
                        brew: firstExisting(["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]))

        let (dn, dnOK) = findDotnet()
        out.append(Dep(id: "dotnet", name: "dep.dotnet", hint: "dep.dotnet.hint",
                       present: dnOK, detail: dnOK ? dn : "dep.dotnet.missing",
                       installCmd: ["/bin/bash", "-c",
                         "curl -sSL https://dot.net/v1/dotnet-install.sh -o /tmp/di.sh && chmod +x /tmp/di.sh && /tmp/di.sh --channel 10.0 --install-dir $HOME/.dotnet"]))

        let (py, pyOK) = findPython()
        let pyVer = pythonVersion(py).map { "\($0.0).\($0.1)" } ?? "?"
        // A too-old interpreter is a different problem from a missing package: say which one it is,
        // because the fix differs (install a newer Python vs pip install into this one).
        // A version we cannot read means no interpreter ran at all (py is then the venv
        // that does not exist yet), which is not the same as one that is too old.
        let minVer = "\(minPython.0).\(minPython.1)"
        let pyDetail = pyOK ? (py == BundledTools.python() ? "dep.bundled" : py)
            : pythonVersion(py).map { $0 >= minPython
                ? "dep.python.missing:\(py) (\(pyVer))"
                : "dep.python.old:\(pyVer):\(minVer)" }
            ?? "dep.python.notFound:\(minVer):\(minVer)"
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
                let collected = LineBox()
                ok = Self.runCaptured(["/bin/bash", "-c",
                     cmd.map { $0.contains(" ") ? "'" + $0 + "'" : $0 }.joined(separator: " ")],
                     env: ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                           "HOME": NSHomeDirectory(), "NONINTERACTIVE": "1", "USER": NSUserName()])
                { line in
                    collected.append(line)
                    DispatchQueue.main.async { self.append(line + "\n") }
                }
                let (error, fix) = Self.failureInfo(collected.lines)
                DispatchQueue.main.async {
                    if let j = self.deps.firstIndex(where: { $0.id == dep.id }) {
                        self.deps[j].lastError = ok ? "" : error
                        self.deps[j].fixHint = ok ? "" : fix
                    }
                }
            }
            DispatchQueue.main.async {
                if let j = self.deps.firstIndex(where: { $0.id == dep.id }) { self.deps[j].installing = false }
                if ok, let j = self.deps.firstIndex(where: { $0.id == dep.id }) { self.deps[j].lastError = ""; self.deps[j].fixHint = "" }
                if !ok { self.doneNote = String(format: self.t("dep.install.fail"), self.t(dep.name)) }
                self.checkDeps()
            }
        }
    }

    /// The line a failed install should show, and the fix to offer beside it.
    ///
    /// A GUI user sees a spinner turn back into a button; the reason (brew refusing a directory it
    /// does not own is the common one) lived only in the log. Prefer the tool's own `Error:` line,
    /// and map the few causes we can name to the exact command.
    nonisolated static func failureInfo(_ lines: [String]) -> (error: String, fix: String) {
        let meaningful = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let error = meaningful.first { $0.hasPrefix("Error:") }
            ?? meaningful.first { $0.lowercased().contains("error") }
            ?? meaningful.last ?? ""
        let lower = lines.joined(separator: "\n").lowercased()
        let fix: String
        if lower.contains("/opt/homebrew is not writable") || lower.contains("permission denied @ dir_initialize")
            || lower.contains("/usr/local is not writable") {
            fix = "dep.fix.brewOwner"
        } else if lower.contains("command not found") || lower.contains("brew: not found") {
            fix = "dep.fix.brewMissing"
        } else if lower.contains("agreeing to the xcode license") || lower.contains("xcode license") {
            fix = "dep.fix.xcodeLicense"
        } else if lower.contains("could not resolve host") || lower.contains("failed to download")
            || lower.contains("operation timed out") {
            fix = "dep.fix.network"
        } else {
            fix = "dep.fix.log"
        }
        return (error, fix)
    }

    /// The output lines seen so far, from the pipe's threads and read on the main queue.
    final class LineBox: @unchecked Sendable {
        private let lock = NSLock()
        private var box: [String] = []
        func append(_ l: String) { lock.lock(); box.append(l); lock.unlock() }
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return box }
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
    /// `detail` carries either a real path, an L10n key, or "key:argument[:argument…]".
    func depDetail(_ d: Dep) -> String {
        let raw = d.detail
        if raw.isEmpty { return t(d.hint) }
        if raw.hasPrefix("/") || raw.hasPrefix("~") { return raw }
        if let colon = raw.firstIndex(of: ":") {
            let key = String(raw[..<colon]), arg = String(raw[raw.index(after: colon)...])
            let args = arg.components(separatedBy: ":").map { shortPath($0) as CVarArg }
            if L10n.table[key] != nil { return String(format: t(key), arguments: args) }
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
    var onOpenControls: () -> Void = {}
    var onRunSetup: (() -> Void)?   // the guided first-run setup, again (nil where there is none)
    var controlChanges = 0
    @AppStorage(BuildNotice.defaultsKey) private var notifyBuilds = true   // BuildNotifications.swift
    @State private var extrasOpen = false
    @State private var logOpen = false
    @State private var keyCheck: KeyCheck.Outcome?   // prod.keys against the chosen files (KeyCheck.swift)
    @EnvironmentObject private var padFocus: PadFocus

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 34) {
                if settings { settingsPage } else { buildPage }
            }
            .padding(.horizontal, 40).padding(.top, 40).padding(.bottom, 48)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .onChange(of: padFocus.focused) { id in   // a controller's focus on this page scrolls into view
            if let id, id.hasPrefix("set.") { withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) } }
        }
        .modifier(GameFilesDrop(enabled: !settings && !m.running, label: m.t("drop.hint")) { m.take(dropped: $0) })   // DropFiles.swift
        .alert(String(format: m.t("dev.askTransferTitle"), m.deviceName(m.installDevice)), isPresented: $m.transferAsk) {
            Button(m.t("dev.transferNow")) { m.transferAnswer(true) }
            Button(m.t("dev.transferSkip"), role: .cancel) { m.transferAnswer(false) }
        } message: {
            Text(m.t("dev.askTransferText"))
        }
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
        if m.target != "mac-app" { install.disabled(m.running) }
        logPanel
        action
        outcome
        progress
    }

    /// Where an iPhone build goes: exported as an IPA (as before), or signed and installed on a paired device.
    private var install: some View {
        let devices = [(value: "", label: m.t("dev.none"))] + m.devices.map { d in
            (value: d.id, label: d.name + (d.reachable ? "" : " (" + m.t("dev.notConnected") + ")"))
        }
        let teams = m.teams.map { (value: $0.id, label: $0.label(personalTeam: m.t("dev.personalTeam"))) }
        let needsCertificate = m.teams.first { $0.id == m.signingTeam }.map { !$0.hasCertificate } ?? false
        return group(m.t("dev.section"), footnote: m.installDevice.isEmpty ? "" : (needsCertificate ? m.t("dev.teamNoCert") + " " : "") + m.t("dev.note")) {
            row(m.t("dev.target"), detail: m.devicesChecked && m.devices.isEmpty ? m.t("dev.noDevices") : "") {
                if !m.devicesChecked { ProgressView().controlSize(.small) }
                Button(m.t("dev.refresh")) { m.refreshDevices() }.buttonStyle(.plain).font(.manrope(13)).foregroundStyle(.secondary)
                LauncherMenuPicker(options: devices, selection: m.installDevice) { m.installDevice = $0 }
            }
            if !m.installDevice.isEmpty {
                divider
                if teams.isEmpty {
                    row(m.t("dev.team"), detail: m.t("dev.noTeam"), dot: LauncherPalette.building) { EmptyView() }
                } else {
                    row(m.t("dev.team")) {
                        LauncherMenuPicker(options: teams, selection: m.signingTeam) { m.signingTeam = $0 }
                    }
                }
            }
        }
        .onAppear { if !m.devicesChecked { m.refreshDevices() } }
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
            ForEach(m.slots.filter { !$0.optional }, id: \.id) { s in
                divider; slotRow(s)
                if s.id == "keys", let keyCheck { KeyCheckLine(outcome: keyCheck, t: m.t) }
            }
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
        .task(id: KeyCheck.Inputs(keys: m.keysPath, files: [m.basePath, m.updatePath] + m.dlcPaths)) {
            keyCheck = await KeyCheck.runDetached(KeyCheck.Inputs(keys: m.keysPath, files: [m.basePath, m.updatePath] + m.dlcPaths))
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
        if m.done && !m.installedOn.isEmpty {
            group(String(format: m.t("dev.installed"), m.deviceName(m.installedOn))) {
                row(m.t("dev.installedNote"), dot: LauncherPalette.ready) {
                    Button(String(format: m.t("dev.open"), m.deviceName(m.installedOn))) {
                        m.openOnDevice(udid: m.installedOn, app: m.installedAppPath) { error in if let error { m.doneNote = error } }
                    }
                }
                // The game files were copied (or, after a skipped transfer, await a manual copy — a
                // fast external drive handed to the device is quicker than USB): show where they are.
                if !m.archivePath.isEmpty {
                    divider
                    row(m.t("dev.gameData"), detail: m.shortPath(m.archivePath), dot: LauncherPalette.ready, help: m.archivePath) {
                        Button(m.t("install.reveal")) { reveal(m.archivePath) }
                    }
                }
            }
        } else if m.done && m.target != "mac-app" {
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
            }
        }
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
            }
        }
    }

    /// The build log, right under the Mac / iPhone choice and folded away until it is asked for.
    /// It used to sit at the bottom of the progress card, which is where a failed build's message
    /// pointed ("see the log below") while the log itself was out of view on a short window (#52).
    @ViewBuilder private var logPanel: some View {
        group(m.t("section.log")) {
            disclosure(m.t("build.log"), isOpen: logOpen) { logOpen.toggle() }
            if logOpen { logView.padding(.horizontal, 14).padding(.bottom, 14) }
        }
        .onReceive(BuildNotifier.shared.$showLog) { show in   // a clicked notification of a failed build
            if show { logOpen = true; DispatchQueue.main.async { BuildNotifier.shared.showLog = false } }
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

    /// Every button of the Settings cards is this wide, so they stand in one column.
    static let settingsButtonWidth: CGFloat = 150

    @ViewBuilder private var settingsPage: some View {
        pageHeading(m.t("settings.heading"), note: m.t("settings.note"))
        settingsCards.buttonStyle(LauncherSecondaryButtonStyle(minWidth: Self.settingsButtonWidth))
    }

    @ViewBuilder private var settingsCards: some View {
        group(m.t("section.library"), footnote: m.t("library.folderHint")) {
            row(m.t("library.folderTitle"), detail: library.folder.isEmpty ? m.t("library.folderUnset") : m.shortPath(library.folder),
                dot: library.folder.isEmpty ? LauncherPalette.unbuilt : LauncherPalette.ready, help: library.folder) {
                if library.scanning { ProgressView().controlSize(.small) }
                if !library.folder.isEmpty {
                    Button(m.t("library.rescan")) { library.discover() }.disabled(library.scanning)
                        .padTarget("set.rescan", scope: "main") { if !library.scanning { library.discover() } }
                }
                Button(m.t("library.chooseFolder"), action: onChooseLibraryFolder)
                    .padTarget("set.folder", scope: "main") { onChooseLibraryFolder() }
            }
        }
        group(m.t("section.controls"), footnote: m.t("controls.settingsHint")) {
            row(m.t("controls.row"), detail: controlChanges == 0 ? m.t("controls.defaultLayout") : String(format: m.t("controls.changes"), controlChanges)) {
                Button(m.t("controls.customize"), action: onOpenControls)
                    .padTarget("set.controls", scope: "main") { onOpenControls() }
            }
        }
        tools
        group(m.t("section.app"), footnote: m.appStatus) {
            // The interface language: the device default unless someone picks one here. Stored as
            // "" (follow), "zh" or "en" so a later system-language change still applies.
            row(m.t("settings.language"),
                detail: Lang.saved.map { $0 == .zh ? m.t("settings.language.zh") : m.t("settings.language.en") }
                    ?? m.t("settings.language.system"), dot: LauncherPalette.ready, help: "") {
                // The launcher's own list (as in Launch options), drawn like the buttons beside it and as wide
                LauncherMenuPicker(options: [(value: "", label: m.t("settings.language.system")),
                                             (value: "zh", label: m.t("settings.language.zh")),
                                             (value: "en", label: m.t("settings.language.en"))],
                                   selection: Lang.saved.map { $0.rawValue } ?? "", fill: true, buttonLike: true) { v in
                    Lang.saved = v.isEmpty ? nil : Lang(rawValue: v)
                    m.lang = Lang.initial()
                }
                .frame(width: Self.settingsButtonWidth)
                .padTarget("set.language", scope: "main", activate: { cycleLanguage(1) }, adjust: { cycleLanguage($0) })
            }
            divider
            // Build notifications (BuildNotifications.swift): none without an app bundle, e.g. under swift run
            row(m.t("settings.notify"), detail: m.t(BuildNotice.hasBundleID ? "settings.notifyNote" : "settings.notifyUnbundled")) {
                Toggle("", isOn: $notifyBuilds).toggleStyle(LauncherSwitchStyle()).labelsHidden().disabled(!BuildNotice.hasBundleID)
                    .padTarget("set.notify", scope: "main") { notifyBuilds.toggle() }
            }
            divider
            if let onRunSetup {
                row(m.t("settings.setup"), detail: m.t("settings.setupNote")) {
                    Button(m.t("settings.setupBtn"), action: onRunSetup)
                        .padTarget("set.setup", scope: "main") { onRunSetup() }
                }
                divider
            }
            row("NX2Apple", detail: String(format: m.t("app.version"), BuildModel.appVersion),
                dot: m.appStaged != nil ? LauncherPalette.ready : nil) {
                if m.appBusy { ProgressView().controlSize(.small) }
                if m.appStaged != nil {
                    // Downloaded and verified: it goes in when the app quits; this restarts into it now (not during a build)
                    Button(m.t("app.restartNow")) { m.restartToUpdate() }.disabled(m.running)
                        .padTarget("set.appRestart", scope: "main") { if !m.running { m.restartToUpdate() } }
                } else if let u = m.appUpdate, m.appInstallability == .ok {
                    Button(String(format: m.t("app.updateBtn"), u.tag)) { m.performAppUpdate() }.disabled(m.appBusy || m.running)
                        .padTarget("set.appUpdate", scope: "main") { if !(m.appBusy || m.running) { m.performAppUpdate() } }
                } else {
                    Button(m.t("repo.check")) { m.checkAppUpdate() }.disabled(m.appBusy)
                        .padTarget("set.appCheck", scope: "main") { if !m.appBusy { m.checkAppUpdate() } }
                }
            }
            divider
            // A launcher built from the repository never replaces itself (AppUpdate.installability): the switch says so and stays off
            row(m.t("app.auto"), detail: m.t(m.appInstallability == .ok ? "app.autoNote" : m.appInstallability == .developer ? "app.autoDev" : "app.autoReadOnly")) {
                Toggle("", isOn: Binding(get: { m.autoUpdateApp && m.appInstallability == .ok }, set: { m.autoUpdateApp = $0 }))
                    .labelsHidden().toggleStyle(LauncherSwitchStyle()).disabled(m.appInstallability != .ok)
                    .padTarget("set.appAuto", scope: "main") { if m.appInstallability == .ok { m.autoUpdateApp.toggle() } }
            }
        }
    }

    /// The interface language one step on (a controller's left / right on the language list).
    private func cycleLanguage(_ by: Int) {
        let values = ["", "zh", "en"]
        let at = values.firstIndex(of: Lang.saved.map { $0.rawValue } ?? "") ?? 0
        let v = values[(at + by + values.count) % values.count]
        Lang.saved = v.isEmpty ? nil : Lang(rawValue: v)
        m.lang = Lang.initial()
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
                                .padTarget("set.repoPull", scope: "main") { if !(m.repoBusy || m.running) { m.pullRepo() } }
                        }
                        Button(m.t("repo.check")) { m.checkRepoUpdates() }.disabled(m.repoBusy || m.running)
                            .padTarget("set.repoCheck", scope: "main") { if !(m.repoBusy || m.running) { m.checkRepoUpdates() } }
                    } else {
                        Button(m.t("repo.adopt")) { m.adoptRepoAsGit() }.disabled(m.repoBusy || m.running)
                            .padTarget("set.repoAdopt", scope: "main") { if !(m.repoBusy || m.running) { m.adoptRepoAsGit() } }
                    }
                }
                // Always offered, including when a repository is already configured: a saved path from
                // an earlier session (an upstream clone, a moved folder) is exactly the state a user
                // cannot fix without this button — the report had no way to leave the wrong repository.
                Button(m.t("repo.choose")) { pickRepo() }
                if !m.repoOK {
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
                Text(m.t(m.autoUpdateRepo ? "repo.noGit" : "repo.zipNoAuto")).font(.manrope(12)).foregroundStyle(.secondary)
                    .padding(.horizontal, 18).padding(.bottom, 12)
            }
            if m.repoOK, !BuildModel.missingTools(in: m.repoPath).isEmpty {
                Text(String(format: m.t("repo.toolsOld"), BuildModel.missingTools(in: m.repoPath).joined(separator: ", ")))
                    .font(.manrope(12)).foregroundStyle(LauncherPalette.building)
                    .padding(.horizontal, 18).padding(.bottom, 12)
            }
            if m.repoOK {   // a ZIP copy too: its adoption at launch follows this switch
                divider
                row(m.t("repo.auto"), detail: m.t("repo.autoNote")) {
                    Toggle("", isOn: $m.autoUpdateRepo).labelsHidden().toggleStyle(LauncherSwitchStyle())
                }
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
                        .padTarget("set.deps", scope: "main") { m.checkDeps() }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if m.depsOpen {
                ForEach(m.deps, id: \.id) { d in
                    divider
                    VStack(alignment: .leading, spacing: 0) {
                        row(m.t(d.name), detail: m.shortPath(m.depDetail(d)), dot: d.present ? LauncherPalette.ready : LauncherPalette.building,
                            help: m.t(d.hint)) {
                            if d.installing {
                                ProgressView().controlSize(.small)
                                Text(m.t("dep.installing")).font(.manrope(12)).foregroundStyle(LauncherPalette.building)
                            } else if !d.present {
                                Button(d.actionLabel.isEmpty ? (d.installCmd.isEmpty ? m.t("dep.openAppStore") : m.t("dep.install")) : m.t(d.actionLabel)) { m.installDep(d) }
                            }
                        }
                        // Why the last install failed, and what to do about it: the tool's own
                        // error line under the row, the fix (a command or a place to look) below it.
                        if !d.lastError.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(d.lastError).font(.mono(11)).foregroundStyle(LauncherPalette.building)
                                    .lineLimit(3).help(d.lastError)
                                if !d.fixHint.isEmpty {
                                    Text(m.t(d.fixHint)).font(.manrope(11.5)).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(.leading, 37).padding(.trailing, 18).padding(.bottom, 11)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            divider
            row(m.t("diag.title"), detail: m.t("diag.note")) { DiagnosticsButton(m: m, game: library.selected, width: Self.settingsButtonWidth) }
        }
    }

    private func pickRepo() {
        let d = NSOpenPanel()
        d.canChooseDirectories = true; d.canChooseFiles = false
        d.message = m.t("repo.pickMessage")
        if d.runModal() == .OK, let u = d.url { m.repoPath = u.path }
    }
}
