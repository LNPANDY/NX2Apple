import XCTest
@testable import NXCore

/// `MacPreflight.supports`: only a launcher that names DM_PREFLIGHT is opened for the check, since an older one would start the game.
final class MacPreflightTests: XCTestCase {
    private let fm = FileManager.default
    private var folder: URL!

    override func setUpWithError() throws {
        folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try fm.removeItem(at: folder) }

    private func app(binary: Data?, executable: String? = "game") throws -> URL {
        let url = folder.appendingPathComponent(UUID().uuidString + ".app")
        let macOS = url.appendingPathComponent("Contents/MacOS")
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        if let binary { try binary.write(to: macOS.appendingPathComponent("game")) }
        var info: [String: Any] = ["DMTitleID": "0100000000010000"]
        info["CFBundleExecutable"] = executable
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: url.appendingPathComponent("Contents/Info.plist"))
        return url
    }

    func testOnlyALauncherThatKnowsTheSwitchIsOpened() throws {
        XCTAssertTrue(MacPreflight.supports(try app(binary: Data([0xcf, 0xfa]) + Data("getenv\0DM_PREFLIGHT\0".utf8))))
        XCTAssertFalse(MacPreflight.supports(try app(binary: Data("DM_LAUNCHER\0".utf8))), "a launcher from before the patch")
        XCTAssertFalse(MacPreflight.supports(try app(binary: nil)), "no executable")
        XCTAssertFalse(MacPreflight.supports(try app(binary: Data("DM_PREFLIGHT".utf8), executable: nil)), "no CFBundleExecutable")
    }
}
