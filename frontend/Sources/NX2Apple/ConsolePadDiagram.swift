import SwiftUI
import NXLauncher

/// The controller drawing of the iPhone app's mapping card (frontend-ios XboxControllerDiagram), for console mode: an Xbox-shaped
/// controller in outline, drawn in a 320 × 220 design space and scaled to fit, each button carrying the Switch name of its place
/// (the host maps every controller by position: the right face button is A, the bottom one B). It never shows what a controller
/// presses: in console mode the controller moves the focus. `highlighted` fills one button in cream (the row the focus is on, or the
/// button whose choices are open), `marked` rings the buttons the mapping changed, and a click on a button calls `tap` with its name.
struct ConsolePadDiagram: View {
    /// Switch names (DM_PAD_MAP's) of the buttons drawn with a cream ring.
    var marked: Set<String> = []
    var highlighted: String?
    var tap: ((String) -> Void)?
    static let design = CGSize(width: 320, height: 220)
    static var aspect: CGFloat { design.width / design.height }

    /// Where each mappable button sits in the design space and how large it is, shared by the drawing, the rings and the click
    /// test. The shoulders' frames are their outlines' bounds (`shoulder`).
    static func frame(_ button: String) -> (center: CGPoint, size: CGSize)? {
        if let outline = shoulder(button) {
            let r = outline.boundingRect
            return (CGPoint(x: r.midX, y: r.midY), r.size)
        }
        switch button {
        case "LS": return (CGPoint(x: 88, y: 92), CGSize(width: 46, height: 46))
        case "RS": return (CGPoint(x: 202, y: 140), CGSize(width: 46, height: 46))
        case "Up": return (CGPoint(x: 118, y: 128), CGSize(width: 12, height: 12))
        case "Down": return (CGPoint(x: 118, y: 152), CGSize(width: 12, height: 12))
        case "Left": return (CGPoint(x: 106, y: 140), CGSize(width: 12, height: 12))
        case "Right": return (CGPoint(x: 130, y: 140), CGSize(width: 12, height: 12))
        case "X": return (CGPoint(x: 240, y: 70), CGSize(width: 20, height: 20))
        case "Y": return (CGPoint(x: 219, y: 92), CGSize(width: 20, height: 20))
        case "A": return (CGPoint(x: 261, y: 92), CGSize(width: 20, height: 20))
        case "B": return (CGPoint(x: 240, y: 114), CGSize(width: 20, height: 20))
        case "Minus": return (CGPoint(x: 138, y: 92), CGSize(width: 14, height: 14))
        case "Plus": return (CGPoint(x: 182, y: 92), CGSize(width: 14, height: 14))
        default: return nil
        }
    }

    // MARK: The shoulders

    /// A bumper's spine along the body's upper corner and top edge, a little outside them, so the slab drawn round it overhangs
    /// the body as a real bumper does. The left side, the right one mirrors it.
    private static let bumperStart = CGPoint(x: 40, y: 55), bumperControl = CGPoint(x: 58, y: 35), bumperEnd = CGPoint(x: 116, y: 41)
    private static let bumperThickness: CGFloat = 13
    /// A trigger: a paddle above and behind the bumper's outer half, tilted out. The left side.
    private static let triggerCenter = CGPoint(x: 64, y: 14)
    private static let triggerSize = CGSize(width: 34, height: 22)
    private static let triggerTilt: CGFloat = -10

    private static func isRight(_ button: String) -> Bool { button == "R" || button == "ZR" }
    private static func mirrored(_ p: CGPoint, _ right: Bool) -> CGPoint { right ? CGPoint(x: design.width - p.x, y: p.y) : p }

