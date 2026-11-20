import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import NXCore
@testable import NXModel

final class FrameworkExportBannerTests: XCTestCase {
    private var temporary: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxmodel-fw-banner-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporary)
    }

    private func makeWidePNG() throws -> Data {
        let cs = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: 120, height: 60, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(CGColor(colorSpace: cs, components: [0.1, 0.7, 0.3, 1.0])!)
        ctx.fill(CGRect(x: 0, y: 0, width: 120, height: 60))
        let img = try XCTUnwrap(ctx.makeImage())
        let out = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    func testStandaloneFrameworkExportBackfillsBannerAndCreates512SquareIcon() throws {
        let tid = "0400486024DEC000"
        let workDir = temporary.appendingPathComponent("work")
        let fw = workDir.appendingPathComponent("shell-framework/DmGame\(tid).framework")
        let outDir = temporary.appendingPathComponent("out")
        let banners = temporary.appendingPathComponent("banners")
        try FileManager.default.createDirectory(at: fw, withIntermediateDirectories: true)
        try Data("bin".utf8).write(to: fw.appendingPathComponent("DmGame\(tid)"))
        let plist: [String: Any] = ["CFBundleExecutable": "DmGame\(tid)", "DMTitleID": tid]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: fw.appendingPathComponent("Info.plist"))

        let validPNG = try makeWidePNG()
        let outcome = BuildStore.stageAndReplaceFramework(
            framework: fw.path,
            titleID: tid,
            outFolder: outDir.path,
            team: "",
            runner: SystemProcessRunner(),
            banners: banners,
            pickedBanner: nil,
            workDir: workDir.path,
            ensureBanner: { id, dir in
                BannerCache.ensureCachedBanner(titleID: id, banners: dir, fetcher: { _, _ in validPNG })
            }
        )
        XCTAssertNil(outcome.error)
        let exported = try XCTUnwrap(outcome.destPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported + "/banner.jpg"))
        let iconURL = URL(fileURLWithPath: exported + "/icon.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: iconURL.path))
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(iconURL as CFURL, nil))
        let img = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        XCTAssertEqual(img.width, 512)
        XCTAssertEqual(img.height, 512)
    }

    private final class RecordingSigningRunner: ProcessRunner, @unchecked Sendable {
        let teamID: String
        let sha1 = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        let identity: String
        private let lock = NSLock()
        private var _commands: [[String]] = []
        var commands: [[String]] { lock.lock(); defer { lock.unlock() }; return _commands }

        init(teamID: String) {
            self.teamID = teamID
            self.identity = "Apple Development: Test User (\(teamID))"
        }

        func capture(_ launch: ProcessLaunch) -> ProcessResult {
            lock.lock()
            _commands.append([launch.executable] + launch.arguments)
            lock.unlock()
            if launch.executable == "/usr/bin/security" {
                if launch.arguments.first == "find-identity" {
                    return ProcessResult(status: 0, out: "  1) \(sha1) \"\(identity)\"\n", err: "")
                }
                if launch.arguments.first == "find-certificate" {
                    return ProcessResult(
                        status: 0,
                        out: "SHA-1 hash: \(sha1)\n-----BEGIN CERTIFICATE-----\nFAKE\n-----END CERTIFICATE-----\n",
                        err: ""
                    )
                }
            }
            if launch.executable == "/usr/bin/openssl" {
                return ProcessResult(status: 0, out: "subject=CN=\(identity), OU=\(teamID), C=US\n", err: "")
            }
            return ProcessResult(status: 0, out: "", err: "")
        }

        func stream(_ launch: ProcessLaunch, line: @escaping (String) -> Void) -> Bool { true }
        func streamLines(_ launch: ProcessLaunch, started: @escaping (RunningProcess) -> Void, line: @escaping (String) -> Void) -> ProcessResult {
            ProcessResult(status: 0, out: "", err: "")
        }
        func start(_ launch: ProcessLaunch, onOutput: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) throws -> RunningProcess {
            fatalError("unexpected start in RecordingSigningRunner")
        }
    }

    private func makeDummyFramework(in workDir: URL, titleID: String) throws -> URL {
        let fw = workDir.appendingPathComponent("shell-framework/DmGame\(titleID).framework")
        try FileManager.default.createDirectory(at: fw, withIntermediateDirectories: true)
        try Data("bin".utf8).write(to: fw.appendingPathComponent("DmGame\(titleID)"))
        let plist: [String: Any] = [
            "CFBundleExecutable": "DmGame\(titleID)",
            "CFBundleIdentifier": "org.nxnative.game.\(titleID)",
            "DMTitleID": titleID,
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: fw.appendingPathComponent("Info.plist"))
        return fw
    }

    func testStandaloneFrameworkExportCodesignsWithPerTeamHostBundleIdentifier() throws {
        let tid = "01007EF00011E000"
        let team = "MG2FF22535"
        let workDir = temporary.appendingPathComponent("work-personal")
        let fw = try makeDummyFramework(in: workDir, titleID: tid)
        let outDir = temporary.appendingPathComponent("out-personal")
        let shellRoot = temporary.appendingPathComponent("shell-empty")
        let banners = temporary.appendingPathComponent("banners")
        let runner = RecordingSigningRunner(teamID: team)

        let outcome = BuildStore.stageAndReplaceFramework(
            framework: fw.path,
            titleID: tid,
            outFolder: outDir.path,
            team: team,
            shellRoot: shellRoot.path,
            runner: runner,
            banners: banners,
            pickedBanner: nil,
            workDir: workDir.path,
            ensureBanner: { _, _ in nil }
        )

        XCTAssertNil(outcome.error)
        XCTAssertNotNil(outcome.destPath)
        XCTAssertEqual(outcome.signedTeam, team)
        let signCmd = try XCTUnwrap(runner.commands.first { $0.first == "/usr/bin/codesign" }, "codesign must be invoked")
        let idIdx = try XCTUnwrap(signCmd.firstIndex(of: "--identifier"), "codesign must pass --identifier: \(signCmd)")
        XCTAssertEqual(signCmd[idIdx + 1], "org.nxnative.shell.\(team)")
    }

    func testStandaloneFrameworkExportPrefersPersistedShellBundleIDForMatchingTeamOnly() throws {
        let tid = "0100000000010000"
        let team = "MG2FF22535"
        let banners = temporary.appendingPathComponent("banners")

        // Case 1: persisted custom bundle ID for matching team wins.
        let customShell = temporary.appendingPathComponent("shell-custom")
        try ShellLibrary(bundleID: "com.example.nx2apple", team: team).save(root: customShell.path)
        let work1 = temporary.appendingPathComponent("work-1")
        let fw1 = try makeDummyFramework(in: work1, titleID: tid)
        let runner1 = RecordingSigningRunner(teamID: team)
        let out1 = BuildStore.stageAndReplaceFramework(
            framework: fw1.path,
            titleID: tid,
            outFolder: temporary.appendingPathComponent("out-1").path,
            team: team,
            shellRoot: customShell.path,
            runner: runner1,
            banners: banners,
            pickedBanner: nil,
            workDir: work1.path,
            ensureBanner: { _, _ in nil }
        )
        XCTAssertNil(out1.error)
        let signCmd1 = try XCTUnwrap(runner1.commands.first { $0.first == "/usr/bin/codesign" })
        let idIdx1 = try XCTUnwrap(signCmd1.firstIndex(of: "--identifier"), "codesign must pass --identifier: \(signCmd1)")
        XCTAssertEqual(signCmd1[idIdx1 + 1], "com.example.nx2apple")

        // Case 2: paid team installed under default org.nxnative.shell keeps default bundle ID.
        let paidShell = temporary.appendingPathComponent("shell-paid")
        try ShellLibrary(bundleID: ShellLibrary.defaultBundleID, team: team).save(root: paidShell.path)
        XCTAssertEqual(
            BuildStore.resolveFrameworkHostBundleID(team: team, shellRoot: paidShell.path),
            ShellLibrary.defaultBundleID
        )

        // Case 3: shell.json belonging to a different team does not leak across teams.
        let otherShell = temporary.appendingPathComponent("shell-other")
        try ShellLibrary(bundleID: "com.other.shell", team: "OTHER99999").save(root: otherShell.path)
        XCTAssertEqual(
            BuildStore.resolveFrameworkHostBundleID(team: team, shellRoot: otherShell.path),
            ShellLibrary.teamVariant(team: team)
        )
    }

    @MainActor func testExportFrameworkBundleFallsBackToCertifiedTeamAndDistinguishesSignedNote() throws {
        let tid = "0100535012974000"
        let team = "MG2FF22535"
        let suite = "nxmodel.fw.export.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let shellRoot = temporary.appendingPathComponent("shell-root")
        defaults.set(shellRoot.path, forKey: "shellRoot")
        final class StubRepo: RepoLocation { var path = ""; var isRepo = true; var isGit = true }
        final class StubDeps: DependencyInstalling {
            var pythonPath = "/usr/bin/python3"; var dotnetPath = "/usr/bin/true"
            var checked = true; var allPresent = true; var deps: [Dep] = []
            func isInstalling(_ id: String) -> Bool { false }
            func install(_ dep: Dep) -> Task<Void, Never> { Task {} }
        }
        final class StubEngine: EngineSyncing {
            func syncEngine(then: ((Bool) -> Void)?) -> Task<Void, Never> { then?(true); return Task {} }
        }
        let runner = RecordingSigningRunner(teamID: team)
        let repo = StubRepo()
        let deps = StubDeps()
        let engine = StubEngine()
        let devices = DeviceStore(runner: runner, defaults: defaults, listDevices: { _ in [] }, readTeams: { [] })
        let loc = Localizer(.en)
        let build = BuildStore(localizer: loc, runner: runner, repo: repo, deps: deps, engine: engine, devices: devices, defaults: defaults)
        build.outDir = temporary.appendingPathComponent("exported").path

        let workDir = temporary.appendingPathComponent("work-bundle")
        let fw = try makeDummyFramework(in: workDir, titleID: tid)
        devices.signingTeam = ""
        devices.teams = [
            SigningTeam(id: "NOCERT1234", identity: "", name: "No Cert"),
            SigningTeam(id: team, identity: runner.identity, name: "Personal", personal: true, sha1: runner.sha1),
        ]

        let finished = expectation(description: "SignedFrameworkExported")
        let token = build.$done.filter { $0 }.prefix(1).sink { _ in finished.fulfill() }
        build.exportFrameworkBundle(framework: fw.path, titleID: tid, name: "Hades")
        wait(for: [finished], timeout: 10)
        withExtendedLifetime(token) {}

        let dest = temporary.appendingPathComponent("exported/DmGame\(tid).framework").path
        XCTAssertEqual(build.exportedIPAPath, dest)
        XCTAssertEqual(build.doneNote, String(format: build.t("shell.frameworkExportDoneSigned"), team, dest))
        let signCmd = try XCTUnwrap(runner.commands.first { $0.first == "/usr/bin/codesign" })
        let idIdx = try XCTUnwrap(signCmd.firstIndex(of: "--identifier"), "codesign must pass --identifier: \(signCmd)")
        XCTAssertEqual(signCmd[idIdx + 1], "org.nxnative.shell.\(team)")
    }

    @MainActor func testExportFrameworkBundleRespectsExplicitUnsignedChoiceAndStripsSignature() throws {
        let tid = "01007EF00011E000"
        let team = "MG2FF22535"
        let suite = "nxmodel.fw.unsigned.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let shellRoot = temporary.appendingPathComponent("shell-root")
        defaults.set(shellRoot.path, forKey: "shellRoot")
        final class StubRepo: RepoLocation { var path = ""; var isRepo = true; var isGit = true }
        final class StubDeps: DependencyInstalling {
            var pythonPath = "/usr/bin/python3"; var dotnetPath = "/usr/bin/true"
            var checked = true; var allPresent = true; var deps: [Dep] = []
            func isInstalling(_ id: String) -> Bool { false }
            func install(_ dep: Dep) -> Task<Void, Never> { Task {} }
        }
        final class StubEngine: EngineSyncing {
            func syncEngine(then: ((Bool) -> Void)?) -> Task<Void, Never> { then?(true); return Task {} }
        }
        final class FailingStripRunner: ProcessRunner, @unchecked Sendable {
            private let lock = NSLock()
            private var _commands: [[String]] = []
            var commands: [[String]] { lock.lock(); defer { lock.unlock() }; return _commands }
            func capture(_ launch: ProcessLaunch) -> ProcessResult {
                lock.lock(); _commands.append([launch.executable] + launch.arguments); lock.unlock()
                // Simulate codesign --remove-signature returning non-zero on an already-unsigned binary: must not fail export.
                return ProcessResult(status: 1, out: "", err: "code object is not signed at all")
            }
            func stream(_ launch: ProcessLaunch, line: @escaping (String) -> Void) -> Bool { true }
            func streamLines(_ launch: ProcessLaunch, started: @escaping (RunningProcess) -> Void, line: @escaping (String) -> Void) -> ProcessResult {
                ProcessResult(status: 0, out: "", err: "")
            }
            func start(_ launch: ProcessLaunch, onOutput: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) throws -> RunningProcess {
                fatalError("unexpected start")
            }
        }

        let runner = FailingStripRunner()
        let devices = DeviceStore(runner: runner, defaults: defaults, listDevices: { _ in [] }, readTeams: { [] })
        let build = BuildStore(
            localizer: Localizer(.en),
            runner: runner,
            repo: StubRepo(),
            deps: StubDeps(),
            engine: StubEngine(),
            devices: devices,
            defaults: defaults
        )
        build.outDir = temporary.appendingPathComponent("exported-unsigned").path

        let workDir = temporary.appendingPathComponent("work-unsigned")
        let fw = try makeDummyFramework(in: workDir, titleID: tid)
        let sigDir = fw.appendingPathComponent("_CodeSignature")
        try FileManager.default.createDirectory(at: sigDir, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: sigDir.appendingPathComponent("CodeResources"))

        devices.teams = [
            SigningTeam(id: team, identity: "Apple Development: Test User (\(team))", name: "Personal", personal: true, sha1: "AAA"),
        ]
        devices.signingTeam = team
        devices.exportFrameworkUnsigned = true

        let finished = expectation(description: "UnsignedFrameworkExported")
        let token = build.$done.filter { $0 }.prefix(1).sink { _ in finished.fulfill() }
        build.exportFrameworkBundle(framework: fw.path, titleID: tid, name: "Zelda")
        wait(for: [finished], timeout: 10)
        withExtendedLifetime(token) {}

        let dest = temporary.appendingPathComponent("exported-unsigned/DmGame\(tid).framework").path
        XCTAssertEqual(build.exportedIPAPath, dest)
        XCTAssertEqual(build.doneNote, String(format: build.t("shell.frameworkExportDone"), dest))
        XCTAssertEqual(devices.signingTeam, team, "explicit unsigned export must preserve the direct-install signing team")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest + "/_CodeSignature"), "stale _CodeSignature must be removed")
        XCTAssertFalse(runner.commands.contains { $0.contains("--sign") }, "unsigned export must never invoke codesign --sign")
        XCTAssertTrue(
            runner.commands.contains { $0.first == "/usr/bin/codesign" && $0.contains("--remove-signature") },
            "unsigned export must strip ad-hoc signature best-effort: \(runner.commands)"
        )
    }
}
