import CryptoKit
import Foundation

/// What a release says about the engine it carries (and about the app itself), and how the launcher
/// decides whether to install it.
///
/// The player no longer fetches the repository: the release ships an engine tree — the repository minus
/// the launcher sources (`dm/`, `scripts/`, `docs/`, `ref/`, `.upstream-ref`, `dm/fork_patches.txt`) —
/// and the launcher unpacks it next to its own Application Support folder. That folder then *is* the
/// checkout the build reads (`BuildModel.repoPath`), so `isRepo`, the build script and the RomFS tool
/// keep working unchanged.
///
/// Two channels, one manifest: `stable` is the engine that shipped with this release; `rolling` is the
/// newest one the nightly sync built, opt-in and labelled experimental in Settings.
enum EngineManifest {
    /// One downloadable file: the release asset's name and the SHA-256 we verify before using it.
    struct Asset: Decodable, Equatable {
        let asset: String
        let sha256: String
        let size: Int?
    }

    /// The manifest's shape (`latest.json`). Unknown keys are ignored so an older launcher can read a
    /// newer manifest as long as what it needs is still there.
    struct Manifest: Decodable, Equatable {
        /// The release version this manifest describes, e.g. "0.8.0".
        let version: String
        /// The seedds/nxnative commit the engine tree was built from (what `.upstream-ref` holds).
        let pin: String
        let engine: Asset
        /// The app itself, so one manifest drives both updates.
        let app: Asset?
        /// Where the files live, in the order they are tried. Empty: the release page on GitHub.
        var sources: [String] = []
        /// When the nightly sync built this engine, for the rolling channel ("2026-10-31T02:00:00Z").
        var built: String?
        var channel: String?

        // Written out because a default value does not make a key optional to the synthesized decoder:
        // a manifest without `sources` is valid and means "the release page".
        private enum CodingKeys: String, CodingKey { case version, pin, engine, app, sources, built, channel }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decode(String.self, forKey: .version)
            pin = try c.decode(String.self, forKey: .pin)
            engine = try c.decode(Asset.self, forKey: .engine)
            app = try c.decodeIfPresent(Asset.self, forKey: .app)
            sources = try c.decodeIfPresent([String].self, forKey: .sources) ?? []
            built = try c.decodeIfPresent(String.self, forKey: .built)
            channel = try c.decodeIfPresent(String.self, forKey: .channel)
        }

        init(version: String, pin: String, engine: Asset, app: Asset?, sources: [String] = [], built: String? = nil, channel: String? = nil) {
            self.version = version; self.pin = pin; self.engine = engine; self.app = app
            self.sources = sources; self.built = built; self.channel = channel
        }
    }

    enum Problem: Error, Equatable {
        case notJSON
        case missingVersion
        case missingPin
        case badDigest(String)          // not 64 lowercase hex characters
        case noSources
    }

    /// Decode and validate. A manifest the launcher cannot act on fails here rather than half-way
    /// through a download.
    static func decode(_ data: Data) throws -> Manifest {
        let m: Manifest
        do { m = try JSONDecoder().decode(Manifest.self, from: data) }
        catch { throw Problem.notJSON }
        guard !m.version.trimmingCharacters(in: .whitespaces).isEmpty else { throw Problem.missingVersion }
        guard m.pin.count >= 7 else { throw Problem.missingPin }
        for a in [m.engine, m.app].compactMap({ $0 }) where !isDigest(a.sha256) { throw Problem.badDigest(a.sha256) }
        return m
    }

    static func isDigest(_ s: String) -> Bool {
        s.count == 64 && s.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    // ---- Authenticity ----

    /// What we can say about a manifest's signature. Integrity (a SHA-256 that matches) only proves the
    /// download is what the manifest lists — it says nothing when whoever served the manifest also served
    /// the file. With a mirror in the picture that matters, so a release may carry a detached Ed25519
    /// signature and the app refuses an update it cannot authenticate once a key is built in.
    enum Signature: Equatable {
        case valid
        case invalid
        case absent
        /// No public key in this build yet: the check cannot run. The caller decides what that means —
        /// today it accepts the manifest, as it does without signatures at all.
        case noKey
    }

    /// `publicKey` is the base64 of the 32-byte Ed25519 key, compiled in; empty means "not configured".
    /// `signature` is the base64 of the 64-byte detached signature over the manifest's exact bytes.
    static func verify(manifest: Data, signature: String?, publicKey: String) -> Signature {
        guard !publicKey.isEmpty else { return .noKey }
        guard let signature, let sig = Data(base64Encoded: signature),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: publicKey) ?? Data()) else {
            return .absent
        }
        return key.isValidSignature(sig, for: manifest) ? .valid : .invalid
    }

    /// Whether this result allows an install. Once a key is configured, only a valid signature installs —
    /// by hand or automatically; while no key exists the check cannot run and the launcher behaves as it
    /// did before signatures (`.noKey`), which is what a build from the repository sees.
    static func allowsInstall(_ signature: Signature) -> Bool {
        switch signature {
        case .valid, .noKey: return true
        case .absent, .invalid: return false
        }
    }
}

/// Where engine trees live on disk: one folder per pin, beside the app's other state, so an app update
/// and an engine update cannot half-replace each other, and going back is just selecting the older pin.
struct EngineStore {
    let root: URL

    init(root: URL = EngineStore.defaultRoot) { self.root = root }

    /// `~/Library/Application Support/NX2Apple/engine/<pin>/`. The folder is a full checkout for the
    /// build (`dm/`, `scripts/`, ...), so `repoPath` can point at it.
    static var defaultRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("NX2Apple/engine", isDirectory: true)
    }

    func directory(for pin: String) -> URL { root.appendingPathComponent(pin, isDirectory: true) }

    /// A tree is usable when it holds what the launcher runs by path (`BuildModel.requiredTools`).
    /// Unpacking into a temporary folder and renaming makes a half-written tree unreadable rather than
    /// silently incomplete, and this is the check that backs it up.
    func isUsable(_ pin: String) -> Bool {
        let dir = directory(for: pin)
        for f in ["scripts/build_ipa_from_nsp.py", "dm/tools/romfs_image.py", ".upstream-ref"] {
            guard FileManager.default.fileExists(atPath: dir.appendingPathComponent(f).path) else { return false }
        }
        return true
    }

    /// Remove every other pin's tree. Called after a successful switch, so a player keeps the one they
    /// are on; `keeping` also holds the previous one while a build might still need it.
    @discardableResult
    func prune(keeping pins: Set<String>) -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var removed: [String] = []
        for url in entries where (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            guard !pins.contains(url.lastPathComponent) else { continue }
            if (try? fm.removeItem(at: url)) != nil { removed.append(url.lastPathComponent) }
        }
        return removed.sorted()
    }
}
