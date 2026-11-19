import Foundation
import XCTest
@testable import NXCore

final class LauncherPR3CoreFixesTests: XCTestCase {
    private var temporary: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("pr3-core-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporary)
    }

    func testArtifactSizeBytesSumsRegularFilesInFrameworkDirectoryAndSkipsSymlinks() throws {
        let fm = FileManager.default
        let fw = temporary.appendingPathComponent("DmGame010015100B514000.framework", isDirectory: true)
        try fm.createDirectory(at: fw.appendingPathComponent("dm"), withIntermediateDirectories: true)

        let binaryPayload = Data(repeating: 0xAA, count: 2_000_000)
        let manifestPayload = Data(repeating: 0xBB, count: 500_000)
        try binaryPayload.write(to: fw.appendingPathComponent("DmGame010015100B514000"))
        try manifestPayload.write(to: fw.appendingPathComponent("dm/launcher.json"))

        let outsideTarget = temporary.appendingPathComponent("outside.bin")
        try Data(repeating: 0xCC, count: 1_000_000).write(to: outsideTarget)
        try fm.createSymbolicLink(at: fw.appendingPathComponent("linked.bin"), withDestinationURL: outsideTarget)

        let rawInodeSize = (try? fm.attributesOfItem(atPath: fw.path)[.size] as? Int64) ?? 0
        XCTAssertLessThan(rawInodeSize, 10_000)

        let totalBytes = ShellInstall.artifactSizeBytes(atPath: fw.path, fm: fm)
        XCTAssertEqual(totalBytes, 2_500_000)
        XCTAssertEqual(ShellInstall.sizeText(totalBytes), "2 MB")

        let ipaFile = temporary.appendingPathComponent("Exported.ipa")
        try Data(repeating: 0x11, count: 4096).write(to: ipaFile)
        XCTAssertEqual(ShellInstall.artifactSizeBytes(atPath: ipaFile.path, fm: fm), 4096)
        XCTAssertEqual(ShellInstall.artifactSizeBytes(atPath: temporary.appendingPathComponent("missing").path, fm: fm), 0)
    }

    func testDeviceImgPullErrorLocalizedReasonAcrossLanguages() {
        let cases: [DeviceImgPullError] = [
            .missingDevice,
            .imageNotFoundOnDevice,
            .invalidPulledImage,
            .transferFailed("devicectl copy failed"),
            .transferFailed("error: cable unplugged")
        ]
        for langCode in ["en", "zh", "de"] {
            let lang = Lang(langCode)
            for err in cases {
                let text = err.localizedReason { L10n.string($0, lang) }
                XCTAssertFalse(text.isEmpty, "\(langCode) empty for \(err)")
                XCTAssertFalse(text.contains(";") || text.contains("\u{FF1B}"), "\(langCode) semicolon in \(text)")
                if langCode == "zh", case .missingDevice = err {
                    XCTAssertFalse(text.contains("No device selected"), text)
                }
            }
        }
    }

    func testCleanPackageGameNameAndShellLibraryAddStripTagsAndExtensions() throws {
        XCTAssertEqual(
            RomFSArchive.cleanPackageGameName("Super Mario Wonder [010015100B514000][v0].nsp"),
            "Super Mario Wonder"
        )
        XCTAssertEqual(
            RomFSArchive.cleanPackageGameName("Zelda [01007EF00011E000] (v65536).xci"),
            "Zelda"
        )

        let fwPlain = temporary.appendingPathComponent("DmGame010015100B514000.framework", isDirectory: true)
        try FileManager.default.createDirectory(at: fwPlain, withIntermediateDirectories: true)

        var lib = ShellLibrary()
        lib.add(ShellLibrary.Game(
            titleID: "010015100B514000",
            name: "Super Mario Wonder [010015100B514000][v0].nsp",
            framework: fwPlain.path
        ))
        XCTAssertEqual(lib.games.first?.name, "Super Mario Wonder")

        let fwWithManifest = temporary.appendingPathComponent("DmGame01007EF00011E000.framework", isDirectory: true)
        try FileManager.default.createDirectory(at: fwWithManifest, withIntermediateDirectories: true)
        let manifestJSON = #"{"name": "The Legend of Zelda: Breath of the Wild"}"#
        try Data(manifestJSON.utf8).write(to: fwWithManifest.appendingPathComponent("game.manifest.json"))

        lib.add(ShellLibrary.Game(
            titleID: "01007EF00011E000",
            name: "01007EF00011E000 [01007EF00011E000][v0].nsp",
            framework: fwWithManifest.path
        ))
        XCTAssertEqual(
            lib.games.first(where: { $0.titleID == "01007EF00011E000" })?.name,
            "The Legend of Zelda: Breath of the Wild"
        )
    }

    func testClassifierRecognizesMacNativeGamesSharedFontsErrors() {
        let log1 = "ERROR: Encrypted NSP inputs require --firmware <dir> or --shared-fonts <dir> because standard game packages do not include system shared fonts."
        XCTAssertEqual(BuildFailureClassifier.classify(log1).kind, .mngSharedFonts)

        let log2 = "ERROR: No --firmware or --shared-fonts provided, and no valid shared fonts are cached."
        XCTAssertEqual(BuildFailureClassifier.classify(log2).kind, .mngSharedFonts)

        let genericLog = "checking files\nERROR: missing shared fonts\n"
        XCTAssertEqual(BuildFailureClassifier.classify(genericLog).kind, .unknown)
    }
}
