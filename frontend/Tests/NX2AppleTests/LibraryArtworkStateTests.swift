import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXModel
@testable import NXLauncher

@MainActor final class LibraryArtworkStateTests: IsolatedDefaultsTestCase {
    private func macApp(in root: URL) throws -> URL {
        let app = root.appendingPathComponent("Game.app")
        let executables = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: executables, withIntermediateDirectories: true)
        for name in ["nxnative", "dmhost"] {
            try FileManager.default.createSymbolicLink(at: executables.appendingPathComponent(name), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        }
        let info = ["DMTitleID": "0100000000000000", "CFBundleExecutable": "nxnative"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app
    }
    func testReadinessWarningsAndPlatformFiltersUseActualArtifacts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var game = LibraryGame(titleID: "0100000000000000", name: "Example")
        XCTAssertEqual(LibraryArtworkState(game).attention, .missingData)
        game.inputs = ["base": [root.appendingPathComponent("base.nsp").path]]
        XCTAssertEqual(LibraryArtworkState(game).attention, .missingData)
        try Data().write(to: URL(fileURLWithPath: game.inputs["base"]![0]))
        XCTAssertEqual(LibraryArtworkState(game).attention, .notBuilt)
        XCTAssertTrue(LibraryArtworkState(game).monochrome)
        XCTAssertEqual(LibraryArtworkState(game, building: true).attention, .building)
        let app = try macApp(in: root)
        game.appPath = app.path
        let mac = LibraryArtworkState(game)
        XCTAssertFalse(mac.monochrome)
        XCTAssertNil(mac.chipKey, "Play communicates availability without another Ready badge")
        XCTAssertTrue(LibraryFilter.mac.includes(game))
        XCTAssertFalse(LibraryFilter.ios.includes(game))
        game.inputs["base"] = ["/missing-source.nsp"]
        XCTAssertFalse(LibraryArtworkState(game).monochrome, "Original inputs are not required to play an existing build")
        XCTAssertFalse(LibraryArtworkState(game, building: true).monochrome, "A still-playable existing build stays available")
        let ipa = root.appendingPathComponent("Export.ipa")
        try Data().write(to: ipa)
        game.ipaPath = ipa.path
        XCTAssertEqual(LibraryArtworkState(game).chipKey, "library.chip.both")
        XCTAssertTrue(LibraryFilter.mac.includes(game))
        XCTAssertTrue(LibraryFilter.ios.includes(game), "A dual-platform game appears in both filters")
        try FileManager.default.removeItem(at: app.appendingPathComponent("Contents/MacOS/dmhost"))
        XCTAssertEqual(LibraryArtworkState(game).attention, .fixFiles)
        XCTAssertTrue(LibraryArtworkState(game).monochrome)
        game.appPath = ""
        XCTAssertEqual(LibraryArtworkState(game).chipKey, "library.chip.iosOnly")
        XCTAssertFalse(LibraryArtworkState(game).monochrome)
        XCTAssertFalse(game.onDevice, "An exported artifact is not a verified device installation")
    }
    func testModernMacBuildWithMissingGameDataCannotAdvertisePlay() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try macApp(in: root)
        let plist = app.appendingPathComponent("Contents/Info.plist")
        let info = ["DMTitleID": "0100000000000000", "CFBundleExecutable": "nxnative", "DMRomfsMarker": ""]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: plist)
        var game = LibraryGame(titleID: "0100000000000000", name: "Example")
        game.appPath = app.path
        XCTAssertFalse(game.isReady)
        XCTAssertEqual(LibraryArtworkState(game).attention, .missingData)
        let tree = app.appendingPathComponent("Contents/Resources/romfs")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        XCTAssertTrue(game.isReady)
        try FileManager.default.removeItem(at: tree)
        XCTAssertFalse(game.isReady, "A cached plist must not hide subsequently missing data")
        XCTAssertEqual(game.primary, .build)
    }

    func testChipSymbolsAndSharedLabelsExist() {
        for symbol in ["laptopcomputer.and.iphone", "iphone"] {
            XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil))
        }
        for lang in Lang.all {
            for key in ["library.chip.notBuilt", "library.chip.both", "library.chip.iosOnly", "library.yourLibrary",
                        "ios.ui.missingDataChip", "ios.ui.fixGameFilesChip"] {
                XCTAssertNotEqual(L10n.string(key, lang), key)
            }
        }
    }
}
