import XCTest
@testable import ShellUI

final class FocusNavigationTests: XCTestCase {
    private func target(_ id: String, _ x: CGFloat, _ y: CGFloat) -> FocusTarget {
        FocusTarget(id: id, frame: CGRect(x: x, y: y, width: 44, height: 44), activate: {})
    }
    func testDirectionalNavigationPrefersSameRowAndDoesNotWrap() {
        let targets = [target("a", 0, 0), target("b", 80, 0), target("c", 0, 100), target("d", 80, 100)]
        XCTAssertEqual(FocusNavigation.next(from: "a", action: .right, targets: targets), "b")
        XCTAssertEqual(FocusNavigation.next(from: "b", action: .down, targets: targets), "d")
        XCTAssertEqual(FocusNavigation.next(from: "d", action: .left, targets: targets), "c")
        XCTAssertEqual(FocusNavigation.next(from: "c", action: .left, targets: targets), "c")
        XCTAssertEqual(FocusNavigation.next(from: "missing", action: .down, targets: targets), "a")
        XCTAssertNil(FocusNavigation.next(from: nil, action: .down, targets: []))
    }
}

@MainActor final class NativeToolbarFocusTests: XCTestCase {
    func testClosingANativeSheetRestoresLibraryTargetsWithoutNewGeometry() {
        let targets = FocusTargetBuffer()
        let frame = CGRect(x: 20, y: 80, width: 44, height: 44)
        targets.libraryValues = [FocusTarget(id: "lib.tile.orbit", frame: frame, activate: {})]
        targets.values = [FocusTarget(id: "set.row.mode", frame: frame, activate: {})]
        XCTAssertEqual(targets.active(prefix: "set.", toolbarIDs: []).map(\.id), ["set.row.mode"])
        XCTAssertEqual(targets.active(prefix: "lib.", toolbarIDs: []).map(\.id), ["lib.tile.orbit"])
    }

    func testToolbarReplacesDuplicatePreferencesAndDropsInactiveScreenActions() {
        let targets = FocusTargetBuffer()
        var activations = 0
        let frame = CGRect(x: 20, y: 80, width: 44, height: 44)
        targets.values = [FocusTarget(id: "lib.settings", frame: frame, activate: {}),
                          FocusTarget(id: "set.play", frame: frame, activate: {})]
        targets.toolbarValues = [
            "lib.settings": FocusTarget(id: "lib.settings", frame: frame, activate: {}),
            "set.back": FocusTarget(id: "set.back", frame: frame, activate: { activations += 1 })]
        let active = targets.active(prefix: "set.", toolbarIDs: ["set.back"])
        XCTAssertEqual(Set(active.map(\.id)), ["set.back", "set.play"])
        active.first { $0.id == "set.back" }?.activate()
        XCTAssertEqual(activations, 1)
        XCTAssertEqual(targets.active(prefix: "lib.", toolbarIDs: ["lib.settings"]).count, 1)
    }
}
