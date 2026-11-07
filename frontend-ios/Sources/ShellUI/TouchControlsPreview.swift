import SwiftUI
import CoreGraphics

/// Where the touch controls sit on an iPhone Pro Max held sideways (932 x 430 points, the side insets of the Dynamic Island and the home
/// indicator), for the preview in the settings, in the 3D layout so every control shows. It is the engine's geometry for that screen
/// (`PadGeo`, the Swift copy of `DmPadGeometry.h`): the size, the left stick's place and the player's 3D arrangement. The engine stays the
/// truth on the device, where a choice that does not fit a screen moves toward the built-in layout.
struct TouchPadPreviewGeometry: Equatable {
    static let screen = PadScreen.proMax.size

    enum Shape: Equatable {
        case circle(CGPoint, CGFloat, label: String?)
        case drop(CGPoint, CGFloat, tipRight: Bool, label: String)
        case pill(CGRect, label: String)
        case dpad(CGPoint, CGFloat)
        case ring(CGPoint, CGFloat, knob: CGFloat)
    }

    /// DM_TOUCH_SIZE's scale: small 0.8, medium 1, large 1.2.
    static func scale(_ size: String) -> CGFloat { PadGeo.scale(size) }

    let geo: PadGeo
    var u: CGFloat { geo.u }
    init(size: String, stick: String = "corner", layout: TouchLayout = TouchLayout()) {
        geo = PadGeo.make(.proMax, full: true, size: size, stick: stick, layout: layout)
    }

    var stick: CGPoint { geo.stick }
    var face: CGPoint { geo.face }
    var dpad: CGPoint { geo.dpad }

    var shapes: [Shape] { Self.shapes(geo) }

    /// The drawn controls of a geometry, as the gamepad draws them.
    static func shapes(_ g: PadGeo) -> [Shape] {
        var out: [Shape] = []
        for (i, name) in ["A", "B", "X", "Y"].enumerated() { out.append(.circle(g.faceKey[i], g.faceR, label: name)) }
        out.append(.ring(g.stick, g.stickR, knob: g.knobR))
        if g.full { out.append(.dpad(g.dpad, g.dpadR)) }
        for (i, name) in ["ZL", "L", "ZR", "R"].enumerated() { out.append(.drop(g.drop[i], g.dropR[i], tipRight: i >= 2, label: name)) }
        if g.full { for (i, name) in ["L3", "R3"].enumerated() { out.append(.circle(g.click[i], g.clickR, label: name)) } }
        for (i, name) in ["−", "+"].enumerated() { out.append(.pill(g.pill[i], label: name)) }
        out.append(.circle(g.swap, g.swapR, label: nil))
        return out
    }

    /// The bounding box of a shape, for the tests.
    static func bounds(_ shape: Shape) -> CGRect {
        switch shape {
        case .circle(let c, let r, _), .ring(let c, let r, _): CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        case .drop, .dpad: PadDrawing.outline(shape).boundingRect
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
    var layout = TouchLayout()

    var body: some View {
        let geometry = TouchPadPreviewGeometry(size: size, stick: stick, layout: layout)
        let home = TouchPadPreviewGeometry(size: size).stick
        Canvas { context, canvas in
            let k = canvas.width / TouchPadPreviewGeometry.screen.width
            context.scaleBy(x: k, y: k)
            // A moved stick leaves a dashed cream outline where it sits by default, so the move reads at a glance.
            if geometry.stick != home {
                let r = geometry.geo.stickR
                context.stroke(Path(ellipseIn: CGRect(x: home.x - r, y: home.y - r, width: 2 * r, height: 2 * r)),
                               with: .color(ShellPalette.cream.opacity(0.45)), style: StrokeStyle(lineWidth: 2, dash: [7, 6]))
            }
            for shape in geometry.shapes { PadDrawing.draw(shape, in: &context) }
        }
        .aspectRatio(TouchPadPreviewGeometry.screen.width / TouchPadPreviewGeometry.screen.height, contentMode: .fit)
        .background(PadDrawing.backdrop)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 3))
        .animation(.smooth(duration: 0.2), value: size + stick + layout.encoded)
        .accessibilityElement()
        .accessibilityLabel(ShellStrings.text("Preview of the touch controls"))
        .accessibilityIdentifier("touch.preview")
    }
}

