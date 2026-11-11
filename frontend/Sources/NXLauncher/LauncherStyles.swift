import SwiftUI
import CoreText

package struct LauncherWindowChrome: NSViewRepresentable {
    package init() {}
    package final class ChromeView: NSView {
        private func applyBackground() {
            let light = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .aqua
            window?.backgroundColor = LauncherPalette.backgroundNSColor(light: light)
        }
        package override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            applyBackground()
        }
        package override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            applyBackground()
            window.isMovableByWindowBackground = true
        }
    }
    package func makeNSView(context: Context) -> NSView { ChromeView() }
    package func updateNSView(_ nsView: NSView, context: Context) {}
}

/// The line under the top bar: the divider Dark always had, a black hairline at 0.08 in Light.
package struct LauncherTopBarRule: View {
    @Environment(\.colorScheme) private var scheme
    package init() {}
    package var body: some View {
        if scheme == .light { LauncherPalette.topBarRule.frame(height: 1) } else { Divider().opacity(0.3) }
    }
}

/// What a double-click on the title bar does, as System Settings → Desktop & Dock sets it.
package enum TitlebarAction: Equatable {
    case zoom, minimize, none

    /// `AppleActionOnDoubleClick` ("Maximize", "Fill", "Minimize", "None") wins; the older `AppleMiniaturizeOnDoubleClick` bool is read only
    /// without it; with neither, macOS's default (zoom).
    package static func resolve(actionSetting: String?, miniaturizeFlag: Bool?) -> TitlebarAction {
        if let value = actionSetting?.trimmingCharacters(in: .whitespaces).lowercased(), !value.isEmpty {
            switch value {
            case "minimize": return .minimize
            case "none", "do nothing", "nothing": return .none
            default: return .zoom   // Maximize, Fill, or a value a later macOS adds
            }
        }
        return miniaturizeFlag == true ? .minimize : .zoom
    }

    package static var current: TitlebarAction {
        let d = UserDefaults.standard   // the global domain is searched too
        return resolve(actionSetting: d.string(forKey: "AppleActionOnDoubleClick"),
                       miniaturizeFlag: d.object(forKey: "AppleMiniaturizeOnDoubleClick") as? Bool)
    }

    package func perform(on window: NSWindow?) {
        switch self {
        case .zoom: window?.zoom(nil)   // fills the screen, traffic lights kept; a second one restores
        case .minimize: window?.miniaturize(nil)
        case .none: break
        }
    }
}

/// Sits behind the top bar. Controls above it keep their clicks; on an empty part a double-click does the title bar's action
/// and a single press drags the window (the view takes the mouse-down, so it starts the drag itself).
package struct TitlebarDoubleClick: NSViewRepresentable {
    package init() {}
    package final class DragView: NSView {
        package override var mouseDownCanMoveWindow: Bool { false }
        package override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { TitlebarAction.current.perform(on: window) }
            else { window?.performDrag(with: event) }
        }
    }
    package func makeNSView(context: Context) -> NSView { DragView() }
    package func updateNSView(_ nsView: NSView, context: Context) {}
}

/// The width of the button or dropdown at the trailing end of a setting row, the same on every page, so that these
/// controls stand in one column whatever their labels. A row hands it to its trailing controls (`launcherRowControls()`),
/// and LauncherSecondaryButtonStyle and LauncherDropdown take it from there. Outside a row they size to their label.
package enum LauncherControl {
    /// Wide enough for the longest everyday label in every language on one line ("Sök efter uppdateringar", 148 pt in 13 pt
    /// Manrope semibold, plus the buttons' 15 pt of padding on each side). LauncherControlWidthTests measures them all.
    package static let width: CGFloat = 184
    /// What the label of a button may take.
    package static let buttonLabelWidth: CGFloat = width - 2 * 15
    /// One line of 13 pt Manrope semibold plus 9 pt of padding above and below. A button or dropdown in a row is exactly this
    /// high, so a label can never make one taller than its neighbours.
    package static let height: CGFloat = 36
    /// A label that is a little too long shrinks to this share of its size before it is cut.
    package static let minimumLabelScale: CGFloat = 0.85
    /// The room a dropdown's choice has beside its chevron and the gap to it.
    package static let choiceWidth: CGFloat = buttonLabelWidth - 8 - 10
}

