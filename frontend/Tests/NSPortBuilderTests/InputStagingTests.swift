import XCTest
@testable import NSPortBuilder

/// The staging folder for files picked from several folders (#132): the same selection stages to the same
/// paths with the same dates, and the folder holds exactly the current selection.
final class InputStagingTests: XCTestCase {
    private var temporary: URL!
    private var a: URL { temporary.appendingPathComponent("one") }
    private var b: URL { temporary.appendingPathComponent("two") }
    private var work: String { temporary.appendingPathComponent("0100000000000000_build").path }

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-stage-" + UUID().uuidString)
        for d in [a, b] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: temporary) }

    private func game(_ name: String, in dir: URL, age: TimeInterval) throws -> String {
        let url = dir.appendingPathComponent(name)
        try Data(repeating: 1, count: 4096).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: url.path)
        return url.path
    }

    /// What the script's fingerprint sees: name, size and modification time, following links.
    private func seen(_ dir: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir).sorted().map { name in
            var st = stat()
            XCTAssertEqual(stat(dir + "/" + name, &st), 0)
            return "\(dir)/\(name) \(st.st_size) \(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)"
        }
    }

    func testTwoStagingsOfTheSameSelectionAreIdentical() throws {
        let files = [try game("base.nsp", in: a, age: 5000), try game("update.nsp", in: b, age: 9000)]
        let dir = InputStaging.folder(workDir: work)
        XCTAssertEqual(InputStaging.sync(files: files, into: dir), 2)
        let first = try seen(dir)
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(InputStaging.sync(files: files, into: dir), 2)
        XCTAssertEqual(try seen(dir), first)
        XCTAssertEqual(first.count, 2)
    }

    func testStaleEntryIsRemovedButBuildFoldersStay() throws {
        let base = try game("base.nsp", in: a, age: 100)
        let update = try game("update.nsp", in: b, age: 200)
        let dir = InputStaging.folder(workDir: work)
        _ = InputStaging.sync(files: [base, update], into: dir)
        try FileManager.default.createDirectory(atPath: dir + "/0100000000000000_build/profile", withIntermediateDirectories: true)
        XCTAssertEqual(InputStaging.sync(files: [base], into: dir), 1)
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: dir))
        XCTAssertEqual(names, ["base.nsp", "0100000000000000_build"])
    }

    func testLinkToAnotherFileIsRelinked() throws {
        let one = try game("base.nsp", in: a, age: 100)
        let two = try game("base.nsp", in: b, age: 300)
        let dir = InputStaging.folder(workDir: work)
        _ = InputStaging.sync(files: [one], into: dir)
        _ = InputStaging.sync(files: [two], into: dir)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: dir + "/base.nsp"), two)
    }
}
