import Foundation
import PayloadKit

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

    /// The symlink inside `project/` that points to the current `frontend-ios` package, so `DmShell.xcodeproj` stays valid
    /// after a Gatekeeper AppTranslocation mount is unmounted or the launcher is moved to another folder.
    package static func linkedShellPackage(root: String) -> String { projectFolder(root: root) + "/frontend-ios" }

    /// Point `<root>/project/frontend-ios` (and any dangling engine symlinks in `<root>/project/`) at the running launcher's
    /// paths, and rewrite `DmShell.xcodeproj/project.pbxproj` to reference `frontend-ios` inside `<root>/project/`.
    package static func refreshProjectLinks(root: String, resources: String? = Bundle.main.resourceURL?.path, repo: String,
                                            fm: FileManager = .default) {
        let proj = projectFolder(root: root)
        guard fm.fileExists(atPath: proj) else { return }
        let link = linkedShellPackage(root: root)
        if let pkg = shellPackage(resources: resources, repo: repo, fm: fm), pkg != link {
            let attrs = try? fm.attributesOfItem(atPath: link)
            let isSymlink = (attrs?[.type] as? FileAttributeType) == .typeSymbolicLink
            if isSymlink || attrs == nil, (try? fm.destinationOfSymbolicLink(atPath: link)) != pkg {
                if isSymlink { try? fm.removeItem(atPath: link) }
                try? fm.createSymbolicLink(atPath: link, withDestinationPath: pkg)
            }
        }
        let engine = EngineLayout.root(repo)
        for item in ["Sources", "Shell", "tools"] {
            let itemLink = proj + "/" + item, target = engine + "/dm/ios/" + item
            guard !fm.fileExists(atPath: itemLink), fm.fileExists(atPath: target) else { continue }
            let attrs = try? fm.attributesOfItem(atPath: itemLink)
            let isSymlink = (attrs?[.type] as? FileAttributeType) == .typeSymbolicLink
            if isSymlink || attrs == nil {
                if isSymlink { try? fm.removeItem(atPath: itemLink) }
                try? fm.createSymbolicLink(atPath: itemLink, withDestinationPath: target)
            }
        }
        let pbxPath = proj + "/" + projectName + "/project.pbxproj"
        guard fm.fileExists(atPath: link + "/Package.swift"),
              let pbx = try? String(contentsOfFile: pbxPath, encoding: .utf8),
              let re = try? NSRegularExpression(pattern: #"(path|relativePath) = "?(?:[^";\n]*/)?frontend-ios"?;"#) else { return }
        let updated = re.stringByReplacingMatches(in: pbx, range: NSRange(pbx.startIndex..., in: pbx),
                                                  withTemplate: #"$1 = "frontend-ios";"#)
        if updated != pbx {
            try? updated.write(toFile: pbxPath, atomically: true, encoding: .utf8)
        }
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
        // shell.json and the mirrors it points to as they were, put back when the project step refuses: a framework build_shell.sh
        // rejects (an older build, a game of another profile) must not stay in the library, nor in place of the mirror of a game that
        // worked, or every later install of any game fails on it
        let fm = FileManager.default
        let stateFile = ShellLibrary.stateFile(root: root)
        let before = fm.contents(atPath: stateFile)
        var replaced: [(mirror: String, previous: String)] = []
        func restoreLibrary() {
            do {
                if let before { try before.write(to: URL(fileURLWithPath: stateFile), options: .atomic) }
                else if fm.fileExists(atPath: stateFile) { try fm.removeItem(atPath: stateFile) }
            } catch {
                log("library: shell.json could not be put back as it was at \(stateFile): \(error.localizedDescription)\n")
            }
            for (mirror, previous) in replaced {
                guard ShellInstall.discard(mirror) else {
                    log("library: the refused framework at \(mirror) could not be moved away, the previous one stays at \(previous)\n")
                    continue
                }
                do { try fm.moveItem(atPath: previous, toPath: mirror) } catch {
                    log("library: the previous framework could not be put back at \(mirror) from \(previous): \(error.localizedDescription)\n")
                }
            }
        }
        var library = ShellLibrary.load(root: root)
        if !team.isEmpty { library.team = team }   // the export has no team: keep the one an install stored
        library.add(.init(titleID: titleID, name: name, framework: framework))
        replaced = mirrorFrameworks(&library)
        library.dropMissing()
        let checked = leaveOutIncomplete(&library, titleID: titleID, name: name)   // ShellFrameworks.swift
        if let why = checked.failure {
            let projectName = t("shell.projectStage")
            begin(Self.projectStageID, projectName)
            end(Self.projectStageID, projectName, ok: false, detail: why)
            restoreLibrary()
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
            restoreLibrary()
            return (nil, nil, Outcome(ok: false, message: fmt("shell.projectFailed", error.localizedDescription)), [])
        }

        // 4: the project
        guard let package = ShellInstall.shellPackage(resources: resources, repo: repo) else {
            let looked = ([resources, repo].compactMap { $0 }.filter { !$0.isEmpty }).map { $0 + "/frontend-ios" }.joined(separator: ", ")
            restoreLibrary()
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
            restoreLibrary()
            return (nil, nil, Outcome(ok: false, message: fmt("shell.projectFailed", why)), [])
        }
        for (_, previous) in replaced { ShellInstall.discard(previous) }   // the script took the new frameworks
        ShellInstall.refreshProjectLinks(root: root, resources: resources, repo: repo)
        ShellInstall.writeProjectFrameworks(root: root, games: library.games)
        ShellInstall.pruneEmbeddedFrameworks(root: root, keeping: library.games)
        end(Self.projectStageID, projectName, ok: true)
        return (library, env, nil, checked.notes)
    }

    /// The export: the library and the project, the unsigned build, the entitlements, the IPA. Needs no device and no team.
    package func export(framework: String, titleID: String, name: String) -> Outcome {
        let fm = FileManager.default
        guard fm.fileExists(atPath: framework) else { return missingFramework(framework, name: name) }
        let prepared = prepareShell(framework: framework, titleID: titleID, name: name)
        guard let library = prepared.library else { return prepared.failure! }

        // The unsigned build, in the export's own derived data
        let buildName = t("shell.exportBuildStage")
        begin(Self.exportBuildStageID, buildName)
        let built = run(ShellInstall.exportBuildCommand(xcrun: xcrun, root: root, bundleID: library.bundleID), env: nil, label: buildName,
                        stageID: Self.exportBuildStageID, step: BuildProgress.xcodeStep)
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
        end(Self.exportBuildStageID, buildName, ok: true)
        return packExport(app: URL(fileURLWithPath: app), library: library, notes: prepared.notes)
    }

    /// Stage and zip Payload/<app>.app. Signing can add _CodeSignature/ and CodeResources, so reserve two ZIP32 entries.
    func packExport(app: URL, library: ShellLibrary, notes: [String] = [], entryLimit: Int = ShellExport.entryLimit,
                    hardLimit: Int = ShellExport.entryLimit) -> Outcome {
        let fm = FileManager.default
        let packName = t("shell.exportPackStage")
        begin(Self.exportPackStageID, packName)
        let stage = ShellInstall.exportStage(root: root), ipa = ShellInstall.ipaPath(root: root)
        let stagedApp = URL(fileURLWithPath: stage + "/Payload/" + ShellInstall.appName)
        do {
            try? fm.removeItem(atPath: stage)
            try? fm.removeItem(atPath: ipa)
            try fm.createDirectory(atPath: stage + "/Payload", withIntermediateDirectories: true)
            try fm.copyItem(at: app, to: stagedApp)
            let payload = stagedApp.deletingLastPathComponent()
            if try ShellExport.exceedsEntryLimit(in: payload, limit: entryLimit) {
                try packShaderLibraries(in: stagedApp, games: library.games, label: packName)
                if try ShellExport.exceedsEntryLimit(in: payload, limit: hardLimit) {
                    throw ShellExport.entryLimitExceededError(limit: hardLimit)
                }
            }
        } catch {
            try? fm.removeItem(atPath: stage)
            end(Self.exportPackStageID, packName, ok: false, detail: error.localizedDescription)
            return Outcome(ok: false, message: fmt("shell.exportFailed", error.localizedDescription))
        }
        // Signing the executable also seals its bundle resources. Sign the staged app after packing the shaders.
        // Failure only costs the Increased Memory Limit request, so it does not stop the export.
        let entitlements = ShellInstall.entitlementsPath(root: root)
        if fm.fileExists(atPath: entitlements) {
            _ = run(ShellInstall.cleanAttributesCommand(app: stagedApp.path), env: nil, label: packName, step: { _ in nil })
            let signed = run(ShellInstall.entitlementsCommand(app: stagedApp.path, entitlements: entitlements), env: nil, label: packName, step: { _ in nil })
            if signed.status != 0 { log("export: the entitlements could not be added to the app (a large game may run out of memory): \(signed.output)\n") }
        } else {
            log("export: no entitlements file at \(entitlements), the app asks for no Increased Memory Limit\n")
        }
        let zipped = run(ShellInstall.zipCommand(root: root), env: nil, label: packName, step: { _ in nil })
        try? fm.removeItem(atPath: stage)
        guard zipped.status == 0, fm.fileExists(atPath: ipa) else {
            try? fm.removeItem(atPath: ipa)
            let why = zipped.lastError ?? fmt("msg.exitCode", zipped.status)
            end(Self.exportPackStageID, packName, ok: false, detail: why)
            return Outcome(ok: false, message: fmt("shell.exportFailed", why))
        }
        end(Self.exportPackStageID, packName, ok: true)
        var outcome = Outcome(ok: true, message: ([fmt("shell.exportDone", ipa)] + notes).joined(separator: "\n"), bundleID: library.bundleID)
        outcome.ipaPath = ipa
        return outcome
    }

    /// Keep a large IPA within the sideloader's 16-bit entry count. Only the games in the shell library
    /// know how to unpack an archive. Leave other frameworks' resources in their original layout.
    private func packShaderLibraries(in stagedApp: URL, games: [ShellLibrary.Game], label: String) throws {
        let names = games.map { URL(fileURLWithPath: $0.framework).lastPathComponent }
        try ShellExport.packShaderLibraries(
            in: stagedApp,
            frameworkNames: names,
            runArchive: { command in
                let result = run(command, env: nil, label: label, step: { _ in nil })
                return (result.status, result.output, result.lastError)
            },
            exitCodeMessage: { fmt("msg.exitCode", $0) }
        )
    }

    /// Resolve the device's selection rather than a Mac cache which may describe
    /// a different phone or an update still waiting for restart.
    private func payloadDataFolder(titleID: String, archive: String, bundle: String) throws -> String? {
        try checkPayloadCancellation()
        let fm = FileManager.default
        let stage = fm.temporaryDirectory.appendingPathComponent("nx-payload-data-" + UUID().uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }
        func read(_ name: String) -> URL? {
            let file = stage.appendingPathComponent((name as NSString).lastPathComponent)
            let command = Self.payloadCopy(xcrun: xcrun, device: device, bundle: bundle, toDevice: false,
                source: "Documents/" + name, destination: file.path)
            let result = runner.capture(ProcessLaunch(executable: command[0], arguments: Array(command.dropFirst()), mergesErrors: true, timeout: 30))
            return result.ok && fm.fileExists(atPath: file.path) ? file : nil
        }
        guard let capabilitiesFile = read(PayloadCapabilities.fileName) else {
            if fm.fileExists(atPath: payloadHostFile(bundle: bundle).path) { throw PayloadError.incompatible(t("payload.unavailable")) }
            return nil
        }
        let host = try JSONDecoder().decode(PayloadCapabilities.self, from: Data(contentsOf: capabilitiesFile))
        guard host.version == PayloadCapabilities.protocolVersion, host.bundleID == bundle else {
            throw PayloadError.incompatible("shell protocol or bundle")
        }
        let remembered = payloadHostFile(bundle: bundle)
        try fm.createDirectory(at: remembered.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PayloadArchive.encode(host).write(to: remembered, options: .atomic)
        let inboxFile = stage.appendingPathComponent("inbox.json")
        let inbox = runner.capture(ProcessLaunch(executable: xcrun,
            arguments: ["devicectl", "device", "info", "files", "--device", device, "--domain-type", "appDataContainer",
                        "--domain-identifier", bundle, "--subdirectory", "Documents/" + PayloadStore.inboxName,
                        "--json-output", inboxFile.path], mergesErrors: true, timeout: 30))
        guard inbox.ok, let data = try? Data(contentsOf: inboxFile),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = (json["result"] as? [String: Any])?["files"] as? [[String: Any]] else {
            throw PayloadError.incompatible(t("payload.unavailable"))
        }
        guard !files.contains(where: {
            let path = ($0["relativePath"] as? String) ?? ($0["name"] as? String) ?? ""
            return path == PayloadArchive.readyName || path.hasSuffix("/" + PayloadArchive.readyName)
        }) else { throw PayloadError.incompatible(t("payload.dataSelectionUnavailable")) }
        guard let registryFile = read(PayloadStore.registryName) else { throw PayloadError.incompatible(t("payload.unavailable")) }
        guard let selected = try PayloadStore.selectedManifest(in: Data(contentsOf: registryFile), titleID: titleID) else { return nil }
        func identity(_ line: String) -> (size: UInt64, index: UInt64)? {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.first == "DMROMFSID1" else { return nil }
            func value(_ name: String) -> Substring? {
                fields.dropFirst().first { $0.hasPrefix(name + "=") }?.dropFirst(name.count + 1)
            }
            guard let bytes = value("size"), let size = UInt64(bytes), size > 0,
                  let hash = value("index"), let index = UInt64(hash, radix: 16) else { return nil }
            return (size, index)
        }
        let gamePath = PayloadStore.bundlesName + "/" + titleID + "/" + selected.generation + "/" + selected.framework + "/game.manifest.json"
        guard let gameFile = read(gamePath),
              let game = try JSONSerialization.jsonObject(with: Data(contentsOf: gameFile)) as? [String: Any],
              game["title_id"] as? String == titleID,
              let expectedLine = game["romfs_identity"] as? String, let expected = identity(expectedLine),
              let actualLine = imageIdentity(archive: archive, titleID: titleID), let actual = identity(actualLine),
              actual == expected else {
            throw PayloadError.incompatible(t("payload.dataSelectionUnavailable"))
        }
        // Header/index identity alone does not distinguish changed file bytes
        // across game versions. Bind the source to its package version and hash.
        struct SourceImageID: Decodable {
            let title: String
            let version: String
            let bytes: UInt64
            let sha256: String
        }
        let source = URL(fileURLWithPath: archive).appendingPathComponent("romfs.img")
        guard let metadata = try? Data(contentsOf: URL(fileURLWithPath: archive).appendingPathComponent("romfs.img.id")),
              let sourceID = try? JSONDecoder().decode(SourceImageID.self, from: metadata),
              sourceID.title.uppercased() == titleID,
              sourceID.version == game["package_version"] as? String,
              try PayloadArchive.size(source) == sourceID.bytes,
              try PayloadArchive.digest(source, checkCancellation: checkPayloadCancellation) == sourceID.sha256 else {
            throw PayloadError.incompatible(t("payload.dataSelectionUnavailable"))
        }
        try checkPayloadCancellation()
        return "Documents/" + PayloadStore.gameDataPath(titleID: titleID, generation: selected.generation)
    }

    /// The game data into the shared app that is installed already and signed by another tool (LNPANDY/NX2Apple#416). The app is found
    /// on the device by its bundle ID prefix (a sideloading tool may add a team ID): none is `.appNotFound`, several come back in
    /// `apps` for the player to choose from (`bundleID` then names the one). The copy is the install's own data step (listing, diff,
    /// free space, the wired-or-Wi-Fi question, the copy). A copy that fails comes back as `.refused` with devicectl's words in `detail`.
    /// We believe devicectl writes into an app container only for an app signed for development (get-task-allow). That is not verified on
    /// a device, so the launcher says only that the device refused, and offers the Finder way (#491).
    package func sendData(titleID: String, archive: String, bundleID: String? = nil) -> Outcome {
        if let refused = pairingRefusal() { return refused }
        var chosen = bundleID, name = ""
        if chosen == nil {
            let json = NSTemporaryDirectory() + "nspb-shell-apps-\(UUID().uuidString.prefix(8)).json"
            defer { try? FileManager.default.removeItem(atPath: json) }
            let listed = run([xcrun, "devicectl"] + InstalledApps.listArguments(device: device, json: json), env: nil, label: t("shell.sendStage"), step: { _ in nil })
            guard listed.status == 0, let apps = InstalledApps.parse(FileManager.default.contents(atPath: json) ?? Data()) else {
                var unread = Outcome(ok: false, message: fmt("shell.sendListFailed", deviceName))
                unread.detail = listed.lastError ?? fmt("msg.exitCode", listed.status)
                unread.dataFailure = .noAppList
                return unread
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
        let dataFolder: String?
        do { dataFolder = try payloadDataFolder(titleID: titleID, archive: archive, bundle: chosen!) }
        catch {
            return Outcome(ok: false, message: fmt("payload.failed", String(describing: error)), bundleID: chosen!)
        }
        var outcome = copyGameData(titleID: titleID, archive: archive, app: "", bundleID: chosen!,
                                   outcome: Outcome(ok: true, message: "", bundleID: chosen!), dataFolder: dataFolder)
        outcome.appName = name
        if outcome.ok, !outcome.copySkipped {
            outcome.message = t("shell.sendDone")
        }
        if !outcome.ok, outcome.failure == .shellDataIncomplete {
            // The device listed the app, so a copy that fails is a refusal, whatever devicectl's words are (#491). Its words stay in `detail`.
            outcome.dataFailure = .refused
            outcome.message = t("shell.sendRefused")
            outcome.failure = nil   // the install's Retry card does not fit: nothing of the install ran
        }
        return outcome
    }
}

/// Shared IPA staging helpers used by both unsigned exports (`ShellInstaller.packExport`) and signed app exports (`BuildStore.saveIPA`).
package enum ShellExport {
    /// Signing can add `_CodeSignature/` and `CodeResources`, so reserve two entries below the 16-bit ZIP32 ceiling.
    package static let entryLimit = Int(UInt16.max) - 2

    package static func exceedsEntryLimit(in payload: URL, limit: Int = entryLimit) throws -> Bool {
        var failure: Error?
        guard let entries = FileManager.default.enumerator(at: payload, includingPropertiesForKeys: [], errorHandler: { _, error in
            failure = error
            return false
        }) else {
            throw failure ?? CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: payload.path])
        }
        var count = 1   // ditto --keepParent writes Payload/ itself, then DmShell.app/ and its descendants.
        while count <= limit, entries.nextObject() != nil { count += 1 }
        if let failure { throw failure }
        return count > limit
    }

    package static func entryLimitExceededError(limit: Int) -> Error {
        CocoaError(.fileWriteUnknown, userInfo: [
            NSLocalizedDescriptionKey: "IPA bundle exceeds the \(limit)-entry ZIP32 archive limit"
        ])
    }

    /// Names the embedded `DmGame<titleID>.framework` bundles whose `msl/` trees `ShellHost` knows how to unpack from `.aar`.
    package static func gameFrameworkNames(forApp appPath: String, stagedApp: URL, fm: FileManager = .default) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        func append(_ name: String) {
            if !name.isEmpty, seen.insert(name).inserted {
                names.append(name)
            }
        }
        if let shell = ShellInstall.paths(ofApp: appPath) {
            for game in ShellLibrary.load(root: shell.root).games {
                append(URL(fileURLWithPath: game.framework).lastPathComponent)
            }
        }
        let frameworksDir = stagedApp.appendingPathComponent("Frameworks")
        for item in (try? fm.contentsOfDirectory(atPath: frameworksDir.path))?.sorted() ?? []
            where !ShellInstall.titleID(ofFramework: item).isEmpty {
            append(item)
        }
        return names
    }

    /// Packs loose `msl/` directories inside the named game frameworks into `msl-<UUID>.aar` archives so the IPA stays within ZIP32 limits.
    package static func packShaderLibraries(
        in stagedApp: URL,
        frameworkNames: [String],
        runArchive: ([String]) -> (status: Int32, output: String, lastError: String?),
        exitCodeMessage: (Int32) -> String
    ) throws {
        let fm = FileManager.default
        let frameworks = stagedApp.appendingPathComponent("Frameworks")
        var packed = Set<String>()
        for name in frameworkNames where packed.insert(name).inserted {
            let framework = frameworks.appendingPathComponent(name)
            let shaders = framework.appendingPathComponent("msl")
            var directory: ObjCBool = false
            guard fm.fileExists(atPath: shaders.path, isDirectory: &directory), directory.boolValue else { continue }
            for old in try fm.contentsOfDirectory(at: framework, includingPropertiesForKeys: nil) where old.pathExtension == "aar" {
                let stem = old.deletingPathExtension().lastPathComponent
                if stem.hasPrefix("msl-"), UUID(uuidString: String(stem.dropFirst(4))) != nil {
                    try fm.removeItem(at: old)
                }
            }
            let archive = framework.appendingPathComponent("msl-\(UUID().uuidString).aar")
            let result = runArchive(["/usr/bin/aa", "archive", "-d", shaders.path, "-o", archive.path, "-a", "lzfse"])
            guard result.status == 0, fm.fileExists(atPath: archive.path) else {
                let reason = result.lastError ?? ShellInstall.scriptFailure(result.output) ?? exitCodeMessage(result.status)
                throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: reason])
            }
            try fm.removeItem(at: shaders)
        }
    }
}
