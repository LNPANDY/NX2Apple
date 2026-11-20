import Foundation
import NXCore

// nxkit (Beta) as a build engine (LNPANDY/NX2Apple#1460): `nxb build` from the pair the app bundles or a newer verified one it installed
// (NxkitUpdate.swift). The rules (command line, exit codes, manifest) are NxkitBuilder in NXCore. The stage list comes from nxb's
// `--progress json` events, which BuildStore.handleEvent reads. A failure shows nxb's exit code and last lines, never the NSP script.

/// The update of nxkit, as the engine row shows it.
package enum NxkitUpdateState: Equatable, Sendable {
    case idle
    case checking
    case upToDate
    /// Installed and verified, switched to after the running nxkit build ends.
    case waitingForBuild(String)
    /// A newer release this launcher does not take: not signed, a bad signature, a checksum, another format or macOS.
    case rejected(String, NxkitUpdate.Rejection)
    /// The check got no answer (offline, a rate limit). Shown only after Check for updates.
    case unreachable
}

/// The tone of the engine row's message (DSTone in the view).
package enum NxkitMessageTone: Equatable, Sendable { case info, warning, error }

/// "Did it work?" for one nxkit build or the first start of its app, asked once (NxkitFeedback.swift).
package struct NxkitFeedbackPrompt: Equatable, Identifiable, Sendable {
    package enum Moment: String, Equatable, Sendable { case built, failed, firstLaunch }
    package var id: String { buildID + "." + moment.rawValue }
    package var buildID: String
    package var moment: Moment
    package var titleID: String
    package var gameName: String
    package var gameVersion: String
    package var nxkitVersion: String
    package var engineBuild: String
    package var exitCode: Int32?
    package var log: String

    package init(buildID: String, moment: Moment, titleID: String, gameName: String, gameVersion: String, nxkitVersion: String,
                 engineBuild: String, exitCode: Int32? = nil, log: String = "") {
        self.buildID = buildID; self.moment = moment; self.titleID = titleID; self.gameName = gameName; self.gameVersion = gameVersion
        self.nxkitVersion = nxkitVersion; self.engineBuild = engineBuild; self.exitCode = exitCode; self.log = log
    }

    /// The report the answer opens. A failed build is always "Does not start".
    package func report(_ result: NxkitFeedback.Result) -> NxkitFeedback.Report {
        NxkitFeedback.Report(gameName: gameName, titleID: titleID, gameVersion: gameVersion.isEmpty ? "unknown" : gameVersion, nxkitVersion: nxkitVersion,
                             engineBuild: engineBuild, result: moment == .failed ? .doesNotStart : result, exitCode: exitCode, log: log)
    }
}

/// What the launcher keeps about a game nxkit built: the version, the nxkit-host build and the build's id. Keyed by title ID in the defaults.
package struct NxkitBuildRecord: Codable, Equatable, Sendable {
    package var version: String
    package var hostBuild: String
    package var buildID: String
    package var date: Date
    package init(version: String, hostBuild: String, buildID: String, date: Date) {
        self.version = version; self.hostBuild = hostBuild; self.buildID = buildID; self.date = date
    }
}

extension BuildStore {
    nonisolated package static let nxkitRecordsKey = "nxkitBuilds"
    nonisolated package static let nxkitAskedKey = "nxkitFeedbackAsked"

    package var isNxkitSelected: Bool {
        isUpstreamEnabled(.nxkit) && buildUpstream == .nxkit
    }

    /// The selected engine makes Mac apps only, so the iPhone and iPad target is not offered.
    package var isMacOnlyUpstreamSelected: Bool {
        isUpstreamEnabled(buildUpstream) && buildUpstream.buildsMacOnly
    }

    package var macOnlyNoteKey: String {
        buildUpstream.macOnlyNoteKey ?? "upstream.mngMacOnly"
    }

    func isUpstreamEnabled(_ kind: EngineUpstreamKind) -> Bool {
        switch kind {
        case .nxnative: return true
        case .macNativeGames: return MacNativeGamesBuilder.featureEnabled
        case .s2arm: return S2ArmBuilder.featureEnabled
        case .nxkit: return NxkitBuilder.featureEnabled && nxkitAvailability == .available
        }
    }

