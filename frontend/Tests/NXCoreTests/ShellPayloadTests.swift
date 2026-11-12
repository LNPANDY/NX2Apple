import XCTest
import CryptoKit
import PayloadKit
@testable import NXCore

final class ShellPayloadTests: XCTestCase {
    var temp: URL!
    let team = "TESTTEAM01"
    let title = "0100000000000000"

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-payload-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temp) }

    private func fixture() throws -> (ShellInstaller, URL, PayloadRunner) {
        let root = temp.appendingPathComponent("shell")
        let framework = temp.appendingPathComponent("DmGame.framework")
        try FileManager.default.createDirectory(at: framework.appendingPathComponent("dm"), withIntermediateDirectories: true)
        let native = Self.native(team)
        try native.write(to: framework.appendingPathComponent("DmGame"))
        let info = ["CFBundleExecutable": "DmGame", "CFBundleIdentifier": "org.nxnative.game"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: framework.appendingPathComponent("Info.plist"))
        let game: [String: Any] = ["schema": 1, "loader": "FH", "title_id": title, "framework": "DmGame.framework",
                                  "framework_executable": "DmGame", "display_version": "1", "min_os": "26.0",
                                  "modules": ["main"], "profile": "dm/profile.tsv", "shader_map": "dm/shaders.tsv", "launcher": "launcher.json"]
        try JSONSerialization.data(withJSONObject: game).write(to: framework.appendingPathComponent("game.manifest.json"))
        for name in ["dm/profile.tsv", "dm/shaders.tsv", "launcher.json"] { try Data("fixture".utf8).write(to: framework.appendingPathComponent(name)) }
        let app = URL(fileURLWithPath: ShellInstall.appPath(root: root.path))
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try native.write(to: app.appendingPathComponent(ShellInstall.scheme))
        let host = PayloadCapabilities(bundleID: ShellLibrary.defaultBundleID, teamID: team, osVersion: "26.0",
                                       executableSHA256: try PayloadArchive.digest(app.appendingPathComponent(ShellInstall.scheme)))
        let runner = PayloadRunner(host: host, titleID: title, phone: temp.appendingPathComponent("phone"))
        var installer = ShellInstaller(repo: "", python: "/fake/python", root: root.path, device: "device", team: team)
        installer.runner = runner
        return (installer, framework, runner)
    }

    private func assertNoShellInstall(_ runner: PayloadRunner, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(runner.launches.contains { $0.executable.hasSuffix("xcodebuild") || $0.arguments.contains("xcodebuild") }, file: file, line: line)
        XCTAssertFalse(runner.launches.contains { $0.arguments.starts(with: ["devicectl", "device", "install"]) }, file: file, line: line)
    }

    func testAddingGameSignsAndTransfersOnlyThePayload() throws {
        var (installer, framework, runner) = try fixture()
        installer.waitCancelled = { true }   // an old cable-wait answer must not cancel a new payload transfer
        let result = installer.install(framework: framework.path, titleID: title, name: "Fixture", archive: "")
        XCTAssertTrue(result.ok, result.message)
        XCTAssertEqual(result.message, "Game payload added.")
        XCTAssertEqual(result.payloadDelivery, .active)
        assertNoShellInstall(runner)
        let sends = runner.launches.filter { $0.arguments.starts(with: ["devicectl", "device", "copy", "to"]) }
        XCTAssertEqual(sends.count, 2)
        XCTAssertTrue(sends.last?.arguments.contains(where: { $0.hasSuffix("/ready.json") }) == true, "completion marker is last")
        XCTAssertTrue(runner.launches.contains { $0.executable == "/usr/bin/codesign" && $0.arguments.contains(runner.fingerprint) })
        let payload = try XCTUnwrap(runner.payload)
        let manifest = try PayloadArchive.manifest(at: payload)
        XCTAssertEqual(manifest.titleID, title)
        XCTAssertEqual(manifest.teamID, team)
        XCTAssertFalse(manifest.files.contains { $0.path.contains("romfs") || $0.path.contains("save/") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: framework.appendingPathComponent("DmGame").path), "build product remains")
    }

    func testSupportedShellErrorsNeverFallBackToAnIPAInstall() throws {
        for legacyProtocol in [false, true] {
            let (installer, framework, runner) = try fixture()
            if legacyProtocol { runner.host.version = 1 }
            else { runner.host.teamID = "OTHER" }
            let result = installer.install(framework: framework.path, titleID: title, name: "Fixture", archive: "")
            XCTAssertFalse(result.ok)
            assertNoShellInstall(runner)
            XCTAssertFalse(runner.launches.contains { $0.arguments.contains("--sign") })
        }
    }

    func testMissingIdentityDoesNotChangeBundleOrReinstallShell() throws {
        let (installer, framework, runner) = try fixture()
        runner.host.executableSHA256 = "different"
        let result = installer.install(framework: framework.path, titleID: title, name: "Fixture", archive: "")
        XCTAssertFalse(result.ok)
        assertNoShellInstall(runner)
        XCTAssertFalse(runner.launches.contains { $0.arguments.contains("--sign") })
    }

    func testLinkedFrameworkRejectionDoesNotChangeTheOriginalArtwork() throws {
        var (installer, framework, runner) = try fixture()
        installer.banners = temp.appendingPathComponent("no-cached-artwork")
        let banner = framework.appendingPathComponent("banner.png")
        let original = Data("original artwork".utf8)
        try original.write(to: banner)
        let linked = temp.appendingPathComponent("Linked.framework")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: framework)
        let result = installer.install(framework: linked.path, titleID: title, name: "Fixture", archive: "")
        XCTAssertFalse(result.ok)
        XCTAssertEqual(FileManager.default.contents(atPath: banner.path), original)
        XCTAssertFalse(runner.launches.contains { $0.arguments.contains("--sign") })
        assertNoShellInstall(runner)
    }

    func testUnprocessedPayloadIsReportedAsAwaitingTheShell() throws {
        let (installer, framework, runner) = try fixture()
        runner.receiptState = nil
        let result = installer.install(framework: framework.path, titleID: title, name: "Fixture", archive: "")
        XCTAssertTrue(result.ok, result.message)
        XCTAssertTrue(result.message.contains("library"))
        XCTAssertEqual(result.payloadDelivery, .awaiting)
        assertNoShellInstall(runner)
    }

    func testChunkedTransferIsBoundedAndKeepsMarkerLast() throws {
        var (installer, framework, runner) = try fixture()
        installer.partSize = 512
        let result = installer.install(framework: framework.path, titleID: title, name: "Fixture", archive: "")
        XCTAssertTrue(result.ok, result.message)
        XCTAssertTrue(runner.partSizes.count > 1)
        XCTAssertTrue(runner.partSizes.allSatisfy { $0 <= 512 })
        let ready = try XCTUnwrap(runner.ready)
        XCTAssertEqual(ready.partSize, 512)
        let transaction = runner.phone.appendingPathComponent("Documents/PayloadInbox/" + ready.generation)
        XCTAssertTrue(try PayloadArchive.joinParts(in: transaction, ready: ready))
        let payload = transaction.appendingPathComponent(PayloadArchive.fileName)
        XCTAssertEqual(try PayloadArchive.digest(payload), ready.sha256)
        assertNoShellInstall(runner)
    }

    func testLostHandshakeAfterMigrationDoesNotReinstallTheApp() throws {
        let (installer, framework, runner) = try fixture()
        XCTAssertTrue(installer.install(framework: framework.path, titleID: title, name: "Fixture", archive: "").ok)
        runner.failCapabilities = true
        let second = installer.install(framework: framework.path, titleID: title, name: "Fixture", archive: "")
        XCTAssertFalse(second.ok)
        assertNoShellInstall(runner)
    }

    func testUnchangedGameDataDoesNotHideThePayloadReceipt() throws {
        let (installer, framework, runner) = try fixture()
        let archive = temp.appendingPathComponent("empty-data")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        runner.receiptState = nil
        let result = installer.install(framework: framework.path, titleID: title, name: "Fixture", archive: archive.path)
        XCTAssertTrue(result.ok, result.message)
        XCTAssertEqual(result.payloadDelivery, .awaiting)
        XCTAssertTrue(result.message.contains("library"))
        assertNoShellInstall(runner)
    }

    func testPendingAndAwaitingPayloadDataDoesNotOverwriteTheActiveGame() throws {
        for state: PayloadReceipt.State? in [.restartRequired, nil] {
            let (installer, framework, runner) = try fixture()
            runner.receiptState = state
            let archive = temp.appendingPathComponent("new-data")
            try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
            try Data("new data".utf8).write(to: archive.appendingPathComponent("romfs.img"))
            let active = runner.phone.appendingPathComponent("Documents/games/\(title)/romfs.img")
            try FileManager.default.createDirectory(at: active.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("running game".utf8).write(to: active)
            let result = installer.install(framework: framework.path, titleID: title, name: "Fixture", archive: archive.path)
            XCTAssertTrue(result.ok, result.message)
            XCTAssertEqual(try Data(contentsOf: active), Data("running game".utf8))
            let staged = runner.phone.appendingPathComponent("Documents/games/\(title)/payload-data/\(runner.generation)/romfs.img")
            XCTAssertEqual(try Data(contentsOf: staged), Data("new data".utf8))
            assertNoShellInstall(runner)
            try FileManager.default.removeItem(at: runner.phone)
        }
    }

    func testStandaloneDataSendSelectsPendingOrActivePayloadAndFailsClosed() throws {
        var (installer, framework, runner) = try fixture()
        installer.repo = temp.appendingPathComponent("repo").path
        let tool = URL(fileURLWithPath: EngineLayout.root(installer.repo) + "/" + RepoLayout.romfsImageTool)
        try FileManager.default.createDirectory(at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: tool)
        let gameFile = framework.appendingPathComponent("game.manifest.json")
        var game = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: gameFile)) as? [String: Any])
        runner.imageIdentity = "DMROMFSID1 title=\(title) version=1 build=0 size=8 index=0000000000000001"
        game["romfs_identity"] = runner.imageIdentity
        game["package_version"] = "v0"
        runner.gameManifestData = try JSONSerialization.data(withJSONObject: game)
        try runner.gameManifestData!.write(to: gameFile)
        XCTAssertTrue(installer.install(framework: framework.path, titleID: title, name: "Fixture", archive: "").ok)
        let active = try PayloadArchive.manifest(at: XCTUnwrap(runner.payload))
        var pending = active
        pending.generation = UUID().uuidString.lowercased()
        let archive = temp.appendingPathComponent("send-data")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        let image = archive.appendingPathComponent("romfs.img")
        try Data("new data".utf8).write(to: image)
        func writeSourceID(version: String = "v0") throws {
            let id: [String: Any] = ["title": title.lowercased(), "version": version,
                                     "bytes": try PayloadArchive.size(image), "sha256": try PayloadArchive.digest(image)]
            try JSONSerialization.data(withJSONObject: id).write(to: archive.appendingPathComponent("romfs.img.id"))
        }
        try writeSourceID()
        let live = runner.phone.appendingPathComponent("Documents/games/\(title)/romfs.img")
        try FileManager.default.createDirectory(at: live.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("legacy".utf8).write(to: live)
        func registry(_ pending: PayloadManifest?) throws -> Data {
            var selection: [String: Any] = ["active": try JSONSerialization.jsonObject(with: PayloadArchive.encode(active))]
            if let pending { selection["pending"] = try JSONSerialization.jsonObject(with: PayloadArchive.encode(pending)) }
            return try JSONSerialization.data(withJSONObject: ["schema": 1, "games": [title: selection]])
        }
        runner.imageIdentity = "DMROMFSID1 title=\(title) version=99 build=elsewhere size=8 index=0000000000000001"
        for next in [active, pending] {
            runner.registryData = try registry(next == active ? nil : next)
            let sent = installer.sendData(titleID: title, archive: archive.path, bundleID: runner.host.bundleID)
            XCTAssertTrue(sent.ok, sent.message)
            let folder = "Documents/" + PayloadStore.gameDataPath(titleID: title, generation: next.generation)
            XCTAssertEqual(try Data(contentsOf: runner.phone.appendingPathComponent(folder + "/romfs.img")), Data("new data".utf8))
            XCTAssertEqual(try Data(contentsOf: live), Data("legacy".utf8))
        }
        let copies = runner.launches.filter { $0.arguments.starts(with: ["devicectl", "device", "copy", "to"]) }.count
        try Data("new bits".utf8).write(to: image)
        try writeSourceID(version: "v65536")
        XCTAssertFalse(installer.sendData(titleID: title, archive: archive.path, bundleID: runner.host.bundleID).ok, "same index and size cannot authorize another source version")
        try Data("new data".utf8).write(to: image)
        try writeSourceID()
        try Data("new bits".utf8).write(to: image)
        XCTAssertFalse(installer.sendData(titleID: title, archive: archive.path, bundleID: runner.host.bundleID).ok, "modified file contents cannot reuse the original source metadata")
        try Data("new data".utf8).write(to: image)
        try writeSourceID()
        let selectedRegistry = runner.registryData
        let bundledRegistry = try JSONSerialization.data(withJSONObject: ["schema": 1, "games": [:]] as [String: Any])
        runner.registryData = bundledRegistry
        runner.inboxReady = true
        XCTAssertFalse(installer.sendData(titleID: title, archive: archive.path, bundleID: runner.host.bundleID).ok)
        runner.inboxReady = false
        runner.registryData = selectedRegistry
        for identity in ["DMROMFSID1 size=8 index=2", "DMROMFSID1 size=9 index=1", "invalid size=8 index=1"] {
            runner.imageIdentity = identity
            XCTAssertFalse(installer.sendData(titleID: title, archive: archive.path, bundleID: runner.host.bundleID).ok)
        }
        runner.imageIdentity = nil
        XCTAssertFalse(installer.sendData(titleID: title, archive: archive.path, bundleID: runner.host.bundleID).ok)
        runner.registryData = nil
        XCTAssertFalse(installer.sendData(titleID: title, archive: archive.path, bundleID: runner.host.bundleID).ok)
        runner.failCapabilities = true
        XCTAssertFalse(installer.sendData(titleID: title, archive: archive.path, bundleID: runner.host.bundleID).ok)
        XCTAssertEqual(runner.launches.filter { $0.arguments.starts(with: ["devicectl", "device", "copy", "to"]) }.count, copies)
        runner.failCapabilities = false
        runner.registryData = bundledRegistry
        XCTAssertTrue(installer.sendData(titleID: title, archive: archive.path, bundleID: runner.host.bundleID).ok, "bundled-only hosts retain the legacy data route")
        XCTAssertEqual(try Data(contentsOf: live), Data("new data".utf8))
        assertNoShellInstall(runner)
    }

    func testPayloadDataRetryResumesTheSameGenerationWithoutSendingCodeAgain() throws {
        let (installer, framework, runner) = try fixture()
        runner.receiptState = .restartRequired
        runner.failDataCopies = true
        let archive = temp.appendingPathComponent("new-data")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try Data("new data".utf8).write(to: archive.appendingPathComponent("romfs.img"))
        let failed = installer.install(framework: framework.path, titleID: title, name: "Fixture", archive: archive.path)
        XCTAssertFalse(failed.ok)
        XCTAssertEqual(failed.failure, .shellDataIncomplete)
        let destination = try XCTUnwrap(failed.payloadDataFolder)
        XCTAssertTrue(destination.hasSuffix("/payload-data/" + runner.generation))
        runner.failDataCopies = false
        let before = runner.launches.count
        let retried = installer.installData(titleID: title, archive: archive.path, dataFolder: destination)
        XCTAssertTrue(retried.ok, retried.message)
        XCTAssertEqual(retried.payloadDataFolder, destination)
        XCTAssertEqual(try Data(contentsOf: runner.phone.appendingPathComponent(destination + "/romfs.img")), Data("new data".utf8))
        let retries = runner.launches.dropFirst(before)
        XCTAssertFalse(retries.contains { $0.executable == "/usr/bin/codesign" || $0.arguments.contains(where: { $0.contains("PayloadInbox") }) })
        assertNoShellInstall(runner)
    }

    func testPayloadUpdatesRemoveReplacedLocalMirrors() throws {
        let (installer, framework, runner) = try fixture()
        XCTAssertTrue(installer.install(framework: framework.path, titleID: title, name: "Fixture", archive: "").ok)
        XCTAssertTrue(installer.install(framework: framework.path, titleID: title, name: "Fixture", archive: "").ok)
        let folder = ShellInstall.frameworksMirror(root: installer.root)
        let cleaned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            return !names.contains(where: { $0.hasPrefix(ShellInstall.discardPrefix) })
        }, object: nil)
        wait(for: [cleaned], timeout: 2)
        assertNoShellInstall(runner)
    }

    func testFailedLibrarySaveRestoresThePreviousLocalMirror() throws {
        let (installer, framework, runner) = try fixture()
        let fm = FileManager.default
        let mirror = URL(fileURLWithPath: ShellInstall.mirroredFramework(root: installer.root, titleID: title))
        try fm.createDirectory(at: mirror, withIntermediateDirectories: true)
        try Data("previous".utf8).write(to: mirror.appendingPathComponent("previous-copy"))
        // A directory at shell.json makes the atomic library write fail.
        try fm.createDirectory(atPath: ShellLibrary.stateFile(root: installer.root), withIntermediateDirectories: true)
        let result = installer.install(framework: framework.path, titleID: title, name: "Fixture", archive: "")
        XCTAssertFalse(result.ok)
        XCTAssertEqual(try Data(contentsOf: mirror.appendingPathComponent("previous-copy")), Data("previous".utf8))
        assertNoShellInstall(runner)
    }

    static func native(_ team: String) -> Data {
        func words(_ values: [UInt32], big: Bool = false) -> Data {
            var result = Data()
            for value in values { var v = big ? value.bigEndian : value.littleEndian; withUnsafeBytes(of: &v) { result.append(contentsOf: $0) } }
            return result
        }
        let count = UInt32(53 + team.utf8.count)
        let directory = words([0xfade0c02, count, 0x20200, 0, 0, 0, 0, 0, 0, 0, 0, 0, 52], big: true) + Data(team.utf8) + Data([0])
        let sig = words([0xfade0cc0, UInt32(20 + directory.count), 1, 0, 20], big: true) + directory
        return words([0xfeedfacf, 0x0100000c, 0, 6, 1, 16, 0, 0, 0x1d, 16, 48, UInt32(sig.count)]) + sig
    }
}

