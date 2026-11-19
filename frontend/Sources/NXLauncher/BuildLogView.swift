import SwiftUI
import NXModel

/// The build log as a scrolling text. It is the only view that observes `BuildLog`, so a log line redraws this and not the
/// launcher around it (LNPANDY/NX2Apple#387).
package struct BuildLogView: View {
    @ObservedObject var log: BuildLog
    let placeholder: String
    let height: CGFloat
    @StateObject private var scroll = LauncherScrollPosition()
    @EnvironmentObject private var focus: PadFocus

    package init(log: BuildLog, placeholder: String, height: CGFloat = 220) {
        self.log = log
        self.placeholder = placeholder
        self.height = height
    }

    package var body: some View {
        ScrollViewReader { sp in
            ScrollView {
                Text(log.text.isEmpty ? placeholder : log.text)
                    .font(.mono(11))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(LauncherPalette.secondaryText)
                    .padding(12)
                    .id("end")
                    .background(LauncherScrollProbe(scroll: scroll))
            }
            .frame(height: height)
            .background(LauncherPalette.well, in: RoundedRectangle(cornerRadius: 10))
            .focusable()
            .onMoveCommand { direction in
                guard focus.scope == "main" else { return }
                if direction == .up { _ = scroll.move(-1) }
                if direction == .down { _ = scroll.move(1) }
            }
            .padTarget("set.build.logContent", scope: "main", radius: 10, vertical: scroll.move)
            .onChange(of: log.text) { _ in sp.scrollTo("end", anchor: .bottom) }
            .onAppear { sp.scrollTo("end", anchor: .bottom) }
        }
    }
}

final class LauncherScrollPosition: ObservableObject {
    weak var view: NSScrollView?
    func move(_ direction: Int) -> Bool {
        guard let view, let document = view.documentView else { return false }
        let clip = view.contentView
        let y = min(max(0, clip.bounds.minY + CGFloat(direction) * 100), max(0, document.frame.height - clip.bounds.height))
        guard abs(y - clip.bounds.minY) > 0.5 else { return false }
        clip.setBoundsOrigin(CGPoint(x: clip.bounds.minX, y: y))
        view.reflectScrolledClipView(clip)
        return true
    }
}

struct LauncherScrollProbe: NSViewRepresentable {
    let scroll: LauncherScrollPosition
    final class Probe: NSView {
        weak var scroll: LauncherScrollPosition?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                if let view = self?.enclosingScrollView { self?.scroll?.view = view }
            }
        }
    }
    func makeNSView(context: Context) -> Probe { let view = Probe(); view.scroll = scroll; return view }
    func updateNSView(_ view: Probe, context: Context) {
        view.scroll = scroll
        DispatchQueue.main.async { [weak view] in if let enclosing = view?.enclosingScrollView { scroll.view = enclosing } }
    }
}
