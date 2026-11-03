import Foundation

// The shared app as an unsigned IPA (LNPANDY/NX2Apple#416): no device and no signing team. The same project as the install
// (build_shell.sh --prepare-xcode), built by xcodebuild with signing off, the executable signed ad-hoc to carry its entitlements
// (as build_ipa.sh does for the one-game IPA), then zipped as Payload/<app>.app. A sideloading tool signs the result. The game data
// stays out: the player copies romfs.img into the app's Documents/games/<title ID>/ after installing it.

extension ShellInstall {
    /// The IPA's file name.
    package static let ipaName = "NX2Apple.ipa"

    /// Everything the export writes lives in this folder of the shell root, apart from the project.
    package static func exportFolder(root: String) -> String { root + "/export" }
    package static func ipaPath(root: String) -> String { exportFolder(root: root) + "/" + ipaName }
    /// Its own derived data: the unsigned build must not replace the signed app that an install, a reinstall and a re-sign use.
    package static func exportDerivedData(root: String) -> String { exportFolder(root: root) + "/derived-data" }
    package static func exportAppPath(root: String) -> String { exportDerivedData(root: root) + "/Build/Products/Release-iphoneos/" + appName }
    /// The folder the app is copied into as `Payload/<app>.app` before it is zipped.
    package static func exportStage(root: String) -> String { exportFolder(root: root) + "/stage" }

    /// The shell project (prepared by the install's own script call) built for iOS with signing off, as build_shell.sh --build does.
    /// `bundleID` is the one shell.json holds, so the IPA keeps the identifier of the install.
    package static func exportBuildCommand(xcrun: String, root: String, bundleID: String) -> [String] {
        [xcrun, "xcodebuild", "-project", projectFolder(root: root) + "/" + projectName, "-scheme", scheme,
         "-configuration", "Release", "-destination", "generic/platform=iOS", "-derivedDataPath", exportDerivedData(root: root),
         "PRODUCT_BUNDLE_IDENTIFIER=\(bundleID)", "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "CODE_SIGN_IDENTITY=", "build"]
    }

    /// The entitlements file `build_shell.sh --prepare-xcode` writes into the project (the Increased Memory Limit request).
    package static func entitlementsPath(root: String) -> String { projectFolder(root: root) + "/Gen/DmShell.entitlements" }

    /// An unsigned app has no signature to carry the entitlements, so a sideloader would lose the request. The executable gets an
    /// ad-hoc signature that holds them, which the sideloader replaces and keeps the entitlements of (build_ipa.sh does the same).
    package static func entitlementsCommand(app: String, entitlements: String) -> [String] {
        ["/usr/bin/codesign", "--force", "--sign", "-", "--entitlements", entitlements, app + "/" + scheme]
    }

    /// codesign refuses a file with a resource fork or Finder information.
    package static func cleanAttributesCommand(app: String) -> [String] { ["/usr/bin/xattr", "-cr", app + "/" + scheme] }

    /// The IPA: the stage folder holds `Payload/<app>.app`, and ditto writes it with Payload as the root (see `BuildCommands.ipaCommand`).
    package static func zipCommand(root: String) -> [String] {
        BuildCommands.ipaCommand(payload: exportStage(root: root) + "/Payload", ipa: ipaPath(root: root))
    }
}

extension ShellInstaller {
    package static let exportBuildStageID = 1012, exportPackStageID = 1013

