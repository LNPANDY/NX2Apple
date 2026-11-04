import XCTest
@testable import NX2Apple
@testable import NXCore
import NXModel
@testable import NXLauncher

/// #595: on a disk that is not APFS (Mac OS Extended, exFAT) the Mac app step cannot swap the new app over the old one, so the second
/// build into a folder fails at its last step with error 45. The launcher says so before the build starts and reads the same words
/// from a log.
@MainActor final class VolumeFormatTests: IsolatedDefaultsTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("nspb-volume-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    private func store() throws -> BuildStore {
        let repo = home.appendingPathComponent("repo")
        for f in RepoLayout.requiredTools + ["dm/tools/nx_extract/Program.cs"] {
            let url = repo.appendingPathComponent(f)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "x".write(to: url, atomically: true, encoding: .utf8)
        }
        let stores = LauncherStores(defaults: testDefaults); let m = stores.build
        m.target = BuildTarget.mac
        stores.repo.path = repo.path
        m.cloudFolderCheck = { _ in true }   // ends a build that is let through, before any step runs
        m.outDir = home.appendingPathComponent("out").path
        try FileManager.default.createDirectory(atPath: m.outDir, withIntermediateDirectories: true)
        m.updateSlot("base") { $0.paths = ["/Games/Game [0100152000022000].nsp"] }
        return m
    }

    // ---- the log

    func testTheErrorOfTheSwapIsTheVolumeStop() throws {
        let f = try XCTUnwrap(BuildFailureTests().fixtures().first { $0.id == "volume.swap" })
        XCTAssertEqual(BuildFailureClassifier.classify(f.text).kind, .volumeFormat)
        XCTAssertEqual(BuildFailureClassifier.classify("OSError: [Errno 45] Operation not supported: '/Volumes/X/0100152000022000.app'").kind, .volumeFormat)
        XCTAssertEqual(BuildFailureClassifier.classify("OSError: [Errno 45] Operation not supported: '/Volumes/X/file.txt'").kind, .unknown, "another path keeps its note")
        XCTAssertEqual(BuildFailureClassifier.classify("OSError: [Errno 28] No space left on device").kind, .diskFull)
    }

    func testTheHintIsInAllSixLanguagesWithoutSemicolonsOrDashes() {
        let keys = [BuildFailureKind.volumeFormat.whatKey, BuildFailureKind.volumeFormat.nextKey, "msg.volumeNotAPFS"]
        for key in keys {
            let row = L10n.table[key]
            XCTAssertNotNil(row, key)
            let texts = [row?.zh ?? "", row?.en ?? "", L10n.sv[key] ?? "", L10n.de[key] ?? "", L10n.fr[key] ?? "", L10n.catalogs["it"]?[key] ?? ""]
            for text in texts {
                XCTAssertFalse(text.isEmpty, key)
                XCTAssertFalse(text.contains(";") || text.contains("\u{FF1B}") || text.contains("\u{2014}"), "\(key) has a semicolon or a dash")
                XCTAssertTrue(text.contains("APFS") || key.hasSuffix(".what"), "\(key) does not name the format")
            }
            XCTAssertEqual(Set(texts).count, 6, "\(key) has a text twice")
        }
        let next = L10n.table[BuildFailureKind.volumeFormat.nextKey]!.en
        XCTAssertTrue(next.contains("APFS") && next.contains("Trash"), "the next step names both fixes")
    }

    // ---- the volume

    func testAFolderThatDoesNotExistYetAsksTheFolderAboveIt() throws {
        // the answer is the real volume's and may be either: it must be the same for the folder and for one inside it that is not there
        let here = OutputVolume.supportsAppReplace(at: home.path)
        XCTAssertEqual(OutputVolume.supportsAppReplace(at: home.path + "/not/there/yet"), here)
        XCTAssertNil(OutputVolume.supportsAppReplace(at: ""))
    }

    // ---- before the build

    func testASecondBuildOnADiskThatCannotSwapStopsBeforeItStarts() throws {
        let m = try store()
        var asked: [String] = []
        m.appReplaceCheck = { asked.append($0); return false }
        try FileManager.default.createDirectory(atPath: m.outDir + "/0100152000022000.app", withIntermediateDirectories: true)
        m.startBuild()
        XCTAssertEqual(asked, [m.outDir])
        XCTAssertFalse(m.running)
        XCTAssertEqual(m.failure?.kind, .volumeFormat)
        XCTAssertEqual(m.doneNote, m.t(BuildFailureKind.volumeFormat.whatKey))
        XCTAssertFalse(m.log.text.contains(m.t("msg.volumeNotAPFS")), "the stop says it in the row, not twice")
    }

    func testTheFirstBuildOnSuchADiskGoesAheadAndSaysWhatComesNext() throws {
        let m = try store()
        m.appReplaceCheck = { _ in false }
        m.startBuild()
        XCTAssertEqual(m.failure?.kind, .cloudFolder, "it went on to the next check")
        XCTAssertTrue(m.log.text.contains(m.t("msg.volumeNotAPFS")), "no old app is there, so the first build works and the log says what comes next")
    }

    func testAnApfsDiskOrAnUnknownOneIsNotStopped() throws {
        for answer in [true, nil] as [Bool?] {
            let m = try store()
            m.appReplaceCheck = { _ in answer }
            try FileManager.default.createDirectory(atPath: m.outDir + "/0100152000022000.app", withIntermediateDirectories: true)
            m.startBuild()
            XCTAssertEqual(m.failure?.kind, .cloudFolder, "\(String(describing: answer)) went on to the next check")
            XCTAssertFalse(m.log.text.contains(m.t("msg.volumeNotAPFS")))
        }
    }
}
