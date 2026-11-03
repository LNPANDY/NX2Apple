import SwiftUI

/// Where the touch controls sit on an iPhone Pro Max held sideways (932 x 430 points, the side insets of the Dynamic Island and the home
/// indicator), for the preview in the settings. It mirrors the engine's `DmPadGeometry.h` (patch 0064) for that one screen, in the 3D
/// layout so every control shows: the same constants in u, the bottom corners halfway into the side insets, the left stick's place (patch
/// 0065). The engine stays the truth on the device, where a choice that does not fit a screen moves toward the built-in layout.
struct TouchPadPreviewGeometry: Equatable {
    static let screen = CGSize(width: 932, height: 430)
    static let insets = (left: 59.0, right: 59.0, bottom: 21.0)

    enum Shape: Equatable {
        case circle(CGPoint, CGFloat, label: String?)
        case drop(CGPoint, CGFloat, tipRight: Bool, label: String)
        case pill(CGRect, label: String)
        case dpad(CGPoint, CGFloat)
        case ring(CGPoint, CGFloat, knob: CGFloat)
    }

    /// DM_TOUCH_SIZE's scale: small 0.8, medium 1, large 1.2.
    static func scale(_ size: String) -> CGFloat { size == "small" ? 0.8 : size == "large" ? 1.2 : 1 }

    let u: CGFloat
    /// DM_TOUCH_STICK: corner, higher or inward.
    let place: String
    init(size: String, stick: String = "corner") { u = Self.scale(size); place = stick }

    private var safe: CGRect { CGRect(x: Self.insets.left, y: 0, width: Self.screen.width - Self.insets.left - Self.insets.right, height: Self.screen.height) }
    private var corner: CGRect {
        CGRect(x: Self.insets.left / 2, y: 0, width: Self.screen.width - (Self.insets.left + Self.insets.right) / 2, height: Self.screen.height - Self.insets.bottom)
    }
    private func side(_ r: CGRect, right: Bool, _ dx: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: right ? r.maxX - dx : r.minX + dx, y: y) }

    private var cornerStick: CGPoint { side(corner, right: false, 81 * u, corner.maxY - 82 * u) }
    /// How far the stick moves for its place: higher up to 70 u, until its ring would reach L's circle, inward 60 u (the engine
    /// shrinks either in 2 u steps until nothing overlaps; on this screen only higher meets something, L, at the large size).
    private var shift: CGVector {
        switch place {
        case "higher":
            let l = side(safe, right: false, 44 * u, 108 * u), r = 24 * u
            var d = 70 * u
            while d > 0 && hypot(cornerStick.x - l.x, cornerStick.y - d - l.y) < 77 * u + r { d -= 2 * u }
            return CGVector(dx: 0, dy: -max(d, 0))
        case "inward": return CGVector(dx: 60 * u, dy: 0)
        default: return .zero
        }
    }
    var stick: CGPoint { CGPoint(x: cornerStick.x + shift.dx, y: cornerStick.y + shift.dy) }
    var face: CGPoint { side(corner, right: true, 81 * u, corner.maxY - 82 * u) }
    /// The D-pad sits inward of the stick and moves with it when the stick moves inward.
    var dpad: CGPoint { side(corner, right: false, 231 * u + (place == "inward" ? shift.dx : 0), corner.maxY - 64 * u) }

    var shapes: [Shape] {
        var out: [Shape] = []
        let f = face, gap = 50 * u
        for (dx, dy, name) in [(gap, 0.0, "A"), (0, gap, "B"), (0, -gap, "X"), (-gap, 0, "Y")] {
            out.append(.circle(CGPoint(x: f.x + dx, y: f.y + dy), 27 * u, label: name))
        }
        out.append(.ring(stick, 77 * u, knob: 30 * u))
        out.append(.dpad(dpad, 48 * u))
        for right in [false, true] {
            out.append(.drop(side(safe, right: right, 44 * u, 40 * u), 26 * u, tipRight: right, label: right ? "ZR" : "ZL"))
            out.append(.drop(side(safe, right: right, 44 * u, 108 * u), 24 * u, tipRight: right, label: right ? "R" : "L"))
            out.append(.circle(side(safe, right: right, 102 * u, 40 * u), 17 * u, label: right ? "R3" : "L3"))
            let w = 50 * u, h = 28 * u, x = safe.midX + (right ? 52 : -52) * u
            out.append(.pill(CGRect(x: x - w / 2, y: 22 * u - h / 2, width: w, height: h), label: right ? "+" : "−"))
        }
        out.append(.circle(CGPoint(x: safe.midX, y: 22 * u), 15 * u, label: nil))
        return out
    }

    /// The bounding box of a shape, for the tests.
    static func bounds(_ shape: Shape) -> CGRect {
        switch shape {
        case .circle(let c, let r, _), .ring(let c, let r, _): CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        case .drop(let c, let r, _, _): CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        case .dpad(let c, let r): CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        case .pill(let rect, _): rect
        }
    }
}

