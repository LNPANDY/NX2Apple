import SwiftUI
import CoreText

package struct LauncherWindowChrome: NSViewRepresentable {
    package init() {}
    package final class ChromeView: NSView {
        package override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.appearance = NSAppearance(named: .darkAqua)   // the launcher is dark only (#1458)
            window.backgroundColor = LauncherPalette.backgroundNSColor
            window.isMovableByWindowBackground = true
        }
    }
    package func makeNSView(context: Context) -> NSView { ChromeView() }
    package func updateNSView(_ nsView: NSView, context: Context) {}
}

/// The line under the top bar: a hairline.
package struct LauncherTopBarRule: View {
    package init() {}
    package var body: some View { LauncherPalette.topBarRule.frame(height: 1) }
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

/// Dropdowns share a trailing column; adjacent actions hug their labels up to this width.
package enum LauncherControl {
    /// Wide enough for the longest everyday label in every language on one line ("Sök efter uppdateringar", 148 pt in 13 pt
    /// Manrope semibold, plus the buttons' 15 pt of padding on each side). LauncherControlWidthTests measures them all.
    package static let width: CGFloat = DS.Control.columnWidth
    /// What the label of a button may take.
    package static let buttonLabelWidth: CGFloat = width - 2 * 15
    /// One line of 13 pt Manrope semibold plus 9 pt of padding above and below. A button or dropdown in a row is exactly this
    /// high, so a label can never make one taller than its neighbours.
    package static let height: CGFloat = DS.Control.height
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
    /// Set inside a setting row: dropdown width and maximum action width.
    package var launcherControlWidth: CGFloat? {
        get { self[LauncherControlWidthKey.self] }
        set { self[LauncherControlWidthKey.self] = newValue }
    }
}

extension View {
    /// The trailing controls of a setting row share a height and dropdown-width limit.
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

/// The colour of everything inside a button: its label, its symbols and its spinner (DSSpinner). Each button style sets it once
/// from its role, so nothing inside a button picks its own colour (a cream spinner on the cream primary was invisible, #1458).
package enum DSButtonForeground {
    /// The primary action: black on the cream.
    package static let primary = DS.Color.accentOn
    /// Every flat or glass secondary button and icon button.
    package static let flat = DS.Color.textPrimary
    /// A destructive button: white on the error fill.
    package static let destructive = DS.Color.statusErrorOn
    /// Any disabled button.
    package static let disabled = DS.Color.textTertiary
}

private struct DSButtonForegroundKey: EnvironmentKey { static let defaultValue: Color? = nil }

extension EnvironmentValues {
    /// Set by the launcher's button styles: the colour their content takes (DSButtonForeground). Nil outside a button.
    package var dsButtonForeground: Color? {
        get { self[DSButtonForegroundKey.self] }
        set { self[DSButtonForegroundKey.self] = newValue }
    }
}

extension View {
    /// Gives a button's content its foreground: text and symbols through the foreground style, a system control through the tint,
    /// a DSSpinner through the environment.
    package func dsButtonContent(_ color: Color) -> some View {
        foregroundStyle(color).tint(color).environment(\.dsButtonForeground, color)
    }
}

/// The launcher's spinner. It is drawn in the colour of the button it sits in (DSButtonForeground), or in symbol.default outside
/// one, because AppKit's small ProgressView ignores the tint and stays light on the cream.
package struct DSSpinner: View {
    package init(size: CGFloat = 14) { self.size = size }
    let size: CGFloat
    @Environment(\.dsButtonForeground) private var buttonForeground
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turning = false
    package var body: some View {
        Circle().trim(from: 0.08, to: 0.78)
            .stroke(buttonForeground ?? DS.Color.symbolDefault, style: StrokeStyle(lineWidth: max(1.5, size / 8), lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(turning ? 360 : 0))
            .animation(reduceMotion ? nil : .linear(duration: 0.9).repeatForever(autoreverses: false), value: turning)
            .onAppear { turning = true }
            .accessibilityElement().accessibilityAddTraits(.updatesFrequently)
    }
}

package struct LauncherSecondaryButtonStyle: ButtonStyle {
    package init(accent: Color? = nil, height: CGFloat = LauncherControl.height) {
        self.accent = accent; self.height = height
    }
    package let height: CGFloat
    /// Text and border in this colour (the build bar's Stop); plain text otherwise.
    package var accent: Color? = nil
    package func makeBody(configuration: Configuration) -> some View {
        LauncherSecondaryButton(configuration: configuration, accent: accent, height: height, destructive: false)
    }
}

/// A destructive action that stands on its own (Uninstall): the error fill with a white label. A destructive choice in a list or
/// a "…" menu is a red row instead (LauncherDropdownRequest's destructiveValues).
package struct DSDestructiveButtonStyle: ButtonStyle {
    package init(height: CGFloat = LauncherControl.height) { self.height = height }
    package let height: CGFloat
    package func makeBody(configuration: Configuration) -> some View {
        LauncherSecondaryButton(configuration: configuration, accent: nil, height: height, destructive: true)
    }
}

/// A secondary button: clear Liquid Glass in the navigation layer, a flat raised fill with a hairline in the content (LauncherGlass.swift).
private struct LauncherSecondaryButton: View {
    let configuration: ButtonStyleConfiguration
    let accent: Color?
    let height: CGFloat
    let destructive: Bool
    private var fontSize: CGFloat { height > LauncherControl.height ? 16 : 13 }
    /// Inside a setting row, actions hug their labels up to the shared control-column width.
    @Environment(\.launcherControlWidth) private var width
    @Environment(\.isEnabled) private var enabled
    @Environment(\.launcherGlassLayer) private var glassLayer
    @State private var hovered = false

    /// The stand-in's veil where the live glass is not drawn: a little brighter under the pointer and pressed.
    private var fill: Color {
        if configuration.isPressed { return LauncherPalette.ink(0.14) }
        return hovered && enabled ? LauncherPalette.ink(0.11) : (glassLayer ? LauncherGlass.veil : DS.Color.surfaceRaised)
    }

    var body: some View {
        configuration.label
            .font(.manrope(fontSize, .semibold))
            .multilineTextAlignment(.center)
            .lineLimit(1)
            .minimumScaleFactor(width == nil ? 1 : LauncherControl.minimumLabelScale)
            .padding(.horizontal, 15)
            .frame(height: height)
            .frame(width: width)   // in a setting row every button is as wide as the control column (DS.Control.columnWidth)
            .contentShape(Capsule())
            .launcherControlSurface(in: DSPill(), tint: destructive ? DS.Color.statusErrorFill : nil, fallback: fill, border: accent?.opacity(0.75))
            .dsButtonContent(!enabled ? DSButtonForeground.disabled : destructive ? DSButtonForeground.destructive : (accent ?? DSButtonForeground.flat))
            .launcherMeasured(label: configuration.label.font(.manrope(fontSize, .semibold)), room: LauncherControl.buttonLabelWidth)
            .onHover { hovered = $0 }
            .launcherHover()
    }
}

/// The primary action of a screen (Play, Build, Done, Save, Add to queue): the cream accent with black text, Liquid Glass in the
/// navigation layer and a flat fill in the content (launcherControlSurface). Disabled, it is the raised surface with tertiary text. The
/// label brings its own font and padding.
package struct LauncherActionButtonStyle: ButtonStyle {
    package enum Outline { case capsule, rounded(CGFloat) }
    package init(_ shape: Outline = .capsule) { self.shape = shape }
    package let shape: Outline
    package func makeBody(configuration: Configuration) -> some View { LauncherActionButton(configuration: configuration, shape: shape) }
}

private struct LauncherActionButton: View {
    let configuration: ButtonStyleConfiguration
    let shape: LauncherActionButtonStyle.Outline
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        configuration.label
            .dsButtonContent(enabled ? DSButtonForeground.primary : DSButtonForeground.disabled)   // disabled: the raised surface, tertiary text
            .frame(minHeight: LauncherControl.height)
            .contentShape(Rectangle())
            .modifier(Tinted(shape: shape))
    }

    private struct Tinted: ViewModifier {
        let shape: LauncherActionButtonStyle.Outline
        @ViewBuilder func body(content: Content) -> some View {
            switch shape {
            case .capsule: content.launcherControlSurface(in: DSPill(), tint: LauncherPalette.cream)
            case .rounded(let radius): content.launcherControlSurface(in: RoundedRectangle(cornerRadius: radius), tint: LauncherPalette.cream)
            }
        }
    }
}

/// A control's animation under the system's Reduce Motion setting: with it on, the control changes at once.
package enum LauncherMotion {
    package static func animation(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}

/// The launcher's switch: a cream track when on and a dim one when off.
package struct LauncherSwitchStyle: ToggleStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    package init() {}
    @Environment(\.isEnabled) private var enabled
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
        .opacity(enabled ? 1 : 0.45)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch)
        }
    }
}