    /// nxkit (Beta) is in the engine pop-up: this Mac runs it (macOS 26, Apple silicon) and a pair is there.
    package var nxkitSelectable: Bool { isUpstreamEnabled(.nxkit) && nxkitInstalled }

    /// A pair is there (bundled or installed).
    package var nxkitInstalled: Bool { nxkitInUse != nil }

    /// "Send feedback" on the Build page: a new issue in v0lumehi/nxkit, prefilled with the nxkit version in use. Only opened in the browser.
    package var nxkitSendFeedbackURL: URL {
        NxkitFeedback.feedbackURL(nxkitVersion: nxkitInUse?.version ?? "", engineBuild: nxkitInUse?.hostBuild ?? "")
    }

    /// The pair the next build runs: the installed version state.json names when it is not older than the bundled one, else the bundled pair.
    package func refreshNxkit() {
        nxkitInUse = nxkitVersions.resolve(bundled: nxkitBundledFolder)
        nxkitPreviousVersion = nxkitVersions.previousVersion
    }

    /// The engine row's line: the version in use and the update's state, joined like nxnative's ("nxkit 0.10.3 · up to date").
    package var nxkitStatusLine: String {
        guard let inUse = nxkitInUse else { return t("nxkit.missing") }
        let version = String(format: t("nxkit.version"), inUse.version)
        switch nxkitUpdate {
        case .checking: return version + " · " + t("nxkit.checking")
        case .upToDate: return version + " · " + t("nxkit.upToDate")
        case .waitingForBuild(let v): return version + " · " + String(format: t("nxkit.waiting"), v)
        case .rejected(let v, .unsigned): return version + " · " + String(format: t("nxkit.notSigned"), v)
        case .rejected(let v, _): return version + " · " + String(format: t("nxkit.available"), v)
        case .idle, .unreachable: return version
        }
    }

    /// The engine row's message: what keeps a newer release out, a check without an answer, or the Beta note.
    package var nxkitStatusMessage: (tone: NxkitMessageTone, text: String) {
        switch nxkitUpdate {
        case .rejected(let v, .unsigned): return (.info, String(format: t("nxkit.unsigned"), v))
        case .rejected(let v, .badSignature): return (.error, String(format: t("nxkit.badSignature"), v))
        case .rejected(let v, .checksum): return (.error, String(format: t("nxkit.checksumFailed"), v))
        case .rejected(let v, .incompatible(.macOS(let need))): return (.info, String(format: t("nxkit.needsMacOS"), v, need))
        case .rejected(let v, .incompatible): return (.info, String(format: t("nxkit.incompatible"), v))
        case .rejected(let v, .download), .rejected(let v, .unpack), .rejected(let v, .incomplete): return (.warning, String(format: t("nxkit.updateFailed"), v))
        case .unreachable: return (.warning, t("nxkit.unreachable"))
        default: return (.info, t("nxkit.betaNote"))
        }
    }

    /// Asks GitHub for the latest nxkit release, installs it when it is newer and verifies, and switches when no nxkit build runs.
    /// `manual`: from the row's Check for updates. The launch check runs only with "Update automatically when the app opens" on, and stays quiet offline.
    @discardableResult
    package func checkNxkitUpdate(manual: Bool) -> Task<Void, Never> {
        guard isUpstreamEnabled(.nxkit), nxkitUpdate != .checking, manual || nxkitAutoUpdate() else { return Task {} }
        nxkitUpdate = .checking
        let store = nxkitVersions
        let transport = upstreamTransport
        let inUse = nxkitInUse?.version ?? ""
        let (key, prepare) = (nxkitPublicKey, nxkitPrepare)
        return Task { [weak self] in
            let result = await Task.detached { store.checkAndInstall(inUse: inUse, transport: transport, publicKey: key, prepare: prepare) }.value
            guard let self else { return }
            switch result {
            case .upToDate: self.nxkitUpdate = .upToDate
            case .unreachable: self.nxkitUpdate = manual ? .unreachable : .idle
            case .rejected(let v, let why): self.nxkitUpdate = why == .cancelled ? .idle : .rejected(v, why)
            case .installed(let v): self.switchNxkit(to: v)
            }
        }
    }