/// The line under the preview: what the touch controls rows apply to.
struct TouchControlsNote: View {
    var body: some View {
        Text(ShellSettingsRows.touchNote).shellType(ShellType.note).foregroundStyle(.white.opacity(0.5))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A phone held sideways with the touch controls drawn as the game draws them: white keys of low opacity over a calm picture.
/// It is a picture, VoiceOver reads it as one element with its size, and the rows below it change it.
struct TouchControlsPreview: View {
    var size: String
    var stick = "corner"

    var body: some View {
        let geometry = TouchPadPreviewGeometry(size: size, stick: stick)
        let home = TouchPadPreviewGeometry(size: size).stick
        Canvas { context, canvas in
            let k = canvas.width / TouchPadPreviewGeometry.screen.width
            context.scaleBy(x: k, y: k)
            // A moved stick leaves a dashed cream outline where it sits by default, so the move reads at a glance.
            if geometry.stick != home {
                let r = 77 * geometry.u
                context.stroke(Path(ellipseIn: CGRect(x: home.x - r, y: home.y - r, width: 2 * r, height: 2 * r)),
                               with: .color(ShellPalette.cream.opacity(0.45)), style: StrokeStyle(lineWidth: 2, dash: [7, 6]))
            }
            for shape in geometry.shapes { draw(shape, in: &context) }
        }
        .aspectRatio(TouchPadPreviewGeometry.screen.width / TouchPadPreviewGeometry.screen.height, contentMode: .fit)
        .background(
            LinearGradient(colors: [Color(red: 0.20, green: 0.24, blue: 0.30), Color(red: 0.11, green: 0.13, blue: 0.12)], startPoint: .top, endPoint: .bottom)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 3))
        .animation(.smooth(duration: 0.2), value: size + stick)
        .accessibilityElement()
        .accessibilityLabel(ShellStrings.text("Preview of the touch controls"))
        .accessibilityIdentifier("touch.preview")
    }

    private static let fill = Color.white.opacity(0.14), line = Color.white.opacity(0.38), text = Color.white.opacity(0.6)

    private func draw(_ shape: TouchPadPreviewGeometry.Shape, in context: inout GraphicsContext) {
        func key(_ path: Path) { context.fill(path, with: .color(Self.fill)); context.stroke(path, with: .color(Self.line), lineWidth: 1.5) }
        func label(_ s: String, _ c: CGPoint, _ size: CGFloat) {
            context.draw(Text(s).font(.system(size: size, weight: .semibold)).foregroundStyle(Self.text), at: c)
        }
        switch shape {
        case .circle(let c, let r, let name):
            key(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)))
            if let name { label(name, c, r * 0.75) }
        case .ring(let c, let r, let knob):
            let ring = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            context.fill(ring, with: .color(.white.opacity(0.06))); context.stroke(ring, with: .color(Self.line), lineWidth: 1.5)
            key(Path(ellipseIn: CGRect(x: c.x - knob, y: c.y - knob, width: 2 * knob, height: 2 * knob)))
        case .drop(let c, let r, let right, let name):
            let angle = right ? -Double.pi / 4 : -3 * Double.pi / 4, d = r * 1.45, th = acos(r / d)
            var p = Path()
            p.move(to: CGPoint(x: c.x + d * cos(angle), y: c.y + d * sin(angle)))
            p.addArc(center: c, radius: r, startAngle: .radians(angle + th), endAngle: .radians(angle - th + 2 * .pi), clockwise: false)
            p.closeSubpath()
            key(p)
            label(name, c, r * 0.62)
        case .pill(let rect, let name):
            key(Path(roundedRect: rect, cornerRadius: rect.height / 2))
            label(name, CGPoint(x: rect.midX, y: rect.midY), rect.height * 0.64)
        case .dpad(let c, let r):
            let w = r * 17 / 48, inner = r * 11 / 48
            for turn in 0..<4 {
                var p = Path()
                p.addLines([CGPoint(x: -w, y: -r), CGPoint(x: w, y: -r), CGPoint(x: w, y: -(inner + w)), CGPoint(x: 0, y: -inner), CGPoint(x: -w, y: -(inner + w))])
                p.closeSubpath()
                key(p.applying(CGAffineTransform(rotationAngle: CGFloat(turn) * .pi / 2).concatenating(CGAffineTransform(translationX: c.x, y: c.y))))
            }
        }
    }
}