    /// A shoulder button's outline in the design space, `grow` points wider all round (for the ring and the click test), nil for
    /// every other button.
    static func shoulder(_ button: String, grow: CGFloat = 0) -> Path? {
        let right = isRight(button)
        switch button {
        case "L", "R":
            var spine = Path()
            spine.move(to: mirrored(bumperStart, right))
            spine.addQuadCurve(to: mirrored(bumperEnd, right), control: mirrored(bumperControl, right))
            return spine.strokedPath(StrokeStyle(lineWidth: bumperThickness + 2 * grow, lineCap: .round))
        case "ZL", "ZR":
            let size = CGSize(width: triggerSize.width + 2 * grow, height: triggerSize.height + 2 * grow)
            let paddle = RoundedRectangle(cornerRadius: 8 + grow, style: .continuous)
                .path(in: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
            let center = mirrored(triggerCenter, right)
            return paddle.applying(CGAffineTransform(rotationAngle: (right ? -triggerTilt : triggerTilt) * .pi / 180)
                .concatenating(CGAffineTransform(translationX: center.x, y: center.y)))
        default:
            return nil
        }
    }

    /// Where a shoulder's name sits and how it turns: on the bumper's spine, following its slope, in the trigger's middle.
    private static func shoulderLabel(_ button: String) -> (point: CGPoint, angle: CGFloat) {
        let right = isRight(button)
        if button == "ZL" || button == "ZR" { return (mirrored(triggerCenter, right), right ? -triggerTilt : triggerTilt) }
        let t: CGFloat = 0.55
        let a = bumperStart, c = bumperControl, b = bumperEnd
        let p = CGPoint(x: (1 - t) * (1 - t) * a.x + 2 * t * (1 - t) * c.x + t * t * b.x,
                        y: (1 - t) * (1 - t) * a.y + 2 * t * (1 - t) * c.y + t * t * b.y)
        let dx = 2 * (1 - t) * (c.x - a.x) + 2 * t * (b.x - c.x), dy = 2 * (1 - t) * (c.y - a.y) + 2 * t * (b.y - c.y)
        let angle = atan2(dy, dx) * 180 / .pi
        return (mirrored(p, right), right ? -angle : angle)
    }

    /// The mappable button nearest a point of the design space, within a pointer's reach (nil for the body or the Home button).
    static func nearest(to point: CGPoint) -> String? {
        let distances = ConsolePadLayout.buttons.compactMap { button -> (String, CGFloat)? in
            if shoulder(button) != nil {
                let reach = stride(from: 0, through: 20, by: 2).first { shoulder(button, grow: CGFloat($0))?.contains(point) == true }
                return (button, reach.map(CGFloat.init) ?? .infinity)
            }
            guard let f = frame(button) else { return nil }
            let dx = max(0, abs(point.x - f.center.x) - f.size.width / 2), dy = max(0, abs(point.y - f.center.y) - f.size.height / 2)
            return (button, hypot(dx, dy))
        }
        guard let best = distances.min(by: { $0.1 < $1.1 }), best.1 <= 18 else { return nil }
        return best.0
    }

    var body: some View {
        GeometryReader { geometry in
            let s = min(geometry.size.width / Self.design.width, geometry.size.height / Self.design.height)
            ZStack(alignment: .topLeading) {
                drawing(s: s)
                ForEach(ConsolePadLayout.buttons.filter(marked.contains), id: \.self) { ring($0, s: s) }
            }
            .frame(width: Self.design.width * s, height: Self.design.height * s)
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { point in
                guard let tap, let button = Self.nearest(to: CGPoint(x: point.x / s, y: point.y / s)) else { return }
                tap(button)
            }
            .allowsHitTesting(tap != nil)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeOut(duration: 0.15), value: highlighted)
        }
        .aspectRatio(Self.aspect, contentMode: .fit)
        .accessibilityHidden(true)   // the rows say the same, and a controller moves through them
    }

    private func lit(_ button: String) -> Bool { highlighted == button }

    /// A cream ring around a button the mapping changed, in the button's own shape.
    @ViewBuilder private func ring(_ button: String, s: CGFloat) -> some View {
        let line = max(1.5, 2 * s)
        if let outline = Self.shoulder(button, grow: 3.5) {
            DesignShape(path: outline).stroke(LauncherPalette.cream, lineWidth: line)
                .frame(width: Self.design.width * s, height: Self.design.height * s)
        } else if let f = Self.frame(button) {
            let size = CGSize(width: f.size.width + 7, height: f.size.height + 7)
            if ["Up", "Down", "Left", "Right"].contains(button) {
                place(RoundedRectangle(cornerRadius: 6 * s).stroke(LauncherPalette.cream, lineWidth: line), center: f.center, size: size, s: s)
            } else {
                place(Circle().stroke(LauncherPalette.cream, lineWidth: line), center: f.center, size: size, s: s)
            }
        }
    }

