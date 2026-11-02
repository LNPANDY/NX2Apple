import SwiftUI
import UniformTypeIdentifiers
import NXCore
import NXLauncher

// Game files dropped on the Builds page (issue #68): NSP, NSZ and XCI files, a folder, prod.keys, in any
// mix. They are sorted into the slots by the same classification as Choose game folder
// (GameInputs.classify), so a drop and a picked folder never disagree about what is the update.

/// The Builds page as a drop target: a highlight while files are dragged over it, the files to the model when dropped.
struct GameFilesDrop: ViewModifier {
    let enabled: Bool
    let label: String
    let onDrop: ([String]) -> Void
    @State private var targeted: Bool

    /// `targeted` starts the highlight on (visual QA renders it without a drag).
    init(enabled: Bool, label: String, targeted: Bool = false, onDrop: @escaping ([String]) -> Void) {
        self.enabled = enabled; self.label = label; self.onDrop = onDrop
        _targeted = State(initialValue: targeted)
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                if targeted && enabled {
                    // the page dimmed under the label, so the label reads wherever it lands
                    ZStack {
                        RoundedRectangle(cornerRadius: 18)
                            .fill(LauncherPalette.background.opacity(0.72))
                            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(LauncherPalette.cream.opacity(0.8),
                                                                                    style: StrokeStyle(lineWidth: 2, dash: [8, 6])))
                        Label(label, systemImage: "square.and.arrow.down")
                            .font(.manrope(15, .semibold)).foregroundStyle(.black)
                            .padding(.horizontal, 20).padding(.vertical, 12)
                            .background(LauncherPalette.cream, in: Capsule())
                    }
                    .padding(12)
                    .allowsHitTesting(false)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                guard enabled else { return false }
                Self.paths(from: providers) { onDrop($0) }
                return true
            }
    }

    /// The file URLs of a drop, delivered on the main queue once all have loaded.
    static func paths(from providers: [NSItemProvider], then done: @escaping ([String]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var paths: [String] = []
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = p.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                if let data, let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL {
                    lock.lock(); paths.append(url.path); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { if !paths.isEmpty { done(paths) } }
    }
}