/// What one button or dropdown in a setting row measured when it was drawn: the width its label wants on a single line, the width
/// it has, and the size of the whole control. Only collected when `measuresLauncherControls` is set (LauncherControlWidthTests
/// renders the real pages in every language with it), so the check covers every control a page shows without a list of labels.
package struct LauncherControlSample: Equatable {
    package init(labelWidth: CGFloat, room: CGFloat, size: CGSize) { self.labelWidth = labelWidth; self.room = room; self.size = size }
    package var labelWidth: CGFloat
    package var room: CGFloat
    package var size: CGSize
}

package struct LauncherControlSamples: PreferenceKey {
    package static var defaultValue: [LauncherControlSample] = []
    package static func reduce(value: inout [LauncherControlSample], nextValue: () -> [LauncherControlSample]) { value += nextValue() }
}

private struct MeasuresLauncherControlsKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    package var measuresLauncherControls: Bool {
        get { self[MeasuresLauncherControlsKey.self] }
        set { self[MeasuresLauncherControlsKey.self] = newValue }
    }
}

private struct LauncherControlMeasure<Label: View>: ViewModifier {
    let label: Label
    let room: CGFloat
    @Environment(\.measuresLauncherControls) private var measures
    @Environment(\.launcherControlWidth) private var width
    @ViewBuilder func body(content: Content) -> some View {
        if measures && width != nil {
            content.background(GeometryReader { box in
                label.fixedSize().hidden().background(GeometryReader { text in
                    Color.clear.preference(key: LauncherControlSamples.self,
                                           value: [LauncherControlSample(labelWidth: text.size.width, room: room, size: box.size)])
                })
            })
        } else {
            content
        }
    }
}

extension View {
    /// Reports this control, when it stands in a setting row, and the width its `label` wants (see LauncherControlSample) when a test asks for it.
    package func launcherMeasured<Label: View>(label: Label, room: CGFloat) -> some View {
        modifier(LauncherControlMeasure(label: label, room: room))
    }
}

private struct LauncherControlWidthKey: EnvironmentKey { static let defaultValue: CGFloat? = nil }

extension EnvironmentValues {
    /// Set inside a setting row: every button and dropdown there is exactly this wide.
    package var launcherControlWidth: CGFloat? {
        get { self[LauncherControlWidthKey.self] }
        set { self[LauncherControlWidthKey.self] = newValue }
    }
}

extension View {
    /// The trailing controls of a setting row: buttons and dropdowns take LauncherControl.width.
    package func launcherRowControls() -> some View { environment(\.launcherControlWidth, LauncherControl.width) }

    /// This text as wide and as high as a button of a setting row, on one line (for a control drawn by hand, like the cream capsule).
    package func launcherRowControlFrame() -> some View { modifier(LauncherRowControlFrame()) }
}

private struct LauncherRowControlFrame: ViewModifier {
    @Environment(\.launcherControlWidth) private var width
    func body(content: Content) -> some View {
        content
            .lineLimit(1).minimumScaleFactor(width == nil ? 1 : LauncherControl.minimumLabelScale)
            .padding(.horizontal, 15)
            .frame(width: width, height: width == nil ? nil : LauncherControl.height)
            .launcherMeasured(label: content, room: LauncherControl.buttonLabelWidth)
    }
}

package struct LauncherSecondaryButtonStyle: ButtonStyle {
    package init(accent: Color? = nil) { self.accent = accent }
    /// Text and border in this colour (the build bar's Stop); plain text otherwise.
    package var accent: Color? = nil
    package func makeBody(configuration: Configuration) -> some View {
        LauncherSecondaryButton(configuration: configuration, accent: accent)
    }
}

/// A secondary button: a quiet fill with a hairline. Light has its own fill under the pointer and pressed.
private struct LauncherSecondaryButton: View {
    let configuration: ButtonStyleConfiguration
    let accent: Color?
    /// Inside a setting row the button is exactly LauncherControl.width wide and LauncherControl.height high, its label centred on
    /// one line (a little smaller when it does not fit): the buttons of a page line up in one column and are equally high.
    @Environment(\.launcherControlWidth) private var width
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme
    @State private var hovered = false

