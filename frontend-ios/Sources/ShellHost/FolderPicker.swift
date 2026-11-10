import Foundation
#if canImport(UIKit)
import UIKit
import UniformTypeIdentifiers
#endif

/// What asking for a folder came to. `unavailable` is a picker that could not be shown at all (no window to present from, as inside a
/// host app such as LiveContainer): the player is told, and not left with a button that does nothing (LNPANDY/NX2Apple#1049).
public enum FolderPickOutcome: Sendable {
    case picked(URL)
    case cancelled
    case unavailable
}

/// Asks the player for a folder. The shell's model only knows this protocol, so tests answer without UI.
public protocol FolderPicker: Sendable {
    /// The picked folder with the picker's security scope, or nil when the player cancelled.
    @MainActor func pickFolder() async -> URL?
    /// The same, telling a picker that could not be shown from a cancel. The default is `pickFolder`'s answer.
    @MainActor func pickFolderOutcome() async -> FolderPickOutcome
}

extension FolderPicker {
    @MainActor public func pickFolderOutcome() async -> FolderPickOutcome {
        if let url = await pickFolder() { return .picked(url) }
        return .cancelled
    }
}

/// No picker: always cancelled. The default on platforms without UIKit.
public struct NoFolderPicker: FolderPicker {
    public init() {}
    public func pickFolder() async -> URL? { nil }
}

/// Answers a picker exactly once. A hosted app (LiveContainer) may report a pick through the older single-document callback, report
/// nothing but a dismissal, or both, so every path ends here and a later one is ignored. Without it a picker that closes without a
/// delegate call left the shell waiting for ever (#1049).
public final class FolderPickAnswer<Value: Sendable> {
    private var resume: ((Value?) -> Void)?
    public private(set) var answered = false
    public init(_ resume: @escaping (Value?) -> Void) { self.resume = resume }
    /// The first call wins: a pick, or nil for a cancel or a dismissal.
    public func finish(_ value: Value?) {
        guard !answered else { return }
        answered = true
        resume?(value)
        resume = nil
    }
}

#if canImport(UIKit)
/// `UIDocumentPickerViewController` for a folder, opened in place (not copied) as the per-game app does, so the
/// bookmark keeps pointing at the player's drive or iCloud Drive folder.
public struct DocumentFolderPicker: FolderPicker {
    public init() {}

    @MainActor public func pickFolder() async -> URL? {
        if case .picked(let url) = await pickFolderOutcome() { return url }
        return nil
    }

    @MainActor public func pickFolderOutcome() async -> FolderPickOutcome {
        guard let presenter = Self.topViewController() else { return .unavailable }
        let url: URL? = await withCheckedContinuation { continuation in
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
            picker.allowsMultipleSelection = false
            let delegate = Delegate(answer: FolderPickAnswer { continuation.resume(returning: $0) })
            picker.delegate = delegate
            picker.presentationController?.delegate = delegate   // a sheet swiped away is a cancel, not a wait that never ends
            // The picker holds its delegate weakly: keep it for as long as the picker lives.
            objc_setAssociatedObject(picker, &Delegate.key, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            presenter.present(picker, animated: true)
        }
        return url.map(FolderPickOutcome.picked) ?? .cancelled
    }

    /// The view controller to present from: the key window of the active scene. A host app that runs this shell inside its own process
    /// (LiveContainer) can leave the scene inactive or have no key window, so the next best window of any scene is used before giving up.
    @MainActor static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let ordered = scenes.filter { $0.activationState == .foregroundActive }
            + scenes.filter { $0.activationState == .foregroundInactive }
            + scenes.filter { $0.activationState != .foregroundActive && $0.activationState != .foregroundInactive }
        for scene in ordered {
            let window = scene.keyWindow ?? scene.windows.first { $0.isKeyWindow } ?? scene.windows.first { !$0.isHidden }
            var top = window?.rootViewController
            while let next = top?.presentedViewController { top = next }
            if let top { return top }
        }
        return nil
    }

    private final class Delegate: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
        nonisolated(unsafe) static var key = 0
        private let answer: FolderPickAnswer<URL>
        init(answer: FolderPickAnswer<URL>) { self.answer = answer }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { answer.finish(urls.first) }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentAt url: URL) { answer.finish(url) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { answer.finish(nil) }
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { answer.finish(nil) }
    }
}
#endif
