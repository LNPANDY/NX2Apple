import Foundation
import Combine
import NXCore

// What a failed build says and what its card offers: the classification, "Build anyway" and the fix buttons (LNPANDY/NX2Apple#387).

struct FastRefreshRequest {
    var titleID: String
    var targetName: String
    var outDir: String?
    var gameName: String?
    var existingMacAppPath: String?
    var externalImgPath: String?
    var cheatsDir: String?
    var knownArchivePath: String?
    var forceShaderRebuildTrailer: Bool
}

enum InstallRecovery {
    case install(
        framework: String,
        titleID: String,
        name: String,
        archive: String,
        dataOnly: Bool,
        didUpdateImg: Bool,
        updatedImgPath: String,
        fastRefresh: FastRefreshRequest?
    )
    case installBuilt(framework: String, titleID: String, name: String)
    case installBatch(games: [DeferredShellGame], dataOnly: Bool)
    case resign(app: String, device: String, then: (() -> Void)?)
    case sendData(bundle: String?)
    case resumeClosure(() -> Void)
}

struct InstallRecoveryState {
    var pending: InstallRecovery?
    var lastFastRefresh: FastRefreshRequest?
}

@MainActor private final class InstallRecoveryBox {
    var state = InstallRecoveryState()
}

@MainActor private let installRecoveryTable = NSMapTable<BuildStore, InstallRecoveryBox>.weakToStrongObjects()

extension BuildStore {
    var installRecovery: InstallRecoveryState {
        get { installRecoveryTable.object(forKey: self)?.state ?? InstallRecoveryState() }
        set {
            let box = installRecoveryTable.object(forKey: self) ?? {
                let created = InstallRecoveryBox()
                installRecoveryTable.setObject(created, forKey: self)
                return created
            }()
            box.state = newValue
        }
    }

    func setInstallRecovery(_ recovery: InstallRecovery) {
        installRecovery.pending = recovery
    }

    func clearInstallRecovery(includeFastRefresh: Bool = false) {
        installRecovery.pending = nil
        if includeFastRefresh {
            installRecovery.lastFastRefresh = nil
        }
    }

    /// Retry the failed installation with its original built games, without restarting the game builder.
    /// When the built framework or archive is no longer on disk, falls back to rebuilding cleanly.
    package func retryShellInstall() {
        guard !running else { return }
        guard let recovery = installRecovery.pending else {
            failure = nil; done = false; doneNote = ""
            runBuild()  // Non-shell or pre-build pairing checks retain their existing recovery path.
            return
        }
        failure = nil; done = false; doneNote = ""
        let fm = FileManager.default
        switch recovery {
        case .install(let framework, let titleID, let name, let archive, let dataOnly,
                      let didUpdateImg, let updatedImgPath, let fastRefresh):
            let hasArchive = archive.isEmpty || fm.fileExists(atPath: archive)
            let valid = dataOnly
                ? (!archive.isEmpty && fm.fileExists(atPath: archive))
                : (fm.fileExists(atPath: framework) && hasArchive)
            guard valid else {
                clearInstallRecovery(includeFastRefresh: true)
                fallbackToRebuild(fastRefresh: fastRefresh)
                return
            }
            installShell(framework: framework, titleID: titleID, name: name, archive: archive,
                         dataOnly: dataOnly, didUpdateImg: didUpdateImg, updatedImgPath: updatedImgPath)
        case .installBuilt(let framework, let titleID, let name):
            let mirror = ShellInstall.mirroredFramework(root: shellRoot, titleID: titleID)
            let resolvedFramework = fm.fileExists(atPath: framework) ? framework
                : (fm.fileExists(atPath: mirror) ? mirror : nil)
            guard let resolvedFramework else {
                clearInstallRecovery(includeFastRefresh: true)
                if canBuild { runBuild() }
                else { installBuiltShell(framework: framework, titleID: titleID, name: name) }
                return
            }
            installBuiltShell(framework: resolvedFramework, titleID: titleID, name: name)
        case .installBatch(let games, let dataOnly):
            let allPresent = games.allSatisfy { game in
                let hasArchive = game.archive.isEmpty || fm.fileExists(atPath: game.archive)
                if dataOnly { return hasArchive }
                let mirror = ShellInstall.mirroredFramework(root: shellRoot, titleID: game.titleID)
                return (fm.fileExists(atPath: game.framework) || fm.fileExists(atPath: mirror)) && hasArchive
            }
            guard allPresent else {
                clearInstallRecovery(includeFastRefresh: true)
                if games.count == 1 && canBuild { runBuild() }
                else { installShellBatch(games, dataOnly: dataOnly) }
                return
            }
            installShellBatch(games, dataOnly: dataOnly)
        case .resign(let app, let device, let then):
            let valid = fm.fileExists(atPath: app)
                && ShellInstall.paths(ofApp: app).map { fm.fileExists(atPath: $0.project) } == true
            if !valid { clearInstallRecovery(includeFastRefresh: true) }
            resignOnDevice(app: app, device: device, then: then)
        case .sendData(let bundle):
            guard !archivePath.isEmpty, fm.fileExists(atPath: archivePath) else {
                let fastRefresh = installRecovery.lastFastRefresh
                clearInstallRecovery(includeFastRefresh: true)
                fallbackToRebuild(fastRefresh: fastRefresh)
                return
            }
            sendGameData(bundle: bundle)
        case .resumeClosure(let resume):
            clearInstallRecovery()
            resume()
        }
    }

