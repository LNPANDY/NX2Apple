import XCTest
@testable import NXCore

/// The build-files folder: `<title ID>_build` apart from the finished app (BuildFilesFolder, BuildStore+BuildFiles.swift).
final class BuildFilesFolderTests: XCTestCase {
    private let id = "0100000000010000"
    private let fm = FileManager.default
    private var folder: URL!

    override func setUpWithError() throws {
        folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try fm.removeItem(at: folder) }

    private func makeApp(_ url: URL, _ titleID: String, name: String) throws {
        let bin = url.appendingPathComponent("Contents/MacOS")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: bin.appendingPathComponent("dmhost"), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        let info = ["DMTitleID": titleID, "CFBundleExecutable": "dmhost", "CFBundleDisplayName": name]
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0).write(to: url.appendingPathComponent("Contents/Info.plist"))
    }

    func testWithoutAChosenFolderTheBuildFilesStayBesideTheApp() {
        XCTAssertEqual(BuildFilesFolder.root(chosen: "", appFolder: "/Users/a/Games"), "/Users/a/Games")
        XCTAssertEqual(BuildFilesFolder.root(chosen: "  ", appFolder: "/Users/a/Games"), "/Users/a/Games")
        XCTAssertEqual(BuildFilesFolder.workDir(root: "/Users/a/Games", key: id), "/Users/a/Games/\(id)_build")
        XCTAssertEqual(BuildFilesFolder.workDir(root: "", key: id), "")
    }

    func testAChosenFolderHoldsTheBuildFiles() {
        let root = BuildFilesFolder.root(chosen: "/Volumes/Drive/Builds", appFolder: "/Users/a/Games")
        XCTAssertEqual(BuildFilesFolder.workDir(root: root, key: id), "/Volumes/Drive/Builds/\(id)_build")
    }

    func testCandidatesLookInTheChosenFolderFirstThenTheEarlierPlaces() {
        let list = BuildFilesFolder.candidates(key: id, chosen: "/Volumes/Drive/Builds", others: ["/Users/a/Games", "", "/Users/a/Games/"])
        XCTAssertEqual(list, ["/Volumes/Drive/Builds/\(id)_build", "/Users/a/Games/\(id)_build"])
        XCTAssertEqual(BuildFilesFolder.candidates(key: id, chosen: "", others: ["/Users/a/Games"]), ["/Users/a/Games/\(id)_build"])
    }

    func testADriveThatIsNotConnectedIsMissing() throws {
        let volumes = folder.appendingPathComponent("Volumes")
        try fm.createDirectory(at: volumes.appendingPathComponent("Here"), withIntermediateDirectories: true)
        XCTAssertTrue(BuildFilesFolder.driveMissing(volumes.path + "/Gone/Switch/\(id)_build", volumes: volumes.path))
        XCTAssertFalse(BuildFilesFolder.driveMissing(volumes.path + "/Here/Switch/\(id)_build", volumes: volumes.path))
        XCTAssertFalse(BuildFilesFolder.driveMissing("/Users/a/Games/\(id)_build", volumes: volumes.path))
        XCTAssertEqual(BuildFilesFolder.driveName(volumes.path + "/Gone/Switch", volumes: volumes.path), "Gone")
        XCTAssertNil(BuildFilesFolder.driveName("/Users/a/Games", volumes: volumes.path))
    }

    func testAPlainFolderUnderVolumesIsNotADrive() {
        // /Volumes/<name> that is a folder on the Mac's own disk (the drive gone) must not take a build. The startup disk's own
        // entry in /Volumes is a link to "/", which is a real mount point and so not missing.
        XCTAssertTrue(BuildFilesFolder.driveMissing("/Volumes/NX2Apple-test-\(UUID().uuidString)/Switch"))
        XCTAssertNil(BuildFilesFolder.mountPointOf("/nonexistent-\(UUID().uuidString)"))
        XCTAssertEqual(BuildFilesFolder.mountPointOf("/"), "/")
    }

    func testAFirstBuildPacksTheAppInTheAppFolderUnderAHiddenName() throws {
        let builds = folder.appendingPathComponent("drive/Builds"), games = folder.appendingPathComponent("Games")
        try fm.createDirectory(at: builds, withIntermediateDirectories: true)
        try fm.createDirectory(at: games, withIntermediateDirectories: true)
        let output = MacAppOutput(workDir: builds.appendingPathComponent(id + "_build"), key: id, titleID: id, preferred: "", appDirectory: games)
        XCTAssertEqual(output.builderURL.deletingLastPathComponent().standardizedFileURL.path, games.standardizedFileURL.path)
        XCTAssertEqual(output.builderURL.lastPathComponent, "." + id + ".app")
        try makeApp(output.builderURL, id, name: "Adventure")
        try Data([7]).write(to: output.builderURL.appendingPathExtension("key"))
        let placed = try output.finish()
        XCTAssertEqual(placed.standardizedFileURL.path, games.appendingPathComponent("Adventure.app").standardizedFileURL.path)
        XCTAssertEqual(try Data(contentsOf: placed.appendingPathExtension("key")), Data([7]))
        XCTAssertTrue(fm.fileExists(atPath: games.appendingPathComponent(".nx2apple-library").path), "saves and logs follow the app")
        XCTAssertFalse(fm.fileExists(atPath: builds.appendingPathComponent(".nx2apple-library").path))
        let rebuild = MacAppOutput(workDir: builds.appendingPathComponent(id + "_build"), key: id, titleID: id, preferred: placed.path, appDirectory: games)
        XCTAssertEqual(rebuild.builderURL.standardizedFileURL.path, placed.standardizedFileURL.path, "a rebuild packs into the game's own app")
    }

    func testTheAppFolderBesideTheBuildFolderKeepsTheOldLayout() {
        let work = folder.appendingPathComponent(id + "_build")
        let same = MacAppOutput(workDir: work, key: id, titleID: id, preferred: "", appDirectory: folder)
        XCTAssertEqual(same.builderURL, work.appendingPathComponent(id + ".app"))
        let none = MacAppOutput(workDir: work, key: id, titleID: id, preferred: "")
        XCTAssertEqual(none.builderURL, work.appendingPathComponent(id + ".app"))
    }
}
