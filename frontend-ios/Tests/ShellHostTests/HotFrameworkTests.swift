import Foundation
import Testing
@testable import ShellHost

@MainActor @Suite struct HotFrameworkTests {
    private let secondTitleID = "01007EF00011E000"

    private func writeFramework(in parent: URL, folder: String? = nil, titleID: String = Fixtures.orbit,
                                name: String = "Orbit Fixture", builtAt: String? = nil,
                                executableBytes: String = "macho-placeholder") throws -> URL {
        let fwFolder = folder ?? "DmGame\(titleID).framework"
        let fw = parent.appendingPathComponent(fwFolder, isDirectory: true)
        let source = Fixtures.gamesURL.appendingPathComponent(Fixtures.orbit)
        var manifest = try String(contentsOf: source.appendingPathComponent("game.manifest.json"), encoding: .utf8)
        let exeName = "DmGame\(titleID)"
        manifest = manifest
            .replacingOccurrences(of: Fixtures.orbit, with: titleID)
            .replacingOccurrences(of: "Orbit Fixture", with: name)
            .replacingOccurrences(of: "\"DmGame.framework\"", with: "\"\(fwFolder)\"")
            .replacingOccurrences(of: "\"DmGame\"", with: "\"\(exeName)\"")
            .replacingOccurrences(of: "\"FR\"", with: "\"FH\"")
        if let builtAt {
            manifest = manifest.replacingOccurrences(of: "\"schema\": 1,", with: "\"schema\": 1,\n  \"built_at\": \"\(builtAt)\",")
        }
        var launcher = try String(contentsOf: source.appendingPathComponent("launcher.json"), encoding: .utf8)
        launcher = launcher.replacingOccurrences(of: Fixtures.orbit, with: titleID)

        let fm = FileManager.default
        try fm.createDirectory(at: fw.appendingPathComponent("dm", isDirectory: true), withIntermediateDirectories: true)
        try Data(manifest.utf8).write(to: fw.appendingPathComponent("game.manifest.json"))
        try Data(launcher.utf8).write(to: fw.appendingPathComponent("dm/launcher.json"))
        try Data(executableBytes.utf8).write(to: fw.appendingPathComponent(exeName))
        return fw
    }

    @Test func provisioningTeamIdentifierAndBeaconRoundTrip() throws {
        let box = try FrameworkBox()
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        let plist: [String: Any] = [
            "TeamIdentifier": ["TEAM123456"],
            "ExpirationDate": expiry,
        ]
        let xml = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        var cmsWrapped = Data([0x30, 0x82, 0x01, 0x00, 0x06, 0x09])
        cmsWrapped.append(xml)
        cmsWrapped.append(contentsOf: [0x00, 0x00])
        #expect(ProvisioningProfile.teamIdentifier(fromProfile: cmsWrapped) == "TEAM123456")
        #expect(ProvisioningProfile.expiration(fromProfile: cmsWrapped) == expiry)

        let entOnly: [String: Any] = ["Entitlements": ["com.apple.developer.team-identifier": "ENT9876543"]]
        let entData = try PropertyListSerialization.data(fromPropertyList: entOnly, format: .binary, options: 0)
        #expect(ProvisioningProfile.teamIdentifier(fromProfile: entData) == "ENT9876543")

        let sampleSHA1 = String(repeating: "A", count: 40)
        let beacon = ShellHostBeacon(bundleID: "org.nxnative.shell.TEAM123456",
                                     teamID: "TEAM123456", chain: "b-3f9a2c", version: "1.4.0",
                                     expiresAtEpoch: Int64(expiry.timeIntervalSince1970),
                                     allowsHotPush: true,
                                     certSHA1: sampleSHA1)
        #expect(beacon.glueVersion == 3)
        #expect(beacon.allowsHotPush == true)
        #expect(beacon.certSHA1 == sampleSHA1)
        let encoded = try JSONEncoder().encode(beacon)
        let decoded = try JSONDecoder().decode(ShellHostBeacon.self, from: encoded)
        #expect(decoded == beacon)

        ShellHostBeacon.write(to: box.documents)
        let writtenURL = box.documents.appendingPathComponent(ShellHostBeacon.fileName)
        let writtenBeacon = try JSONDecoder().decode(ShellHostBeacon.self, from: Data(contentsOf: writtenURL))
        #expect(writtenBeacon.schema == 1)
        #expect(writtenBeacon.glueVersion == 3)
        #expect(writtenBeacon.allowsHotPush == false)
    }