private final class PayloadRunner: ProcessRunner {
    var host: PayloadCapabilities
    let titleID: String
    let phone: URL
    var launches: [ProcessLaunch] = []
    var generation = ""
    var payload: URL?
    var ready: PayloadArchive.Ready?
    var partSizes: [UInt64] = []
    var receiptState: PayloadReceipt.State? = .active
    var failCapabilities = false
    var failDataCopies = false
    var registryData: Data?
    var gameManifestData: Data?
    var imageIdentity: String?
    var inboxReady = false
    let certificate = Data("fixture certificate".utf8)
    var fingerprint: String { Insecure.SHA1.hash(data: certificate).map { String(format: "%02X", $0) }.joined() }

    init(host: PayloadCapabilities, titleID: String, phone: URL) { self.host = host; self.titleID = titleID; self.phone = phone }

    func capture(_ launch: ProcessLaunch) -> ProcessResult {
        launches.append(launch)
        func argument(_ name: String) -> String? { launch.arguments.firstIndex(of: name).map { launch.arguments[$0 + 1] } }
        do {
            if launch.arguments.contains("--identity") { return ProcessResult(out: imageIdentity ?? "") }
            if launch.arguments.starts(with: ["devicectl", "device", "info", "files"]),
               argument("--subdirectory") == "Documents/" + PayloadStore.inboxName, let file = argument("--json-output") {
                let files: [[String: Any]] = inboxReady ? [["relativePath": "queued/ready.json"]] : []
                try JSONSerialization.data(withJSONObject: ["result": ["files": files]]).write(to: URL(fileURLWithPath: file))
            } else if launch.arguments.starts(with: ["devicectl", "list", "devices"]), let file = argument("--json-output") {
                let device: [String: Any] = ["hardwareProperties": ["reality": "physical", "platform": "iOS", "udid": "device"],
                                              "connectionProperties": ["pairingState": "paired", "transportType": "wired"]]
                try JSONSerialization.data(withJSONObject: ["result": ["devices": [device]]]).write(to: URL(fileURLWithPath: file))
            } else if launch.arguments.starts(with: ["devicectl", "device", "copy", "from"]), let from = argument("--source"), let to = argument("--destination") {
                if from.hasSuffix(PayloadCapabilities.fileName) {
                    if failCapabilities { return ProcessResult(status: 1) }
                    try PayloadArchive.encode(host).write(to: URL(fileURLWithPath: to))
                }
                else if from.hasSuffix("/game.manifest.json") {
                    guard let gameManifestData else { return ProcessResult(status: 1) }
                    try gameManifestData.write(to: URL(fileURLWithPath: to))
                }
                else if from.hasSuffix(PayloadStore.registryName) {
                    guard let registryData else { return ProcessResult(status: 1) }
                    try registryData.write(to: URL(fileURLWithPath: to))
                }
                else if let receiptState {
                    try PayloadArchive.encode(PayloadReceipt(generation: generation, titleID: titleID, state: receiptState)).write(to: URL(fileURLWithPath: to))
                } else { return ProcessResult(status: 1) }
            } else if let option = launch.arguments.first(where: { $0.hasPrefix("--extract-certificates=") }) {
                let prefix = String(option.dropFirst("--extract-certificates=".count))
                try certificate.write(to: URL(fileURLWithPath: prefix + "0"))
            } else if launch.executable.hasSuffix("security") { return ProcessResult(out: fingerprint + " identity") }
            else if launch.arguments.starts(with: ["devicectl", "device", "copy", "to"]), let from = argument("--source"), let to = argument("--destination") {
                if failDataCopies, to.hasPrefix("Documents/games/") { return ProcessResult(status: 1, out: "copy interrupted") }
                let target = phone.appendingPathComponent(to)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                try FileManager.default.copyItem(atPath: from, toPath: target.path)
                if to.contains(".nxpart.") { partSizes.append(try PayloadArchive.size(target)) }
                if to.hasSuffix(PayloadArchive.fileName) { payload = target }
                if to.hasSuffix(PayloadArchive.readyName) {
                    ready = try JSONDecoder().decode(PayloadArchive.Ready.self, from: Data(contentsOf: target))
                    generation = ready!.generation
                }
            }
            return ProcessResult()
        } catch { return ProcessResult(status: 1, out: String(describing: error)) }
    }
    func stream(_ launch: ProcessLaunch, line: @escaping (String) -> Void) -> Bool { capture(launch).ok }
    func streamLines(_ launch: ProcessLaunch, started: @escaping (RunningProcess) -> Void, line: @escaping (String) -> Void) -> ProcessResult { capture(launch) }
    func start(_ launch: ProcessLaunch, onOutput: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) throws -> RunningProcess { throw CocoaError(.featureUnsupported) }
}