    private var fill: Color {
        if configuration.isPressed { return LauncherPalette.secondaryPressed }
        return scheme == .light && hovered && enabled ? LauncherPalette.secondaryHover : LauncherPalette.secondaryFill
    }

    var body: some View {
        configuration.label
            .font(.manrope(13, .semibold))
            .multilineTextAlignment(.center)
            .lineLimit(1)
            .minimumScaleFactor(width == nil ? 1 : LauncherControl.minimumLabelScale)
            .padding(.horizontal, 15).padding(.vertical, 9)
            .frame(width: width, height: width == nil ? nil : LauncherControl.height)
            .background(fill, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(accent?.opacity(0.75) ?? LauncherPalette.secondaryBorder))
            .foregroundStyle(enabled ? (accent ?? LauncherPalette.text) : .gray)
            .opacity(enabled ? 1 : 0.55)
            .contentShape(RoundedRectangle(cornerRadius: 9))
            .launcherMeasured(label: configuration.label.font(.manrope(13, .semibold)), room: LauncherControl.buttonLabelWidth)
            .onHover { hovered = $0 }
            .launcherHover(lightBrightness: 0)
    }
}

/// The primary action outside the hero (Done, Save, Build, Add to queue): the cream fill in Dark, near-black with white text in
/// Light, darker when pressed and a little lighter under the pointer there. The label brings its own font and padding.
package struct LauncherActionButtonStyle: ButtonStyle {
    package enum Outline { case capsule, rounded(CGFloat) }
    package init(_ shape: Outline = .capsule) { self.shape = shape }
    package let shape: Outline
    package func makeBody(configuration: Configuration) -> some View { LauncherActionButton(configuration: configuration, shape: shape) }

    /// The fill for a state: Dark always the cream, Light pressed, under the pointer or at rest.
    package static func fill(light: Bool, pressed: Bool, hovered: Bool) -> Color {
        guard light else { return LauncherPalette.cream }
        return pressed ? LauncherPalette.primaryPressed : (hovered ? LauncherPalette.primaryHover : LauncherPalette.cream)
    }
}

private struct LauncherActionButton: View {
    let configuration: ButtonStyleConfiguration
    let shape: LauncherActionButtonStyle.Outline
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    var body: some View {
        let fill = LauncherActionButtonStyle.fill(light: scheme == .light, pressed: configuration.isPressed, hovered: hovered && enabled)
        configuration.label
            .foregroundStyle(LauncherPalette.onCream)
            .background { background(fill) }
            .onHover { hovered = $0 }
    }

    @ViewBuilder private func background(_ fill: Color) -> some View {
        switch shape {
        case .capsule: Capsule().fill(fill)
        case .rounded(let radius): RoundedRectangle(cornerRadius: radius).fill(fill)
        }
    }
}

/// A control's animation under the system's Reduce Motion setting: with it on, the control changes at once.
package enum LauncherMotion {
    package static func animation(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}

/// The launcher's switch: a cream track when on and a dim one when off in Dark, a near-black or a gray track with a white knob in Light.
package struct LauncherSwitchStyle: ToggleStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    package init() {}
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme
    package func makeBody(configuration: Configuration) -> some View {
        Button { withAnimation(LauncherMotion.animation(.spring(response: 0.25, dampingFraction: 0.8), reduceMotion: reduceMotion)) { configuration.isOn.toggle() } } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule().fill(configuration.isOn ? LauncherPalette.switchOnTrack : LauncherPalette.switchOffTrack)
                Circle().fill(configuration.isOn ? LauncherPalette.switchOnKnob : LauncherPalette.switchOffKnob)
                    .padding(3)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            }
            .frame(width: 40, height: 24)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : (scheme == .light ? 0.4 : 0.45))
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch)
        }
    }
}

