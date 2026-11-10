import Foundation
import Testing
@testable import ShellUI

/// Keys set to Toggle in the touch layout editor (#658): stored with the layout, passed to every game as DM_TOUCH_TOGGLE.
@Suite struct TouchToggleTests {
    private func store() -> ShellSettingsStore { ShellSettingsStore(defaults: UserDefaults(suiteName: "t-toggle-\(UUID().uuidString)")!) }

    @Test func onlySingleKeysToggle() {
        let toggleable = TouchLayout.Control.allCases.filter(\.canToggle).map(\.rawValue)
        #expect(toggleable == ["a", "b", "x", "y", "zl", "l", "zr", "r", "l3", "r3", "minus", "plus"])
        var layout = TouchLayout()
        layout.setToggles(.stick, true)
        layout.setToggles(.face, true)
        layout.setToggles(.dpad, true)
        #expect(!layout.hasToggles && layout.encodedToggles.isEmpty)
    }

    @Test func theValueIsTheEngineOrderAndReadsBack() {
        var layout = TouchLayout()
        layout.setToggles(.zr, true)
        layout.setToggles(.a, true)
        layout.setToggles(.zl, true)
        #expect(layout.encodedToggles == "a,zl,zr")
        var read = TouchLayout()
        read.readToggles("zr,home,stick,a,,zl")
        #expect(read.toggles == [.a, .zl, .zr])
        layout.setToggles(.a, false)
        #expect(layout.encodedToggles == "zl,zr")
        // Toggles are no places: the layout's own value and its emptiness stay as they were.
        #expect(layout.isEmpty && layout.encoded.isEmpty && layout.hasToggles)
    }

    @Test func defaultIsHoldAndNothingIsPassed() {
        let store = store()
        #expect(!store.touchLayout.hasToggles)
        #expect(store.gameDefaults["DM_TOUCH_TOGGLE"] == nil)
    }

    @MainActor @Test func theEditorSavesTheModeOfTheChosenKey() {
        let store = store()
        let model = TouchLayoutEditorModel(store: store)
        model.select(.zr)
        #expect(!model.selectedToggles)
        model.setToggles(true)
        #expect(model.selectedToggles && model.hasChanges)
        #expect(!store.touchLayout.hasToggles)   // a draft until Save
        model.commit()
        #expect(store.touchLayout.toggles == [.zr])
        #expect(store.gameDefaults["DM_TOUCH_TOGGLE"] == "zr")
        #expect(store.gameDefaults["DM_TOUCH_LAYOUT"] == nil)

        let reopened = TouchLayoutEditorModel(store: store)
        #expect(!reopened.hasChanges)
        reopened.select(.zr)
        #expect(reopened.selectedToggles)
        reopened.setToggles(false)
        reopened.commit()
        #expect(store.gameDefaults["DM_TOUCH_TOGGLE"] == nil)
        #expect(store.defaults.object(forKey: ShellSettingsStore.touchToggleKey) == nil)
    }

    @MainActor @Test func theDiamondAndTheStickHaveNoMode() {
        let model = TouchLayoutEditorModel(store: store())
        model.select(.face)
        model.setToggles(true)
        model.select(.stick)
        model.setToggles(true)
        #expect(!model.hasChanges)
    }

    @MainActor @Test func resettingPlacesKeepsTheModes() {
        let store = store()
        let model = TouchLayoutEditorModel(store: store)
        model.select(.l)
        model.setToggles(true)
        model.select(.stick)
        #expect(model.nudge(dx: 1, dy: 0) == .moved)
        model.askReset()
        model.reset()
        model.commit()
        #expect(store.touchLayout.isEmpty && store.touchLayout.toggles == [.l])
        store.resetTouchLayout(.threeD)
        #expect(store.touchLayout.toggles == [.l])
    }

    @Test func voiceOverSaysTheModeOfAKey() {
        #expect(TouchLayoutEditorView.accessibilityValue(.zl, moved: false, toggles: true)
                == ShellStrings.text("In its place") + ", " + ShellStrings.text("Toggle"))
        #expect(TouchLayoutEditorView.accessibilityValue(.a, moved: true, toggles: false)
                == ShellStrings.text("Moved") + ", " + ShellStrings.text("Hold"))
        #expect(TouchLayoutEditorView.accessibilityValue(.stick, moved: false, toggles: false) == ShellStrings.text("In its place"))
    }
}
