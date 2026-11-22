import Testing
@testable import ShellUI

@Suite struct ShellModalRoutingTests {
    @Test func noticeHostAlwaysResolvesSingleTopmostPresenter() {
        #expect(ShellNoticeHost.resolve(menuSheetPresented: false, coverCropPresented: false, touchEditorPresented: false, hostSheetPresented: false) == .root)
        #expect(ShellNoticeHost.resolve(menuSheetPresented: false, coverCropPresented: false, touchEditorPresented: false, hostSheetPresented: true) == .hostSheet)
        #expect(ShellNoticeHost.resolve(menuSheetPresented: true, coverCropPresented: false, touchEditorPresented: false, hostSheetPresented: false) == .menuSheet)
        #expect(ShellNoticeHost.resolve(menuSheetPresented: true, coverCropPresented: false, touchEditorPresented: false, hostSheetPresented: true) == .menuSheet)
        #expect(ShellNoticeHost.resolve(menuSheetPresented: true, coverCropPresented: false, touchEditorPresented: true, hostSheetPresented: false) == .deferred)
        #expect(ShellNoticeHost.resolve(menuSheetPresented: true, coverCropPresented: true, touchEditorPresented: false, hostSheetPresented: false) == .coverCrop)
        #expect(ShellNoticeHost.resolve(menuSheetPresented: false, coverCropPresented: true, touchEditorPresented: false, hostSheetPresented: true) == .coverCrop)
    }

    @Test func keyboardCommandResponderYieldsToModalsAndTextInput() {
        #expect(ShellKeyboardCommandPolicy.shouldBecomeFirstResponder(
            active: true, inWindow: true, alreadyFirstResponder: false,
            hostHasPresentedModal: false, windowHasTextInputFirstResponder: false
        ))
        // Must never steal focus when an alert, sheet, or document picker is presented above the host VC.
        #expect(!ShellKeyboardCommandPolicy.shouldBecomeFirstResponder(
            active: true, inWindow: true, alreadyFirstResponder: false,
            hostHasPresentedModal: true, windowHasTextInputFirstResponder: false
        ))
        // Must never steal focus when a SecureField / TextField already owns keyboard input.
        #expect(!ShellKeyboardCommandPolicy.shouldBecomeFirstResponder(
            active: true, inWindow: true, alreadyFirstResponder: false,
            hostHasPresentedModal: false, windowHasTextInputFirstResponder: true
        ))
        // Must resign immediately when a modal presents above it, even if `active` was not toggled yet.
        #expect(ShellKeyboardCommandPolicy.shouldResignFirstResponder(
            active: true, alreadyFirstResponder: true, hostHasPresentedModal: true
        ))
        #expect(ShellKeyboardCommandPolicy.shouldResignFirstResponder(
            active: false, alreadyFirstResponder: true, hostHasPresentedModal: false
        ))
        #expect(!ShellKeyboardCommandPolicy.shouldResignFirstResponder(
            active: true, alreadyFirstResponder: true, hostHasPresentedModal: false
        ))
    }
}
