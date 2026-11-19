import SwiftUI

/// Controller focus across the launcher. macOS gives SwiftUI controls keyboard focus only with Full Keyboard Access
/// turned on, so the launcher keeps a focus of its own: every control a controller can reach is a target (`padTarget`)
/// that reports its frame in its scope (the main window, or one sheet). The D-pad or left stick moves to the nearest
/// target in that direction, A activates it, and on a target that holds a value (a choice, a slider, a switch) left and
/// right change the value instead. The ring shows only after a controller was used, so mouse users never see it.
package final class PadFocus: ObservableObject {
    package struct Target: Equatable {
        package let id: String
        package let frame: CGRect
        package init(id: String, frame: CGRect) { self.id = id; self.frame = frame }
    }
    package struct Handlers {
        package var activate: (() -> Void)?
        package var adjust: ((Int) -> Void)?
        package var vertical: ((Int) -> Bool)?
        package init(activate: (() -> Void)? = nil, adjust: ((Int) -> Void)? = nil, vertical: ((Int) -> Bool)? = nil) { self.activate = activate; self.adjust = adjust; self.vertical = vertical }
    }

    package init() {}

    @Published package var focused: String?
    @Published package private(set) var visible = false
    /// The scope the controller acts in: "main", or the open sheet's.
    package var scope = "main" {
        didSet {
            if scope != oldValue {
                awaitingFrame = nil
                if let index = parents.lastIndex(where: { $0.scope == scope }) {
                    focused = parents[index].focus.flatMap { id in frames[scope, default: []].contains { $0.id == id } ? id : nil }
                    parents.removeSubrange(index...)
                } else {
                    parents.append((oldValue, focused))
                    focused = nil
                }
            }
        }
    }
    private var parents: [(scope: String, focus: String?)] = []
    private var awaitingFrame: String?
    private(set) var frames: [String: [Target]] = [:]
    private var handlers: [String: Handlers] = [:]   // refreshed on every render of the target, so the closures see current state

    package func setFrames(_ targets: [Target], scope: String) {
        frames[scope] = targets
        if scope == self.scope, targets.contains(where: { $0.id == awaitingFrame }) { awaitingFrame = nil }
    }
    /// A lazy grid can scroll to its next tile before that tile reports its frame.
    package func focusAfterScroll(_ id: String) { focused = id; awaitingFrame = id }
    package func frame(of id: String) -> CGRect? { frames[scope]?.first { $0.id == id }?.frame }
    package func register(_ id: String, _ h: Handlers) { handlers[id] = h }

    /// Focus a target (a default when nothing is focused yet) and show the ring.
    package func show(default id: String?) {
        visible = true
        if focused != nil, focused == awaitingFrame { return }
        if focused == nil || !(frames[scope] ?? []).contains(where: { $0.id == focused }) {
            focused = id.flatMap { want in (frames[scope] ?? []).first { $0.id == want }?.id } ?? topLeft()
        }
    }

    package func hide() { visible = false }

    /// Left / right: the target's own value when it holds one, else a move.
    package func horizontal(_ step: Int) {
        if let id = focused, onScreen(id), let adjust = handlers[id]?.adjust { adjust(step) } else { move(dx: CGFloat(step), dy: 0) }
    }

    package func activate() { if let id = focused, onScreen(id) { handlers[id]?.activate?() } }

    /// Back belongs to the innermost question, without closing the sheet behind it.
    package func cancel() -> Bool {
        let id = scope + ".cancel"
        guard onScreen(id), let cancel = handlers[id]?.activate else { return false }
        cancel()
        return true
    }

    /// Handlers outlive their views, so a target that is no longer drawn (a card the library filter or the search hides) is
    /// recognised by its missing frame: A and left / right do nothing on it.
    private func onScreen(_ id: String) -> Bool { frames[scope, default: []].contains { $0.id == id } }

    /// The nearest target in the direction, scored by distance along it plus twice the distance across it. Left and right
    /// stay in the row (the target must overlap it vertically), so the last card does not jump to a button across the
    /// screen; up and down prefer a target in the same column and take the nearest otherwise (a card row up to the tabs).
    package func move(dx: CGFloat, dy: CGFloat) {
        if dy != 0, let id = focused, onScreen(id), handlers[id]?.vertical?(dy < 0 ? -1 : 1) == true { return }
        let all = frames[scope] ?? []
        guard let current = all.first(where: { $0.id == focused })?.frame else {
            if focused == nil || focused != awaitingFrame { focused = topLeft() }
            return
        }
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
    /// A control the controller can focus: A runs `activate`, left / right run `adjust` when given. An explicit radius describes a non-capsule control. Pass `enabled` for a control disabled before this modifier.
    package func padTarget(_ id: String, scope: String, radius: CGFloat? = nil, focusColor: Color? = nil, enabled: Bool = true, activate: (() -> Void)? = nil, adjust: ((Int) -> Void)? = nil, vertical: ((Int) -> Bool)? = nil) -> some View {
        modifier(PadTargetModifier(id: id, scope: scope, radius: radius, color: focusColor, enabled: enabled, handlers: .init(activate: activate, adjust: adjust, vertical: vertical)))
    }

    /// The root of a scope: collects its targets' frames for the focus.
    package func padScope(_ scope: String, _ focus: PadFocus) -> some View {
        coordinateSpace(name: "pad." + scope)
            .onPreferenceChange(PadTargetKey.self) { focus.setFrames($0, scope: scope) }
    }
}

/// Focus follows the control's edge. An explicit radius describes cards and rows, otherwise the control is a capsule.
package enum PadRingStyle { case outset, hug, none }
private struct PadRingStyleKey: EnvironmentKey { static let defaultValue = PadRingStyle.hug }
extension EnvironmentValues {
    package var padRingStyle: PadRingStyle {
        get { self[PadRingStyleKey.self] }
        set { self[PadRingStyleKey.self] = newValue }
    }
}

private struct PadTargetModifier: ViewModifier {
    let id: String, scope: String
    let radius: CGFloat?
    let color: Color?
    let enabled: Bool
    let handlers: PadFocus.Handlers
    @Environment(\.isEnabled) private var isEnabled
    @EnvironmentObject private var focus: PadFocus
    @Environment(\.padRingStyle) private var ringStyle

    func body(content: Content) -> some View {
        let active = enabled && isEnabled
        focus.register(id, active ? handlers : .init())
        let on = active && focus.visible && focus.focused == id
        return content
            .overlay {
                GeometryReader { bounds in
                Group {
                    if let radius {
                        RoundedRectangle(cornerRadius: radius).strokeBorder(color ?? LauncherPalette.focusRing, lineWidth: on && ringStyle != .none ? LauncherPalette.focusRingWidth : 0)
                    } else if abs(bounds.size.width - bounds.size.height) < 0.5 {
                        Circle().strokeBorder(color ?? LauncherPalette.focusRing, lineWidth: on && ringStyle != .none ? LauncherPalette.focusRingWidth : 0)
                    } else {
                        Capsule().strokeBorder(color ?? LauncherPalette.focusRing, lineWidth: on && ringStyle != .none ? LauncherPalette.focusRingWidth : 0)
                    }
                }
                .padding(ringStyle == .outset ? -4 : 0)
                }.allowsHitTesting(false)
            }
            .background(GeometryReader { g in
                Color.clear.preference(key: PadTargetKey.self, value: active ? [.init(id: id, frame: g.frame(in: .named("pad." + scope)))] : [])
            })
            .id(id)
    }
}