    @ViewBuilder private func drawing(s: CGFloat) -> some View {
        // Back to front: the triggers behind, the body, the bumpers over the body's edge.
        shoulderView("ZL", s: s, font: 10.5)
        shoulderView("ZR", s: s, font: 10.5)
        ControllerBody()
            .fill(Color(red: 0.11, green: 0.11, blue: 0.12))
            .overlay(ControllerBody().stroke(Color.white.opacity(0.35), lineWidth: max(1, 1.6 * s)))
            .frame(width: Self.design.width * s, height: Self.design.height * s)
        shoulderView("L", s: s, font: 9.5)
        shoulderView("R", s: s, font: 9.5)
        stick("LS", s: s)
        stick("RS", s: s)
        dpad(s: s)
        ForEach(["X", "Y", "A", "B"], id: \.self) { face($0, s: s) }
        small("Minus", symbol: "minus", s: s)
        small("Plus", symbol: "plus", s: s)
        home(at: CGPoint(x: 160, y: 60), s: s)
    }
    private static let neutral = Color(white: 0.82)
    /// A shoulder at rest: opaque, a step lighter than the body, so a bumper reads in front of the body's edge.
    private static let shoulderIdle = Color(red: 0.17, green: 0.17, blue: 0.18)

    private func place(_ view: some View, center: CGPoint, size: CGSize, s: CGFloat) -> some View {
        view.frame(width: size.width * s, height: size.height * s).position(x: center.x * s, y: center.y * s)
    }

    private func shoulderView(_ button: String, s: CGFloat, font: CGFloat) -> some View {
        let on = lit(button)
        let outline = DesignShape(path: Self.shoulder(button) ?? Path())
        let name = Self.shoulderLabel(button)
        return ZStack(alignment: .topLeading) {
            outline.fill(on ? LauncherPalette.cream : Self.shoulderIdle)
            outline.stroke(Color.white.opacity(on ? 0.9 : 0.4), lineWidth: max(1, 1.4 * s))
            Text(verbatim: button).font(.manrope(font * s, .heavy)).foregroundStyle(on ? LauncherPalette.background : .white.opacity(0.75))
                .rotationEffect(.degrees(name.angle))
                .position(x: name.point.x * s, y: name.point.y * s)
        }
        .frame(width: Self.design.width * s, height: Self.design.height * s)
        .shadow(color: on ? LauncherPalette.cream.opacity(0.55) : .clear, radius: 8 * s)
    }

