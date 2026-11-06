import XCTest
@testable import NXCore

final class MacAppPlacementTests: XCTestCase {
    private let id = "0100000000010000"
    private let other = "0100000000020000"
    private let fm = FileManager.default
    private var folder: URL!

    override func setUpWithError() throws {
        folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try fm.removeItem(at: folder) }

    private func makeApp(_ url: URL, _ titleID: String, name: String? = nil) throws {
        let bin = url.appendingPathComponent("Contents/MacOS")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: bin.appendingPathComponent("dmhost"), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        var info = ["DMTitleID": titleID, "CFBundleExecutable": "dmhost"]
        info["CFBundleDisplayName"] = name
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0).write(to: url.appendingPathComponent("Contents/Info.plist"))
    }

    private func output(_ key: String, known: Bool = true) -> MacAppOutput {
        MacAppOutput(workDir: folder.appendingPathComponent(key + "_build"), key: key, titleID: known ? key : nil, preferred: "")
    }

    func testConcurrentFirstBuildsWithTheSameSanitizedNameKeepBothGames() throws {
        let first = output(id), second = output(other)
        try makeApp(first.builderURL, id, name: "雪 / Journey")
        try makeApp(second.builderURL, other, name: "雪: Journey")
        let a = try first.finish(), b = try second.finish()
        XCTAssertEqual(a.lastPathComponent, "雪 - Journey.app")
        XCTAssertEqual(b.lastPathComponent, "雪 - Journey [\(other)].app")
        XCTAssertEqual(try MacGameBundle.read(a).titleID, id)
        XCTAssertEqual(try MacGameBundle.read(b).titleID, other)
        XCTAssertEqual(output(other).builderURL.lastPathComponent, b.lastPathComponent, "reuse the packer's own replacement and fingerprint on rebuild")
    }

    func testLegacyAppMigratesAndRebuildKeepsAManuallyChosenName() throws {
        let old = folder.appendingPathComponent(id + ".app")
        try makeApp(old, id, name: "Adventure")
        try Data([1]).write(to: old.appendingPathExtension("key"))
        let legacy = output(id)
        XCTAssertEqual(legacy.builderURL.lastPathComponent, old.lastPathComponent)
        let named = try legacy.finish()
        XCTAssertEqual(named.lastPathComponent, "Adventure.app")
        XCTAssertFalse(fm.fileExists(atPath: old.path))
        XCTAssertEqual(try Data(contentsOf: named.appendingPathExtension("key")), Data([1]))
        let manual = folder.appendingPathComponent("My copy.app")
        try fm.moveItem(at: named, to: manual)
        let again = output(id)
        XCTAssertEqual(again.builderURL.lastPathComponent, manual.lastPathComponent)
        XCTAssertEqual(try again.finish().lastPathComponent, manual.lastPathComponent)
    }

    func testUnknownInputIDReplacesOnlyTheMatchingAppAfterPacking() throws {
        let manual = folder.appendingPathComponent("My copy.app")
        try makeApp(manual, id, name: "Old")
        let plan = output("untitled-89abcdef", known: false)
        try makeApp(plan.builderURL, id, name: "New")
        let result = try plan.finish()
        XCTAssertEqual(result.lastPathComponent, manual.lastPathComponent)
        XCTAssertEqual(try MacGameBundle.read(result).name, "New")
    }

    func testMissingTitleFallsBackToMetadataIDAndCannotOverwriteAnUnrelatedApp() throws {
        let taken = folder.appendingPathComponent(id + ".app")
        try makeApp(taken, other, name: "Other game")
        let plan = output("untitled-89abcdef", known: false)
        try makeApp(plan.builderURL, id, name: " /: ..")
        let result = try plan.finish()
        XCTAssertTrue(result.lastPathComponent.contains(id))
        XCTAssertNotEqual(result.lastPathComponent, taken.lastPathComponent)
        XCTAssertEqual(try MacGameBundle.read(taken).titleID, other)
        XCTAssertEqual(try MacGameBundle.read(result).titleID, id)
    }

    func testAnAppAtAnotherLocationAndASymlinkToItAreNeverBuildTargets() throws {
        let elsewhere = folder.appendingPathComponent("Elsewhere/Keep.app")
        try makeApp(elsewhere, id, name: "Journey")
        let link = folder.appendingPathComponent("Journey.app")
        try fm.createSymbolicLink(at: link, withDestinationURL: elsewhere)
        XCTAssertNil(MacAppOutput.existing(in: folder, titleID: id, preferred: elsewhere.path))
        let plan = output(id)
        try makeApp(plan.builderURL, id, name: "Journey")
        XCTAssertEqual(try plan.finish().lastPathComponent, "Journey [\(id)].app")
        XCTAssertTrue(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
        XCTAssertEqual(try MacGameBundle.read(elsewhere).name, "Journey")
    }

    func testLongUnicodeTitleLeavesRoomForThePackersSidecars() throws {
        let plan = output(id)
        try makeApp(plan.builderURL, id, name: "." + String(repeating: "海", count: 160))
        let result = try plan.finish()
        XCTAssertTrue(result.lastPathComponent.hasPrefix("海"))
        XCTAssertLessThanOrEqual((result.lastPathComponent + ".key.partial").utf8.count, 255)
    }
}
