import XCTest
@testable import NXCore

final class MultiEngineIsolationTests: XCTestCase {
    private var root: URL!
    private let tid = "0100535012974000"

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("multi-engine-iso-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    @discardableResult
    private func createFakeBundle(at url: URL, titleID: String, displayName: String, upstream: EngineUpstreamKind) throws -> URL {
        let macOS = url.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let exe: String
        let domain = root.appendingPathComponent("iso-\(upstream.rawValue)-\(titleID)").path
        let bundleID: String
        var extra: [String: Any] = [:]
        switch upstream {
        case .nxnative:
            exe = "nxnative"
            try FileManager.default.createSymbolicLink(at: macOS.appendingPathComponent("dmhost"), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
            bundleID = domain
        case .kidWithSword, .noLagKart:
            exe = "nxnative"
            try FileManager.default.createSymbolicLink(at: macOS.appendingPathComponent("dmhost"), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
            bundleID = upstream.personalMacBundleID(titleID: titleID) ?? domain
        case .macNativeGames:
            exe = "macnativegames"
            bundleID = domain
            extra["DMUpstream"] = "macnativegames"
        case .s2arm:
            exe = "s2arm-host"
            bundleID = domain
            extra["DMUpstream"] = "s2arm"
            try Data("lib".utf8).write(to: macOS.appendingPathComponent("libs2a_vaguard.dylib"))
        case .nxkit:
            exe = NxkitBuilder.hostName
            bundleID = domain
            let res = url.appendingPathComponent("Contents/Resources/nxkit", isDirectory: true)
            try FileManager.default.createDirectory(at: res, withIntermediateDirectories: true)
            try Data("k".utf8).write(to: res.appendingPathComponent("romfs"))
        }
        try FileManager.default.createSymbolicLink(at: macOS.appendingPathComponent(exe), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        var plist: [String: Any] = [
            "DMTitleID": titleID,
            "CFBundleDisplayName": displayName,
            "CFBundleExecutable": exe,
            "CFBundleIdentifier": bundleID
        ]
        for (k, v) in extra { plist[k] = v }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
        return url
    }

    func testMacAppOutputCoexistenceAndSameEngineRebuild() throws {
        let outDir = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        func buildAndFinish(_ upstream: EngineUpstreamKind) throws -> URL {
            let suffix = upstream.workDirSuffix.map { "_\($0)" } ?? ""
            let workDir = outDir.appendingPathComponent("\(tid)\(suffix)_build", isDirectory: true)
            let output = MacAppOutput(workDir: workDir, key: tid, titleID: tid, upstream: upstream, preferred: "")
            try createFakeBundle(at: output.builderURL, titleID: tid, displayName: "Hades", upstream: upstream)
            return try output.finish()
        }

        let nxApp = try buildAndFinish(.nxnative)
        let mngApp = try buildAndFinish(.macNativeGames)
        let s2armApp = try buildAndFinish(.s2arm)
        let nxkitApp = try buildAndFinish(.nxkit)
        let kwsApp = try buildAndFinish(.kidWithSword)
        let nlkApp = try buildAndFinish(.noLagKart)

        XCTAssertEqual(nxApp.lastPathComponent, "Hades.app")
        XCTAssertEqual(mngApp.lastPathComponent, "Hades [MacNativeGames].app")
        XCTAssertEqual(s2armApp.lastPathComponent, "Hades [S2Arm].app")
        XCTAssertEqual(nxkitApp.lastPathComponent, "Hades [nxkit].app")
        XCTAssertEqual(kwsApp.lastPathComponent, "Hades [Kid with Sword].app")
        XCTAssertEqual(nlkApp.lastPathComponent, "Hades [No Lag Kart].app")

        for url in [nxApp, mngApp, s2armApp, nxkitApp, kwsApp, nlkApp] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Missing \(url.lastPathComponent)")
        }

        // MacAppOutput.existing must scope to `(titleID, upstream)` so rebuilding MNG never hits nxnative.app.
        XCTAssertEqual(MacAppOutput.existing(in: outDir, titleID: tid, upstream: .nxnative)?.standardizedFileURL, nxApp.standardizedFileURL)
        XCTAssertEqual(MacAppOutput.existing(in: outDir, titleID: tid, upstream: .macNativeGames)?.standardizedFileURL, mngApp.standardizedFileURL)
        XCTAssertEqual(MacAppOutput.existing(in: outDir, titleID: tid, upstream: .s2arm)?.standardizedFileURL, s2armApp.standardizedFileURL)
        XCTAssertEqual(MacAppOutput.existing(in: outDir, titleID: tid, upstream: .kidWithSword)?.standardizedFileURL, kwsApp.standardizedFileURL)
        XCTAssertEqual(MacAppOutput.existing(in: outDir, titleID: tid, upstream: .noLagKart)?.standardizedFileURL, nlkApp.standardizedFileURL)

        // Work dir suffixes keep nxnative clean (`nil`) and isolate all other engines.
        XCTAssertNil(EngineUpstreamKind.nxnative.workDirSuffix)
        XCTAssertEqual(EngineUpstreamKind.macNativeGames.workDirSuffix, "mng")
        XCTAssertEqual(EngineUpstreamKind.s2arm.workDirSuffix, "s2arm")
        XCTAssertEqual(EngineUpstreamKind.nxkit.workDirSuffix, "nxkit")
        XCTAssertEqual(EngineUpstreamKind.kidWithSword.workDirSuffix, "kidwithsword")
        XCTAssertEqual(EngineUpstreamKind.noLagKart.workDirSuffix, "nolagkart")
    }

    func testMacGameBundleDetectsVariantFallbackBundleIDsAndSaveSharingPolicy() throws {
        let kws = try createFakeBundle(at: root.appendingPathComponent("OOT [Kid with Sword].app"), titleID: EngineUpstreamKind.ootSwitch2TitleID, displayName: "OOT", upstream: .kidWithSword)
        let nlk = try createFakeBundle(at: root.appendingPathComponent("MKW [No Lag Kart].app"), titleID: EngineUpstreamKind.mkwSwitch2TitleID, displayName: "MKW", upstream: .noLagKart)

        XCTAssertEqual(try MacGameBundle.read(kws).upstream, .kidWithSword)
        XCTAssertEqual(try MacGameBundle.read(nlk).upstream, .noLagKart)

        XCTAssertTrue(EngineUpstreamKind.nxnative.sharesSaveWithNxnative)
        XCTAssertFalse(EngineUpstreamKind.macNativeGames.sharesSaveWithNxnative)
        XCTAssertTrue(EngineUpstreamKind.kidWithSword.sharesSaveWithNxnative)
        XCTAssertTrue(EngineUpstreamKind.noLagKart.sharesSaveWithNxnative)
        XCTAssertFalse(EngineUpstreamKind.s2arm.sharesSaveWithNxnative)
        XCTAssertFalse(EngineUpstreamKind.nxkit.sharesSaveWithNxnative)
    }

    func testSaveEnginesRouteMNGAndS2ArmWithoutFallingBackToDm() throws {
        let support = root.appendingPathComponent("support", isDirectory: true)
        let totkTID = "0100F2C0115B6000"
        let nx = try createFakeBundle(at: root.appendingPathComponent("TOTK.app"), titleID: totkTID, displayName: "TOTK", upstream: .nxnative)
        let kws = try createFakeBundle(at: root.appendingPathComponent("OOT [Kid with Sword].app"), titleID: EngineUpstreamKind.ootSwitch2TitleID, displayName: "OOT", upstream: .kidWithSword)
        let nlk = try createFakeBundle(at: root.appendingPathComponent("MKW [No Lag Kart].app"), titleID: EngineUpstreamKind.mkwSwitch2TitleID, displayName: "MKW", upstream: .noLagKart)
        let mng = try createFakeBundle(at: root.appendingPathComponent("TOTK [MacNativeGames].app"), titleID: totkTID, displayName: "TOTK", upstream: .macNativeGames)
        let s2arm = try createFakeBundle(at: root.appendingPathComponent("TOTK [S2Arm].app"), titleID: totkTID, displayName: "TOTK", upstream: .s2arm)
        let nxkit = try createFakeBundle(at: root.appendingPathComponent("TOTK [nxkit].app"), titleID: totkTID, displayName: "TOTK", upstream: .nxkit)

        XCTAssertTrue(SaveEngines.forApp(nx.path) is DmSaveEngine)
        XCTAssertTrue(SaveEngines.forApp(kws.path) is DmSaveEngine)
        XCTAssertTrue(SaveEngines.forApp(nlk.path) is DmSaveEngine)
        XCTAssertTrue(SaveEngines.forApp(mng.path) is MacNativeGamesSaveEngine)
        XCTAssertTrue(SaveEngines.forApp(s2arm.path) is S2ArmSaveEngine)
        XCTAssertTrue(SaveEngines.forApp(nxkit.path) is NxkitSaveEngine)

        let mngEngine = SaveEngines.forApp(mng.path)
        XCTAssertFalse(mngEngine.managesSavesInLauncher)
        XCTAssertEqual(mngEngine.defaultSave(titleID: totkTID, support: support).path, support.appendingPathComponent("MacNativeGames/TOTK/profile/save").path)
        XCTAssertEqual(mngEngine.defaultSave(titleID: "01002DA013484000", support: support).path,
                       support.appendingPathComponent("The Legend of Zelda Skyward Sword HD/save").path)
        XCTAssertEqual(mngEngine.defaultSave(titleID: "010048900CF64000", support: support).path,
                       support.appendingPathComponent("MacNativeGames/Worldend Syndrome/save").path)

        let s2armEngine = SaveEngines.forApp(s2arm.path)
        XCTAssertFalse(s2armEngine.managesSavesInLauncher)
        XCTAssertEqual(s2armEngine.defaultSave(titleID: totkTID, support: support).path,
                       support.appendingPathComponent("NX2Apple/s2arm-data/\(totkTID)/SaveData").path)

        // Global/game save overrides and library marker must never hijack MNG or S2Arm paths or inject DM_SAVE/DM_SAVE_SYNC.
        let global = SaveGlobalSettings(cloudFolder: "icloud", cloudOn: true, saveRoot: "/Volumes/Saves")
        let gameOverride = SaveGameOverride(cloud: .folder("/Volumes/Cloud"), saveFolder: "/Volumes/CustomSave")
        for engine in [mngEngine, s2armEngine] {
            let eff = SaveLocations.effectiveSave(titleID: totkTID, appPath: mng.path, global: global, game: gameOverride, support: support, engine: engine)
            XCTAssertEqual(eff.path, engine.defaultSave(titleID: totkTID, support: support))
            XCTAssertEqual(eff.source, .standard)
            XCTAssertTrue(SaveLocations.environment(save: eff, cloud: .init(folder: "icloud", source: .global), engine: engine).isEmpty)
            XCTAssertTrue(PlayerProfile(id: "p2", name: "Alice").environment(base: eff.path, engine: engine).isEmpty)
        }
    }

    func testOneGameIPAPathAndPersonalBundleIDIsolation() {
        XCTAssertEqual(OneGameIPA.path(folder: "/tmp/out", titleID: tid, upstream: .nxnative), "/tmp/out/\(tid).ipa")
        XCTAssertEqual(OneGameIPA.path(folder: "/tmp/out", titleID: tid, upstream: .kidWithSword), "/tmp/out/\(tid)-kidwithsword.ipa")

        XCTAssertEqual(
            OneGameIPA.personalBundleID(titleID: tid, teamID: "TEAM123", upstream: .nxnative),
            "org.nxnative.\(tid.lowercased()).TEAM123"
        )
        XCTAssertEqual(
            OneGameIPA.personalBundleID(titleID: tid, teamID: "TEAM123", upstream: .kidWithSword),
            "org.nxnative.\(tid.lowercased()).kidwithsword.TEAM123"
        )
    }

    func testDefaultBuildPreferencePersistenceAndFallbackResolution() {
        let defaults = TestDefaults.make("multi-engine-pref")

        XCTAssertNil(DefaultBuildPreference.get(titleID: tid, defaults: defaults))
        DefaultBuildPreference.set(.macNativeGames, titleID: tid, defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: "defaultMacEngine.\(tid)"), EngineUpstreamKind.macNativeGames.rawValue)
        XCTAssertEqual(DefaultBuildPreference.get(titleID: tid, defaults: defaults), .macNativeGames)

        XCTAssertEqual(
            DefaultBuildPreference.resolveActive(preferred: .macNativeGames, available: [.nxnative, .macNativeGames, .s2arm]),
            .macNativeGames
        )
        XCTAssertEqual(
            DefaultBuildPreference.resolveActive(preferred: .macNativeGames, available: [.nxnative, .s2arm]),
            .nxnative
        )
        XCTAssertEqual(
            DefaultBuildPreference.resolveActive(preferred: .macNativeGames, available: [.s2arm, .nxkit]),
            .s2arm
        )
        XCTAssertNil(DefaultBuildPreference.resolveActive(preferred: .macNativeGames, available: []))

        DefaultBuildPreference.set(nil, titleID: tid, defaults: defaults)
        XCTAssertNil(DefaultBuildPreference.get(titleID: tid, defaults: defaults))
    }
}
