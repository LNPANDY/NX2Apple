import Foundation
import NXCore
import NXLauncher

// Route C: one app on the iPhone or iPad that holds several games. The build script makes only each game's framework
// (`--shell-framework`), and this file does the rest: the shell's library file (shell.json), the shell's Xcode project
// (dm/ios/tools/build_shell.sh), signing, the install, and the game data. Everything pure (the file, the commands, the listing
// parser, the diff) is a static function with its own tests. `ShellInstaller` strings them together, blocking, so the same code
// runs under the build model (on a background queue) and from the terminal (`NSPortBuilder --install-shell`).

/// The shell's library: which games are in it, and the bundle ID the app has on the device. It lives in `<shell root>/shell.json`.
struct ShellLibrary: Codable, Equatable {
    struct Game: Codable, Equatable {
        var titleID: String
        var name: String
        var framework: String
    }

    static let defaultBundleID = "org.nxnative.shell"

    var bundleID = ShellLibrary.defaultBundleID
    var team = ""
    var games: [Game] = []

    /// The identifier a team falls back to when `org.nxnative.shell` is registered to another team (the same per-team variant the
    /// per-game install uses). Once stored in shell.json it stays: the app's Documents (game data, saves) belong to the identifier.
    static func teamVariant(team: String) -> String { defaultBundleID + "." + team }

    /// Adding a game replaces the entry with the same title ID (a rebuilt game has a new framework folder), otherwise appends.
    mutating func add(_ game: Game) {
        if let i = games.firstIndex(where: { $0.titleID == game.titleID }) { games[i] = game } else { games.append(game) }
    }

    /// Drops the games whose framework folder is gone, so the shell is never built against a missing one.
    mutating func dropMissing(exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        games = games.filter { exists($0.framework) }
    }

    static func stateFile(root: String) -> String { root + "/shell.json" }

    /// The file's library, or a fresh one when there is none (or it cannot be read: the next save writes a valid one).
    static func load(root: String) -> ShellLibrary {
        guard let data = FileManager.default.contents(atPath: stateFile(root: root)),
              let library = try? JSONDecoder().decode(ShellLibrary.self, from: data) else { return ShellLibrary() }
        return library
    }

    func save(root: String) throws {
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: URL(fileURLWithPath: Self.stateFile(root: root)), options: .atomic)
    }

    /// The shell root: the saved one (`shellRoot` in `defaults`), else `<parent>/NX2Apple-shell`, which is then saved so the shell
    /// stays where it was first made, whatever output folder a later build uses.
    static func resolveRoot(defaults: UserDefaults = .standard, parent: String) -> String {
        if let saved = defaults.string(forKey: "shellRoot"), !saved.isEmpty { return saved }
        let root = parent + "/NX2Apple-shell"
        defaults.set(root, forKey: "shellRoot")
        return root
    }
}

/// The commands and parsers of the shell install, as pure functions.
enum ShellInstall {
    static let appName = "DmShell.app"
    static let scheme = "DmShell"
    static let projectName = "DmShell.xcodeproj"

    static func projectFolder(root: String) -> String { root + "/project" }
    static func derivedData(root: String) -> String { root + "/derived-data" }
    static func appPath(root: String) -> String { derivedData(root: root) + "/Build/Products/Release-iphoneos/" + appName }

    /// The folder that mirrors every game's framework inside the shell folder: a game survives its build folder's deletion here.
    static func frameworksMirror(root: String) -> String { root + "/frameworks" }
    static func mirroredFramework(root: String, titleID: String) -> String {
        frameworksMirror(root: root) + "/DmGame\(titleID).framework"
    }

