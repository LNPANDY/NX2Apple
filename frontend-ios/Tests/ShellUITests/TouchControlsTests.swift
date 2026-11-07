import Foundation
import Testing
@testable import ShellUI

/// The touch controls settings (#347): the size row and the preview's geometry.
@Suite struct TouchControlsTests {
    private func store() -> ShellSettingsStore { ShellSettingsStore(defaults: UserDefaults(suiteName: "t-touch-\(UUID().uuidString)")!) }

    @MainActor @Test func savedModeReopensAndUsesTheExistingEngineSetting() {
        let store = store()
        #expect(store.gameDefaults["DM_PROF_PAD_LAYOUT"] == nil)
        let editor = TouchLayoutEditorModel(store: store)
        editor.setKind(.twoD)
        #expect(store.touchMode == "3d")
        editor.commit()
        #expect(store.touchMode == "2d" && store.gameDefaults["DM_PROF_PAD_LAYOUT"] == "0")
        let reopened = TouchLayoutEditorModel(store: store)
        #expect(reopened.kind == .twoD && !reopened.hasChanges)
        reopened.updateScreen(.duoUpright)
        #expect(reopened.kind == .twoDSplit && !reopened.hasChanges)
        reopened.setKind(.threeDSplit)
        reopened.commit()
        #expect(TouchLayoutEditorModel(store: store).kind == .threeD)
        #expect(store.gameDefaults["DM_PROF_PAD_LAYOUT"] == "1")
        store.storeTouchMode("invalid")
        #expect(store.touchMode == "3d")
    }

