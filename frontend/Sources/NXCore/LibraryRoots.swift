import Foundation

/// The folders the library looks for games in (LNPANDY/NX2Apple#992). Pure rules, so they are tested without a library:
/// two spellings of one folder are one root, a root keeps its place (the first root wins when two hold the same game), and a root on a
/// drive that is not connected is a state of its own, not an error. Where the built game goes stays the player's explicit choice.
package enum LibraryRoots {
    package enum State: Equatable {
        case connected
        /// The folder is on `/Volumes/<name>` and that volume is not mounted: its games stay in the library, not ready.
        case disconnected
        /// The folder is gone from a mounted volume (moved, renamed, deleted).
        case missing
        /// An earlier root already contains it, so its games are found there.
        case covered(by: String)
    }

    /// The folder as one root is compared: standardized, symbolic links resolved when it exists, without a trailing slash.
    package static func normalized(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let resolved = FileManager.default.fileExists(atPath: url.path) ? url.resolvingSymlinksInPath().path : url.path
        return resolved.count > 1 && resolved.hasSuffix("/") ? String(resolved.dropLast()) : resolved
    }

    /// The roots with `path` added at the end, unless one of them is the same folder. Order is kept. Empty paths are dropped.
    package static func adding(_ path: String, to roots: [String]) -> [String] {
        let new = normalized(path)
        guard !new.isEmpty, !roots.contains(where: { normalized($0) == new }) else { return roots }
        return roots + [URL(fileURLWithPath: path).standardizedFileURL.path]
    }

    /// The roots without the folder `path` names, and without a second spelling of any root.
    package static func removing(_ path: String, from roots: [String]) -> [String] {
        let gone = normalized(path)
        var seen = Set<String>()
        return roots.filter { root in
            let key = normalized(root)
            return key != gone && seen.insert(key).inserted
        }
    }

    package static func state(of root: String, in roots: [String], volumes: String = "/Volumes") -> State {
        if VolumePath.onUnmounted(root, volumes: volumes) { return .disconnected }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue else { return .missing }
        let mine = normalized(root)
        for earlier in roots {
            if earlier == root { break }
            let other = normalized(earlier)
            if other == mine || mine.hasPrefix(other + "/") { return .covered(by: earlier) }
        }
        return .connected
    }

    /// The roots a scan walks, in order: connected ones that no earlier root contains.
    package static func scannable(_ roots: [String], volumes: String = "/Volumes") -> [String] {
        roots.filter { state(of: $0, in: roots, volumes: volumes) == .connected }
    }
}
