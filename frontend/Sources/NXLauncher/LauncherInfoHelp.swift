import SwiftUI
import NXModel

/// Matches the prototype's short-delay native help, with an explicit activation path for keyboard and controllers.
package struct LauncherInfoHelp: View {
    let id: String
    let label: String
    let text: String
    @EnvironmentObject private var loc: Localizer
    @EnvironmentObject private var pad: PadFocus
    @State private var hovering = false
    @State private var presented = false
    @State private var pinned = false
    @State private var previousScope = "main"
    private var scope: String { id + ".popover" }

    package var body: some View {
        Button(action: activate) {
            Image(systemName: "info.circle").font(.system(size: 13))
                .foregroundStyle(.secondary).frame(width: 24, height: 24).contentShape(Circle())
        }.buttonStyle(.plain).accessibilityLabel(label).accessibilityHint(text)
            .background(LauncherInfoHoverTracking { hovering = $0 })
            .padTarget(id, scope: "main", activate: activate)
            .popover(isPresented: $presented, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(text).font(.callout).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                    if pinned {
                        HStack {
                            Spacer()
                            Button(loc.t("console.key.done"), action: close)
                                .buttonStyle(LauncherSecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                                .padTarget(scope + ".cancel", scope: scope, activate: close)
                        }
                    }
                }.padding(12).frame(width: 280, alignment: .leading)
                    .environmentObject(pad).padScope(scope, pad)
                    .accessibilityAction(.escape, close)
            }
            .task(id: hovering) {
                guard hovering else { if !pinned { presented = false }; return }
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled else { return }
                presented = true
            }
            .onChange(of: presented) { open in if !open { restoreFocus() } }
            .onDisappear { restoreFocus() }
    }

    private func activate() {
        if pinned { close(); return }
        previousScope = pad.scope
        pinned = true; presented = true
        pad.scope = scope
        if pad.visible { pad.focused = scope + ".cancel" }
    }
    private func close() { presented = false; restoreFocus() }
    private func restoreFocus() {
        pinned = false
        if pad.scope == scope {
            pad.scope = previousScope
            if pad.visible { pad.focused = id }
        }
    }
}

/// Keep hover tracking active when the native hint becomes a child panel, without taking the button's clicks.
private struct LauncherInfoHoverTracking: NSViewRepresentable {
    let changed: (Bool) -> Void
    final class Probe: NSView {
        var changed: (Bool) -> Void = { _ in }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }
        override func mouseEntered(with event: NSEvent) { changed(true) }
        override func mouseExited(with event: NSEvent) { changed(false) }
    }
    func makeNSView(context: Context) -> NSView { let view = Probe(); view.changed = changed; return view }
    func updateNSView(_ view: NSView, context: Context) { (view as? Probe)?.changed = changed }
}