    @MainActor @Test(arguments: ["noop", "size", "stick", "arrangement", "pose"])
    func savingOtherEditorStateKeepsAnUnsetModeUnset(edit: String) {
        let store = store()
        let model = TouchLayoutEditorModel(store: store, upright: edit == "pose" ? .duoUpright : nil)
        switch edit {
        case "size": model.setSize("large")
        case "stick": model.setStick("higher")
        case "arrangement":
            model.select(.stick)
            #expect(model.nudge(dx: 1, dy: 0) == .moved)
        case "pose": model.setKind(.threeDSplit)
        default: break
        }

        model.commit()

        #expect(store.defaults.object(forKey: ShellSettingsStore.touchModeKey) == nil)
        #expect(store.gameDefaults["DM_PROF_PAD_LAYOUT"] == nil)
        if edit == "size" { #expect(store.touchSize == "large") }
        if edit == "stick" { #expect(store.touchStick == "higher") }
        if edit == "arrangement" { #expect(!store.touchLayout.isEmpty) }
    }

    @MainActor @Test func changingModeBackToItsInitialValueLeavesThePreferenceUnchanged() {
        let unset = store()
        let model = TouchLayoutEditorModel(store: unset)
        model.setKind(.twoD)
        model.setKind(.threeD)
        #expect(!model.hasChanges)
        model.commit()
        #expect(unset.defaults.object(forKey: ShellSettingsStore.touchModeKey) == nil)

        for initial in ["2d", "3d"] {
            let saved = store()
            saved.storeTouchMode(initial)
            let editor = TouchLayoutEditorModel(store: saved)
            editor.setKind(initial == "2d" ? .threeD : .twoD)
            editor.setKind(initial == "2d" ? .twoD : .threeD)
            #expect(!editor.hasChanges)
            editor.commit()
            #expect(saved.defaults.string(forKey: ShellSettingsStore.touchModeKey) == initial)
        }
    }

    @MainActor @Test func discardingAChangedModeDoesNotStoreIt() {
        let store = store()
        let model = TouchLayoutEditorModel(store: store)
        model.setKind(.twoD)
        #expect(!model.requestExit() && model.confirmingExit)
        #expect(store.defaults.object(forKey: ShellSettingsStore.touchModeKey) == nil)
        #expect(store.gameDefaults["DM_PROF_PAD_LAYOUT"] == nil)
    }

    @MainActor @Test(arguments: ["2d", "3d"])
    func unrelatedSavePreservesAnExplicitMode(mode: String) {
        let store = store()
        store.storeTouchMode(mode)
        let model = TouchLayoutEditorModel(store: store)
        model.setSize("large")
        model.updateScreen(.duoUpright)
        model.commit()
        let reopened = ShellSettingsStore(defaults: store.defaults)
        #expect(reopened.touchSize == "large")
        #expect(reopened.defaults.string(forKey: ShellSettingsStore.touchModeKey) == mode)
        #expect(reopened.gameDefaults["DM_PROF_PAD_LAYOUT"] == (mode == "3d" ? "1" : "0"))
    }

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

    /// Reset all asks first, edits stay local until commit, and resetting one layout keeps the other saved layouts.
    @MainActor @Test func resetAllAsksBeforeItActs() {
        let store = store()
        var original = TouchLayout()
        original[.threeDSplit, .stick] = TouchLayout.Offset(dx: 2, dy: -1)
        store.storeTouchLayout(original)
        let m = TouchLayoutEditorModel(store: store, kind: .threeD)
        m.askReset()
        #expect(!m.confirmingReset, "nothing moved, nothing to ask")
        m.setKind(.twoD); m.select(.stick); m.nudge(dx: 0, dy: -1)
        m.setKind(.threeD); m.select(.face); m.nudge(dx: -1, dy: 0)
        let moved = m.editing.layout
        #expect(store.touchLayout == original, "editing is a draft until confirmation")
        m.askReset()
        #expect(m.confirmingReset && m.editing.layout == moved && !m.layoutIsBuiltIn)
        m.cancelReset()
        #expect(!m.confirmingReset && m.editing.layout == moved)
        m.askReset(); m.setKind(.twoD)
        #expect(!m.confirmingReset, "another layout drops the question")
        m.setKind(.threeD); m.askReset(); m.reset()
        #expect(!m.confirmingReset && m.layoutIsBuiltIn)
        #expect(store.touchLayout == original, "reset remains a draft too")
        m.commit()
        #expect(store.touchLayout.isEmpty(.threeD) && !store.touchLayout.isEmpty(.twoD), "the 2D move is saved")
        #expect(store.touchLayout[.threeDSplit, .stick] == original[.threeDSplit, .stick], "the split layout is preserved")
    }

    @Test func theSizesKeepTheirOrder() {
        #expect(TouchPadPreviewGeometry(size: "small").u < TouchPadPreviewGeometry(size: "medium").u)
        #expect(TouchPadPreviewGeometry(size: "large").u > TouchPadPreviewGeometry(size: "medium").u)
    }
    @MainActor @Test func presetsAndCustomPositionsShareOneDraft() {
        let store = store()
        var original = TouchLayout()
        original[.threeDSplit, .stick] = .init(dx: 2, dy: -1)
        store.storeTouchLayout(original)
        let discarded = TouchLayoutEditorModel(store: store)
        discarded.setSize("large"); discarded.setStick("inward")
        discarded.select(.stick); discarded.nudge(dx: 0, dy: -1)
        #expect(store.touchSize == "medium" && store.touchStick == "corner")
        #expect(store.touchLayout == original)
        let saved = TouchLayoutEditorModel(store: store)
        saved.setSize("small"); saved.setStick("higher")
        saved.select(.stick); saved.nudge(dx: 0, dy: -1)
        let grouped = saved.editing.layout
        saved.setTogether(false)
        #expect(saved.editing.layout == grouped, "ungrouping must not move saved controls")
        #expect(saved.editing.layout[.threeDSplit, .stick] == original[.threeDSplit, .stick])
        let draft = saved.editing.layout
        saved.commit()
        #expect(store.touchSize == "small" && store.touchStick == "higher")
        #expect(store.touchLayout == draft)
        saved.setSize("invalid"); saved.setStick("invalid")
        #expect(saved.editing.size == "small" && saved.editing.stick == "higher")
    }

    /// A live pose change selects the engine's separated or over-the-picture layout while preserving the draft for every pose.
    @MainActor @Test func liveSurfaceChangesKeepAllLayoutDraftsAndCancelTransientState() {
        let store = store()
        var original = TouchLayout()
        original[.twoD, .a] = .init(dx: 2, dy: 1)
        original[.threeDSplit, .plus] = .init(dx: -3, dy: 2)
        store.storeTouchLayout(original)

        let model = TouchLayoutEditorModel(store: store, sideways: .proMax)
        model.select(.stick)
        #expect(model.nudge(dx: 0, dy: -1) == .moved)
        model.setSize("large")
        model.setStick("inward")
        let draft = model.editing.layout
        #expect(draft[.twoD, .a] == original[.twoD, .a])
        #expect(draft[.threeD, .stick] == .init(dx: 0, dy: -1))
        #expect(draft[.threeDSplit, .plus] == original[.threeDSplit, .plus])

        model.pickUp(.stick)
        model.dragTo(.stick, from: model.dragOffset(.stick), by: CGSize(width: 10_000, height: 0))
        #expect(model.invalidPlacement)
        model.askReset()
        #expect(model.confirmingReset)

        model.updateScreen(.duoUpright)
        #expect(model.kind == .threeDSplit, "the inner portrait surface separates the controls")
        #expect(model.editing.screen == .duoUpright)
        #expect(model.editing.layout == draft, "pose adaptation must not prune or replace any saved/draft offsets")
        #expect(model.selected == .stick && !model.held)
        #expect(!model.invalidPlacement && !model.rejected && !model.confirmingReset)
        #expect(model.editing.size == "large" && model.editing.stick == "inward")

        model.updateScreen(.proMax)
        #expect(model.kind == .threeD, "the landscape surface returns to the over-the-picture variant")
        #expect(model.editing.screen == .proMax && model.editing.layout == draft)
        #expect(model.selected == .stick && !model.held)

        model.setKind(.twoD)
        model.updateScreen(.duoUpright)
        #expect(model.kind == .twoDSplit, "the same pose adaptation retains the selected 2D layout")
        #expect(model.editing.layout == draft)
    }

    @MainActor @Test func exitOnlyConfirmsUnsavedPersistentChanges() {
        let store = store()
        let model = TouchLayoutEditorModel(store: store)
        #expect(!model.hasChanges && model.requestExit() && !model.confirmingExit)
        model.setKind(.twoD)
        #expect(model.hasChanges && !model.requestExit(), "2D/3D is a saved choice")
        model.confirmingExit = false
        model.setKind(.threeD)
        model.setTogether(false)
        #expect(!model.hasChanges, "grouping is temporary; reverting the mode clears its change")
        model.setSize("large")
        #expect(model.hasChanges && !model.requestExit() && model.confirmingExit)
        #expect(store.touchSize == "medium", "requesting Exit must not save the draft")
        model.confirmingExit = false
        model.setSize("medium")
        #expect(!model.hasChanges && model.requestExit())
        model.select(.stick)
        #expect(model.nudge(dx: 0, dy: -1) == .moved)
        #expect(model.hasChanges && !model.requestExit())
        model.putBack()
        #expect(!model.hasChanges)
        model.setStick("higher")
        #expect(model.hasChanges && !model.requestExit())
    }

}
