import Foundation

/// Which engine the launcher follows, and where its manifest lives.
///
/// - `stable` is the engine that shipped with the running app's release: the tested one, and the default.
/// - `experimental` ("实验版") is the tree the nightly sync built from the newest pin, published as a
///   pre-release under a fixed tag. It is opt-in, it never carries the app, and it is only checked by CI
///   (compiled, patches applied, host tests) — not played on hardware.
enum EngineChannel: String, CaseIterable {
    case stable, experimental

    /// The pre-release tag the nightly job replaces the experimental engine under. A fixed tag, so the
    /// launcher's URL never changes; the assets inside are re-uploaded.
    static let experimentalTag = "engine-experimental"
    /// Where this repository's release assets live.
    static let releaseBase = "https://github.com/LNPANDY/NX2Apple/releases/download/"

    /// The manifest for this channel. `version` is the running app's release version, which names the
    /// stable tag (`v0.7.2`); the experimental channel ignores it.
    func manifestURL(version: String) -> URL? {
        switch self {
        case .stable: return URL(string: Self.releaseBase + "v" + version + "/latest.json")
        case .experimental: return URL(string: Self.releaseBase + Self.experimentalTag + "/latest.json")
        }
    }

    /// Where an asset of this channel lives when the manifest names no source. A manifest that lists
    /// sources wins: that is how a mirror is introduced without a new launcher.
    func assetURL(_ name: String, version: String, sources: [String]) -> URL? {
        if let first = sources.first {
            let base = first.hasSuffix("/") ? first : first + "/"
            return URL(string: base + name)
        }
        let tag = self == .stable ? "v" + version : Self.experimentalTag
        return URL(string: Self.releaseBase + tag + "/" + name)
    }
}

/// Installing an engine tree: unpack it beside the others, check it is complete, switch to it, and keep
/// the previous one until the next successful switch (a build started moments ago may still be running).
enum EngineInstaller {
    enum Failure: Error, Equatable {
        case unpack                 // ditto failed: not a zip, or out of space
        case incomplete(String)     // the tree lacks what the launcher runs by path
        case move                   // could not put it in place
    }

    /// Unpack `zip` into `<store>/<pin>/`. The archive's root is the tree itself
    /// (`scripts/`, `dm/`, `.upstream-ref`, …), as the release workflow builds it.
    ///
    /// Unpacking goes to a hidden folder first and is renamed only when complete, so an interrupted
    /// download never leaves a tree that looks usable.
    @discardableResult
    static func install(zip: URL, pin: String, store: EngineStore, keeping previous: String? = nil) throws -> URL {
        let fm = FileManager.default
        let dest = store.directory(for: pin)
        let tmp = store.root.appendingPathComponent(".tmp-" + UUID().uuidString, isDirectory: true)
        try? fm.createDirectory(at: store.root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, tmp.path]   // the same unpacker the app's own update uses
        ditto.standardOutput = FileHandle.nullDevice
        ditto.standardError = FileHandle.nullDevice
        do { try ditto.run() } catch { throw Failure.unpack }
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw Failure.unpack }

        // A release asset may wrap the tree in one folder (`engine/…`, or `<something>/engine/…`): descend
        // while the folder has no build script and exactly one subdirectory, two levels at most.
        let marker = "scripts/build_ipa_from_nsp.py"
        var source = tmp
        for _ in 0..<2 where !fm.fileExists(atPath: source.appendingPathComponent(marker).path) {
            let kids = ((try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            guard kids.count == 1, let only = kids.first else { break }
            source = only
        }
        guard fm.fileExists(atPath: source.appendingPathComponent("scripts/build_ipa_from_nsp.py").path),
              fm.fileExists(atPath: source.appendingPathComponent("dm/tools/romfs_image.py").path),
              fm.fileExists(atPath: source.appendingPathComponent(".upstream-ref").path) else {
            throw Failure.incomplete(source.lastPathComponent)
        }

        try? fm.removeItem(at: dest)
        do { try fm.moveItem(at: source, to: dest) } catch { throw Failure.move }
        guard store.isUsable(pin) else { throw Failure.incomplete(pin) }

        var keep: Set<String> = [pin]
        if let previous, previous != pin { keep.insert(previous) }
        store.prune(keeping: keep)
        return dest
    }
}

/// Which channel and pin the launcher is on, remembered between launches.
struct EngineSelection: Equatable {
    var channel: EngineChannel
    var pin: String          // empty: nothing installed by the launcher yet (a developer's checkout)
    var previousPin: String  // the one kept for a build that was already running

    private static let channelKey = "engineChannel"
    private static let pinKey = "enginePin"
    private static let previousKey = "enginePreviousPin"

    static func load(_ defaults: UserDefaults = .standard) -> EngineSelection {
        EngineSelection(channel: EngineChannel(rawValue: defaults.string(forKey: channelKey) ?? "") ?? .stable,
                        pin: defaults.string(forKey: pinKey) ?? "",
                        previousPin: defaults.string(forKey: previousKey) ?? "")
    }

    func save(_ defaults: UserDefaults = .standard) {
        defaults.set(channel.rawValue, forKey: Self.channelKey)
        defaults.set(pin, forKey: Self.pinKey)
        defaults.set(previousPin, forKey: Self.previousKey)
    }

    /// Move to a newly installed pin, keeping the one we came from.
    mutating func switched(to pin: String) {
        if !self.pin.isEmpty, self.pin != pin { previousPin = self.pin }
        self.pin = pin
    }
}
