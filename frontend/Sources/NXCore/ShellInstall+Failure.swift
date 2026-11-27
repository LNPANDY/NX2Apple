import Foundation

extension ShellInstaller {
    /// Classifies a failed `xcodebuild` signing run from its full output so earlier root causes (such as a signed-out Xcode account) are not masked by trailing profile errors.
    func signFailureOutcome(_ built: ToolResult, signName: String) -> Outcome {
        if let devModeLine = BuildFailureClassifier.developerModeLine(in: built.output, deviceID: device) {
            end(Self.signStageID, signName, ok: false, detail: devModeLine)
            return Outcome(ok: false, message: fmt("dev.signFailed", devModeLine), step: .sign, failure: .developerMode)
        }
        if BuildFailureClassifier.noSigningAccount(in: built.output) {
            let why = BuildFailureClassifier.noSigningAccountLine(in: built.output)
                ?? built.lastError ?? fmt("msg.exitCode", built.status)
            end(Self.signStageID, signName, ok: false, detail: why)
            return Outcome(ok: false, message: fmt("dev.signFailed", why), step: .sign, failure: .noSigningAccount)
        }
        if BuildFailureClassifier.appIDLimitReached(built.output) {
            let line = built.output.split(whereSeparator: \.isNewline)
                .map(String.init)
                .last { BuildFailureClassifier.appIDLimitReached($0) }
            let why = line ?? built.lastError ?? fmt("msg.exitCode", built.status)
            end(Self.signStageID, signName, ok: false, detail: why)
            var out = Outcome(ok: false, message: fmt("dev.signFailed", why), step: .sign, failure: .appIDLimit)
            out.detail = BuildFailureClassifier.appIDLimitReset(in: built.output)
                ?? AppSignature.oldestFreeAppIDExpiry(forTeam: team, lang: lang) ?? ""
            return out
        }
        // Xcode follows a destination failure with reasons other destinations are ineligible.
        // Those entries can contain "error:" even though they do not describe the requested device.
        let destinationUnavailable = built.output.split(whereSeparator: \.isNewline).contains {
            $0.hasPrefix("xcodebuild: error: Unable to find a destination matching the provided destination specifier:")
        }
        let why = destinationUnavailable ? t("shell.destinationUnavailable") : built.lastError ?? fmt("msg.exitCode", built.status)
        end(Self.signStageID, signName, ok: false, detail: why)
        let message = destinationUnavailable ? t("shell.destinationUnavailableNext") : fmt("dev.signFailed", why)
        return Outcome(ok: false, message: message, step: .sign)
    }
}
