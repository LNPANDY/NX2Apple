#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import ShellUI

@MainActor
@Suite(.serialized)
struct TouchEditorPresentationTests {
    @Test func reopeningDuringDismissalPresentsAReplacement() {
        let (window, presenter) = host()
        defer { window.isHidden = true; window.rootViewController = nil }
        let rendered = RenderLog()

        presenter.content = content("initial", loggingTo: rendered)
        presenter.updatePresentation()
        #expect(presenter.editors.count == 1)
        presenter.finishPresentation()

        guard let closingEditor = presenter.editors.first else { return }
        presenter.content = nil
        presenter.updatePresentation()
        #expect(presenter.hasPendingDismissal)

        presenter.content = content("intermediate", loggingTo: rendered)
        presenter.updatePresentation()
        presenter.content = content("latest", loggingTo: rendered)
        presenter.updatePresentation()
        presenter.finishDismissal()

        #expect(presenter.editors.count == 2)
        guard presenter.editors.count == 2 else { return }
        #expect(presenter.editors[1] !== closingEditor)
        #expect(presenter.editors[1].contentUpdates == 1)
        #expect(presenter.hasPendingPresentation)
        #expect(rendered.markers.contains("latest"))
        #expect(!rendered.markers.contains("intermediate"))
    }

    @Test func removingPendingContentDuringDismissalCancelsReopen() {
        let (window, presenter) = host()
        defer { window.isHidden = true; window.rootViewController = nil }

        presenter.content = content("initial")
        presenter.updatePresentation()
        presenter.finishPresentation()

        presenter.content = nil
        presenter.updatePresentation()
        #expect(presenter.hasPendingDismissal)

        presenter.content = content("pending")
        presenter.updatePresentation()
        presenter.content = nil
        presenter.updatePresentation()
        presenter.finishDismissal()

        #expect(presenter.editors.count == 1)
        #expect(!presenter.hasPendingPresentation)
    }

    @Test func removingContentBeforePresentationCompletesDismissesWithoutReopening() {
        let (window, presenter) = host()
        defer { window.isHidden = true; window.rootViewController = nil }

        presenter.content = content("initial")
        presenter.updatePresentation()
        #expect(presenter.editors.count == 1)
        #expect(presenter.hasPendingPresentation)

        presenter.content = nil
        presenter.updatePresentation()
        presenter.finishPresentation()

        #expect(presenter.hasPendingDismissal)
        presenter.finishDismissal()
        #expect(presenter.editors.count == 1)
        #expect(!presenter.hasPendingPresentation)
    }

    @Test func repeatedUpdatesAfterDismissalCreateExactlyOneReplacement() {
        let (window, presenter) = host()
        defer { window.isHidden = true; window.rootViewController = nil }

        presenter.content = content("initial")
        presenter.updatePresentation()
        presenter.finishPresentation()
        presenter.content = nil
        presenter.updatePresentation()
        #expect(presenter.hasPendingDismissal)

        presenter.content = content("replacement")
        for _ in 0..<3 { presenter.updatePresentation() }
        presenter.finishDismissal()
        #expect(presenter.editors.count == 2)

        for _ in 0..<3 { presenter.updatePresentation() }
        presenter.finishPresentation()
        for _ in 0..<3 { presenter.updatePresentation() }
        #expect(presenter.editors.count == 2)
    }

    private func host() -> (UIWindow, LifecycleDouble) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let presenter = LifecycleDouble()
        window.rootViewController = presenter
        window.makeKeyAndVisible()
        _ = presenter.view
        return (window, presenter)
    }

    private func content(_ marker: String, loggingTo log: RenderLog? = nil) -> AnyView {
        if let log {
            return AnyView(RenderMarker(marker: marker, log: log))
        }
        return AnyView(Text(marker))
    }
}

@MainActor
private final class RenderLog {
    private(set) var markers: [String] = []

    func record(_ marker: String) {
        markers.append(marker)
    }
}

@MainActor
private struct RenderMarker: View {
    let marker: String
    let log: RenderLog

    var body: some View {
        let _ = log.record(marker)
        Text(marker)
    }
}

@MainActor
private final class LifecycleDouble: TouchEditorPresentation.Presenter {
    private(set) var editors: [EditorDouble] = []
    private var presentationCompletions: [() -> Void] = []
    private var dismissalCompletion: (() -> Void)?

    var hasPendingPresentation: Bool { !presentationCompletions.isEmpty }
    var hasPendingDismissal: Bool { dismissalCompletion != nil }

    override func makeEditor() -> TouchEditorPresentation.Editor {
        EditorDouble(owner: self)
    }

    override func present(_ viewControllerToPresent: UIViewController, animated: Bool, completion: (() -> Void)?) {
        guard let editor = viewControllerToPresent as? EditorDouble else {
            Issue.record("Touch editor presenter created an unexpected controller")
            return
        }
        editors.append(editor)
        _ = editor.sizeThatFits(in: CGSize(width: 320, height: 200))
        if let completion { presentationCompletions.append(completion) }
    }

    override func dismiss(animated: Bool, completion: (() -> Void)?) {
        guard dismissalCompletion == nil else {
            Issue.record("Touch editor dismissal started more than once")
            return
        }
        dismissalCompletion = completion
    }

    func finishPresentation() {
        guard !presentationCompletions.isEmpty else {
            Issue.record("No touch editor presentation is pending")
            return
        }
        presentationCompletions.removeFirst()()
    }

    func finishDismissal() {
        guard let completion = dismissalCompletion else {
            Issue.record("No touch editor dismissal is pending")
            return
        }
        dismissalCompletion = nil
        completion()
    }
}

@MainActor
private final class EditorDouble: TouchEditorPresentation.Editor {
    weak var owner: LifecycleDouble?
    private(set) var contentUpdates = 0

    init(owner: LifecycleDouble) {
        self.owner = owner
        super.init(rootView: AnyView(EmptyView()))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var presentingViewController: UIViewController? { owner }

    override func updateContent(_ content: AnyView) {
        contentUpdates += 1
        super.updateContent(content)
    }
}
#endif
