import Foundation
import NXCore

// The experimental builder (#749): Settings' switch and the nxb binary it uses. With the switch on, the build is `nxb build` and the script is not run.
// The rules (where nxb comes from, the command line, the exit codes) are ExperimentalBuilder in NXCore.

extension BuildStore {
    /// The `nxb` the next build takes, nil when there is none.
    package var experimentalBuilderBinary: String? {
        ExperimentalBuilder.resolve(customPath: experimentalBuilderPath, bundled: bundledBuilder)
    }

    /// Why the build cannot start as `nxb build`: no nxb found, or one that is older than the command line needs. The player's text, nil when it can start (or the switch is off).
    /// A game or a target nxb does not take is not checked here: nxb says so itself (exit code 4) and the launcher shows it.
    func experimentalBuilderProblem() -> String? {
        guard ExperimentalBuilder.featureEnabled, experimentalBuilder else { return nil }
        guard let nxb = experimentalBuilderBinary, let version = runner.output(nxb, ["version"]) else { return t("msg.builderMissingError") }
        return ExperimentalBuilder.isNewEnough(version) ? nil : String(format: t("nxb.tooOld"), version.trimmingCharacters(in: .whitespacesAndNewlines), ExperimentalBuilder.minimumVersion)
    }

    /// The launch of `nxb build`: nxb as the program with the script's own arguments, the engine as its working folder and `NXB_ENGINE`, the tool environment the script gets.
    func experimentalLaunch(nxb: String, scriptArguments: [String], engine: String, environment: [String: String], python: String) -> ProcessLaunch {
        let args = ExperimentalBuilder.arguments(fromScript: scriptArguments)
        say(String(format: t("msg.builderOn"), nxb) + " " + args.joined(separator: " "))
        lastBuildCommand = [nxb] + args
        return ProcessLaunch(executable: nxb, arguments: args, environment: environment.merging(ExperimentalBuilder.environment(engine: engine)) { $1 }, directory: engine, groupPython: python)
    }

    /// What a failed `nxb build` says: its exit code in words and the last error line it printed.
    func experimentalFailureNote(status: Int32) -> String {
        let why = String(format: t(ExperimentalBuilder.exitKey(status)), status)
        guard let line = ExperimentalBuilder.lastError(in: logTail) else { return why }
        return why + " " + line
    }

    /// The environment the build's tools run in, for the script and for `nxb build` alike: PATH, the user, the .NET runtime root, the bundled Python's settings.
    func toolEnvironment(python py: String) -> [String: String] {
        // The root of the runtime the apphost looks for: derived from the detected installation, not assumed to be ~/.dotnet (Homebrew keeps it in .../opt/dotnet/libexec).
        // Only set when the derivation actually answered. TMPDIR as well: .NET 10 on macOS keeps the named mutex its first-run configure takes under $TMPDIR/.dotnet/shm.
        var denv: [String: String] = ["PATH": BuildCommands.toolPath("/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", python: py),
                                      "USER": NSUserName(), "HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8",
                                      "TMPDIR": NSTemporaryDirectory()]
        if let droot = Toolchain.dotnetRoot(for: deps.dotnetPath.isEmpty ? "dotnet" : deps.dotnetPath) {
            denv["DOTNET_ROOT"] = droot   // both variables carry the same root, as the apphost checks the arch-specific one first
            denv["DOTNET_ROOT_ARM64"] = droot
        }
        // The bundled Python lives inside the signed app: a .pyc written there would change what the signature seals
        // (the packages are compiled at bundle time), and a user site must not shadow its pinned packages.
        denv.merge(BundledTools.environment(for: py)) { $1 }
        return denv
    }
}
