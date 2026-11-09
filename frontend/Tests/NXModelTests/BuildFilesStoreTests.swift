import XCTest
@testable import NXModel

/// Build files (#232): the store measures off the main actor, lists the largest first, asks before a removal and never removes the
/// files of the game that builds.
@MainActor final class BuildFilesStoreTests: XCTestCase {
    private final class Disk: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes: [String: Int64]
        private(set) var removed: [String] = []
        init(_ bytes: [String: Int64]) { self.bytes = bytes }
        func size(_ folder: String) -> Int64 { lock.withLock { bytes[folder] ?? 0 } }
        func remove(_ folder: String) -> Int64 {
            lock.withLock { let freed = bytes[folder] ?? 0; bytes[folder] = 0; removed.append(folder); return freed }
        }
    }

    private let a = UUID(), b = UUID(), c = UUID()

    private func store(_ disk: Disk) -> BuildFilesStore {
        BuildFilesStore(measure: { disk.size($0.folder) }, remove: { disk.remove($0.folder) })
    }

    private var games: [BuildFilesStore.Game] {
        [.init(id: a, name: "Hades", folder: "/out/a_build"), .init(id: b, name: "Zelda", folder: "/out/b_build"),
         .init(id: c, name: "Celeste", folder: "/out/c_build")]
    }

    func testTheListIsLargestFirstWithTheTotalAndLeavesOutAFolderWithNothingToRemove() async {
        let disk = Disk(["/out/a_build": 2_000, "/out/b_build": 31_000, "/out/c_build": 0])
        let store = store(disk)
        XCTAssertFalse(store.isMeasured(a))
        await store.refresh(games).value
        XCTAssertEqual(store.entries.map(\.name), ["Zelda", "Hades"])
        XCTAssertEqual(store.total, 33_000)
        XCTAssertTrue(store.isMeasured(c))
        XCTAssertNil(store.entry(c), "nothing to remove: no menu item, no row")
        XCTAssertFalse(store.measuring)
    }

    func testSameSizeSortsByName() {
        let x = BuildFilesStore.Entry(id: UUID(), name: "b", folder: "", bytes: 5), y = BuildFilesStore.Entry(id: UUID(), name: "a", folder: "", bytes: 5)
        XCTAssertEqual(BuildFilesStore.sorted([x, y]).map(\.name), ["a", "b"])
    }

    func testRemovingAsksFirstAndMeasuresAgain() async {
        let disk = Disk(["/out/a_build": 2_000, "/out/b_build": 31_000])
        let store = store(disk)
        await store.refresh(games).value
        store.ask(b, building: false)
        XCTAssertEqual(store.confirmingEntry?.name, "Zelda")
        XCTAssertTrue(disk.removed.isEmpty, "the question removes nothing")
        await store.remove(b, building: false)?.value
        XCTAssertNil(store.confirming)
        XCTAssertEqual(disk.removed, ["/out/b_build"])
        XCTAssertEqual(store.entries.map(\.name), ["Hades"])
        XCTAssertTrue(store.isMeasured(b))
    }

    func testNeverWhileThatGameBuilds() async {
        let disk = Disk(["/out/a_build": 2_000])
        let store = store(disk)
        await store.refresh(games).value
        store.ask(a, building: true)
        XCTAssertNil(store.confirming, "no question for the game that builds")
        XCTAssertNil(store.remove(a, building: true))
        XCTAssertTrue(disk.removed.isEmpty)
        XCTAssertEqual(store.entry(a)?.bytes, 2_000)
    }

    func testAFailureIsKeptForTheCard() async {
        struct Failed: LocalizedError { var errorDescription: String? { "Permission denied" } }
        let store = BuildFilesStore(measure: { _ in 100 }, remove: { _ in throw Failed() })
        await store.refresh(games).value
        await store.remove(a, building: false)?.value
        XCTAssertEqual(store.failure, "Permission denied")
        XCTAssertEqual(store.entry(a)?.bytes, 100, "what is still there stays listed")
    }
}
