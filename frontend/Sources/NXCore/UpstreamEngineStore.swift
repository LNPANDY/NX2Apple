import Foundation

/// Managed storage and archive installer for optional external build engines (`MacNativeGames`, `S2Arm`).
/// Trees live in `~/Library/Application Support/NX2Apple/upstreams/<kind>/`, beside `NX2Apple/engine/`, so
/// `EngineStore.prune` never touches them and `Uninstall.plan` cleans them automatically.
package struct UpstreamEngineStore: Sendable {
    package enum Failure: Error, Equatable, Sendable {
        case unsupportedKind
        case cancelled
        case download
        case unpack
        case incomplete
    }

    package let root: URL

    package init(root: URL = UpstreamEngineStore.defaultRoot) {
        self.root = root
    }

    package static var defaultRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("NX2Apple/upstreams", isDirectory: true)
    }

    package static func root(forHome home: String) -> URL {
        URL(fileURLWithPath: home + "/Library/Application Support/NX2Apple/upstreams", isDirectory: true)
    }

    package static func archiveURL(for kind: EngineUpstreamKind) -> URL? {
        switch kind {
        case .nxnative:
            return nil
        case .macNativeGames:
            return URL(string: "https://codeload.github.com/ly05010419/MacNativeGames/zip/refs/heads/main")
        case .s2arm:
            return URL(string: "https://codeload.github.com/jhaizhou-ops/S2Arm/zip/refs/heads/main")
        case .kidWithSword:
            return URL(string: "https://codeload.github.com/cheemu21/kid-with-sword-remake/zip/refs/heads/L")
        case .noLagKart:
            return URL(string: "https://codeload.github.com/kingbumi31/no-lag-kart/zip/refs/heads/main")
        case .nxkit:
            return nil   // bundled with the app, updated by NxkitUpdate.swift
        }
    }

    package static func isUsableTree(_ path: String, kind: EngineUpstreamKind, fileManager fm: FileManager = .default) -> Bool {
        switch kind {
        case .nxnative:
            return true
        case .macNativeGames:
            return MacNativeGamesBuilder.isUsableTree(path, fileManager: fm)
        case .s2arm:
            return S2ArmBuilder.isUsableTree(path, fileManager: fm)
        case .kidWithSword, .noLagKart:
            return EngineUpstream.isTree(path, kind: kind, fileManager: fm)
        case .nxkit:
            return false   // nxkit is bundled and updated by NxkitUpdate, never unpacked here
        }
    }

    package func directory(for kind: EngineUpstreamKind) -> URL? {
        switch kind {
        case .nxnative, .nxkit:
            return nil
        case .macNativeGames, .s2arm, .kidWithSword, .noLagKart:
            return root.appendingPathComponent(kind.rawValue, isDirectory: true)
        }
    }

    package func usableDirectory(for kind: EngineUpstreamKind, fileManager fm: FileManager = .default) -> URL? {
        guard let dir = directory(for: kind), Self.isUsableTree(dir.path, kind: kind, fileManager: fm) else {
            return nil
        }
        return dir
    }

    @discardableResult
    package func install(
        zip: URL,
        kind: EngineUpstreamKind,
        remoteInfo: UpstreamRemoteInfo? = nil,
        shouldCancel: (@Sendable () -> Bool)? = nil
    ) throws -> URL {
        guard let dest = directory(for: kind) else {
            throw Failure.unsupportedKind
        }
        if shouldCancel?() == true {
            throw Failure.cancelled
        }
        let fm = FileManager.default
        let tmp = root.appendingPathComponent(".tmp-" + UUID().uuidString, isDirectory: true)
        do {
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        } catch {
            throw Failure.unpack
        }
        defer { try? fm.removeItem(at: tmp) }

        try Self.unpack(zip: zip, into: tmp, shouldCancel: shouldCancel)

        var source = tmp
        for _ in 0..<2 where !Self.isUsableTree(source.path, kind: kind, fileManager: fm) {
            let children = ((try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                .filter { url in
                    let name = url.lastPathComponent
                    guard name != "__MACOSX" && !name.hasPrefix(".") else { return false }
                    return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                }
            guard children.count == 1, let only = children.first else { break }
            source = only
        }

        guard Self.isUsableTree(source.path, kind: kind, fileManager: fm) else {
            throw Failure.incomplete
        }

        let scriptsToMarkExecutable: [String]
        switch kind {
        case .nxnative:
            scriptsToMarkExecutable = []
        case .macNativeGames:
            scriptsToMarkExecutable = ["build_app.py"]
        case .s2arm:
            scriptsToMarkExecutable = [S2ArmBuilder.macOneClickScript, "pack/jobs/main.py"]
        case .kidWithSword, .noLagKart:
            scriptsToMarkExecutable = [RepoLayout.buildScript]
        case .nxkit:
            scriptsToMarkExecutable = []
        }
        for rel in scriptsToMarkExecutable {
            let scriptPath = source.appendingPathComponent(rel).path
            if fm.fileExists(atPath: scriptPath) {
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
            }
        }

        let receipt = UpstreamVersion.receiptForInstall(kind: kind, zipURL: zip, remoteInfo: remoteInfo)
        try? UpstreamVersion.writeReceipt(receipt, to: source)

        if kind == .s2arm {
            S2ArmBootstrap.ensureGitRepo(in: source.path)
        } else if kind == .kidWithSword {
            _ = KidWithSwordCompat.ensureMacPackCompatibility(in: source.path)
        }

        if shouldCancel?() == true {
            throw Failure.cancelled
        }

        try replace(dest: dest, with: source, kind: kind)
        return dest
    }

    /// `ditto -x -k`: the ZIP unpacked into an existing folder. Ends early when `shouldCancel` says so.
    static func unpack(zip: URL, into tmp: URL, shouldCancel: (@Sendable () -> Bool)?) throws {
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, tmp.path]
        ditto.standardOutput = FileHandle.nullDevice
        ditto.standardError = FileHandle.nullDevice
        do {
            try ditto.run()
        } catch {
            throw Failure.unpack
        }
        if let shouldCancel {
            while ditto.isRunning {
                if shouldCancel() {
                    ditto.terminate()
                    ditto.waitUntilExit()
                    throw Failure.cancelled
                }
                Thread.sleep(forTimeInterval: 0.025)
            }
        }
        ditto.waitUntilExit()
        if shouldCancel?() == true {
            throw Failure.cancelled
        }
        guard ditto.terminationStatus == 0 else {
            throw Failure.unpack
        }
    }

    /// `source` takes the place of `dest`. The old folder is kept until the new one is in, and put back when the move fails or the new tree is not usable.
    func replace(dest: URL, with source: URL, kind: EngineUpstreamKind) throws {
        let fm = FileManager.default
        try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let backup = root.appendingPathComponent(".old-" + kind.rawValue + "-" + UUID().uuidString, isDirectory: true)
        let hadExisting = fm.fileExists(atPath: dest.path)
        if hadExisting {
            try? fm.removeItem(at: backup)
            try? fm.moveItem(at: dest, to: backup)
        }
        do {
            if fm.fileExists(atPath: dest.path) {
                try? fm.removeItem(at: dest)
            }
            try fm.moveItem(at: source, to: dest)
        } catch {
            try? fm.removeItem(at: dest)
            if hadExisting && fm.fileExists(atPath: backup.path) {
                try? fm.moveItem(at: backup, to: dest)
            }
            throw Failure.unpack
        }
        guard Self.isUsableTree(dest.path, kind: kind, fileManager: fm) else {
            try? fm.removeItem(at: dest)
            if hadExisting && fm.fileExists(atPath: backup.path) {
                try? fm.moveItem(at: backup, to: dest)
            }
            throw Failure.incomplete
        }
        if fm.fileExists(atPath: backup.path) {
            try? fm.removeItem(at: backup)
        }
    }

    package func downloadAndInstall(
        kind: EngineUpstreamKind,
        transport: EngineTransport,
        remoteInfo: UpstreamRemoteInfo? = nil,
        shouldCancel: (@Sendable () -> Bool)? = nil,
        onProgress: (@Sendable (Int64, Int64?) -> Void)? = nil,
        onExtracting: (@Sendable () -> Void)? = nil
    ) -> Result<URL, Failure> {
        guard let url = Self.archiveURL(for: kind) else {
            return .failure(.unsupportedKind)
        }
        if shouldCancel?() == true {
            return .failure(.cancelled)
        }
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        let zipFile = root.appendingPathComponent(".download-" + UUID().uuidString + ".zip")
        defer { try? fm.removeItem(at: zipFile) }

        let ok = transport.download(from: url, to: zipFile, progress: onProgress, shouldCancel: shouldCancel)
        if shouldCancel?() == true {
            return .failure(.cancelled)
        }
        guard ok else {
            return .failure(.download)
        }
        let resolvedRemote: UpstreamRemoteInfo?
        if let remoteInfo {
            resolvedRemote = remoteInfo
        } else if shouldCancel?() != true {
            resolvedRemote = UpstreamVersion.fetchRemoteInfo(
                for: kind,
                transport: transport,
                timeout: UpstreamVersion.quickFetchTimeout
            )
        } else {
            resolvedRemote = nil
        }
        if shouldCancel?() == true {
            return .failure(.cancelled)
        }
        onExtracting?()
        do {
            return .success(try install(zip: zipFile, kind: kind, remoteInfo: resolvedRemote, shouldCancel: shouldCancel))
        } catch let err as Failure {
            return .failure(err)
        } catch {
            return .failure(.unpack)
        }
    }
}
