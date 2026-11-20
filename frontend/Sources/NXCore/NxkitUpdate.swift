import CryptoKit
import Darwin
import Foundation

/// nxkit updates itself without a new launcher release (LNPANDY/NX2Apple#1460). The bundled pair (`Contents/Resources/nxbuild/`) is the baseline and the
/// fallback. A newer release is installed only when its `SHA256SUMS.sig` verifies with `publicKey` (Ed25519 over the exact bytes of `SHA256SUMS`), then the
/// ZIP and both programs match `SHA256SUMS` (and MANIFEST.json), and its MANIFEST.json is a format this launcher reads, for arm64 and this macOS. Nothing
/// unverified ever runs. Versions live in `~/Library/Application Support/NX2Apple/nxkit/<version>/`, `state.json` names the one in use and the one
/// before it (Use previous version), and a switch is one atomic write of that file.
package enum NxkitUpdate {
    /// The Ed25519 public key of nxkit's release workflow (v0lumehi/nxkit#35, `SHA256SUMS.sig`), base64 of its 32 raw bytes.
    /// TODO: it comes from the signing key of v0lumehi/nxkit's release workflow (.github/workflows/release.yml, #35). Replace it here when that key changes.
    package static let publicKey = "9FKs7HGStVtytRbhJN38vwPyBmXjWs70Mn1hqKrug7M="

    package static let latestReleaseURL = URL(string: "https://api.github.com/repos/v0lumehi/nxkit/releases/latest")!
    package static let signatureName = "SHA256SUMS.sig"

    /// What the latest release offers: its tag, the macOS ZIP, the checksum file and its signature.
    package struct Release: Equatable, Sendable {
        package let tag: String
        package let zipName: String
        package let zipURL: URL
        package let sumsURL: URL?
        package let signatureURL: URL?

        package var version: String { NxkitBuilder.normalizedVersion(tag) }
    }

    /// The answer of `repos/v0lumehi/nxkit/releases/latest`. nil when it names no macOS ZIP.
    package static func parseRelease(_ data: Data) -> Release? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tag = root["tag_name"] as? String, !tag.isEmpty,
              let assets = root["assets"] as? [[String: Any]] else { return nil }
        func url(_ asset: [String: Any]) -> URL? { (asset["browser_download_url"] as? String).flatMap(URL.init(string:)) }
        let zips = assets.filter {
            let name = ($0["name"] as? String)?.lowercased() ?? ""
            return name.hasSuffix(".zip") && name.contains("macos")
        }
        let zip = zips.first { ($0["name"] as? String)?.lowercased().contains("arm64") == true } ?? zips.first
        guard let zip, let name = zip["name"] as? String, let zipURL = url(zip) else { return nil }
        let sums = assets.first { ($0["name"] as? String) == NxkitBuilder.sumsName }.flatMap(url)
        let sig = assets.first { ($0["name"] as? String) == signatureName }.flatMap(url)
        return Release(tag: tag, zipName: name, zipURL: zipURL, sumsURL: sums, signatureURL: sig)
    }

    // MARK: Signature

    /// The key as CryptoKit takes it. nil for a key that is not 32 bytes of base64.
    package static func key(_ base64: String) -> Curve25519.Signing.PublicKey? {
        guard let raw = Data(base64Encoded: base64.trimmingCharacters(in: .whitespacesAndNewlines)), raw.count == 32 else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
    }

    /// `SHA256SUMS.sig` (one line, base64 of the 64 signature bytes) over the exact bytes of `SHA256SUMS`.
    package static func verifySignature(sums: Data, signature: Data, publicKey: String = publicKey) -> Bool {
        guard let key = key(publicKey),
              let text = String(data: signature, encoding: .utf8),
              let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)), raw.count == 64 else { return false }
        return key.isValidSignature(raw, for: sums)
    }

    // MARK: Why a release is not taken

    package enum Rejection: Error, Equatable, Sendable {
        case unsigned          // the release has no SHA256SUMS.sig (0.10.2 and older)
        case badSignature      // it has one, and it does not verify
        case checksum          // the ZIP or a program does not match SHA256SUMS or MANIFEST.json
        case incompatible(NxkitBuilder.Incompatibility)
        case incomplete        // no nxb, no nxkit-host or no MANIFEST.json in the ZIP
        case download
        case unpack
        case cancelled
    }

    /// The release's files, checked in this order: the signature over SHA256SUMS, then the ZIP against SHA256SUMS. Returns the checksums.
    package static func verifiedSums(sums: Data, signature: Data?, publicKey: String = publicKey) throws -> [String: String] {
        guard let signature else { throw Rejection.unsigned }
        guard verifySignature(sums: sums, signature: signature, publicKey: publicKey) else { throw Rejection.badSignature }
        return NxkitBuilder.parseChecksums(String(decoding: sums, as: UTF8.self))
    }
}

