import SwiftUI

/// How a LauncherDropdown's button is drawn: `pill` is the round choice beside a launch option, `button` is
/// LauncherSecondaryButtonStyle's rounded rectangle (the Settings cards).
enum LauncherDropdownStyle { case pill, button }

/// Where the list of an open dropdown goes and how big it is. Pure, so the rules are tested (LauncherDropdownTests).
enum LauncherDropdownLayout {
    static let rowHeight: CGFloat = 34
    static let rowSpacing: CGFloat = 2
    static let padding: CGFloat = 6
    static let gap: CGFloat = 6        // between the button and its list
    static let margin: CGFloat = 8     // kept free at the edges of the window
    static let maxHeight: CGFloat = 320
    static let minWidth: CGFloat = 180
    static let maxWidth: CGFloat = 360

    static func contentHeight(rows: Int) -> CGFloat {
        CGFloat(rows) * rowHeight + CGFloat(max(rows - 1, 0)) * rowSpacing + padding * 2
    }

    /// As wide as the longest label needs (plus room for the checkmark), never narrower than the button.
    static func width(labels: [String], button: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let widest = labels.map { ceil(($0 as NSString).size(withAttributes: [.font: font]).width * 1.1) }.max() ?? 0
        return min(max(widest + 12 * 2 + 16 + 12 + padding * 2, button, minWidth), maxWidth)
    }

    /// The list opens below the button, above it when there is no room below, and takes the bigger side when it fits on
    /// neither (then it scrolls). A button in the right half of the window gets its list aligned to its right edge.
    static func place(button: CGRect, container: CGSize, rows: Int, width: CGFloat) -> (origin: CGPoint, size: CGSize) {
        let wanted = min(contentHeight(rows: rows), maxHeight)
        let below = container.height - margin - (button.maxY + gap)
        let above = button.minY - gap - margin
        let opensBelow = below >= wanted || below >= above
        let height = max(min(wanted, opensBelow ? below : above), rowHeight + padding * 2)
        let y = opensBelow ? button.maxY + gap : button.minY - gap - height
        let preferredX = button.midX > container.width / 2 ? button.maxX - width : button.minX
        let x = min(max(preferredX, margin), max(margin, container.width - width - margin))
        return (CGPoint(x: x, y: max(y, margin)), CGSize(width: width, height: height))
    }

    /// The row an arrow key lands on, wrapping at the ends. Without a highlighted row Down takes the first, Up the last.
    static func step(from current: Int?, by delta: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return delta > 0 ? 0 : count - 1 }
        return (current + delta % count + count) % count
    }
}

/// One dropdown being open: what its list shows and what a pick does.
struct LauncherDropdownRequest {
    let id: UUID
    let options: [(value: String, label: String)]
    let selection: String
    let label: String
    let choose: (String) -> Void
}

/// The open dropdown of one window or sheet, shared by the host (which draws the list) and the buttons (which open it).
final class LauncherDropdownState: ObservableObject {
    @Published var request: LauncherDropdownRequest?
    func close() { withAnimation(.easeOut(duration: 0.12)) { request = nil } }
}

private struct LauncherDropdownHostKey: EnvironmentKey { static let defaultValue: LauncherDropdownState? = nil }

extension EnvironmentValues {
    var launcherDropdownHost: LauncherDropdownState? {
        get { self[LauncherDropdownHostKey.self] }
        set { self[LauncherDropdownHostKey.self] = newValue }
    }
}

/// Each dropdown button reports its frame here, so the list opens against it and follows it when the page scrolls.
struct LauncherDropdownAnchorKey: PreferenceKey {
    static var defaultValue: [UUID: Anchor<CGRect>] = [:]
    static func reduce(value: inout [UUID: Anchor<CGRect>], nextValue: () -> [UUID: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Draws the open LauncherDropdown's list over this view, outside the clipping of the scroll view the button sits in.
    /// Every window and sheet with dropdowns needs one at its root, because a sheet is a window of its own.
    /// A dropdown without a host opens its list as a popover.
    func launcherDropdownHost() -> some View { modifier(LauncherDropdownHost()) }
}

extension View {
    /// The list's own surface: the app's dark card with its border, radius and shadow.
    func launcherDropdownSurface() -> some View {
        background(LauncherPalette.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.10)))
            .shadow(color: .black.opacity(0.5), radius: 18, y: 6)
    }
}

