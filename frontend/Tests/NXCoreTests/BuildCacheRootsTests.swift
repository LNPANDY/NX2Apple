import XCTest
@testable import NXCore

/// Where the nxkit work folder and the build seeds live: the defaults are today's places, a saved root wins over them,
/// `DM_SEED_CACHE_DIR` of the launcher's environment wins over both, `refresh-builds` follows the seed root, and a root on a drive
/// that is not connected is not reachable.
final class BuildCacheRootsTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() { defaults = TestDefaults.make("nspb-cache-roots") }

    func testTheDefaultsAreTodaysPlaces() {
        XCTAssertEqual(BuildCacheRoots.nxkitRoot(defaults: defaults, home: "/Users/p"), "/Users/p/Library/Caches/NX2Apple/nxkit")
        XCTAssertEqual(BuildCacheRoots.seedRoot(defaults: defaults, home: "/Users/p", env: [:]), "/Users/p/Library/Application Support/nxnative/build-seeds")
        XCTAssertEqual(BuildCacheRoots.seedRoot(defaults: defaults, home: "/Users/p", env: [:]), BuildSeedCache.defaultRoot(home: "/Users/p", env: [:]))
        XCTAssertEqual(BuildCacheRoots.refreshBuilds(seedRoot: BuildCacheRoots.defaultSeedRoot(home: "/Users/p")),
                       "/Users/p/Library/Application Support/nxnative/refresh-builds")
        XCTAssertEqual(BuildCacheRoots.seedEnvironment(defaults: defaults, home: "/Users/p", env: [:]), [:], "nothing changes for a player who never moved them")
    }

    func testASavedRootWinsAndRefreshBuildsFollowsTheSeedRoot() {
        defaults.set("/Volumes/T7/Games/NX2Apple-nxkit", forKey: BuildCacheRoots.nxkitKey)
        defaults.set("/Volumes/T7/Games/NX2Apple-build-seeds/build-seeds", forKey: BuildCacheRoots.seedKey)
        XCTAssertEqual(BuildCacheRoots.nxkitRoot(defaults: defaults, home: "/Users/p"), "/Volumes/T7/Games/NX2Apple-nxkit")
        let seeds = BuildCacheRoots.seedRoot(defaults: defaults, home: "/Users/p", env: [:])
        XCTAssertEqual(seeds, "/Volumes/T7/Games/NX2Apple-build-seeds/build-seeds")
        XCTAssertEqual(BuildCacheRoots.refreshBuilds(seedRoot: seeds), "/Volumes/T7/Games/NX2Apple-build-seeds/refresh-builds")
        XCTAssertEqual(BuildSeedCache.seedDirectory(for: "0100aaaa00000000", seedRoot: seeds), seeds + "/0100AAAA00000000")
        XCTAssertEqual(BuildCacheRoots.seedEnvironment(defaults: defaults, home: "/Users/p", env: [:]), ["DM_SEED_CACHE_DIR": seeds])

        defaults.set("relative/place", forKey: BuildCacheRoots.nxkitKey)
        XCTAssertEqual(BuildCacheRoots.nxkitRoot(defaults: defaults, home: "/Users/p"), "/Users/p/Library/Caches/NX2Apple/nxkit", "a broken value is the default")
    }

    func testTheLaunchersOwnEnvironmentKeepsWinning() {
        defaults.set("/Volumes/T7/Games/NX2Apple-build-seeds/build-seeds", forKey: BuildCacheRoots.seedKey)
        let env = ["DM_SEED_CACHE_DIR": "/custom/seeds"]
        XCTAssertEqual(BuildCacheRoots.seedRoot(defaults: defaults, home: "/Users/p", env: env), "/custom/seeds")
        XCTAssertEqual(BuildCacheRoots.seedEnvironment(defaults: defaults, home: "/Users/p", env: env), ["DM_SEED_CACHE_DIR": "/custom/seeds"])
        XCTAssertTrue(BuildCacheRoots.seedRootFromEnvironment(env))
        XCTAssertFalse(BuildCacheRoots.seedRootFromEnvironment(["DM_SEED_CACHE_DIR": ""]))
    }

    func testSavingTheDefaultPlaceLeavesNoValue() {
        let home = "/Users/p"
        BuildCacheRoots.save("/Volumes/T7/NX2Apple-nxkit", key: BuildCacheRoots.nxkitKey, default: BuildCacheRoots.defaultNxkitRoot(home: home), defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: BuildCacheRoots.nxkitKey), "/Volumes/T7/NX2Apple-nxkit")
        BuildCacheRoots.save(BuildCacheRoots.defaultNxkitRoot(home: home), key: BuildCacheRoots.nxkitKey, default: BuildCacheRoots.defaultNxkitRoot(home: home), defaults: defaults)
        XCTAssertNil(defaults.string(forKey: BuildCacheRoots.nxkitKey))
    }

    /// A drive that is not connected: its folder under /Volumes is missing, so the root must not be used or made.
    func testARootOnADriveThatIsNotConnectedIsNotReachable() throws {
        let volumes = FileManager.default.temporaryDirectory.path + "/nspb-volumes-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: volumes) }
        XCTAssertTrue(BuildCacheRoots.unreachable(volumes + "/T7/Games/NX2Apple-nxkit", volumes: volumes))
        try FileManager.default.createDirectory(atPath: volumes + "/T7", withIntermediateDirectories: true)
        XCTAssertFalse(BuildCacheRoots.unreachable(volumes + "/T7/Games/NX2Apple-nxkit", volumes: volumes), "connected, the folder itself may be missing")
        XCTAssertFalse(BuildCacheRoots.unreachable("/Users/p/Library/Caches/NX2Apple/nxkit", volumes: volumes), "the internal disk is always there")
        XCTAssertFalse(FileManager.default.fileExists(atPath: volumes + "/T7/Games"), "the check makes nothing")
    }
}
