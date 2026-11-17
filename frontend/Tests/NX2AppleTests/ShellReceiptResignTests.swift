import Foundation
import XCTest
@testable import NXCore
@testable import NXModel
@testable import NX2Apple

@MainActor
final class ShellReceiptResignTests: IsolatedDefaultsTestCase {
    private var tempDir: URL!
    private let fm = FileManager.default

    override func setUp() async throws {
        try await super.setUp()
        tempDir = fm.temporaryDirectory.appendingPathComponent("nx2apple-resign-tests-" + UUID().uuidString)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir { try? fm.removeItem(at: tempDir) }
        try await super.tearDown()
    }

    private func makeSignedShellApp(root: URL, titles: [(String, String)]) throws -> String {
        let appDir = URL(fileURLWithPath: ShellInstall.appPath(root: root.path))
        try fm.createDirectory(at: appDir, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "org.nxnative.shell.TEAM123", "CFBundleExecutable": "DmShell"]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: appDir.appendingPathComponent("Info.plist"))
        try Data("profile".utf8).write(to: appDir.appendingPathComponent(AppSignature.profileName))

        var shellLib = ShellLibrary(bundleID: "org.nxnative.shell.TEAM123", team: "TEAM123")
        for (tid, name) in titles {
            let fw = ShellInstall.mirroredFramework(root: root.path, titleID: tid)
            try fm.createDirectory(atPath: fw, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: URL(fileURLWithPath: fw + "/game.manifest.json"))
            shellLib.add(.init(titleID: tid, name: name, framework: fw))
        }
        try shellLib.save(root: root.path)
        return appDir.path
    }

    func testExportingSharedIPAPreservesInstalledDeviceAndResignEligibility() throws {
        let shellRoot = tempDir.appendingPathComponent("shell")
        let tid = "0100CD801CE5E000"
        let appPath = try makeSignedShellApp(root: shellRoot, titles: [(tid, "Balatro")])

        let libFile = tempDir.appendingPathComponent("library.json")
        let library = GameLibrary(file: libFile)
        let game = LibraryGame(titleID: tid, name: "Balatro")
        library.upsert(game)
        let gameID = try XCTUnwrap(library.games.first?.id)

        // 1. Direct device install records UDID in both library and shell receipt.
        library.recordCompletedIOS(archive: "", app: appPath, device: "00008130-TESTUDID", commit: "abc", for: gameID)
        XCTAssertEqual(ShellLibrary.installedDevice(root: shellRoot.path), "00008130-TESTUDID")
        let installed = try XCTUnwrap(library.games.first)
        XCTAssertTrue(installed.onDevice)
        XCTAssertFalse(installed.isOlderIOSBuild)

        // 2. Subsequent shared IPA export has empty `device` while `DmShell.app` still exists in derived-data.
        let exportedIPA = shellRoot.appendingPathComponent("export/NX2Apple.ipa").path
        try fm.createDirectory(atPath: (exportedIPA as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data("ipa".utf8).write(to: URL(fileURLWithPath: exportedIPA))

        library.recordCompletedIOS(archive: "", app: appPath, device: "", commit: "def", ipa: exportedIPA, for: gameID)
        let afterExport = try XCTUnwrap(library.games.first)
        XCTAssertEqual(afterExport.installedDevice, "00008130-TESTUDID", "shared IPA export must not wipe installedDevice")
        XCTAssertTrue(afterExport.onDevice, "re-sign eligibility must remain active after shared IPA export")
        XCTAssertFalse(afterExport.isOlderIOSBuild)
        XCTAssertTrue(afterExport.shellIPAExists)
    }

    func testSyncSharedAppHealsClearedInstalledDeviceOnlyForReceiptGames() throws {
        let shellRoot = tempDir.appendingPathComponent("shell-heal")
        let installedTID = "0100CD801CE5E000"
        let uninstalledTID = "0100E65002BB8000"
        _ = try makeSignedShellApp(root: shellRoot, titles: [
            (installedTID, "Balatro"),
            (uninstalledTID, "Stardew Valley"),
        ])

        // Write a legacy receipt containing only `installedTID` and no `.installed-device` file.
        let legacyReceiptDir = URL(fileURLWithPath: ShellInstall.derivedData(root: shellRoot.path))
        try fm.createDirectory(at: legacyReceiptDir, withIntermediateDirectories: true)
        try JSONEncoder().encode([installedTID]).write(to: legacyReceiptDir.appendingPathComponent(".installed-games.json"))

        let libFile = tempDir.appendingPathComponent("library-heal.json")
        let library = GameLibrary(file: libFile)
        library.upsert(LibraryGame(titleID: installedTID, name: "Balatro"))
        library.upsert(LibraryGame(titleID: uninstalledTID, name: "Stardew Valley"))

        // Without fallbackDevice or receipt device, `onDevice` cannot guess a UDID.
        library.syncSharedApp(root: shellRoot.path)
        XCTAssertEqual(library.games.first { $0.titleID == installedTID }?.installedDevice, "")

        // With the paired target `fallbackDevice`, only the game inside `.installed-games.json` heals `onDevice`.
        library.syncSharedApp(root: shellRoot.path, fallbackDevice: "00008140-PAIRED")
        let healed = try XCTUnwrap(library.games.first { $0.titleID == installedTID })
        let unbuiltOnPhone = try XCTUnwrap(library.games.first { $0.titleID == uninstalledTID })

        XCTAssertEqual(healed.installedDevice, "00008140-PAIRED")
        XCTAssertTrue(healed.onDevice)
        XCTAssertFalse(healed.isOlderIOSBuild)
        XCTAssertEqual(ShellLibrary.installedDevice(root: shellRoot.path), "00008140-PAIRED")

        XCTAssertEqual(unbuiltOnPhone.installedDevice, "", "uninstalled framework must never inherit installedDevice")
        XCTAssertFalse(unbuiltOnPhone.onDevice)
    }
}
