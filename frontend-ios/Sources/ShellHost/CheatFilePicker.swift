import Foundation
#if canImport(UIKit)
import UIKit
import UniformTypeIdentifiers
#endif

/// Outcome of picking a `.txt` cheat file from Files on iOS.
public enum CheatFilePickOutcome: Sendable {
    case picked(data: Data, fileName: String)
    case cancelled
    case unavailable
    case unreadable
    case tooLarge
}

/// Abstracts picking an Atmosphère `.txt` cheat file so `ShellHostModel` stays testable without UIKit.
public protocol CheatFilePicker: Sendable {
    @MainActor func pickCheatFileOutcome() async -> CheatFilePickOutcome
}

public struct NoCheatFilePicker: CheatFilePicker {
    public init() {}
    @MainActor public func pickCheatFileOutcome() async -> CheatFilePickOutcome { .cancelled }
}

#if canImport(UIKit)
public struct DocumentCheatFilePicker: CheatFilePicker {
    /// Matches `hle_cheats.c` and `cheat_bake.py` FILE_MAX (4 MiB).
    public static let maxFileBytes = 4 * 1024 * 1024

    public init() {}

    private nonisolated static func makeAnswer(_ continuation: CheckedContinuation<URL?, Never>) -> FolderPickAnswer<URL> {
        FolderPickAnswer { continuation.resume(returning: $0) }
    }

    @MainActor public func pickCheatFileOutcome() async -> CheatFilePickOutcome {
        guard let presenter = DocumentFolderPicker.topViewController() else { return .unavailable }
        var types: [UTType] = [.plainText]
        if let txt = UTType(filenameExtension: "txt"), !types.contains(txt) {
            types.append(txt)
        }
        let copiedURL: URL? = await withCheckedContinuation { continuation in
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
            picker.allowsMultipleSelection = false
            let delegate = Delegate(answer: Self.makeAnswer(continuation))
            picker.delegate = delegate
            picker.presentationController?.delegate = delegate
            objc_setAssociatedObject(picker, &Delegate.key, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            presenter.present(picker, animated: true)
        }
        guard let copiedURL else { return .cancelled }
        let limit = Self.maxFileBytes
        return await Task.detached(priority: .userInitiated) {
            defer { try? FileManager.default.removeItem(at: copiedURL) }
            let fileName = copiedURL.lastPathComponent
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: copiedURL.path),
                  let size = (attrs[.size] as? NSNumber)?.int64Value,
                  size >= 0 else {
                return CheatFilePickOutcome.unreadable
            }
            guard size <= Int64(limit) else {
                return CheatFilePickOutcome.tooLarge
            }
            guard let data = try? Data(contentsOf: copiedURL) else { return CheatFilePickOutcome.unreadable }
            return CheatFilePickOutcome.picked(data: data, fileName: fileName)
        }.value
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
