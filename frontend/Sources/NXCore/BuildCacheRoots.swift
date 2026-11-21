import Foundation

// Where the two big build caches live, and how they move (Settings, Tools, next to the shell cache):
//
// - The nxkit work folder: one folder per game with the extracted RomFS and the shader and PSO caches, easily 16 GB a game.
//   Default `~/Library/Caches/NX2Apple/nxkit`, moved into `<picked>/NX2Apple-nxkit`.
// - The build seeds for Fast Refresh: `build-seeds` (one folder per title ID, written by the engine's build_seed.py) and its
//   sibling `refresh-builds` (the work and output folder of a Fast Refresh without an output folder). The launcher derives
//   `refresh-builds` from the seed root, so the two move together, as one tree: `<picked>/NX2Apple-build-seeds/build-seeds` and
//   `<picked>/NX2Apple-build-seeds/refresh-builds`. The default stays `~/Library/Application Support/nxnative/build-seeds` (and
//   `.../nxnative/refresh-builds`). The nxnative folder itself holds the games' saves, so it never moves.
//
// The roots are saved in the defaults, as the shell root is. No saved value is the default place, so nothing changes for a
// player who never moves them. The engine reads `DM_SEED_CACHE_DIR` itself: every engine process the launcher starts gets it
// when the seed root is not the default. A `DM_SEED_CACHE_DIR` in the launcher's own environment keeps winning, as before.
//
// Neither cache has an index file. A plain folder whose visible entries are all plain folders is the launcher's (the folder per
// game, the folder per title ID). `refresh-builds` holds whatever a build leaves there, so any content of the plain folder moves.

package enum BuildCacheRoots {
    /// The defaults keys of the saved roots.
    package static let nxkitKey = "nxkitWorkRoot"
    package static let seedKey = "buildSeedRoot"
    /// The folder a move makes inside the folder the player picked.
    package static let nxkitFolderName = "NX2Apple-nxkit"
    package static let seedFolderName = "NX2Apple-build-seeds"
    package static let seedEnvironmentKey = "DM_SEED_CACHE_DIR"

    // MARK: nxkit

    package static func defaultNxkitRoot(home: String) -> String { home + "/Library/Caches/NX2Apple/nxkit" }

    /// The saved nxkit work root, else the default.
    package static func nxkitRoot(defaults: UserDefaults, home: String) -> String {
        saved(defaults, nxkitKey) ?? defaultNxkitRoot(home: home)
    }

    package static func nxkitDestination(inside folder: String) -> String {
        (folder as NSString).standardizingPath + "/" + nxkitFolderName
    }

    package static let nxkitRules = CacheFolderMove.Rules.folders(nxkitFolderName)

    package static func nxkitMoves(from source: String, to destination: String) -> [CacheFolderMove.Move] {
        [CacheFolderMove.Move(source, to: destination, rules: nxkitRules)]
    }

    // MARK: Build seeds

    /// `~/Library/Application Support/nxnative/build-seeds`, the engine's own default.
    package static func defaultSeedRoot(home: String) -> String { BuildSeedCache.defaultRoot(home: home, env: [:]) }

    /// The seed root the launcher and the engine use: `DM_SEED_CACHE_DIR` of the launcher's environment, else the saved one,
    /// else the default.
    package static func seedRoot(defaults: UserDefaults, home: String, env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let override = env[seedEnvironmentKey], !override.isEmpty { return override }
        return saved(defaults, seedKey) ?? defaultSeedRoot(home: home)
    }

    /// The launcher's environment names the seed root, so a move would not change the folder that is used.
    package static func seedRootFromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        !(env[seedEnvironmentKey] ?? "").isEmpty
    }

    /// `refresh-builds`, beside the seed root.
    package static func refreshBuilds(seedRoot: String) -> String {
        (seedRoot as NSString).deletingLastPathComponent + "/refresh-builds"
    }

    /// The seed root inside the folder the player picked: `<folder>/NX2Apple-build-seeds/build-seeds`.
    package static func seedDestination(inside folder: String) -> String {
        (folder as NSString).standardizingPath + "/" + seedFolderName + "/build-seeds"
    }

    /// `build-seeds` and `refresh-builds` move together, each to its place beside the new seed root.
    package static func seedMoves(from source: String, to destination: String) -> [CacheFolderMove.Move] {
        [CacheFolderMove.Move(source, to: destination, rules: .folders("build-seeds", ownParent: seedFolderName)),
         CacheFolderMove.Move(refreshBuilds(seedRoot: source), to: refreshBuilds(seedRoot: destination),
                              rules: .anything("refresh-builds", ownParent: seedFolderName))]
    }

    /// What an engine process gets added to its environment: `DM_SEED_CACHE_DIR` when the seed root is not the default.
    package static func seedEnvironment(defaults: UserDefaults, home: String,
                                        env: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        let root = seedRoot(defaults: defaults, home: home, env: env)
        return root == defaultSeedRoot(home: home) ? [:] : [seedEnvironmentKey: root]
    }

    // MARK: Saving and the drive

    /// Saves a root after a move. The default place is saved as no value.
    package static func save(_ root: String, key: String, default defaultRoot: String, defaults: UserDefaults) {
        if root == defaultRoot { defaults.removeObject(forKey: key) } else { defaults.set(root, forKey: key) }
    }

    /// The root is on an external drive (`/Volumes/<name>/...`) that is not connected. A build must not write there: the folder
    /// would be made on this Mac's own disk, or the write would fail late. The launcher never makes `/Volumes/<name>` itself.
    package static func unreachable(_ root: String, volumes: String = "/Volumes") -> Bool {
        VolumePath.onUnmounted(root, volumes: volumes)
    }

    private static func saved(_ defaults: UserDefaults, _ key: String) -> String? {
        guard let value = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines), value.hasPrefix("/") else { return nil }
        return (value as NSString).standardizingPath
    }
}