    /// Steps 3 and 4 of the install, which the export shares: the library with this game, and the shell's project.
    /// Exactly one of `failure` and (`library`, `env`) is set. `notes` name the games left out because their framework is incomplete.
    func prepareShell(framework: String, titleID: String, name: String)
        -> (library: ShellLibrary?, env: [String: String]?, failure: Outcome?, notes: [String]) {
        // 3: the library
        ShellInstall.sweepDiscarded(in: ShellInstall.frameworksMirror(root: root))
        var library = ShellLibrary.load(root: root)
        if !team.isEmpty { library.team = team }   // the export has no team: keep the one an install stored
        library.add(.init(titleID: titleID, name: name, framework: framework))
        mirrorFrameworks(&library)
        library.dropMissing()
        let checked = leaveOutIncomplete(&library, titleID: titleID, name: name)   // ShellFrameworks.swift
        if let why = checked.failure {
            let projectName = t("shell.projectStage")
            begin(Self.projectStageID, projectName)
            end(Self.projectStageID, projectName, ok: false, detail: why)
            return (nil, nil, Outcome(ok: false, message: fmt("shell.projectFailed", why)), [])
        }
        // The 16:9 banner of the shell's library for every game in it (ShellHost reads <framework>/banner.<ext>, the square
        // icon.png is the fallback): a game rebuilt since its last install gets its banner back too
        for game in library.games {
            let picked = game.titleID == titleID ? pickedArtwork : nil
            if let banner = ShellInstall.placeBanner(titleID: game.titleID, framework: game.framework, banners: banners, picked: picked) {
                log("banner: \(game.titleID) \(banner)\n")
            }
        }
        do { try library.save(root: root) } catch {
            return (nil, nil, Outcome(ok: false, message: fmt("shell.projectFailed", error.localizedDescription)), [])
        }

        // 4: the project
        guard let package = ShellInstall.shellPackage(resources: resources, repo: repo) else {
            let looked = ([resources, repo].compactMap { $0 }.filter { !$0.isEmpty }).map { $0 + "/frontend-ios" }.joined(separator: ", ")
            return (nil, nil, Outcome(ok: false, message: fmt("shell.projectFailed", "no frontend-ios Swift package (Package.swift) in " + looked)), [])
        }
        var env = ShellInstall.projectEnvironment(root: root, frameworks: library.games.map(\.framework), bundleID: library.bundleID,
                                                  team: team, python: python, path: toolPath, home: NSHomeDirectory(), user: NSUserName(),
                                                  tmp: NSTemporaryDirectory(), package: package)
        env.merge(BundledTools.environment(for: python)) { $1 }
        let projectName = t("shell.projectStage")
        begin(Self.projectStageID, projectName)
        let project = run(ShellInstall.projectCommand(repo: repo), env: env, label: projectName, step: { _ in nil })
        if project.status != 0 {
            let why = ShellInstall.scriptFailure(project.output) ?? fmt("msg.exitCode", project.status)
            end(Self.projectStageID, projectName, ok: false, detail: why)
            return (nil, nil, Outcome(ok: false, message: fmt("shell.projectFailed", why)), [])
        }
        end(Self.projectStageID, projectName, ok: true)
        return (library, env, nil, checked.notes)
    }

    /// The export: the library and the project, the unsigned build, the entitlements, the IPA. Needs no device and no team.
    package func export(framework: String, titleID: String, name: String) -> Outcome {
        let fm = FileManager.default
        guard fm.fileExists(atPath: framework) else { return Outcome(ok: false, message: fmt("shell.noFramework", framework)) }
        let prepared = prepareShell(framework: framework, titleID: titleID, name: name)
        guard let library = prepared.library else { return prepared.failure! }

        // The unsigned build, in the export's own derived data
        let buildName = t("shell.exportBuildStage")
        begin(Self.exportBuildStageID, buildName)
        let built = run(ShellInstall.exportBuildCommand(xcrun: xcrun, root: root, bundleID: library.bundleID), env: nil, label: buildName,
                        step: BuildProgress.xcodeStep)
        if built.status != 0 {
            let why = built.lastError ?? fmt("msg.exitCode", built.status)
            end(Self.exportBuildStageID, buildName, ok: false, detail: why)
            return Outcome(ok: false, message: fmt("shell.exportFailed", why))
        }
        let app = ShellInstall.exportAppPath(root: root)
        guard fm.fileExists(atPath: app) else {
            end(Self.exportBuildStageID, buildName, ok: false, detail: app)
            return Outcome(ok: false, message: fmt("dev.noProject", app))
        }
        // The Increased Memory Limit request rides in an ad-hoc signature of the executable. Without it the IPA still installs, and a
        // game that needs the memory may run out of it, so a failure here is logged and does not stop the export.
        let entitlements = ShellInstall.entitlementsPath(root: root)
        if fm.fileExists(atPath: entitlements) {
            _ = run(ShellInstall.cleanAttributesCommand(app: app), env: nil, label: buildName, step: { _ in nil })
            let signed = run(ShellInstall.entitlementsCommand(app: app, entitlements: entitlements), env: nil, label: buildName, step: { _ in nil })
            if signed.status != 0 { log("export: the entitlements could not be added to the app (a large game may run out of memory): \(signed.output)\n") }
        } else {
            log("export: no entitlements file at \(entitlements), the app asks for no Increased Memory Limit\n")
        }
        end(Self.exportBuildStageID, buildName, ok: true)

        // The IPA: Payload/<app>.app in a stage folder, zipped
        let packName = t("shell.exportPackStage")
        begin(Self.exportPackStageID, packName)
        let stage = ShellInstall.exportStage(root: root), ipa = ShellInstall.ipaPath(root: root)
        do {
            try? fm.removeItem(atPath: stage)
            try? fm.removeItem(atPath: ipa)
            try fm.createDirectory(atPath: stage + "/Payload", withIntermediateDirectories: true)
            try fm.copyItem(atPath: app, toPath: stage + "/Payload/" + ShellInstall.appName)
        } catch {
            try? fm.removeItem(atPath: stage)
            end(Self.exportPackStageID, packName, ok: false, detail: error.localizedDescription)
            return Outcome(ok: false, message: fmt("shell.exportFailed", error.localizedDescription))
        }
        let zipped = run(ShellInstall.zipCommand(root: root), env: nil, label: packName, step: { _ in nil })
        try? fm.removeItem(atPath: stage)
        guard zipped.status == 0, fm.fileExists(atPath: ipa) else {
            let why = zipped.lastError ?? fmt("msg.exitCode", zipped.status)
            end(Self.exportPackStageID, packName, ok: false, detail: why)
            return Outcome(ok: false, message: fmt("shell.exportFailed", why))
        }
        end(Self.exportPackStageID, packName, ok: true)
        var outcome = Outcome(ok: true, message: ([fmt("shell.exportDone", ipa)] + prepared.notes).joined(separator: "\n"), bundleID: library.bundleID)
        outcome.ipaPath = ipa
        return outcome
    }