    private func fallbackToRebuild(fastRefresh: FastRefreshRequest?) {
        if let fastRefresh {
            startFastRefresh(
                titleID: fastRefresh.titleID,
                targetName: fastRefresh.targetName,
                outDir: fastRefresh.outDir,
                gameName: fastRefresh.gameName,
                existingMacAppPath: fastRefresh.existingMacAppPath,
                externalImgPath: fastRefresh.externalImgPath,
                cheatsDir: fastRefresh.cheatsDir,
                knownArchivePath: fastRefresh.knownArchivePath,
                forceShaderRebuildTrailer: fastRefresh.forceShaderRebuildTrailer
            )
        } else {
            runBuild()
        }
    }
    /// A failed build's log read for the script's known early stops: the card under the build button then says what
    /// happened and what to do. An unknown stop leaves the note (the last line of the log) as it is.
    package func noteFailure() {
        let f = BuildFailureClassifier.classify(logTail, inputs: failureInputs())
        guard f.kind != .unknown else { failure = nil; return }
        failure = f
        doneNote = failureWhat(f)
    }

    /// Another game is chosen while a stopped build's failure shows: the failure, its note and its stages belong to the game that
    /// failed, so they go. The same game chosen again (its files read once more) keeps them. Nothing changes while a build runs
    /// or while no game is chosen.
    func dropFailureOfOtherGame() {
        guard !running, failure != nil, let key = failureGameKey, !basePath.isEmpty || gameFolder != nil, buildKey != key else { return }
        failure = nil
        done = false
        doneNote = ""
        stages = []
        clearInstallRecovery(includeFastRefresh: true)
    }

    /// The Save to folder, picked in the app's folder panel (`chooseFolder`). Clears the cloud-folder stop, since the next build looks at the new folder.
    package func chooseBuildFolder() {
        guard let path = chooseFolder() else { return }
        outDir = path
        if failure?.kind == .cloudFolder || failure?.kind == .volumeFormat { failure = nil; doneNote = "" }
    }

    /// What the classifier may check besides the log: the keys file and where the game files are.
    package func failureInputs() -> BuildFailureClassifier.Inputs {
        BuildFailureClassifier.Inputs(keysPath: keysPath, paths: ([basePath, updatePath, gameDir] + dlcPaths).filter { !$0.isEmpty },
                                      volumes: volumesRoot)
    }

    /// A failed step of an install on a device, as a card when the launcher can say more than the tool's line.
    /// Called after `finishInstall`, which put the tool's own error into the note.
    package func noteInstallFailure(_ step: BuildFailureClassifier.InstallStep, error: String) {
        let teamsOfMac = devices.readTeams
        let listed = teamsOfMac().contains { $0.id == devices.signingTeam }
        var classified = BuildFailureClassifier.classifyInstall(step, error: error, teamListed: listed)
        if classified?.kind != .appIDLimit, !logTail.isEmpty, BuildFailureClassifier.appIDLimitReached(logTail) {
            classified = BuildFailureClassifier.classifyInstall(step, error: logTail, teamListed: listed)
        }
        guard let f = classified else { failure = nil; return }
        failure = f
        doneNote = failureWhat(f)
    }

    /// The first sentence of a failure's hint (it names the game of a 32-bit program when the message does).
    package func failureWhat(_ f: BuildFailure) -> String {
        if f.kind == .a32Program, let name = f.gameName { return String(format: t("fail.a32Program.whatNamed"), name) }
        if f.kind == .driveMissing, let name = f.detail { return String(format: t("fail.driveMissing.whatNamed"), name) }
        if f.kind == .diskFull, let gb = f.detail { return String(format: t("fail.diskFull.whatNeeds"), gb) }
        if f.kind == .psoDiskFull, let gb = f.detail { return String(format: t("fail.psoDiskFull.whatNeeds"), gb) }
        if f.kind == .updateMismatch, let versions = f.detail { return String(format: t("macFail.updateMismatch.whatVersions"), versions) }
        if f.kind == .nxkit, let code = f.detail { return String(format: t("fail.nxkit.whatCode"), code) }
        if f.kind == .appIDLimit, let date = f.detail, !date.isEmpty { return String(format: t("fail.appIDLimit.whatUntil"), date) }
        return t(f.kind.whatKey)
    }