/// How the gamepad's controls look, for the previews: white keys of low opacity, a thin line, the labels.
enum PadDrawing {
    struct Style {
        var fill = Color.white.opacity(0.14), line = Color.white.opacity(0.38), text = Color.white.opacity(0.6), ring = Color.white.opacity(0.06)
        var lineWidth: CGFloat = 1.5
    }
    static let backdrop = LinearGradient(colors: [Color(red: 0.20, green: 0.24, blue: 0.30), Color(red: 0.11, green: 0.13, blue: 0.12)],
                                         startPoint: .top, endPoint: .bottom)

    /// The outline of a shape, for a highlight or the dashed place it came from.
    static func outline(_ shape: TouchPadPreviewGeometry.Shape) -> Path {
        switch shape {
        case .circle(let c, let r, _), .ring(let c, let r, _): Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        case .drop(let c, let r, let right, let name): dropPath(c, r, right, round: dropRound(r, name))
        case .pill(let rect, _): Path(roundedRect: rect, cornerRadius: rect.height / 2)
        case .dpad(let c, let r): dpadPath(c, r)
        }
    }

    private static func dropRound(_ r: CGFloat, _ name: String) -> CGFloat {
        r * 4 / (name == "ZL" || name == "ZR" ? 26 : 24)
    }

    /// DmGamepad's tangent-rounded teardrop. The radius is 4*u in the engine.
    static func dropPath(_ c: CGPoint, _ r: CGFloat, _ right: Bool, round: CGFloat) -> Path {
        let angle: CGFloat = right ? -.pi / 4 : -3 * .pi / 4
        let d = r * 1.45, th = acos(r / d)
        let tip = CGPoint(x: c.x + d * cos(angle), y: c.y + d * sin(angle))
        let p1 = CGPoint(x: c.x + r * cos(angle + th), y: c.y + r * sin(angle + th))
        let p2 = CGPoint(x: c.x + r * cos(angle - th), y: c.y + r * sin(angle - th))
        let path = CGMutablePath()
        path.move(to: p2)
        path.addArc(tangent1End: tip, tangent2End: p1, radius: round)
        path.addArc(center: c, radius: r, startAngle: angle + th, endAngle: angle - th + 2 * .pi, clockwise: false)
        path.closeSubpath()
        return Path(path)
    }

    static func dpadPath(_ c: CGPoint, _ r: CGFloat) -> Path {
        let w = r * 17 / 48, inner = r * 11 / 48, round = r / 8 // 6*u, where the engine's D-pad radius is 48*u
        let path = CGMutablePath()
        for turn in 0..<4 {
            let angle = CGFloat(turn) * .pi / 2, cs = cos(angle), sn = sin(angle)
            let local: [CGPoint] = [CGPoint(x: -w, y: -r), CGPoint(x: w, y: -r), CGPoint(x: w, y: -(inner + w)), CGPoint(x: 0, y: -inner), CGPoint(x: -w, y: -(inner + w))]
            let v = local.map { CGPoint(x: c.x + $0.x * cs - $0.y * sn, y: c.y + $0.x * sn + $0.y * cs) }
            path.move(to: CGPoint(x: (v[4].x + v[0].x) / 2, y: (v[4].y + v[0].y) / 2))
            for i in 0..<5 { path.addArc(tangent1End: v[i], tangent2End: v[(i + 1) % 5], radius: round) }
            path.closeSubpath()
        }
        return Path(path)
    }

    static func draw(_ shape: TouchPadPreviewGeometry.Shape, in context: inout GraphicsContext, style: Style = Style()) {
        func key(_ path: Path) { context.fill(path, with: .color(style.fill)); context.stroke(path, with: .color(style.line), lineWidth: style.lineWidth) }
        func label(_ s: String, _ c: CGPoint, _ size: CGFloat) {
            context.draw(Text(verbatim: s).font(.system(size: size, weight: .semibold)).foregroundStyle(style.text), at: c)
        }
        switch shape {
        case .circle(let c, let r, let name):
            key(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)))
            if let name { label(name, c, r * 0.75) }
        case .ring(let c, let r, let knob):
            let ring = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            context.fill(ring, with: .color(style.ring)); context.stroke(ring, with: .color(style.line), lineWidth: style.lineWidth)
            key(Path(ellipseIn: CGRect(x: c.x - knob, y: c.y - knob, width: 2 * knob, height: 2 * knob)))
        case .drop(let c, let r, let right, let name):
            key(dropPath(c, r, right, round: dropRound(r, name)))
            label(name, c, r * 0.62)
        case .pill(let rect, let name):
            key(Path(roundedRect: rect, cornerRadius: rect.height / 2))
            label(name, CGPoint(x: rect.midX, y: rect.midY), rect.height * 0.64)
        case .dpad(let c, let r):
            key(dpadPath(c, r))
        }
    }
}