    /// The game data into the shared app that is installed already and signed by another tool (LNPANDY/NX2Apple#416). The app is found
    /// on the device by its bundle ID prefix (a sideloading tool may add a team ID): none is `.appNotFound`, several come back in
    /// `apps` for the player to choose from (`bundleID` then names the one). The copy is the install's own data step (listing, diff,
    /// free space, the wired-or-Wi-Fi question, the copy). devicectl writes into an app container only for an app signed for development
    /// (get-task-allow), so its refusal comes back as `.refused` with its own words in `detail`.
    package func sendData(titleID: String, archive: String, bundleID: String? = nil) -> Outcome {
        if let refused = pairingRefusal() { return refused }
        var chosen = bundleID, name = ""
        if chosen == nil {
            let json = NSTemporaryDirectory() + "nspb-shell-apps-\(UUID().uuidString.prefix(8)).json"
            defer { try? FileManager.default.removeItem(atPath: json) }
            let listed = run([xcrun, "devicectl"] + InstalledApps.listArguments(device: device, json: json), env: nil, label: t("shell.sendStage"), step: { _ in nil })
            guard listed.status == 0, let apps = InstalledApps.parse(FileManager.default.contents(atPath: json) ?? Data()) else {
                return Outcome(ok: false, message: listed.lastError ?? fmt("msg.exitCode", listed.status))
            }
            let found = ShellInstall.shellApps(in: apps)
            guard let first = found.first else {
                var none = Outcome(ok: false, message: t("shell.sendNoApp"))
                none.dataFailure = .appNotFound
                return none
            }
            if found.count > 1 {
                var several = Outcome(ok: false, message: t("shell.sendSeveral"))
                several.apps = found
                return several
            }
            chosen = first.bundle; name = first.name
        }
        var outcome = copyGameData(titleID: titleID, archive: archive, app: "", bundleID: chosen!,
                                   outcome: Outcome(ok: true, message: "", bundleID: chosen!))
        outcome.appName = name
        if outcome.ok, !outcome.copySkipped, outcome.message.isEmpty || outcome.message == fmt("shell.dataAlready", deviceName) {
            outcome.message = t("shell.sendDone")
        }
        if !outcome.ok, outcome.failure == .shellDataIncomplete {
            outcome.dataFailure = ShellInstall.dataFailure(copyError: outcome.detail)
            outcome.message = outcome.dataFailure == .appNotFound ? t("shell.sendNoApp") : t("shell.sendRefused")
            outcome.failure = nil   // the install's Retry card does not fit: nothing of the install ran
        }
        return outcome
    }
}
