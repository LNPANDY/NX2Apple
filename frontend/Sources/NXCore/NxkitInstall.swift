import Foundation

/// The install of nxkit from its GitHub release (LNPANDY/NX2Apple#1460): the latest release's macOS ZIP, checked against the release's
/// `SHA256SUMS`, unpacked into `upstreams/nxkit/` with `nxb` and, when the release has it, `nxkit-host`.
extension UpstreamEngineStore {
    package func latestNxkitRelease(transport: EngineTransport) -> NxkitBuilder.Release? {
        guard case .ok(let data) = transport.data(from: NxkitBuilder.latestReleaseURL) else { return nil }
        return NxkitBuilder.parseRelease(data)
    }

    /// Unpacks `zip` (named `zipName` in the release's `sums`) and puts the binaries in place.
    /// A ZIP the checksums do not list, or whose hash differs, installs nothing. A ZIP without `nxkit-host` installs, and the
    /// install file says so: the launcher then shows that this release cannot build apps yet.
    @discardableResult
    package func installNxkit(
        zip: URL,
        zipName: String,
        tag: String,
        sums: [String: String],
        shouldCancel: (@Sendable () -> Bool)? = nil
    ) throws -> URL {
        let kind = EngineUpstreamKind.nxkit
        guard let dest = directory(for: kind) else { throw Failure.unsupportedKind }
        if shouldCancel?() == true { throw Failure.cancelled }
        guard NxkitBuilder.verify(file: zip, listedAs: zipName, in: sums) == .ok else { throw Failure.checksum }

        let fm = FileManager.default
        let tmp = root.appendingPathComponent(".tmp-" + UUID().uuidString, isDirectory: true)
        do { try fm.createDirectory(at: tmp, withIntermediateDirectories: true) } catch { throw Failure.unpack }
        defer { try? fm.removeItem(at: tmp) }
        try Self.unpack(zip: zip, into: tmp, shouldCancel: shouldCancel)

        guard let source = Self.folderHoldingBuilder(in: tmp, fileManager: fm) else { throw Failure.incomplete }
        // A file the checksums list by its path in the ZIP is checked as well.
        let prefix = source.path == tmp.path ? "" : source.lastPathComponent + "/"
        for name in [NxkitBuilder.builderName, NxkitBuilder.hostName] {
            let file = source.appendingPathComponent(name)
            guard fm.fileExists(atPath: file.path), sums[prefix + name] != nil else { continue }
            if NxkitBuilder.verify(file: file, listedAs: prefix + name, in: sums) != .ok { throw Failure.checksum }
        }

        for name in [NxkitBuilder.builderName, NxkitBuilder.hostName] {
            let file = source.appendingPathComponent(name).path
            if fm.fileExists(atPath: file) { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file) }
        }
        Self.clearQuarantine(source)
        let hasHost = fm.isExecutableFile(atPath: source.appendingPathComponent(NxkitBuilder.hostName).path)
        NxkitBuilder.writeInfo(NxkitBuilder.InstallInfo(tag: tag, hasHost: hasHost), in: source)
        if shouldCancel?() == true { throw Failure.cancelled }

        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        try replace(dest: dest, with: source, kind: kind)
        guard NxkitBuilder.isUsableTree(dest.path) else {
            try? fm.removeItem(at: dest)
            throw Failure.incomplete
        }
        return dest
    }

    package func downloadAndInstallNxkit(
        release: NxkitBuilder.Release,
        transport: EngineTransport,
        shouldCancel: (@Sendable () -> Bool)? = nil,
        onProgress: (@Sendable (Int64, Int64?) -> Void)? = nil,
        onExtracting: (@Sendable () -> Void)? = nil
    ) -> Result<URL, Failure> {
        if shouldCancel?() == true { return .failure(.cancelled) }
        guard let sumsURL = release.sumsURL,
              case .ok(let sumsData) = transport.data(from: sumsURL),
              let sumsText = String(data: sumsData, encoding: .utf8) else {
            return .failure(.checksum)   // no checksums, no install
        }
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        let zipFile = root.appendingPathComponent(".download-" + UUID().uuidString + ".zip")
        defer { try? fm.removeItem(at: zipFile) }
        let ok = transport.download(from: release.zipURL, to: zipFile, progress: onProgress, shouldCancel: shouldCancel)
        if shouldCancel?() == true { return .failure(.cancelled) }
        guard ok else { return .failure(.download) }
        onExtracting?()
        do {
            return .success(try installNxkit(zip: zipFile, zipName: release.zipName, tag: release.tag,
                                             sums: NxkitBuilder.parseChecksums(sumsText), shouldCancel: shouldCancel))
        } catch let err as Failure {
            return .failure(err)
        } catch {
            return .failure(.unpack)
        }
    }

    /// The folder (the unpacked root or one level below) that holds the `nxb` file.
    private static func folderHoldingBuilder(in root: URL, fileManager fm: FileManager) -> URL? {
        var folders = [root]
        for _ in 0..<2 {
            for folder in folders where fm.fileExists(atPath: folder.appendingPathComponent(NxkitBuilder.builderName).path) {
                return folder
            }
            folders = folders.flatMap { folder in
                ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []).filter {
                    $0.lastPathComponent != "__MACOSX" && !$0.lastPathComponent.hasPrefix(".")
                        && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                }
            }
        }
        return folders.first { fm.fileExists(atPath: $0.appendingPathComponent(NxkitBuilder.builderName).path) }
    }

    /// The downloaded binaries must run without Gatekeeper's first-start check, as the other builders' files do.
    private static func clearQuarantine(_ folder: URL) {
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-dr", "com.apple.quarantine", folder.path]
        xattr.standardOutput = FileHandle.nullDevice
        xattr.standardError = FileHandle.nullDevice
        guard (try? xattr.run()) != nil else { return }
        xattr.waitUntilExit()
    }
}
