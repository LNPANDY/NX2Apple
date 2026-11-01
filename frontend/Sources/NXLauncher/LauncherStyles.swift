import SwiftUI

package struct LauncherWindowChrome: NSViewRepresentable {
    package init() {}
    package final class ChromeView: NSView {
        package override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.backgroundColor = NSColor(red: 0.055, green: 0.055, blue: 0.06, alpha: 1)
            window.isMovableByWindowBackground = true
        }
    }
    package func makeNSView(context: Context) -> NSView { ChromeView() }
    package func updateNSView(_ nsView: NSView, context: Context) {}
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
    /// Text and border in this colour (the build bar's Stop); plain white otherwise.
    package var accent: Color? = nil
    /// Inside a setting row the button is exactly LauncherControl.width wide and LauncherControl.height high, its label centred on
    /// one line (a little smaller when it does not fit): the buttons of a page line up in one column and are equally high.
    @Environment(\.launcherControlWidth) private var width
    @Environment(\.isEnabled) private var enabled
    package func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.manrope(13, .semibold))
            .multilineTextAlignment(.center)
            .lineLimit(1)
            .minimumScaleFactor(width == nil ? 1 : LauncherControl.minimumLabelScale)
            .padding(.horizontal, 15).padding(.vertical, 9)
            .frame(width: width, height: width == nil ? nil : LauncherControl.height)
            .background(Color.white.opacity(configuration.isPressed ? 0.13 : 0.055), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(accent?.opacity(0.75) ?? Color.white.opacity(0.10)))
            .foregroundStyle(enabled ? (accent ?? Color.white.opacity(0.92)) : .gray)
            .opacity(enabled ? 1 : 0.55)
            .contentShape(RoundedRectangle(cornerRadius: 9))
            .launcherMeasured(label: configuration.label.font(.manrope(13, .semibold)), room: LauncherControl.buttonLabelWidth)
    }
}

/// The launcher's switch: a cream track when on, a dim one when off.
package struct LauncherSwitchStyle: ToggleStyle {
    package init() {}
    @Environment(\.isEnabled) private var enabled
    package func makeBody(configuration: Configuration) -> some View {
        Button { withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { configuration.isOn.toggle() } } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule().fill(configuration.isOn ? LauncherPalette.cream : Color.white.opacity(0.14))
                Circle().fill(configuration.isOn ? LauncherPalette.background : Color.white.opacity(0.85))
                    .padding(3)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            }
            .frame(width: 40, height: 24)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
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
    package init(title: String, symbol: String) { self.title = title; self.symbol = symbol }
    package let title: String
    package let symbol: String

    package var body: some View {
        HStack(spacing: LauncherHeroAction.iconSpacing) {
            Image(systemName: symbol).frame(width: LauncherHeroAction.iconSlot)
            Text(title).lineLimit(1).minimumScaleFactor(LauncherHeroAction.minimumScale)
        }
        .font(.manrope(18, .bold))
        .foregroundStyle(.black)
        .padding(.horizontal, LauncherHeroAction.horizontalPadding)
        .frame(width: LauncherHeroAction.width, height: LauncherHeroAction.height)
        .background(LauncherPalette.cream, in: Capsule())
    }
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

/// Two or three choices side by side; the chosen one is a cream pill. Each choice takes an equal share of the width
/// it is given.
package struct LauncherSegmented: View {
    package init(options: [(value: String, label: String)], selection: String, choose: @escaping (String) -> Void) {
        self.options = options; self.selection = selection; self.choose = choose
    }
    package let options: [(value: String, label: String)]
    package let selection: String
    package let choose: (String) -> Void
    package var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { o in
                let on = o.value == selection
                Button { withAnimation(.easeOut(duration: 0.15)) { choose(o.value) } } label: {
                    Text(o.label).font(.manrope(12.5, on ? .bold : .medium))
                        .foregroundStyle(on ? Color.black : Color.white.opacity(0.75))
                        .lineLimit(1).minimumScaleFactor(0.85)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(on ? LauncherPalette.cream : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Color.white.opacity(0.06), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08)))
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
                Capsule().fill(Color.white.opacity(0.14)).frame(height: 4).padding(.horizontal, knob / 2)
                Capsule().fill(LauncherPalette.cream).frame(width: track * fraction + knob / 2, height: 4).padding(.leading, knob / 2)
                Circle().fill(LauncherPalette.cream).frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    .offset(x: track * fraction)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let raw = range.lowerBound + Double(min(max(drag.location.x - knob / 2, 0), track) / max(track, 1)) * span
                let snapped = step > 0 ? (raw / step).rounded() * step : raw
                change(min(max(snapped, range.lowerBound), range.upperBound))
            })
        }
        .frame(height: 22)
    }
}
