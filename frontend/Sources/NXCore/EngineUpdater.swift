import Foundation

/// Which engine the launcher follows, and where its manifest lives.
///
/// - `stable` is the engine that shipped with the running app's release: the tested one, and the default.
/// - `experimental` ("实验版") is the tree built from the newest upstream pin. The release workflow publishes it
///   from main after an upstream bump passed CI, as a pre-release under a fixed tag. It is opt-in and never
///   carries the app. CI compiles it, applies the patches and runs the host tests. Nobody has played it.
package enum EngineChannel: String, CaseIterable {
    case stable, experimental

    /// The pre-release tag the experimental engine is published under. The tag is fixed, so the launcher's URL
    /// never changes. The assets inside are uploaded again with each publish.
    package static let experimentalTag = "engine-experimental"
    /// Where this repository's release assets live.
    package static let releaseBase = "https://github.com/LNPANDY/NX2Apple/releases/download/"

    /// The manifest for this channel. `version` is the running app's release version, which names the
    /// stable tag (`v0.7.2`); the experimental channel ignores it.
    package func manifestURL(version: String) -> URL? {
        switch self {
        case .stable: return URL(string: Self.releaseBase + "v" + version + "/latest.json")
        case .experimental: return URL(string: Self.releaseBase + Self.experimentalTag + "/latest.json")
        }
    }

    /// The detached signature next to the manifest (`latest.json.sig`, base64 of the Ed25519 signature).
    package func signatureURL(version: String) -> URL? {
        manifestURL(version: version).flatMap { URL(string: $0.absoluteString + ".sig") }
    }

    /// The localization key of this channel's name in Settings.
    package var labelKey: String { "engine.channel." + rawValue }

    /// The localization key of the warning shown before switching from `self` to `other`, nil when nothing changes.
    /// Each switch can bring another shader chain, and then every game compiles its shaders again on its next build.
    package func switchWarningKey(to other: EngineChannel) -> String? {
        guard other != self else { return nil }
        return other == .experimental ? "engine.switch.toExperimental" : "engine.switch.toStable"
    }

    /// Where an asset of this channel lives when the manifest names no source. A manifest that lists
    /// sources wins: that is how a mirror is introduced without a new launcher.
    package func assetURL(_ name: String, version: String, sources: [String]) -> URL? {
        assetURLs(name, version: version, sources: sources).first
    }

    /// Every place an asset is tried, in order: the manifest's sources, then this channel's release on GitHub
    /// when no source already is it.
    package func assetURLs(_ name: String, version: String, sources: [String]) -> [URL] {
        let tag = self == .stable ? "v" + version : Self.experimentalTag
        var bases = sources.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        let github = Self.releaseBase + tag + "/"
        if !bases.contains(github) { bases.append(github) }
        return bases.compactMap { URL(string: $0 + name) }
    }
}

/// Whether the experimental engine is built on newer upstream code than the stable one (LNPANDY/NX2Apple#1095). The nightly bump can
/// stop at a conflicting patch while the stable engine moves on through a manual bump, and Experimental would then be the older one.
package enum ExperimentalStanding: Equatable {
    case unknown        // a manifest is missing or has no upstream date: offered as before
    case ahead
    case notAhead       // the same engine as Stable, or one built on an older upstream commit

    /// The same engine is not ahead. Otherwise the upstream pin dates decide: an older experimental pin is not ahead, an equal date
    /// with another engine id is (the patch series differs), and a missing date on either side is unknown.
    package static func compare(experimental: EngineManifest.Manifest, stable: EngineManifest.Manifest) -> ExperimentalStanding {
        if !experimental.engineID.isEmpty, experimental.engineID == stable.engineID { return .notAhead }
        guard let e = EngineManifest.date(experimental.upstreamDate), let s = EngineManifest.date(stable.upstreamDate) else { return .unknown }
        return e < s ? .notAhead : .ahead
    }
}

/// What the engine row of Settings offers, from the channel the launcher is on and how Experimental stands.
package struct EngineChannelChoice: Equatable {
    /// The channels the picker lists. Stable alone while Experimental is not ahead of it, so the switch is not offered.
    package let options: [EngineChannel]
    /// The localization key of the secondary text that replaces the usual note, nil: the usual note.
    package let noteKey: String?
    /// A "Back to Stable" button: the launcher is on an Experimental engine that is not ahead of Stable.
    package let offersBackToStable: Bool

    package init(selected: EngineChannel, standing: ExperimentalStanding) {
        let behind = standing == .notAhead
        options = behind && selected == .stable ? [.stable] : EngineChannel.allCases
        noteKey = behind ? "engine.experimentalBehind" : nil
        offersBackToStable = behind && selected == .experimental
    }

    /// Whether a switch to `channel` may be asked for.
    package static func allowsSwitch(to channel: EngineChannel, from selected: EngineChannel, standing: ExperimentalStanding) -> Bool {
        !(channel == .experimental && selected == .stable && standing == .notAhead)
    }
}

