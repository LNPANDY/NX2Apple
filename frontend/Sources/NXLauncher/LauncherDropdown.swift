import SwiftUI

/// How a LauncherDropdown's button is drawn: `pill` is the round choice beside a launch option, `button` is
/// LauncherSecondaryButtonStyle's rounded rectangle (the Settings cards).
package enum LauncherDropdownStyle { case pill, button }

/// Where the list of an open dropdown goes and how big it is. Pure, so the rules are tested (LauncherDropdownTests).
package enum LauncherDropdownLayout {
    package static let rowHeight: CGFloat = 34
    package static let rowSpacing: CGFloat = 2
    package static let padding: CGFloat = 6
    package static let gap: CGFloat = 6        // between the button and its list
    package static let margin: CGFloat = 8     // kept free at the edges of the window
    package static let maxHeight: CGFloat = 320
    package static let minWidth: CGFloat = 180
    package static let maxWidth: CGFloat = 360

    package static func contentHeight(rows: Int) -> CGFloat {
        CGFloat(rows) * rowHeight + CGFloat(max(rows - 1, 0)) * rowSpacing + padding * 2
    }

    /// As wide as the longest label needs (plus room for the checkmark), never narrower than the button.
    package static func width(labels: [String], button: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let widest = labels.map { ceil(($0 as NSString).size(withAttributes: [.font: font]).width * 1.1) }.max() ?? 0
        return min(max(widest + 12 * 2 + 16 + 12 + padding * 2, button, minWidth), maxWidth)
    }

    /// The list opens below the button, above it when there is no room below, and takes the bigger side when it fits on
    /// neither (then it scrolls). A button in the right half of the window gets its list aligned to its right edge.
    package static func place(button: CGRect, container: CGSize, rows: Int, width: CGFloat) -> (origin: CGPoint, size: CGSize) {
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

    /// Places a custom panel of fixed `width` and bounded `maxHeight` below (or above when tight) the trigger button.
    package static func placeCustom(
        button: CGRect,
        container: CGSize,
        maxHeight: CGFloat,
        width: CGFloat
    ) -> (x: CGFloat, topY: CGFloat, bottomY: CGFloat, maxHeight: CGFloat, opensBelow: Bool) {
        let clampedWidth = min(width, max(minWidth, container.width - margin * 2))
        let below = container.height - margin - (button.maxY + gap)
        let above = button.minY - gap - margin
        let opensBelow = below >= maxHeight || below >= above
        let available = max(min(maxHeight, opensBelow ? below : above), rowHeight + padding * 2)
        let preferredX = button.midX > container.width / 2 ? button.maxX - clampedWidth : button.minX
        let x = min(max(preferredX, margin), max(margin, container.width - clampedWidth - margin))
        return (x: x, topY: max(button.maxY + gap, margin), bottomY: max(button.minY - gap, margin), maxHeight: available, opensBelow: opensBelow)
    }

    /// The row an arrow key lands on, wrapping at the ends. Without a highlighted row Down takes the first, Up the last.
    package static func step(from current: Int?, by delta: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return delta > 0 ? 0 : count - 1 }
        return (current + delta % count + count) % count
    }
}

/// One dropdown being open: what its list shows and what a pick does.
package struct LauncherDropdownRequest {
    package init(id: UUID, options: [(value: String, label: String)], selection: String, label: String, destructiveValues: Set<String> = [], choose: @escaping (String) -> Void) {
        self.id = id; self.options = options; self.selection = selection; self.label = label; self.choose = choose
        self.destructiveValues = destructiveValues
    }
    package let destructiveValues: Set<String>
    package let id: UUID
    package let options: [(value: String, label: String)]
    package let selection: String
    package let label: String
    package let choose: (String) -> Void
}