/// Hero actions share a height; the label determines their width.
package enum LauncherHeroAction {
    package static let minimumWidth: CGFloat = 120
    package static let height: CGFloat = 44
    package static let horizontalPadding: CGFloat = 24
    package static let iconSlot: CGFloat = 20
    package static let iconSpacing: CGFloat = 8
}

package struct LauncherHeroActionLabel: View {
    package init(title: String, symbol: String, loading: Bool = false) {
        self.title = title; self.symbol = symbol; self.loading = loading
    }
    package let title: String
    package let symbol: String
    package let loading: Bool

    package var body: some View {
        HStack(spacing: LauncherHeroAction.iconSpacing) {
            if loading {
                DSSpinner(size: 15).frame(width: LauncherHeroAction.iconSlot)   // the button's foreground: black on the cream
            } else { Image(systemName: symbol).frame(width: LauncherHeroAction.iconSlot) }
            Text(title).lineLimit(1).minimumScaleFactor(LauncherControl.minimumLabelScale)
        }
        .font(.manrope(16, .semibold))
        .padding(.horizontal, LauncherHeroAction.horizontalPadding)
        .frame(minWidth: LauncherHeroAction.minimumWidth, minHeight: LauncherHeroAction.height, maxHeight: LauncherHeroAction.height)
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

/// Two or three choices side by side, the chosen pill cream. Each choice takes an equal share of the width
/// it is given.
package struct LauncherSegmented: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    @Environment(\.isEnabled) private var enabled
    package var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { o in
                let on = o.value == selection
                Button { withAnimation(LauncherMotion.animation(.easeOut(duration: 0.15), reduceMotion: reduceMotion)) { choose(o.value) } } label: {
                    Text(o.label).font(.manrope(size, semibold ? .semibold : (on ? .bold : .medium)))
                        .foregroundStyle(on ? LauncherPalette.segmentSelectedText : LauncherPalette.segmentText)
                        .lineLimit(1).minimumScaleFactor(0.85)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, minHeight: LauncherControl.height - 6)
                        .background(on ? LauncherPalette.segmentSelected : .clear, in: Capsule())
                        .overlay(DSPill().strokeBorder(on ? LauncherPalette.segmentSelectedBorder : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(LauncherPalette.segmentTrack, in: Capsule())
        .overlay(DSPill().strokeBorder(LauncherPalette.segmentTrackBorder))
        .opacity(enabled ? 1 : 0.45)

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