/// The cream button of the library's hero (Play, Build game, Open on a device). It has one size in every state and language, so
/// the button does not change size when a game goes from not built to built. A long label shrinks, then ends in an ellipsis.
package enum LauncherHeroAction {
    package static let width: CGFloat = 200
    package static let height: CGFloat = 54
    package static let horizontalPadding: CGFloat = 24
    package static let iconSlot: CGFloat = 28
    package static let iconSpacing: CGFloat = 8
    package static let labelWidth = width - 2 * horizontalPadding - iconSlot - iconSpacing
    package static let minimumScale: CGFloat = 0.7
}

package struct LauncherHeroActionLabel: View {
    package init(title: String, symbol: String, loading: Bool = false) {
        self.title = title
        self.symbol = symbol
        self.loading = loading
    }
    package let title: String
    package let symbol: String
    package let loading: Bool

    package var body: some View {
        HStack(spacing: LauncherHeroAction.iconSpacing) {
            if loading {
                ProgressView()
                    .controlSize(.small)
                    .tint(LauncherPalette.onCream)
                    .frame(width: LauncherHeroAction.iconSlot)
            } else {
                Image(systemName: symbol).frame(width: LauncherHeroAction.iconSlot)
            }
            Text(title).lineLimit(1).minimumScaleFactor(LauncherHeroAction.minimumScale)
        }
        .font(.manrope(18, .bold))
        .foregroundStyle(LauncherPalette.onCream)
        .padding(.horizontal, LauncherHeroAction.horizontalPadding)
        .frame(width: LauncherHeroAction.width, height: LauncherHeroAction.height)
        .background(LauncherPalette.cream, in: Capsule())
    }
}

/// The height of a sheet of the launcher: at most 720 pt, and 80 pt shorter than the screen it is on.
package enum LauncherSheet {
    package static let width: CGFloat = 680
    package static func maxHeight(screen: CGFloat) -> CGFloat { min(720, max(320, screen - 80)) }
}

/// The width of a launch option's control (choices, list, slider with its value), so the controls of a card line up
/// in one column whatever their labels.
package enum LaunchControl {
    package static let width: CGFloat = 220
    /// A slider's value, in percent or in pixels: wide enough for "1920×1080" in 13 pt Manrope semibold with monospaced digits
    /// (71 pt), so every slider of the sheet is equally long and the reset arrows line up.
    package static let valueWidth: CGFloat = 72

    /// Characters the segments of one control share: a segment of 12.5 pt text, 24 pt of padding in 220 pt, takes about 10 with two
    /// choices and 6 with three.
    package static let segmentedCharacters = 20

    /// Segmented for two or three short labels, a menu otherwise. The game's language (DM_LANG) is always a menu, as on the iPhone.
    package static func isSegmented(env: String, labels: [String]) -> Bool {
        guard env != "DM_LANG", labels.count <= 3 else { return false }
        return labels.allSatisfy { $0.count <= segmentedCharacters / max(labels.count, 1) }
    }
}

