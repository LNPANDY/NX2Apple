import CryptoKit
import Foundation
import NXCore

/// The game's names for a library entry whose app carries no `DMTitleNames` (packed before the engine wrote the key, or not built yet),
/// so no game has to be built again for its name to follow the launcher's language (LNPANDY/NX2Apple#895). From the game's own
/// control data, offline, in this order:
/// 1. a `control.nacp` an earlier build left in its build folder (`<title ID>_build/extract/v<version>/`, the NSP script's),
/// 2. the base game's package (NSP, NSZ, XCI, XCZ) with the player's keys: `nx_extract --control` reads the control data alone
///    (under a second, where an extraction takes minutes). The extractor is built once from the engine's sources with the .NET SDK a
///    build uses and kept in `<cache>/nx_extract-<hash of its sources>/`.
/// A game with neither (the package deleted, no keys, no .NET SDK) keeps showing the bundle name. Blocking: call it off the main thread.
final class TitleNameLookup {
    private let engineRoot: String
    private let cache: URL
    private let runner: ProcessRunner
    private let findDotnet: () -> (path: String, ok: Bool)
    private lazy var tool: String? = buildTool()

    init(engineRoot: String, cache: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NS Port Builder/tools", isDirectory: true),
         runner: ProcessRunner = SystemProcessRunner(), findDotnet: @escaping () -> (path: String, ok: Bool) = { Toolchain.findDotnet() }) {
        self.engineRoot = engineRoot; self.cache = cache; self.runner = runner; self.findDotnet = findDotnet
    }

    /// The names from the game's control data, nil when none could be read.
    func names(for game: LibraryGame) -> [String: String]? {
        if let leftover = Self.leftoverControl(for: game), let data = try? Data(contentsOf: leftover) {
            let names = GameTitleNames.names(nacp: data)
            if !names.isEmpty { return names }
        }
        guard let (keys, package) = Self.packageInputs(of: game), let tool else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("nx2apple-control-" + UUID().uuidString + ".nacp")
        defer { try? FileManager.default.removeItem(at: out) }
        let result = runner.capture(ProcessLaunch(executable: tool, arguments: [keys, "--control", package, out.path, "--app", game.titleID],
                                                  environment: environment(), mergesErrors: true, timeout: 120))
        guard result.started, result.status == 0, let data = try? Data(contentsOf: out) else { return nil }
        let names = GameTitleNames.names(nacp: data)
        return names.isEmpty ? nil : names
    }

    /// The control data a build of this game left in its build folder: beside the base package (the NSP script's default), in the
    /// output folder or in the game's folder. The highest version's, as the build reads it.
    static func leftoverControl(for game: LibraryGame, fm: FileManager = .default) -> URL? {
        var folders: [String] = [game.outputDirectory, game.sourceFolder, (game.appPath as NSString).deletingLastPathComponent]
        folders += (game.inputs["base"] ?? []).map { ($0 as NSString).deletingLastPathComponent }
        for folder in folders where !folder.isEmpty {
            let extract = URL(fileURLWithPath: folder).appendingPathComponent(game.titleID + "_build/extract", isDirectory: true)
            guard let versions = try? fm.contentsOfDirectory(atPath: extract.path) else { continue }
            let found = versions.filter { $0.hasPrefix("v") }
                .sorted { (Int($0.dropFirst()) ?? -1) > (Int($1.dropFirst()) ?? -1) }
                .map { extract.appendingPathComponent($0 + "/control.nacp") }
                .first { fm.fileExists(atPath: $0.path) }
            if let found { return found }
        }
        return nil
    }

    /// The keys file and the base game's package when both are files on disk. A game folder (a Switch 2 game's) or a NUP has no package to read.
    static func packageInputs(of game: LibraryGame, fm: FileManager = .default) -> (keys: String, package: String)? {
        guard let keys = game.inputs["keys"]?.first, let package = game.inputs["base"]?.first,
              ["nsp", "nsz", "xci", "xcz"].contains((package as NSString).pathExtension.lowercased()) else { return nil }
        var dir: ObjCBool = false
        guard fm.fileExists(atPath: keys), fm.fileExists(atPath: package, isDirectory: &dir), !dir.boolValue else { return nil }
        return (keys, package)
    }

