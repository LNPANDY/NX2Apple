import Foundation
import XCTest
@testable import NXCore

final class MacNativeGamesCompatTests: XCTestCase {
    private let fm = FileManager.default
    private var tmpDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpDir = fm.temporaryDirectory.appendingPathComponent("mng-compat-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tmpDir {
            try? fm.removeItem(at: tmpDir)
        }
        tmpDir = nil
        try super.tearDownWithError()
    }

    private static let sampleBrokenAppIconJSON = """
    {
      "source_page": "https://www.nintendo.com/us/store/products/the-legend-of-zelda-ocarina-of-time-switch-2/",
      "url": "\(MacNativeGamesCompat.brokenOotIconURL)",
      "sha256": "15d81aed2feace626e7a3b36f411443eb312b16bc2477db11105cf9de153af72",
      "custom_note": "preserve-me"
    }
    """

    private func makeMNGTree(name: String, appIconJSON: String? = MacNativeGamesCompatTests.sampleBrokenAppIconJSON) throws -> URL {
        let tree = tmpDir.appendingPathComponent(name, isDirectory: true)
        let buildApp = tree.appendingPathComponent("build_app.py")
        let totkDir = tree.appendingPathComponent("games/totk", isDirectory: true)
        let ootBuild = tree.appendingPathComponent("games/oot/build.py")
        try fm.createDirectory(at: totkDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: ootBuild.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/usr/bin/env python3\n".write(to: buildApp, atomically: true, encoding: .utf8)
        try "# oot\n".write(to: ootBuild, atomically: true, encoding: .utf8)

        if let appIconJSON {
            let specURL = tree.appendingPathComponent(MacNativeGamesCompat.ootAppIconSpecRelativePath)
            try fm.createDirectory(at: specURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try appIconJSON.write(to: specURL, atomically: true, encoding: .utf8)
        }
        return tree
    }

    func testUpdatesBrokenOotAppIconURLAndIsIdempotentWhilePreservingOtherFields() throws {
        let tree = try makeMNGTree(name: "mng-broken-icon")
        let specURL = tree.appendingPathComponent(MacNativeGamesCompat.ootAppIconSpecRelativePath)

        XCTAssertTrue(MacNativeGamesCompat.ensureOotAppIconCompatibility(in: tree.path))

        let updatedData = try Data(contentsOf: specURL)
        let updated = try XCTUnwrap(try JSONSerialization.jsonObject(with: updatedData) as? [String: Any])
        XCTAssertEqual(updated["url"] as? String, MacNativeGamesCompat.fixedOotIconURL)
        XCTAssertEqual(updated["sha256"] as? String, MacNativeGamesCompat.fixedOotIconSHA256)
        XCTAssertEqual(
            updated["source_page"] as? String,
            "https://www.nintendo.com/us/store/products/the-legend-of-zelda-ocarina-of-time-switch-2/"
        )
        XCTAssertEqual(updated["custom_note"] as? String, "preserve-me")

        // Second pass must be a no-op
        XCTAssertFalse(MacNativeGamesCompat.ensureOotAppIconCompatibility(in: tree.path))
        XCTAssertEqual(try Data(contentsOf: specURL), updatedData)
    }

    func testSkipsWhenUpstreamAlreadyUpdatedToAnotherURL() throws {
        let upstreamUpdatedJSON = """
        {
          "source_page": "https://www.nintendo.com/us/store/products/the-legend-of-zelda-ocarina-of-time-switch-2/",
          "url": "https://assets.nintendo.com/image/upload/example/new-upstream-url",
          "sha256": "0000000000000000000000000000000000000000000000000000000000000000"
        }
        """
        let tree = try makeMNGTree(name: "mng-upstream-updated", appIconJSON: upstreamUpdatedJSON)
        let specURL = tree.appendingPathComponent(MacNativeGamesCompat.ootAppIconSpecRelativePath)

        XCTAssertFalse(MacNativeGamesCompat.ensureOotAppIconCompatibility(in: tree.path))
        XCTAssertEqual(try String(contentsOf: specURL, encoding: .utf8), upstreamUpdatedJSON)
    }

    func testRejectsSymlinkEscapingEngineTree() throws {
        let outside = tmpDir.appendingPathComponent("outside.json")
        try Self.sampleBrokenAppIconJSON.write(to: outside, atomically: true, encoding: .utf8)

        let tree = try makeMNGTree(name: "mng-symlink", appIconJSON: nil)
        let specURL = tree.appendingPathComponent(MacNativeGamesCompat.ootAppIconSpecRelativePath)
        try fm.createDirectory(at: specURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: specURL, withDestinationURL: outside)

        XCTAssertFalse(MacNativeGamesCompat.ensureOotAppIconCompatibility(in: tree.path))
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), Self.sampleBrokenAppIconJSON)
    }

    func testUpstreamEngineStoreInstallAppliesOotAppIconCompatGuard() throws {
        let stage = tmpDir.appendingPathComponent("zip-stage/MacNativeGames-main", isDirectory: true)
        let tree = try makeMNGTree(name: "zip-src")
        try fm.createDirectory(at: stage.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: tree, to: stage)

        let zipURL = tmpDir.appendingPathComponent("mng.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--sequesterRsrc", tmpDir.appendingPathComponent("zip-stage").path, zipURL.path]
        try ditto.run()
        ditto.waitUntilExit()
        XCTAssertEqual(ditto.terminationStatus, 0)

        let storeRoot = tmpDir.appendingPathComponent("upstreams", isDirectory: true)
        let store = UpstreamEngineStore(root: storeRoot)
        let installed = try store.install(zip: zipURL, kind: .macNativeGames)
        let installedData = try Data(contentsOf: installed.appendingPathComponent(MacNativeGamesCompat.ootAppIconSpecRelativePath))
        let installedJSON = try XCTUnwrap(try JSONSerialization.jsonObject(with: installedData) as? [String: Any])
        XCTAssertEqual(installedJSON["url"] as? String, MacNativeGamesCompat.fixedOotIconURL)
        XCTAssertEqual(installedJSON["sha256"] as? String, MacNativeGamesCompat.fixedOotIconSHA256)
    }
}
