import XCTest
@testable import NXCore

/// The images one platform's build leaves for the other's (#708): which ones the launcher names to the build script, the identity file
/// that goes along with the image the archive step copies, and the probe for the script's option. The script itself checks each image.
final class RomFSImageReuseTests: XCTestCase {
    private var root: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-romfs-reuse-" + UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: root) }

    private func write(_ rel: String, _ text: String = "x") throws {
        let path = root + "/" + rel
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func testOnlyImagesWithAnIdentityAreNamed() throws {
        let key = "0100AAAA00000000"
        XCTAssertEqual(RomFSArchive.reusableImages(root: root, key: key), [])
        try write("games/\(key)/romfs.img")
        try write("\(key).app/Contents/Resources/romfs.img")
        XCTAssertEqual(RomFSArchive.reusableImages(root: root, key: key), [], "an image copied before identity files is not vouched for")
        try write("\(key).app/Contents/Resources/romfs.img.id")
        XCTAssertEqual(RomFSArchive.reusableImages(root: root, key: key), [root + "/\(key).app/Contents/Resources/romfs.img"])
        try write("games/\(key)/romfs.img.id")
        XCTAssertEqual(RomFSArchive.reusableImages(root: root, key: key),
                       [root + "/games/\(key)/romfs.img", root + "/\(key).app/Contents/Resources/romfs.img"])
        try write("games/0100BBBB00000000/romfs.img"); try write("games/0100BBBB00000000/romfs.img.id")
        XCTAssertEqual(RomFSArchive.reusableImages(root: root, key: key).count, 2, "another game's image is not named")
    }

    func testRenamedMacAppOfThisGameIsNamedWhileOtherAppsAndSymlinksAreSkipped() throws {
        let key = "0100AAAA00000000"
        try write("Hollow Knight.app/Contents/Resources/romfs.img")
        try write("Hollow Knight.app/Contents/Resources/romfs.img.id", "{\"title\": \"0100aaaa00000000\", \"version\": \"v0\"}\n")
        try write("Celeste.app/Contents/Resources/romfs.img")
        try write("Celeste.app/Contents/Resources/romfs.img.id", "{\"title\": \"0100bbbb00000000\", \"version\": \"v0\"}\n")
        let plistApp = URL(fileURLWithPath: root + "/Hollow Knight [\(key)].app/Contents")
        try FileManager.default.createDirectory(at: plistApp.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["DMTitleID": key], format: .xml, options: 0)
            .write(to: plistApp.appendingPathComponent("Info.plist"))
        try write("Hollow Knight [\(key)].app/Contents/Resources/romfs.img")
        try write("Hollow Knight [\(key)].app/Contents/Resources/romfs.img.id", "legacy-id")
        try FileManager.default.createSymbolicLink(
            atPath: root + "/Linked.app",
            withDestinationPath: root + "/Hollow Knight.app"
        )
        XCTAssertEqual(
            RomFSArchive.reusableImages(root: root, key: key),
            [
                root + "/Hollow Knight [\(key)].app/Contents/Resources/romfs.img",
                root + "/Hollow Knight.app/Contents/Resources/romfs.img",
            ]
        )
    }

    func testAKeyWithoutATitleIDNamesEveryGamesImage() throws {   // Game.nsp: the games folder is named after the framework's title ID (#515)
        let key = "Game-1a2b3c4d"
        try write("games/0100AAAA00000000/romfs.img"); try write("games/0100AAAA00000000/romfs.img.id")
        try write("games/0100BBBB00000000/romfs.img")   // no identity
        try write("\(key).app/Contents/Resources/romfs.img"); try write("\(key).app/Contents/Resources/romfs.img.id")
        XCTAssertEqual(RomFSArchive.reusableImages(root: root, key: key),
                       [root + "/games/0100AAAA00000000/romfs.img", root + "/\(key).app/Contents/Resources/romfs.img"])
    }

    func testTheIdentityGoesWithTheImageAndAStaleOneGoes() throws {
        try write("extract/v0/RomFS.img.id", "{\"version\": \"v0\"}")
        try write("games/id/romfs.img.id", "stale")
        RomFSArchive.copyImageIdentity(of: root + "/extract/v0/RomFS.img", to: root + "/games/id/romfs.img")
        XCTAssertEqual(try String(contentsOfFile: root + "/games/id/romfs.img.id", encoding: .utf8), "{\"version\": \"v0\"}")
        try FileManager.default.removeItem(atPath: root + "/extract/v0/RomFS.img.id")
        RomFSArchive.copyImageIdentity(of: root + "/extract/v0/RomFS.img", to: root + "/games/id/romfs.img")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/games/id/romfs.img.id"))
    }

    func testTheOptionIsPassedOnlyToAScriptThatHasIt() throws {
        try write("engine/scripts/build_ipa_from_nsp.py", "ap.add_argument('--work-dir')\n")
        XCTAssertFalse(RepoLayout.supportsRomfsFrom(root + "/engine"))
        try write("engine/scripts/build_ipa_from_nsp.py", "ap.add_argument('--romfs-from', action='append')\n")
        XCTAssertTrue(RepoLayout.supportsRomfsFrom(root + "/engine"))
    }
}