    private func environment() -> [String: String] {
        var env = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "TMPDIR": NSTemporaryDirectory(), "LANG": "en_US.UTF-8",
                   "DOTNET_CLI_TELEMETRY_OPTOUT": "1", "DOTNET_NOLOGO": "1"]
        let dotnet = findDotnet()
        if dotnet.ok, let root = Toolchain.dotnetRoot(for: dotnet.path, runner: runner) { env["DOTNET_ROOT"] = root; env["DOTNET_ROOT_ARM64"] = root }
        return env
    }

    /// The extractor for these sources, built now when the cache has none. nil without the sources or a .NET SDK 10, or when the build fails.
    private func buildTool() -> String? {
        let project = URL(fileURLWithPath: engineRoot).appendingPathComponent("dm/tools/nx_extract", isDirectory: true)
        guard let source = try? Data(contentsOf: project.appendingPathComponent("Program.cs")),
              let csproj = try? Data(contentsOf: project.appendingPathComponent("nx_extract.csproj")),
              String(decoding: source, as: UTF8.self).contains("\"--control\"") else { return nil }   // an engine whose extractor has no --control yet
        let hash = SHA256.hash(data: source + csproj).prefix(8).map { String(format: "%02x", $0) }.joined()
        let folder = cache.appendingPathComponent("nx_extract-" + hash, isDirectory: true)
        let exe = folder.appendingPathComponent("nx_extract").path
        if FileManager.default.isExecutableFile(atPath: exe) { return exe }
        let dotnet = findDotnet()
        guard dotnet.ok else { return nil }
        let staging = cache.appendingPathComponent("nx_extract-" + hash + ".partial-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let built = runner.capture(ProcessLaunch(executable: dotnet.path, arguments: ["build", project.path, "-c", "Release", "-o", staging.path, "-v", "quiet", "-nologo"],
                                                 environment: environment(), mergesErrors: true, timeout: 600))
        guard built.started, built.status == 0, FileManager.default.isExecutableFile(atPath: staging.appendingPathComponent("nx_extract").path) else { return nil }
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: folder)
        do { try FileManager.default.moveItem(at: staging, to: folder) } catch { return nil }
        return exe
    }
}

extension GameLibrary {
    /// Looks up the names of the games that have none, in the background, one game at a time, and keeps what it finds. Each game is
    /// tried once per launch and engine tree: a game whose package is gone is not read again on every library change, and a newer
    /// engine (the launcher may start on the previous one and switch, whose extractor may have no --control) tries again.
    func fillMissingTitleNames(engineRoot: String) {
        guard !engineRoot.isEmpty else { return }
        let key = { (game: LibraryGame) in engineRoot + "|" + game.titleID }
        let wanted = games.filter { $0.titleNames.isEmpty && !$0.titleID.hasPrefix("/") && !TitleNameAttempts.shared.contains(key($0)) }
        guard !wanted.isEmpty else { return }
        wanted.forEach { TitleNameAttempts.shared.insert(key($0)) }
        let lookup = TitleNameLookup(engineRoot: engineRoot)
        TitleNameAttempts.queue.async {
            for game in wanted {
                guard let names = lookup.names(for: game) else { continue }
                DispatchQueue.main.async { self.setTitleNames(names, for: game.id) }
            }
        }
    }
}

/// The games looked up this launch (engine tree and title ID), and the queue the lookups run on one after another.
enum TitleNameAttempts {
    static let queue = DispatchQueue(label: "nx2apple.title-names", qos: .utility)
    static let shared = LockedSet()

    final class LockedSet: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: Set<String> = []
        func contains(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return ids.contains(id) }
        func insert(_ id: String) { lock.lock(); ids.insert(id); lock.unlock() }
    }
}