    private func stick(_ button: String, s: CGFloat) -> some View {
        let on = lit(button)
        let c = Self.frame(button)?.center ?? .zero
        return ZStack {
            place(Circle().fill(Color.black.opacity(0.35)).overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: max(1, s))),
                  center: c, size: CGSize(width: 46, height: 46), s: s)
            place(Circle().fill(on ? LauncherPalette.cream : Color(white: 0.26))
                    .overlay(Circle().stroke(Color.white.opacity(on ? 0.9 : 0.4), lineWidth: max(1, 1.4 * s)))
                    .overlay(Text(verbatim: button).font(.manrope(8.5 * s, .heavy)).foregroundStyle(on ? LauncherPalette.background : .white.opacity(0.6)))
                    .shadow(color: on ? LauncherPalette.cream.opacity(0.55) : .clear, radius: 8 * s),
                  center: c, size: CGSize(width: 30, height: 30), s: s)
        }
    }

    private func dpad(s: CGFloat) -> some View {
        let c = CGPoint(x: 118, y: 140)
        let arms: [(String, CGFloat, CGFloat)] = [("Up", 0, -12), ("Down", 0, 12), ("Left", -12, 0), ("Right", 12, 0)]
        return ZStack {
            place(RoundedRectangle(cornerRadius: 3 * s).fill(Color.white.opacity(0.10)), center: c, size: CGSize(width: 12, height: 12), s: s)
            ForEach(arms, id: \.0) { button, dx, dy in
                place(RoundedRectangle(cornerRadius: 3 * s).fill(lit(button) ? LauncherPalette.cream : Color.white.opacity(0.10))
                        .overlay(RoundedRectangle(cornerRadius: 3 * s).stroke(Color.white.opacity(lit(button) ? 0.9 : 0.35), lineWidth: max(1, s)))
                        .shadow(color: lit(button) ? LauncherPalette.cream.opacity(0.55) : .clear, radius: 6 * s),
                      center: CGPoint(x: c.x + dx, y: c.y + dy), size: CGSize(width: 12, height: 12), s: s)
            }
        }
    }

    private func face(_ button: String, s: CGFloat) -> some View {
        let on = lit(button)
        return place(
            ZStack {
                Circle().fill(on ? LauncherPalette.cream : Color.black.opacity(0.35))
                Circle().stroke(on ? Color.white.opacity(0.9) : Self.neutral.opacity(0.8), lineWidth: max(1, 1.5 * s))
                Text(verbatim: button).font(.manrope(11 * s, .heavy)).foregroundStyle(on ? LauncherPalette.background : Self.neutral)
            }
            .shadow(color: on ? LauncherPalette.cream.opacity(0.6) : .clear, radius: 8 * s),
            center: Self.frame(button)?.center ?? .zero, size: CGSize(width: 20, height: 20), s: s)
    }

    private func small(_ button: String, symbol: String, s: CGFloat) -> some View {
        let on = lit(button)
        return place(
            ZStack {
                Circle().fill(on ? LauncherPalette.cream : Color.black.opacity(0.35))
                Circle().stroke(Color.white.opacity(on ? 0.9 : 0.35), lineWidth: max(1, s))
                Image(systemName: symbol).font(.system(size: 6 * s, weight: .bold)).foregroundStyle(on ? LauncherPalette.background : .white.opacity(0.7))
            }
            .shadow(color: on ? LauncherPalette.cream.opacity(0.6) : .clear, radius: 8 * s),
            center: Self.frame(button)?.center ?? .zero, size: CGSize(width: 14, height: 14), s: s)
    }

    /// The Home button: drawn for the shape, never mapped (no game sees it).
    private func home(at c: CGPoint, s: CGFloat) -> some View {
        place(
            ZStack {
                Circle().fill(Color.black.opacity(0.35))
                Circle().stroke(Color.white.opacity(0.45), lineWidth: max(1, 1.4 * s))
                Image(systemName: "house.fill").font(.system(size: 8 * s, weight: .heavy)).foregroundStyle(.white.opacity(0.6))
            },
            center: c, size: CGSize(width: 22, height: 22), s: s)
    }
}

/// A path of the drawing's design space, scaled to the rect it is drawn in (the whole drawing).
private struct DesignShape: Shape {
    let path: Path
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / ConsolePadDiagram.design.width, sy = rect.height / ConsolePadDiagram.design.height
        return path.applying(CGAffineTransform(scaleX: sx, y: sy).concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}

/// The outline of the controller: a broad top, the two grips curving down and in, a shallow bottom between them.
private struct ControllerBody: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / ConsolePadDiagram.design.width, sy = rect.height / ConsolePadDiagram.design.height
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy) }
        var path = Path()
        path.move(to: p(160, 46))
        path.addCurve(to: p(262, 44), control1: p(200, 46), control2: p(236, 36))
        path.addCurve(to: p(310, 150), control1: p(292, 54), control2: p(304, 100))
        path.addCurve(to: p(268, 212), control1: p(318, 196), control2: p(296, 220))
        path.addCurve(to: p(214, 168), control1: p(244, 206), control2: p(232, 172))
        path.addCurve(to: p(160, 162), control1: p(196, 164), control2: p(178, 162))
        path.addCurve(to: p(106, 168), control1: p(142, 162), control2: p(124, 164))
        path.addCurve(to: p(52, 212), control1: p(88, 172), control2: p(76, 206))
        path.addCurve(to: p(10, 150), control1: p(24, 220), control2: p(2, 196))
        path.addCurve(to: p(58, 44), control1: p(16, 100), control2: p(28, 54))
        path.addCurve(to: p(160, 46), control1: p(84, 36), control2: p(120, 46))
        path.closeSubpath()
        return path
    }
}
