// Route C shell (docs/launcher-c-plan.md M2): the library on the frontend-ios package (ShellHost, ShellUI) and the real GameLauncher.
// The games are the frameworks embedded in the app (Frameworks/DmGame<title ID>.framework, each with its manifest, settings list,
// shader libraries and icon), their data the app's Documents/games/<title ID>/ or a folder the player picked. Play computes the
// engine's environment (EngineLaunchPlan, the per-game app's boot_env() order) and hands it to ShellMain.m, which loads the framework
// and starts the host. The per-game settings are the ones ShellHost stores per game, with the per-game app's key names, and reach the
// engine as the same DM_* variables the per-game app's launcher sets.
import Foundation
import SwiftUI
import UIKit
import ShellHost
import ShellUI

/// The real launcher: one game per process. The process becomes the game, so `launch` returns only on a failure to start.
struct EngineGameLauncher: GameLauncher {
    enum Failure: LocalizedError {
        case engine(String)
        var errorDescription: String? { if case .engine(let text) = self { return text }; return nil }
    }

    @MainActor func launch(_ game: LaunchableGame) async throws {
        let fm = FileManager.default
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let bundleURL = Bundle.main.bundleURL
        let envFile = try? String(contentsOf: documents.appendingPathComponent("env.txt"), encoding: .utf8)
        let plan = EngineLaunchPlan.make(game: game, appResources: Bundle.main.resourceURL ?? bundleURL, documents: documents, envFileText: envFile)
        let executableURL = plan.frameworkExecutable
        if let refusal = await Task.detached(priority: .userInitiated, operation: {
            FrameworkSignature.preflightExternal(executable: executableURL, appBundleURL: bundleURL,
                                                 hostTeamID: ProvisioningProfile.bundledTeamIdentifier())
        }).value {
            throw Failure.engine(refusal)
        }
        try plan.createFolders()
        let pairs = plan.environment.sorted { $0.key < $1.key }
        let failure = withCStrings(pairs.map(\.key)) { keys in
            withCStrings(pairs.map(\.value)) { values in
                withCStrings(plan.arguments) { argv in
                    dm_shell_start_game(keys, values, Int32(pairs.count), argv, Int32(plan.arguments.count),
                                        plan.frameworkExecutable.path, plan.imageMarker, plan.logURL.path, plan.workingDirectory.path)
                }
            }
        }
        if let failure { throw Failure.engine(String(cString: failure)) }
        dm_shell_present_game()
    }
}

/// `strdup`ed copies for the C call, freed after it (the engine copies what it keeps).
private func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>) -> R) -> R {
    let copies: [UnsafePointer<CChar>?] = strings.map { UnsafePointer(strdup($0)) }
    defer { copies.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
    return copies.withUnsafeBufferPointer { body($0.baseAddress!) }
}

/// The library's root controller, for ShellMain.m's scene delegate.
@objc(ShellLibrary) final class ShellLibrary: NSObject {
    @MainActor @objc static func makeController() -> UIViewController {
        let info = Bundle.main.infoDictionary ?? [:]
        // The shader chain the host was compiled with (build_shell.sh writes DMChain): a framework built for another one needs an app update
        let chain = (info["DMChain"] as? String).map { "b-" + $0 }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let glueVer = Int(DM_SHELL_GLUE_VERSION)
        Task.detached(priority: .utility) {
            ShellHostBeacon.write(to: documents, glueVersion: glueVer)
        }
        let frameworks = Bundle.main.privateFrameworksURL ?? Bundle.main.bundleURL.appendingPathComponent("Frameworks", isDirectory: true)
        let config = ShellHostConfig(gamesRoot: frameworks, appDataRoot: ShellHostConfig.defaultAppDataRoot(),
                                     hotFrameworksRoot: ShellHostConfig.defaultHotFrameworksRoot(),
                                     environment: HostEnvironment(chain: chain),
                                     updateURL: URL(string: "https://github.com/LNPANDY/NX2Apple/releases"))
        let model = ShellHostModel(config: config, launcher: EngineGameLauncher(), picker: DocumentFolderPicker())
        model.startControllers()
        for entry in model.entries {
            fputs("shell: game \(entry.id) \(entry.title) at \(entry.frameworkURL?.lastPathComponent ?? "-")\(entry.problem.map { ", broken: \($0.reason), \($0.detail)" } ?? "")\n", stderr)
        }
        // DM_SHELL_PLAY=<title ID> in the launch environment (devicectl process launch --environment-variables, the Mac launcher's
        // Play on device) starts that game as Play in the library would, through the same launcher
        if let id = ProcessInfo.processInfo.environment["DM_SHELL_PLAY"], !id.isEmpty {
            let state = model.details.first { $0.id == id }.map { "\($0.game.state)" } ?? "not in the library"
            fputs("shell: DM_SHELL_PLAY=\(id) (\(state))\n", stderr)
            DispatchQueue.main.async { model.play(id) }
        }
        let host = UIHostingController(rootView: ShellHostView(model: model))
        host.view.backgroundColor = .black
        return host
    }
}
