import Combine
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

extension StepState {
    var color: Color {
        switch self {
        case .pending: return .gray
        case .running: return .yellow
        case .done: return .green
        case .failed: return .red
        }
    }
}

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

final class BuildModel: ObservableObject, PythonLocation {
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
    /// The services: the only places that start a process (`ProcessRunner`) and that run git (`GitCheckout`). Tests pass in fakes.
    let runner: ProcessRunner
    let gitCheckout: GitCheckout
    /// Where the self-update looks for releases (the real one is GitHub's).
    let releases: ReleaseSource
    init(localizer: Localizer = Localizer(), runner: ProcessRunner = SystemProcessRunner(), gitCheckout: GitCheckout? = nil,
         releases: ReleaseSource = GitHubReleases()) {
        self.localizer = localizer
        self.runner = runner
        self.releases = releases
        self.gitCheckout = gitCheckout ?? SystemGitCheckout(runner: runner)
        _ = Self.endGroupsWhenQuitting
    }

    private var proc: RunningProcess?
    private var staging: String?

    /// The process groups of the builds are `ProcessGroups` (NXCore). Quitting the app ends them: the notification is AppKit's.
    private static let endGroupsWhenQuitting: Void = {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in ProcessGroups.endAll() }
    }()

    // ---- The repository (`RepoStore`, NXModel) ----
    // It owns the path, the status line, the update check, the pull and the automatic update. The model creates it with its services
    // and wires what reaches back here: whether a build runs, the log, and the engine sync that follows a clone, a pull or an adoption.

    /// Created on first use, on the main thread, because its closures reach back to this model.
    private(set) lazy var repo: RepoStore = MainActor.assumeIsolated {
        let store = RepoStore(
            localizer: localizer, git: gitCheckout,
            buildRunning: { [unowned self] in running },
            isReleaseApp: { [unowned self] in MainActor.assumeIsolated { engineSync.usesEngineStore } },
            log: { [unowned self] in append($0) },
            didMove: { [unowned self] in MainActor.assumeIsolated { engineSync.syncEngine() } })   // the pull may have moved the pin or the patches
        // The build state that reads the repository (`canBuild`, the setup rows) is still here: a change of the repository
        // redraws what observes this model, as it did when the repository's state was published by it. Goes with the build store.
        repoChanges = store.objectWillChange.sink { [unowned self] _ in objectWillChange.send() }
        return store
    }
    private var repoChanges: AnyCancellable?

    /// The checkout the build reads, for the build code in this model. The views take it from `repo`.
    var repoPath: String {
        get { MainActor.assumeIsolated { repo.path } }
        set { MainActor.assumeIsolated { repo.path = newValue } }
    }
    var repoOK: Bool { MainActor.assumeIsolated { repo.isRepo } }
    var repoIsGit: Bool { MainActor.assumeIsolated { repo.isGit } }

    // ---- The engine (`EngineSyncStore`, NXModel) ----
    // It owns the engine selection, the sync of a checkout's engine/ and the engine switch of the release app. The model creates it
    // with its services and wires what reaches back here: the repository and the interpreter to read, where the build's tools
    // are read from, whether a build runs, the automatic update and the log.

    /// Created on first use, on the main thread, because its closures reach back to this model.
    private(set) lazy var engineSync: EngineSyncStore = MainActor.assumeIsolated {
        let store = EngineSyncStore(
            localizer: localizer, runner: runner, repo: repo, python: self,
            setRepoPath: { [unowned self] in repoPath = $0 },
            buildRunning: { [unowned self] in running },
            autoUpdate: { [unowned self] in MainActor.assumeIsolated { repo.autoUpdate } },
            log: { [unowned self] in append($0) })
        // The build state that reads the engine's paths (`canBuild`, the setup rows) is still here: a change of the engine redraws
        // what observes this model, as it did when the engine's state was published by it. Goes with the build store.
        engineChanges = store.objectWillChange.sink { [unowned self] _ in objectWillChange.send() }
        return store
    }
    private var engineChanges: AnyCancellable?

    /// The PATH of the processes that run the build, installing packages and writing the RomFS image: the bundled tools in front of
    /// `base` (BundledTools.swift), which is Homebrew's folders and the system's. One place, so that no environment forgets the bundle.
    nonisolated static func toolPath(_ base: String = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", python: String? = nil) -> String {
        BundledTools.path(base, python: python)
    }

    // ---- App self-update (GitHub Releases) ----
    // `AppUpdateStore` (NXModel) owns it: the check, the staged update, the update sheet, the uninstall plan and the version.
    // The model creates it with its services and wires the two things that need AppKit, quitting and the quit notification.

    /// Created on first use, on the main thread, because its closures reach back to this model (`running`).
    private(set) lazy var appUpdates: AppUpdateStore = MainActor.assumeIsolated {
        let store = AppUpdateStore(
            localizer: localizer, runner: runner, releases: releases,
            buildRunning: { [unowned self] in running || ProcessGroups.buildProcessesAlive },
            terminate: {
                NSApp.terminate(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { exit(0) }
            })
        // The staged update goes in as the app quits, so the next launch is the new version without interrupting anyone.
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak store] _ in
            MainActor.assumeIsolated { store?.appWillTerminate() }
        }
        return store
    }
    private var quitObserver: NSObjectProtocol?

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
        let found = GameInputs.classify(GameInputs.inputFiles(in: folder))
        updateSlot("base") { $0.paths = found.base.map { [$0] } ?? []; $0.problem = found.base == nil ? "data.noBase" : "" }
        updateSlot("update") { $0.paths = found.update.map { [$0] } ?? []; $0.problem = ""; $0.note = updateNote(found) }
        updateSlot("dlc") { $0.paths = found.dlc; $0.problem = "" }
        updateSlot("keys") { $0.paths = found.keys.map { [$0] } ?? []; $0.problem = "" }
        if !found.anyGame {
            updateSlot("base") { $0.problem = "data.noNsp" }
        }
    }

    /// The update row's note when the files held several updates: which one was taken and why one is enough.
    func updateNote(_ found: GameInputs.Found) -> String {
        guard found.update != nil, found.updateCount > 1 else { return "" }
        return String(format: t("data.updateNewest"), found.updateVersion, found.updateCount)
    }

    /// The row's message for a rejected file, as a finished sentence in the current language.
    func rowProblemText(_ mismatch: GameInputs.RowMismatch, name: String) -> String {
        func hex(_ tid: UInt64) -> String { String(format: "%016llX", tid) }
        switch mismatch {
        case .notBase(let tid): return String(format: t("data.rowNotBase"), name, hex(tid))
        case .notUpdate(let tid): return String(format: t("data.rowNotUpdate"), name, hex(tid))
        case .notDLC(let tid): return String(format: t("data.rowNotDLC"), name, hex(tid))
        case .otherGame: return String(format: t("data.rowOtherGame"), name)
        }
    }

    func pickFiles(kind: InputKind) {
        let p = NSOpenPanel()
        p.canChooseDirectories = false
        p.canChooseFiles = true
        p.allowsMultipleSelection = (kind == .dlc)
        p.allowedFileTypes = GameInputs.allowedFileTypes(for: kind)
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
            if let why = GameInputs.rowMismatch(kind, name: name, base: baseName) {
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
        let py = pythonPath.isEmpty ? Toolchain.findPython().path : pythonPath
        // engine/ is the only engine and is stale or missing (#214): make it, then start again
        if EngineLayout.needsSyncBeforeBuild(repoPath) {
            MainActor.assumeIsolated {
                engineSync.syncEngine { ok in
                    self.running = false
                    if ok && !EngineLayout.needsSyncBeforeBuild(self.repoPath) { self.startBuild() }
                    else { self.fail(String(format: self.t("msg.toolsOld"), "engine/ (python3 tools/engine.py sync, see the log)")) }
                }
            }
            return
        }
        // The tools this app runs, before a build that takes an hour finds one missing at its last step (#87)
        let missing = RepoLayout.missingTools(in: repoPath)
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
        if let base = TitleID.parse((basePath as NSString).lastPathComponent) {
            let app = base & ~0xFFF
            for f in unpicked {
                guard let tid = TitleID.parse(f) else { continue }
                let low = tid & 0xFFF
                let owner = low == 0 ? tid : (low == 0x800 ? tid & ~0xFFF : (tid & ~0xFFF) - 0x1000)
                guard owner == app else { continue }
                if low == 0x800 && !updatePath.isEmpty { continue }   // the update was picked already
                if low != 0 && low != 0x800 && tid <= app { continue }   // add-on content sits above its base
                staged.append(baseDir + "/" + f)
            }
        }
        let tidHex = TitleID.buildKey(basePath)
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
        let hasWorkDir = RepoLayout.supportsWorkDir(repoPath)
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
        if compressed, !Toolchain.runOK(py, ["-c", "import nsz"]) {
            say(t("msg.installingNsz"))
            let r = runner.runCaptured([py, "-m", "pip", "install", "nsz"],
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
        var args = [engine + "/" + RepoLayout.buildScript, inputDir, "-k", keysPath,
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
        if let droot = Toolchain.dotnetRoot(for: dotnetPath.isEmpty ? "dotnet" : dotnetPath) {
            denv["DOTNET_ROOT"] = droot   // both variables carry the same root, as the apphost checks the arch-specific one first
            denv["DOTNET_ROOT_ARM64"] = droot
        }
        // The bundled Python lives inside the signed app: a .pyc written there would change what the signature seals
        // (the packages are compiled at bundle time), and a user site must not shadow its pinned packages.
        denv.merge(BundledTools.environment(for: py)) { $1 }
        let launch = ProcessLaunch(executable: py, arguments: args, environment: denv, directory: engine, groupPython: py)
        let onExit: (Int32) -> Void = { [weak self] status in
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
                if status == 0 {
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
                        let tid = TitleID.buildKey(self.basePath)
                        let name = ((self.basePath as NSString).lastPathComponent as NSString).deletingPathExtension
                        let fw = ShellInstall.frameworkPath(workDir: self.effectiveWorkDir, titleID: tid)
                        self.packArchive(workDir: self.effectiveWorkDir) {
                            self.installShell(framework: fw, titleID: tid, name: name, archive: $0)
                        }
                    }
                } else {
                    if let i = self.stages.lastIndex(where: { $0.state == .running }) {
                        self.stages[i].state = .failed
                        self.stages[i].detail = String(format: self.t("msg.exitCode"), status)
                        self.noteFailure()
                    } else {
                        // The last real line says more than the exit code alone, and the message
                        // points at the log: "Build failed (exit code 1)" with nothing else sent a
                        // reporter looking for a log that a short window had below the fold (#52)
                        self.doneNote = String(format: self.t("msg.buildFailed"), status)
                        if let last = BuildProgress.lastMeaningfulLine(self.logTail) {
                            self.doneNote = String(format: self.t("msg.buildFailedReason"), last)
                        }
                        self.noteFailure()
                    }
                    self.cleanupStaging()
                }
            }
        }
        do {
            proc = try runner.start(launch, onOutput: { [weak self] d in
                guard let s = String(data: d, encoding: .utf8) else { return }
                DispatchQueue.main.async { self?.ingest(s) }
            }, onExit: onExit)
        } catch { fail(String(format: t("msg.launchFailed"), error.localizedDescription)) }
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
            installDep(Dep(id: "xcode", name: "dep.xcode", hint: "dep.xcode.hint", present: false, installCmd: Toolchain.iosPlatformCmd))
        case .cltSelected:
            if let xcode = Toolchain.installedXcode() {
                installDep(Dep(id: "xcode", name: "dep.xcode", hint: "dep.xcode.hint", present: false, installCmd: Toolchain.selectXcodeCmd(xcode)))
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
        guard let app = Toolchain.installedXcode() else { return }
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
        ProcessGroups.endGroup(proc.processIdentifier)   // the script and every tool it started
    }

    private func cleanupStaging() {
        staging = nil   // the folder stays for the next build of this game (#132, InputStaging)
    }

    /// A stopped build leaves no half-finished stages behind: the progress starts empty again.
    private func resetProgress() { stages = []; BuildLog.onMain { log.clear() } }

    private func markAllDone() { for i in stages.indices where stages[i].state != .failed { stages[i].state = .done } }

    // MARK: Output parsing

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
        guard let s = BuildProgress.parseStage(line) else { return }
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
            let detail = BuildProgress.progressDetail(e)
            let eta = (e["eta"] as? NSNumber)?.doubleValue
            stage { $0.percent = fraction.map { $0 * 100 }; $0.detail = detail; $0.eta = eta; $0.etaAt = eta == nil ? nil : Date() }
        case "stage_end":
            let ok = e["ok"] as? Bool ?? true, summary = e["summary"] as? String ?? ""
            let elapsed = BuildProgress.duration((e["elapsed"] as? NSNumber)?.doubleValue ?? 0)
            append("\(ok ? "✓" : "✗") \(e["name"] as? String ?? "") (\(elapsed))" + (summary.isEmpty ? "" : ": \(summary)") + "\n")
            stage { $0.state = ok ? .done : .failed; $0.detail = summary; $0.percent = ok ? 100 : $0.percent; $0.eta = nil }
        case "say":
            let msg = e["msg"] as? String ?? ""
            append(msg + "\n")
            noteChainChange(msg)
        default: break
        }
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
        let tid = TitleID.buildKey(basePath)
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
        // dest/romfs.img: one file, which main.m's per-game lookup takes before any folder.
        let engine = EngineLayout.root(repoPath)
        let romfsPy = pythonPath.isEmpty ? "/usr/bin/python3" : pythonPath
        let launch = ProcessLaunch(executable: romfsPy, arguments: [engine + "/" + RepoLayout.romfsImageTool, "--reuse", romfs, dest + "/romfs.img"],
                                   environment: ["PATH": Self.toolPath("/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin", python: romfsPy), "PYTHONPATH": engine + "/dm/tools"]
                                       .merging(BundledTools.environment(for: romfsPy)) { $1 },
                                   groupPython: romfsPy)
        let onExit: (Int32) -> Void = { [weak self] st in DispatchQueue.main.async {
            guard let self else { return }
            let cancelled = self.stopping
            let succeeded = st == 0 && !cancelled
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
                    : String(format: self.t("msg.archiveFailed"), st)
            }
            if succeeded { return then(dest) }
            self.cleanupStaging()
            self.running = false
            self.done = false
            if cancelled { self.resetProgress() }
            self.doneNote = cancelled ? self.t("msg.stopped") : String(format: self.t("msg.archiveFailed"), st)
        }}
        do {
            proc = try runner.start(launch, onOutput: { [weak self] d in
                guard let s = String(data: d, encoding: .utf8) else { return }
                DispatchQueue.main.async { self?.append(s) }
            }, onExit: onExit)
        } catch {
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
        let python = pythonPath.isEmpty ? Toolchain.findPython().path : pythonPath
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
        installer.processStarted = { p in DispatchQueue.main.async { self.proc = p; ProcessGroups.track(p) } }
        installer.processEnded = { p in ProcessGroups.untrack(p) }
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
                Self.reinstallCommand(xcrun: xcrunPath, device: device, app: app), step: BuildProgress.installStep) { error in
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
                command, step: BuildProgress.xcodeStep) { error in
            if let error, !error.isEmpty {
                self.running = false
                self.doneNote = String(format: self.t("dev.resignFailed"), error)
                then?(); return
            }
            self.runTool(id: 1007, name: String(format: self.t("dev.installStage"), name),
                         Self.reinstallCommand(xcrun: xcrun, device: device, app: app), step: BuildProgress.installStep) { installError in
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
        let launch = ProcessLaunch(command, environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "USER": NSUserName(), "LANG": "en_US.UTF-8"],
                                   groupPython: pythonPath.isEmpty ? "/usr/bin/python3" : pythonPath)
        var buffer = "", lastError = ""
        let onOutput: (Data) -> Void = { [weak self] d in
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
        let onExit: (Int32) -> Void = { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.stopping {
                    self.stopping = false; self.running = false
                    self.resetProgress(); self.doneNote = self.t("msg.stopped"); self.cleanupStaging()
                    return
                }
                let ok = status == 0
                if let i = self.stages.firstIndex(where: { $0.id == id }) {
                    self.stages[i].state = ok ? .done : .failed
                    if ok { self.stages[i].percent = 100; self.stages[i].detail = "" }
                }
                then(ok ? nil : (lastError.isEmpty ? String(format: self.t("msg.exitCode"), status) : lastError))
            }
        }
        do { proc = try runner.start(launch, onOutput: onOutput, onExit: onExit) } catch { then(error.localizedDescription) }
    }

    /// Start the game on the device it was installed on.
    func openOnDevice(udid: String, app: String, completion: @escaping (String?) -> Void) {
        let info = NSDictionary(contentsOfFile: app + "/Info.plist")
        guard let bundle = info?["CFBundleIdentifier"] as? String else { return completion(String(format: t("dev.noProject"), shortPath(app))) }
        let launch = ProcessLaunch(executable: xcrunPath, arguments: ["devicectl", "device", "process", "launch", "--device", udid, bundle], mergesErrors: true)
        let runner = runner
        DispatchQueue.global(qos: .userInitiated).async {
            let r = runner.capture(launch)
            var message: String?
            if !r.started { message = r.out }
            else if r.status != 0 { message = r.out.split(separator: "\n").last(where: { $0.contains("rror") }).map(String.init) ?? r.out }
            DispatchQueue.main.async { completion(message) }
        }
    }

    // MARK: Dependencies

    /// Whether the xcode row asks for the iOS SDK. Always, as before, unless the guided setup stored a Mac-only choice
    /// and builds are for the Mac: upstream no longer needs the iOS SDK for a Mac build (c464cb24).
    nonisolated static func needsIOSPlatform(defaults: UserDefaults = .standard) -> Bool {
        if OnboardingDefaults.sessionPlatform == "mac" { return false }   // a forced run's choice, not stored yet
        guard defaults.string(forKey: OnboardingDefaults.platform) == "mac" else { return true }
        return BuildTarget.normalized(defaults.string(forKey: "buildTarget")) != BuildTarget.mac
    }

    /// The Metal toolchain row. A compiler that does not run is the missing-toolchain row with its install button. One that differs from the
    /// lock's pin is a warning and not a blocker: the row stays present, and its error and hint lines (the install failures' fields) say that
    /// NVN games will stop. Pure over its inputs, so tests give it version strings.
    nonisolated static func metalDep(runs: Bool, lock: String?, now: [String: String?], needsIOS: Bool) -> Dep {
        var dep = Dep(id: "metal", name: "dep.metal", hint: "dep.metal.hint", present: runs, installCmd: Toolchain.metalToolchainCmd)
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
        let selected = Toolchain.developerDir()
        let xcodeApp = Toolchain.installedXcode()
        let sdkenv = Toolchain.runOK("/usr/bin/xcrun", ["--sdk", "iphoneos", "--show-sdk-version"])
        // A Mac-only setup does not need the iOS platform (onboarding's platform choice, #120); a
        // Mac build still needs a selected Xcode, so the CommandLineTools state is reported either way.
        switch Toolchain.xcodeState(selected: selected, xcodeApp: xcodeApp, iosSDK: !needsIOS || sdkenv) {
        case .ready:
            out.append(Dep(id: "xcode", name: "dep.xcode", hint: "dep.xcode.hint", present: true, installCmd: []))
        case .noIOSSDK:
            out.append(Dep(id: "xcode", name: "dep.xcode", hint: "dep.xcode.hint", present: false,
                           detail: "dep.xcode.noSDK", installCmd: Toolchain.iosPlatformCmd))
        case .commandLineToolsOnly(let xcode):
            out.append(Dep(id: "xcode", name: "dep.xcode", hint: "dep.xcode.hint", present: false,
                           detail: "dep.xcode.notSelected", actionLabel: "dep.xcode.fix",
                           installCmd: Toolchain.selectXcodeCmd(xcode)))
        case .notInstalled:
            out.append(Dep(id: "xcode", name: "dep.xcode", hint: "dep.xcode.hint", present: false, installCmd: []))
        }

        let macMetal = Toolchain.firstOutputLine("/usr/bin/xcrun", ["-sdk", "macosx", "metal", "--version"])
        let lock = repo.isEmpty ? nil : try? String(contentsOfFile: EngineLayout.root(repo) + "/" + MetalPin.lockPath, encoding: .utf8)
        let iosMetal = needsIOS && lock != nil ? Toolchain.firstOutputLine("/usr/bin/xcrun", ["-sdk", "iphoneos", "metal", "--version"]) : nil
        out.append(metalDep(runs: macMetal != nil, lock: lock, now: ["macosx": macMetal, "iphoneos": iosMetal], needsIOS: needsIOS))

        out += Toolchain.toolDeps(resources: BundledTools.resources,
                        installed: { Toolchain.firstExisting(["/opt/homebrew/bin/\($0)", "/usr/local/bin/\($0)"]) },
                        brew: Toolchain.firstExisting(["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]))

        let (dn, dnOK) = Toolchain.findDotnet()
        out.append(Dep(id: "dotnet", name: "dep.dotnet", hint: "dep.dotnet.hint",
                       present: dnOK, detail: dnOK ? dn : "dep.dotnet.missing",
                       installCmd: ["/bin/bash", "-c",
                         "curl -sSL https://dot.net/v1/dotnet-install.sh -o /tmp/di.sh && chmod +x /tmp/di.sh && /tmp/di.sh --channel 10.0 --install-dir $HOME/.dotnet"]))

        let (py, pyOK) = Toolchain.findPython()
        // A too-old interpreter is a different problem from a missing package: say which one it is,
        // because the fix differs (install a newer Python vs pip install into this one).
        // A version we cannot read means no interpreter ran at all (py is then the venv
        // that does not exist yet), which is not the same as one that is too old.
        let pyDetail = Toolchain.pythonDetail(py: py, ok: pyOK)
        out.append(Dep(id: "python", name: "dep.python", hint: "dep.python.hint",
                       present: pyOK, detail: pyDetail,
                       installCmd: [py, "-m", "pip", "install", "--user", "lz4", "capstone", "fonttools", "zbic", "backports.zstd"]))
        return out
    }

    func checkDeps() {
        depsChecked = false
        DispatchQueue.global(qos: .userInitiated).async {
            let d = Self.detectDepsSync(repo: self.repoPath)
            Self.writeDepsReport(d)
            let (py, _) = Toolchain.findPython()
            let (dn, _) = Toolchain.findDotnet()
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
        let dir = (Toolchain.venvDir as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var out = "NX2Apple \(AppUpdateStore.appVersion) dependency check\n"
        out += "date: \(ISO8601DateFormatter().string(from: Date()))\n"
        out += "HOME: \(NSHomeDirectory())\n"
        out += "PATH: \(ProcessInfo.processInfo.environment["PATH"] ?? "(unset)")\n"
        let chosen = Toolchain.findPython()
        let bundled = BundledTools.python()
        out += "python chosen: \(chosen.path) (\(chosen.ok ? "ok" : "not usable")\(chosen.path == bundled ? ", bundled with the app" : ""))\n"
        out += "bundled python: \(bundled ?? "(none: not the release app)")\n"
        out += "python candidates (after the bundled one, in search order):\n"
        for c in Toolchain.pythonCandidates() { out += "  \(c)\n" }
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
                let r = Toolchain.makeVenv(base: self.pythonPath)
                DispatchQueue.main.async { self.append("\n--- 安装输出 ---\n" + r.log) }
                ok = r.ok
            } else {
                let collected = LineBox()
                ok = self.runner.runCaptured(["/bin/bash", "-c",
                     cmd.map { $0.contains(" ") ? "'" + $0 + "'" : $0 }.joined(separator: " ")],
                     env: ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                           "HOME": NSHomeDirectory(), "NONINTERACTIVE": "1", "USER": NSUserName()])
                { line in
                    collected.append(line)
                    DispatchQueue.main.async { self.append(line + "\n") }
                }
                let (error, fix) = BuildProgress.failureInfo(collected.lines)
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

    /// The output lines seen so far, from the pipe's threads and read on the main queue.
    final class LineBox: @unchecked Sendable {
        private let lock = NSLock()
        private var box: [String] = []
        func append(_ l: String) { lock.lock(); box.append(l); lock.unlock() }
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return box }
    }

    var allDepsPresent: Bool { depsChecked && deps.allSatisfy { $0.present } }

    /// Home shown as ~ (shorter in a one-line row, and it keeps the account name out of
    /// screenshots).
    func shortPath(_ path: String) -> String { RepoLayout.shortPath(path) }

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
    @ObservedObject var updates: AppUpdateStore   // the app's self-update (Settings, "NX2Apple" section)
    @ObservedObject var repo: RepoStore   // the repository (Settings, "Tools" section, and the setup hint)
    @ObservedObject var engine: EngineSyncStore   // the engine (Settings, "Tools" section)
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
        if !repo.isRepo || !m.allDepsPresent {
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
        } else if !repo.isRepo {
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
        group(loc.t("section.app"), footnote: updates.status) {
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
            row("NX2Apple", detail: String(format: loc.t("app.version"), updates.version),
                dot: updates.staged != nil ? LauncherPalette.ready : nil) {
                if updates.busy { ProgressView().controlSize(.small) }
                if updates.staged != nil {
                    // Downloaded and verified: it goes in when the app quits; this restarts into it now (not during a build)
                    Button(loc.t("app.restartNow")) { updates.restartNow() }.disabled(m.running)
                        .padTarget("set.appRestart", scope: "main") { if !m.running { updates.restartNow() } }
                } else if let u = updates.update, updates.installability == .ok {
                    Button(String(format: loc.t("app.updateBtn"), u.tag)) { updates.performUpdate() }.disabled(updates.busy || m.running)
                        .padTarget("set.appUpdate", scope: "main") { if !(updates.busy || m.running) { updates.performUpdate() } }
                } else {
                    Button(loc.t("repo.check")) { updates.checkForUpdate() }.disabled(updates.busy)
                        .padTarget("set.appCheck", scope: "main") { if !updates.busy { updates.checkForUpdate() } }
                }
            }
            divider
            if updates.installability == .ok {
                // The uninstaller (Uninstall.swift): state folders and the launcher's own checkout go; the
                // games folder and prod.keys stay; the app itself goes to the Trash.
                row(loc.t("uninstall.title"), detail: loc.t("uninstall.note")) {
                    Button(loc.t("uninstall.button")) { updates.uninstallPlan = uninstallPlan() }
                    .disabled(m.running)
                    .padTarget("set.uninstall", scope: "main") { if !m.running { updates.uninstallPlan = uninstallPlan() } }
                }
                divider
            }
            // A launcher built from the repository never replaces itself (AppUpdate.installability): the switch says so and stays off
            row(loc.t("app.auto"), detail: loc.t(updates.installability == .ok ? "app.autoNote" : updates.installability == .developer ? "app.autoDev" : "app.autoReadOnly")) {
                Toggle("", isOn: Binding(get: { updates.automatic && updates.installability == .ok }, set: { updates.automatic = $0 }))
                    .labelsHidden().toggleStyle(LauncherSwitchStyle()).disabled(updates.installability != .ok)
                    .padTarget("set.appAuto", scope: "main") { if updates.installability == .ok { updates.automatic.toggle() } }
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
                       checkouts: [repo.path], defaultsDomain: Bundle.main.bundleIdentifier)
    }

    private var tools: some View {
        group(loc.t("section.tools"), footnote: engine.usesEngineStore ? engine.status
                : (repo.status.isEmpty ? (repo.isRepo ? "" : loc.t("repo.firstHint")) : repo.status)) {
            if engine.usesEngineStore {
                engineRows
            } else {
            row(loc.t("repo.title"),
                detail: repo.isRepo ? m.shortPath(repo.path)
                    : (repo.path.isEmpty ? loc.t("repo.notFound") : String(format: loc.t("repo.notRepo"), m.shortPath(repo.path))),
                dot: repo.isRepo ? LauncherPalette.ready : LauncherPalette.building, help: repo.path) {
                if repo.busy { ProgressView().controlSize(.small) }
                if repo.isRepo {
                    if repo.isGit {
                        if let n = repo.behind, n > 0 {
                            Button(loc.t("repo.pull")) { repo.pull() }.disabled(repo.busy || m.running)
                                .padTarget("set.repoPull", scope: "main") { if !(repo.busy || m.running) { repo.pull() } }
                        }
                        Button(loc.t("repo.check")) { repo.checkForUpdates() }.disabled(repo.busy || m.running)
                            .padTarget("set.repoCheck", scope: "main") { if !(repo.busy || m.running) { repo.checkForUpdates() } }
                    } else {
                        Button(loc.t("repo.adopt")) { repo.adoptAsGit() }.disabled(repo.busy || m.running)
                            .padTarget("set.repoAdopt", scope: "main") { if !(repo.busy || m.running) { repo.adoptAsGit() } }
                    }
                }
                // Always offered, including when a repository is already configured: a saved path from
                // an earlier session (an upstream clone, a moved folder) is exactly the state a user
                // cannot fix without this button — the report had no way to leave the wrong repository.
                Button(loc.t("repo.choose")) { pickRepo() }
                if !repo.isRepo {
                    Button(loc.t("repo.download")) { repo.clone() }.disabled(repo.busy || m.running)
                }
            }
            if !repo.isRepo {
                // GitHub does not load everywhere: the manual route (Code → Download ZIP → unzip →
                // Choose repository) needs no git at all, and the note says which folder to pick.
                HStack(spacing: 4) {
                    Text(loc.t("repo.manualHint")).foregroundStyle(.secondary)
                    Link("github.com/LNPANDY/NX2Apple", destination: URL(string: RepoStore.url.replacingOccurrences(of: ".git", with: ""))!)
                    Text(loc.t("repo.manualHint2")).foregroundStyle(.secondary)
                }
                .font(.manrope(12)).padding(.horizontal, 18).padding(.bottom, 12)
            }
            if repo.isRepo, !repo.isGit {
                Text(loc.t(repo.autoUpdate ? "repo.noGit" : "repo.zipNoAuto")).font(.manrope(12)).foregroundStyle(.secondary)
                    .padding(.horizontal, 18).padding(.bottom, 12)
            }
            if repo.isRepo, !RepoLayout.missingTools(in: repo.path).isEmpty {
                Text(String(format: loc.t("repo.toolsOld"), RepoLayout.missingTools(in: repo.path).joined(separator: ", ")))
                    .font(.manrope(12)).foregroundStyle(LauncherPalette.building)
                    .padding(.horizontal, 18).padding(.bottom, 12)
            }
            if repo.isRepo {   // a ZIP copy too: its adoption at launch follows this switch
                divider
                row(loc.t("repo.auto"), detail: loc.t("repo.autoNote")) {
                    Toggle("", isOn: $repo.autoUpdate).labelsHidden().toggleStyle(LauncherSwitchStyle())
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

    /// The release app's engine (EngineSyncStore): which one the build uses, its channel, and the automatic update.
    @ViewBuilder private var engineRows: some View {
        let idle = !(engine.busy || m.running)
        row(loc.t("engine.title"), detail: engine.detail,
            dot: engine.selection.engineID.isEmpty ? LauncherPalette.building : LauncherPalette.ready, help: repo.path) {
            if engine.busy { ProgressView().controlSize(.small) }
            if let next = engine.available {
                Button(String(format: loc.t("engine.install"), next.version)) { engine.installAvailable() }.disabled(!idle)
                    .padTarget("set.engineInstall", scope: "main") { if idle { engine.installAvailable() } }
            }
            Button(loc.t("repo.check")) { engine.checkForUpdate() }.disabled(!idle)
                .padTarget("set.engineCheck", scope: "main") { if idle { engine.checkForUpdate() } }
        }
        divider
        // A different channel is asked about first (the alert below): the switch can recompile every game's shaders
        row(loc.t("engine.update"), detail: loc.t("engine.channelNote"), dot: LauncherPalette.ready) {
            LauncherDropdown(options: EngineChannel.allCases.map { (value: $0.rawValue, label: loc.t($0.labelKey)) },
                             selection: engine.selection.channel.rawValue) { v in
                if let channel = EngineChannel(rawValue: v) { engine.requestChannel(channel) }
            }
            .disabled(!idle)
            .padTarget("set.engineChannel", scope: "main") {
                if idle { engine.requestChannel(engine.selection.channel == .stable ? .experimental : .stable) }
            }
        }
        .alert(loc.t("engine.switch.title"), isPresented: Binding(get: { engine.confirmingChannel != nil },
                                                               set: { if !$0 { engine.cancelChannel() } })) {
            if let channel = engine.confirmingChannel {
                Button(String(format: loc.t("engine.switch.go"), loc.t(channel.labelKey))) { engine.confirmChannel(channel) }
            }
            Button(loc.t("engine.switch.cancel"), role: .cancel) { engine.cancelChannel() }
        } message: {
            Text(engine.confirmingChannel.flatMap { engine.selection.channel.switchWarningKey(to: $0) }.map { loc.t($0) } ?? "")
        }
        divider
        row(loc.t("shellCache.row"), detail: loc.t("shellCache.note"), detail2: m.shellCachePath) {
            Button(loc.t("shellCache.open")) { m.revealFolder(URL(fileURLWithPath: m.shellCachePath)) }
                .buttonStyle(LauncherSecondaryButtonStyle())
        }
        divider
        row(loc.t("repo.auto"), detail: loc.t("engine.autoNote")) {
            Toggle("", isOn: $repo.autoUpdate).labelsHidden().toggleStyle(LauncherSwitchStyle())
        }
    }

    private func pickRepo() {
        let d = NSOpenPanel()
        d.canChooseDirectories = true; d.canChooseFiles = false
        d.message = loc.t("repo.pickMessage")
        if d.runModal() == .OK, let u = d.url { repo.path = u.path }
    }
}

/// A flag two threads share (the cancel button on the main thread, the install's wait loop on a background one).
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set(_ value: Bool) { lock.lock(); flag = value; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
