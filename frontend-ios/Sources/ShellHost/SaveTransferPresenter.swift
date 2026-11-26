import Foundation
#if canImport(UIKit)
import UIKit
import UniformTypeIdentifiers
#endif

/// Outcome of picking a save source (folder, `.zip` archive, or individual file) in Files on iOS.
public enum SaveSourcePickOutcome: Sendable {
    case picked(URL)
    case cancelled
    case unavailable
}

/// Outcome of presenting the system export / share sheet for a packed save `.zip`.
public enum SaveExportShareOutcome: Sendable {
    case exported
    case cancelled
    case unavailable
}

/// Abstracts iOS document picking and sharing for save import/export so `ShellHostModel` stays testable without UIKit.
public protocol SaveTransferPresenter: Sendable {
    @MainActor func pickSaveSourceOutcome() async -> SaveSourcePickOutcome
    @MainActor func presentExportArchive(at url: URL) async -> SaveExportShareOutcome
}

/// Default no-op presenter for non-UIKit hosts and headless tests.
public struct NoSaveTransferPresenter: SaveTransferPresenter {
    public init() {}
    @MainActor public func pickSaveSourceOutcome() async -> SaveSourcePickOutcome { .cancelled }
    @MainActor public func presentExportArchive(at url: URL) async -> SaveExportShareOutcome { .cancelled }
}

#if canImport(UIKit)
public struct DocumentSaveTransferPresenter: SaveTransferPresenter {
    public init() {}

    private nonisolated static func makeURLAnswer(_ continuation: CheckedContinuation<URL?, Never>) -> FolderPickAnswer<URL> {
        FolderPickAnswer { continuation.resume(returning: $0) }
    }

    private nonisolated static func makeShareAnswer(_ continuation: CheckedContinuation<Bool?, Never>) -> FolderPickAnswer<Bool> {
        FolderPickAnswer { continuation.resume(returning: $0) }
    }

    @MainActor public func pickSaveSourceOutcome() async -> SaveSourcePickOutcome {
        guard let presenter = DocumentFolderPicker.topViewController() else { return .unavailable }
        var types: [UTType] = [.folder, .zip, .data]
        if let savType = UTType(filenameExtension: "sav"), !types.contains(savType) {
            types.append(savType)
        }
        let url: URL? = await withCheckedContinuation { continuation in
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
            picker.allowsMultipleSelection = false
            let delegate = Delegate(answer: Self.makeURLAnswer(continuation))
            picker.delegate = delegate
            picker.presentationController?.delegate = delegate
            objc_setAssociatedObject(picker, &Delegate.key, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            presenter.present(picker, animated: true)
        }
        return url.map(SaveSourcePickOutcome.picked) ?? .cancelled
    }

    @MainActor public func presentExportArchive(at url: URL) async -> SaveExportShareOutcome {
        guard let presenter = DocumentFolderPicker.topViewController() else { return .unavailable }
        let completed: Bool? = await withCheckedContinuation { continuation in
            let answer = Self.makeShareAnswer(continuation)
            let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            activityVC.completionWithItemsHandler = { _, completed, _, _ in
                Task { @MainActor in
                    answer.finish(completed)
                }
            }
            if let popover = activityVC.popoverPresentationController {
                popover.sourceView = presenter.view
                popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
            presenter.present(activityVC, animated: true)
        }
        return (completed == true) ? .exported : .cancelled
    }

    private final class Delegate: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
        nonisolated(unsafe) static var key = 0
        private let answer: FolderPickAnswer<URL>
        init(answer: FolderPickAnswer<URL>) { self.answer = answer }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            DocumentPickerDismissWaiter.finishAfterDismiss(controller: controller, value: urls.first, answer: answer)
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentAt url: URL) {
            DocumentPickerDismissWaiter.finishAfterDismiss(controller: controller, value: url, answer: answer)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            DocumentPickerDismissWaiter.finishAfterDismiss(controller: controller, value: nil, answer: answer)
        }
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { answer.finish(nil) }
    }
}
#endif