    /// The switch to an installed version, now or after the running nxkit build.
    func switchNxkit(to version: String) {
        if running && nxkitRun {
            nxkitPendingVersion = version
            nxkitUpdate = .waitingForBuild(version)
            return
        }
        nxkitPendingVersion = nil
        try? nxkitVersions.switchTo(version)
        refreshNxkit()
        nxkitUpdate = .upToDate
    }

    /// After a build: the version that waited for it takes over.
    func applyPendingNxkitSwitch() {
        guard let version = nxkitPendingVersion else { return }
        switchNxkit(to: version)
    }

    /// The state gallery's fixtures set the update's state directly (GalleryNxkit.swift).
    package func setNxkitUpdateForGallery(_ state: NxkitUpdateState) { nxkitUpdate = state }

    /// "…" › Use previous version.
    package func useNxkitPreviousVersion() {
        guard !running, nxkitPreviousVersion != nil else { return }
        try? nxkitVersions.rollback()
        refreshNxkit()
        nxkitUpdate = .idle
    }

    /// Why the build cannot start with nxkit, in the player's words. nil when it can (or nxkit is not selected).
    func nxkitProblem() -> String? {
        guard isNxkitSelected else { return nil }
        guard target == BuildTarget.mac else { return t("upstream.nxkitMacOnly") }
        guard let inUse = nxkitInUse, NxkitBuilder.canBuildApps(inUse.folder) else { return t("nxkit.missing") }
        if let folder = gameFolder, folder.nup == nil { return t("upstream.nxkitNoDumpFolder") }
        return nil
    }

    /// The folder `nxb build` reads: the picked files' folder, or a folder of links when the files, or other games' packages, lie apart or together.
    /// nil when the links could not be made. A NUP goes by its own path, not through here.
    func nxkitSourceFolder(workDir: String) -> String? {
        let baseDir = inputFolder
        let allPaths = [basePath, updatePath] + dlcPaths
        let dirs = Set(allPaths.filter { !$0.isEmpty }.map { ($0 as NSString).deletingLastPathComponent })
        let picked = Set(allPaths.filter { !$0.isEmpty }.map { ($0 as NSString).lastPathComponent })
        let unpicked = ((try? FileManager.default.contentsOfDirectory(atPath: baseDir)) ?? []).filter {
            ["nsp", "xci", "nsz", "xcz"].contains(($0 as NSString).pathExtension.lowercased()) && !picked.contains($0)
        }
        var staged = allPaths
        if let base = selectedTitleID.flatMap({ UInt64($0, radix: 16) }) ?? TitleID.parse(basePath) {
            let app = base & ~0xFFF
            for f in unpicked {
                guard let tid = TitleID.parse(f) else { continue }
                let low = tid & 0xFFF
                let owner = low == 0 ? tid : (low == 0x800 ? tid & ~0xFFF : (tid & ~0xFFF) - 0x1000)
                guard owner == app else { continue }
                if low == 0x800 && !updatePath.isEmpty { continue }
                if low != 0 && low != 0x800 && tid <= app { continue }
                staged.append(baseDir + "/" + f)
            }
        }
        guard dirs.count > 1 || !unpicked.isEmpty || staged.contains(where: InputStaging.needsLowercaseName) else {
            staging = nil
            return baseDir
        }
        let tmp = InputStaging.folder(workDir: workDir)
        guard InputStaging.sync(files: staged, into: tmp) > 0 else { return nil }
        staging = tmp
        if !unpicked.isEmpty {
            say(String(format: t("msg.stagedFromSharedFolder"), (basePath as NSString).lastPathComponent))
        }
        return tmp
    }

