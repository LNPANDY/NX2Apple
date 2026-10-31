import SwiftUI

struct LauncherWindowChrome: NSViewRepresentable {
    final class ChromeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.backgroundColor = NSColor(red: 0.055, green: 0.055, blue: 0.06, alpha: 1)
            window.isMovableByWindowBackground = true
        }
    }
    func makeNSView(context: Context) -> NSView { ChromeView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// What a double-click on the title bar does, as System Settings → Desktop & Dock sets it.
enum TitlebarAction: Equatable {
    case zoom, minimize, none

    /// `AppleActionOnDoubleClick` ("Maximize", "Fill", "Minimize", "None") wins; the older `AppleMiniaturizeOnDoubleClick` bool is read only
    /// without it; with neither, macOS's default (zoom).
    static func resolve(actionSetting: String?, miniaturizeFlag: Bool?) -> TitlebarAction {
        if let value = actionSetting?.trimmingCharacters(in: .whitespaces).lowercased(), !value.isEmpty {
            switch value {
            case "minimize": return .minimize
            case "none", "do nothing", "nothing": return .none
            default: return .zoom   // Maximize, Fill, or a value a later macOS adds
            }
        }
        return miniaturizeFlag == true ? .minimize : .zoom
    }

    static var current: TitlebarAction {
        let d = UserDefaults.standard   // the global domain is searched too
        return resolve(actionSetting: d.string(forKey: "AppleActionOnDoubleClick"),
                       miniaturizeFlag: d.object(forKey: "AppleMiniaturizeOnDoubleClick") as? Bool)
    }

    func perform(on window: NSWindow?) {
        switch self {
        case .zoom: window?.zoom(nil)   // fills the screen, traffic lights kept; a second one restores
        case .minimize: window?.miniaturize(nil)
        case .none: break
        }
    }
}

/// Sits behind the top bar. Controls above it keep their clicks; on an empty part a double-click does the title bar's action
/// and a single press drags the window (the view takes the mouse-down, so it starts the drag itself).
struct TitlebarDoubleClick: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { TitlebarAction.current.perform(on: window) }
            else { window?.performDrag(with: event) }
        }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// The width of the button or dropdown at the trailing end of a setting row, the same on every page, so that these
/// controls stand in one column whatever their labels. A row hands it to its trailing controls (`launcherRowControls()`),
/// and LauncherSecondaryButtonStyle and LauncherDropdown take it from there. Outside a row they size to their label.
enum LauncherControl {
    /// Wide enough for the longest everyday label in every language on one line ("Sök efter uppdateringar", 148 pt in 13 pt
    /// Manrope semibold, plus the buttons' 15 pt of padding on each side). LauncherControlWidthTests measures them all.
    static let width: CGFloat = 184
    /// What the label of a button may take.
    static let buttonLabelWidth: CGFloat = width - 2 * 15
}

private struct LauncherControlWidthKey: EnvironmentKey { static let defaultValue: CGFloat? = nil }

extension EnvironmentValues {
    /// Set inside a setting row: every button and dropdown there is exactly this wide.
    var launcherControlWidth: CGFloat? {
        get { self[LauncherControlWidthKey.self] }
        set { self[LauncherControlWidthKey.self] = newValue }
    }
}

extension View {
    /// The trailing controls of a setting row: buttons and dropdowns take LauncherControl.width.
    func launcherRowControls() -> some View { environment(\.launcherControlWidth, LauncherControl.width) }

    /// This view as wide as a button of a setting row (for a control drawn by hand, like the cream capsule).
    func launcherRowControlFrame() -> some View { modifier(LauncherRowControlFrame()) }
}

private struct LauncherRowControlFrame: ViewModifier {
    @Environment(\.launcherControlWidth) private var width
    func body(content: Content) -> some View { content.frame(width: width) }
}

struct LauncherSecondaryButtonStyle: ButtonStyle {
    /// Text and border in this colour (the build bar's Stop); plain white otherwise.
    var accent: Color? = nil
    /// Inside a setting row the button is exactly LauncherControl.width wide, its label centred and wrapped to a second
    /// line when it does not fit: the buttons of a page line up in one column.
    @Environment(\.launcherControlWidth) private var width
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.manrope(13, .semibold))
            .multilineTextAlignment(.center)
            .lineLimit(width == nil ? 1 : 2)
            .padding(.horizontal, 15).padding(.vertical, 9)
            .frame(width: width)
            .background(Color.white.opacity(configuration.isPressed ? 0.13 : 0.055), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(accent?.opacity(0.75) ?? Color.white.opacity(0.10)))
            .foregroundStyle(enabled ? (accent ?? Color.white.opacity(0.92)) : .gray)
            .opacity(enabled ? 1 : 0.55)
            .contentShape(RoundedRectangle(cornerRadius: 9))
    }
}

/// The launcher's switch: a cream track when on, a dim one when off.
struct LauncherSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
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

/// The width of a launch option's control (choices, list, slider with its value), so the controls of a card line up
/// in one column whatever their labels.
enum LaunchControl {
    static let width: CGFloat = 220

    /// Characters the segments of one control share: a segment of 12.5 pt text, 24 pt of padding in 220 pt, takes about 10 with two
    /// choices and 6 with three.
    static let segmentedCharacters = 20

    /// Segmented for two or three short labels, a menu otherwise. The game's language (DM_LANG) is always a menu, as on the iPhone.
    static func isSegmented(env: String, labels: [String]) -> Bool {
        guard env != "DM_LANG", labels.count <= 3 else { return false }
        return labels.allSatisfy { $0.count <= segmentedCharacters / max(labels.count, 1) }
    }
}

/// Two or three choices side by side; the chosen one is a cream pill. Each choice takes an equal share of the width
/// it is given.
struct LauncherSegmented: View {
    let options: [(value: String, label: String)]
    let selection: String
    let choose: (String) -> Void
    var body: some View {
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
struct LauncherSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let change: (Double) -> Void
    var body: some View {
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