    package func buildTitle(_ titleID: String) {
        guard canBuild, failure?.titleIDs.contains(titleID) == true else { return }
        selectedTitleID = titleID
        runBuild()
    }

    /// "Build anyway": asks first. Nothing is armed until `confirmBuildAnyway`.
    package func requestBuildAnyway() {
        guard !running, let kind = failure?.kind, kind.overrideFlag != nil else { return }
        confirmingOverride = kind
    }

    package func cancelBuildAnyway() { confirmingOverride = nil }

    package func confirmBuildAnyway() {
        guard let kind = confirmingOverride else { return }
        confirmingOverride = nil
        armedOverride = kind
        runBuild()
    }

    /// The flag the next build runs with, once: the arm is cleared here, so a later build never inherits it.
    package func takeOverrideFlag() -> String? {
        defer { armedOverride = nil }
        return armedOverride?.overrideFlag
    }

    /// The card's fix buttons run the dependency rows' own commands (the same installDep as Settings).
    package func fixBuildFailure(_ kind: BuildFailureKind) {
        switch kind {
        case .translator:
            // No row of the tools panel: a build needs no .NET (#1404), only an engine whose translator is not a native executable does.
            installRow(Dep(id: "dotnet", name: "dep.dotnet", hint: "dep.dotnet.hint", present: false, installCmd: DependencyCheck.dotnetInstallCmd))
        case .iosSDK:
            installRow(Dep(id: "xcode", name: "dep.xcode", hint: "dep.xcode.hint", present: false, installCmd: Toolchain.iosPlatformCmd))
        case .metalToolchain:
            installRow(Dep(id: "metal", name: "dep.metal", hint: "dep.metal.hint", present: false, installCmd: Toolchain.metalToolchainCmd))
        case .cltSelected:
            if XcodeSelection.app(in: defaults) != nil {
                openXcode()
            } else if let xcode = Toolchain.installedXcode(customApp: nil) {
                installRow(Dep(id: "xcode", name: "dep.xcode", hint: "dep.xcode.hint", present: false, installCmd: Toolchain.selectXcodeCmd(xcode)))
            }
        case .zbic:
            installRow("python")   // the venv install, which now names zbic
        case .keys, .keysOld:
            if let chooseKeys { chooseKeys() } else { pickFiles(kind: .keys) }   // the same picker as the keys row
        case .updateMismatch:
            pickFiles(kind: .update)
        case .mngSharedFonts:
            selectUpstream(.nxnative)
            failure = nil
            doneNote = ""
        case .severalGames, .noTitleID, .diskFull, .staleProfile:
            showFailureFolder()
        case .cloudFolder, .volumeFormat:
            chooseBuildFolder()
        case .teamTaken, .noSigningAccount, .freeAccountLimit, .appIDLimit:
            openXcode()
        case .deviceTransfer, .devicePairing, .developerMode:
            retryShellInstall()
        case .shellDataIncomplete:
            retryShellData()
        default: break
        }
    }

    /// The folder the failure is about, in the Finder: the folder of the game files, else the one the message names. For a full
    /// disk the build folder (`<title ID>_build`, beside the game files) when it is there, since that is where the space went.
    package func showFailureFolder() {
        guard let f = failure else { return }
        var folder = gameDir.isEmpty ? (f.detail ?? "") : gameDir
        if f.kind == .diskFull, !gameDir.isEmpty {
            let built = ((try? FileManager.default.contentsOfDirectory(atPath: gameDir)) ?? []).sorted().first { $0.hasSuffix("_build") }
            if let built { folder = gameDir + "/" + built }
        }
        guard !folder.isEmpty else { return }
        revealFolder(URL(fileURLWithPath: folder))
    }

    package var installedXcode: String? { Toolchain.installedXcode(customApp: XcodeSelection.app(in: defaults)) }

    /// Xcode itself: its Settings > Accounts is where a team is signed in, and Xcode has no address that opens that pane.
    package func openXcode() {
        guard let app = installedXcode else { return }
        openApp(URL(fileURLWithPath: app))
    }

    /// Whether the card's fix button is already running its command.
    package func fixBusy(_ kind: BuildFailureKind) -> Bool {
        guard [.translator, .iosSDK, .metalToolchain, .cltSelected, .zbic].contains(kind) else { return false }
        let id = kind == .translator ? "dotnet" : kind == .zbic ? "python" : kind == .metalToolchain ? "metal" : "xcode"
        return deps.isInstalling(id)
    }

    /// The row `id` of the tools panel installs, or the row given (a fix the panel has no row for).
    package func installRow(_ id: String) {
        if let d = deps.deps.first(where: { $0.id == id }) { _ = deps.install(d) }
    }
    package func installRow(_ dep: Dep) {
        _ = deps.install(dep)
    }
}