/// Two or three choices side by side; the chosen one is a cream pill in Dark, a white one with a hairline in Light. Each choice takes an equal share of the width
/// it is given.
package struct LauncherSegmented: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    package init(options: [(value: String, label: String)], selection: String, size: CGFloat = 12.5, semibold: Bool = false,
                 choose: @escaping (String) -> Void) {
        self.options = options; self.selection = selection; self.size = size; self.semibold = semibold; self.choose = choose
    }
    package let options: [(value: String, label: String)]
    package let selection: String
    /// 12.5 pt with the chosen one bold, as in a setting row. The category selectors of a sheet use 13 pt semibold for every choice.
    package let size: CGFloat
    package let semibold: Bool
    package let choose: (String) -> Void
    package var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { o in
                let on = o.value == selection
                Button { withAnimation(LauncherMotion.animation(.easeOut(duration: 0.15), reduceMotion: reduceMotion)) { choose(o.value) } } label: {
                    Text(o.label).font(.manrope(size, semibold ? .semibold : (on ? (scheme == .light ? .semibold : .bold) : .medium)))
                        .foregroundStyle(on ? LauncherPalette.segmentSelectedText : LauncherPalette.segmentText)
                        .lineLimit(1).minimumScaleFactor(0.85)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(on ? LauncherPalette.segmentSelected : .clear, in: Capsule())
                        .overlay(Capsule().strokeBorder(on ? LauncherPalette.segmentSelectedBorder : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(LauncherPalette.segmentTrack, in: Capsule())
        .overlay(Capsule().strokeBorder(LauncherPalette.segmentTrackBorder))
    }

    /// Equal-share width sized so the longest option fits on one line at full size, at least `minWidth`.
    package static func compactWidth(labels: [String], size: CGFloat = 12.5, minWidth: CGFloat) -> CGFloat {
        guard !labels.isEmpty else { return minWidth }
        let maxLabel: CGFloat
        if let ct = Typography.manropeFont(size: size, weight: .bold) {
            maxLabel = labels.map { label in
                let attr = NSAttributedString(string: label, attributes: [kCTFontAttributeName as NSAttributedString.Key: ct])
                return ceil(CTLineGetBoundsWithOptions(CTLineCreateWithAttributedString(attr), []).width) + 1
            }.max() ?? 0
        } else {
            maxLabel = CGFloat(labels.map(\.count).max() ?? 0) * (size * 0.65)
        }
        let count = CGFloat(labels.count)
        let needed = ceil((maxLabel + 24) * count + 6 + 2 * max(0, count - 1))
        return min(max(minWidth, needed), 360)
    }

    package func compactFrame(minWidth: CGFloat) -> some View {
        frame(width: Self.compactWidth(labels: options.map(\.label), size: size, minWidth: minWidth))
    }
}

/// A slider without tick marks: a thin track, a cream fill and a round knob; snaps to its step.
package struct LauncherSlider: View {
    package init(value: Double, range: ClosedRange<Double>, step: Double, change: @escaping (Double) -> Void) {
        self.value = value; self.range = range; self.step = step; self.change = change
    }
    package let value: Double
    package let range: ClosedRange<Double>
    package let step: Double
    package let change: (Double) -> Void
    package var body: some View {
        GeometryReader { g in
            let span = range.upperBound - range.lowerBound
            let fraction = span > 0 ? (min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / span : 0
            let knob: CGFloat = 16, track = g.size.width - knob
            ZStack(alignment: .leading) {
                Capsule().fill(LauncherPalette.ink(0.14)).frame(height: 4).padding(.horizontal, knob / 2)
                Capsule().fill(LauncherPalette.accent).frame(width: track * fraction + knob / 2, height: 4).padding(.leading, knob / 2)
                Circle().fill(LauncherPalette.accent).frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    .offset(x: track * fraction)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let raw = range.lowerBound + Double(min(max(drag.location.x - knob / 2, 0), track) / max(track, 1)) * span
                change(Self.snapped(raw, range: range, step: step))
            })
        }
        .frame(height: 22)
        .focusable()
        .onMoveCommand { direction in
            switch direction {
            case .left: change(Self.moved(value, by: -1, range: range, step: step))
            case .right: change(Self.moved(value, by: 1, range: range, step: step))
            default: break
            }
        }
        .accessibilityRepresentation {
            Slider(value: Binding(get: { value }, set: change), in: range,
                   step: step > 0 ? step : (range.upperBound - range.lowerBound) / 20)
        }
    }

    /// A raw value on the slider's steps, inside its range. The steps count from the range's lower bound, as the
    /// accessibility `Slider` counts them, so a range of 1...9 with a step of 2 has 1, 3, 5, 7 and 9.
    package static func snapped(_ raw: Double, range: ClosedRange<Double>, step: Double) -> Double {
        let snapped = step > 0 ? range.lowerBound + ((raw - range.lowerBound) / step).rounded() * step : raw
        return min(max(snapped, range.lowerBound), range.upperBound)
    }

    /// The value one arrow key press away. Without a step it moves a twentieth of the range.
    package static func moved(_ value: Double, by presses: Int, range: ClosedRange<Double>, step: Double) -> Double {
        let unit = step > 0 ? step : (range.upperBound - range.lowerBound) / 20
        return snapped(value + Double(presses) * unit, range: range, step: step)
    }
}