private struct LauncherDropdownHost: ViewModifier {
    @StateObject private var state = LauncherDropdownState()
    func body(content: Content) -> some View {
        content
            .environment(\.launcherDropdownHost, state)
            .overlayPreferenceValue(LauncherDropdownAnchorKey.self) { anchors in
                LauncherDropdownLayer(state: state, anchors: anchors)
            }
    }
}

private struct LauncherDropdownLayer: View {
    @ObservedObject var state: LauncherDropdownState
    let anchors: [UUID: Anchor<CGRect>]
    var body: some View {
        GeometryReader { g in
            if let request = state.request, let anchor = anchors[request.id] {
                let button = g[anchor]
                let width = LauncherDropdownLayout.width(labels: request.options.map(\.label), button: button.width)
                let spot = LauncherDropdownLayout.place(button: button, container: g.size, rows: request.options.count, width: width)
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.001).contentShape(Rectangle())
                        .onTapGesture { state.close() }
                        .accessibilityHidden(true)
                    LauncherDropdownList(options: request.options, selection: request.selection, label: request.label,
                                         choose: { value in request.choose(value); state.close() }, close: { state.close() })
                        .frame(width: spot.size.width, height: spot.size.height)
                        .launcherDropdownSurface()
                        .offset(x: spot.origin.x, y: spot.origin.y)
                        .transition(.opacity)
                }
            }
        }
    }
}

/// The rows of an open dropdown: the chosen one with a checkmark, the one under the pointer or the arrow keys lit.
/// Arrow keys move, Return or Space pick, Esc closes (a local key monitor while it is open, as in the Manage menu).
struct LauncherDropdownList: View {
    let options: [(value: String, label: String)]
    let selection: String
    let label: String
    let choose: (String) -> Void
    let close: () -> Void
    @State private var highlighted: Int?
    @State private var monitor: Any?
    @AccessibilityFocusState private var spoken: Int?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: LauncherDropdownLayout.rowSpacing) {
                    ForEach(Array(options.enumerated()), id: \.offset) { index, option in row(option, index: index).id(index) }
                }
                .padding(LauncherDropdownLayout.padding)
            }
            .onChange(of: highlighted) { index in if let index { proxy.scrollTo(index) } }
            .onAppear {
                let at = options.firstIndex { $0.value == selection }
                highlighted = at
                if let at { proxy.scrollTo(at, anchor: .center) }
                spoken = at ?? 0
                startKeys()
            }
        }
        .onDisappear(perform: stopKeys)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, close)
    }

    private func row(_ option: (value: String, label: String), index: Int) -> some View {
        let selected = option.value == selection
        return Button { choose(option.value) } label: {
            HStack(spacing: 10) {
                Text(option.label).font(.manrope(13, selected ? .bold : .medium)).lineLimit(1)
                Spacer(minLength: 16)
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(LauncherPalette.cream)
                    .opacity(selected ? 1 : 0)
            }
            .foregroundStyle(Color.white.opacity(0.92))
            .padding(.horizontal, 12).frame(height: LauncherDropdownLayout.rowHeight)
            .background(highlighted == index ? Color.white.opacity(0.09) : (selected ? Color.white.opacity(0.045) : .clear),
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { highlighted = index } else if highlighted == index { highlighted = nil }
        }
        .accessibilityLabel(option.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityFocused($spoken, equals: index)
    }

    private func startKeys() {
        stopKeys()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 125: highlighted = LauncherDropdownLayout.step(from: highlighted, by: 1, count: options.count)
            case 126: highlighted = LauncherDropdownLayout.step(from: highlighted, by: -1, count: options.count)
            case 36, 76, 49: if let i = highlighted, options.indices.contains(i) { choose(options[i].value) }
            case 53: close()
            case 48: close(); return event
            default: return event
            }
            return nil
        }
    }

    private func stopKeys() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// The launcher's dropdown: a button with the current choice that opens a list drawn in the app's own style
/// (its dark surface, Manrope, a checkmark on the chosen row). It never cuts the label short unless it is given
/// `fill` (the width of its container). Inside a setting row it is exactly LauncherControl.width wide and LauncherControl.height high, its choice at
/// the left and the chevron at the right, the choice a little smaller when it does not fit.
/// `label` names the setting for VoiceOver, which then reads the choice as the value.
struct LauncherDropdown: View {
    let options: [(value: String, label: String)]
    let selection: String
    var label = ""
    var style: LauncherDropdownStyle = .pill
    var fill = false
    let choose: (String) -> Void
    @Environment(\.launcherDropdownHost) private var host
    @State private var id = UUID()