/// A custom interactive dropdown panel (such as the Build engine switcher) hosted above scroll clipping.
package struct LauncherCustomDropdown {
    package let id: UUID
    package let width: CGFloat
    package let maxHeight: CGFloat
    package let label: String
    package let content: (@escaping () -> Void) -> AnyView

    package init(
        id: UUID,
        width: CGFloat = 368,
        maxHeight: CGFloat = 260,
        label: String = "",
        content: @escaping (@escaping () -> Void) -> AnyView
    ) {
        self.id = id
        self.width = width
        self.maxHeight = maxHeight
        self.label = label
        self.content = content
    }
}

/// The open dropdown of one window or sheet, shared by the host (which draws the list) and the buttons (which open it).
package final class LauncherDropdownState: ObservableObject {
    package init() {}
    @Published package var request: LauncherDropdownRequest? {
        didSet { if request != nil, custom != nil { custom = nil } }
    }
    @Published package var custom: LauncherCustomDropdown? {
        didSet { if custom != nil, request != nil { request = nil } }
    }
    package func close() {
        withAnimation(.easeOut(duration: 0.12)) {
            request = nil
            custom = nil
        }
    }
}

private struct LauncherDropdownHostKey: EnvironmentKey { static let defaultValue: LauncherDropdownState? = nil }

extension EnvironmentValues {
    package var launcherDropdownHost: LauncherDropdownState? {
        get { self[LauncherDropdownHostKey.self] }
        set { self[LauncherDropdownHostKey.self] = newValue }
    }
}

