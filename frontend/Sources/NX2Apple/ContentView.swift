import SwiftUI
import NXCore
import NXLauncher
import NXModel

// NS Port Builder: a macOS front end that walks a user through building a playable
// IPA from their own Switch game files. Not part of the host runtime; drives the
// repository's scripts (build_ipa_from_nsp.py, romfs_image.py) as subprocesses.
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

    /// A stage's name in the launcher's language. The script names its stages in English (PROG.stage in
    /// build_ipa_from_nsp.py): stage.<name> in the table, "extract <name>" and "<API> shader capture" with their
    /// part kept; a name the table does not know (a newer script's) is shown as the script wrote it.
    static func localizedName(_ name: String, _ t: (String) -> String) -> String {
        func known(_ key: String) -> String? { let s = t(key); return s == key ? nil : s }
        let key = "stage." + name.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if let s = known(key) { return s }
        if name.hasPrefix("extract "), let f = known("stage.extract") { return String(format: f, String(name.dropFirst("extract ".count))) }
        if name.hasSuffix(" shader capture"), let f = known("stage.capture") { return String(format: f, String(name.dropLast(" shader capture".count))) }
        return name
    }

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
    /// A finished sentence shown beside the file name (the update row: which of several updates was taken).
    var note: String = ""
    var ok: Bool { paths.contains { FileManager.default.fileExists(atPath: $0) } }
    /// `problem` holds either a finished message or a key + arguments, resolved by the model
    /// (it needs the current language, which a struct cannot read).
    var problemText: String { problem }
    func summary(_ t: (String) -> String) -> String {
        if !problem.isEmpty { return problem.hasPrefix("data.") ? t(problem) : problem }
        if paths.isEmpty {
            if kind == .dlc { return t("data.notSelectedDlc") }
            return optional ? t("data.notSelectedOptional") : t("data.notSelected")
        }
        if paths.count == 1 {
            let name = (paths[0] as NSString).lastPathComponent
            return note.isEmpty ? name : name + "\n" + note
        }
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
    @Published var staleFrameworks: [StaleFrameworks.Entry] = []   // the prompt of StaleFrameworksPrompt.swift (#449)
    /// The shell folder the cache row shows: the frameworks' mirror, shell.json and the banner cache live here.
    var shellCachePath: String { shellRoot }
    /// The shell folder of the install and of the cache row: the saved one, else next to the output folder (or the game's folder).
    var shellRoot: String { ShellLibrary.resolveRoot(parent: outDir.isEmpty ? (basePath as NSString).deletingLastPathComponent : outDir) }
    @Published var stopping = false
    /// The build log. Not published: only `BuildLogView` observes it (#387), so a log line redraws the log and nothing else.
    let log = BuildLog()
    var logTail: String {
        get { BuildLog.onMain { log.text } }
        set { BuildLog.onMain { log.set(newValue) } }
    }
    @Published var done = false
    @Published var doneNote = ""
    /// What the NSP script stopped on, when it is one of the known early stops (BuildFailure.swift). nil for a build that
    /// succeeded, is running, or failed some other way (the note then shows the last line of the log, as it always did).
    @Published var failure: BuildFailure?
    /// "Build anyway" asked for this stop and waiting for the confirmation dialog.
    @Published var confirmingOverride: BuildFailureKind?
    /// The one-off `--allow-*` of a confirmed "Build anyway": taken by the next build and never stored.
    private(set) var armedOverride: BuildFailureKind?
    @Published var macAppPath = ""   // --platform mac-app: the .app this build produced
    /// BuildTarget.ios = the game's framework in the one shared app on an iPhone or iPad; BuildTarget.mac = a double-clickable
    /// Mac app (upstream's --platform mac-app). A Mac app is a different output of the same pipeline, not a
    /// different pipeline: same extraction, rewrite and shaders, then dm/mac/pack_app.py.
    @Published var target = BuildTarget.saved() {
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
    /// The shared app's copy question: the size and the connection (nil: none is up).
    @Published var shellCopy: ShellCopyPlan?
    @Published var shellWaiting = false   // waiting for a cable before the game data goes over
    fileprivate var shellCopyAnswer: ((ShellCopyDecision) -> Void)?
    let shellWaitCancelled = LockedFlag()
    private var shellRetry: (framework: String, titleID: String, name: String, archive: String)?
    var xcrunPath = "/usr/bin/xcrun"      // tests stand in for xcodebuild and devicectl
    var volumesRoot = "/Volumes"          // where external drives are mounted
    var teamsProvider: () -> [SigningTeam] = { DeviceTools.teams() }   // the teams the Mac knows, read when a signing step fails
    var chooseKeys: (() -> Void)?          // tests stand in for the file picker
    var revealFolder: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var openApp: (URL) -> Void = { NSWorkspace.shared.openApplication(at: $0, configuration: NSWorkspace.OpenConfiguration()) }

    /// This iPhone build goes straight to a device.
    var installsDirectly: Bool { target != BuildTarget.mac && !installDevice.isEmpty && !signingTeam.isEmpty }

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

    /// The language and the strings: views take them from the environment, this model only for the text it writes itself.
    let localizer: Localizer
    init(localizer: Localizer = Localizer()) { self.localizer = localizer }

    private var proc: Process?
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

    static func track(_ p: Process) {
        _ = exitHandlers
        groupsLock.lock(); groups.insert(p.processIdentifier); groupsLock.unlock()
    }

    static func untrack(_ p: Process) {
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
        EngineLayout.isCheckout(dir)   // a checkout with tools/engine.py, a synced engine/, or an engine tree (#214)
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
        let root = EngineLayout.root(dir)   // the checkout's engine/, or an engine tree itself (Engine.swift)
        return requiredTools.filter { !FileManager.default.fileExists(atPath: root + "/" + $0) }
    }

    /// Whether the checkout's build script has this fork's `--work-dir` (issue #5): an upstream
    /// nxnative checkout, or a ZIP of an older release, stops with "unrecognized arguments" when the
    /// app passes it. Read from the script's own argparse rather than assumed — the option is the
    /// fork's, not upstream's.
    nonisolated static func repoSupportsWorkDir(_ dir: String) -> Bool {
        let script = EngineLayout.root(dir) + "/" + buildScript
        if !FileManager.default.fileExists(atPath: script), EngineLayout.hasEngineTool(dir) { return true }   // engine/ not made yet: the fork's engine has it
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

    // ---- The release app's engine (EngineUpdater.swift, EngineUpdateModel.swift) ----

    /// The engine tree inside the app bundle. nil for a launcher built from the repository, which keeps its checkout and git.
    /// A release app builds from the engine store instead, and never clones or pulls.
    var engineBundle: URL? = EngineBundle.tree(in: Bundle.main.resourceURL)
    var engineStore = EngineStore()
    var engineTransport: EngineTransport = URLSessionEngineTransport()
    @Published var engineSelection = EngineSelection.load()
    @Published var engineBusy = false
    @Published var engineStatus = ""
    /// A newer engine the launch check found while automatic updates are off: Settings offers it.
    @Published var engineAvailable: EngineUpdate.Engine?
    /// The channel the player picked and is asked to confirm (the switch can change the shader chain).
    @Published var confirmingChannel: EngineChannel?
    /// An installed engine that waits for the running build to end before the build tools switch to it.
    var pendingEngine: (engine: EngineUpdate.Engine, channel: EngineChannel)?
    var usesEngineStore: Bool { engineBundle != nil }

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
        guard !running, !repoBusy, !usesEngineStore else { return }
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
                    self.syncEngine()
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
        guard repoOK, repoIsGit, !usesEngineStore else { return }   // a release app updates its engine by version instead
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
        guard !running, !repoBusy, !usesEngineStore, repoOK, repoIsGit, let git = Self.gitBinary() else { return }
        repoBusy = true; repoStatus = t("repo.pulling")
        let dir = repoPath
        DispatchQueue.global().async {
            let r = Self.runQuiet([git, "-C", dir, "pull", "--ff-only", "origin", "main"], env: Self.gitEnv())
            DispatchQueue.main.async {
                self.repoBusy = false
                if r.ok {
                    self.repoBehind = 0; self.repoStatus = self.t("repo.pulled")
                    if !r.out.isEmpty { self.append(r.out + "\n") }
                    self.syncEngine()   // the pull may have moved the pin or the patches
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
        guard !running, !repoBusy, !usesEngineStore, repoOK, repoIsGit, let git = Self.gitBinary() else { return }
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
                    self.syncEngine()
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
        guard !usesEngineStore else { return }
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
        guard !running, !repoBusy, !usesEngineStore, repoOK, !repoIsGit, let git = Self.gitBinary() else { return }
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
                    self.syncEngine()
                } else {
                    self.repoStatus = self.t(automatic ? "repo.adoptFailAuto" : "repo.adoptFail")
                }
            }
        }
    }

    /// What waits for the running `tools/engine.py sync` (nil: none runs), and whether another one is due when it ends.
    private var engineSyncWaiting: [(Bool) -> Void]?
    private var engineSyncAgain = false
    /// A sync runs: the launcher shows a status line with a spinner (EngineSyncBanner).
    @Published var engineSyncing = false
    /// How the last sync stopped (no network or GitHub unreachable, or another stop), as a failure row with a retry button. nil: none.
    @Published var engineFailure: BuildFailure?

    /// `tools/engine.py sync` when engine/ is stale (#214, Engine.swift): at launch, after a clone, a pull or an adoption, and before a
    /// build that has no other engine. Checkouts only: a release app carries its engine tree (#227) and never syncs. A no-op for a current engine/ or a folder
    /// that is an engine tree. `then(ok)` runs on the main queue.
    func syncEngine(then: ((Bool) -> Void)? = nil) {
        if engineSyncWaiting != nil { engineSyncAgain = true; if let then { engineSyncWaiting?.append(then) }; return }
        guard EngineLayout.isStale(repoPath) else { engineFailure = nil; then?(true); return }
        engineSyncWaiting = then.map { [$0] } ?? []
        engineSyncing = true; engineFailure = nil
        let repo = repoPath, chosen = pythonPath
        append("$ python3 tools/engine.py sync\n")
        var tail = ""   // what failureKind reads when the sync stops (only touched on the main queue)
        DispatchQueue.global().async {
            let py = chosen.isEmpty ? Self.findPython().path : chosen
            let ok = EngineLayout.runSync(repo: repo, python: py) { line in
                DispatchQueue.main.async { self.append(line + "\n"); tail = String((tail + line + "\n").suffix(4000)) }
            }
            DispatchQueue.main.async {
                let waiting = self.engineSyncWaiting ?? [], again = self.engineSyncAgain && ok
                self.engineSyncWaiting = nil; self.engineSyncAgain = false
                self.engineSyncing = false
                self.engineFailure = ok ? nil : BuildFailure(kind: EngineLayout.failureKind(tail), gameName: nil)
                if again { self.syncEngine { ok in waiting.forEach { $0(ok) } } } else { waiting.forEach { $0(ok) } }
                self.objectWillChange.send()   // repoOK and the engine's paths may have changed
            }
        }
    }

    /// The failure row's Try again: clears the row and runs the sync again.
    func retryEngineSync() {
        guard !engineSyncing else { return }
        engineFailure = nil
        syncEngine()
    }

    // ---- App self-update (GitHub Releases) ----
    // The rules (what is verified, which copies replace themselves, never during a build) are in AppUpdate.swift.

    /// Bump together with each release tag; the update check compares it with the latest release.
    static let appVersion = "1.0.1"
    /// The update checkAppUpdate found: the tag, the asset to download, its digest, and the release
    /// notes the sheet shows. The notes are why the sheet exists — "update available" alone told a
    /// user nothing about what they would get.
    @Published var appUpdate: AppUpdate.Release?
    @Published var appBusy = false
    /// Whether the "a new version is out" sheet is up: opened by the launch check and by Check for
    /// updates, so a user learns what changed before deciding, not after downloading.
    @Published var showUpdateSheet = false
    /// The uninstall row's dialog: computed when the row is pressed, run when the player confirms.
    @Published var uninstallPlan: Uninstall.Plan?
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
            // The old instance is still running, so opening the same bundle now would only activate it:
            // a helper opens the new copy once this process has exited.
            if AppUpdate.relaunch(placed) {
                NSApp.terminate(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { exit(0) }
            } else {
                appStatus = String(format: t("app.relaunchFail"), staged.release.tag)
            }
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
        updateSlot("update") { $0.paths = found.update.map { [$0] } ?? []; $0.problem = ""; $0.note = updateNote(found) }
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
        /// How many updates the files held and the version of the one taken (the newest), for the update row's note.
        var updateCount = 0
        var updateVersion = 0
        var anyGame: Bool { base != nil || update != nil || !dlc.isEmpty }
        static func == (a: Self, b: Self) -> Bool {
            a.base == b.base && a.update == b.update && a.dlc == b.dlc && a.keys == b.keys
        }
    }

    /// The update row's note when the files held several updates: which one was taken and why one is enough.
    func updateNote(_ found: FoundInputs) -> String {
        guard found.update != nil, found.updateCount > 1 else { return "" }
        return String(format: t("data.updateNewest"), found.updateVersion, found.updateCount)
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
            guard let tid = titleID(name) else { continue }   // a name without a title ID cannot be classified
            switch tid & 0xFFF {
            case 0: base.append((path, size))
            case 0x800: update.append((path, size, updateVersion(name)))
            default: dlc.append(path)
            }
        }
        // several bases happen when a folder holds a repack beside the original: the largest wins
        found.base = base.sorted { $0.1 > $1.1 }.first?.0
        // a folder that holds other games too: only the update and add-on content of the chosen base game count
        if let app = found.base.flatMap({ titleID(($0 as NSString).lastPathComponent) }).map({ $0 & ~0xFFF }) {
            update = update.filter { titleID(($0.0 as NSString).lastPathComponent).map(owner) == app }
            dlc = dlc.filter { titleID(($0 as NSString).lastPathComponent).map(owner) == app }
        }
        // several updates: the newest version is the one a profile would pack (an update contains the earlier ones)
        let newest = update.sorted { $0.2 > $1.2 }.first
        found.update = newest?.0
        found.updateCount = update.count
        found.updateVersion = newest?.2 ?? 0
        found.dlc = dlc.sorted()
        return found
    }

    /// The base game's title ID (low 12 bits clear) a title ID belongs to, as build_ipa_from_nsp.py reads it:
    /// 0x000 is a base game, 0x800 its update, anything else add-on content in the block above the base.
    nonisolated static func owner(_ tid: UInt64) -> UInt64 {
        let low = tid & 0xFFF
        return low == 0 ? tid : (low == 0x800 ? tid & ~0xFFF : (tid & ~0xFFF) - 0x1000)
    }

    /// Why a file does not fit the row it was put in, judged by the title ID in its name.
    enum RowMismatch: Equatable { case notBase(UInt64), notUpdate(UInt64), notDLC(UInt64), otherGame }

    /// A file whose name carries no title ID fits every row (the build script reads the ID from the package).
    /// `base` is the selected base game's file name, when it carries one.
    nonisolated static func rowMismatch(_ kind: InputKind, name: String, base: String?) -> RowMismatch? {
        guard kind != .keys, let tid = titleID(name) else { return nil }
        let low = tid & 0xFFF
        switch kind {
        case .base: if low != 0 { return .notBase(tid) }
        case .update: if low != 0x800 { return .notUpdate(tid) }
        case .dlc: if low == 0 || low == 0x800 { return .notDLC(tid) }
        case .keys: break
        }
        if kind != .base, let b = base.flatMap(titleID), owner(tid) != b & ~0xFFF { return .otherGame }
        return nil
    }

    /// The row's message for a rejected file, as a finished sentence in the current language.
    func rowProblemText(_ mismatch: RowMismatch, name: String) -> String {
        func hex(_ tid: UInt64) -> String { String(format: "%016llX", tid) }
        switch mismatch {
        case .notBase(let tid): return String(format: t("data.rowNotBase"), name, hex(tid))
        case .notUpdate(let tid): return String(format: t("data.rowNotUpdate"), name, hex(tid))
        case .notDLC(let tid): return String(format: t("data.rowNotDLC"), name, hex(tid))
        case .otherGame: return String(format: t("data.rowOtherGame"), name)
        }
    }

    /// The version in a file name, 0 when absent: `[v65536]` first, then the `_v65536` / ` v65536` token the
    /// eShop-style names use (`01007EF00011E800_v1114112_038ff9df0888.nsp`). Picks the newest of several updates.
    nonisolated static func updateVersion(_ name: String) -> Int {
        for pattern in [#"\[v(\d+)\]"#, #"(?:^|[_ ])v(\d+)(?=$|[_ .\-)\]])"#] {
            if let v = firstGroup(pattern, in: name), let n = Int(v) { return n }
        }
        return 0
    }

    nonisolated private static func firstGroup(_ pattern: String, in name: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = name as NSString
        guard let m = re.firstMatch(in: name, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    /// What the Choose… dialog of a row offers. The compressed NSZ / XCZ are accepted by the build
    /// script like their plain forms. DLC ships as NSP (or NSZ), never as a cartridge image.
    nonisolated static func allowedFileTypes(for kind: InputKind) -> [String] {
        switch kind {
        case .base, .update: return ["nsp", "xci", "nsz", "xcz"]
        case .dlc: return ["nsp", "nsz"]
        case .keys: return ["keys"]
        }
    }

    func pickFiles(kind: InputKind) {
        let p = NSOpenPanel()
        p.canChooseDirectories = false
        p.canChooseFiles = true
        p.allowsMultipleSelection = (kind == .dlc)
        p.allowedFileTypes = Self.allowedFileTypes(for: kind)
        switch kind {
        case .dlc:
            p.message = t("data.dlcPanelMessage")
            p.prompt = t("data.dlcPanelPrompt")
        case .update: p.message = t("data.updatePanelMessage")
        default: break
        }
        guard p.runModal() == .OK, !p.urls.isEmpty else { return }
        take(picked: p.urls.map(\.path), kind: kind)
    }

    /// Files chosen for one row: those that fit it are taken, the first that does not is named on the row
    /// and left out (it is not moved to another row: the row the user chose stays as they set it).
    func take(picked: [String], kind: InputKind) {
        let id = kind == .base ? "base" : kind == .update ? "update" : kind == .dlc ? "dlc" : "keys"
        let baseName = kind == .base ? nil : (basePath as NSString).lastPathComponent
        var fitting: [String] = [], problem = ""
        for path in picked {
            let name = (path as NSString).lastPathComponent
            if let why = Self.rowMismatch(kind, name: name, base: baseName) {
                if problem.isEmpty { problem = rowProblemText(why, name: name) }
            } else { fitting.append(path) }
        }
        updateSlot(id) { s in
            if !fitting.isEmpty {
                s.paths = kind == .dlc ? Array(Set(s.paths + fitting)).sorted() : Array(fitting.prefix(1))
                s.note = ""
            }
            s.problem = problem
        }
        if kind == .base, let first = fitting.first { gameDir = (first as NSString).deletingLastPathComponent }
    }

    func clear(_ id: String) { updateSlot(id) { $0.paths = []; $0.problem = "" } }

    /// The title ID in a file name: `[0100F2C0115B6000]` first, else a bare 16-digit ID that starts with 01 as a token
    /// (start of the name or after `_`, space, `-`, `.`, `(`, `[`). Only the file name counts, so a full path works and a folder named with an ID never
    /// stands in for the file (#382). Like `01007EF00011E000_v0_420d1c5034ab.nsp`.
    nonisolated static func titleID(_ path: String) -> UInt64? {
        let name = (path as NSString).lastPathComponent
        let found = firstGroup(#"\[([0-9A-Fa-f]{16})\]"#, in: name)
            ?? firstGroup(#"(?:^|[_ \-.(\[])(01[0-9A-Fa-f]{14})(?![0-9A-Fa-f])"#, in: name)
        return found.flatMap { UInt64($0, radix: 16) }
    }

    /// The name of a game's work folder and output (`<key>_build`, `<key>.app`). The title ID in the file name when there
    /// is one, so `<ID>_build` stays what the library looks for. Else the file name without its extension, cut to letters,
    /// digits, `-` and `_`, plus a short hash of the full name: two games never share a folder (and so a shader cache),
    /// the same file name always gets the same one (a rebuild reuses its cache). Never a constant.
    nonisolated static func buildKey(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        if let id = titleID(name) { return String(format: "%016llX", id) }
        let stem = (name as NSString).deletingPathExtension
        var hash: UInt32 = 2166136261   // FNV-1a, stable across runs (Hashable is seeded per launch)
        for byte in stem.utf8 { hash = (hash ^ UInt32(byte)) &* 16777619 }
        let clean = String(stem.unicodeScalars.map { c in
            c.isASCII && (CharacterSet.alphanumerics.contains(c) || c == "-" || c == "_") ? Character(c) : "_"
        }).prefix(40)
        return (clean.isEmpty ? "game" : String(clean)) + "-" + String(format: "%08x", hash)
    }

    var repoOK: Bool { Self.isRepo(repoPath) }
    /// A clone has .git; a GitHub "Download ZIP" copy does not (everything builds, but there is
    /// nothing to fetch or pull — the update buttons hide and the note says to re-download instead).
    var repoIsGit: Bool { FileManager.default.fileExists(atPath: repoPath + "/.git") }
    var canBuild: Bool { repoOK && slot("base").ok && slot("keys").ok && allDepsPresent && !running }

    // MARK: Build

    func startBuild() {
        guard !running else { return }
        // The shared app needs a device this Mac knows. Found out here, before an hour of building, not after it.
        if target != BuildTarget.mac, !shellDeviceChecked {
            guard installsDirectly else { doneNote = t("shell.needsDevice"); done = false; return }
            verifyShellDevice()
            return
        }
        shellDeviceChecked = false
        if target != BuildTarget.mac, askAboutStaleFrameworks() { return }   // StaleFrameworksPrompt.swift (#449)
        stopping = false
        running = true; done = false; doneNote = ""; stages = []; BuildLog.onMain { log.clear() }; chainNoteShown = false
        failure = nil; confirmingOverride = nil
        let override = takeOverrideFlag()   // for this build only: the next one asks again
        installedOn = ""; installedAppPath = ""
        guard repoOK else {
            fail(repoPath.isEmpty ? t("msg.repoInvalidEmpty") : String(format: t("msg.repoInvalid"), shortPath(repoPath)))
            return
        }
        // Resolve the interpreter here if the dependency check has not landed yet. checkDeps()
        // runs on a background queue and startBuild() can beat it — for a moment pythonPath is
        // empty, and the old fallback was Apple's /usr/bin/python3 (3.9), which the script then
        // rejected with "require Python 3.12 or newer" whatever the machine actually had (#53).
        let py = pythonPath.isEmpty ? Self.findPython().path : pythonPath
        // engine/ is the only engine and is stale or missing (#214): make it, then start again
        if EngineLayout.needsSyncBeforeBuild(repoPath) {
            syncEngine { ok in
                self.running = false
                if ok && !EngineLayout.needsSyncBeforeBuild(self.repoPath) { self.startBuild() }
                else { self.fail(String(format: self.t("msg.toolsOld"), "engine/ (python3 tools/engine.py sync, see the log)")) }
            }
            return
        }
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
        let tidHex = Self.buildKey(basePath)
        let workDir = (outDir.isEmpty ? baseDir : outDir) + "/" + tidHex + "_build"
        // The build's signing step refuses the attributes a cloud folder adds, after the long steps: stop here instead.
        if cloudFolderCheck(workDir) {
            failure = BuildFailure(kind: .cloudFolder, gameName: nil, detail: workDir)
            fail(failureWhat(failure!))
            return
        }
        var inputDir = baseDir
        if dirs.count > 1 || !unpicked.isEmpty {
            // A stable folder per game (#132): the script's fingerprints name its files and its profile path.
            let tmp = InputStaging.folder(workDir: workDir)
            let linked = InputStaging.sync(files: staged, into: tmp)
            if linked == 0 { fail(t("msg.stagingFailed")); return }
            staging = tmp; inputDir = tmp
            if !unpicked.isEmpty {
                say(String(format: t("msg.stagedFromSharedFolder"), (basePath as NSString).lastPathComponent))
            }
        } else { staging = nil }

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
        let engine = EngineLayout.root(repoPath)   // the checkout's engine/ (#214)
        var args = [engine + "/" + Self.buildScript, inputDir, "-k", keysPath,
                    "--progress", "json"]
        // A compatibility switch the player turned on: written to a small env file the pipeline
        // copies into the app bundle (main.m sets one variable per line at boot). Only for an iPhone or iPad build;
        // a Mac app runs on this Mac's GPU, which always has BC support.
        if bcOnCPU && target != BuildTarget.mac {
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
        let macApp = target == BuildTarget.mac
        if macApp {
            // -o names the .app; the RomFS goes inside it, so the archive step is skipped below.
            args += ["--platform", "mac-app"]
            macAppPath = (outDir.isEmpty ? baseDir : outDir) + "/" + tidHex + ".app"
            args += ["-o", macAppPath]
        } else {
            // Only the game's framework: the one shared app is made and signed after the script (installShell)
            args += ShellInstall.buildArguments(workDir: workDir, team: signingTeam)
        }
        // The archive step packs whatever folder the build reported; without --work-dir that is the
        // script's default, which is the same workDir unless a separate output folder was chosen.
        effectiveWorkDir = hasWorkDir ? workDir : (inputDir as NSString).appendingPathComponent(tidHex + "_build")
        args = BuildFailureClassifier.arguments(args, adding: override)
        if let override { say(String(format: t("fail.override.note"), override)) }
        say(String(format: t("msg.running"), py) + " " + args.joined(separator: " "))
        lastBuildCommand = [py] + args

        let p = Process()
        p.executableURL = URL(fileURLWithPath: py)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: engine)
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
                    if self.target == BuildTarget.mac {
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
                    } else {
                        // The game's archive, then its framework into the one shared app on the device
                        let tid = Self.buildKey(self.basePath)
                        let name = ((self.basePath as NSString).lastPathComponent as NSString).deletingPathExtension
                        let fw = ShellInstall.frameworkPath(workDir: self.effectiveWorkDir, titleID: tid)
                        self.packArchive(workDir: self.effectiveWorkDir) {
                            self.installShell(framework: fw, titleID: tid, name: name, archive: $0)
                        }
                    }
                } else {
                    if let i = self.stages.lastIndex(where: { $0.state == .running }) {
                        self.stages[i].state = .failed
                        self.stages[i].detail = String(format: self.t("msg.exitCode"), status.terminationStatus)
                        self.noteFailure()
                    } else {
                        // The last real line says more than the exit code alone, and the message
                        // points at the log: "Build failed (exit code 1)" with nothing else sent a
                        // reporter looking for a log that a short window had below the fold (#52)
                        self.doneNote = String(format: self.t("msg.buildFailed"), status.terminationStatus)
                        if let last = Self.lastMeaningfulLine(self.logTail) {
                            self.doneNote = String(format: self.t("msg.buildFailedReason"), last)
                        }
                        self.noteFailure()
                    }
                    self.cleanupStaging()
                }
            }
        }
        PipeReader.attach(to: pipe.fileHandleForReading) { [weak self] d in
            guard let s = String(data: d, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.ingest(s) }
        }
        proc = p
        do { try p.run(); Self.track(p) } catch { fail(String(format: t("msg.launchFailed"), error.localizedDescription)) }
    }

    private var shellDeviceChecked = false

    /// Looks the device up in `devicectl list devices` (in the background), then starts the build, or says how to pair it.
    private func verifyShellDevice() {
        running = true; done = false; doneNote = ""; failure = nil; stages = []
        let xcrun = xcrunPath, device = installDevice
        DispatchQueue.global(qos: .userInitiated).async {
            let link = ShellInstall.connection(of: device, in: DeviceTools.devices(xcrun: xcrun, timeout: 20))
            DispatchQueue.main.async {
                self.running = false
                if link == .notPaired {
                    self.failure = BuildFailure(kind: .devicePairing, gameName: nil)
                    self.doneNote = String(format: self.t("shell.notPaired"), self.deviceName(device))
                    return
                }
                self.shellDeviceChecked = true
                self.startBuild()
            }
        }
    }

    /// A failed build's log read for the script's known early stops: the card under the build button then says what
    /// happened and what to do. An unknown stop leaves the note (the last line of the log) as it is.
    func noteFailure() {
        let f = BuildFailureClassifier.classify(logTail, inputs: failureInputs())
        guard f.kind != .unknown else { failure = nil; return }
        failure = f
        doneNote = failureWhat(f)
    }

    /// Whether the build folder is in a cloud folder. Tests stand in for the system's answer.
    var cloudFolderCheck: (String) -> Bool = { CloudFolder.contains($0) }

    /// The Save to folder, picked in a panel. Clears the cloud-folder stop, since the next build looks at the new folder.
    func chooseBuildFolder() {
        let d = NSOpenPanel(); d.canChooseDirectories = true; d.canChooseFiles = false
        guard d.runModal() == .OK, let u = d.url else { return }
        outDir = u.path
        if failure?.kind == .cloudFolder { failure = nil; doneNote = "" }
    }

    /// What the classifier may check besides the log: the keys file and where the game files are.
    func failureInputs() -> BuildFailureClassifier.Inputs {
        BuildFailureClassifier.Inputs(keysPath: keysPath, paths: ([basePath, updatePath, gameDir] + dlcPaths).filter { !$0.isEmpty },
                                      volumes: volumesRoot)
    }

    /// A failed step of an install on a device, as a card when the launcher can say more than the tool's line.
    /// Called after `finishInstall`, which put the tool's own error into the note.
    func noteInstallFailure(_ step: BuildFailureClassifier.InstallStep, error: String) {
        let listed = teamsProvider().contains { $0.id == signingTeam }
        guard let f = BuildFailureClassifier.classifyInstall(step, error: error, teamListed: listed) else { failure = nil; return }
        failure = f
        doneNote = failureWhat(f)
    }

    /// The first sentence of a failure's hint (it names the game of a 32-bit program when the message does).
    func failureWhat(_ f: BuildFailure) -> String {
        if f.kind == .a32Program, let name = f.gameName { return String(format: t("fail.a32Program.whatNamed"), name) }
        if f.kind == .driveMissing, let name = f.detail { return String(format: t("fail.driveMissing.whatNamed"), name) }
        if f.kind == .diskFull, let gb = f.detail { return String(format: t("fail.diskFull.whatNeeds"), gb) }
        return t(f.kind.whatKey)
    }

    /// "Build anyway": asks first. Nothing is armed until `confirmBuildAnyway`.
    func requestBuildAnyway() {
        guard !running, let kind = failure?.kind, kind.overrideFlag != nil else { return }
        confirmingOverride = kind
    }

    func cancelBuildAnyway() { confirmingOverride = nil }

    func confirmBuildAnyway() {
        guard let kind = confirmingOverride else { return }
        confirmingOverride = nil
        armedOverride = kind
        startBuild()
    }

    /// The flag the next build runs with, once: the arm is cleared here, so a later build never inherits it.
    func takeOverrideFlag() -> String? {
        defer { armedOverride = nil }
        return armedOverride?.overrideFlag
    }

    /// The card's fix buttons run the dependency rows' own commands (the same installDep as Settings).
    func fixBuildFailure(_ kind: BuildFailureKind) {
        switch kind {
        case .translator:
            if let d = deps.first(where: { $0.id == "dotnet" }) { installDep(d) }
        case .iosSDK:
            installDep(Dep(id: "xcode", name: "dep.xcode", hint: "dep.xcode.hint", present: false, installCmd: Self.iosPlatformCmd))
        case .cltSelected:
            if let xcode = Self.installedXcode() {
                installDep(Dep(id: "xcode", name: "dep.xcode", hint: "dep.xcode.hint", present: false, installCmd: Self.selectXcodeCmd(xcode)))
            }
        case .zbic:
            if let d = deps.first(where: { $0.id == "python" }) { installDep(d) }   // the venv install, which now names zbic
        case .keys:
            if let chooseKeys { chooseKeys() } else { pickFiles(kind: .keys) }   // the same picker as the keys row
        case .severalGames, .noTitleID, .diskFull:
            showFailureFolder()
        case .cloudFolder:
            chooseBuildFolder()
        case .teamTaken, .noSigningAccount:
            openXcode()
        case .deviceTransfer, .devicePairing:
            startBuild()
        case .shellDataIncomplete:
            retryShellData()
        default: break
        }
    }

    /// The folder the failure is about, in the Finder: the folder of the game files, else the one the message names. For a full
    /// disk the build folder (`<title ID>_build`, beside the game files) when it is there, since that is where the space went.
    func showFailureFolder() {
        guard let f = failure else { return }
        var folder = gameDir.isEmpty ? (f.detail ?? "") : gameDir
        if f.kind == .diskFull, !gameDir.isEmpty {
            let built = ((try? FileManager.default.contentsOfDirectory(atPath: gameDir)) ?? []).sorted().first { $0.hasSuffix("_build") }
            if let built { folder = gameDir + "/" + built }
        }
        guard !folder.isEmpty else { return }
        revealFolder(URL(fileURLWithPath: folder))
    }

    /// Xcode itself: its Settings > Accounts is where a team is signed in, and Xcode has no address that opens that pane.
    func openXcode() {
        guard let app = Self.installedXcode() else { return }
        openApp(URL(fileURLWithPath: app))
    }

    /// Whether the card's fix button is already running its command.
    func fixBusy(_ kind: BuildFailureKind) -> Bool {
        guard [.translator, .iosSDK, .cltSelected, .zbic].contains(kind) else { return false }
        let id = kind == .translator ? "dotnet" : kind == .zbic ? "python" : "xcode"
        return deps.first { $0.id == id }?.installing ?? false
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
        staging = nil   // the folder stays for the next build of this game (#132, InputStaging)
    }

    /// A stopped build leaves no half-finished stages behind: the progress starts empty again.
    private func resetProgress() { stages = []; BuildLog.onMain { log.clear() } }

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
    private func append(_ s: String) { BuildLog.onMain { log.append(s) } }

    /// Split into lines (the pipe delivers arbitrary chunks) and turn the script's progress into the stage list.
    /// `--progress json` writes one event per line (stage, step, progress with done / total / frac / eta, stage_end,
    /// say), a count change at most every half second; anything else on the pipe (a tool's traceback) is log text.
    /// The older `--progress lines` form is still understood:
    ///   [12:00:01] [2/7] extract v720896 …
    ///   [12:00:20] ✓ [2/7] extract v720896 (0:19): 30,000 files, 3.4 GB
    func ingest(_ chunk: String) {
        for line in BuildLog.onMain({ log.feed(chunk) }) { handle(line) }
    }

    private func flushLines() {
        if let rest = BuildLog.onMain({ log.flush() }) { handle(rest) }
    }

    private func handle(_ line: String) {
        if line.hasPrefix("{"), let data = line.data(using: .utf8),
           let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let kind = event["ev"] as? String {
            return handleEvent(kind, event)
        }
        append(line + "\n")
        noteChainChange(line)
        guard let s = Self.parseStage(line) else { return }
        if let i = stages.firstIndex(where: { $0.id == s.k }) {
            if !s.name.isEmpty { stages[i].name = Stage.localizedName(s.name, t) }
            if s.state != .pending { stages[i].state = s.state }
            if !s.detail.isEmpty { stages[i].detail = s.detail }
            stages[i].percent = s.percent
        } else if s.state != .pending {
            stages.append(Stage(id: s.k, name: Stage.localizedName(s.name, t), state: s.state, detail: s.detail, percent: s.percent, started: Date()))
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
            else { var s = Stage(id: k, name: Stage.localizedName(e["name"] as? String ?? "", t)); update(&s); stages.append(s); stages.sort { $0.id < $1.id } }
        }
        switch kind {
        case "stage":
            let name = e["name"] as? String ?? "", step = e["step"] as? String ?? ""
            let n = (e["n"] as? NSNumber)?.intValue ?? 0
            append("[\(k)/\(n)] \(name)" + (step.isEmpty ? "" : " · \(step)") + " …\n")
            stage { $0.name = Stage.localizedName(name, t); $0.state = .running; $0.detail = step; $0.percent = nil; $0.started = Date(); $0.eta = nil }
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

    /// The DLC images ride along: with the slim default the build script leaves them in the work folder
    /// instead of packing them into the IPA, and the host mounts them from DM_AOC_DIR/<index>.img, so
    /// they belong in this game's folder. Every way the archive step can end (folder pack, image copy,
    /// image reuse, stamp reuse) goes through here (issue #202).
    private func placeAddOnContent(workDir: String, in dest: String) {
        let n = Self.copyAddOnContent(from: workDir + "/aoc", to: dest + "/aoc")
        if n > 0 { say(String(format: t("msg.aocCopied"), n)) }
    }

    /// Replace `to` with a copy of `from` when `from` exists. Returns how many entries `to` holds afterwards.
    nonisolated static func copyAddOnContent(from: String, to: String) -> Int {
        let fm = FileManager.default
        guard fm.fileExists(atPath: from) else { return 0 }
        try? fm.removeItem(atPath: to)
        try? fm.copyItem(atPath: from, toPath: to)
        return ((try? fm.contentsOfDirectory(atPath: to)) ?? []).count
    }

    /// Pack the extracted RomFS into one romfs.img. The extracted folder is
    /// <work>/extract/v<N>/RomFS where N is the profile's package version, so take
    /// the highest v* that actually has a RomFS instead of hardcoding one game.
    /// `then` continues the build with the archive's folder (installing on a device).
    private func packArchive(workDir: String, then: @escaping (String) -> Void) {
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
        let tid = Self.buildKey(basePath)
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
            placeAddOnContent(workDir: workDir, in: dest)
            return then(dest)
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
                placeAddOnContent(workDir: workDir, in: dest)
                archivePath = dest
                return then(dest)
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
                placeAddOnContent(workDir: workDir, in: dest)
                archivePath = dest
                return then(dest)
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
        let engine = EngineLayout.root(repoPath)
        p.arguments = [engine + "/" + Self.romfsImageTool, "--reuse", romfs, dest + "/romfs.img"]
        let romfsPy = p.executableURL!.path
        p.environment = ["PATH": Self.toolPath("/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin", python: romfsPy), "PYTHONPATH": engine + "/dm/tools"]
            .merging(BundledTools.environment(for: romfsPy)) { $1 }
        Self.inOwnGroup(p, python: p.executableURL!.path)
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        PipeReader.attach(to: pipe.fileHandleForReading) { [weak self] d in
            guard let s = String(data: d, encoding: .utf8) else { return }
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
                self.placeAddOnContent(workDir: workDir, in: dest)
            }
            if let i = self.stages.firstIndex(where: { $0.id == idx }) {
                self.stages[i].state = succeeded ? .done : .failed
                self.stages[i].detail = succeeded
                    ? String(format: self.t("prog.archiveDone"), dest)
                    : String(format: self.t("msg.archiveFailed"), st.terminationStatus)
            }
            if succeeded { return then(dest) }
            self.cleanupStaging()
            self.running = false
            self.done = false
            if cancelled { self.resetProgress() }
            self.doneNote = cancelled ? self.t("msg.stopped") : String(format: self.t("msg.archiveFailed"), st.terminationStatus)
        }}
        proc = p
        do { try p.run(); Self.track(p) } catch {
            if let i = stages.firstIndex(where: { $0.id == idx }) {
                stages[i].state = .failed; stages[i].detail = t("msg.archiveNoStart")
            }
            running = false; doneNote = t("msg.archiveNoStart"); cleanupStaging()
        }
    }

    // MARK: Installing on a device

    /// Steps 4 to 7 of the shared app (ShellInstall.swift) for a game whose framework is built and whose archive is packed: the
    /// shell's project, signing, the install over the app that is already there, and the game data the device lacks.
    func installShell(framework: String, titleID: String, name: String, archive: String, dataOnly: Bool = false) {
        running = true
        if dataOnly { failure = nil; done = false; doneNote = "" }
        shellRetry = (framework, titleID, name, archive)
        let python = pythonPath.isEmpty ? Self.findPython().path : pythonPath
        let root = shellRoot
        var installer = ShellInstaller(xcrun: xcrunPath, repo: repoPath, python: python, root: root, device: installDevice, team: signingTeam)
        installer.deviceName = deviceName(installDevice)
        installer.lang = lang
        installer.ownGroup = true
        installer.toolPath = Self.toolPath("/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", python: python)
        installer.log = { s in DispatchQueue.main.async { self.append(s) } }
        installer.stage = { s in DispatchQueue.main.async {
            if let i = self.stages.firstIndex(where: { $0.id == s.id }) {
                self.stages[i].name = s.name; self.stages[i].state = s.state; self.stages[i].detail = s.detail
                if let percent = s.percent { self.stages[i].percent = percent }
                if s.state == .running, self.stages[i].started == nil { self.stages[i].started = Date() }
            } else {
                self.stages.append(Stage(id: s.id, name: s.name, state: s.state, detail: s.detail, percent: s.percent,
                                         started: s.state == .running ? Date() : nil))
            }
        } }
        installer.processStarted = { p in DispatchQueue.main.async { self.proc = p; Self.track(p) } }
        installer.processEnded = { p in Self.untrack(p) }
        // The size and the connection are shown with Continue, "Wait for a cable" and "Not now" (ShellCopyCard)
        installer.decideCopy = { plan in
            let answered = DispatchSemaphore(value: 0)
            var answer = ShellCopyDecision.skip
            DispatchQueue.main.async {
                self.shellWaitCancelled.set(false)
                self.shellCopyAnswer = { answer = $0; answered.signal() }
                self.shellCopy = plan
            }
            answered.wait()
            return answer
        }
        installer.waiting = { on in DispatchQueue.main.async { self.shellWaiting = on } }
        installer.waitCancelled = { self.shellWaitCancelled.value }
        let device = installDevice
        DispatchQueue.global(qos: .userInitiated).async {
            let result = dataOnly ? installer.installData(titleID: titleID, archive: archive)
                                  : installer.install(framework: framework, titleID: titleID, name: name, archive: archive)
            DispatchQueue.main.async {
                self.shellCopy = nil; self.shellWaiting = false
                if self.stopping {
                    self.stopping = false; self.running = false
                    self.resetProgress(); self.doneNote = self.t("msg.stopped"); self.cleanupStaging()
                    return
                }
                guard result.ok else {
                    self.finishInstall(result.message)
                    if let kind = result.failure { self.failure = BuildFailure(kind: kind, gameName: nil) }
                    else if let step = result.step { self.noteInstallFailure(step, error: result.message) }
                    return
                }
                self.installedOn = device
                self.installedAppPath = result.appPath
                self.finishInstall(nil, note: result.message)
            }
        }
    }

    /// What the player picked on the copy card (Continue, wait for a cable, not now), handed to the install waiting for it.
    func answerShellCopy(_ decision: ShellCopyDecision) {
        guard let answer = shellCopyAnswer else { return }
        shellCopyAnswer = nil
        shellCopy = nil
        answer(decision)
    }

    /// "Stop waiting" while the install waits for a cable: the poll ends at its next look and the game data stays for later.
    func cancelShellWait() { shellWaitCancelled.set(true) }

    /// Retry after game data that went over in part: only the data step runs again (listing, diff, copy).
    func retryShellData() {
        guard !running, let r = shellRetry else { return }
        installShell(framework: r.framework, titleID: r.titleID, name: r.name, archive: r.archive, dataOnly: true)
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

    /// Renew the shared app's signature (a free Apple ID's profile lasts 7 days). The same xcodebuild parameters as
    /// the install, run on the cached project and derived data: Xcode reuses the compiled products and only signs
    /// again, then devicectl installs the app over itself. PRODUCT_BUNDLE_IDENTIFIER is the one shell.json holds, so the
    /// device keeps the app's Documents (game data, saves).
    func resignOnDevice(app: String, device: String, then: (() -> Void)? = nil) {
        guard !device.isEmpty, !app.isEmpty else { then?(); return }
        guard !signingTeam.isEmpty else {
            doneNote = t("dev.resignNoTeam")
            then?(); return
        }
        // An app from before the shared app has its own project and cannot be signed again here: build the game again
        guard let shell = ShellInstall.paths(ofApp: app) else {
            doneNote = t("dev.resignOlder")
            then?(); return
        }
        guard FileManager.default.fileExists(atPath: shell.project) else {
            doneNote = String(format: t("dev.resignNoProject"), shortPath(shell.project))
            then?(); return
        }
        let xcrun = xcrunPath, team = signingTeam, name = deviceName(device)
        let bundle = ShellLibrary.load(root: shell.root).bundleID
        running = true
        // The shared app is signed again under the identifier shell.json holds, so the device keeps its Documents
        let command = ShellInstall.buildCommand(xcrun: xcrun, root: shell.root, device: device, team: team, bundleID: bundle)
        runTool(id: 1006, name: String(format: t("dev.resignStage"), name),
                command, step: Self.xcodeStep) { error in
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
        PipeReader.attach(to: pipe.fileHandleForReading) { [weak self] d in
            guard let chunk = String(data: d, encoding: .utf8) else { return }
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
        var warning = false  // present, but with a caveat the row's error and hint lines explain (the Metal compiler is not the tested one)
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

    /// The Python that actually has lz4/capstone/fontTools/zbic/backports.zstd — the one
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

    /// The interpreter probe: lz4 / capstone / fontTools / zbic always, and zstd from either source —
    /// `compression.zstd` is built in from Python 3.14 and `backports.zstd` (which declares
    /// Python < 3.14) is the only option before that. Requiring the backport unconditionally
    /// rejected an otherwise working Homebrew Python 3.15 (issue #1).
    /// zbic is required although only a game with system 22.0.0+ modules (ZBIC segments, Nintendo's zstd variant) needs it:
    /// the launcher cannot know that before the extraction, and the build stops late without it (issue #251).
    /// nsz is deliberately not required here: it is only needed for NSZ / XCZ dumps, and the
    /// pipeline says so by name when one shows up. The venv installs it anyway so that a player
    /// who downloads a compressed dump never meets that error.
    nonisolated static let importProbe = """
        import lz4, capstone, fontTools, zbic
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

    /// Where uv keeps the Pythons it installs (`uv python install`): the shims in `~/.local/bin`
    /// and the store the real binaries live in, which `UV_PYTHON_INSTALL_DIR` moves. A uv user
    /// often has neither python.org's framework nor Homebrew, and a GUI launch's PATH is
    /// /usr/bin:/bin:/usr/sbin:/sbin, so neither `which` nor the locations below see them: a
    /// working uv Python 3.12 was reported as "No Python 3.12 or newer found". Injectable so a
    /// test can point them at a scratch tree.
    nonisolated static var uvShimDir = NSHomeDirectory() + "/.local/bin"
    nonisolated static var uvPythonRoot: String = {
        let dir = ProcessInfo.processInfo.environment["UV_PYTHON_INSTALL_DIR"] ?? ""
        return dir.isEmpty ? NSHomeDirectory() + "/.local/share/uv/python" : dir
    }()

    /// Where mise and asdf keep the Pythons they install, and mise's shims. `MISE_DATA_DIR` and
    /// `ASDF_DATA_DIR` move them. A GUI launch's PATH does not include the shims directory, so a
    /// Python managed by either was not found at all (issue #113). Injectable for tests.
    nonisolated static var miseDataDir: String = {
        let dir = ProcessInfo.processInfo.environment["MISE_DATA_DIR"] ?? ""
        return dir.isEmpty ? NSHomeDirectory() + "/.local/share/mise" : dir
    }()
    nonisolated static var asdfDataDir: String = {
        let dir = ProcessInfo.processInfo.environment["ASDF_DATA_DIR"] ?? ""
        return dir.isEmpty ? NSHomeDirectory() + "/.asdf" : dir
    }()

    nonisolated static func importsOK(_ py: String) -> Bool {
        runOK(py, ["-c", importProbe], env: ProcessInfo.processInfo.environment.merging(BundledTools.environment(for: py)) { $1 })
    }

    /// backports.zstd declares Python < 3.14, so it is only installed where it is needed.
    /// nsz is always installed: NSZ / XCZ dumps are accepted by the pipeline now, and a player who
    /// downloads one should not have to run pip by hand (it is a few hundred KB).
    nonisolated static func pipPackages(_ version: (Int, Int)) -> [String] {
        version < (3, 14) ? ["lz4", "capstone", "fonttools", "zbic", "backports.zstd", "nsz"]
                          : ["lz4", "capstone", "fonttools", "zbic", "nsz"]
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
        // An existing venv below minPython (built from Apple's 3.9 by an older app, issue #75) is
        // moved aside and rebuilt: pip into it would "succeed" and the build would still fail.
        // Moved, never deleted, because the folder is the user's. Only when a usable base exists,
        // so a Mac with no new Python keeps its old venv instead of losing it for nothing.
        if FileManager.default.isExecutableFile(atPath: vpy), pythonVersion(vpy).map({ $0 < minPython }) ?? true {
            guard let interp = venvBase(preferred: base), interp != vpy else {
                return (false, log + "\(venvDir) is older than Python \(minPython.0).\(minPython.1) and no newer Python was found to rebuild it from\n")
            }
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let aside = venvDir + ".old-" + stamp
            do { try FileManager.default.moveItem(atPath: venvDir, toPath: aside) } catch {
                return (false, log + "could not move \(venvDir) aside: \(error.localizedDescription)\n")
            }
            log += "moved the old venv (Python below \(minPython.0).\(minPython.1)) to \(aside)\n"
        }
        if !FileManager.default.isExecutableFile(atPath: vpy) {
            // findPython() returns the venv path it hopes to create when no interpreter was
            // found, and the panel hands that to this function. It cannot be a base: `-m venv`
            // failed with "could not start …" and the Python row never recovered.
            guard let interp = venvBase(preferred: base) else {
                return (false, log + "no Python \(minPython.0).\(minPython.1) or newer to create \(venvDir) from\n")
            }
            if interp != base { log += "\(base) is not a usable interpreter; using \(interp)\n" }
            log += "$ \(interp) -m venv \(venvDir)\n"
            try? FileManager.default.createDirectory(atPath: (venvDir as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            guard run(interp, ["-m", "venv", venvDir]) else { return (false, log + "venv creation failed\n") }
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

    /// The interpreter to create the venv from. `preferred` is what the panel picked; when
    /// findPython() found nothing that is the venv path it hopes to create, which cannot be a
    /// base (see makeVenv). So a base that does not run at the required version falls back to
    /// the newest candidate that does. nil when this Mac has no such interpreter at all.
    nonisolated static func venvBase(preferred: String) -> String? {
        if FileManager.default.isExecutableFile(atPath: preferred),
           let v = pythonVersion(preferred), v >= minPython {
            return preferred
        }
        return pythonCandidates().first {
            FileManager.default.isExecutableFile(atPath: $0)
                && (pythonVersion($0).map { $0 >= minPython } ?? false)
        }
    }

    /// The `python3` / `python3.x` names in a directory, newest version first.
    nonisolated static func pythonNames(in dir: String, matching pattern: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return names.filter { $0.range(of: pattern, options: .regularExpression) != nil }
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
    }

    /// uv's managed Pythons: the shims in `uvShimDir` and every install under `uvPythonRoot`
    /// (`cpython-3.12.13-macos-aarch64-none/bin/python3.12`). A uv user often has neither
    /// python.org's framework nor Homebrew, and a GUI launch's PATH does not contain
    /// `~/.local/bin`, so nothing else on this Mac finds them.
    nonisolated static func uvPythonCandidates() -> [String] {
        var out = pythonNames(in: uvShimDir, matching: #"^python3(\.\d+)?$"#).map { uvShimDir + "/" + $0 }
        let installs = (try? FileManager.default.contentsOfDirectory(atPath: uvPythonRoot)) ?? []
        for d in installs.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
            let bin = uvPythonRoot + "/" + d + "/bin"
            out += pythonNames(in: bin, matching: #"^python3(\.\d+)?$"#).map { bin + "/" + $0 }
        }
        return out
    }

    /// Pythons managed by mise (installs, then its shims) and asdf (installs only: an asdf shim is
    /// a script that needs `asdf` on the PATH, which a GUI launch lacks). Only the interpreter
    /// names are taken, never `python3-config` and the other files that share the folder.
    nonisolated static func versionManagerPythonCandidates() -> [String] {
        var out: [String] = []
        let strict = #"^python3(\.\d+)?$"#
        for root in [miseDataDir + "/installs/python", asdfDataDir + "/installs/python"] {
            let installs = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
            for d in installs.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
                let bin = root + "/" + d + "/bin"
                out += pythonNames(in: bin, matching: strict).map { bin + "/" + $0 }
            }
        }
        let shims = miseDataDir + "/shims"
        out += pythonNames(in: shims, matching: strict).map { shims + "/" + $0 }
        return out
    }

    /// Every interpreter a build could run under, best first: python.org's framework, Homebrew,
    /// /usr/local, uv's store, mise and asdf, then whatever `which` can see. Probed by hand because a GUI app
    /// does not inherit the shell's PATH — the same reason .NET (in ~/.dotnet) used to show as
    /// missing while a terminal saw it.
    nonisolated static func pythonCandidates() -> [String] {
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
            cands += pythonNames(in: dir, matching: #"^python3\.\d+$"#).map { dir + "/" + $0 }
        }
        cands += uvPythonCandidates()
        cands += versionManagerPythonCandidates()
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

    /// Every python3 on this Mac, newest-looking first, each tried for a usable version and the
    /// packages. Returns the one to build with, plus why the others were rejected for the message.
    nonisolated static func findPython(resources: URL? = BundledTools.resources) -> (path: String, ok: Bool) {
        // The release app's own Python (BundledTools.swift) has every package and is the one the build is tested with: it wins over
        // any Python on this Mac and needs no venv. One that does not run (a damaged copy) falls through to the search below
        // (uv's Pythons, the other candidates, then the venv).
        if let bundled = BundledTools.python(in: resources), pythonVersion(bundled).map({ $0 >= minPython }) == true, importsOK(bundled) {
            return (bundled, true)
        }
        var seen = Set<String>()
        var fallback: (String, (Int, Int))? = nil   // newest with an acceptable version but no packages
        for c in pythonCandidates() where !c.isEmpty && seen.insert(c).inserted {
            guard FileManager.default.isExecutableFile(atPath: c), let v = pythonVersion(c) else { continue }
            guard v >= minPython else { continue }
            if importsOK(c) { return (c, true) }
            if fallback == nil || v > fallback!.1 { fallback = (c, v) }
        }
        // No system interpreter has the packages: the venv (existing, or created by 安装) is next.
        let vpy = venvPython()
        // A venv below minPython is not ready however complete its packages are: an older app
        // version made it from Apple's 3.9, and the build script refuses that (issue #75). It
        // falls through to the candidates above, or to the row saying the Python is too old.
        if FileManager.default.isExecutableFile(atPath: vpy), let v = pythonVersion(vpy), v >= minPython {
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

    /// One admin prompt runs both steps: switch the toolchain to this Xcode, then let it finish its first launch (license and
    /// components) - a fresh App Store download has neither. The Xcode row and the failure card run the same command.
    nonisolated static func selectXcodeCmd(_ xcode: String) -> [String] {
        let script = "xcode-select -s '" + xcode + "/Contents/Developer' && xcodebuild -runFirstLaunch"
        let apple = "do shell script \"" + script.replacingOccurrences(of: "\"", with: "\\\"") + "\" with administrator privileges"
        return ["/usr/bin/osascript", "-e", apple]
    }

    /// Whether the xcode row asks for the iOS SDK. Always, as before, unless the guided setup stored a Mac-only choice
    /// and builds are for the Mac: upstream no longer needs the iOS SDK for a Mac build (c464cb24).
    nonisolated static func needsIOSPlatform(defaults: UserDefaults = .standard) -> Bool {
        if OnboardingDefaults.sessionPlatform == "mac" { return false }   // a forced run's choice, not stored yet
        guard defaults.string(forKey: OnboardingDefaults.platform) == "mac" else { return true }
        return BuildTarget.normalized(defaults.string(forKey: "buildTarget")) != BuildTarget.mac
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

    /// First line of a tool's output (the Metal compiler's version line), nil when it does not run or says nothing.
    nonisolated static func firstOutputLine(_ tool: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out; p.standardError = Pipe(); p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init)
    }

    /// The Metal toolchain row. A compiler that does not run is the missing-toolchain row with its install button. One that differs from the
    /// lock's pin is a warning and not a blocker: the row stays present, and its error and hint lines (the install failures' fields) say that
    /// NVN games will stop. Pure over its inputs, so tests give it version strings.
    nonisolated static func metalDep(runs: Bool, lock: String?, now: [String: String?], needsIOS: Bool) -> Dep {
        var dep = Dep(id: "metal", name: "dep.metal", hint: "dep.metal.hint", present: runs, installCmd: metalToolchainCmd)
        guard runs, let lock, let m = MetalPin.mismatches(lock: lock, now: now, iOS: needsIOS).first else { return dep }
        dep.warning = true
        dep.detail = "dep.metal.other:" + m.now + ":" + m.pinned
        dep.lastError = "metal_" + m.sdk + ": " + m.now
        dep.fixHint = "dep.fix.metalPin"
        return dep
    }

    nonisolated static func detectDepsSync(needsIOS: Bool = BuildModel.needsIOSPlatform(), repo: String = "") -> [Dep] {
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
            out.append(Dep(id: "xcode", name: "dep.xcode", hint: "dep.xcode.hint", present: false,
                           detail: "dep.xcode.notSelected", actionLabel: "dep.xcode.fix",
                           installCmd: selectXcodeCmd(xcode)))
        case .notInstalled:
            out.append(Dep(id: "xcode", name: "dep.xcode", hint: "dep.xcode.hint", present: false, installCmd: []))
        }

        let macMetal = firstOutputLine("/usr/bin/xcrun", ["-sdk", "macosx", "metal", "--version"])
        let lock = repo.isEmpty ? nil : try? String(contentsOfFile: EngineLayout.root(repo) + "/" + MetalPin.lockPath, encoding: .utf8)
        let iosMetal = needsIOS && lock != nil ? firstOutputLine("/usr/bin/xcrun", ["-sdk", "iphoneos", "metal", "--version"]) : nil
        out.append(metalDep(runs: macMetal != nil, lock: lock, now: ["macosx": macMetal, "iphoneos": iosMetal], needsIOS: needsIOS))

        out += toolDeps(resources: BundledTools.resources,
                        installed: { firstExisting(["/opt/homebrew/bin/\($0)", "/usr/local/bin/\($0)"]) },
                        brew: firstExisting(["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]))

        let (dn, dnOK) = findDotnet()
        out.append(Dep(id: "dotnet", name: "dep.dotnet", hint: "dep.dotnet.hint",
                       present: dnOK, detail: dnOK ? dn : "dep.dotnet.missing",
                       installCmd: ["/bin/bash", "-c",
                         "curl -sSL https://dot.net/v1/dotnet-install.sh -o /tmp/di.sh && chmod +x /tmp/di.sh && /tmp/di.sh --channel 10.0 --install-dir $HOME/.dotnet"]))

        let (py, pyOK) = findPython()
        // A too-old interpreter is a different problem from a missing package: say which one it is,
        // because the fix differs (install a newer Python vs pip install into this one).
        // A version we cannot read means no interpreter ran at all (py is then the venv
        // that does not exist yet), which is not the same as one that is too old.
        let pyDetail = pythonDetail(py: py, ok: pyOK)
        out.append(Dep(id: "python", name: "dep.python", hint: "dep.python.hint",
                       present: pyOK, detail: pyDetail,
                       installCmd: [py, "-m", "pip", "install", "--user", "lz4", "capstone", "fonttools", "zbic", "backports.zstd"]))
        return out
    }

    nonisolated static func pythonDetail(py: String, ok: Bool) -> String {
        let pyVer = pythonVersion(py).map { "\($0.0).\($0.1)" } ?? "?"
        let minVer = "\(minPython.0).\(minPython.1)"
        return ok ? (py == BundledTools.python() ? "dep.bundled" : py)
            : pythonVersion(py).map { $0 >= minPython
                ? "dep.python.missing:\(py) (\(pyVer))"
                : "dep.python.old:\(pyVer):\(minVer)" }
            ?? "dep.python.notFound:\(minVer):\(minVer)"
    }

    func checkDeps() {
        depsChecked = false
        DispatchQueue.global(qos: .userInitiated).async {
            let d = Self.detectDepsSync(repo: self.repoPath)
            Self.writeDepsReport(d)
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

    /// Write what the panel just decided beside library.json (`deps-check.txt`).
    ///
    /// The panel is the only place those verdicts appear, so "it says Python is missing" cannot be
    /// checked afterwards: the interpreter that was tried, and the environment a Finder launch
    /// gives the app (its PATH is /usr/bin:/bin:/usr/sbin:/sbin, unlike the terminal's), are both
    /// invisible in a bug report. This file has them — paths and versions only, never key material.
    nonisolated static func writeDepsReport(_ deps: [Dep]) {
        let dir = (venvDir as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var out = "NX2Apple \(appVersion) dependency check\n"
        out += "date: \(ISO8601DateFormatter().string(from: Date()))\n"
        out += "HOME: \(NSHomeDirectory())\n"
        out += "PATH: \(ProcessInfo.processInfo.environment["PATH"] ?? "(unset)")\n"
        let chosen = findPython()
        let bundled = BundledTools.python()
        out += "python chosen: \(chosen.path) (\(chosen.ok ? "ok" : "not usable")\(chosen.path == bundled ? ", bundled with the app" : ""))\n"
        out += "bundled python: \(bundled ?? "(none: not the release app)")\n"
        out += "python candidates (after the bundled one, in search order):\n"
        for c in pythonCandidates() { out += "  \(c)\n" }
        out += "rows:\n"
        for d in deps { out += "  \(d.id): \(d.present ? "ok" : "MISSING") \(d.detail)\n" }
        try? out.write(toFile: dir + "/deps-check.txt", atomically: true, encoding: .utf8)
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
            PipeReader.attach(to: h) { d in
                if let s = String(data: d, encoding: .utf8) {
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
    @EnvironmentObject var loc: Localizer
    @ObservedObject var library: GameLibrary
    var settings = false
    var onViewGame: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    var onChooseLibraryFolder: () -> Void = {}
    var onOpenControls: () -> Void = {}
    var onOpenControllers: () -> Void = {}   // the Controllers sheet (the console mode's list, with the player-mode setting)
    var onRunSetup: (() -> Void)?   // the guided first-run setup, again (nil where there is none)
    var controlChanges = 0
    var padMerge: Binding<Bool> = .constant(false)   // "All controllers are player 1" (ControlLayout.padMerge)
    @AppStorage(ConsolePrompt.defaultsKey) private var consolePromptOn = true   // ConsoleCoordinator.swift
    @AppStorage(BuildNotice.defaultsKey) private var notifyBuilds = true   // BuildNotifications.swift
    @AppStorage(ReturnAfterPlay.defaultsKey) private var returnAfterPlay = true   // ReturnAfterPlay.swift
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
        .modifier(GameFilesDrop(enabled: !settings && !m.running, label: loc.t("drop.hint")) { m.take(dropped: $0) })   // DropFiles.swift
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
    /// the title (with a disclosure chevron beside it when `open` is given), a secondary detail, and its controls.
    /// Its buttons and dropdowns are all LauncherControl.width wide, so they line up in one column across the cards.
    private func row<Trailing: View>(_ title: String, detail: String = "", detail2: String = "", dot: Color? = nil, help: String = "", open: Bool? = nil,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            Circle().fill(dot ?? .clear).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.manrope(14)).fixedSize(horizontal: false, vertical: true)
                    if let open {
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(open ? 90 : 0))
                    }
                }
                if !detail.isEmpty {
                    // A path is technical text: the system's monospaced face, on one line, cut in the middle when
                    // too long. Everything else is prose in Manrope and wraps, so no word is ever cut.
                    if detail.hasPrefix("/") || detail.hasPrefix("~") {
                        Text(detail).font(.mono(12)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).help(help.isEmpty ? detail : help)
                    } else {
                        Text(detail).font(.manrope(12.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true).help(help.isEmpty ? detail : help)
                    }
                }
                if !detail2.isEmpty {
                    Text(detail2).font(.mono(12)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(detail2)
                }
            }
            Spacer(minLength: 12)
            trailing().launcherRowControls()
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
        pageHeading(loc.t("build.heading"), note: loc.t("build.intro"))
        if !m.repoOK || !m.allDepsPresent {
            group(loc.t("section.setup")) {
                row(loc.t("library.setupHint"), dot: LauncherPalette.building) {
                    Button(loc.t("build.setup"), action: onOpenSettings)
                }
            }
        }
        files.disabled(m.running)
        target
        if m.target != BuildTarget.mac { install.disabled(m.running) }
        logPanel
        action
        ShellCopyCard(m: m)
        BuildFailureCard(m: m)
        outcome
        progress
    }

    /// Where an iPhone build goes: exported as an IPA (as before), or signed and installed on a paired device.
    private var install: some View {
        let devices = [(value: "", label: loc.t("dev.none"))] + m.devices.map { d in
            (value: d.id, label: d.name + (d.reachable ? "" : " (" + loc.t("dev.notConnected") + ")"))
        }
        let teams = m.teams.map { (value: $0.id, label: $0.label(personalTeam: loc.t("dev.personalTeam"))) }
        let needsCertificate = m.teams.first { $0.id == m.signingTeam }.map { !$0.hasCertificate } ?? false
        return group(loc.t("dev.section"), footnote: m.installDevice.isEmpty ? "" : (needsCertificate ? loc.t("dev.teamNoCert") + " " : "") + loc.t("dev.note")) {
            row(loc.t("dev.target"), detail: m.devicesChecked && m.devices.isEmpty ? loc.t("dev.noDevices") : "") {
                if !m.devicesChecked { ProgressView().controlSize(.small) }
                Button(loc.t("dev.refresh")) { m.refreshDevices() }.buttonStyle(.plain).font(.manrope(13)).foregroundStyle(.secondary)
                LauncherDropdown(options: devices, selection: m.installDevice, label: loc.t("dev.target")) { m.installDevice = $0 }
            }
            if !m.installDevice.isEmpty {
                divider
                if teams.isEmpty {
                    row(loc.t("dev.team"), detail: loc.t("dev.noTeam"), dot: LauncherPalette.building) { EmptyView() }
                } else {
                    row(loc.t("dev.team")) {
                        LauncherDropdown(options: teams, selection: m.signingTeam, label: loc.t("dev.team")) { m.signingTeam = $0 }
                    }
                }
            }
        }
        .onAppear { if !m.devicesChecked { m.refreshDevices() } }
    }

    private var files: some View {
        // The report's own mistake, and a reasonable one: the output folder silently decides where
        // the build cache lives, so changing it threw away a finished build. Say it under Save to, all the time.
        group(loc.t("section.files"), footnote: loc.t("msg.workdirHint")) {
            Button(action: pickFolder) {
                row(loc.t(m.gameDir.isEmpty ? "build.folderCTA" : "build.folderSelected"),
                    detail: m.gameDir.isEmpty ? loc.t("build.folderNote") : m.shortPath(m.gameDir), help: m.gameDir) {
                    Text(loc.t(m.gameDir.isEmpty ? "data.choose" : "data.change"))
                        .font(.manrope(13, .semibold)).foregroundStyle(.black)
                        .launcherRowControlFrame()
                        .background(LauncherPalette.cream, in: Capsule())
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            ForEach(m.slots.filter { !$0.optional }, id: \.id) { s in
                divider; slotRow(s)
                if s.id == "keys", let keyCheck { KeyCheckLine(outcome: keyCheck, t: loc.t) }
            }
            divider
            disclosure(loc.t("build.options"), isOpen: extrasOpen) { extrasOpen.toggle() }
            if extrasOpen {
                ForEach(m.slots.filter(\.optional), id: \.id) { s in divider; slotRow(s) }
            }
            divider
            row(loc.t("build.saveTo"), detail: m.outDir.isEmpty ? loc.t("build.saveDefault") : m.shortPath(m.outDir), help: m.outDir) {
                Button(loc.t("data.change")) { m.chooseBuildFolder() }
            }
        }
        .task(id: KeyCheck.Inputs(keys: m.keysPath, files: [m.basePath, m.updatePath] + m.dlcPaths)) {
            keyCheck = await KeyCheck.runDetached(KeyCheck.Inputs(keys: m.keysPath, files: [m.basePath, m.updatePath] + m.dlcPaths))
        }
    }

    private func slotRow(_ s: Slot) -> some View {
        // An empty prod.keys row says where the file comes from.
        row(loc.t(s.title), detail: s.id == "keys" && s.paths.isEmpty ? loc.t("build.keyHint") : s.summary(loc.t), dot: s.ok ? LauncherPalette.ready : LauncherPalette.unbuilt,
            help: s.paths.joined(separator: "\n")) {
            if !s.paths.isEmpty {
                Button(loc.t("data.clear")) { m.clear(s.id) }.buttonStyle(.plain)
                    .font(.manrope(13)).foregroundStyle(.secondary)
            }
            Button(s.paths.isEmpty ? loc.t("data.choose") : loc.t("data.change")) { m.pickFiles(kind: s.kind) }
        }
    }

    private func pickFolder() {
        let d = NSOpenPanel()
        d.canChooseDirectories = true; d.canChooseFiles = false
        if d.runModal() == .OK, let u = d.url { m.scan(folder: u.path) }
    }

    private var target: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(loc.t("section.target")).font(.manrope(15, .semibold)).foregroundStyle(.secondary)
                .padding(.leading, 2)
            HStack(spacing: 14) {
                targetCard(BuildTarget.mac, symbol: "desktopcomputer", title: "build.mac", note: "build.macNote")
                targetCard(BuildTarget.ios, symbol: "iphone", title: "build.ios", note: "build.iosNote")
            }
            // A Mac app runs on this Mac's GPU, which always decodes BC textures: the switch is the iPhone's only.
            if m.target != BuildTarget.mac {
                VStack(spacing: 0) {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(loc.t("opt.bc")).font(.manrope(14))
                            Text(loc.t("opt.bc.note")).font(.manrope(12.5)).foregroundStyle(.secondary)
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
                    Text(loc.t(title)).font(.manrope(16, .semibold))
                    Text(loc.t(note)).font(.manrope(12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
        if m.done && m.target == BuildTarget.mac {
            group(loc.t("section.done")) {
                row(loc.t("library.ready"), detail: m.shortPath(m.macAppPath), dot: LauncherPalette.ready, help: m.macAppPath) {
                    Button(loc.t("install.reveal")) { reveal(m.macAppPath) }
                    Button(loc.t("build.showLibrary"), action: onViewGame)
                }
            }
        }
        if m.done && !m.installedOn.isEmpty {
            group(String(format: loc.t("dev.installed"), m.deviceName(m.installedOn))) {
                row(loc.t("dev.installedNote"), dot: LauncherPalette.ready) {
                    Button(String(format: loc.t("dev.open"), m.deviceName(m.installedOn))) {
                        m.openOnDevice(udid: m.installedOn, app: m.installedAppPath) { error in if let error { m.doneNote = error } }
                    }
                }
                // The game files were copied (or, after a skipped transfer, await a manual copy — a
                // fast external drive handed to the device is quicker than USB): show where they are.
                if !m.archivePath.isEmpty {
                    divider
                    row(loc.t("dev.gameData"), detail: m.shortPath(m.archivePath), dot: LauncherPalette.ready, help: m.archivePath) {
                        Button(loc.t("install.reveal")) { reveal(m.archivePath) }
                    }
                }
            }
        }
    }

    /// The script's own stages once a build has run, and its log behind a disclosure.
    @ViewBuilder private var progress: some View {
        if m.running || !m.stages.isEmpty {
            group(loc.t("section.progress")) {
                ForEach(Array(m.stages.enumerated()), id: \.element.id) { index, s in
                    if index > 0 { divider }
                    HStack(spacing: 12) {
                        if s.state == .running { ProgressView().controlSize(.small).frame(width: 14) }
                        else { Circle().fill(s.state.color).frame(width: 7, height: 7).frame(width: 14) }
                        Text(s.name).font(.manrope(14)).lineLimit(1)
                        Spacer(minLength: 12)
                        if s.state == .running {
                            TimelineView(.periodic(from: Date(), by: 1)) { context in
                                Text([s.detail, s.clock(at: context.date, left: loc.t("prog.eta"))].filter { !$0.isEmpty }.joined(separator: " · "))
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
                    row(loc.t("library.preparing")) { ProgressView().controlSize(.small) }
                }
            }
        }
    }

    /// The build log, right under the Mac / iPhone choice and folded away until it is asked for.
    /// It used to sit at the bottom of the progress card, which is where a failed build's message
    /// pointed ("see the log below") while the log itself was out of view on a short window (#52).
    @ViewBuilder private var logPanel: some View {
        group(loc.t("section.log")) {
            if m.shellCopy != nil || m.shellWaiting {
                // The log below is the build's own output; the data transfer is driven by the app, so
                // its questions and errors (a locked device, a failed listing) answer here, not in it.
                Text(loc.t("log.transferNote")).font(.manrope(12.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 14).padding(.top, 2)
            }
            disclosure(loc.t("build.log"), isOpen: logOpen) { logOpen.toggle() }
            if logOpen { logView.padding(.horizontal, 14).padding(.bottom, 14) }
        }
        .onReceive(BuildNotifier.shared.$showLog) { show in   // a clicked notification of a failed build
            if show { logOpen = true; DispatchQueue.main.async { BuildNotifier.shared.showLog = false } }
        }
    }

    private var logView: some View {
        BuildLogView(log: m.log,placeholder: loc.t("log.placeholder"))
    }

    /// The page's conclusion, at the end of its column: what is still missing, and the button.
    private var action: some View {
        HStack(spacing: 18) {
            statusText
            Spacer(minLength: 12)
            Button {
                m.running ? m.stop() : m.startBuild()
            } label: {
                Label(m.running ? loc.t(m.stopping ? "library.stopping" : "btn.stop") : (m.done ? loc.t("btn.rebuild") : loc.t("build.startGame")),
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
        .staleFrameworksPrompt(m)
    }

    @ViewBuilder private var statusText: some View {
        if !m.doneNote.isEmpty {
            Text(m.doneNote).font(.manrope(13))
                .foregroundStyle(m.done ? LauncherPalette.ready : LauncherPalette.building).lineLimit(2)
        } else if !m.depsChecked {
            Text(loc.t("status.checkingDeps")).font(.manrope(13)).foregroundStyle(.secondary)
        } else if !m.allDepsPresent {
            Text(loc.t("status.installFirst")).font(.manrope(13)).foregroundStyle(LauncherPalette.building)
        } else if !m.repoOK {
            Text(loc.t("status.chooseRepo")).font(.manrope(13)).foregroundStyle(LauncherPalette.building)
        } else if !m.slot("base").ok || !m.slot("keys").ok {
            Text(loc.t("status.needInputs")).font(.manrope(13)).foregroundStyle(.secondary)
        } else {
            Text(String(format: loc.t("status.output"), m.shortPath(m.outDir.isEmpty ? (m.basePath as NSString).deletingLastPathComponent : m.outDir)))
                .font(.manrope(13)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
        }
    }

    // ---- Settings ----

    @ViewBuilder private var settingsPage: some View {
        pageHeading(loc.t("settings.heading"), note: loc.t("settings.note"))
        settingsCards
    }

    @ViewBuilder private var settingsCards: some View {
        group(loc.t("section.library"), footnote: loc.t("library.folderHint")) {
            row(loc.t("library.folderTitle"), detail: library.folder.isEmpty ? loc.t("library.folderUnset") : m.shortPath(library.folder),
                dot: library.folder.isEmpty ? LauncherPalette.unbuilt : LauncherPalette.ready, help: library.folder) {
                if library.scanning { ProgressView().controlSize(.small) }
                if !library.folder.isEmpty {
                    Button(loc.t("library.rescan")) { library.discover() }.disabled(library.scanning)
                        .padTarget("set.rescan", scope: "main") { if !library.scanning { library.discover() } }
                }
                Button(loc.t("library.chooseFolder"), action: onChooseLibraryFolder)
                    .padTarget("set.folder", scope: "main") { onChooseLibraryFolder() }
            }
        }
        group(loc.t("section.controls"), footnote: loc.t("controls.settingsHint")) {
            row(loc.t("controls.row"), detail: controlChanges == 0 ? loc.t("controls.defaultLayout") : String(format: loc.t("controls.changes"), controlChanges)) {
                Button(loc.t("controls.customize"), action: onOpenControls)
                    .padTarget("set.controls", scope: "main") { onOpenControls() }
            }
            divider
            row(loc.t("console.mergeAll"), detail: loc.t("console.mergeNote")) {
                Toggle("", isOn: padMerge).labelsHidden().toggleStyle(LauncherSwitchStyle())
                    .padTarget("set.padMerge", scope: "main") { padMerge.wrappedValue.toggle() }
            }
            divider
            row(loc.t("console.controllers"), detail: loc.t("console.controllersRowNote")) {
                Button(loc.t("console.controllersOpen"), action: onOpenControllers)
                    .padTarget("set.controllers", scope: "main") { onOpenControllers() }
            }
            divider
            row(loc.t("console.promptSetting"), detail: loc.t("console.promptSettingNote")) {
                Toggle("", isOn: $consolePromptOn).labelsHidden().toggleStyle(LauncherSwitchStyle())
                    .padTarget("set.consolePrompt", scope: "main") { consolePromptOn.toggle() }
            }
        }
        tools
        group(loc.t("section.app"), footnote: m.appStatus) {
            // The interface language: the device default unless someone picks one here. Stored as
            // "" (follow), "zh", "en", "sv", "de" or "fr" so a later system-language change still applies.
            row(loc.t("settings.language"),
                detail: Lang.saved.map { loc.t("settings.language.\($0.rawValue)") }
                    ?? loc.t("settings.language.system"), dot: LauncherPalette.ready, help: "") {
                // The launcher's own list, drawn like the buttons beside it and as wide as they are.
                // The language names are in their own language (see "settings.language.*"), only "system" follows the UI.
                LauncherDropdown(options: Self.languageCodes.map { (value: $0, label: loc.t("settings.language." + ($0.isEmpty ? "system" : $0))) },
                                 selection: Lang.saved.map { $0.rawValue } ?? "", label: loc.t("settings.language"),
                                 style: .button) { v in
                    loc.choose(v)
                }
                .padTarget("set.language", scope: "main", activate: { cycleLanguage(1) }, adjust: { cycleLanguage($0) })
            }
            divider
            // Build notifications (BuildNotifications.swift): none without an app bundle, e.g. under swift run
            row(loc.t("settings.notify"), detail: loc.t(BuildNotice.hasBundleID ? "settings.notifyNote" : "settings.notifyUnbundled")) {
                Toggle("", isOn: $notifyBuilds).toggleStyle(LauncherSwitchStyle()).labelsHidden().disabled(!BuildNotice.hasBundleID)
                    .padTarget("set.notify", scope: "main") { notifyBuilds.toggle() }
            }
            divider
            if let onRunSetup {
                row(loc.t("settings.setup"), detail: loc.t("settings.setupNote")) {
                    Button(loc.t("settings.setupBtn"), action: onRunSetup)
                        .padTarget("set.setup", scope: "main") { onRunSetup() }
                }
                divider
            }
            // The launcher back in front when a game it started quits (ReturnAfterPlay.swift)
            row(loc.t("settings.returnAfterPlay"), detail: loc.t("settings.returnAfterPlayNote")) {
                Toggle("", isOn: $returnAfterPlay).toggleStyle(LauncherSwitchStyle()).labelsHidden()
                    .padTarget("set.returnAfterPlay", scope: "main") { returnAfterPlay.toggle() }
            }
            divider
            row("NX2Apple", detail: String(format: loc.t("app.version"), BuildModel.appVersion),
                dot: m.appStaged != nil ? LauncherPalette.ready : nil) {
                if m.appBusy { ProgressView().controlSize(.small) }
                if m.appStaged != nil {
                    // Downloaded and verified: it goes in when the app quits; this restarts into it now (not during a build)
                    Button(loc.t("app.restartNow")) { m.restartToUpdate() }.disabled(m.running)
                        .padTarget("set.appRestart", scope: "main") { if !m.running { m.restartToUpdate() } }
                } else if let u = m.appUpdate, m.appInstallability == .ok {
                    Button(String(format: loc.t("app.updateBtn"), u.tag)) { m.performAppUpdate() }.disabled(m.appBusy || m.running)
                        .padTarget("set.appUpdate", scope: "main") { if !(m.appBusy || m.running) { m.performAppUpdate() } }
                } else {
                    Button(loc.t("repo.check")) { m.checkAppUpdate() }.disabled(m.appBusy)
                        .padTarget("set.appCheck", scope: "main") { if !m.appBusy { m.checkAppUpdate() } }
                }
            }
            divider
            if m.appInstallability == .ok {
                // The uninstaller (Uninstall.swift): state folders and the launcher's own checkout go; the
                // games folder and prod.keys stay; the app itself goes to the Trash.
                row(loc.t("uninstall.title"), detail: loc.t("uninstall.note")) {
                    Button(loc.t("uninstall.button")) { m.uninstallPlan = uninstallPlan() }
                    .disabled(m.running)
                    .padTarget("set.uninstall", scope: "main") { if !m.running { m.uninstallPlan = uninstallPlan() } }
                }
                divider
            }
            // A launcher built from the repository never replaces itself (AppUpdate.installability): the switch says so and stays off
            row(loc.t("app.auto"), detail: loc.t(m.appInstallability == .ok ? "app.autoNote" : m.appInstallability == .developer ? "app.autoDev" : "app.autoReadOnly")) {
                Toggle("", isOn: Binding(get: { m.autoUpdateApp && m.appInstallability == .ok }, set: { m.autoUpdateApp = $0 }))
                    .labelsHidden().toggleStyle(LauncherSwitchStyle()).disabled(m.appInstallability != .ok)
                    .padTarget("set.appAuto", scope: "main") { if m.appInstallability == .ok { m.autoUpdateApp.toggle() } }
            }
        }
    }

    /// The interface language one step on (a controller's left / right on the language list).
    /// The language picker's choices in order, "" being the system's. A new language is one more code here and its
    /// "settings.language.<code>" entry, which is its own name (Svenska, Deutsch) in every language.
    static let languageCodes = ["", "zh", "en", "sv", "de", "fr"]

    private func cycleLanguage(_ by: Int) {
        let values = Self.languageCodes
        let at = values.firstIndex(of: Lang.saved.map { $0.rawValue } ?? "") ?? 0
        let v = values[(at + by + values.count) % values.count]
        loc.choose(v)
    }

    private func uninstallPlan() -> Uninstall.Plan {
        Uninstall.plan(home: NSHomeDirectory(), gamesFolder: library.folder, outputFolder: m.outDir,
                       checkouts: [m.repoPath], defaultsDomain: Bundle.main.bundleIdentifier)
    }

    private var tools: some View {
        group(loc.t("section.tools"), footnote: m.usesEngineStore ? m.engineStatus
                : (m.repoStatus.isEmpty ? (m.repoOK ? "" : loc.t("repo.firstHint")) : m.repoStatus)) {
            if m.usesEngineStore {
                engineRows
            } else {
            row(loc.t("repo.title"),
                detail: m.repoOK ? m.shortPath(m.repoPath)
                    : (m.repoPath.isEmpty ? loc.t("repo.notFound") : String(format: loc.t("repo.notRepo"), m.shortPath(m.repoPath))),
                dot: m.repoOK ? LauncherPalette.ready : LauncherPalette.building, help: m.repoPath) {
                if m.repoBusy { ProgressView().controlSize(.small) }
                if m.repoOK {
                    if m.repoIsGit {
                        if let n = m.repoBehind, n > 0 {
                            Button(loc.t("repo.pull")) { m.pullRepo() }.disabled(m.repoBusy || m.running)
                                .padTarget("set.repoPull", scope: "main") { if !(m.repoBusy || m.running) { m.pullRepo() } }
                        }
                        Button(loc.t("repo.check")) { m.checkRepoUpdates() }.disabled(m.repoBusy || m.running)
                            .padTarget("set.repoCheck", scope: "main") { if !(m.repoBusy || m.running) { m.checkRepoUpdates() } }
                    } else {
                        Button(loc.t("repo.adopt")) { m.adoptRepoAsGit() }.disabled(m.repoBusy || m.running)
                            .padTarget("set.repoAdopt", scope: "main") { if !(m.repoBusy || m.running) { m.adoptRepoAsGit() } }
                    }
                }
                // Always offered, including when a repository is already configured: a saved path from
                // an earlier session (an upstream clone, a moved folder) is exactly the state a user
                // cannot fix without this button — the report had no way to leave the wrong repository.
                Button(loc.t("repo.choose")) { pickRepo() }
                if !m.repoOK {
                    Button(loc.t("repo.download")) { m.cloneRepo() }.disabled(m.repoBusy || m.running)
                }
            }
            if !m.repoOK {
                // GitHub does not load everywhere: the manual route (Code → Download ZIP → unzip →
                // Choose repository) needs no git at all, and the note says which folder to pick.
                HStack(spacing: 4) {
                    Text(loc.t("repo.manualHint")).foregroundStyle(.secondary)
                    Link("github.com/LNPANDY/NX2Apple", destination: URL(string: BuildModel.repoURL.replacingOccurrences(of: ".git", with: ""))!)
                    Text(loc.t("repo.manualHint2")).foregroundStyle(.secondary)
                }
                .font(.manrope(12)).padding(.horizontal, 18).padding(.bottom, 12)
            }
            if m.repoOK, !m.repoIsGit {
                Text(loc.t(m.autoUpdateRepo ? "repo.noGit" : "repo.zipNoAuto")).font(.manrope(12)).foregroundStyle(.secondary)
                    .padding(.horizontal, 18).padding(.bottom, 12)
            }
            if m.repoOK, !BuildModel.missingTools(in: m.repoPath).isEmpty {
                Text(String(format: loc.t("repo.toolsOld"), BuildModel.missingTools(in: m.repoPath).joined(separator: ", ")))
                    .font(.manrope(12)).foregroundStyle(LauncherPalette.building)
                    .padding(.horizontal, 18).padding(.bottom, 12)
            }
            if m.repoOK {   // a ZIP copy too: its adoption at launch follows this switch
                divider
                row(loc.t("repo.auto"), detail: loc.t("repo.autoNote")) {
                    Toggle("", isOn: $m.autoUpdateRepo).labelsHidden().toggleStyle(LauncherSwitchStyle())
                }
            }
            }
            divider
            Button(action: { withAnimation(.easeInOut(duration: 0.18)) { m.toggleDeps() } }) {
                row(loc.t("dep.title"),
                    detail: !m.depsChecked ? loc.t("dep.checking")
                        : (m.allDepsPresent ? loc.t("dep.allReady") : String(format: loc.t("dep.missing"), m.deps.filter { !$0.present }.count)),
                    dot: !m.depsChecked ? LauncherPalette.unbuilt : (m.allDepsPresent ? LauncherPalette.ready : LauncherPalette.building),
                    open: m.depsOpen) {
                    if !m.depsChecked { ProgressView().controlSize(.small) }
                    Button(loc.t("dep.recheck")) { m.checkDeps() }
                        .padTarget("set.deps", scope: "main") { m.checkDeps() }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if m.depsOpen {
                ForEach(m.deps, id: \.id) { d in
                    divider
                    VStack(alignment: .leading, spacing: 0) {
                        row(loc.t(d.name), detail: m.shortPath(m.depDetail(d)), dot: d.present && !d.warning ? LauncherPalette.ready : LauncherPalette.building,
                            help: loc.t(d.hint)) {
                            if d.installing {
                                ProgressView().controlSize(.small)
                                Text(loc.t("dep.installing")).font(.manrope(12)).foregroundStyle(LauncherPalette.building)
                            } else if !d.present {
                                Button(d.actionLabel.isEmpty ? (d.installCmd.isEmpty ? loc.t("dep.openAppStore") : loc.t("dep.install")) : loc.t(d.actionLabel)) { m.installDep(d) }
                            }
                        }
                        // Why the last install failed, and what to do about it: the tool's own
                        // error line under the row, the fix (a command or a place to look) below it.
                        if !d.lastError.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(d.lastError).font(.mono(11)).foregroundStyle(LauncherPalette.building)
                                    .lineLimit(3).help(d.lastError)
                                if !d.fixHint.isEmpty {
                                    Text(loc.t(d.fixHint)).font(.manrope(11.5)).foregroundStyle(.secondary)
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
            row(loc.t("diag.title"), detail: loc.t("diag.note")) { DiagnosticsButton(m: m, game: library.selected) }
        }
    }

    /// The release app's engine (EngineUpdateModel.swift): which one the build uses, its channel, and the automatic update.
    @ViewBuilder private var engineRows: some View {
        let idle = !(m.engineBusy || m.running)
        row(loc.t("engine.title"), detail: m.engineDetail,
            dot: m.engineSelection.engineID.isEmpty ? LauncherPalette.building : LauncherPalette.ready, help: m.repoPath) {
            if m.engineBusy { ProgressView().controlSize(.small) }
            if let next = m.engineAvailable {
                Button(String(format: loc.t("engine.install"), next.version)) { m.installAvailableEngine() }.disabled(!idle)
                    .padTarget("set.engineInstall", scope: "main") { if idle { m.installAvailableEngine() } }
            }
            Button(loc.t("repo.check")) { m.checkEngineUpdate() }.disabled(!idle)
                .padTarget("set.engineCheck", scope: "main") { if idle { m.checkEngineUpdate() } }
        }
        divider
        // A different channel is asked about first (the alert below): the switch can recompile every game's shaders
        row(loc.t("engine.update"), detail: loc.t("engine.channelNote"), dot: LauncherPalette.ready) {
            LauncherDropdown(options: EngineChannel.allCases.map { (value: $0.rawValue, label: loc.t($0.labelKey)) },
                             selection: m.engineSelection.channel.rawValue) { v in
                if let channel = EngineChannel(rawValue: v) { m.requestEngineChannel(channel) }
            }
            .disabled(!idle)
            .padTarget("set.engineChannel", scope: "main") {
                if idle { m.requestEngineChannel(m.engineSelection.channel == .stable ? .experimental : .stable) }
            }
        }
        .alert(loc.t("engine.switch.title"), isPresented: Binding(get: { m.confirmingChannel != nil },
                                                               set: { if !$0 { m.cancelEngineChannel() } })) {
            if let channel = m.confirmingChannel {
                Button(String(format: loc.t("engine.switch.go"), loc.t(channel.labelKey))) { m.confirmEngineChannel(channel) }
            }
            Button(loc.t("engine.switch.cancel"), role: .cancel) { m.cancelEngineChannel() }
        } message: {
            Text(m.confirmingChannel.flatMap { m.engineSelection.channel.switchWarningKey(to: $0) }.map { loc.t($0) } ?? "")
        }
        divider
        row(loc.t("shellCache.row"), detail: loc.t("shellCache.note"), detail2: m.shellCachePath) {
            Button(loc.t("shellCache.open")) { m.revealFolder(URL(fileURLWithPath: m.shellCachePath)) }
                .buttonStyle(LauncherSecondaryButtonStyle())
        }
        divider
        row(loc.t("repo.auto"), detail: loc.t("engine.autoNote")) {
            Toggle("", isOn: $m.autoUpdateRepo).labelsHidden().toggleStyle(LauncherSwitchStyle())
        }
    }

    private func pickRepo() {
        let d = NSOpenPanel()
        d.canChooseDirectories = true; d.canChooseFiles = false
        d.message = loc.t("repo.pickMessage")
        if d.runModal() == .OK, let u = d.url { m.repoPath = u.path }
    }
}

/// A flag two threads share (the cancel button on the main thread, the install's wait loop on a background one).
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set(_ value: Bool) { lock.lock(); flag = value; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
