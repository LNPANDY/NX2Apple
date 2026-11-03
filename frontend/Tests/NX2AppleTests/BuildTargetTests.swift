import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher

/// The launcher builds for this Mac or for the one shared app on an iPhone or iPad. Settings and library files written
/// when one IPA per game was a target still load, and older single-IPA builds stay in the library.
final class BuildTargetTests: XCTestCase {
    private var temporary: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-target-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporary)
    }

    func testAnyStoredValueButMacIsTheIPhoneTarget() {
        XCTAssertEqual(BuildTarget.normalized(nil), BuildTarget.ios)
        XCTAssertEqual(BuildTarget.normalized("ios"), BuildTarget.ios)
        XCTAssertEqual(BuildTarget.normalized("ios-shell"), BuildTarget.ios)
        XCTAssertEqual(BuildTarget.normalized("something else"), BuildTarget.ios)
        XCTAssertEqual(BuildTarget.normalized("mac-app"), BuildTarget.mac)
    }

    func testTheSavedChoiceIsMigratedAndStoredAgain() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "nspb-target-" + UUID().uuidString))
        XCTAssertEqual(BuildTarget.saved(defaults), BuildTarget.ios, "nothing stored yet")
        XCTAssertNil(defaults.string(forKey: "buildTarget"))
        defaults.set("ios-shell", forKey: "buildTarget")
        XCTAssertEqual(BuildTarget.saved(defaults), "ios")
        XCTAssertEqual(defaults.string(forKey: "buildTarget"), "ios")
        defaults.set("mac-app", forKey: "buildTarget")
        XCTAssertEqual(BuildTarget.saved(defaults), "mac-app")
        XCTAssertEqual(defaults.string(forKey: "buildTarget"), "mac-app")
    }

    func testALibraryGameKeepsOnlyTheTwoTargets() throws {
        let id = UUID()
        for (stored, expected) in [("ios-shell", "ios"), ("ios", "ios"), ("mac-app", "mac-app")] {
            let json = #"{"id":"\#(id.uuidString)","titleID":"0100535012974000","name":"Hades","lastTarget":"\#(stored)"}"#
            let game = try JSONDecoder().decode(LibraryGame.self, from: Data(json.utf8))
            XCTAssertEqual(game.lastTarget, expected, stored)
        }
        let none = try JSONDecoder().decode(LibraryGame.self, from: Data(#"{"id":"\#(id.uuidString)","titleID":"1","name":"H"}"#.utf8))
        XCTAssertEqual(none.lastTarget, "ios")
    }

    private func app(named name: String, at folder: String) throws -> URL {
        let url = temporary.appendingPathComponent(folder).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("plist".utf8).write(to: url.appendingPathComponent("Info.plist"))
        return url
    }

    func testASingleIPAOrAnAppOfItsOwnIsAnOlderBuildAndTheSharedAppIsNot() throws {
        let ipa = temporary.appendingPathComponent("Hades.ipa")
        try Data([0]).write(to: ipa)
        let single = LibraryGame(titleID: "0100535012974000", name: "Hades", ipaPath: ipa.path)
        XCTAssertTrue(single.hasIOSBuild)
        XCTAssertTrue(single.isOlderIOSBuild)
        XCTAssertEqual(single.primary, .build, "Build makes the game again for the shared app")

        let own = try app(named: "DmIOS.app", at: "0100_build/xcode-derived-data/Build/Products/Release-iphoneos")
        XCTAssertTrue(LibraryGame(titleID: "1", name: "H", iosAppPath: own.path, installedDevice: "UDID").isOlderIOSBuild)

        let shared = try app(named: "DmShell.app", at: "shell/derived-data/Build/Products/Release-iphoneos")
        let current = LibraryGame(titleID: "1", name: "H", iosAppPath: shared.path, installedDevice: "UDID")
        XCTAssertFalse(current.isOlderIOSBuild)
        XCTAssertFalse(LibraryGame(titleID: "1", name: "H").isOlderIOSBuild, "nothing built for iPhone")
    }

    func testABuildForTheSharedAppReplacesTheListedIPA() throws {
        let file = temporary.appendingPathComponent("library.json")
        let ipa = temporary.appendingPathComponent("Hades.ipa")
        try Data([0]).write(to: ipa)
        let game = LibraryGame(titleID: "0100535012974000", name: "Hades", ipaPath: ipa.path)
        try JSONEncoder().encode([game]).write(to: file)
        let library = GameLibrary(file: file)
        let shared = try app(named: "DmShell.app", at: "shell/derived-data/Build/Products/Release-iphoneos")
        library.recordCompletedIOS(archive: "", app: shared.path, device: "UDID", for: game.id)
        let stored = try XCTUnwrap(GameLibrary(file: file).games.first)
        XCTAssertEqual(stored.ipaPath, "")
        XCTAssertEqual(stored.iosAppPath, shared.path)
        XCTAssertFalse(stored.isOlderIOSBuild)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ipa.path), "the old file is not deleted")
        library.recordCompletedIOS(archive: "", app: temporary.path + "/none.app", for: game.id)
        XCTAssertEqual(GameLibrary(file: file).games.first?.iosAppPath, shared.path, "a build that made no app records nothing")
    }

    func testEveryLanguageTellsAnOlderBuildAndTheTwoTargets() {
        for key in ["library.olderIOS", "dev.resignOlder", "build.ios", "build.iosNote"] {
            XCTAssertNotNil(L10n.table[key], key)
            XCTAssertNotNil(L10n.de[key], key)
        }
        for key in ["library.olderIOS", "build.iosNote"] { XCTAssertNotNil(L10n.sv[key], key) }
        XCTAssertEqual(L10n.string("build.ios", .en), "iPhone / iPad")
        XCTAssertEqual(L10n.string("build.iosNote", .de), "Eine App auf deinem iPhone oder iPad für alle deine Spiele.")
    }
}