/// Each dropdown button reports its frame here, so the list opens against it and follows it when the page scrolls.
package struct LauncherDropdownAnchorKey: PreferenceKey {
    package static var defaultValue: [UUID: Anchor<CGRect>] = [:]
    package static func reduce(value: inout [UUID: Anchor<CGRect>], nextValue: () -> [UUID: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Draws the open LauncherDropdown's list over this view, outside the clipping of the scroll view the button sits in.
    /// Every window and sheet with dropdowns needs one at its root, because a sheet is a window of its own.
    /// A dropdown without a host opens its list as a popover.
    package func launcherDropdownHost(_ state: LauncherDropdownState? = nil, pad: PadFocus? = nil) -> some View {
        modifier(LauncherDropdownHost(state: state, pad: pad))
    }
}

extension View {
    /// The list's own surface: the app's card with its border, radius and shadow.
    package func launcherDropdownSurface() -> some View {
        background(LauncherPalette.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(LauncherPalette.ink(0.10)))
            .shadow(color: LauncherPalette.dropdownShadow, radius: 18, y: 6)
    }
}

private struct LauncherDropdownHost: ViewModifier {
    @StateObject private var state: LauncherDropdownState
    let pad: PadFocus?
    init(state: LauncherDropdownState?, pad: PadFocus?) {
        _state = StateObject(wrappedValue: state ?? LauncherDropdownState())
        self.pad = pad
    }
    func body(content: Content) -> some View {
        content
            .environment(\.launcherDropdownHost, state)
            .overlayPreferenceValue(LauncherDropdownAnchorKey.self) { anchors in
                LauncherDropdownLayer(state: state, anchors: anchors, pad: pad)
            }
    }
}

private struct LauncherDropdownMaxHeightKey: EnvironmentKey { static let defaultValue: CGFloat? = nil }
extension EnvironmentValues {
    package var launcherDropdownMaxHeight: CGFloat? {
        get { self[LauncherDropdownMaxHeightKey.self] }
        set { self[LauncherDropdownMaxHeightKey.self] = newValue }
    }
}

private struct LauncherDropdownCapLayout: Layout {
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let first = subviews.first else { return .zero }
        let cap = max(0, min(maxHeight, proposal.height ?? maxHeight))
        let size = first.sizeThatFits(ProposedViewSize(width: proposal.width, height: cap))
        return CGSize(width: size.width, height: min(size.height, cap))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let first = subviews.first else { return }
        first.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

private struct LauncherCustomDropdownBox: View {
    let custom: LauncherCustomDropdown
    let maxHeight: CGFloat
    let close: () -> Void
    @State private var monitor: Any?

    var body: some View {
        LauncherDropdownCapLayout(maxHeight: maxHeight) {
            custom.content(close)
                .environment(\.launcherControlWidth, nil)
                .environment(\.launcherDropdownMaxHeight, maxHeight)
                .frame(width: custom.width)
        }
        .launcherDropdownSurface()
            .accessibilityElement(children: .contain)
            .accessibilityLabel(custom.label)
            .accessibilityAddTraits(.isModal)
            .accessibilityAction(.escape, close)
            .onAppear {
                stopKeys()
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    if event.keyCode == 53 {
                        close()
                        return nil
                    }
                    return event
                }
            }
            .onDisappear {
                stopKeys()
            }
    }

    private func stopKeys() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

private struct LauncherDropdownLayer: View {
    @ObservedObject var state: LauncherDropdownState
    let anchors: [UUID: Anchor<CGRect>]
    let pad: PadFocus?
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
                    LauncherDropdownList(options: request.options, selection: request.selection, label: request.label, destructiveValues: request.destructiveValues,
                                         choose: { value in request.choose(value); state.close() }, close: { state.close() }, pad: pad)
                        .frame(width: spot.size.width, height: spot.size.height)
                        .launcherDropdownSurface()
                        .offset(x: spot.origin.x, y: spot.origin.y)
                        .transition(.opacity)
                }
            } else if let custom = state.custom, let anchor = anchors[custom.id] {
                let button = g[anchor]
                let width = min(custom.width, max(LauncherDropdownLayout.minWidth, g.size.width - LauncherDropdownLayout.margin * 2))
                let spot = LauncherDropdownLayout.placeCustom(button: button, container: g.size, maxHeight: custom.maxHeight, width: width)
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.001).contentShape(Rectangle())
                        .onTapGesture { state.close() }
                        .accessibilityHidden(true)
                    if spot.opensBelow {
                        LauncherCustomDropdownBox(custom: custom, maxHeight: spot.maxHeight, close: { state.close() })
                            .offset(x: spot.x, y: spot.topY)
                            .transition(.opacity)
                    } else {
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            LauncherCustomDropdownBox(custom: custom, maxHeight: spot.maxHeight, close: { state.close() })
                        }
                        .frame(width: width, height: max(spot.bottomY - LauncherDropdownLayout.margin, 0), alignment: .bottomLeading)
                        .offset(x: spot.x, y: LauncherDropdownLayout.margin)
                        .transition(.opacity)
                    }
                }
            }
        }
    }
}