/// The engine tree the release app carries in `Contents/Resources/engine` (the release workflow puts it there).
/// A launcher built from the repository has none, and keeps working on its checkout with git.
package enum EngineBundle {
    /// The bundled tree, when it is complete and names itself. nil: no engine in this app.
    package static func tree(in resources: URL?) -> URL? {
        guard let dir = resources?.appendingPathComponent("engine", isDirectory: true),
              let id = EngineStore.identity(of: dir), EngineStore.isComplete(dir, id: id) else { return nil }
        return dir
    }
}

/// Installing an engine tree into the store. Every tree is unpacked or copied into a hidden folder beside the others
/// and renamed into place only when it is complete, so an interrupted download never leaves a tree that looks usable.
/// A tree is never changed once it is in place: the same id is the same files.
package enum EngineInstaller {
    package enum Failure: Error, Equatable {
        case unpack                 // ditto failed: not a zip, or out of space
        case incomplete(String)     // the tree lacks what the launcher runs by path
        case wrongEngine(String)    // the tree's .engine-id is not the one the manifest names
        case badID(String)          // not an engine id
        case move                   // could not put it in place
    }

    /// Unpack `zip` into `<store>/<engineID>/`. The archive's root is the tree itself
    /// (`scripts/`, `dm/`, `.upstream-ref`, `.engine-id`, ...), as `tools/engine.py tree` builds it.
    @discardableResult
    package static func install(zip: URL, engineID: String, store: EngineStore) throws -> URL {
        guard store.directory(for: engineID) != nil else { throw Failure.badID(engineID) }
        if store.isUsable(engineID), let dest = store.directory(for: engineID) { return dest }
        let fm = FileManager.default
        let tmp = try scratch(in: store)
        defer { try? fm.removeItem(at: tmp) }

        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, tmp.path]   // the same unpacker the app's own update uses
        ditto.standardOutput = FileHandle.nullDevice
        ditto.standardError = FileHandle.nullDevice
        do { try ditto.run() } catch { throw Failure.unpack }
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw Failure.unpack }

        // A release asset may wrap the tree in one folder (`engine/...`, or `<something>/engine/...`): descend
        // while the folder has no build script and exactly one subdirectory, two levels at most.
        let marker = "scripts/build_ipa_from_nsp.py"
        var source = tmp
        for _ in 0..<2 where !fm.fileExists(atPath: source.appendingPathComponent(marker).path) {
            let kids = ((try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            guard kids.count == 1, let only = kids.first else { break }
            source = only
        }
        return try place(source, as: engineID, in: store)
    }

    /// Copy a tree that is already on disk (the one in the app bundle) into the store. The bundle is read-only and
    /// signed, so the build never runs in it.
    @discardableResult
    package static func seed(from tree: URL, engineID: String, store: EngineStore) throws -> URL {
        guard store.directory(for: engineID) != nil else { throw Failure.badID(engineID) }
        if store.isUsable(engineID), let dest = store.directory(for: engineID) { return dest }
        let fm = FileManager.default
        let tmp = try scratch(in: store)
        defer { try? fm.removeItem(at: tmp) }
        let copy = tmp.appendingPathComponent("engine", isDirectory: true)
        do { try fm.copyItem(at: tree, to: copy) } catch { throw Failure.move }
        return try place(copy, as: engineID, in: store)
    }

    private static func scratch(in store: EngineStore) throws -> URL {
        let tmp = store.root.appendingPathComponent(".tmp-" + UUID().uuidString, isDirectory: true)
        do { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) } catch { throw Failure.move }
        return tmp
    }

    /// Check `source` and rename it to `<store>/<engineID>`. A folder of that name that is not usable (left by an
    /// older launcher or damaged) is replaced.
    private static func place(_ source: URL, as engineID: String, in store: EngineStore) throws -> URL {
        let fm = FileManager.default
        guard EngineStore.requiredFiles.allSatisfy({ fm.fileExists(atPath: source.appendingPathComponent($0).path) }) else {
            throw Failure.incomplete(source.lastPathComponent)
        }
        let found = EngineStore.identity(of: source) ?? ""
        guard found == engineID else { throw Failure.wrongEngine(found) }
        guard let dest = store.directory(for: engineID) else { throw Failure.badID(engineID) }
        if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
        do { try fm.moveItem(at: source, to: dest) } catch { throw Failure.move }
        guard store.isUsable(engineID) else { throw Failure.incomplete(engineID) }
        return dest
    }
}

