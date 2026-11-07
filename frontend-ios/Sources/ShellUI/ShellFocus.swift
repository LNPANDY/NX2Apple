import SwiftUI

/// Focus geometry and activation are transient UI state. Hardware belongs to the caller.
struct FocusTarget: Equatable {
    let id: String
    let frame: CGRect
    let activate: () -> Void
    // A new render can change an activation closure without changing its frame or ID.
    private let generation = UUID()
    init(id: String, frame: CGRect, activate: @escaping () -> Void) {
        self.id = id
        self.frame = frame
        self.activate = activate
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.frame == rhs.frame && lhs.generation == rhs.generation
    }
}

/// A non-observed UI registry avoids feeding preference updates back into view rendering.
/// It holds only the latest focus geometry and actions, never game or settings state.
@MainActor final class FocusTargetBuffer {
    var values: [FocusTarget] = []
    // Native sheets host their own preferences; retain the library targets while a sheet is open.
    var libraryValues: [FocusTarget] = []
    var toolbarValues: [String: FocusTarget] = [:]

    func active(prefix: String, toolbarIDs: Set<String>) -> [FocusTarget] {
        let content = (libraryValues + values).filter { !toolbarIDs.contains($0.id) }
        let toolbar = toolbarValues.values.filter { toolbarIDs.contains($0.id) }.sorted { $0.id < $1.id }
        return (content + toolbar).filter { $0.id.hasPrefix(prefix) && $0.frame.width > 1 }
    }
}
struct FocusTargets: PreferenceKey {
    static var defaultValue: [FocusTarget] { [] }
    static func reduce(value: inout [FocusTarget], nextValue: () -> [FocusTarget]) { value += nextValue() }
}
struct FocusAppearance: Equatable {
    var id: String?
    var visible = false
}
private struct FocusAppearanceKey: EnvironmentKey {
    static var defaultValue: FocusAppearance { FocusAppearance() }
}
private struct IgnoresPressKey: EnvironmentKey {
    static var defaultValue: () -> Bool { { false } }
}
extension EnvironmentValues {
    /// True while a press is the system's echo of a controller button, not a finger (see `LibraryView.noteTouch`). A
    /// control that moves at once on a press, before its value comes back, asks it first.
    var shellIgnoresPress: () -> Bool {
        get { self[IgnoresPressKey.self] }
        set { self[IgnoresPressKey.self] = newValue }
    }
    var shellFocus: FocusAppearance {
        get { self[FocusAppearanceKey.self] }
        set { self[FocusAppearanceKey.self] = newValue }
    }
}
struct ShellFocusTarget: ViewModifier {
    let id: String
    let enabled: Bool
    /// The ring follows the control's shape: 12 for covers and cards, a large value for capsules and circles.
    let radius: CGFloat
    var showsRing = true
    let action: () -> Void
    @Environment(\.shellFocus) private var focus
    func body(content: Content) -> some View {
        content
            .overlay {
                if showsRing && focus.visible && focus.id == id {
                    RoundedRectangle(cornerRadius: radius + 5).strokeBorder(ShellPalette.cream, lineWidth: 3)
                        .padding(-5).allowsHitTesting(false).accessibilityHidden(true)
                        // On and off at once: a ring fading in or out stays where it was while a panel slides, apart
                        // from its control.
                        .transition(.identity)
                }
            }
            .background {
                if enabled {
                    GeometryReader { geometry in
                        Color.clear.preference(key: FocusTargets.self, value: [
                            FocusTarget(id: id, frame: geometry.frame(in: .global), activate: action)
                        ])
                    }
                }
            }
            .id(id)
    }
}
extension View {
    func shellTarget(_ id: String, enabled: Bool = true, radius: CGFloat = 12, showsRing: Bool = true, action: @escaping () -> Void) -> some View {
        modifier(ShellFocusTarget(id: id, enabled: enabled, radius: radius, showsRing: showsRing, action: action))
    }
}