/// The rows of an open dropdown: the chosen one with a checkmark, the one under the pointer or the arrow keys lit.
/// Arrow keys move, Return or Space pick, Esc closes (a local key monitor while it is open, as in the Manage menu).
package struct LauncherDropdownList: View {
    package init(options: [(value: String, label: String)], selection: String, label: String, destructiveValues: Set<String> = [], choose: @escaping (String) -> Void, close: @escaping () -> Void, pad: PadFocus? = nil) {
        self.options = options; self.selection = selection; self.label = label; self.choose = choose; self.close = close
        self.pad = pad
        self.destructiveValues = destructiveValues
    }
    package let destructiveValues: Set<String>
    package let options: [(value: String, label: String)]
    package let selection: String
    package let label: String
    package let choose: (String) -> Void
    package let close: () -> Void
    let pad: PadFocus?
    @State private var highlighted: Int?
    @State private var monitor: Any?
    @AccessibilityFocusState private var spoken: Int?

    @ViewBuilder package var body: some View {
        if let pad {
            list.padScope("dropdown", pad).environmentObject(pad)
                .onAppear { pad.focused = "dropdown.\(options.firstIndex { $0.value == selection } ?? 0)" }
                .onChange(of: pad.focused) { id in
                    if let id, id.hasPrefix("dropdown."), let index = Int(id.dropFirst(9)) { highlighted = index }
                }
        } else { list }
    }

    private var list: some View {
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

    @ViewBuilder private func row(_ option: (value: String, label: String), index: Int) -> some View {
        let selected = option.value == selection
        let button = Button(role: destructiveValues.contains(option.value) ? .destructive : nil) { choose(option.value) } label: {
            HStack(spacing: 10) {
                Text(option.label).font(.manrope(13, selected ? .bold : .medium)).lineLimit(1)
                Spacer(minLength: 16)
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(LauncherPalette.accent)
                    .opacity(selected ? 1 : 0)
            }
            .foregroundStyle(destructiveValues.contains(option.value) ? LauncherPalette.danger : LauncherPalette.text)
            .padding(.horizontal, 12).frame(height: LauncherDropdownLayout.rowHeight)
            .background(highlighted == index ? LauncherPalette.ink(0.09) : (selected ? LauncherPalette.ink(0.045) : .clear),
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
        if pad != nil {
            button.padTarget("dropdown.\(index)", scope: "dropdown", radius: 8) { choose(option.value) }
        } else { button }
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
package struct LauncherDropdown: View {
    package init(options: [(value: String, label: String)], selection: String, label: String = "", style: LauncherDropdownStyle = .button,
                  fill: Bool = false, leading: Bool = false, choose: @escaping (String) -> Void) {
        self.options = options; self.selection = selection; self.label = label; self.style = style; self.fill = fill; self.leading = leading
        self.choose = choose
    }
    package let options: [(value: String, label: String)]
    package let selection: String
    package var label = ""
    package var style: LauncherDropdownStyle = .button
    package var fill = false
    /// With `fill`: the choice starts at the left, like the text of a field (the export's device, LNPANDY/NX2Apple#416).
    package var leading = false
    package let choose: (String) -> Void
    @Environment(\.launcherDropdownHost) private var host
    @State private var id = UUID()

    package var body: some View {
        if let host {
            Hosted(host: host, dropdown: self)
        } else {
            Popped(dropdown: self)
        }
    }

    fileprivate var current: String { options.first { $0.value == selection }?.label ?? selection }

    fileprivate func face(open: Bool, rowWidth: CGFloat?) -> some View {
        let rounded = style == .button
        let shape = Capsule()
        let width = fill ? nil : rowWidth
        return HStack(spacing: 0) {
            Text(current).font(.manrope(rounded ? 13 : 12.5, .semibold)).lineLimit(1)
                .minimumScaleFactor(width == nil ? 1 : 0.85)
                .fixedSize(horizontal: !fill && width == nil, vertical: false)
                .frame(maxWidth: fill || width != nil ? .infinity : nil, alignment: fill && leading ? .leading : .center)   // the words centre across the whole button
                .padding(.leading, (fill && !leading) || width != nil ? 14 : 0)   // room so the chevron never crowds them
            if fill || width != nil {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(LauncherPalette.secondaryText)
                    .rotationEffect(.degrees(open ? 180 : 0)).padding(.trailing, 14)
            } else {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(LauncherPalette.secondaryText)
                    .rotationEffect(.degrees(open ? 180 : 0)).padding(.leading, 8)
            }
        }
        .padding(.horizontal, rounded ? 15 : 14).padding(.vertical, rounded ? 9 : 7)
        .frame(width: width, height: LauncherControl.height)
        .frame(maxWidth: fill ? .infinity : nil)
        .background(open ? LauncherPalette.secondaryPressed : (rounded ? LauncherPalette.secondaryFill : LauncherPalette.dropdownFill), in: shape)
        .overlay(shape.strokeBorder(open ? LauncherPalette.dropdownOpenBorder : LauncherPalette.secondaryBorder))
        .foregroundStyle(LauncherPalette.text)
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
                            .launcherAppearance()
                    }
            )
        }
    }
}