    /// The build log's header names the engine and the version that runs, then the command.
    func nxkitLaunch(input: String, nup: String?, workDir: String, outputAppPath: String) -> ProcessLaunch? {
        guard let inUse = nxkitInUse else { return nil }
        nxkitRunSelection = inUse
        nxkitBuildID = UUID().uuidString
        let args = NxkitBuilder.arguments(input: input, nup: nup, keysPath: keysPath, outputAppPath: outputAppPath, workDir: workDir,
                                          titleID: selectedTitleID ?? gameTitleID)
        let nxb = NxkitBuilder.builderPath(in: inUse.folder)
        let host = inUse.hostBuild.isEmpty ? "" : String(inUse.hostBuild.prefix(12))
        say(String(format: t(inUse.source == .bundled ? "nxkit.logHeaderBundled" : "nxkit.logHeaderInstalled"), inUse.version, host))
        say(String(format: t("msg.running"), nxb) + " " + args.joined(separator: " "))
        lastBuildCommand = [nxb] + args
        let base = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
                    "USER": NSUserName(), "HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8", "TMPDIR": NSTemporaryDirectory()]
        return ProcessLaunch(executable: nxb, arguments: args, environment: NxkitBuilder.environment(folder: inUse.folder, base: base), directory: workDir)
    }

    /// Stop: nxb is not started in a group of its own (that needs Python, which nxkit does not), and it ends on SIGINT with its own exit code 130.
    /// What is left after 5 s is killed.
    func endNxkitProcess(_ pid: pid_t) {
        guard pid > 1 else { return }
        kill(pid, SIGINT)
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
    }

    // MARK: The end of a build

    /// nxb stopped with `status`: its exit code in words and its last lines in the failure card, the question "Did it work?".
    func finishFailedNxkitBuild(status: Int32) {
        let lines = NxkitBuilder.outputTail(logTail, count: 12)
        failure = BuildFailure(kind: .nxkit, gameName: nil, detail: String(status), lines: lines)
        let why = String(format: t(NxkitBuilder.exitKey(status)), status)
        let note = NxkitBuilder.lastError(in: logTail).map { why + " " + $0 } ?? why
        if let i = stages.lastIndex(where: { $0.state == .running }) {
            stages[i].state = .failed
            stages[i].detail = String(format: t("msg.exitCode"), status)
        }
        doneNote = note
        say("✗ " + note)
        askNxkitFeedback(.failed, gameVersion: "", exitCode: status)
    }

    /// The Mac app is in place: the game remembers that nxkit built it, and the question is asked.
    func finishNxkitBuild(app: URL) {
        let version = (try? MacGameBundle.read(app))?.version ?? ""
        if let tid = gameTitleID ?? (try? MacGameBundle.read(app))?.titleID, let sel = nxkitRunSelection {
            var records = nxkitRecords
            records[tid.uppercased()] = NxkitBuildRecord(version: sel.version, hostBuild: sel.hostBuild, buildID: nxkitBuildID, date: Date())
            nxkitRecords = records
        }
        askNxkitFeedback(.built, gameVersion: version, exitCode: 0)
    }

    func askNxkitFeedback(_ moment: NxkitFeedbackPrompt.Moment, gameVersion: String, exitCode: Int32?) {
        guard let sel = nxkitRunSelection, !nxkitBuildID.isEmpty, !nxkitFeedbackAsked(nxkitBuildID + "." + moment.rawValue) else { return }
        nxkitFeedback = NxkitFeedbackPrompt(buildID: nxkitBuildID, moment: moment, titleID: (gameTitleID ?? buildKey).uppercased(), gameName: gameName,
                                            gameVersion: gameVersion, nxkitVersion: sel.version, engineBuild: sel.hostBuild, exitCode: exitCode, log: logTail)
    }

    // MARK: What the launcher keeps

    /// The games nxkit built, by upper-case title ID.
    package var nxkitRecords: [String: NxkitBuildRecord] {
        get {
            guard let data = defaults.data(forKey: Self.nxkitRecordsKey),
                  let records = try? JSONDecoder().decode([String: NxkitBuildRecord].self, from: data) else { return [:] }
            return records
        }
        set { if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: Self.nxkitRecordsKey) } }
    }

    package func nxkitRecord(_ titleID: String) -> NxkitBuildRecord? { nxkitRecords[titleID.uppercased()] }

    package func nxkitFeedbackAsked(_ id: String) -> Bool {
        (defaults.stringArray(forKey: Self.nxkitAskedKey) ?? []).contains(id)
    }

    /// The question is answered or put away: it is not asked again for this build and moment.
    package func markNxkitFeedbackAsked(_ id: String) {
        var asked = defaults.stringArray(forKey: Self.nxkitAskedKey) ?? []
        if !asked.contains(id) { asked.append(id) }
        defaults.set(Array(asked.suffix(200)), forKey: Self.nxkitAskedKey)
        objectWillChange.send()
        if nxkitFeedback?.id == id { nxkitFeedback = nil }
    }
}
