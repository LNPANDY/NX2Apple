#if os(iOS)
import SwiftUI
import UIKit

// A full-screen controller owns the editor's rotation policy, independently of browsing.
struct TouchEditorPresentation: UIViewControllerRepresentable {
    var content: AnyView?
    @Environment(\.scenePhase) private var scenePhase

    func makeUIViewController(context: Context) -> Presenter { Presenter() }
    func updateUIViewController(_ controller: Presenter, context: Context) {
        // A separately presented hosting controller does not inherit its presenting SwiftUI scene.
        controller.content = content.map { AnyView($0.environment(\.scenePhase, scenePhase)) }
        controller.updatePresentation()
    }

    class Presenter: UIViewController {
        var content: AnyView?
        private var editor: Editor?
        private var transitioning = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.isUserInteractionEnabled = false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            updatePresentation()
        }

        func makeEditor() -> Editor { Editor(rootView: AnyView(EmptyView())) }

        func updatePresentation() {
            guard !transitioning, editor != nil || viewIfLoaded?.window != nil else { return }
            if let content {
                if let editor {
                    editor.updateContent(content)
                    return
                }
                let editor = makeEditor()
                editor.updateContent(content)
                editor.onDismiss = { [weak self, weak editor] in
                    guard let self, let editor, self.editor === editor else { return }
                    self.editor = nil
                    self.transitioning = false
                    self.setNeedsUpdateOfSupportedInterfaceOrientations()
                    self.updatePresentation()
                }
                editor.modalPresentationStyle = .fullScreen
                editor.isModalInPresentation = true
                if #available(iOS 27.1, *) {
                    editor.hasInnerDisplay = !(view.window?.reservedRegions(kind: .division, options: .includeInactive).isEmpty ?? true)
                }
                self.editor = editor
                transitioning = true
                present(editor, animated: true) { [weak self] in
                    self?.transitioning = false
                    self?.updatePresentation()
                }
            } else if let editor {
                editor.closeEditor()
            }
        }
    }

    class Editor: UIHostingController<AnyView> {
        var onDismiss: (() -> Void)?
        private var closing = false

        func updateContent(_ content: AnyView) {
            guard !closing else { return }
            rootView = AnyView(content.environment(\.shellDismissTouchEditor, { [weak self] in self?.closeEditor() }))
        }

        func closeEditor() {
            guard !closing, let owner = presentingViewController else { return }
            closing = true
            // UIKit may forward presentation beyond the representable, especially after sheet adaptation.
            owner.dismiss(animated: true) { [weak self] in self?.onDismiss?() }
        }

        var hasInnerDisplay = false
        private var hingeInteraction: UIInteraction?

        override func viewDidLoad() {
            super.viewDidLoad()
            if #available(iOS 27.1, *) {
                let interaction = UIHingeInteraction { [weak self] _, update in
                    guard let self else { return }
                    let inner = update.hinge.map { $0.status != .closed && $0.status != .unknown } ?? false
                    guard inner != self.hasInnerDisplay else { return }
                    self.hasInnerDisplay = inner
                    self.setNeedsUpdateOfSupportedInterfaceOrientations()
                    if !inner, self.traitCollection.userInterfaceIdiom == .phone {
                        self.view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape))
                    }
                }
                view.addInteraction(interaction)
                hingeInteraction = interaction
            }
        }

        override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
            traitCollection.userInterfaceIdiom == .phone && !hasInnerDisplay ? .landscape : .all
        }
        override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
            guard traitCollection.userInterfaceIdiom == .phone, !hasInnerDisplay else {
                return presentingViewController?.view.window?.windowScene?.effectiveGeometry.interfaceOrientation ?? .portrait
            }
            let current = presentingViewController?.view.window?.windowScene?.effectiveGeometry.interfaceOrientation
            return current == .landscapeLeft ? .landscapeLeft : .landscapeRight
        }
    }
}
#endif