/// Pure spatial focus selection shared by the UI and its navigation tests.
enum FocusNavigation {
    static func next(from id: String?, action: ShellInput.Action, targets: [FocusTarget]) -> String? {
        guard let origin = targets.first(where: { $0.id == id }) else { return targets.first?.id }
        let candidates = targets.filter { target in
            guard target.id != origin.id else { return false }
            let dx = target.frame.midX - origin.frame.midX
            let dy = target.frame.midY - origin.frame.midY
            switch action {
            case .left: return dx < -8
            case .right: return dx > 8
            case .up: return dy < -8
            case .down: return dy > 8
            default: return false
            }
        }
        func score(_ target: FocusTarget) -> CGFloat {
            let dx = abs(target.frame.midX - origin.frame.midX)
            let dy = abs(target.frame.midY - origin.frame.midY)
            switch action {
            case .left, .right: return dx + dy * 3
            default: return dy + dx * 3
            }
        }
        return candidates.min(by: { score($0) < score($1) })?.id ?? id
    }
}

private struct ShellNativeBarsKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var shellNativeBars: Bool {
        get { self[ShellNativeBarsKey.self] }
        set { self[ShellNativeBarsKey.self] = newValue }
    }
}

/// Keyboard commands use a non-text responder on iOS, so a context menu cannot summon a text keyboard.
struct ShellKeyboardNavigation: ViewModifier {
    let active: Bool
    let handle: (ShellInput.Action) -> Void
    @FocusState private var focused: Bool
    func body(content: Content) -> some View {
        #if os(iOS)
        content.background { ShellKeyCommands(active: active, handle: handle).frame(width: 0, height: 0) }
        #else
        content.focusable(active).focused($focused).focusEffectDisabled()
            .onAppear { focused = active }
            .onChange(of: active) { _, value in focused = value }
            .onKeyPress(.leftArrow) { press(.left) }
            .onKeyPress(.rightArrow) { press(.right) }
            .onKeyPress(.upArrow) { press(.up) }
            .onKeyPress(.downArrow) { press(.down) }
            .onKeyPress(.return) { press(.activate) }
            .onKeyPress(.escape) { press(.back) }
            .onKeyPress("o") { press(.settings) }
            .onKeyPress("y") { press(.controllers) }
        #endif
    }
    private func press(_ action: ShellInput.Action) -> KeyPress.Result {
        guard active else { return .ignored }
        handle(action)
        return .handled
    }
}

#if os(iOS)
private struct ShellKeyCommands: UIViewRepresentable {
    let active: Bool
    let handle: (ShellInput.Action) -> Void
    func makeUIView(context: Context) -> CommandView { CommandView() }
    func updateUIView(_ view: CommandView, context: Context) {
        view.active = active
        view.handle = handle
        if active, view.window != nil, !view.isFirstResponder { view.becomeFirstResponder() }
        else if !active, view.isFirstResponder { view.resignFirstResponder() }
    }
    final class CommandView: UIView {
        var active = false
        var handle: ((ShellInput.Action) -> Void)?
        private static let actions: [(String, ShellInput.Action)] = [
            (UIKeyCommand.inputLeftArrow, .left), (UIKeyCommand.inputRightArrow, .right),
            (UIKeyCommand.inputUpArrow, .up), (UIKeyCommand.inputDownArrow, .down),
            ("\r", .activate), (UIKeyCommand.inputEscape, .back), ("o", .settings), ("y", .controllers)
        ]
        override var canBecomeFirstResponder: Bool { active }
        override var keyCommands: [UIKeyCommand]? {
            active ? Self.actions.map { UIKeyCommand(input: $0.0, modifierFlags: [], action: #selector(command(_:))) } : nil
        }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if active, window != nil { becomeFirstResponder() }
        }
        @objc private func command(_ command: UIKeyCommand) {
            guard active, let action = Self.actions.first(where: { $0.0 == command.input })?.1 else { return }
            handle?(action)
        }
    }
}
#endif