    var body: some View {
        if let host {
            Hosted(host: host, dropdown: self)
        } else {
            Popped(dropdown: self)
        }
    }

    fileprivate var current: String { options.first { $0.value == selection }?.label ?? selection }

    fileprivate func face(open: Bool, rowWidth: CGFloat?) -> some View {
        let rounded = style == .button
        let shape = RoundedRectangle(cornerRadius: rounded ? 9 : 99)
        let width = fill ? nil : rowWidth
        return HStack(spacing: 0) {
            Text(current).font(.manrope(rounded ? 13 : 12.5, .semibold)).lineLimit(1)
                .minimumScaleFactor(width == nil ? 1 : 0.85)
                .fixedSize(horizontal: !fill && width == nil, vertical: false)
                .frame(maxWidth: fill || width != nil ? .infinity : nil, alignment: .center)
                .padding(.leading, fill || width != nil ? 14 : 0)   // room so the chevron never crowds the words
            if fill || width != nil {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(open ? 180 : 0)).padding(.trailing, 14)
            } else {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(open ? 180 : 0)).padding(.leading, 8)
            }
        }
.padding(.horizontal, rounded ? 15 : 14).padding(.vertical, rounded ? 9 : 7)
        .frame(width: width, height: width == nil ? nil : LauncherControl.height)
        .frame(maxWidth: fill ? .infinity : nil)
        .background(Color.white.opacity(open ? 0.13 : (rounded ? 0.055 : 0.06)), in: shape)
        .overlay(shape.strokeBorder(Color.white.opacity(open ? 0.18 : 0.10)))
        .foregroundStyle(Color.white.opacity(0.92))
        .contentShape(shape)
        .launcherMeasured(label: Text(current).font(.manrope(rounded ? 13 : 12.5, .semibold)), room: LauncherControl.choiceWidth)
    }

    fileprivate func accessible<V: View>(_ view: V) -> some View {
        view.accessibilityLabel(label.isEmpty ? current : label).accessibilityValue(label.isEmpty ? "" : current)
    }

    private struct Hosted: View {
        @ObservedObject var host: LauncherDropdownState
        let dropdown: LauncherDropdown
        @Environment(\.isEnabled) private var enabled
        @Environment(\.launcherControlWidth) private var rowWidth
        var body: some View {
            let open = host.request?.id == dropdown.id
            dropdown.accessible(
                Button {
                    withAnimation(.easeOut(duration: 0.12)) {
                        host.request = open ? nil : LauncherDropdownRequest(id: dropdown.id, options: dropdown.options, selection: dropdown.selection,
                                                                            label: dropdown.label, choose: dropdown.choose)
                    }
                } label: { dropdown.face(open: open, rowWidth: rowWidth) }
                .buttonStyle(.plain)
                .opacity(enabled ? 1 : 0.55)
                .anchorPreference(key: LauncherDropdownAnchorKey.self, value: .bounds) { [dropdown.id: $0] }
            )
        }
    }

    /// Without a host the same list opens in a popover.
    private struct Popped: View {
        let dropdown: LauncherDropdown
        @State private var open = false
        @Environment(\.isEnabled) private var enabled
        @Environment(\.launcherControlWidth) private var rowWidth
        var body: some View {
            dropdown.accessible(
                Button { open.toggle() } label: { dropdown.face(open: open, rowWidth: rowWidth) }
                    .buttonStyle(.plain)
                    .opacity(enabled ? 1 : 0.55)
                    .popover(isPresented: $open, arrowEdge: .bottom) {
                        LauncherDropdownList(options: dropdown.options, selection: dropdown.selection, label: dropdown.label,
                                             choose: { dropdown.choose($0); open = false }, close: { open = false })
                            .frame(width: LauncherDropdownLayout.width(labels: dropdown.options.map(\.label), button: 0),
                                   height: min(LauncherDropdownLayout.contentHeight(rows: dropdown.options.count), LauncherDropdownLayout.maxHeight))
                            .preferredColorScheme(.dark)
                    }
            )
        }
    }
}
