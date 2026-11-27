import Foundation
import XCTest
@testable import NXCore

final class EngineVariantsAndTunedQueryTests: XCTestCase {
    private var temporary: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("engine-variants-core-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        BuiltUpstreamRegistry.customStoreURL = temporary.appendingPathComponent("built-upstreams.json")
    }

    override func tearDownWithError() throws {
        BuiltUpstreamRegistry.customStoreURL = nil
        try? FileManager.default.removeItem(at: temporary)
    }

    func testGroupingCapabilitiesAndWorkDirIsolation() {
        XCTAssertEqual(EngineUpstreamKind.nxnative.group, .general)
        XCTAssertEqual(EngineUpstreamKind.nxkit.group, .general)
        XCTAssertEqual(EngineUpstreamKind.macNativeGames.group, .gameTuned)
        XCTAssertEqual(EngineUpstreamKind.kidWithSword.group, .gameTuned)
        XCTAssertEqual(EngineUpstreamKind.noLagKart.group, .gameTuned)

        XCTAssertTrue(EngineUpstreamKind.kidWithSword.isNxnativeVariant)
        XCTAssertTrue(EngineUpstreamKind.noLagKart.isNxnativeVariant)
        XCTAssertFalse(EngineUpstreamKind.nxnative.isNxnativeVariant)
        XCTAssertFalse(EngineUpstreamKind.macNativeGames.isNxnativeVariant)

        // Kid with Sword supports Mac + iOS standalone IPA (never shared shell).
        XCTAssertFalse(EngineUpstreamKind.kidWithSword.buildsMacOnly)
        XCTAssertTrue(EngineUpstreamKind.kidWithSword.supportsIOS)
        XCTAssertTrue(EngineUpstreamKind.kidWithSword.buildsIOSStandaloneOnly)
        XCTAssertFalse(EngineUpstreamKind.kidWithSword.supportsSharedIOSShell)
        XCTAssertEqual(EngineUpstreamKind.kidWithSword.gitBranch, "L")
        XCTAssertEqual(EngineUpstreamKind.kidWithSword.workDirSuffix, "kidwithsword")

        // No Lag Kart supports Mac only.
        XCTAssertTrue(EngineUpstreamKind.noLagKart.buildsMacOnly)
        XCTAssertFalse(EngineUpstreamKind.noLagKart.supportsIOS)
        XCTAssertFalse(EngineUpstreamKind.noLagKart.buildsIOSStandaloneOnly)
        XCTAssertEqual(EngineUpstreamKind.noLagKart.macOnlyNoteKey, "upstream.noLagKartMacOnly")
        XCTAssertEqual(EngineUpstreamKind.noLagKart.gitBranch, "main")
        XCTAssertEqual(EngineUpstreamKind.noLagKart.workDirSuffix, "nolagkart")
    }

    func testUnifiedTunedEnginesQueryAndRecommendations() {
        // Ocarina of Time Switch 2 has both Kid with Sword (Mac+iOS) and MacNativeGames (Mac only).
        let ootTuned = EngineUpstream.tunedEngines(forTitleID: "0400486024dec000", macNativeGamesEnabled: true)
        XCTAssertEqual(ootTuned, [.kidWithSword, .macNativeGames])
        XCTAssertTrue(EngineUpstream.hasTunedEngine(forTitleID: "0400486024DEC000", macNativeGamesEnabled: true))
        XCTAssertEqual(
            EngineUpstream.recommendedTunedEngine(forTitleID: "0400486024DEC000", target: BuildTarget.mac, macNativeGamesEnabled: true),
            .kidWithSword
        )
        XCTAssertEqual(
            EngineUpstream.recommendedTunedEngine(forTitleID: "0400486024DEC000", target: BuildTarget.ios, macNativeGamesEnabled: true),
            .kidWithSword
        )

        // Mario Kart World Switch 2 has No Lag Kart (Mac only).
        XCTAssertEqual(EngineUpstream.tunedEngines(forTitleID: "0400C3F00006E000", macNativeGamesEnabled: true), [.noLagKart])
        XCTAssertEqual(
            EngineUpstream.recommendedTunedEngine(forTitleID: "0400C3F00006E000", target: BuildTarget.mac, macNativeGamesEnabled: true),
            .noLagKart
        )
        XCTAssertNil(
            EngineUpstream.recommendedTunedEngine(forTitleID: "0400C3F00006E000", target: BuildTarget.ios, macNativeGamesEnabled: true)
        )

        // Breath of the Wild has MacNativeGames only.
        XCTAssertEqual(EngineUpstream.tunedEngines(forTitleID: "01007EF00011E000", macNativeGamesEnabled: true), [.macNativeGames])
        XCTAssertEqual(EngineUpstream.tunedEngines(forTitleID: "01007EF00011E000", macNativeGamesEnabled: false), [])

        // Unmatched or malformed title ID returns empty.
        XCTAssertEqual(EngineUpstream.tunedEngines(forTitleID: "0100152000022000", macNativeGamesEnabled: true), [])
        XCTAssertEqual(EngineUpstream.tunedEngines(forTitleID: "not-a-title-id", macNativeGamesEnabled: true), [])
    }