/// Which channel and engine the launcher is on, remembered between launches.
package struct EngineSelection: Equatable {
    package var channel: EngineChannel
    package var engineID: String       // empty: nothing installed by the launcher yet
    package var version: String        // the manifest's version of that engine, for Settings
    package var previousID: String     // the one kept for a build that was already running

    private static let channelKey = "engineChannel"
    private static let idKey = "engineID"
    private static let versionKey = "engineVersion"
    private static let previousKey = "enginePreviousID"

    package init(channel: EngineChannel, engineID: String, version: String, previousID: String) {
        self.channel = channel
        self.engineID = engineID
        self.version = version
        self.previousID = previousID
    }

    package static func load(_ defaults: UserDefaults = .standard) -> EngineSelection {
        EngineSelection(channel: EngineChannel(rawValue: defaults.string(forKey: channelKey) ?? "") ?? .stable,
                        engineID: defaults.string(forKey: idKey) ?? "",
                        version: defaults.string(forKey: versionKey) ?? "",
                        previousID: defaults.string(forKey: previousKey) ?? "")
    }

    package func save(_ defaults: UserDefaults = .standard) {
        defaults.set(channel.rawValue, forKey: Self.channelKey)
        defaults.set(engineID, forKey: Self.idKey)
        defaults.set(version, forKey: Self.versionKey)
        defaults.set(previousID, forKey: Self.previousKey)
    }

    /// Move to a newly installed engine, keeping the one we came from.
    package mutating func switched(to id: String, version: String) {
        if !engineID.isEmpty, engineID != id { previousID = engineID }
        engineID = id
        self.version = version
    }

    /// The trees the store keeps: this one and the one before it.
    package var kept: Set<String> { Set([engineID, previousID].filter { !$0.isEmpty }) }
}

// ---- Fetching ----

/// What a request for one file gave.
package enum EngineFetch<Value> {
    case ok(Value)
    case missing        // HTTP 404: the release has no such file
    case failed         // offline, a timeout, any other status
}

/// The network, as the updater sees it. Tests replace it with files in memory.
package protocol EngineTransport {
    func data(from url: URL) -> EngineFetch<Data>
    /// Download to `destination` (which does not exist yet). true when the whole file arrived.
    func download(from url: URL, to destination: URL) -> Bool
    /// Download to `destination`, reporting `(writtenBytes, expectedBytes)` as chunks arrive.
    func download(from url: URL, to destination: URL, progress: (@Sendable (Int64, Int64?) -> Void)?) -> Bool
}

extension EngineTransport {
    package func download(from url: URL, to destination: URL, progress: (@Sendable (Int64, Int64?) -> Void)?) -> Bool {
        download(from: url, to: destination)
    }
}

private final class EngineDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: (@Sendable (Int64, Int64?) -> Void)?
    private let done: @Sendable (Bool) -> Void
    private let lock = NSLock()
    private var movedOK = false
    private var finished = false

    init(
        destination: URL,
        progress: (@Sendable (Int64, Int64?) -> Void)?,
        done: @escaping @Sendable (Bool) -> Void
    ) {
        self.destination = destination
        self.progress = progress
        self.done = done
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        progress?(totalBytesWritten, expected)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let ok: Bool
        if (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 {
            ok = (try? FileManager.default.moveItem(at: location, to: destination)) != nil
        } else {
            ok = false
        }
        lock.lock()
        movedOK = ok
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        let ok = error == nil && movedOK
        lock.unlock()
        done(ok)
    }
}

