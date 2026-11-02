import Foundation
import Combine
import NXCore

/// A file picker request: what the store asks the app's open panel for (`BuildStore.choosePaths`).
package struct FilePick: Equatable {
    package var allowsMultiple: Bool
    package var fileTypes: [String]
    package var message: String?
    package var prompt: String?

    package init(allowsMultiple: Bool, fileTypes: [String], message: String? = nil, prompt: String? = nil) {
        self.allowsMultiple = allowsMultiple; self.fileTypes = fileTypes; self.message = message; self.prompt = prompt
    }
}

/// What the build asks of the engine sync: make `engine/` of the checkout current, and tell when it is done.
@MainActor package protocol EngineSyncing: AnyObject {
    func syncEngine(then: ((Bool) -> Void)?) -> Task<Void, Never>
}

/// What the build asks of the dependency store besides its status: the rows, and the install the card's fix buttons run.
@MainActor package protocol DependencyInstalling: DependencyStatus {
    func isInstalling(_ id: String) -> Bool
    func install(_ dep: Dep) -> Task<Void, Never>
}

/// What the build reads from the device store: the device and the team to install on, the names, the listing of the teams, and the
/// copy flow the install blocks on (its queue is not the main one, so those four are `nonisolated`).
@MainActor package protocol InstallTarget: AnyObject {
    var installDevice: String { get }
    /// The paired devices the last listing found.
    var devices: [AppleDevice] { get }
    var signingTeam: String { get }
    var xcrun: String { get }
    var readTeams: @Sendable () -> [SigningTeam] { get }
    func deviceName(_ udid: String) -> String
    nonisolated func askCopy(_ plan: ShellCopyPlan) -> ShellCopyDecision
    nonisolated func setWaiting(_ on: Bool)
    nonisolated var waitCancelled: Bool { get }
    func copyEnded()
}

extension DeviceStore: InstallTarget {}
extension DependencyStore: DependencyInstalling {}
extension EngineSyncStore: EngineSyncing {}

/// Runs `body` on the main actor, from a queue that is not the main one: the pipe's callbacks and the background install land here.
func hop(_ body: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async { MainActor.assumeIsolated(body) }
}

