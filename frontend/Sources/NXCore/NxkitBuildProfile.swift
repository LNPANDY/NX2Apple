import Foundation

/// How nxkit built a Mac app: the optional `build` object at the top of the app's `Contents/Resources/nxkit/launcher.json`
/// (v0lumehi/nxkit#54). nxkit builds a game without a title module on its generic path, and its rule R15 says no such build is silent:
/// the launcher shows it, a log line is not enough. The object is
/// `"build": {"profile": "title" | "generic", "engine": "<engine family id>" | null, "graphics": "nvn" | "vulkan" | "opengl" | null,
/// "evidence": ["<short marker>", ...], "nxkit_version": "<x.y.z>"}`.
///
/// It is read tolerantly: a missing file, a file that is not JSON, a missing `build` object, `"profile": "title"` and a profile value this
/// launcher does not know all read as nil (a normal build, nothing shown). A field of the wrong type is left out, never fatal.
package struct NxkitBuildProfile: Equatable, Sendable {
    /// The engine family nxkit detected (`unreal`, ...), nil when it found none.
    package var engine: String?
    /// The graphics API nxkit found in the game's modules (`nvn`, `vulkan`, `opengl`), nil when it found none.
    package var graphics: String?
    /// nxkit's short markers for what it found. Not shown, kept for a report.
    package var evidence: [String]
    /// The nxkit version that built the app, nil when the file does not say (a build before nxkit wrote it): the report then takes
    /// the launcher's own record of the build.
    package var nxkitVersion: String?

    package init(engine: String? = nil, graphics: String? = nil, evidence: [String] = [], nxkitVersion: String? = nil) {
        self.engine = engine; self.graphics = graphics; self.evidence = evidence; self.nxkitVersion = nxkitVersion
    }

    /// The generic build `data` (the text of launcher.json) describes, nil for a normal build or anything this launcher cannot read.
    package static func parse(_ data: Data) -> NxkitBuildProfile? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let build = root["build"] as? [String: Any],
              let profile = (build["profile"] as? String)?.lowercased(), profile == "generic" else { return nil }
        func text(_ key: String) -> String? {
            guard let s = (build[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            return s
        }
        let evidence = (build["evidence"] as? [Any])?.compactMap { $0 as? String } ?? []
        return NxkitBuildProfile(engine: text("engine"), graphics: text("graphics"), evidence: evidence, nxkitVersion: text("nxkit_version"))
    }

    /// The list of an app nxkit built (LaunchSetting.listURL names the same file).
    package static func listURL(app: String) -> URL {
        URL(fileURLWithPath: app).appendingPathComponent("Contents/Resources/nxkit/launcher.json")
    }

    /// The list's date and size, nil when the app has none: a cache that keeps what read() said (LibraryArtworkStateCache) keys on it,
    /// so a rebuild into the same app path is seen.
    package struct Stamp: Hashable, Sendable { let modified: Date?; let size: UInt64? }
    package static func stamp(app: String) -> Stamp? {
        guard !app.isEmpty, let attributes = try? FileManager.default.attributesOfItem(atPath: listURL(app: app).path) else { return nil }
        return Stamp(modified: attributes[.modificationDate] as? Date, size: (attributes[.size] as? NSNumber)?.uint64Value)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: (stamp: Stamp, profile: NxkitBuildProfile?)] = [:]

    /// The generic build of the app at `app`, nil for a normal build and for an app that is not nxkit's (it has no nxkit/launcher.json).
    /// Views call it while drawing: the file is read again only when its date or size changed.
    package static func read(app: String) -> NxkitBuildProfile? {
        guard let stamp = stamp(app: app) else { return nil }
        let url = listURL(app: app)
        lock.lock()
        if let hit = cache[url.path], hit.stamp == stamp { lock.unlock(); return hit.profile }
        lock.unlock()
        let profile = (try? Data(contentsOf: url)).flatMap(parse)
        lock.lock(); cache[url.path] = (stamp, profile); lock.unlock()
        return profile
    }

    /// The graphics API as players know it, the id itself for one this launcher does not know.
    package var graphicsName: String? {
        graphics.map { id in
            switch id.lowercased() {
            case "nvn": return "NVN"
            case "vulkan": return "Vulkan"
            case "opengl": return "OpenGL"
            default: return id
            }
        }
    }

    /// The engine family as players know it, the id itself for one this launcher does not know.
    package var engineName: String? {
        engine.map { id in
            switch id.lowercased() {
            case "unreal", "unreal4", "ue4": return "Unreal Engine"
            case "unity": return "Unity"
            default: return id
            }
        }
    }
}
