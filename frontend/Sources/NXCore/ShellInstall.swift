import Foundation

// Route C: one app on the iPhone or iPad that holds several games. The build script makes only each game's framework
// (`--shell-framework`), and this file does the rest: the shell's library file (shell.json), the shell's Xcode project
// (dm/ios/tools/build_shell.sh), signing, the install, and the game data. Everything pure (the file, the commands, the listing
// parser, the diff) is a static function with its own tests. `ShellInstaller` strings them together, blocking, so the same code
// runs under the build model (on a background queue) and from the terminal (`NSPortBuilder --install-shell`).


/// The commands and parsers of the shell install, as pure functions.
package enum ShellInstall {
    package static let appName = "DmShell.app"
    package static let scheme = "DmShell"
    package static let projectName = "DmShell.xcodeproj"

    package static func projectFolder(root: String) -> String { root + "/project" }

    /// Whether the shell root can be written, checked before an hour of building: a folder on a read-only volume (or a
    /// file where the folder goes) only failed at the last step otherwise (#492).
    package static func canWriteRoot(_ root: String, fm: FileManager = .default) -> Bool {
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: root, isDirectory: &isDir) { return isDir.boolValue && fm.isWritableFile(atPath: root) }
        let parent = (root as NSString).deletingLastPathComponent
        guard fm.fileExists(atPath: parent, isDirectory: &isDir), isDir.boolValue else { return false }
        return fm.isWritableFile(atPath: parent)
    }

    package static func derivedData(root: String) -> String { root + "/derived-data" }
    package static func appPath(root: String) -> String { derivedData(root: root) + "/Build/Products/Release-iphoneos/" + appName }

    /// The folder that mirrors every game's framework inside the shell folder: a game survives its build folder's deletion here.
    package static func frameworksMirror(root: String) -> String { root + "/frameworks" }
    package static func mirroredFramework(root: String, titleID: String) -> String {
        frameworksMirror(root: root) + "/DmGame\(titleID).framework"
    }

    /// Mirrors a framework into the shell folder as a copy. On APFS the copy is a clone: it costs no space, and a later write to
    /// the build folder does not reach it. On another volume it is a real copy. It replaces the previous mirror, so a rebuilt
    /// game's mirror follows. The copy goes to a hidden folder first and is renamed into place when it is whole, so a failed or
    /// interrupted copy never leaves a half mirror where shell.json points (ShellFrameworks.swift).
    /// With `keepPrevious`, the previous mirror is renamed aside instead of deleted, and its hidden path is returned (nil when there
    /// was none): the caller puts it back when the new framework is refused, or discards it. A launcher quit in between leaves it to
    /// `sweepDiscarded`, like any discarded folder.
    @discardableResult
    package static func mirrorFramework(framework: String, root: String, titleID: String? = nil, keepPrevious: Bool = false) throws -> String? {
        let fm = FileManager.default
        let mirror = mirroredFramework(root: root, titleID: titleID ?? Self.titleID(ofFramework: framework))
        let folder = (mirror as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let copy = folder + "/" + discardPrefix + UUID().uuidString
        var previous: String? = nil
        do {
            try fm.copyItem(atPath: framework, toPath: copy)
            if keepPrevious, fm.fileExists(atPath: mirror) {
                let aside = folder + "/" + discardPrefix + UUID().uuidString
                try fm.moveItem(atPath: mirror, toPath: aside)
                previous = aside
            } else {
                guard discard(mirror) else { throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: mirror]) }
            }
            try fm.moveItem(atPath: copy, toPath: mirror)
        } catch {
            try? fm.removeItem(atPath: copy)
            if let previous { try? fm.moveItem(atPath: previous, toPath: mirror) }
            throw error
        }
        return previous
    }

    /// The title ID a framework path carries (`DmGame0100…framework`, the build script's name).
    package static func titleID(ofFramework framework: String) -> String {
        let name = (framework as NSString).lastPathComponent
        return name.hasPrefix("DmGame") && name.hasSuffix(".framework")
            ? String(name.dropFirst("DmGame".count).dropLast(".framework".count)) : ""
    }

    /// The framework the build script's `--shell-framework <folder>` writes for a game.
    package static func frameworkPath(workDir: String, titleID: String) -> String {
        workDir + "/shell-framework/DmGame\(titleID).framework"
    }

    /// The framework the build wrote in `<work>/shell-framework`. The script names it after the title ID it read from the game
    /// data, which a file name without a title ID does not carry (the build key is then the name plus a hash, #515), so the
    /// handoff takes the folder's own `DmGame*.framework`: the newest when an older build left a second one. nil when there is none.
    package static func builtFramework(workDir: String, fm: FileManager = .default) -> String? {
        let folder = workDir + "/shell-framework"
        let names = ((try? fm.contentsOfDirectory(atPath: folder)) ?? [])
            .filter { $0.hasPrefix("DmGame") && $0.hasSuffix(".framework") && $0.count > "DmGame.framework".count }
        func modified(_ name: String) -> Date {
            ((try? fm.attributesOfItem(atPath: folder + "/" + name))?[.modificationDate] as? Date) ?? .distantPast
        }
        return names.max { (modified($0), $0) < (modified($1), $1) }.map { folder + "/" + $0 }
    }

    /// The part of the build script's argument list that makes the game's framework instead of an Xcode project.
    package static func buildArguments(workDir: String, team: String) -> [String] {
        ["--shell-framework", workDir + "/shell-framework"] + (team.isEmpty ? [] : ["--team-id", team])
    }

    // ---- 4: the project ----

    package static func projectCommand(repo: String) -> [String] {
        ["/bin/bash", repo + "/dm/ios/tools/build_shell.sh", "--prepare-xcode"]
    }

    /// The `frontend-ios` Swift package the shell project links (build_shell.sh's DM_SHELL_PACKAGE). The script defaults to
    /// `frontend-ios` beside `dm/`, which is the engine root, and an engine tree has none since #214. So: the release app's
    /// Contents/Resources/frontend-ios, else the source checkout's `frontend-ios` (`repo`). nil when neither has a Package.swift.
    package static func shellPackage(resources: String?, repo: String, fm: FileManager = .default) -> String? {
        ([resources, repo].compactMap { $0 }.filter { !$0.isEmpty }).map { $0 + "/frontend-ios" }
            .first { fm.fileExists(atPath: $0 + "/Package.swift") }
    }

    /// What build_shell.sh reads. `path` is the build's own tool PATH (xcodegen must be found on it).
    package static func projectEnvironment(root: String, frameworks: [String], bundleID: String, team: String, python: String,
                                   path: String, home: String, user: String, tmp: String? = nil, package: String? = nil) -> [String: String] {
        var env = ["SHELL_DIR": projectFolder(root: root),
                   "DM_SHELL_FRAMEWORKS": frameworks.joined(separator: "\n"),
                   "DM_BUNDLE_ID": bundleID,
                   "DM_TEAM_ID": team,
                   "DM_XCODE_DERIVED_DATA": derivedData(root: root),
                   "FONT_PY": python,
                   "PATH": path, "HOME": home, "USER": user, "LANG": "en_US.UTF-8"]
        if let tmp { env["TMPDIR"] = tmp }
        if let package { env["DM_SHELL_PACKAGE"] = package }
        return env
    }

    // ---- 5 and 6: sign, build, install ----

    /// `bundleID` goes in as PRODUCT_BUNDLE_IDENTIFIER every time: the identifier stored in shell.json is the one the device's
    /// copy of the app has, and installing under another would start an app with empty Documents.
    package static func buildCommand(xcrun: String, root: String, device: String, team: String, bundleID: String) -> [String] {
        [xcrun, "xcodebuild", "-project", projectFolder(root: root) + "/" + projectName, "-scheme", scheme,
         "-configuration", "Release", "-destination", "id=\(device)", "-derivedDataPath", derivedData(root: root),
         "-allowProvisioningUpdates", "DEVELOPMENT_TEAM=\(team)", "PRODUCT_BUNDLE_IDENTIFIER=\(bundleID)", "build"]
    }

    /// Installing over the existing app keeps its Documents.
    package static func installCommand(xcrun: String, device: String, app: String) -> [String] {
        [xcrun, "devicectl", "device", "install", "app", "--device", device, app]
    }

    // ---- 7: the game data ----

    package static func gameFolder(titleID: String) -> String { "Documents/games/\(titleID)" }

    /// Kept free beyond the data on the device (the game's saves, shader caches, the system).
    package static let freeSpaceMargin: Int64 = 2_000_000_000

    /// The shell's own log from the device (Documents/shell-log.txt, written at every start).
    package static func shellLogCommand(xcrun: String, device: String, bundleID: String, destination: String) -> [String] {
        [xcrun, "devicectl", "device", "copy", "from", "--device", device, "--domain-type", "appDataContainer",
         "--domain-identifier", bundleID, "--source", "Documents/shell-log.txt", "--destination", destination]
    }

    /// The last "shell: free space <bytes> bytes" line of the shell's log, nil without one.
    package static func freeSpace(inShellLog text: String?) -> Int64? {
        guard let text else { return nil }
        return text.split(separator: "\n").reversed().lazy.compactMap { line -> Int64? in
            guard line.hasPrefix("shell: free space ") else { return nil }
            return Int64(line.dropFirst("shell: free space ".count).split(separator: " ").first ?? "")
        }.first.flatMap { $0 >= 0 ? $0 : nil }
    }

    /// Whether a failed sign under `attempted` is retried under the selected team's `variant`: the identifier is registered to another
    /// team, or Xcode has no profile for it. This is wider than `BuildFailureClassifier.signingTeamTaken`, which picks the failure
    /// card: an identifier stored under another team's variant (`org.nxnative.shell.<team A>`, with team B selected now) gets only
    /// "No profiles for" that identifier, and must still be retried under team B's. The variant itself is never retried.
    package static func retryUnderTeamVariant(_ output: String, attempted: String, variant: String) -> Bool {
        attempted != variant
            && (output.contains("cannot be registered to your development team") || output.contains("No profiles for '\(attempted)'"))
    }

    /// xcodebuild's words when the provisioning profile lacks the Increased Memory Limit the shell asks for.
    package static func memoryCapabilityMissing(_ output: String) -> Bool {
        output.contains("doesn't include the Increased Memory Limit capability") || output.contains("doesn't include the com.apple.developer.kernel.increased-memory-limit entitlement")
    }

    /// Copies the game's banner into its framework as banner.<ext>, the picture the shell's library shows: the player's own pick,
    /// else the eShop banner the launcher caches per title ID (ArtworkStore). The cache is only read. Without either, an older
    /// banner is removed and the library shows the framework's icon.png. Returns the picture used.
    @discardableResult static func placeBanner(titleID: String, framework: String, banners: URL, picked: String?,
                                               fm: FileManager = .default) -> String? {
        let source = [picked, BannerCache.cached(titleID, in: banners)?.path].compactMap { $0 }.first { !$0.isEmpty && fm.fileExists(atPath: $0) }
        for ext in ["png", "jpg", "jpeg", "heic", "webp"] { try? fm.removeItem(atPath: framework + "/banner." + ext) }
        guard let source else { return nil }
        let ext = (source as NSString).pathExtension.lowercased()
        let dest = framework + "/banner." + (["png", "jpg", "jpeg", "heic", "webp"].contains(ext) ? ext : "jpg")
        return (try? fm.copyItem(atPath: source, toPath: dest)) != nil ? source : nil
    }

    /// devicectl's recursive listing of the game's folder in the app's container, written as JSON to `json`.
    package static func listCommand(xcrun: String, device: String, bundleID: String, titleID: String, json: String) -> [String] {
        [xcrun, "devicectl", "device", "info", "files", "--device", device, "--domain-type", "appDataContainer",
         "--domain-identifier", bundleID, "--subdirectory", gameFolder(titleID: titleID), "--json-output", json]
    }

    /// One file into the game's folder. A file destination creates the parent folders and names the file. Never
    /// `--remove-existing-content true`: on a real device it deletes the destination's siblings too (#266).
    package static func copyCommand(xcrun: String, device: String, bundleID: String, titleID: String, source: String, relativePath: String) -> [String] {
        [xcrun, "devicectl", "device", "copy", "to", "--device", device, "--source", source,
         "--destination", gameFolder(titleID: titleID) + "/" + relativePath,
         "--domain-type", "appDataContainer", "--domain-identifier", bundleID]
    }

    /// The device's files (path relative to the game's folder → size) from the listing JSON. The error JSON of a folder that does
    /// not exist (or an app that is new) and anything unreadable mean "nothing on the device": an empty list.
    package static func parseListing(_ data: Data?) -> [String: Int64] {
        guard let data, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = (root["result"] as? [String: Any])?["files"] as? [[String: Any]] else { return [:] }
        var found: [String: Int64] = [:]
        for file in files {
            if (file["resources"] as? [String: Any])?["isDirectory"] as? Bool == true { continue }
            guard let path = (file["relativePath"] as? String) ?? (file["name"] as? String),
                  let size = (file["metadata"] as? [String: Any])?["size"] as? NSNumber else { continue }
            found[path] = size.int64Value
        }
        return found
    }

    /// The archive folder's files (relative path → size), without dot files (.packstamp) and without folders.
    package static func localFiles(in archive: String) -> [String: Int64] {
        let fm = FileManager.default
        var found: [String: Int64] = [:]
        guard let enumerator = fm.enumerator(atPath: archive) else { return found }   // a folder that is not there holds nothing
        for case let path as String in enumerator {
            if path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { continue }
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: archive + "/" + path, isDirectory: &isDirectory), !isDirectory.boolValue,
                  let size = (try? fm.attributesOfItem(atPath: archive + "/" + path))?[.size] as? NSNumber else { continue }
            found[path] = size.int64Value
        }
        return found
    }

    /// The local files to copy: missing on the device, or of another size. Sorted, so the copies run in a stable order.
    /// The caller also checks the last RomFS transfer before treating a same-size device image as a match.
    package static func filesToCopy(local: [String: Int64], device: [String: Int64]) -> [String] {
        local.filter { device[$0.key] != $0.value }.map(\.key).sorted()
    }

    /// The reason the build_shell.sh run failed, for the player: its last `[RED]` line (the refusals, for example two different
    /// games in one shell), else its last `FAIL:` line, else the last line it printed.
    package static func scriptFailure(_ output: String) -> String? {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let red = lines.last(where: { $0.contains("[RED]") }), let r = red.range(of: "[RED]") {
            return String(red[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        if let fail = lines.last(where: { $0.contains("FAIL:") }), let r = fail.range(of: "FAIL:") {
            return String(fail[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return lines.last
    }

    // ---- the connection of the copy ----

    /// How the device is connected to this Mac (`ShellConnection`, NXCore).
    package typealias Connection = ShellConnection

    package static func connection(of udid: String, in devices: [AppleDevice]) -> Connection {
        guard let device = devices.first(where: { $0.id == udid }) else { return .notPaired }
        if device.wired { return .wired }
        if device.overNetwork { return .network }
        return device.reachable ? .other : .notConnected
    }

    /// Minutes a copy of `bytes` takes over Wi-Fi, as a range: devicectl over the local network does about 17 to 25 MB/s, so
    /// 15 GB is 10 to 15 minutes. At least one minute.
    package static func wifiEstimate(bytes: Int64) -> (low: Int, high: Int) {
        let low = max(1, Int((Double(bytes) / 25e6 / 60).rounded()))
        return (low, max(low, Int((Double(bytes) / 17e6 / 60).rounded())))
    }

    package static func sizeText(_ bytes: Int64) -> String {
        // Decimal units as devicectl and the Finder count, and the same text in every locale
        if bytes >= 1_000_000_000 { return String(format: "%.1f GB", Double(bytes) / 1e9) }
        if bytes >= 1_000_000 { return String(format: "%.0f MB", Double(bytes) / 1e6) }
        return String(format: "%.0f KB", (Double(bytes) / 1e3).rounded(.up))
    }

    /// An installed app's shell paths, from its own path (<root>/derived-data/Build/Products/Release-iphoneos/DmShell.app), nil for
    /// any other app. A re-sign runs on that project and derived data.
    package static func paths(ofApp app: String) -> (root: String, project: String, derived: String)? {
        guard (app as NSString).lastPathComponent == appName, let marker = app.range(of: "/Build/Products/") else { return nil }
        let derived = String(app[..<marker.lowerBound])
        guard (derived as NSString).lastPathComponent == "derived-data" else { return nil }
        let root = (derived as NSString).deletingLastPathComponent
        return (root, projectFolder(root: root) + "/" + projectName, derived)
    }
}

/// One stage of the install, as the model and the terminal show it.
package struct ShellStage {
    package var id: Int
    package var name: String
    package var state: StepState
    package var detail = ""
    package var percent: Double? = nil

    package init(id: Int, name: String, state: StepState, detail: String = "", percent: Double? = nil) {
        self.id = id; self.name = name; self.state = state; self.detail = detail; self.percent = percent
    }
}

/// Steps 3 to 7: the shell's library, its project, signing, the install and the game data, blocking. A tool that fails ends the
/// install with a diagnostic from the tool.
package struct ShellInstaller {
    package var xcrun = "/usr/bin/xcrun"
    package var repo: String
    /// The app's Contents/Resources, where a release app carries frontend-ios. Nil for a launcher run from a checkout.
    package var resources: String? = Bundle.main.resourceURL?.path
    package var python: String
    package var root: String
    package var device: String
    package var team: String
    package var deviceName = "iPhone"
    package var lang: Lang = .en
    package var defaults = UserDefaults.standard
    /// Run tools in a process group of their own (the model's Stop ends the group). The terminal does not need it.
    package var ownGroup = false
    package var toolPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    package var log: (String) -> Void = { _ in }
    package var stage: (ShellStage) -> Void = { _ in }
    /// Told when a tool has started, so Stop can end it (the model keeps it).
    package var processStarted: (RunningProcess) -> Void = { _ in }
    /// Starts every tool and the device listing (`ProcessRunner`, NXCore). A test passes in a fake.
    package var runner: ProcessRunner = SystemProcessRunner()
    /// Asked once, only when something must be copied, with the size and the connection. The terminal answers `.copy`.
    package var decideCopy: (ShellCopyPlan) -> ShellCopyDecision = { _ in .copy }
    /// While waiting for a cable: told true when the wait starts and false when it ends, and asked between polls whether the
    /// player cancelled.
    package var waiting: (Bool) -> Void = { _ in }
    package var waitCancelled: () -> Bool = { false }
    /// The bytes copied so far and the bytes to copy, told before each file and after it (the data send shows them).
    package var copyProgress: (Int64, Int64) -> Void = { _, _ in }
    /// Seconds between two looks at `devicectl list devices` while waiting for a cable.
    package var pollInterval: TimeInterval = 4
    /// Where the eShop banners are cached (ArtworkStore), read only: the game's goes into its framework for the shell's library.
    package var banners: URL = BannerCache.directory
    /// A picture the player chose for the game in the library, which wins over the cached banner (nil: none).
    package var pickedArtwork: String? = nil
    /// The size of one part of a file sent in parts, and the largest file sent whole to an app that may not join parts
    /// (`ShellDataParts`). A test makes them small.
    package var partSize: Int64 = ShellDataParts.partSize
    package var singleCopyLimit: Int64 = ShellDataParts.singleCopyLimit()

    package init(xcrun: String = "/usr/bin/xcrun", repo: String, python: String, root: String, device: String, team: String) {
        self.xcrun = xcrun; self.repo = repo; self.python = python; self.root = root; self.device = device; self.team = team
    }

    package struct Outcome {
        package var ok: Bool
        package var message: String
        package var step: BuildFailureClassifier.InstallStep? = nil   // the failed device step, for the failure card
        package var appPath = ""
        /// The IPA of an export (ShellExport.swift).
        package var ipaPath = ""
        /// devicectl's own words for a copy that failed (the data copy of `sendData` shows them).
        package var detail = ""
        /// The data send: what the copy meant (`ShellExport.swift`), the copies of the shared app when there are several, the app's name.
        package var dataFailure: ShellInstall.DataFailure? = nil
        package var apps: [InstalledApp] = []
        package var appName = ""
        package var bundleID = ""
        package var copied = 0
        package var copySkipped = false
        /// The card the launcher shows for the failure, when it has words for it.
        package var failure: BuildFailureKind? = nil
        /// Signed without the Increased Memory Limit, because the team's profile cannot carry it yet.
        package var noMemoryCapability = false

        package init(ok: Bool, message: String, step: BuildFailureClassifier.InstallStep? = nil, appPath: String = "", bundleID: String = "", copied: Int = 0, copySkipped: Bool = false, failure: BuildFailureKind? = nil, noMemoryCapability: Bool = false) {
            self.ok = ok; self.message = message; self.step = step; self.appPath = appPath; self.bundleID = bundleID; self.copied = copied
            self.copySkipped = copySkipped; self.failure = failure; self.noMemoryCapability = noMemoryCapability
        }
    }

    package static let projectStageID = 1010, signStageID = 1001, installStageID = 1002, copyStageID = 1003, checkStageID = 1011

    func t(_ key: String) -> String { L10n.string(key, lang) }
    func fmt(_ key: String, _ args: CVarArg...) -> String { String(format: t(key), arguments: args) }

    struct ToolResult { var status: Int32; var output: String; var lastError: String? }

    /// The mirror in the shell folder is the primary copy of a game's framework: shell.json points there. A game whose
    /// framework is in its build folder is mirrored now, so a game built before the mirror existed gets one too. A game whose
    /// build folder is gone plays from the mirror it already has. A failed mirror is logged and the game keeps its build path.
    /// Returns the mirrors it replaced with the hidden path their previous framework was kept at, for `prepareShell` to put back
    /// when build_shell.sh refuses the new one.
    func mirrorFrameworks(_ library: inout ShellLibrary) -> [(mirror: String, previous: String)] {
        let fm = FileManager.default
        var replaced: [(mirror: String, previous: String)] = []
        for i in library.games.indices {
            let game = library.games[i]
            let mirror = ShellInstall.mirroredFramework(root: root, titleID: game.titleID)
            if game.framework == mirror { continue }
            if fm.fileExists(atPath: game.framework) {
                do {
                    if let previous = try ShellInstall.mirrorFramework(framework: game.framework, root: root, titleID: game.titleID,
                                                                       keepPrevious: true) {
                        replaced.append((mirror, previous))
                    }
                    library.games[i].framework = mirror
                } catch {
                    log("library: \(game.titleID)'s framework could not be mirrored at \(mirror), it stays at \(game.framework): \(error.localizedDescription)\n")
                }
            } else if fm.fileExists(atPath: mirror) {
                log("library: \(game.titleID)'s build folder is gone, its framework is the mirror at \(mirror)\n")
                library.games[i].framework = mirror
            }
        }
        return replaced
    }

    /// The framework the build should have written is not there: the build steps passed, but a framework deleted by hand, a
    /// cancelled build, a moved work folder or an old build folder leaves nothing to hand off (#491). The message names the game and the
    /// folder by its short name and says what to do. The full path goes to the log.
    func missingFramework(_ framework: String, name: String) -> Outcome {
        log("framework: not found at \(framework)\n")
        let folder = ((framework as NSString).deletingLastPathComponent as NSString).lastPathComponent
        return Outcome(ok: false, message: fmt("shell.noFramework", name, folder.isEmpty ? "shell-framework" : folder))
    }

    package func install(framework: String, titleID: String, name: String, archive: String) -> Outcome {
        guard FileManager.default.fileExists(atPath: framework) else {
            return missingFramework(framework, name: name)
        }
        // A device this Mac never paired is found out now, not after the signing: nothing is built for it
        if let refused = pairingRefusal() { return refused }
        // 3 and 4: the library and the project
        let prepared = prepareShell(framework: framework, titleID: titleID, name: name)
        guard var library = prepared.library, let env = prepared.env else { return prepared.failure! }
        let projectName = t("shell.projectStage")

        // 5: sign and build, with one retry under this team's own identifier
        let signName = fmt("dev.signStage", deviceName)
        func sign(_ bundleID: String) -> ToolResult {
            begin(Self.signStageID, signName)
            return run(ShellInstall.buildCommand(xcrun: xcrun, root: root, device: device, team: team, bundleID: bundleID),
                       env: nil, label: signName, step: BuildProgress.xcodeStep)
        }
        var bundleID = library.bundleID
        var built = sign(bundleID)
        let variant = ShellLibrary.teamVariant(team: team)
        if built.status != 0, ShellInstall.retryUnderTeamVariant(built.output, attempted: bundleID, variant: variant) {
            log("signing: \(bundleID) is registered to another team, retrying as \(variant)\n")
            bundleID = variant
            built = sign(bundleID)
        }
        // A team whose profiles cannot carry the Increased Memory Limit (a free Apple ID, or a paid one whose holder has not yet
        // accepted the current Program License Agreement, so Xcode cannot add the capability) fails here. The shell is generated
        // again without the request and signed with what the team has: it installs and runs, and the log says that a large game may
        // run out of memory until the capability can be added (the next install asks for it again).
        var noMemoryCapability = false
        if built.status != 0, ShellInstall.memoryCapabilityMissing(built.output) {
            log("signing: the team's provisioning profile cannot carry the Increased Memory Limit capability; signing without it (a large game may run out of memory)\n")
            var plain = env; plain["DM_ENTITLEMENTS"] = ""
            let again = run(ShellInstall.projectCommand(repo: repo), env: plain, label: projectName, step: { _ in nil })
            if again.status == 0 {
                ShellInstall.refreshProjectLinks(root: root, resources: resources, repo: repo)
                noMemoryCapability = true
                built = sign(bundleID)
            }
        }
        if built.status != 0 {
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
        end(Self.signStageID, signName, ok: true)
        // The identifier that signed is the one the device's app gets: stored once the signing passed, also when the sign without the
        // Increased Memory Limit is what passed under the team's variant, so the next install starts with it
        if bundleID != library.bundleID {
            library.bundleID = bundleID
            try? library.save(root: root)
        }

        // 6: install over the existing app, which keeps its Documents
        let app = ShellInstall.appPath(root: root)
        guard FileManager.default.fileExists(atPath: app) else {
            return Outcome(ok: false, message: fmt("dev.noProject", app), step: .install)
        }
        let installName = fmt("dev.installStage", deviceName)
        begin(Self.installStageID, installName)
        let installed = run(ShellInstall.installCommand(xcrun: xcrun, device: device, app: app), env: nil, label: installName, step: BuildProgress.installStep)
        if installed.status != 0 {
            let why = installed.lastError ?? fmt("msg.exitCode", installed.status)
            end(Self.installStageID, installName, ok: false, detail: why)
            return Outcome(ok: false, message: fmt("dev.installFailed", why), step: .install)
        }
        ShellLibrary.recordInstalled(root: root)
        end(Self.installStageID, installName, ok: true)

        // 7: the game data, only what the device does not have yet
        var outcome = Outcome(ok: true, message: fmt("dev.installed", deviceName), appPath: app, bundleID: bundleID)
        outcome.noMemoryCapability = noMemoryCapability
        var result = copyGameData(titleID: titleID, archive: archive, app: app, bundleID: bundleID, outcome: outcome, appJoinsParts: true)
        if result.ok, !prepared.notes.isEmpty { result.message = ([result.message] + prepared.notes).joined(separator: "\n") }
        return result
    }

    /// Step 7 on its own, for a Retry after a copy that failed midway: the listing, the diff and the copy, nothing else. The app
    /// is on the device already, under the identifier shell.json holds.
    package func installData(titleID: String, archive: String) -> Outcome {
        if let refused = pairingRefusal() { return refused }
        let bundleID = ShellLibrary.load(root: root).bundleID, app = ShellInstall.appPath(root: root)
        return copyGameData(titleID: titleID, archive: archive, app: app, bundleID: bundleID,
                            outcome: Outcome(ok: true, message: fmt("dev.installed", deviceName), appPath: app, bundleID: bundleID),
                            appJoinsParts: true)
    }

    /// The pairing steps as a failure when this Mac does not know the device, else nil.
    func pairingRefusal() -> Outcome? {
        guard connection() == .notPaired else { return nil }
        return Outcome(ok: false, message: fmt("shell.notPaired", deviceName), failure: .devicePairing)
    }

    private func connection() -> ShellInstall.Connection {
        ShellInstall.connection(of: device, in: DeviceTools.devices(xcrun: xcrun, timeout: 20, runner: runner))
    }

    /// The game data the device lacks, into the app's `Documents/games/<title ID>/`. `appJoinsParts` says whether the app on the
    /// device joins parts (`ShellDataParts`): true for the shared app this launcher just built, nil to ask the app (its
    /// `shell-features.txt`). A file larger than one part goes as parts to an app that joins them; to any other app only a file
    /// devicectl cannot copy whole (`singleCopyLimit`) does, since the whole copy would stall anyway.
    func copyGameData(titleID: String, archive: String, app: String, bundleID: String, outcome start: Outcome, appJoinsParts: Bool? = nil) -> Outcome {
        var outcome = start
        let checkName = fmt("shell.checkStage", deviceName)
        begin(Self.checkStageID, checkName)
        let listing = NSTemporaryDirectory() + "nspb-shell-files-\(UUID().uuidString.prefix(8)).json"
        defer { try? FileManager.default.removeItem(atPath: listing) }
        // A folder that does not exist yet makes devicectl exit non-zero with an error JSON: nothing on the device, not a failure
        _ = run(ShellInstall.listCommand(xcrun: xcrun, device: device, bundleID: bundleID, titleID: titleID, json: listing),
                env: nil, label: checkName, step: { _ in nil })
        let onDevice = ShellInstall.parseListing(FileManager.default.contents(atPath: listing))
        let local = ShellInstall.localFiles(in: archive)
        // The listing still catches missing and interrupted copies. Two releases can also have the same image size.
        let receipt = "shellCopiedRomFS/\(device)/\(bundleID)/\(titleID)"
        let previous = defaults.string(forKey: receipt)
        let identity = local["romfs.img"] == nil ? nil : imageIdentity(archive: archive, titleID: titleID)
        // The image's parts on the device count only when they are parts of this image: a send of it that stopped halfway records
        // the image it was sending (`partsReceipt`), and its parts then need not go again.
        let partsReceipt = receipt + "/parts"
        var comparable = onDevice
        if identity != previous {
            comparable.removeValue(forKey: "romfs.img")
            if identity == nil || defaults.string(forKey: partsReceipt) != identity {
                comparable = comparable.filter { !ShellDataParts.isPart($0.key, of: "romfs.img") }
            }
        }
        var splitAbove = partSize
        if local.values.contains(where: { $0 > partSize }), !(appJoinsParts ?? appSaysItJoinsParts(bundleID: bundleID, label: checkName)) {
            splitAbove = max(partSize, singleCopyLimit)
        }
        let missing = ShellDataParts.toCopy(local: local, device: comparable, splitAbove: splitAbove, partSize: partSize)
        end(Self.checkStageID, checkName, ok: true)
        guard !missing.isEmpty else {
            outcome.message = fmt(identity != nil && identity == previous ? "shell.dataCurrent" : "shell.dataAlready", deviceName)
            return outcome
        }
        // Free space first: the shell writes it to its log at every start (ShellMain.m), and a game's data is many GB. Without a log
        // (a shell never opened yet) the copy goes ahead and devicectl reports a full device itself.
        let needed = missing.reduce(Int64(0)) { $0 + ShellDataParts.bytes(of: $1, local: local, partSize: partSize) }
        let logCopy = NSTemporaryDirectory() + "nspb-shell-log-\(UUID().uuidString.prefix(8)).txt"
        defer { try? FileManager.default.removeItem(atPath: logCopy) }
        _ = run(ShellInstall.shellLogCommand(xcrun: xcrun, device: device, bundleID: bundleID, destination: logCopy), env: nil, label: checkName, step: { _ in nil })
        if let free = ShellInstall.freeSpace(inShellLog: try? String(contentsOfFile: logCopy, encoding: .utf8)) {
            log("device free space: \(free) bytes, the game data to copy: \(needed) bytes\n")
            if needed + ShellInstall.freeSpaceMargin > free {
                return Outcome(ok: false, message: fmt("shell.noSpace", deviceName, Double(needed) / 1e9, Double(free) / 1e9), appPath: app, bundleID: bundleID)
            }
        }
        // The size and the connection first: a cable needs the device unlocked, Wi-Fi takes long enough that a cable may be worth it
        var link = connection()
        var plan = copyPlan(files: Set(missing.map(\.file)).count, bytes: needed, connection: link)
        if let identity, let previous, identity != previous {
            let note = t("shell.dataChanged")
            plan.versionNote = note
            log(note + "\n")
        }
        log(plan.sizeText + "\n" + plan.connectionText + "\n")
        let parts = missing.filter { if case .part = $0 { return true } else { return false } }.count
        if parts > 0 { log(fmt("shell.dataParts", parts) + "\n") }
        var decision = decideCopy(plan)
        if decision == .waitForCable {
            log(fmt("shell.copyWaiting", deviceName) + "\n")
            waiting(true)
            while !waitCancelled() {
                Thread.sleep(forTimeInterval: pollInterval)
                link = connection()
                if link == .wired { break }
            }
            waiting(false)
            decision = link == .wired && !waitCancelled() ? .copy : .skip
        }
        guard decision == .copy else {
            outcome.copySkipped = true
            outcome.message = fmt("dev.copySkipped", deviceName)
            return outcome
        }
        let copyName = fmt("dev.copyStage", deviceName)
        begin(Self.copyStageID, copyName)
        var copiedBytes: Int64 = 0
        for (i, item) in missing.enumerated() {
            copyProgress(copiedBytes, needed)
            // devicectl reports per file, not per byte. Before the first file is whole there is nothing true to show, and a single
            // 17 GB image would read 0% for its whole run. So the bar stays indeterminate until bytes are done (LNPANDY/NX2Apple#967).
            stage(ShellStage(id: Self.copyStageID, name: copyName, state: .running, detail: "\(i + 1)/\(missing.count)",
                             percent: copiedBytes > 0 && needed > 0 ? Double(copiedBytes) / Double(needed) * 100 : nil))
            // Once an overwrite begins, the old receipt cannot vouch for what a failed copy leaves behind.
            if item.file == "romfs.img", previous != nil { defaults.removeObject(forKey: receipt) }
            var source = archive + "/" + item.file, destination = item.file, staged: String?
            if case .part(let file, let index, let count) = item {
                // The part is cut into a file of its own, which devicectl reads whole, and removed after the copy
                if file == "romfs.img", let identity { defaults.set(identity, forKey: partsReceipt) }
                let path = NSTemporaryDirectory() + "nspb-part-\(UUID().uuidString.prefix(8))"
                do {
                    try ShellDataParts.writePart(source: source, index: index, size: local[file] ?? 0, partSize: partSize, to: path)
                } catch {
                    try? FileManager.default.removeItem(atPath: path)
                    let why = error.localizedDescription
                    end(Self.copyStageID, copyName, ok: false, detail: why)
                    var incomplete = Outcome(ok: false, message: fmt("shell.copyIncomplete", deviceName, why), appPath: app, bundleID: bundleID,
                                             copied: i, failure: .shellDataIncomplete)
                    incomplete.detail = why
                    return incomplete
                }
                staged = path; source = path; destination = ShellDataParts.name(of: file, index: index, count: count)
            }
            let r = run(ShellInstall.copyCommand(xcrun: xcrun, device: device, bundleID: bundleID, titleID: titleID,
                                                 source: source, relativePath: destination),
                        env: nil, label: copyName, step: BuildProgress.installStep)
            if let staged { try? FileManager.default.removeItem(atPath: staged) }
            if r.status != 0 {
                let why = r.lastError ?? fmt("msg.exitCode", r.status)
                end(Self.copyStageID, copyName, ok: false, detail: why)
                // The file that failed may be on the device in part. The next listing sees its size is not the local one and copies it
                // again, so a Retry finishes the data. Nothing here marks the game as ready.
                var incomplete = Outcome(ok: false, message: fmt("shell.copyIncomplete", deviceName, why), appPath: app, bundleID: bundleID, copied: i,
                                         failure: .shellDataIncomplete)
                incomplete.detail = why
                return incomplete
            }
            outcome.copied = i + 1
            copiedBytes += ShellDataParts.bytes(of: item, local: local, partSize: partSize)
        }
        if let identity, missing.contains(where: { $0.file == "romfs.img" }) {
            defaults.set(identity, forKey: receipt)
            defaults.removeObject(forKey: partsReceipt)
        }
        copyProgress(needed, needed)
        end(Self.copyStageID, copyName, ok: true)
        return outcome
    }

    private func copyPlan(files: Int, bytes: Int64, connection: ShellInstall.Connection) -> ShellCopyPlan {
        let connectionText: String
        switch connection {
        case .network:
            let e = ShellInstall.wifiEstimate(bytes: bytes)
            let size = ShellInstall.sizeText(bytes)
            connectionText = e.high == 1 ? fmt("shell.copyWifiMinute", size)
                : e.low == e.high ? fmt("shell.copyWifiOne", size, e.low) : fmt("shell.copyWifi", size, e.low, e.high)
        case .notConnected, .notPaired: connectionText = fmt("shell.copyNotConnected", deviceName)
        case .wired, .other: connectionText = fmt("shell.copyWired", deviceName)
        }
        return ShellCopyPlan(files: files, bytes: bytes, connection: connection, deviceName: deviceName,
                             sizeText: fmt("shell.copySize", ShellInstall.sizeText(bytes), files), connectionText: connectionText)
    }

    func begin(_ id: Int, _ name: String) { stage(ShellStage(id: id, name: name, state: .running)) }
    func end(_ id: Int, _ name: String, ok: Bool, detail: String = "") {
        stage(ShellStage(id: id, name: name, state: ok ? .done : .failed, detail: detail, percent: ok ? 100 : nil))
    }

    /// One tool, blocking: its output lines go to `log`, the last error line is kept. `env` nil is the plain tool environment of the
    /// per-game install (xcodebuild, devicectl).
    func run(_ command: [String], env: [String: String]?, label: String,
                     step: (String) -> (detail: String, percent: Double?)?) -> ToolResult {
        log("[\(label)] \(command.joined(separator: " "))\n")
        var output = "", lastError: String?
        let launch = ProcessLaunch(
            executable: command[0], arguments: Array(command.dropFirst()),
            environment: env ?? ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "USER": NSUserName(), "LANG": "en_US.UTF-8"],
            groupPython: ownGroup ? python : nil)
        let result = runner.streamLines(launch, started: processStarted) { line in
            log(line + "\n")
            output += line + "\n"
            if line.contains("error:") || line.hasPrefix("ERROR:") { lastError = line.trimmingCharacters(in: .whitespaces) }
        }
        guard result.started else { return ToolResult(status: 127, output: result.out, lastError: result.out) }
        return ToolResult(status: result.status, output: output, lastError: lastError)
    }
}