    func testUpstreamStoreAndInfoRefsTrackBranchLAndMain() throws {
        XCTAssertEqual(
            UpstreamEngineStore.archiveURL(for: .kidWithSword)?.absoluteString,
            "https://codeload.github.com/cheemu21/kid-with-sword-remake/zip/refs/heads/L"
        )
        XCTAssertEqual(
            UpstreamEngineStore.archiveURL(for: .noLagKart)?.absoluteString,
            "https://codeload.github.com/kingbumi31/no-lag-kart/zip/refs/heads/main"
        )

        let lCommit = String(repeating: "a", count: 40)
        let mainCommit = String(repeating: "b", count: 40)
        let refsPayload = """
        001e# service=git-upload-pack
        0000003f\(mainCommit) HEAD\0multi_ack
        003f\(mainCommit) refs/heads/main
        003b\(lCommit) refs/heads/L
        0000
        """
        let kwsInfo = UpstreamVersion.parseInfoRefs(kind: .kidWithSword, data: Data(refsPayload.utf8))
        XCTAssertEqual(kwsInfo?.commit, lCommit, "kidWithSword must track refs/heads/L rather than refs/heads/main")
        XCTAssertEqual(kwsInfo?.version, String(lCommit.prefix(7)))

        let nlkInfo = UpstreamVersion.parseInfoRefs(kind: .noLagKart, data: Data(refsPayload.utf8))
        XCTAssertEqual(nlkInfo?.commit, mainCommit, "noLagKart must track refs/heads/main")
        XCTAssertEqual(nlkInfo?.version, String(mainCommit.prefix(7)))

        // Verify usable tree check for nxnative variants.
        let validTree = temporary.appendingPathComponent("kws-tree", isDirectory: true)
        try FileManager.default.createDirectory(at: validTree.appendingPathComponent("dm/tools/nx_extract"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: validTree.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try Data("// cs\n".utf8).write(to: validTree.appendingPathComponent("dm/tools/nx_extract/Program.cs"))
        XCTAssertFalse(UpstreamEngineStore.isUsableTree(validTree.path, kind: .kidWithSword))
        try Data("# \"--progress\" \"--work-dir\" \"--bundle-id\" \"--env-file\"\n".utf8)
            .write(to: validTree.appendingPathComponent("scripts/build_ipa_from_nsp.py"))
        XCTAssertTrue(UpstreamEngineStore.isUsableTree(validTree.path, kind: .kidWithSword))
        XCTAssertTrue(UpstreamEngineStore.isUsableTree(validTree.path, kind: .noLagKart))
        XCTAssertTrue(RepoLayout.supportsProgressJson(validTree.path))
        XCTAssertTrue(RepoLayout.supportsBundleID(validTree.path))
        XCTAssertTrue(RepoLayout.supportsEnvFile(validTree.path))
    }

    func testOneGameIPAPersonalBundleIDAndBuiltUpstreamRegistryAttribution() throws {
        XCTAssertEqual(
            OneGameIPA.personalBundleID(titleID: "0400486024DEC000", teamID: "ABC123DEF4"),
            "org.nxnative.0400486024dec000.ABC123DEF4"
        )
        XCTAssertNil(OneGameIPA.personalBundleID(titleID: "0400486024DEC000", teamID: "  "))
        XCTAssertNil(OneGameIPA.personalBundleID(titleID: "0400486024DEC000", teamID: "0000000000"))
        XCTAssertEqual(
            OneGameIPA.arguments(ipa: "/tmp/out.ipa", bundleID: "org.nxnative.0400486024dec000.TEAM1"),
            ["--platform", "ios", "--romfs", "bundle", "-o", "/tmp/out.ipa", "--bundle-id", "org.nxnative.0400486024dec000.TEAM1"]
        )

        // Build a synthetic Mac .app bundle (no DMUpstream in Info.plist, preserving untouched signature contract).
        let app = temporary.appendingPathComponent("Ocarina.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: app.appendingPathComponent("Contents/MacOS/Game"), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        try FileManager.default.createSymbolicLink(at: app.appendingPathComponent("Contents/MacOS/dmhost"), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        let plist: [String: Any] = [
            "CFBundlePackageType": "APPL",
            "CFBundleExecutable": "Game",
            "CFBundleIdentifier": "org.nxnative.0400486024dec000",
            "CFBundleName": "Ocarina of Time",
            "DMTitleID": "0400486024DEC000",
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: plistURL)

        // Without registry entry -> standard nxnative.
        XCTAssertEqual(try MacGameBundle.read(app).upstream, .nxnative)

        // After recording Kid with Sword -> MacGameBundle recognizes .kidWithSword without mutating Info.plist.
        BuiltUpstreamRegistry.record(appPath: app.path, titleID: "0400486024DEC000", upstream: .kidWithSword)
        XCTAssertEqual(try MacGameBundle.read(app).upstream, .kidWithSword)

        // Rebuilding with standard nxnative clears stale variant attribution.
        BuiltUpstreamRegistry.record(appPath: app.path, titleID: "0400486024DEC000", upstream: .nxnative)
        XCTAssertEqual(try MacGameBundle.read(app).upstream, .nxnative)

        // Recording No Lag Kart, then mutating Info.plist size/mtime outside launcher invalidates attribution.
        BuiltUpstreamRegistry.record(appPath: app.path, titleID: "0400486024DEC000", upstream: .noLagKart)
        XCTAssertEqual(try MacGameBundle.read(app).upstream, .noLagKart)
        var mutated = plist
        mutated["CFBundleShortVersionString"] = "2.0.0"
        try PropertyListSerialization.data(fromPropertyList: mutated, format: .xml, options: 0).write(to: plistURL)
        XCTAssertEqual(try MacGameBundle.read(app).upstream, .nxnative)
    }

    func testOneGameIPASeparateRomfsArgumentsEnvironmentAndStaging() throws {
        let scriptRoot = temporary.appendingPathComponent("kws-romfs-probe", isDirectory: true)
        try FileManager.default.createDirectory(at: scriptRoot.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        let scriptURL = scriptRoot.appendingPathComponent("scripts/build_ipa_from_nsp.py")
        try Data("# no romfs flag\n".utf8).write(to: scriptURL)
        XCTAssertFalse(RepoLayout.supportsRomfsMode(scriptRoot.path))
        try Data("# '--romfs' ('bundle', 'separate')\n".utf8).write(to: scriptURL)
        XCTAssertTrue(RepoLayout.supportsRomfsMode(scriptRoot.path))

        XCTAssertEqual(
            OneGameIPA.arguments(ipa: "/tmp/out.ipa", bundleID: "org.nxnative.test", separateRomfs: true),
            ["--platform", "ios", "--romfs", "separate", "-o", "/tmp/out.ipa", "--bundle-id", "org.nxnative.test"]
        )
        XCTAssertEqual(
            OneGameIPA.arguments(ipa: "/tmp/out.ipa", bundleID: nil, separateRomfs: true, includeRomfsFlag: false),
            ["--platform", "ios", "-o", "/tmp/out.ipa"]
        )
        XCTAssertEqual(OneGameIPA.environment(separateRomfs: true), ["DM_COPY_ROMFS": "NO"])
        XCTAssertEqual(OneGameIPA.environment(separateRomfs: false), ["DM_FULL_ROMFS": "1"])

        let outDir = temporary.appendingPathComponent("out", isDirectory: true)
        let workDir = outDir.appendingPathComponent("0400486024DEC000_kidwithsword_build", isDirectory: true)
        let extractedImg = workDir.appendingPathComponent("extract/v131072/RomFS.img")
        try FileManager.default.createDirectory(at: extractedImg.deletingLastPathComponent(), withIntermediateDirectories: true)
        let payload = Data("DMROMFS1synthetic-oot-romfs".utf8)
        try payload.write(to: extractedImg)

        let ipaPath = outDir.appendingPathComponent("0400486024DEC000-kidwithsword.ipa").path
        XCTAssertEqual(
            OneGameIPA.separateRomfsDirectory(forIPA: ipaPath),
            outDir.appendingPathComponent("0400486024DEC000-kidwithsword-romfs").path
        )
        XCTAssertEqual(OneGameIPA.locateExtractedRomFSImage(in: workDir.path), extractedImg.path)

        let stagedPath = try XCTUnwrap(OneGameIPA.stageSeparateRomFSImage(workDir: workDir.path, ipaPath: ipaPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: extractedImg.path), "Extracted RomFS.img must remain for fast rebuilds")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: stagedPath)), payload)

        // Cross-volume fallback must delete any stale `<ipa-stem>-romfs/romfs.img` and empty directory instead of leaving old images behind.
        try Data("stale-old-romfs".utf8).write(to: URL(fileURLWithPath: stagedPath))
        let fallbackPath = OneGameIPA.stageSeparateRomFSImage(workDir: workDir.path, ipaPath: ipaPath, sameVolumeOverride: false)
        XCTAssertEqual(fallbackPath, extractedImg.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: OneGameIPA.separateRomfsDirectory(forIPA: ipaPath)))

        // Direct cleanup helper removes staged image and empty directory, while keeping unrelated files in the directory.
        let restagedPath = try XCTUnwrap(OneGameIPA.stageSeparateRomFSImage(workDir: workDir.path, ipaPath: ipaPath))
        XCTAssertEqual(restagedPath, stagedPath)
        let dirURL = URL(fileURLWithPath: OneGameIPA.separateRomfsDirectory(forIPA: ipaPath), isDirectory: true)
        let markerURL = dirURL.appendingPathComponent("README.txt")
        try Data("keep".utf8).write(to: markerURL)
        OneGameIPA.cleanupSeparateRomFSArtifacts(forIPA: ipaPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
        try FileManager.default.removeItem(at: markerURL)
        OneGameIPA.cleanupSeparateRomFSArtifacts(forIPA: ipaPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dirURL.path))
    }
}