/// URLSession, waited on from a background queue as the app update does (AppUpdateStore).
/// Nothing is cached: the experimental release replaces its files under the same names.
package struct URLSessionEngineTransport: EngineTransport {
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        c.timeoutIntervalForRequest = 60
        return URLSession(configuration: c)
    }()

    package init() {}

    package func data(from url: URL) -> EngineFetch<Data> {
        var result: EngineFetch<Data> = .failed
        let sem = DispatchSemaphore(value: 0)
        session.dataTask(with: url) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200, let data { result = .ok(data) } else if status == 404 { result = .missing }
            sem.signal()
        }.resume()
        sem.wait()
        return result
    }

    package func download(from url: URL, to destination: URL) -> Bool {
        download(from: url, to: destination, progress: nil)
    }

    package func download(from url: URL, to destination: URL, progress: (@Sendable (Int64, Int64?) -> Void)?) -> Bool {
        guard progress != nil else {
            var ok = false
            let sem = DispatchSemaphore(value: 0)
            session.downloadTask(with: url) { local, response, _ in
                if let local, (response as? HTTPURLResponse)?.statusCode == 200 {
                    ok = (try? FileManager.default.moveItem(at: local, to: destination)) != nil
                }
                sem.signal()
            }.resume()
            sem.wait()
            return ok
        }
        final class OutcomeBox: @unchecked Sendable {
            private let lock = NSLock()
            var ok = false
            func set(_ v: Bool) {
                lock.lock()
                ok = v
                lock.unlock()
            }
        }
        let box = OutcomeBox()
        let sem = DispatchSemaphore(value: 0)
        let delegate = EngineDownloadDelegate(destination: destination, progress: progress) { succeeded in
            box.set(succeeded)
            sem.signal()
        }
        let c = URLSessionConfiguration.ephemeral
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        c.timeoutIntervalForRequest = 60
        let streamSession = URLSession(configuration: c, delegate: delegate, delegateQueue: nil)
        defer { streamSession.finishTasksAndInvalidate() }
        streamSession.downloadTask(with: url).resume()
        sem.wait()
        return box.ok
    }
}

