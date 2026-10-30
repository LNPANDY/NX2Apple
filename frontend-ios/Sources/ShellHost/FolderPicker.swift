import Foundation
#if canImport(UIKit)
import UIKit
import UniformTypeIdentifiers
#endif

/// Asks the player for a folder. The shell's model only knows this protocol, so tests answer without UI.
public protocol FolderPicker: Sendable {
    /// The picked folder with the picker's security scope, or nil when the player cancelled.
    @MainActor func pickFolder() async -> URL?
}

/// No picker: always cancelled. The default on platforms without UIKit.
public struct NoFolderPicker: FolderPicker {
    public init() {}
    public func pickFolder() async -> URL? { nil }
}

#if canImport(UIKit)
/// `UIDocumentPickerViewController` for a folder, opened in place (not copied) as the per-game app does, so the
/// bookmark keeps pointing at the player's drive or iCloud Drive folder.
public struct DocumentFolderPicker: FolderPicker {
    public init() {}

    @MainActor public func pickFolder() async -> URL? {
        guard let presenter = Self.topViewController() else { return nil }
        return await withCheckedContinuation { continuation in
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
            picker.allowsMultipleSelection = false
            let delegate = Delegate(continuation: continuation)
            picker.delegate = delegate
            // The picker holds its delegate weakly: keep it for as long as the picker lives.
            objc_setAssociatedObject(picker, &Delegate.key, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            presenter.present(picker, animated: true)
        }
    }

    @MainActor private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
        var top = scene?.keyWindow?.rootViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }

    private final class Delegate: NSObject, UIDocumentPickerDelegate {
        nonisolated(unsafe) static var key = 0
        private var continuation: CheckedContinuation<URL?, Never>?
        init(continuation: CheckedContinuation<URL?, Never>) { self.continuation = continuation }
        private func finish(_ url: URL?) { continuation?.resume(returning: url); continuation = nil }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { finish(urls.first) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish(nil) }
    }
}
#endif