/// The installed versions under `~/Library/Application Support/NX2Apple/nxkit/` and which one is in use.
package struct NxkitVersionStore: Sendable {
    package let root: URL

    package init(root: URL = NxkitVersionStore.defaultRoot) { self.root = root }

    package static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/NX2Apple/nxkit", isDirectory: true)
    }

    /// `state.json`: the version in use and the one before it.
    package struct State: Codable, Equatable, Sendable {
        package var current: String?
        package var previous: String?
        package init(current: String? = nil, previous: String? = nil) { self.current = current; self.previous = previous }
    }

    /// The pair the build runs: its folder, version, the nxkit-host build its MANIFEST.json names, and where it came from.
    package struct Selection: Equatable, Sendable {
        package enum Source: String, Equatable, Sendable { case bundled, installed }
        package let folder: String
        package let version: String
        package let hostBuild: String
        package let source: Source
        package init(folder: String, version: String, hostBuild: String, source: Source) {
            self.folder = folder; self.version = version; self.hostBuild = hostBuild; self.source = source
        }
    }

    static let stateName = "state.json"
    static let verifiedName = ".verified"

    package func folder(for version: String) -> URL { root.appendingPathComponent(version, isDirectory: true) }

    package func readState() -> State {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(Self.stateName)),
              let state = try? JSONDecoder().decode(State.self, from: data) else { return State() }
        return state
    }

    /// One atomic write: the launcher never sees half a state.
    package func writeState(_ state: State) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: root.appendingPathComponent(Self.stateName), options: .atomic)
    }

    /// A version that was verified when it was installed and is whole: both programs, MANIFEST.json, the marker the install leaves last.
    package func isVerified(_ version: String) -> Bool {
        let dir = folder(for: version).path
        return NxkitBuilder.canBuildApps(dir)
            && FileManager.default.fileExists(atPath: dir + "/" + NxkitBuilder.manifestName)
            && FileManager.default.fileExists(atPath: dir + "/" + Self.verifiedName)
    }

    /// The pair to build with: the version `state.json` names when it is verified and not older than the bundled one, else the bundled pair.
    package func resolve(bundled: String?) -> Selection? {
        let bundledSelection: Selection? = bundled.flatMap { folder in
            guard NxkitBuilder.canBuildApps(folder) else { return nil }
            let m = NxkitBuilder.readManifest(in: folder)
            return Selection(folder: folder, version: m?.version ?? "", hostBuild: m?.hostBuild ?? "", source: .bundled)
        }
        if let current = readState().current, isVerified(current) {
            let dir = folder(for: current).path
            let m = NxkitBuilder.readManifest(in: dir)
            let installed = Selection(folder: dir, version: m?.version ?? current, hostBuild: m?.hostBuild ?? "", source: .installed)
            guard let b = bundledSelection else { return installed }
            return NxkitBuilder.isNewer(b.version, than: installed.version) ? b : installed
        }
        return bundledSelection
    }

    /// The version before the one in use, when it is still there.
    package var previousVersion: String? {
        readState().previous.flatMap { isVerified($0) ? $0 : nil }
    }

    /// `version` becomes the one in use, the one in use the previous one. Other versions are removed.
    package func switchTo(_ version: String) throws {
        var state = readState()
        guard state.current != version else { return }
        state.previous = state.current
        state.current = version
        try writeState(state)
        prune(keeping: [state.current, state.previous].compactMap { $0 })
    }

    /// Use previous version: the one before takes the place of the one in use, and the other way round.
    package func rollback() throws {
        var state = readState()
        guard let previous = state.previous, isVerified(previous) else { return }
        state.previous = state.current
        state.current = previous
        try writeState(state)
    }

    func prune(keeping: [String]) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where !keeping.contains(name) && name != Self.stateName {
            var dir: ObjCBool = false
            if fm.fileExists(atPath: root.appendingPathComponent(name).path, isDirectory: &dir), dir.boolValue {
                try? fm.removeItem(at: root.appendingPathComponent(name))
            }
        }
    }

    // MARK: Install

    /// Unpacks a downloaded release ZIP whose signed checksums are `sums` and puts nxb, nxkit-host and MANIFEST.json into `<root>/<version>/`.
    /// Checks the ZIP and each program against `sums` and MANIFEST.json, and the manifest against this Mac. `prepare` clears the quarantine and
    /// signs the programs ad hoc (tests pass their own). Does not switch: the caller does, when no nxkit build runs.
    @discardableResult
    package func install(
        zip: URL,
        zipName: String,
        sums: [String: String],
        running: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        prepare: @Sendable (URL) -> Bool = NxkitVersionStore.prepare,
        shouldCancel: (@Sendable () -> Bool)? = nil
    ) throws -> String {
        guard let want = sums[zipName], NxkitBuilder.sha256(of: zip) == want else { throw NxkitUpdate.Rejection.checksum }
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        let tmp = root.appendingPathComponent(".tmp-" + UUID().uuidString, isDirectory: true)
        do { try fm.createDirectory(at: tmp, withIntermediateDirectories: true) } catch { throw NxkitUpdate.Rejection.unpack }
        defer { try? fm.removeItem(at: tmp) }
        do { try UpstreamEngineStore.unpack(zip: zip, into: tmp, shouldCancel: shouldCancel) } catch UpstreamEngineStore.Failure.cancelled {
            throw NxkitUpdate.Rejection.cancelled
        } catch { throw NxkitUpdate.Rejection.unpack }

        guard let source = Self.releaseFolder(in: tmp, fileManager: fm),
              let manifest = NxkitBuilder.readManifest(in: source.path) else { throw NxkitUpdate.Rejection.incomplete }
        if let why = NxkitBuilder.incompatibility(manifest, running: running) { throw NxkitUpdate.Rejection.incompatible(why) }
        let prefix = source.path == tmp.path ? "" : source.lastPathComponent + "/"
        let staged = root.appendingPathComponent(".stage-" + UUID().uuidString, isDirectory: true)
        try? fm.createDirectory(at: staged, withIntermediateDirectories: true)
        var keepStaged = false
        defer { if !keepStaged { try? fm.removeItem(at: staged) } }
        for name in [NxkitBuilder.builderName, NxkitBuilder.hostName] {
            let file = source.appendingPathComponent(name)
            guard fm.fileExists(atPath: file.path) else { throw NxkitUpdate.Rejection.incomplete }
            let have = NxkitBuilder.sha256(of: file)
            guard have != nil, have == (sums[prefix + name] ?? sums[name]), have == manifest.files[name] else { throw NxkitUpdate.Rejection.checksum }
            do { try fm.copyItem(at: file, to: staged.appendingPathComponent(name)) } catch { throw NxkitUpdate.Rejection.unpack }
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.appendingPathComponent(name).path)
        }
        do { try fm.copyItem(at: source.appendingPathComponent(NxkitBuilder.manifestName), to: staged.appendingPathComponent(NxkitBuilder.manifestName)) }
        catch { throw NxkitUpdate.Rejection.unpack }
        for name in [NxkitBuilder.builderName, NxkitBuilder.hostName] {
            guard prepare(staged.appendingPathComponent(name)) else { throw NxkitUpdate.Rejection.unpack }
        }
        if shouldCancel?() == true { throw NxkitUpdate.Rejection.cancelled }
        // the marker last: a folder without it is never used
        fm.createFile(atPath: staged.appendingPathComponent(Self.verifiedName).path, contents: Data(manifest.version.utf8))
        let dest = folder(for: manifest.version)
        if fm.fileExists(atPath: dest.path) {
            guard readState().current != manifest.version else { return manifest.version }   // the one in use stays as it is
            try? fm.removeItem(at: dest)
        }
        do { try fm.moveItem(at: staged, to: dest) } catch { throw NxkitUpdate.Rejection.unpack }
        keepStaged = true
        return manifest.version
    }

    /// The folder (the unpacked root or one level below) that holds nxb.
    static func releaseFolder(in root: URL, fileManager fm: FileManager) -> URL? {
        if fm.fileExists(atPath: root.appendingPathComponent(NxkitBuilder.builderName).path) { return root }
        let subs = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []).filter {
            $0.lastPathComponent != "__MACOSX" && !$0.lastPathComponent.hasPrefix(".")
        }
        return subs.first { fm.fileExists(atPath: $0.appendingPathComponent(NxkitBuilder.builderName).path) }
    }

    /// The downloaded program must run without Gatekeeper's first-start check, and with a signature as the bundled one: the quarantine is removed
    /// and the file is signed ad hoc.
    package static func prepare(_ file: URL) -> Bool {
        removexattr(file.path, "com.apple.quarantine", 0)
        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = ["--force", "--sign", "-", file.path]
        codesign.standardOutput = FileHandle.nullDevice
        codesign.standardError = FileHandle.nullDevice
        guard (try? codesign.run()) != nil else { return false }
        codesign.waitUntilExit()
        return codesign.terminationStatus == 0
    }
}

