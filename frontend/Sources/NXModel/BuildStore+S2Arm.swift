import Foundation
import NXCore

extension BuildStore {
    package var isS2ArmSelected: Bool {
        S2ArmBuilder.featureEnabled && buildUpstream == .s2arm
    }

    func s2armProblem() -> String? {
        guard isS2ArmSelected else { return nil }
        guard S2ArmBuilder.isUsableTree(s2armPath) else {
            return s2armPath.isEmpty ? t("upstream.s2armMissing") : String(format: t("upstream.s2armInvalid"), shortPath(s2armPath))
        }
        return nil
    }

    func s2armLaunch(python py: String, sourceInput: String, workDir: String, eventsFile: String, environment: [String: String]) -> ProcessLaunch {
        let unencrypted = gameFolder != nil || (sourceInput as NSString).pathExtension.lowercased() == "nup"
        let isMac = target == BuildTarget.mac
        let deviceUDID = isMac ? nil : (devices.installDevice.isEmpty ? nil : devices.installDevice)
        let args = S2ArmBuilder.arguments(
            tree: s2armPath,
            sourceInput: sourceInput,
            keysPath: keysPath,
            isUnencryptedInput: unencrypted,
            workDir: workDir,
            isMacTarget: isMac,
            titleID: selectedTitleID ?? gameTitleID,
            deviceUDID: deviceUDID,
            eventsFile: eventsFile
        )
        let bash = "/bin/bash"
        say(String(format: t("msg.running"), bash) + " " + args.joined(separator: " "))
        lastBuildCommand = [bash] + args
        let mergedEnv = environment.merging(S2ArmBuilder.environment(pythonPath: py, keysPath: keysPath, isUnencryptedInput: unencrypted)) { $1 }
        return ProcessLaunch(executable: bash, arguments: args, environment: mergedEnv, directory: s2armPath, groupPython: py)
    }

    func finishS2ArmBuild() {
        let eventsText = try? String(contentsOfFile: s2armEventsPath, encoding: .utf8)
        let summary = eventsText.flatMap(S2ArmBuilder.parseEvents)
        markAllDone()
        running = false
        done = true
        if let ipa = summary?.ipaPath, !ipa.isEmpty {
            exportedIPAPath = ipa
            say("✓ " + shortPath(ipa))
            doneNote = String(format: t("msg.ipaAt"), shortPath(ipa))
        } else if let root = summary?.macRootPath, !root.isEmpty {
            say("✓ " + shortPath(root))
            doneNote = String(format: t("upstream.s2armMacDone"), shortPath(root))
        } else {
            doneNote = t("upstream.s2armDone")
        }
        cleanupStaging()
    }

    func s2armFailureNote(status: Int32) -> String {
        let eventsText = try? String(contentsOfFile: s2armEventsPath, encoding: .utf8)
        if let line = S2ArmBuilder.lastError(in: logTail, eventsText: eventsText) {
            return String(format: t("msg.buildFailedReason"), line)
        }
        return String(format: t("msg.buildFailed"), status)
    }
}
