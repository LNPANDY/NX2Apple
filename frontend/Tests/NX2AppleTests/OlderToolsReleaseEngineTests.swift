import XCTest
@testable import NX2Apple
@testable import NXCore

/// #944: a release engine tree has no git history, but it names itself. A game records that name and is marked once another engine is
/// selected, and the note stays "different tools" (the changed files are unknown there, so no fix is promised).
final class OlderToolsReleaseEngineTests: XCTestCase {
    private var tree: URL!
    private let first = "c78d7375bea9-0123456789ab", second = "c78d7375bea9-ba9876543210"

    override func setUpWithError() throws {
        tree = FileManager.default.temporaryDirectory.appendingPathComponent("release-engine-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("dm/tools/nx_extract"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: tree.appendingPathComponent(EngineLayout.marker).path, contents: Data())
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tree) }

    private func select(_ id: String) throws { try (id + "\n").write(to: tree.appendingPathComponent(".engine-id"), atomically: true, encoding: .utf8) }

    func testAReleaseTreeNamesItselfWithItsEngineID() throws {
        try select(first)
        XCTAssertEqual(ToolsAge.head(repo: tree.path), "engine:" + first)
    }

    func testAGameBuiltWithAnotherReleaseEngineIsMarkedAndOneBuiltWithTheSameIsNot() throws {
        try select(first)
        let built = (id: UUID(), titleID: "0100535012974000", commit: ToolsAge.head(repo: tree.path)!)
        XCTAssertEqual(ToolsAge.olderGames([built], repo: tree.path), [])
        try select(second)
        XCTAssertEqual(ToolsAge.olderGames([built], repo: tree.path), [built.id])
    }

    func testAGameWithNoRecordedEngineIsNeverMarked() throws {
        try select(second)
        XCTAssertEqual(ToolsAge.olderGames([(id: UUID(), titleID: "0100535012974000", commit: "")], repo: tree.path), [])
    }
}
