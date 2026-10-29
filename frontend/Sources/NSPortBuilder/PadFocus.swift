import SwiftUI

/// Controller focus across the launcher. macOS gives SwiftUI controls keyboard focus only with Full Keyboard Access
/// turned on, so the launcher keeps a focus of its own: every control a controller can reach is a target (`padTarget`)
/// that reports its frame in its scope (the main window, or one sheet). The D-pad or left stick moves to the nearest
/// target in that direction, A activates it, and on a target that holds a value (a choice, a slider, a switch) left and
/// right change the value instead. The ring shows only after a controller was used, so mouse users never see it.
final class PadFocus: ObservableObject {
    struct Target: Equatable { let id: String; let frame: CGRect }
    struct Handlers { var activate: (() -> Void)?; var adjust: ((Int) -> Void)? }

    @Published var focused: String?
    @Published private(set) var visible = false
    /// The scope the controller acts in: "main", or the open sheet's.
    var scope = "main" { didSet { if scope != oldValue { focused = nil } } }
    private var frames: [String: [Target]] = [:]
    private var handlers: [String: Handlers] = [:]   // refreshed on every render of the target, so the closures see current state

    func setFrames(_ targets: [Target], scope: String) { frames[scope] = targets }
    func register(_ id: String, _ h: Handlers) { handlers[id] = h }

    /// Focus a target (a default when nothing is focused yet) and show the ring.
    func show(default id: String?) {
        visible = true
        if focused == nil || !(frames[scope] ?? []).contains(where: { $0.id == focused }) {
            focused = id.flatMap { want in (frames[scope] ?? []).first { $0.id == want }?.id } ?? topLeft()
        }
    }

    func hide() { visible = false }

    /// Left / right: the target's own value when it holds one, else a move.
    func horizontal(_ step: Int) {
        if let id = focused, let adjust = handlers[id]?.adjust { adjust(step) } else { move(dx: CGFloat(step), dy: 0) }
    }

    func activate() { if let id = focused { handlers[id]?.activate?() } }

    /// The nearest target in the direction, scored by distance along it plus twice the distance across it. Left and right
    /// stay in the row (the target must overlap it vertically), so the last card does not jump to a button across the
    /// screen; up and down prefer a target in the same column and take the nearest otherwise (a card row up to the tabs).
    func move(dx: CGFloat, dy: CGFloat) {
        let all = frames[scope] ?? []
        guard let current = all.first(where: { $0.id == focused })?.frame else { focused = topLeft(); return }
        let from = CGPoint(x: current.midX, y: current.midY)
        let ahead = all.filter { $0.id != focused }.compactMap { t -> (target: Target, score: CGFloat)? in
            let to = CGPoint(x: t.frame.midX, y: t.frame.midY)
            let along = dx != 0 ? (to.x - from.x) * dx : (to.y - from.y) * dy
            let across = dx != 0 ? abs(to.y - from.y) : abs(to.x - from.x)
            return along > 4 ? (t, along + 2 * across) : nil
        }
        let overlapping = ahead.filter { c in
            dx != 0 ? c.target.frame.minY < current.maxY && c.target.frame.maxY > current.minY
                    : c.target.frame.minX < current.maxX && c.target.frame.maxX > current.minX
        }
        let pool = dx != 0 || !overlapping.isEmpty ? overlapping : ahead
        if let best = pool.min(by: { $0.score < $1.score }) { focused = best.target.id }
    }

    private func topLeft() -> String? {
        (frames[scope] ?? []).min { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }?.id
    }
}

private struct PadTargetKey: PreferenceKey {
    static var defaultValue: [PadFocus.Target] = []
    static func reduce(value: inout [PadFocus.Target], nextValue: () -> [PadFocus.Target]) { value += nextValue() }
}

extension View {
    /// A control the controller can focus: A runs `activate`, left / right run `adjust` when given. `shape` draws the ring.
    func padTarget(_ id: String, scope: String, radius: CGFloat = 9, activate: (() -> Void)? = nil, adjust: ((Int) -> Void)? = nil) -> some View {
        modifier(PadTargetModifier(id: id, scope: scope, radius: radius, handlers: .init(activate: activate, adjust: adjust)))
    }

    /// The root of a scope: collects its targets' frames for the focus.
    func padScope(_ scope: String, _ focus: PadFocus) -> some View {
        coordinateSpace(name: "pad." + scope)
            .onPreferenceChange(PadTargetKey.self) { focus.setFrames($0, scope: scope) }
    }
}

/// How the focus ring sits on a control. The desktop launcher draws it 4 points outside. The console mode draws it on the
/// control's own edge, in the control's own shape (`radius`), so there is no gap and layout never changes with focus.
enum PadRingStyle { case outset, hug }
private struct PadRingStyleKey: EnvironmentKey { static let defaultValue = PadRingStyle.outset }
extension EnvironmentValues {
    var padRingStyle: PadRingStyle {
        get { self[PadRingStyleKey.self] }
        set { self[PadRingStyleKey.self] = newValue }
    }
}

private struct PadTargetModifier: ViewModifier {
    let id: String, scope: String, radius: CGFloat
    let handlers: PadFocus.Handlers
    @EnvironmentObject private var focus: PadFocus
    @Environment(\.padRingStyle) private var ringStyle

    func body(content: Content) -> some View {
        focus.register(id, handlers)
        let on = focus.visible && focus.focused == id
        return content
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(LauncherPalette.cream, lineWidth: on ? 2 : 0).padding(ringStyle == .hug ? 0 : -4).allowsHitTesting(false))
            .background(GeometryReader { g in
                Color.clear.preference(key: PadTargetKey.self, value: [.init(id: id, frame: g.frame(in: .named("pad." + scope)))])
            })
            .id(id)
    }
}