    @Test func provisioningProfileHotFrameworkEligibilityRequiresDevelopmentGetTaskAllow() throws {
        let devProfile: [String: Any] = [
            "TeamIdentifier": ["TEAM123456"],
            "Entitlements": ["get-task-allow": true],
        ]
        let devData = try PropertyListSerialization.data(fromPropertyList: devProfile, format: .xml, options: 0)
        #expect(ProvisioningProfile.allowsHotFrameworkLoading(fromProfile: devData))

        let distProfile: [String: Any] = [
            "TeamIdentifier": ["TEAM123456"],
            "Entitlements": ["get-task-allow": false],
        ]
        let distData = try PropertyListSerialization.data(fromPropertyList: distProfile, format: .xml, options: 0)
        #expect(!ProvisioningProfile.allowsHotFrameworkLoading(fromProfile: distData))

        let noEntitlementProfile: [String: Any] = [
            "TeamIdentifier": ["TEAM123456"],
            "Entitlements": [:],
        ]
        let noEntData = try PropertyListSerialization.data(fromPropertyList: noEntitlementProfile, format: .xml, options: 0)
        #expect(!ProvisioningProfile.allowsHotFrameworkLoading(fromProfile: noEntData))

        let enterpriseProfile: [String: Any] = [
            "TeamIdentifier": ["TEAM123456"],
            "ProvisionsAllDevices": true,
            "Entitlements": ["get-task-allow": true],
        ]
        let entData = try PropertyListSerialization.data(fromPropertyList: enterpriseProfile, format: .xml, options: 0)
        #expect(!ProvisioningProfile.allowsHotFrameworkLoading(fromProfile: entData))
        #expect(!ProvisioningProfile.allowsHotFrameworkLoading(fromProfile: Data()))

        let box = try FrameworkBox()
        let appBundle = box.root.appendingPathComponent("DmShell.app", isDirectory: true)
        let bundledExe = appBundle.appendingPathComponent("Frameworks/DmGame.framework/DmGame")
        try box.write("bundled", to: bundledExe)
        #expect(FrameworkSignature.preflightExternal(executable: bundledExe, appBundleURL: appBundle,
                                                   hostTeamID: "TEAM123456", allowsHotLoading: false) == nil,
                "embedded frameworks inside App/Frameworks stay allowed even without get-task-allow")

        let externalExe = box.documents.appendingPathComponent("Frameworks/DmGame.framework/DmGame")
        try box.write("external", to: externalExe)
        let refusal = FrameworkSignature.preflightExternal(executable: externalExe, appBundleURL: appBundle,
                                                           hostTeamID: nil, allowsHotLoading: false)
        #expect(refusal == hostText("This app signature does not support loading games from Documents/Frameworks. Reinstall the app from NX2Apple on your computer."))
    }

    @Test func stagedFrameworkPromotesOnlyWhenReadyAndFootprintMatch() throws {
        let box = try FrameworkBox()
        let hotRoot = box.documents.appendingPathComponent("Frameworks", isDirectory: true)
        let fm = FileManager.default

        // 1. Fresh staging without .ready stays untouched (transfer still in progress).
        let inFlight = hotRoot.appendingPathComponent(".staging-\(Fixtures.orbit)-inflight", isDirectory: true)
        _ = try writeFramework(in: inFlight, titleID: Fixtures.orbit)
        GameCatalogue.promoteStagedFrameworks(in: hotRoot, now: Date(), staleAge: 3600)
        #expect(fm.fileExists(atPath: inFlight.path))
        #expect(!fm.fileExists(atPath: hotRoot.appendingPathComponent("DmGame\(Fixtures.orbit).framework").path))

        // 2. Staging with a mismatched byte count in .ready is rejected and cleaned up.
        let mismatched = hotRoot.appendingPathComponent(".staging-\(secondTitleID)-badbytes", isDirectory: true)
        let badFW = try writeFramework(in: mismatched, titleID: secondTitleID, name: "Zelda Fixture")
        let actualBad = try #require(GameCatalogue.frameworkFootprint(at: badFW))
        let wrongReady = HotFrameworkReady(titleID: secondTitleID, files: actualBad.files, bytes: actualBad.bytes + 99)
        try JSONEncoder().encode(wrongReady).write(to: mismatched.appendingPathComponent(".ready"))
        GameCatalogue.promoteStagedFrameworks(in: hotRoot)
        #expect(!fm.fileExists(atPath: mismatched.path))
        #expect(!fm.fileExists(atPath: hotRoot.appendingPathComponent("DmGame\(secondTitleID).framework").path))

        // 3. Valid staging with matching .ready promotes atomically and removes superseded in-flight folder.
        let validStaging = hotRoot.appendingPathComponent(".staging-\(Fixtures.orbit)-complete", isDirectory: true)
        let stagedFW = try writeFramework(in: validStaging, titleID: Fixtures.orbit, name: "Orbit Hot", builtAt: "2026-11-12T12:00:00Z")
        let footprint = try #require(GameCatalogue.frameworkFootprint(at: stagedFW))
        let ready = HotFrameworkReady(titleID: Fixtures.orbit, files: footprint.files, bytes: footprint.bytes)
        try JSONEncoder().encode(ready).write(to: validStaging.appendingPathComponent(".ready"))

        let entries = GameCatalogue.scan(root: box.frameworks, hotRoot: hotRoot)
        #expect(entries.count == 1)
        #expect(entries.first?.title == "Orbit Hot")
        #expect(fm.fileExists(atPath: hotRoot.appendingPathComponent("DmGame\(Fixtures.orbit).framework").path))
        #expect(!fm.fileExists(atPath: validStaging.path))
        #expect(!fm.fileExists(atPath: inFlight.path), "superseded incomplete staging for the promoted title is cleaned up")
    }

    @Test func newerHotBuildOverridesBundledWhileEqualOrNewerBundledReclaimsSpace() throws {
        let box = try FrameworkBox()
        let hotRoot = box.documents.appendingPathComponent("Frameworks", isDirectory: true)
        let fm = FileManager.default

        _ = try writeFramework(in: box.frameworks, titleID: Fixtures.orbit, name: "Orbit v1", builtAt: "2026-11-10T10:00:00Z")
        let hotOrbit = try writeFramework(in: hotRoot, titleID: Fixtures.orbit, name: "Orbit v2 Hot", builtAt: "2026-11-11T10:00:00Z")
        _ = try writeFramework(in: hotRoot, titleID: secondTitleID, name: "Extra Hot Game", builtAt: "2026-11-11T11:00:00Z")

        let firstScan = GameCatalogue.scan(root: box.frameworks, hotRoot: hotRoot)
        #expect(firstScan.count == 2)
        let orbitEntry = try #require(firstScan.first { $0.id == Fixtures.orbit })
        #expect(orbitEntry.title == "Orbit v2 Hot")
        #expect(orbitEntry.directory.standardizedFileURL == hotOrbit.standardizedFileURL)

        // Later full app re-sign / rebuild embeds the same (or newer) build into App/Frameworks: redundant hot copy is removed.
        try fm.removeItem(at: box.frameworks.appendingPathComponent("DmGame\(Fixtures.orbit).framework"))
        let bundledSame = try writeFramework(in: box.frameworks, titleID: Fixtures.orbit, name: "Orbit v2 Bundled", builtAt: "2026-11-11T10:00:00Z")
        let secondScan = GameCatalogue.scan(root: box.frameworks, hotRoot: hotRoot)
        let updatedOrbit = try #require(secondScan.first { $0.id == Fixtures.orbit })
        #expect(updatedOrbit.title == "Orbit v2 Bundled")
        #expect(updatedOrbit.directory.standardizedFileURL == bundledSame.standardizedFileURL)
        #expect(!fm.fileExists(atPath: hotOrbit.path), "redundant hot framework is reclaimed once the app bundle carries the build")
    }

    @Test func deletingHotOverriddenGameRemovesHotFrameworkAndSuppressesOlderBundledCopy() throws {
        let box = try Sandbox()
        let hotRoot = box.root.appendingPathComponent("Documents/Frameworks", isDirectory: true)
        _ = try box.giveAppData()
        // Sandbox.games holds the bundled Orbit fixture (builtAt nil); place a newer hot framework in hotRoot.
        let hotFW = try writeFramework(in: hotRoot, titleID: Fixtures.orbit, name: "Orbit Hot Build", builtAt: "2026-11-12T10:00:00Z")
        var cfg = box.config()
        cfg.hotFrameworksRoot = hotRoot

        let model = ShellHostModel(config: cfg)
        #expect(model.details.first { $0.id == Fixtures.orbit }?.game.title == "Orbit Hot Build")

        model.deleteGame(Fixtures.orbit, saves: true)
        #expect(!FileManager.default.fileExists(atPath: hotFW.path), "writable hot framework is physically deleted")
        #expect(!model.details.contains { $0.id == Fixtures.orbit }, "older bundled copy does not reappear right after delete")
        #expect(!ShellHostModel(config: cfg).details.contains { $0.id == Fixtures.orbit }, "stays deleted across relaunch")
    }

    #if os(macOS)
    @Test func frameworkSignatureInspectsRealMachOBinariesAndEnforcesTeamMatch() throws {
        let box = try FrameworkBox()
        let appBundle = box.root.appendingPathComponent("DmShell.app", isDirectory: true)
        let bundledExe = appBundle.appendingPathComponent("Frameworks/DmGame.framework/DmGame")
        try box.write("bundled", to: bundledExe)
        #expect(FrameworkSignature.preflightExternal(executable: bundledExe, appBundleURL: appBundle, hostTeamID: "TEAM123456") == nil,
                "frameworks inside DmShell.app bypass external preflight")

        let src = box.root.appendingPathComponent("tiny.c")
        let dylib = box.root.appendingPathComponent("Documents/Frameworks/DmGame.framework/DmGame")
        try FileManager.default.createDirectory(at: dylib.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("int dm_test_sym(void) { return 7; }\n".utf8).write(to: src)

        let clang = Process()
        clang.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        clang.arguments = ["-dynamiclib", src.path, "-o", dylib.path]
        try clang.run()
        clang.waitUntilExit()
        #expect(clang.terminationStatus == 0)

        // Default clang output on macOS arm64 carries an ad-hoc signature (hasCodeSignature == true, teamID == nil).
        let adhocInfo = try #require(FrameworkSignature.inspect(executable: dylib))
        #expect(adhocInfo.hasCodeSignature)
        #expect(adhocInfo.teamID == nil)

        // TrollStore / no host provisioning profile accepts ad-hoc signed external frameworks.
        #expect(FrameworkSignature.preflightExternal(executable: dylib, appBundleURL: appBundle, hostTeamID: nil) == nil)
        #expect(FrameworkSignature.preflightExternal(executable: dylib, appBundleURL: appBundle, hostTeamID: "") == nil)

        // Team-signed host refuses an ad-hoc external framework cleanly before dlopen can crash.
        let teamMismatch = FrameworkSignature.preflightExternal(executable: dylib, appBundleURL: appBundle, hostTeamID: "TEAM123456")
        #expect(teamMismatch?.contains("ad-hoc") == true)
        #expect(teamMismatch?.contains("TEAM123456") == true)

        // Strip signature completely -> unsigned refusal even without a host team ID.
        let strip = Process()
        strip.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        strip.arguments = ["--remove-signature", dylib.path]
        try strip.run()
        strip.waitUntilExit()
        #expect(strip.terminationStatus == 0)
        let strippedInfo = try #require(FrameworkSignature.inspect(executable: dylib))
        #expect(!strippedInfo.hasCodeSignature)
        #expect(FrameworkSignature.preflightExternal(executable: dylib, appBundleURL: appBundle, hostTeamID: nil)?.contains("unsigned") == true)
    }
    #endif

    @Test func reinstallingLegacyBundledFrameworkWithoutBuiltAtDiscardsOlderHotCopy() throws {
        let box = try FrameworkBox()
        let hotRoot = box.documents.appendingPathComponent("Frameworks", isDirectory: true)
        let fm = FileManager.default
        let olderDate = Date(timeIntervalSince1970: 1_700_000_000)
        let newerDate = Date(timeIntervalSince1970: 1_700_003_600)

        func setMtime(_ fw: URL, titleID: String, date: Date) throws {
            let attrs: [FileAttributeKey: Any] = [.modificationDate: date]
            try fm.setAttributes(attrs, ofItemAtPath: fw.appendingPathComponent("DmGame\(titleID)").path)
            try fm.setAttributes(attrs, ofItemAtPath: fw.appendingPathComponent("game.manifest.json").path)
        }

        // Case A: overwriting with a legacy IPA lacking built_at whose bundled framework is newer on disk reclaims older hot copy.
        let hotOrbit = try writeFramework(in: hotRoot, titleID: Fixtures.orbit, name: "Orbit Hot Old", builtAt: "2026-11-10T10:00:00Z")
        try setMtime(hotOrbit, titleID: Fixtures.orbit, date: olderDate)
        let bundledOrbit = try writeFramework(in: box.frameworks, titleID: Fixtures.orbit, name: "Orbit Legacy IPA", builtAt: nil)
        try setMtime(bundledOrbit, titleID: Fixtures.orbit, date: newerDate)

        // Case B: pushing a newer hot framework on top of an older legacy bundled IPA keeps the hot copy.
        let bundledSecond = try writeFramework(in: box.frameworks, titleID: secondTitleID, name: "Second Legacy Bundled", builtAt: nil)
        try setMtime(bundledSecond, titleID: secondTitleID, date: olderDate)
        let hotSecond = try writeFramework(in: hotRoot, titleID: secondTitleID, name: "Second Hot New", builtAt: "2026-11-12T10:00:00Z")
        try setMtime(hotSecond, titleID: secondTitleID, date: newerDate)

        let scanned = GameCatalogue.scan(root: box.frameworks, hotRoot: hotRoot)
        let orbitEntry = try #require(scanned.first { $0.id == Fixtures.orbit })
        #expect(orbitEntry.title == "Orbit Legacy IPA")
        #expect(orbitEntry.directory.standardizedFileURL == bundledOrbit.standardizedFileURL)
        #expect(!fm.fileExists(atPath: hotOrbit.path))

        let secondEntry = try #require(scanned.first { $0.id == secondTitleID })
        #expect(secondEntry.title == "Second Hot New")
        #expect(secondEntry.directory.standardizedFileURL == hotSecond.standardizedFileURL)
        #expect(fm.fileExists(atPath: hotSecond.path))
    }

    @Test func resigningOlderBundledFrameworkWithNewerDiskMtimeKeepsNewerHotBuild() throws {
        let box = try FrameworkBox()
        let hotRoot = box.documents.appendingPathComponent("Frameworks", isDirectory: true)
        let fm = FileManager.default

        let bundledOrbit = try writeFramework(in: box.frameworks, titleID: Fixtures.orbit, name: "Orbit Re-signed Bundled", builtAt: "2026-11-10T10:00:00Z")
        let hotOrbit = try writeFramework(in: hotRoot, titleID: Fixtures.orbit, name: "Orbit Newer Hot", builtAt: "2026-11-11T10:00:00Z")

        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_010_000)],
                             ofItemAtPath: bundledOrbit.appendingPathComponent("DmGame\(Fixtures.orbit)").path)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
                             ofItemAtPath: hotOrbit.appendingPathComponent("DmGame\(Fixtures.orbit)").path)

        let scanned = GameCatalogue.scan(root: box.frameworks, hotRoot: hotRoot)
        let orbitEntry = try #require(scanned.first { $0.id == Fixtures.orbit })
        #expect(orbitEntry.title == "Orbit Newer Hot")
        #expect(orbitEntry.directory.standardizedFileURL == hotOrbit.standardizedFileURL)
        #expect(fm.fileExists(atPath: hotOrbit.path))
    }

    @Test func promoteStagedFrameworksRescuesBackupMslOnlyOnMatchingChain() throws {
        let box = try FrameworkBox()
        let fm = FileManager.default
        let hotRoot = box.documents.appendingPathComponent("Frameworks", isDirectory: true)
        let dataRoot = box.documents.appendingPathComponent("games", isDirectory: true)
        let chain = "b-3f9a2c"

        // Matching chain: old hot framework holds loose msl/, staged hot framework stripped msl/.
        let installedFW = try writeFramework(in: hotRoot, titleID: Fixtures.orbit, name: "Orbit Old", builtAt: "2026-11-10T10:00:00Z")
        let oldShader = installedFW.appendingPathComponent("msl/\(chain)/cached.metallib")
        try box.write("rescued-shader", to: oldShader)

        let stagingMatch = hotRoot.appendingPathComponent(".staging-\(Fixtures.orbit)-match", isDirectory: true)
        let stagedMatchFW = try writeFramework(in: stagingMatch, titleID: Fixtures.orbit, name: "Orbit New", builtAt: "2026-11-11T10:00:00Z")
        let footMatch = try #require(GameCatalogue.frameworkFootprint(at: stagedMatchFW))
        try JSONEncoder().encode(HotFrameworkReady(titleID: Fixtures.orbit, files: footMatch.files, bytes: footMatch.bytes))
            .write(to: stagingMatch.appendingPathComponent(".ready"))

        GameCatalogue.promoteStagedFrameworks(in: hotRoot, gameDataRoot: dataRoot)
        let rescuedShader = dataRoot.appendingPathComponent("\(Fixtures.orbit)/msl/\(chain)/cached.metallib")
        #expect(try String(contentsOf: rescuedShader, encoding: .utf8) == "rescued-shader")
        #expect(!fm.fileExists(atPath: stagingMatch.path))
        #expect(!fm.fileExists(atPath: installedFW.appendingPathComponent("msl").path))

        // Different chain: old backup/msl belongs to a mismatched chain and must not be rescued into gameDataRoot.
        let stagingMismatch = hotRoot.appendingPathComponent(".staging-\(Fixtures.orbit)-mismatch", isDirectory: true)
        let stagedMismatchFW = try writeFramework(in: stagingMismatch, titleID: Fixtures.orbit, name: "Orbit Chain2", builtAt: "2026-11-12T10:00:00Z")
        let mismatchManifestURL = stagedMismatchFW.appendingPathComponent("game.manifest.json")
        let mismatchManifest = try String(contentsOf: mismatchManifestURL, encoding: .utf8)
            .replacingOccurrences(of: chain, with: "b-other9")
        try Data(mismatchManifest.utf8).write(to: mismatchManifestURL)
        try box.write("old-chain-shader", to: installedFW.appendingPathComponent("msl/\(chain)/stale.metallib"))
        let footMismatch = try #require(GameCatalogue.frameworkFootprint(at: stagedMismatchFW))
        try JSONEncoder().encode(HotFrameworkReady(titleID: Fixtures.orbit, files: footMismatch.files, bytes: footMismatch.bytes))
            .write(to: stagingMismatch.appendingPathComponent(".ready"))

        GameCatalogue.promoteStagedFrameworks(in: hotRoot, gameDataRoot: dataRoot)
        let unexpectedStale = dataRoot.appendingPathComponent("\(Fixtures.orbit)/msl/\(chain)/stale.metallib")
        #expect(!fm.fileExists(atPath: unexpectedStale.path))
    }

    /// Synthesizes a minimal valid 64-bit arm64 Mach-O binary carrying `LC_CODE_SIGNATURE` + `CS_CodeDirectory` v0x20200
    /// so `FrameworkSignature.inspect` and `ProvisioningProfile` run identically on both macOS and iOS Simulator without external tools.
    private static func makeMinimalSignedMachO(identifier: String, teamID: String) -> Data {
        func appendU32LE(_ d: inout Data, _ v: UInt32) {
            d.append(contentsOf: [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)])
        }
        func appendU32BE(_ d: inout Data, _ v: UInt32) {
            d.append(contentsOf: [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)])
        }

        let identBytes = Data(identifier.utf8) + Data([0])
        let teamBytes = Data(teamID.utf8) + Data([0])
        let cdHeaderLen: UInt32 = 52
        let identOff = cdHeaderLen
        let teamOff = identOff + UInt32(identBytes.count)
        let hashOff = teamOff + UInt32(teamBytes.count)
        let cdLen = hashOff + 32

        var cd = Data()
        appendU32BE(&cd, 0xfade_0c02) // CSMAGIC_CODEDIRECTORY
        appendU32BE(&cd, cdLen)
        appendU32BE(&cd, 0x0002_0200) // version supporting teamOffset
        appendU32BE(&cd, 0)           // flags
        appendU32BE(&cd, hashOff)
        appendU32BE(&cd, identOff)
        appendU32BE(&cd, 0)           // nSpecialSlots
        appendU32BE(&cd, 1)           // nCodeSlots
        appendU32BE(&cd, 64)          // codeLimit
        cd.append(contentsOf: [32, 2, 0, 14]) // hashSize=32, SHA-256, platform=0, pageSize=2^14
        appendU32BE(&cd, 0)           // spare2
        appendU32BE(&cd, 0)           // scatterOffset
        appendU32BE(&cd, teamOff)     // teamOffset
        cd.append(identBytes)
        cd.append(teamBytes)
        cd.append(Data(repeating: 0xaa, count: 32))

        let sbLen = UInt32(20 + cd.count)
        var sb = Data()
        appendU32BE(&sb, 0xfade_0cc0) // CSMAGIC_EMBEDDED_SIGNATURE
        appendU32BE(&sb, sbLen)
        appendU32BE(&sb, 1)           // count = 1
        appendU32BE(&sb, 0)           // CSSLOT_CODEDIRECTORY
        appendU32BE(&sb, 20)          // offset
        sb.append(cd)

        var macho = Data()
        appendU32LE(&macho, 0xfeed_facf) // MH_MAGIC_64
        appendU32LE(&macho, 0x0100_000c) // CPU_TYPE_ARM64
        appendU32LE(&macho, 0)           // cpusubtype
        appendU32LE(&macho, 2)           // MH_EXECUTE
        appendU32LE(&macho, 1)           // ncmds = 1
        appendU32LE(&macho, 16)          // sizeofcmds = 16
        appendU32LE(&macho, 0)           // flags
        appendU32LE(&macho, 0)           // reserved
        appendU32LE(&macho, 0x0000_001d) // LC_CODE_SIGNATURE
        appendU32LE(&macho, 16)          // cmdsize
        appendU32LE(&macho, 64)          // dataoff
        appendU32LE(&macho, sbLen)       // datasize
        if macho.count < 64 {
            macho.append(Data(repeating: 0, count: 64 - macho.count))
        }
        macho.append(sb)
        return macho
    }

    @Test func liveContainerGuestEnvironmentAllowsHotLoadingAndPrefersExecutableTeamOverStaleProfile() throws {
        let box = try FrameworkBox()
        let fm = FileManager.default

        func makeGuestApp(named folderName: String, profile: [String: Any]? = nil) throws -> Bundle {
            let appURL = box.root.appendingPathComponent(folderName, isDirectory: true)
            try fm.createDirectory(at: appURL, withIntermediateDirectories: true)
            let appInfo: [String: Any] = [
                "CFBundleExecutable": "DmShell",
                "CFBundleIdentifier": "org.nxnative.shell.guest",
                "CFBundleName": "NX2Apple",
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": "1.5.1",
                "DMChain": "3f9a2c",
            ]
            try PropertyListSerialization.data(fromPropertyList: appInfo, format: .xml, options: 0)
                .write(to: appURL.appendingPathComponent("Info.plist"))
            try Self.makeMinimalSignedMachO(identifier: "org.nxnative.shell.guest", teamID: "TEAMLCNEW1")
                .write(to: appURL.appendingPathComponent("DmShell"))
            if let profile {
                try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
                    .write(to: appURL.appendingPathComponent("embedded.mobileprovision"))
            }
            return try #require(Bundle(url: appURL))
        }

        let lcEnv = ["LC_HOME_PATH": "/var/mobile/Containers/Data/Application/LIVECONTAINER/Documents/Data/Application/GUEST"]
        let lpEnv = ["LP_HOME_PATH": "/var/mobile/Containers/Data/Application/LIVEPROCESS/Documents"]

        // 1. Unsigned IPA imported into LiveContainer has no embedded.mobileprovision:
        //    outside LiveContainer -> hot loading stays blocked; inside LiveContainer -> allowed and team comes from Mach-O.
        let guestBundle = try makeGuestApp(named: "GuestNoProfile.app")
        #expect(!ProvisioningProfile.isRunningInLiveContainer(environment: [:]))
        #expect(ProvisioningProfile.isRunningInLiveContainer(environment: lcEnv))
        #expect(ProvisioningProfile.isRunningInLiveContainer(environment: lpEnv))
        #expect(!ProvisioningProfile.bundledAllowsHotFrameworkLoading(bundle: guestBundle, environment: [:], fileManager: fm))
        #expect(ProvisioningProfile.bundledAllowsHotFrameworkLoading(bundle: guestBundle, environment: lcEnv, fileManager: fm))
        #expect(ProvisioningProfile.bundledTeamIdentifier(bundle: guestBundle, environment: lcEnv, fileManager: fm) == "TEAMLCNEW1")

        ShellHostBeacon.write(to: box.documents, bundle: guestBundle, environment: lcEnv, fileManager: fm)
        let beaconURL = box.documents.appendingPathComponent(ShellHostBeacon.fileName)
        let lcBeacon = try JSONDecoder().decode(ShellHostBeacon.self, from: Data(contentsOf: beaconURL))
        #expect(lcBeacon.allowsHotPush == true)
        #expect(lcBeacon.teamID == "TEAMLCNEW1")

        // 2. Guest IPA carrying a stale build-time embedded.mobileprovision from another team (`TEAMOLD999`, get-task-allow=false)
        //    re-signed by LiveContainer for `TEAMLCNEW1`: executable team wins and stale profile does not block hot loading.
        let staleBundle = try makeGuestApp(named: "GuestStaleProfile.app", profile: [
            "TeamIdentifier": ["TEAMOLD999"],
            "Entitlements": ["get-task-allow": false],
        ])
        #expect(ProvisioningProfile.bundledTeamIdentifier(bundle: staleBundle, environment: lcEnv, fileManager: fm) == "TEAMLCNEW1")
        #expect(ProvisioningProfile.bundledAllowsHotFrameworkLoading(bundle: staleBundle, environment: lcEnv, fileManager: fm))
        #expect(!ProvisioningProfile.bundledAllowsHotFrameworkLoading(bundle: staleBundle, environment: [:], fileManager: fm))

        // 3. Same-team distribution profile with get-task-allow=false stays respected.
        let sameTeamDistBundle = try makeGuestApp(named: "GuestSameTeamDist.app", profile: [
            "TeamIdentifier": ["TEAMLCNEW1"],
            "Entitlements": ["get-task-allow": false],
        ])
        #expect(!ProvisioningProfile.bundledAllowsHotFrameworkLoading(bundle: sameTeamDistBundle, environment: lcEnv, fileManager: fm))
    }
}