/// The check and the install, over the network (EngineTransport, so tests run without one).
package enum NxkitUpdateCheck: Equatable, Sendable {
    case upToDate
    /// A newer release that verifies: installed as `version`, waiting for its switch.
    case installed(String)
    /// A newer release that is not taken, and why.
    case rejected(String, NxkitUpdate.Rejection)
    /// No answer: offline, a rate limit, any other status. Quiet.
    case unreachable
}

extension NxkitVersionStore {
    /// Asks for the latest release and installs it when it is newer than `inUse` and verifies. Never switches.
    package func checkAndInstall(
        inUse: String,
        transport: EngineTransport,
        running: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        publicKey: String = NxkitUpdate.publicKey,
        prepare: @Sendable (URL) -> Bool = NxkitVersionStore.prepare,
        shouldCancel: (@Sendable () -> Bool)? = nil
    ) -> NxkitUpdateCheck {
        guard case .ok(let data) = transport.data(from: NxkitUpdate.latestReleaseURL), let release = NxkitUpdate.parseRelease(data) else { return .unreachable }
        let version = release.version
        guard NxkitBuilder.isNewer(version, than: inUse) else { return .upToDate }
        if isVerified(version) { return .installed(version) }   // installed earlier, its switch waited for a build
        guard let sumsURL = release.sumsURL, case .ok(let sums) = transport.data(from: sumsURL) else { return .rejected(version, .unsigned) }
        var signature: Data?
        if let sigURL = release.signatureURL {
            switch transport.data(from: sigURL) {
            case .ok(let d): signature = d
            case .missing: signature = nil
            case .failed: return .unreachable
            }
        }
        let table: [String: String]
        do { table = try NxkitUpdate.verifiedSums(sums: sums, signature: signature, publicKey: publicKey) }
        catch let r as NxkitUpdate.Rejection { return .rejected(version, r) } catch { return .rejected(version, .badSignature) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let zip = root.appendingPathComponent(".download-" + UUID().uuidString + ".zip")
        defer { try? FileManager.default.removeItem(at: zip) }
        guard transport.download(from: release.zipURL, to: zip, progress: nil, shouldCancel: shouldCancel) else {
            return shouldCancel?() == true ? .rejected(version, .cancelled) : .rejected(version, .download)
        }
        do {
            return .installed(try install(zip: zip, zipName: release.zipName, sums: table, running: running, prepare: prepare, shouldCancel: shouldCancel))
        } catch let r as NxkitUpdate.Rejection {
            return .rejected(version, r)
        } catch {
            return .rejected(version, .unpack)
        }
    }
}