/// The build (LNPANDY/NX2Apple#387, step 7, the last store): the inputs (the four rows, the output folder), the target, the stages
/// and whether a build runs, the script's JSON events, the run itself with its archive step and its hand-off to the device, the
/// failure the card shows and "Build anyway". It follows `AppUpdateStore` (`frontend/ARCHITECTURE.md`, "Stores").
///
/// - What it works with comes through `init`: the `Localizer`, a `ProcessRunner`, the `BuildLog`, and three narrow views of the other
///   stores: `RepoLocation` (where the checkout is), `DependencyInstalling` (the tools: `DependencyStatus` and the install the fix
///   buttons run), `EngineSyncing` (the sync a stale `engine/` needs before a build) and `InstallTarget` (the device, the team and
///   the copy flow). The app wires them.
/// - AppKit reaches it as closures: the file and folder pickers (`choosePaths`, `chooseFolder`, `chooseSaveLocation`), the notice
///   (`showNotice`), the Finder (`revealFolder`, `openApp`), and `targetChanged`, which the app answers with a new dependency check.
/// - It checks the conditions for its own actions: `canBuild` and the start of a build (`startBuild`).
/// - The pieces live in the `BuildStore+` files: `Inputs`, `Run`, `Failure`, `Archive`, `Install`, `Stale`, `DropFiles`.
@MainActor package final class BuildStore: ObservableObject {
    nonisolated package static let outputKey = "buildOutputDirectory"
    nonisolated package static let targetKey = "buildTarget"
    nonisolated package static let bcOnCPUKey = "bcOnCPU"

    @Published package var gameDir = ""
    @Published package var slots: [Slot] = [
        Slot(id: "base", kind: .base, title: "data.base", optional: false),
        Slot(id: "update", kind: .update, title: "data.update", optional: true),
        Slot(id: "dlc", kind: .dlc, title: "data.dlc", optional: true),
        Slot(id: "keys", kind: .keys, title: "data.keys", optional: false),
    ]
    @Published package var outDir: String {
        didSet { defaults.set(outDir, forKey: Self.outputKey) }
    }
    @Published package var stages: [Stage] = []
    var chainNoteShown = false   // the shader-chain notice shows once per build
    @Published package var running = false
    @Published package var staleFrameworks: [StaleFrameworks.Entry] = []   // the prompt of StaleFrameworksPrompt.swift (#449)
    /// The shell folder the cache row shows: the frameworks' mirror, shell.json and the banner cache live here.
    package var shellCachePath: String { shellRoot }
    /// The shell folder of the install and of the cache row: the saved one, else next to the output folder (or the game's folder).
    package var shellRoot: String { ShellLibrary.resolveRoot(defaults: defaults, parent: outDir.isEmpty ? (basePath as NSString).deletingLastPathComponent : outDir) }
    @Published package var stopping = false
    /// The build log. Not published: only `BuildLogView` observes it (#387), so a log line redraws the log and nothing else.
    package let log: BuildLog
    package var logTail: String {
        get { log.text }
        set { log.set(newValue) }
    }
    @Published package var done = false
    @Published package var doneNote = ""
    /// What the NSP script stopped on, when it is one of the known early stops (BuildFailureClassifier). nil for a build that
    /// succeeded, is running, or failed some other way (the note then shows the last line of the log, as it always did).
    @Published package var failure: BuildFailure?
    /// "Build anyway" asked for this stop and waiting for the confirmation dialog.
    @Published package var confirmingOverride: BuildFailureKind?
    /// The one-off `--allow-*` of a confirmed "Build anyway": taken by the next build and never stored.
    package var armedOverride: BuildFailureKind?
    @Published package var macAppPath = ""   // --platform mac-app: the .app this build produced
    /// BuildTarget.ios = the game's framework in the one shared app on an iPhone or iPad; BuildTarget.mac = a double-clickable
    /// Mac app (upstream's --platform mac-app). A Mac app is a different output of the same pipeline, not a
    /// different pipeline: same extraction, rewrite and shaders, then dm/mac/pack_app.py.
    @Published package var target: String {
        didSet {
            defaults.set(target, forKey: Self.targetKey)
            if oldValue != target { targetChanged() }
        }
    }
    /// Decode BC-compressed textures on the CPU. Only relevant for GPUs without BC support
    /// (A15/A16 and older): on a device that has it the GPU path is always better, so the switch
    /// is a compatibility option and defaults off. Passed as DM_TEX_BC_CPU through --env-file,
    /// which the host reads at start-up — no rebuild of the host needed.
    @Published package var bcOnCPU: Bool {
        didSet { defaults.set(bcOnCPU, forKey: Self.bcOnCPUKey) }
    }
    @Published package var archivePath = ""  // the romfs folder the pack wrote
    /// Where this build's folder actually is: --work-dir when the checkout has it, else the script's
    /// default under the input folder (issue #5 — an upstream checkout has no --work-dir).
    package var effectiveWorkDir = ""
    package var lastBuildCommand: [String] = []   // this session's last build, for Copy diagnostics (Diagnostics.swift)

    // ---- Installing on an iPhone or iPad (Xcode with a development certificate) ----
    // Optional: with a paired device and a signing team chosen, the script prepares the game's Xcode project
    // (--prepare-xcode, the route its README gives developers), xcodebuild signs it for that device with the
    // team (Xcode makes the provisioning profile) without the game files, devicectl installs it and copies the game's
    // folder (romfs.img, aoc/) into its Documents, as a sideloaded copy has it. Without a device or a team the build stays an unsigned IPA, as before.
    @Published package var installedOn = ""       // the device the last build went to (its UDID)
    @Published package var installedAppPath = ""  // the signed app that went there
    var shellRetry: (framework: String, titleID: String, name: String, archive: String)?
    var shellDeviceChecked = false

    // ---- The app's side: AppKit and the wiring, as closures ----
    package var chooseKeys: (() -> Void)?          // tests stand in for the file picker
    /// The open panel: the paths the player picked, none when they cancelled.
    package var choosePaths: (FilePick) -> [String] = { _ in [] }
    /// The folder panel of "Save to": the folder's path, nil when they cancelled.
    package var chooseFolder: () -> String? = { nil }
    /// The save panel of "Save IPA" (title, the name offered): where to write, nil when they cancelled.
    package var chooseSaveLocation: (String, String) -> URL? = { _, _ in nil }
    /// A notice the player must see (the shader chain changed): an alert.
    package var showNotice: (String) -> Void = { _ in }
    package var revealFolder: (URL) -> Void = { _ in }
    package var openApp: (URL) -> Void = { _ in }
    /// Whether the build folder is in a cloud folder. Tests stand in for the system's answer.
    package var cloudFolderCheck: (String) -> Bool = { CloudFolder.contains($0) }
    /// The target changed: the app checks the tools again when a Mac-only setup now needs, or no longer needs, the iOS SDK.
    package var targetChanged: () -> Void

    // ---- What it works with ----
    package let localizer: Localizer
    package let runner: ProcessRunner
    package let repo: RepoLocation
    package let deps: DependencyInstalling
    package let engine: EngineSyncing
    package let devices: InstallTarget
    package let volumesRoot: String
    let defaults: UserDefaults

    var proc: RunningProcess?
    var staging: String?

    /// - Parameters:
    ///   - volumesRoot: where external drives are mounted (the failure classifier reads it).
    ///   - targetChanged: see the property of the same name.
    package init(localizer: Localizer, runner: ProcessRunner, log: BuildLog = BuildLog(), repo: RepoLocation, deps: DependencyInstalling,
                 engine: EngineSyncing, devices: InstallTarget, defaults: UserDefaults = .standard, volumesRoot: String = "/Volumes",
                 targetChanged: @escaping () -> Void = {}) {
        self.localizer = localizer
        self.runner = runner
        self.log = log
        self.repo = repo
        self.deps = deps
        self.engine = engine
        self.devices = devices
        self.defaults = defaults
        self.volumesRoot = volumesRoot
        self.targetChanged = targetChanged
        outDir = defaults.string(forKey: Self.outputKey) ?? ""
        target = BuildTarget.saved(defaults)
        bcOnCPU = defaults.bool(forKey: Self.bcOnCPUKey)
    }

    /// The language and the text this store writes itself: views take strings from the environment.
    package var lang: Lang { get { localizer.lang } set { localizer.lang = newValue } }
    package func t(_ key: String) -> String { localizer.t(key) }

    /// This iPhone build goes straight to a device.
    package var installsDirectly: Bool { target != BuildTarget.mac && !devices.installDevice.isEmpty && !devices.signingTeam.isEmpty }

    /// Home shown as ~ (shorter in a one-line row, and it keeps the account name out of screenshots).
    package func shortPath(_ path: String) -> String { RepoLayout.shortPath(path) }

    package var basePath: String { slot("base").paths.first ?? "" }
    package var keysPath: String { slot("keys").paths.first ?? "" }
    package var updatePath: String { slot("update").paths.first ?? "" }
    package var dlcPaths: [String] { slot("dlc").paths }

    package func slot(_ id: String) -> Slot { slots.first { $0.id == id } ?? slots[0] }
    package func updateSlot(_ id: String, _ body: (inout Slot) -> Void) {
        if let i = slots.firstIndex(where: { $0.id == id }) { body(&slots[i]) }
    }

    /// A build may start: the repository is usable, the base game and the keys are there, the tools are all present and none runs.
    package var canBuild: Bool { repo.isRepo && slot("base").ok && slot("keys").ok && deps.allPresent && !running }

    /// A line for the build card's note, from a store that has no card of its own (the dependency store's failed install).
    package func note(_ text: String) { doneNote = text }

    // MARK: Ending a build

    package func fail(_ why: String) { running = false; doneNote = why; say("✗ " + why); cleanupStaging() }

    package func stop() {
        guard running, !stopping, let proc, proc.isRunning else { return }
        stopping = true
        ProcessGroups.endGroup(proc.processIdentifier)   // the script and every tool it started
    }

    package func cleanupStaging() {
        staging = nil   // the folder stays for the next build of this game (#132, InputStaging)
    }

    /// A stopped build leaves no half-finished stages behind: the progress starts empty again.
    package func resetProgress() { stages = []; log.clear() }

    package func markAllDone() { for i in stages.indices where stages[i].state != .failed { stages[i].state = .done } }

    // MARK: Output parsing

    package func say(_ s: String) { append(s + "\n") }
    package func append(_ s: String) { log.append(s) }

    /// Split into lines (the pipe delivers arbitrary chunks) and turn the script's progress into the stage list.
    /// `--progress json` writes one event per line (stage, step, progress with done / total / frac / eta, stage_end,
    /// say), a count change at most every half second; anything else on the pipe (a tool's traceback) is log text.
    /// The older `--progress lines` form is still understood:
    ///   [12:00:01] [2/7] extract v720896 …
    ///   [12:00:20] ✓ [2/7] extract v720896 (0:19): 30,000 files, 3.4 GB
    package func ingest(_ chunk: String) {
        for line in log.feed(chunk) { handle(line) }
    }

    package func flushLines() {
        if let rest = log.flush() { handle(rest) }
    }

    package func handle(_ line: String) {
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
    package func noteChainChange(_ text: String) {
        guard text.contains("[NOTE] chain-changed"), !chainNoteShown else { return }
        chainNoteShown = true
        showNotice(t("msg.chainChanged"))
    }

    /// One event of `--progress json`: the stage list follows it, and the log gets a readable line (no count updates).
    package func handleEvent(_ kind: String, _ e: [String: Any]) {
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
}