    /// Mirrors a framework into the shell folder as a copy. On APFS the copy is a clone: it costs no space, and a later write to
    /// the build folder does not reach it. On another volume it is a real copy. It replaces the previous mirror, so a rebuilt
    /// game's mirror follows, and a failed copy leaves no half mirror behind.
    static func mirrorFramework(framework: String, root: String, titleID: String? = nil) throws {
        let fm = FileManager.default
        let mirror = mirroredFramework(root: root, titleID: titleID ?? Self.titleID(ofFramework: framework))
        try fm.createDirectory(atPath: (mirror as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? fm.removeItem(atPath: mirror)
        do { try fm.copyItem(atPath: framework, toPath: mirror) }
        catch {
            try? fm.removeItem(atPath: mirror)
            throw error
        }
    }

    /// The title ID a framework path carries (`DmGame0100…framework`, the build script's name).
    static func titleID(ofFramework framework: String) -> String {
        let name = (framework as NSString).lastPathComponent
        return name.hasPrefix("DmGame") && name.hasSuffix(".framework")
            ? String(name.dropFirst("DmGame".count).dropLast(".framework".count)) : ""
    }

    /// The framework the build script's `--shell-framework <folder>` writes for a game.
    static func frameworkPath(workDir: String, titleID: String) -> String {
        workDir + "/shell-framework/DmGame\(titleID).framework"
    }

    /// The part of the build script's argument list that makes the game's framework instead of an Xcode project.
    static func buildArguments(workDir: String, team: String) -> [String] {
        ["--shell-framework", workDir + "/shell-framework", "--team-id", team]
    }

    // ---- 4: the project ----

    static func projectCommand(repo: String) -> [String] {
        ["/bin/bash", repo + "/dm/ios/tools/build_shell.sh", "--prepare-xcode"]
    }

    /// The `frontend-ios` Swift package the shell project links (build_shell.sh's DM_SHELL_PACKAGE). The script defaults to
    /// `frontend-ios` beside `dm/`, which is the engine root, and an engine tree has none since #214. So: the release app's
    /// Contents/Resources/frontend-ios, else the source checkout's `frontend-ios` (`repo`). nil when neither has a Package.swift.
    static func shellPackage(resources: String?, repo: String, fm: FileManager = .default) -> String? {
        ([resources, repo].compactMap { $0 }.filter { !$0.isEmpty }).map { $0 + "/frontend-ios" }
            .first { fm.fileExists(atPath: $0 + "/Package.swift") }
    }

    /// What build_shell.sh reads. `path` is the build's own tool PATH (xcodegen must be found on it).
    static func projectEnvironment(root: String, frameworks: [String], bundleID: String, team: String, python: String,
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
    static func buildCommand(xcrun: String, root: String, device: String, team: String, bundleID: String) -> [String] {
        [xcrun, "xcodebuild", "-project", projectFolder(root: root) + "/" + projectName, "-scheme", scheme,
         "-configuration", "Release", "-destination", "id=\(device)", "-derivedDataPath", derivedData(root: root),
         "-allowProvisioningUpdates", "DEVELOPMENT_TEAM=\(team)", "PRODUCT_BUNDLE_IDENTIFIER=\(bundleID)", "build"]
    }

    /// Installing over the existing app keeps its Documents.
    static func installCommand(xcrun: String, device: String, app: String) -> [String] {
        [xcrun, "devicectl", "device", "install", "app", "--device", device, app]
    }

    // ---- 7: the game data ----

    static func gameFolder(titleID: String) -> String { "Documents/games/\(titleID)" }

    /// Kept free beyond the data on the device (the game's saves, shader caches, the system).
    static let freeSpaceMargin: Int64 = 2_000_000_000

    /// The shell's own log from the device (Documents/shell-log.txt, written at every start).
    static func shellLogCommand(xcrun: String, device: String, bundleID: String, destination: String) -> [String] {
        [xcrun, "devicectl", "device", "copy", "from", "--device", device, "--domain-type", "appDataContainer",
         "--domain-identifier", bundleID, "--source", "Documents/shell-log.txt", "--destination", destination]
    }

    /// The last "shell: free space <bytes> bytes" line of the shell's log, nil without one.
    static func freeSpace(inShellLog text: String?) -> Int64? {
        guard let text else { return nil }
        return text.split(separator: "\n").reversed().lazy.compactMap { line -> Int64? in
            guard line.hasPrefix("shell: free space ") else { return nil }
            return Int64(line.dropFirst("shell: free space ".count).split(separator: " ").first ?? "")
        }.first.flatMap { $0 >= 0 ? $0 : nil }
    }

    /// xcodebuild's words when the provisioning profile lacks the Increased Memory Limit the shell asks for.
    static func memoryCapabilityMissing(_ output: String) -> Bool {
        output.contains("doesn't include the Increased Memory Limit capability") || output.contains("doesn't include the com.apple.developer.kernel.increased-memory-limit entitlement")
    }

    /// Copies the game's banner into its framework as banner.<ext>, the picture the shell's library shows: the player's own pick,
    /// else the eShop banner the launcher caches per title ID (ArtworkStore). The cache is only read. Without either, an older
    /// banner is removed and the library shows the framework's icon.png. Returns the picture used.
    @discardableResult static func placeBanner(titleID: String, framework: String, banners: URL, picked: String?,
                                               fm: FileManager = .default) -> String? {
        let source = [picked, ArtworkStore.cachedBanner(titleID, in: banners)?.path].compactMap { $0 }.first { !$0.isEmpty && fm.fileExists(atPath: $0) }
        for ext in ["png", "jpg", "jpeg", "heic", "webp"] { try? fm.removeItem(atPath: framework + "/banner." + ext) }
        guard let source else { return nil }
        let ext = (source as NSString).pathExtension.lowercased()
        let dest = framework + "/banner." + (["png", "jpg", "jpeg", "heic", "webp"].contains(ext) ? ext : "jpg")
        return (try? fm.copyItem(atPath: source, toPath: dest)) != nil ? source : nil
    }

    /// devicectl's recursive listing of the game's folder in the app's container, written as JSON to `json`.
    static func listCommand(xcrun: String, device: String, bundleID: String, titleID: String, json: String) -> [String] {
        [xcrun, "devicectl", "device", "info", "files", "--device", device, "--domain-type", "appDataContainer",
         "--domain-identifier", bundleID, "--subdirectory", gameFolder(titleID: titleID), "--json-output", json]
    }

    /// One file into the game's folder. A file destination creates the parent folders and names the file. Never
    /// `--remove-existing-content true`: on a real device it deletes the destination's siblings too (#266).
    static func copyCommand(xcrun: String, device: String, bundleID: String, titleID: String, source: String, relativePath: String) -> [String] {
        [xcrun, "devicectl", "device", "copy", "to", "--device", device, "--source", source,
         "--destination", gameFolder(titleID: titleID) + "/" + relativePath,
         "--domain-type", "appDataContainer", "--domain-identifier", bundleID]
    }

    /// The device's files (path relative to the game's folder → size) from the listing JSON. The error JSON of a folder that does
    /// not exist (or an app that is new) and anything unreadable mean "nothing on the device": an empty list.
    static func parseListing(_ data: Data?) -> [String: Int64] {
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
    static func localFiles(in archive: String) -> [String: Int64] {
        let fm = FileManager.default
        var found: [String: Int64] = [:]
        for case let path as String in fm.enumerator(atPath: archive) ?? FileManager.DirectoryEnumerator() {
            if path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { continue }
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: archive + "/" + path, isDirectory: &isDirectory), !isDirectory.boolValue,
                  let size = (try? fm.attributesOfItem(atPath: archive + "/" + path))?[.size] as? NSNumber else { continue }
            found[path] = size.int64Value
        }
        return found
    }

    /// The local files to copy: missing on the device, or of another size. Sorted, so the copies run in a stable order.
    /// Path and size only: a file with the same size and other content stays. A hash comparison (a manifest the device keeps next to
    /// the game's folder) can close that gap later.
    static func filesToCopy(local: [String: Int64], device: [String: Int64]) -> [String] {
        local.filter { device[$0.key] != $0.value }.map(\.key).sorted()
    }

    /// The reason the build_shell.sh run failed, for the player: its last `[RED]` line (the refusals, for example two different
    /// games in one shell), else its last `FAIL:` line, else the last line it printed.
    static func scriptFailure(_ output: String) -> String? {
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

    /// How the device is connected to this Mac, from `devicectl list devices` (connectionProperties.transportType: "wired" for a
    /// cable, "localNetwork" for Wi-Fi, absent when the device is not reachable). A device the list does not show, or shows
    /// unpaired, was never paired with this Mac.
    enum Connection: Equatable {
        case wired, network, other, notConnected, notPaired
    }

    static func connection(of udid: String, in devices: [AppleDevice]) -> Connection {
        guard let device = devices.first(where: { $0.id == udid }) else { return .notPaired }
        if device.wired { return .wired }
        if device.overNetwork { return .network }
        return device.reachable ? .other : .notConnected
    }

    /// Minutes a copy of `bytes` takes over Wi-Fi, as a range: devicectl over the local network does about 17 to 25 MB/s, so
    /// 15 GB is 10 to 15 minutes. At least one minute.
    static func wifiEstimate(bytes: Int64) -> (low: Int, high: Int) {
        let low = max(1, Int((Double(bytes) / 25e6 / 60).rounded()))
        return (low, max(low, Int((Double(bytes) / 17e6 / 60).rounded())))
    }

    static func sizeText(_ bytes: Int64) -> String {
        // Decimal units as devicectl and the Finder count, and the same text in every locale
        if bytes >= 1_000_000_000 { return String(format: "%.1f GB", Double(bytes) / 1e9) }
        if bytes >= 1_000_000 { return String(format: "%.0f MB", Double(bytes) / 1e6) }
        return String(format: "%.0f KB", (Double(bytes) / 1e3).rounded(.up))
    }

    /// An installed app's shell paths, from its own path (<root>/derived-data/Build/Products/Release-iphoneos/DmShell.app), nil for
    /// any other app. A re-sign runs on that project and derived data.
    static func paths(ofApp app: String) -> (root: String, project: String, derived: String)? {
        guard (app as NSString).lastPathComponent == appName, let marker = app.range(of: "/Build/Products/") else { return nil }
        let derived = String(app[..<marker.lowerBound])
        guard (derived as NSString).lastPathComponent == "derived-data" else { return nil }
        let root = (derived as NSString).deletingLastPathComponent
        return (root, projectFolder(root: root) + "/" + projectName, derived)
    }
}

/// What the player is told before the game data goes over: how much, and over which connection. The GUI shows it with its
/// buttons, the terminal prints it and copies.
struct ShellCopyPlan: Equatable {
    var files: Int
    var bytes: Int64
    var connection: ShellInstall.Connection
    var deviceName: String
    /// "15 GB in 2 files."
    var sizeText: String
    /// The cable note, or the Wi-Fi hint with its estimate.
    var connectionText: String
    /// Whether waiting for a cable is offered (the device is on Wi-Fi, or not connected).
    var canWaitForCable: Bool { connection == .network || connection == .notConnected }
}

enum ShellCopyDecision: Equatable { case copy, skip, waitForCable }

/// One stage of the install, as the model and the terminal show it.
struct ShellStage {
    var id: Int
    var name: String
    var state: StepState
    var detail = ""
    var percent: Double? = nil
}

/// Steps 3 to 7: the shell's library, its project, signing, the install and the game data, blocking. A tool that fails ends the
/// install with its own last error line.
struct ShellInstaller {
    var xcrun = "/usr/bin/xcrun"
    var repo: String
    /// The app's Contents/Resources, where a release app carries frontend-ios. Nil for a launcher run from a checkout.
    var resources: String? = Bundle.main.resourceURL?.path
    var python: String
    var root: String
    var device: String
    var team: String
    var deviceName = "iPhone"
    var lang: Lang = .en
    /// Run tools in a process group of their own (the model's Stop ends the group). The terminal does not need it.
    var ownGroup = false
    var toolPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    var log: (String) -> Void = { _ in }
    var stage: (ShellStage) -> Void = { _ in }
    var processStarted: (Process) -> Void = { _ in }
    var processEnded: (Process) -> Void = { _ in }
    /// Asked once, only when something must be copied, with the size and the connection. The terminal answers `.copy`.
    var decideCopy: (ShellCopyPlan) -> ShellCopyDecision = { _ in .copy }
    /// While waiting for a cable: told true when the wait starts and false when it ends, and asked between polls whether the
    /// player cancelled.
    var waiting: (Bool) -> Void = { _ in }
    var waitCancelled: () -> Bool = { false }
    /// Seconds between two looks at `devicectl list devices` while waiting for a cable.
    var pollInterval: TimeInterval = 4
    /// Where the eShop banners are cached (ArtworkStore), read only: the game's goes into its framework for the shell's library.
    var banners: URL = ArtworkStore.shared.directory
    /// A picture the player chose for the game in the library, which wins over the cached banner (nil: none).
    var pickedArtwork: String? = nil

    struct Outcome {
        var ok: Bool
        var message: String
        var step: BuildFailureClassifier.InstallStep? = nil   // the failed device step, for the failure card
        var appPath = ""
        var bundleID = ""
        var copied = 0
        var copySkipped = false
        /// The card the launcher shows for the failure, when it has words for it.
        var failure: BuildFailureKind? = nil
        /// Signed without the Increased Memory Limit, because the team's profile cannot carry it yet.
        var noMemoryCapability = false
    }

    static let projectStageID = 1010, signStageID = 1001, installStageID = 1002, copyStageID = 1003, checkStageID = 1011

    private func t(_ key: String) -> String { L10n.string(key, lang) }
    private func fmt(_ key: String, _ args: CVarArg...) -> String { String(format: t(key), arguments: args) }

    private struct ToolResult { var status: Int32; var output: String; var lastError: String? }

    /// The mirror in the shell folder is the primary copy of a game's framework: shell.json points there. A game whose
    /// framework is in its build folder is mirrored now, so a game built before the mirror existed gets one too. A game whose
    /// build folder is gone plays from the mirror it already has. A failed mirror is logged and the game keeps its build path.
    private func mirrorFrameworks(_ library: inout ShellLibrary) {
        let fm = FileManager.default
        for i in library.games.indices {
            let game = library.games[i]
            let mirror = ShellInstall.mirroredFramework(root: root, titleID: game.titleID)
            if game.framework == mirror { continue }
            if fm.fileExists(atPath: game.framework) {
                do {
                    try ShellInstall.mirrorFramework(framework: game.framework, root: root, titleID: game.titleID)
                    library.games[i].framework = mirror
                } catch {
                    log("library: \(game.titleID)'s framework could not be mirrored at \(mirror), it stays at \(game.framework): \(error.localizedDescription)\n")
                }
            } else if fm.fileExists(atPath: mirror) {
                log("library: \(game.titleID)'s build folder is gone, its framework is the mirror at \(mirror)\n")
                library.games[i].framework = mirror
            }
        }
    }

    func install(framework: String, titleID: String, name: String, archive: String) -> Outcome {
        guard FileManager.default.fileExists(atPath: framework) else {
            return Outcome(ok: false, message: fmt("shell.noFramework", framework))
        }
        // A device this Mac never paired is found out now, not after the signing: nothing is built for it
        if let refused = pairingRefusal() { return refused }
        // 3: the library
        var library = ShellLibrary.load(root: root)
        library.team = team
        library.add(.init(titleID: titleID, name: name, framework: framework))
        mirrorFrameworks(&library)
        library.dropMissing()
        // The 16:9 banner of the shell's library for every game in it (ShellHost reads <framework>/banner.<ext>, the square
        // icon.png is the fallback): a game rebuilt since its last install gets its banner back too
        for game in library.games {
            let picked = game.titleID == titleID ? pickedArtwork : nil
            if let banner = ShellInstall.placeBanner(titleID: game.titleID, framework: game.framework, banners: banners, picked: picked) {
                log("banner: \(game.titleID) \(banner)\n")
            }
        }
        do { try library.save(root: root) } catch {
            return Outcome(ok: false, message: fmt("shell.projectFailed", error.localizedDescription))
        }

        // 4: the project
        guard let package = ShellInstall.shellPackage(resources: resources, repo: repo) else {
            let looked = ([resources, repo].compactMap { $0 }.filter { !$0.isEmpty }).map { $0 + "/frontend-ios" }.joined(separator: ", ")
            return Outcome(ok: false, message: fmt("shell.projectFailed", "no frontend-ios Swift package (Package.swift) in " + looked))
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
            return Outcome(ok: false, message: fmt("shell.projectFailed", why))
        }
        end(Self.projectStageID, projectName, ok: true)

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
        if built.status != 0, BuildFailureClassifier.signingTeamTaken(built.output), bundleID != variant {
            log("signing: \(bundleID) is registered to another team, retrying as \(variant)\n")
            bundleID = variant
            built = sign(bundleID)
            if built.status == 0 {
                library.bundleID = variant
                try? library.save(root: root)
            }
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
            if again.status == 0 { noMemoryCapability = true; built = sign(bundleID) }
        }
        if built.status != 0 {
            let why = built.lastError ?? fmt("msg.exitCode", built.status)
            end(Self.signStageID, signName, ok: false, detail: why)
            return Outcome(ok: false, message: fmt("dev.signFailed", why), step: .sign)
        }
        end(Self.signStageID, signName, ok: true)

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
        end(Self.installStageID, installName, ok: true)

        // 7: the game data, only what the device does not have yet
        var outcome = Outcome(ok: true, message: fmt("dev.installed", deviceName), appPath: app, bundleID: bundleID)
        outcome.noMemoryCapability = noMemoryCapability
        return copyGameData(titleID: titleID, archive: archive, app: app, bundleID: bundleID, outcome: outcome)
    }

    /// Step 7 on its own, for a Retry after a copy that failed midway: the listing, the diff and the copy, nothing else. The app
    /// is on the device already, under the identifier shell.json holds.
    func installData(titleID: String, archive: String) -> Outcome {
        if let refused = pairingRefusal() { return refused }
        let bundleID = ShellLibrary.load(root: root).bundleID, app = ShellInstall.appPath(root: root)
        return copyGameData(titleID: titleID, archive: archive, app: app, bundleID: bundleID,
                            outcome: Outcome(ok: true, message: fmt("dev.installed", deviceName), appPath: app, bundleID: bundleID))
    }

    /// The pairing steps as a failure when this Mac does not know the device, else nil.
    private func pairingRefusal() -> Outcome? {
        guard connection() == .notPaired else { return nil }
        return Outcome(ok: false, message: fmt("shell.notPaired", deviceName), failure: .devicePairing)
    }

    private func connection() -> ShellInstall.Connection {
        ShellInstall.connection(of: device, in: DeviceTools.devices(xcrun: xcrun, timeout: 20))
    }

    private func copyGameData(titleID: String, archive: String, app: String, bundleID: String, outcome start: Outcome) -> Outcome {
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
        let missing = ShellInstall.filesToCopy(local: local, device: onDevice)
        end(Self.checkStageID, checkName, ok: true)
        guard !missing.isEmpty else {
            outcome.message = fmt("shell.dataAlready", deviceName)
            return outcome
        }
        // Free space first: the shell writes it to its log at every start (ShellMain.m), and a game's data is many GB. Without a log
        // (a shell never opened yet) the copy goes ahead and devicectl reports a full device itself.
        let needed = missing.reduce(Int64(0)) { $0 + (local[$1] ?? 0) }
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
        var plan = copyPlan(files: missing.count, bytes: needed, connection: link)
        log(plan.sizeText + "\n" + plan.connectionText + "\n")
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
        for (i, path) in missing.enumerated() {
            stage(ShellStage(id: Self.copyStageID, name: copyName, state: .running, detail: "\(i + 1)/\(missing.count)",
                             percent: Double(i) / Double(missing.count) * 100))
            let r = run(ShellInstall.copyCommand(xcrun: xcrun, device: device, bundleID: bundleID, titleID: titleID,
                                                 source: archive + "/" + path, relativePath: path),
                        env: nil, label: copyName, step: BuildProgress.installStep)
            if r.status != 0 {
                let why = r.lastError ?? fmt("msg.exitCode", r.status)
                end(Self.copyStageID, copyName, ok: false, detail: why)
                // The file that failed may be on the device in part. The next listing sees its size is not the local one and copies it
                // again, so a Retry finishes the data. Nothing here marks the game as ready.
                return Outcome(ok: false, message: fmt("shell.copyIncomplete", deviceName, why), appPath: app, bundleID: bundleID, copied: i,
                               failure: .shellDataIncomplete)
            }
            outcome.copied = i + 1
        }
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

    private func begin(_ id: Int, _ name: String) { stage(ShellStage(id: id, name: name, state: .running)) }
    private func end(_ id: Int, _ name: String, ok: Bool, detail: String = "") {
        stage(ShellStage(id: id, name: name, state: ok ? .done : .failed, detail: detail, percent: ok ? 100 : nil))
    }

    /// One tool, blocking: its output lines go to `log`, the last error line is kept. `env` nil is the plain tool environment of the
    /// per-game install (xcodebuild, devicectl).
    private func run(_ command: [String], env: [String: String]?, label: String,
                     step: (String) -> (detail: String, percent: Double?)?) -> ToolResult {
        log("[\(label)] \(command.joined(separator: " "))\n")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: command[0])
        p.arguments = Array(command.dropFirst())
        p.environment = env ?? ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "USER": NSUserName(), "LANG": "en_US.UTF-8"]
        p.standardInput = FileHandle.nullDevice
        if ownGroup { BuildModel.inOwnGroup(p, python: python) }
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return ToolResult(status: 127, output: error.localizedDescription, lastError: error.localizedDescription) }
        processStarted(p)
        var output = "", pending = "", lastError: String?
        func consume(_ line: String) {
            log(line + "\n")
            output += line + "\n"
            if line.contains("error:") || line.hasPrefix("ERROR:") { lastError = line.trimmingCharacters(in: .whitespaces) }
        }
        let handle = pipe.fileHandleForReading
        while true {
            let data = handle.availableData
            if data.isEmpty { break }
            pending += String(decoding: data, as: UTF8.self)
            while let nl = pending.firstIndex(of: "\n") {
                consume(String(pending[..<nl]))
                pending = String(pending[pending.index(after: nl)...])
            }
        }
        if !pending.isEmpty { consume(pending) }
        p.waitUntilExit()
        processEnded(p)
        return ToolResult(status: p.terminationStatus, output: output, lastError: lastError)
    }
}

/// `NSPortBuilder --install-shell ...`: steps 3 to 7 without a window and without questions, for a terminal or a script.
enum ShellCLI {
    static let usage = "NSPortBuilder --install-shell --framework <path> --archive <games/TITLEID folder> --title-id <id> --name <name> "
        + "--device <udid> --team <team> --repo <repo> [--shell-root <dir>] [--python <path>]"

    /// The options as a dictionary, nil when an option has no value.
    static func parse(_ args: [String]) -> [String: String]? {
        var options: [String: String] = [:]
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "--install-shell" { i += 1; continue }
            guard a.hasPrefix("--"), i + 1 < args.count else { return nil }
            options[String(a.dropFirst(2))] = args[i + 1]
            i += 2
        }
        return options
    }

    /// Exit status: 0 installed, 1 failed (or wrong usage). `out` gets every line, stage lines and tool output alike.
    /// `--xcrun` is for the tests, which stand in for xcodebuild and devicectl.
    static func run(_ args: [String], defaults: UserDefaults = .standard, out: @escaping (String) -> Void = { fputs($0, stdout); fflush(stdout) }) -> Int32 {
        let required = ["framework", "archive", "title-id", "name", "device", "team", "repo"]
        guard let o = parse(args), required.allSatisfy({ !(o[$0] ?? "").isEmpty }) else {
            out("usage: " + usage + "\n")
            return 1
        }
        let archive = o["archive"]!
        let root = o["shell-root"] ?? ShellLibrary.resolveRoot(
            defaults: defaults, parent: ((archive as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent)
        let python = o["python"] ?? Toolchain.findPython().path
        var installer = ShellInstaller(xcrun: o["xcrun"] ?? "/usr/bin/xcrun", repo: o["repo"]!, python: python, root: root,
                                       device: o["device"]!, team: o["team"]!)
        installer.deviceName = o["device"]!
        installer.toolPath = BuildModel.toolPath("/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", python: python)
        installer.log = out
        installer.stage = { s in
            switch s.state {
            case .running: if s.detail.isEmpty { out("==> \(s.name)\n") }
            case .done: out("==> \(s.name): done\n")
            case .failed: out("==> \(s.name): FAILED \(s.detail)\n")
            case .pending: break
            }
        }
        let result = installer.install(framework: o["framework"]!, titleID: o["title-id"]!, name: o["name"]!, archive: archive)
        out((result.ok ? "OK: " : "FAIL: ") + result.message + "\n")
        return result.ok ? 0 : 1
    }
}
