import Foundation
import Testing
@testable import ShellUI

/// The touch controls settings (#347): the size row and the preview's geometry.
@Suite struct TouchControlsTests {
    private func store() -> ShellSettingsStore { ShellSettingsStore(defaults: UserDefaults(suiteName: "t-touch-\(UUID().uuidString)")!) }

    @Test func theSizeRowOffersTheEngineSizesAndStoresThem() {
        let store = store()
        let row = ShellSettingsRows.touchSizeRow(store)
        guard case .choice(let options) = row.kind else { Issue.record("not a choice"); return }
        #expect(options.map(\.id) == ShellSettingsStore.touchSizes && row.value == "medium")
        ShellSettingsRows.apply(row.id, value: "small", to: store)
        #expect(ShellSettingsRows.touchSizeRow(store).value == "small" && store.gameDefaults["DM_TOUCH_SIZE"] == "small")
    }

    @Test func theSizeRowIsSegmentedOnAPhone() {
        guard case .choice(let options) = ShellSettingsRows.touchSizeRow(store()).kind else { return }
        #expect(ChoicePresentation.resolve(labels: options.map(\.label), width: 320, textScale: 1) == .segmented)
    }

    /// The preview mirrors the engine's built-in layout on iPhone Pro Max (DmPadGeometry.h): the same points at medium.
    @Test func thePreviewAtMediumIsTheEnginesLayout() {
        let g = TouchPadPreviewGeometry(size: "medium")
        #expect(g.face == CGPoint(x: 932 - 29.5 - 81, y: 430 - 21 - 82))
        #expect(g.stick == CGPoint(x: 29.5 + 81, y: 430 - 21 - 82))
        #expect(g.dpad == CGPoint(x: 29.5 + 231, y: 430 - 21 - 64))
    }

    @Test(arguments: ShellSettingsStore.touchSizes)
    func everyPreviewShapeIsOnTheScreenAndClearOfTheOthers(size: String) {
        let screen = CGRect(origin: .zero, size: TouchPadPreviewGeometry.screen)
        let boxes = TouchPadPreviewGeometry(size: size).shapes.map(TouchPadPreviewGeometry.bounds)
        for box in boxes { #expect(screen.contains(box), "\(size): \(box) leaves the screen") }
        // Bounding boxes of the round keys may touch at their corners, so compare the circles by their centres.
        let shapes = TouchPadPreviewGeometry(size: size).shapes
        for i in shapes.indices {
            for j in shapes.indices where j > i {
                if case .circle(let a, let ra, _) = shapes[i], case .circle(let b, let rb, _) = shapes[j] {
                    #expect(hypot(a.x - b.x, a.y - b.y) >= ra + rb, "\(size): keys \(i) and \(j) overlap")
                }
            }
        }
    }

    @Test func theStickRowOffersTheEnginePlacesAndStoresThem() {
        let store = store()
        let row = ShellSettingsRows.touchStickRow(store)
        guard case .choice(let options) = row.kind else { Issue.record("not a choice"); return }
        #expect(options.map(\.id) == ShellSettingsStore.touchStickPlaces && row.value == "corner")
        #expect(ChoicePresentation.resolve(labels: options.map(\.label), width: 320, textScale: 1) == .segmented)
        ShellSettingsRows.apply(row.id, value: "higher", to: store)
        #expect(store.touchStick == "higher" && store.gameDefaults["DM_TOUCH_STICK"] == "higher")
    }

    /// The preview moves only the left stick (and for inward the D-pad with it), as the engine does (DmPadGeometry.h, patch 0066).
    @Test(arguments: ShellSettingsStore.touchSizes)
    func thePreviewMovesTheStickAndNothingOnTheRight(size: String) {
        let corner = TouchPadPreviewGeometry(size: size), higher = TouchPadPreviewGeometry(size: size, stick: "higher"),
            inward = TouchPadPreviewGeometry(size: size, stick: "inward")
        #expect(higher.stick.x == corner.stick.x && corner.stick.y - higher.stick.y >= 30 * corner.u)
        #expect(inward.stick.y == corner.stick.y && inward.stick.x - corner.stick.x >= 30 * corner.u)
        #expect(abs((inward.dpad.x - corner.dpad.x) - (inward.stick.x - corner.stick.x)) < 0.001 && higher.dpad == corner.dpad)
        #expect(higher.face == corner.face && inward.face == corner.face)
        for g in [higher, inward] {
            let screen = CGRect(origin: .zero, size: TouchPadPreviewGeometry.screen)
            for box in g.shapes.map(TouchPadPreviewGeometry.bounds) { #expect(screen.contains(box)) }
        }
    }

    /// Reset all controls asks first: the first press only asks, Cancel keeps every move, the answer resets the shown layout alone.
    @MainActor @Test func resetAllAsksBeforeItActs() {
        let store = store()
        let m = TouchLayoutEditorModel(store: store, kind: .threeD)
        m.askReset()
        #expect(!m.confirmingReset, "nothing moved, nothing to ask")
        m.setKind(.twoD); m.select(.stick); m.nudge(dx: 0, dy: -1)
        m.setKind(.threeD); m.select(.face); m.nudge(dx: -1, dy: 0)
        let moved = store.touchLayout
        m.askReset()
        #expect(m.confirmingReset && store.touchLayout == moved && !m.layoutIsBuiltIn)
        m.cancelReset()
        #expect(!m.confirmingReset && store.touchLayout == moved)
        m.askReset(); m.setKind(.twoD)
        #expect(!m.confirmingReset, "another layout drops the question")
        m.setKind(.threeD); m.askReset(); m.reset()
        #expect(!m.confirmingReset && m.layoutIsBuiltIn)
        #expect(store.touchLayout.isEmpty(.threeD) && !store.touchLayout.isEmpty(.twoD), "the 2D layout keeps its move")
    }

    /// The column beside the preview held sideways fits the smallest phone and never grows past the buttons' room on an iPad.
    @Test func theSidewaysColumnFitsEveryPhone() {
        #expect(TouchLayoutEditorView.column(width: 667) == 250)
        #expect(TouchLayoutEditorView.column(width: 832) == 283)
        #expect(TouchLayoutEditorView.column(width: 1376) == 340)
    }

    @Test func theSizesKeepTheirOrder() {
        #expect(TouchPadPreviewGeometry(size: "small").u < TouchPadPreviewGeometry(size: "medium").u)
        #expect(TouchPadPreviewGeometry(size: "large").u > TouchPadPreviewGeometry(size: "medium").u)
    }
}
