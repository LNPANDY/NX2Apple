import Foundation
import Combine
import NXCore

// What a failed build says and what its card offers: the classification, "Build anyway" and the fix buttons (LNPANDY/NX2Apple#387).

extension BuildStore {
    /// A failed build's log read for the script's known early stops: the card under the build button then says what
    /// happened and what to do. An unknown stop leaves the note (the last line of the log) as it is.
    package func noteFailure() {
        let f = BuildFailureClassifier.classify(logTail, inputs: failureInputs())
        guard f.kind != .unknown else { failure = nil; return }
        failure = f
        doneNote = failureWhat(f)
    }

    /// The Save to folder, picked in the app's folder panel (`chooseFolder`). Clears the cloud-folder stop, since the next build looks at the new folder.
    package func chooseBuildFolder() {
        guard let path = chooseFolder() else { return }
        outDir = path
        if failure?.kind == .cloudFolder { failure = nil; doneNote = "" }
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
        guard let f = BuildFailureClassifier.classifyInstall(step, error: error, teamListed: listed) else { failure = nil; return }
        failure = f
        doneNote = failureWhat(f)
    }

    /// The first sentence of a failure's hint (it names the game of a 32-bit program when the message does).
    package func failureWhat(_ f: BuildFailure) -> String {
        if f.kind == .a32Program, let name = f.gameName { return String(format: t("fail.a32Program.whatNamed"), name) }
        if f.kind == .driveMissing, let name = f.detail { return String(format: t("fail.driveMissing.whatNamed"), name) }
        if f.kind == .diskFull, let gb = f.detail { return String(format: t("fail.diskFull.whatNeeds"), gb) }
        return t(f.kind.whatKey)
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
        startBuild()
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
            installRow("dotnet")
        case .iosSDK:
            installRow(Dep(id: "xcode", name: "dep.xcode", hint: "dep.xcode.hint", present: false, installCmd: Toolchain.iosPlatformCmd))
        case .cltSelected:
            if let xcode = Toolchain.installedXcode() {
                installRow(Dep(id: "xcode", name: "dep.xcode", hint: "dep.xcode.hint", present: false, installCmd: Toolchain.selectXcodeCmd(xcode)))
            }
        case .zbic:
            installRow("python")   // the venv install, which now names zbic
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

    /// Xcode itself: its Settings > Accounts is where a team is signed in, and Xcode has no address that opens that pane.
    package func openXcode() {
        guard let app = Toolchain.installedXcode() else { return }
        openApp(URL(fileURLWithPath: app))
    }

    /// Whether the card's fix button is already running its command.
    package func fixBusy(_ kind: BuildFailureKind) -> Bool {
        guard [.translator, .iosSDK, .cltSelected, .zbic].contains(kind) else { return false }
        let id = kind == .translator ? "dotnet" : kind == .zbic ? "python" : "xcode"
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
