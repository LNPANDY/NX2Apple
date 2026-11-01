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
/// Two channels, one manifest shape: `stable` is the engine that shipped with this release, `experimental` is the
/// newest one the nightly sync built from main, opt-in in Settings (EngineChannel).
package enum EngineManifest {
    /// One downloadable file: the release asset's name and the SHA-256 we verify before using it.
    package struct Asset: Decodable, Equatable {
        package init(asset: String, sha256: String, size: Int?) { self.asset = asset; self.sha256 = sha256; self.size = size }
        package let asset: String
        package let sha256: String
        package let size: Int?
    }

    /// The manifest's shape (`latest.json`, written by `tools/release_manifest.py`). Unknown keys are ignored so
    /// an older launcher can read a newer manifest as long as what it needs is still there.
    package struct Manifest: Decodable, Equatable {
        /// The release version this manifest describes, e.g. "0.8.0" (or "0.8.0-experimental").
        package let version: String
        /// The seedds/nxnative commit the engine tree was built from (what `.upstream-ref` holds). Information only:
        /// the patch series changes without the pin moving, so the pin does not name a tree.
        package let pin: String
        /// `<pin>-<12 hex of the patch series digest>`: the tree's identity, and its folder name in the store.
        package let engineID: String
        package let engine: Asset
        /// The app itself, so one manifest drives both updates.
        package let app: Asset?
        /// Where the files live, in the order they are tried. Empty: the release page on GitHub.
        package var sources: [String] = []
        /// When the engine was built ("2026-10-31T02:00:00Z").
        package var built: String?
        /// "stable" or "experimental".
        package var channel: String?

        // Written out because a default value does not make a key optional to the synthesized decoder:
        // a manifest without `sources` is valid and means "the release page".
        private enum CodingKeys: String, CodingKey {
            case version, pin, engine, app, sources, built, channel
            case engineID = "engine_id"
        }

        package init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decode(String.self, forKey: .version)
            pin = try c.decode(String.self, forKey: .pin)
            engineID = try c.decodeIfPresent(String.self, forKey: .engineID) ?? ""
            engine = try c.decode(Asset.self, forKey: .engine)
            app = try c.decodeIfPresent(Asset.self, forKey: .app)
            sources = try c.decodeIfPresent([String].self, forKey: .sources) ?? []
            built = try c.decodeIfPresent(String.self, forKey: .built)
            channel = try c.decodeIfPresent(String.self, forKey: .channel)
        }

        package init(version: String, pin: String, engineID: String, engine: Asset, app: Asset?, sources: [String] = [],
             built: String? = nil, channel: String? = nil) {
            self.version = version; self.pin = pin; self.engineID = engineID; self.engine = engine; self.app = app
            self.sources = sources; self.built = built; self.channel = channel
        }
    }

    package enum Problem: Error, Equatable {
        case notJSON
        case missingVersion
        case missingPin                 // not 7 to 64 lowercase hex characters
        case badEngineID(String)        // not `<pin>-<12 lowercase hex>`
        case badDigest(String)          // not 64 lowercase hex characters
        case badAsset(String)           // not a plain file name
        case badSource(String)          // not an https URL
    }

    /// Decode and validate. A manifest the launcher cannot act on fails here rather than half-way
    /// through a download. Every value that later becomes part of a path or a URL is checked here, because
    /// an unsigned manifest is accepted while no key is built in.
    package static func decode(_ data: Data) throws -> Manifest {
        let m: Manifest
        do { m = try JSONDecoder().decode(Manifest.self, from: data) }
        catch { throw Problem.notJSON }
        guard !m.version.trimmingCharacters(in: .whitespaces).isEmpty else { throw Problem.missingVersion }
        guard isPin(m.pin) else { throw Problem.missingPin }
        guard EngineStore.isEngineID(m.engineID), m.engineID.hasPrefix(m.pin + "-") else { throw Problem.badEngineID(m.engineID) }
        for a in [m.engine, m.app].compactMap({ $0 }) {
            guard isDigest(a.sha256) else { throw Problem.badDigest(a.sha256) }
            guard isAssetName(a.asset) else { throw Problem.badAsset(a.asset) }
        }
        for s in m.sources {
            guard let u = URL(string: s), u.scheme == "https", u.host?.isEmpty == false else { throw Problem.badSource(s) }
        }
        return m
    }

    package static func isDigest(_ s: String) -> Bool {
        s.count == 64 && s.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    package static func isPin(_ s: String) -> Bool {
        (7...64).contains(s.count) && s.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// A release asset's name: it is appended to a source URL and names a downloaded file, so no folders and no dots
    /// at the start.
    package static func isAssetName(_ s: String) -> Bool {
        guard (1...128).contains(s.count), !s.hasPrefix(".") else { return false }
        return s.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || "._-".unicodeScalars.contains($0) }
    }

    // ---- Authenticity ----

    /// The public half of the key that signs `latest.json`: base64 of the 32 raw Ed25519 bytes, the same line as
    /// `frontend/engine-signing.pub` (the private half is the repository secret ENGINE_SIGNING_KEY). Once it is set,
    /// only a manifest with a valid signature installs; the release workflow fails a tag build whose constant is empty
    /// (the launcher would otherwise accept every manifest unsigned, silently).
    package static let publicKey = "PVCqIahW5HtyZPq76zTSFBa+lK2bB2dKWScyb/4R3tY="

    /// What we can say about a manifest's signature. Integrity (a SHA-256 that matches) only proves the
    /// download is what the manifest lists — it says nothing when whoever served the manifest also served
    /// the file. With a mirror in the picture that matters, so a release may carry a detached Ed25519
    /// signature and the app refuses an update it cannot authenticate once a key is built in.
    package enum Signature: Equatable {
        case valid
        case invalid
        case absent
        /// No public key in this build yet: the check cannot run. The caller decides what that means —
        /// today it accepts the manifest, as it does without signatures at all.
        case noKey
    }

    /// `publicKey` is the base64 of the 32-byte Ed25519 key, compiled in; empty means "not configured".
    /// `signature` is the base64 of the 64-byte detached signature over the manifest's exact bytes.
    package static func verify(manifest: Data, signature: String?, publicKey: String) -> Signature {
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
    package static func allowsInstall(_ signature: Signature) -> Bool {
        switch signature {
        case .valid, .noKey: return true
        case .absent, .invalid: return false
        }
    }
}

/// Where engine trees live on disk: one folder per engine id, beside the app's other state, so an app update
/// and an engine update cannot half-replace each other, and going back is just selecting the older tree.
package struct EngineStore {
    package let root: URL

    package init(root: URL = EngineStore.defaultRoot) { self.root = root }

    /// `~/Library/Application Support/NX2Apple/engine/<engine_id>/`. The folder is a full checkout for the
    /// build (`dm/`, `scripts/`, ...), so `repoPath` can point at it.
    package static var defaultRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("NX2Apple/engine", isDirectory: true)
    }

    /// The file in a tree that names it (`tools/engine.py tree` writes it, with a newline).
    package static let idFile = ".engine-id"
    /// What the launcher runs by path, and the pin. A tree without one of them is not used.
    package static let requiredFiles = ["scripts/build_ipa_from_nsp.py", "dm/tools/romfs_image.py", ".upstream-ref", idFile]

    /// `<pin>-<12 hex>`: lowercase hex and dashes only, so an id can never leave the store as a path
    /// (no `/`, no `..`, no dot at the start).
    package static func isEngineID(_ s: String) -> Bool {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, EngineManifest.isPin(String(parts[0])), parts[1].count == 12 else { return false }
        return parts[1].allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// The tree's folder, or nil for anything that is not an engine id.
    package func directory(for id: String) -> URL? {
        Self.isEngineID(id) ? root.appendingPathComponent(id, isDirectory: true) : nil
    }

    /// The id a tree names itself with (its `.engine-id`), nil when it has none.
    package static func identity(of tree: URL) -> String? {
        guard let text = try? String(contentsOf: tree.appendingPathComponent(idFile), encoding: .utf8) else { return nil }
        let id = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return isEngineID(id) ? id : nil
    }

    /// Whether `tree` holds everything the launcher runs by path and calls itself `id`.
    package static func isComplete(_ tree: URL, id: String) -> Bool {
        requiredFiles.allSatisfy { FileManager.default.fileExists(atPath: tree.appendingPathComponent($0).path) }
            && identity(of: tree) == id
    }

    /// A tree is usable when it is complete and is the engine its folder is named after. Unpacking into a
    /// temporary folder and renaming makes a half-written tree unreadable rather than silently incomplete,
    /// and this is the check that backs it up.
    package func isUsable(_ id: String) -> Bool {
        guard let dir = directory(for: id) else { return false }
        return Self.isComplete(dir, id: id)
    }

    /// Remove the trees not in `ids`, and what an interrupted install left behind. Only direct children this store
    /// creates are touched: folders named like an engine id, and the `.tmp-` and `.download-` entries. Anything else
    /// in the folder stays.
    @discardableResult
    package func prune(keeping ids: Set<String>) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        var removed: [String] = []
        for name in names {
            let ours = Self.isEngineID(name) || name.hasPrefix(".tmp-") || name.hasPrefix(".download-")
            guard ours, !ids.contains(name) else { continue }
            if (try? fm.removeItem(at: root.appendingPathComponent(name))) != nil { removed.append(name) }
        }
        return removed.sorted()
    }
}
