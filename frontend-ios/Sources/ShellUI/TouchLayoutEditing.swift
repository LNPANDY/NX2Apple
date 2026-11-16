import CoreGraphics
import Foundation

/// The layout editor's rules, pure so the tests drive them (#414): one layout of the player's arrangement on one screen. A move is
/// kept only when the engine places the control there (`PadGeo`, the copy of `DmPadGeometry.h`) and every other control stays where it
/// was, so what the editor shows is what the game draws, and a rejected spot leaves the layout as it was. The groups a game's layout
/// editor placed and sized (`TouchGroups`) are drawn as the game draws them and kept as they are: a single move goes along with its
/// group, and one that would send a group back to its built-in place or change its size is refused.
struct TouchLayoutEditing: Equatable {
    typealias Control = TouchLayout.Control
    typealias Offset = TouchLayout.Offset

    var layout: TouchLayout
    var kind: TouchLayout.Kind
    /// The screen of this layout: the device held sideways for 2D and 3D, held upright for the split ones.
    var screen: PadScreen
    var size = "medium"
    var stick = "corner"
    /// A B X Y move as one diamond. Off, each key moves on its own (the engine keeps the diamond for a key that does not fit).
    var together = true
    /// Every game's groups (DM_TOUCH_GROUPS), which the game's own editor sets: shown and kept, reset with the layout.
    var groups = TouchGroups()

    func geometry(_ l: TouchLayout) -> PadGeo { PadGeo.make(screen, full: kind.full, size: size, stick: stick, layout: l, groups: groups) }
    var geo: PadGeo { geometry(layout) }

    /// The control a touch on `c` moves: the whole diamond while its keys move together.
    func mover(_ c: Control) -> Control { together && c.isFaceKey ? .face : c }
    func offset(_ c: Control) -> Offset { layout[kind, c] }
    /// Away from its built-in place: a key also when the diamond moved.
    func isMoved(_ c: Control) -> Bool { !offset(c).isZero || (c.isFaceKey && !offset(.face).isZero) || (c == .face && Control.allCases.contains { $0.isFaceKey && !offset($0).isZero }) }

    /// The controls whose place a move of `c` may change: `c` itself, and the four keys when the diamond moves.
    private func follows(_ other: Control, _ c: Control) -> Bool { other == c || (c == .face && other.isFaceKey) }

    /// The arrangement with `c` at `o`, when the engine puts it there and leaves every other control where it is. nil: rejected.
    func trying(_ c: Control, _ o: Offset) -> TouchLayout? {
        var l = layout
        l[kind, c] = o
        let before = geo, after = geometry(l)
        if !o.isZero && !after.moved.contains(c) { return nil }
        // No other control may lose its place, a key of the diamond included, and no group its place or its size.
        if !after.dropped.subtracting(before.dropped).isEmpty { return nil }
        if !after.groupDropped.subtracting(before.groupDropped).isEmpty || after.gs != before.gs { return nil }
        for other in Control.allCases where other.drawn(full: kind.full) && !follows(other, c) {
            if !Self.same(before.anchor(other), after.anchor(other)) { return nil }
        }
        return normalized(l, c)
    }
    static func same(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x - b.x) < 0.01 && abs(a.y - b.y) < 0.01 }

    /// A control dragged past the edge stops at the edge (the engine pushes it back in). Its offset is then kept one step past the
    /// edge at most, so the first step back moves it.
    private func normalized(_ l: TouchLayout, _ c: Control) -> TouchLayout {
        let g = geometry(l), o = l[kind, c]
        var zero = l; zero[kind, c] = .zero
        let base = geometry(zero).anchor(c), at = g.anchor(c), step = g.screenStep(c)
        func axis(_ want: Int, _ b: CGFloat, _ a: CGFloat) -> Int {
            let target = b + CGFloat(want) * step
            if abs(target - a) < 0.01 { return want }
            let q = (a - b) / step
            return target > a ? Int(ceil(q - 1e-6)) : Int(floor(q + 1e-6))
        }
        let n = Offset(dx: axis(o.dx, base.x, at.x), dy: axis(o.dy, base.y, at.y))
        guard n != o else { return l }
        var m = l
        m[kind, c] = n
        let mg = geometry(m)
        return Control.allCases.allSatisfy { Self.same(mg.anchor($0), g.anchor($0)) } && mg.dropped == g.dropped ? m : l
    }

    /// The offset a drag of `c` by `translation` (in the screen's points) from `start` asks for, snapped to whole steps (a step of a
    /// control in a resized group is as much larger or smaller on the screen).
    func dragged(_ c: Control, from start: Offset, by translation: CGSize) -> Offset {
        let step = geo.screenStep(mover(c))
        return Offset(dx: start.dx + Int((translation.width / step).rounded()), dy: start.dy + Int((translation.height / step).rounded()))
    }

    enum Outcome: Equatable { case moved, atEdge, rejected }
    /// One step of `c` in a direction, from the arrows, a controller or VoiceOver.
    mutating func nudge(_ c: Control, dx: Int, dy: Int) -> Outcome {
        let m = mover(c)
        var o = offset(m)
        o.dx += dx; o.dy += dy
        guard let l = trying(m, o) else { return .rejected }
        if Self.same(geometry(l).anchor(m), geo.anchor(m)) { return .atEdge }
        layout = l
        return .moved
    }
    /// A drag's spot: kept when the engine takes it.
    mutating func place(_ c: Control, _ o: Offset) -> Bool {
        let m = mover(c)
        if o == offset(m) { return true }
        guard let l = trying(m, o) else { return false }
        layout = l
        return true
    }

    /// `c` back to its built-in place (with the diamond: its keys too). A control another one now covers that place for goes back as well,
    /// and offsets the engine does not use on this screen are dropped, so the stored value says what the game shows.
    mutating func putBack(_ c: Control) {
        let m = mover(c)
        layout[kind, m] = .zero
        if m == .face { for k in Control.allCases where k.isFaceKey { layout[kind, k] = .zero } }
        prune()
    }
    /// Every control of this layout back to its built-in place, its groups too (as the game editor's Reset to default does).
    mutating func reset() { layout.reset(kind); groups.reset(kind) }

    /// Forgets the offsets of controls the engine keeps at their place on this screen.
    mutating func prune() {
        let g = geo
        for c in g.dropped { layout[kind, c] = .zero }
    }

    /// Where control `c` may go: the safe area, or for the bottom corners the area reaching halfway into the side insets.
    func allowedArea(_ c: Control) -> CGRect? { geo.box(of: mover(c) == .face ? .face : c)?.within }

    /// The drawn control at a point of the screen, the nearest within `slop` points of its shape.
    func control(at p: CGPoint, slop: CGFloat) -> Control? {
        let g = geo
        var best: (Control, CGFloat)?
        for c in g.drawnControls {
            guard let (box, _) = g.box(of: c) else { continue }
            let grown = box.insetBy(dx: -slop, dy: -slop)
            guard grown.contains(p) else { continue }
            let d = hypot(p.x - g.anchor(c).x, p.y - g.anchor(c).y)
            if best == nil || d < best!.1 { best = (c, d) }
        }
        return best?.0
    }
}