/// One engine update: read the channel's manifest, check its signature, and put its engine into the store, from the
/// store itself, from the app bundle or from a download whose SHA-256 matches. Runs on a background queue, touches
/// no UI state, and returns what the model shows.
package enum EngineUpdate {
    /// An engine as Settings names it.
    package struct Engine: Equatable {
        package let id: String
        package let version: String

        package init(id: String, version: String) {
            self.id = id
            self.version = version
        }
    }

    package enum Via: Equatable { case store, bundle, download }

    package enum Failure: Error, Equatable {
        case network                                    // the manifest did not arrive
        case noManifest                                 // this channel has no latest.json
        case unsigned(EngineManifest.Signature)         // a key is built in and the signature is absent or wrong
        case badManifest(EngineManifest.Problem)
        case wrongChannel(String)                       // a manifest of the other channel
        case download                                   // no source gave the archive
        case digest                                     // what arrived is not what the manifest lists
        case install(EngineInstaller.Failure)
    }

    package enum Outcome: Equatable {
        case current(Engine)                            // the selected tree is the channel's engine
        case available(Engine)                          // a newer one exists and `install` was off
        case installed(Engine, Via)
        case failed(Failure)
    }

    package static let assetPrefix = ".download-"

    /// Formats downloaded bytes into an optional 0...1 fraction and a readable MB summary.
    package static func formatDownloadProgress(written: Int64, expected: Int64?) -> (fraction: Double?, text: String) {
        let safeWritten = max(0, written)
        let mbWritten = Double(safeWritten) / 1_048_576.0
        if let expected, expected > 0 {
            let frac = min(max(Double(safeWritten) / Double(expected), 0), 1)
            let mbExpected = Double(expected) / 1_048_576.0
            let pct = Int((frac * 100).rounded())
            return (frac, String(format: "%.1f / %.1f MB (%d%%)", mbWritten, mbExpected, pct))
        }
        return (nil, String(format: "%.1f MB", mbWritten))
    }

    package static func run(
        channel: EngineChannel,
        appVersion: String,
        current: String,
        store: EngineStore,
        bundled: URL?,
        publicKey: String = EngineManifest.publicKey,
        install: Bool,
        transport: EngineTransport,
        onProgress: (@Sendable (Int64, Int64?) -> Void)? = nil
    ) -> Outcome {
        guard let manifestURL = channel.manifestURL(version: appVersion) else { return .failed(.noManifest) }
        let bundledID = bundled.flatMap { EngineStore.identity(of: $0) }

        let data: Data
        switch transport.data(from: manifestURL) {
        case .ok(let d): data = d
        case .missing:
            // A release without latest.json (one from before engine updates): its stable engine is the one in the app
            guard channel == .stable, let bundled, let id = bundledID else { return .failed(.noManifest) }
            return place(Engine(id: id, version: appVersion), current: current, store: store, bundled: bundled, bundledID: id,
                         install: install) { .failed(.noManifest) }
        case .failed: return .failed(.network)
        }

        var signature: String?
        if let sigURL = channel.signatureURL(version: appVersion), case .ok(let s) = transport.data(from: sigURL) {
            signature = String(decoding: s, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let check = EngineManifest.verify(manifest: data, signature: signature, publicKey: publicKey)
        guard EngineManifest.allowsInstall(check) else { return .failed(.unsigned(check)) }

        let m: EngineManifest.Manifest
        do { m = try EngineManifest.decode(data) }
        catch { return .failed(.badManifest(error as? EngineManifest.Problem ?? .notJSON)) }
        if let c = m.channel, c != channel.rawValue { return .failed(.wrongChannel(c)) }

        return place(Engine(id: m.engineID, version: m.version), current: current, store: store, bundled: bundled, bundledID: bundledID,
                     install: install) {
            downloadAndInstall(m, channel: channel, appVersion: appVersion, store: store, transport: transport, onProgress: onProgress)
        }
    }

    /// How Experimental stands against Stable: both manifests are read, checked like an update's and compared. Anything that goes
    /// wrong (offline, no manifest, a bad signature) is `.unknown`, which offers the switch as before.
    package static func standing(appVersion: String, publicKey: String = EngineManifest.publicKey,
                                 transport: EngineTransport) -> ExperimentalStanding {
        func manifest(_ channel: EngineChannel) -> EngineManifest.Manifest? {
            guard let url = channel.manifestURL(version: appVersion), case .ok(let data) = transport.data(from: url) else { return nil }
            var signature: String?
            if let sigURL = channel.signatureURL(version: appVersion), case .ok(let s) = transport.data(from: sigURL) {
                signature = String(decoding: s, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard EngineManifest.allowsInstall(EngineManifest.verify(manifest: data, signature: signature, publicKey: publicKey)) else { return nil }
            return try? EngineManifest.decode(data)
        }
        guard let experimental = manifest(.experimental), let stable = manifest(.stable) else { return .unknown }
        return ExperimentalStanding.compare(experimental: experimental, stable: stable)
    }

    /// The engine from the cheapest place: already selected, already in the store, in the app, or downloaded.
    private static func place(_ engine: Engine, current: String, store: EngineStore, bundled: URL?, bundledID: String?,
                              install: Bool, download: () -> Outcome) -> Outcome {
        if engine.id == current, store.isUsable(current) { return .current(engine) }
        guard install else { return .available(engine) }
        if store.isUsable(engine.id) { return .installed(engine, .store) }
        if let bundled, bundledID == engine.id {
            do { try EngineInstaller.seed(from: bundled, engineID: engine.id, store: store) }
            catch { return .failed(.install(error as? EngineInstaller.Failure ?? .move)) }
            return .installed(engine, .bundle)
        }
        return download()
    }

    private static func downloadAndInstall(
        _ m: EngineManifest.Manifest,
        channel: EngineChannel,
        appVersion: String,
        store: EngineStore,
        transport: EngineTransport,
        onProgress: (@Sendable (Int64, Int64?) -> Void)?
    ) -> Outcome {
        let fm = FileManager.default
        try? fm.createDirectory(at: store.root, withIntermediateDirectories: true)
        var failure = Failure.download
        let manifestExpected = m.engine.size.flatMap { $0 > 0 ? Int64($0) : nil }
        for url in channel.assetURLs(m.engine.asset, version: appVersion, sources: m.sources) {
            let file = store.root.appendingPathComponent(assetPrefix + UUID().uuidString + ".zip")
            defer { try? fm.removeItem(at: file) }
            let downloaded = transport.download(from: url, to: file) { written, expected in
                onProgress?(written, expected ?? manifestExpected)
            }
            guard downloaded else { continue }
            let size = (try? fm.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue
            guard m.engine.size == nil || size == m.engine.size, AppUpdate.sha256(of: file) == m.engine.sha256 else {
                failure = .digest   // a mirror that serves other bytes: the next source may have the right ones
                continue
            }
            do { try EngineInstaller.install(zip: file, engineID: m.engineID, store: store) }
            catch { return .failed(.install(error as? EngineInstaller.Failure ?? .move)) }
            return .installed(Engine(id: m.engineID, version: m.version), .download)
        }
        return .failed(failure)
    }

    /// The shader chain before and after a switch, when it changed. Every game then compiles its shaders again on
    /// its next build, which the player is told.
    package static func chainChange(from old: String, to new: String) -> (old: String, new: String)? {
        guard let a = EngineLayout.shaderChain(repo: old), let b = EngineLayout.shaderChain(repo: new), a != b else { return nil }
        return (a, b)
    }

    /// The localization key of a failure's message.
    package static func key(_ failure: Failure) -> String {
        switch failure {
        case .network: return "engine.fail.network"
        case .noManifest: return "engine.fail.noManifest"
        case .unsigned: return "engine.fail.unsigned"
        case .badManifest, .wrongChannel: return "engine.fail.manifest"
        case .download: return "engine.fail.download"
        case .digest: return "engine.fail.digest"
        case .install: return "engine.fail.install"
        }
    }
}
