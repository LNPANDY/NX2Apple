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

        let beacon = ShellHostBeacon(glueVersion: 1, bundleID: "org.nxnative.shell.TEAM123456",
                                     teamID: "TEAM123456", chain: "b-3f9a2c", version: "1.4.0",
                                     expiresAtEpoch: Int64(expiry.timeIntervalSince1970))
        let encoded = try JSONEncoder().encode(beacon)
        let decoded = try JSONDecoder().decode(ShellHostBeacon.self, from: encoded)
        #expect(decoded == beacon)
        _ = box
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
}
