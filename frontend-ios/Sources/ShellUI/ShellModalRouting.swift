import Foundation

/// Determines which presentation layer owns a host-level notice alert so it always appears above the active sheet or modal.
public enum ShellNoticeHost: Equatable, Sendable {
    case root
    case menuSheet
    case coverCrop
    case hostSheet
    case deferred

    /// Resolves the single topmost presenter for host notices across all active shell modals.
    public static func resolve(
        menuSheetPresented: Bool,
        coverCropPresented: Bool,
        touchEditorPresented: Bool,
        hostSheetPresented: Bool
    ) -> ShellNoticeHost {
        if coverCropPresented { return .coverCrop }
        if touchEditorPresented { return .deferred }
        if menuSheetPresented { return .menuSheet }
        if hostSheetPresented { return .hostSheet }
        return .root
    }
}

/// Pure policy deciding when the hidden iOS keyboard-command responder may claim or must yield first responder.
enum ShellKeyboardCommandPolicy {
    static func shouldBecomeFirstResponder(
        active: Bool,
        inWindow: Bool,
        alreadyFirstResponder: Bool,
        hostHasPresentedModal: Bool,
        windowHasTextInputFirstResponder: Bool
    ) -> Bool {
        active && inWindow && !alreadyFirstResponder && !hostHasPresentedModal && !windowHasTextInputFirstResponder
    }

    static func shouldResignFirstResponder(
        active: Bool,
        alreadyFirstResponder: Bool,
        hostHasPresentedModal: Bool
    ) -> Bool {
        alreadyFirstResponder && (!active || hostHasPresentedModal)
    }
}
