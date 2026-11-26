import SwiftUI

extension TouchLayoutEditorView {
    enum Highlight { case none, chosen, refused }

    /// Where the active control is drawn beyond its kept place: under the finger on a refused spot, or on its way back.
    func activeOffset(_ g: PadGeo) -> CGSize {
        if let drag, let refused = drag.refused {
            let kept = model.dragOffset(drag.control)
            return CGSize(width: CGFloat(refused.dx - kept.dx) * g.step + bounce.width,
                          height: CGFloat(refused.dy - kept.dy) * g.step + bounce.height)
        }
        return bounce
    }

    /// The active control and the controls that move with it: the diamond's keys while they move together.
    func isActive(_ c: TouchLayout.Control, _ active: TouchLayout.Control?) -> Bool {
        guard let active else { return false }
        return model.editing.mover(c) == model.editing.mover(active)
    }

    func drawBackdrop(_ g: PadGeo, in context: inout GraphicsContext) {
        // In portrait split, render both the fixed 4:3 picture slot (gameClip) and the fitted 16:9 game picture inside it
        // so editor spacing matches the runtime 4:3 frame and fixed lower control area.
        if g.region.separated {
            let slot = g.region.gameClip
            let picture = g.region.game
            if !slot.isEmpty {
                context.fill(Path(roundedRect: slot, cornerRadius: 10), with: .color(.white.opacity(0.045)))
                context.stroke(Path(roundedRect: slot, cornerRadius: 10),
                               with: .color(ShellPalette.cream.opacity(0.22)),
                               style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            }
            if !picture.isEmpty {
                context.fill(Path(roundedRect: picture, cornerRadius: 8), with: .color(.white.opacity(0.08)))
            }
            context.fill(Path(g.region.controls), with: .color(.black.opacity(0.20)))
            let y = g.region.controls.minY
            var divider = Path()
            divider.move(to: CGPoint(x: 0, y: y))
            divider.addLine(to: CGPoint(x: screen.size.width, y: y))
            context.stroke(divider, with: .color(.white.opacity(0.16)), lineWidth: 1)
        } else {
            let picture = g.region.game.intersection(CGRect(origin: .zero, size: screen.size))
            context.fill(Path(roundedRect: picture, cornerRadius: 10), with: .color(.white.opacity(0.03)))
        }
    }

    func drawGuides(for active: TouchLayout.Control, _ g: PadGeo, k: CGFloat, in context: inout GraphicsContext) {
        let m = model.editing.mover(active)
        // The area it may use: a calm cream tint with a dashed edge.
        if let area = model.editing.allowedArea(active) {
            let path = Path(roundedRect: area.insetBy(dx: 1, dy: 1), cornerRadius: 14)
            context.fill(path, with: .color(ShellPalette.cream.opacity(0.06)))
            context.stroke(path, with: .color(ShellPalette.cream.opacity(0.55)), style: StrokeStyle(lineWidth: 1.5 / k, dash: [8 / k, 6 / k]))
        }
        // Its built-in place, dashed, once it has moved.
        if model.editing.isMoved(m) {
            var built = model.editing
            built.putBack(m)
            let home = built.geo
            for c in home.drawnControls where model.editing.mover(c) == m {
                for shape in Self.shapes(c, home) {
                    context.stroke(PadDrawing.outline(shape), with: .color(ShellPalette.cream.opacity(0.5)), style: StrokeStyle(lineWidth: 1.5 / k, dash: [5 / k, 5 / k]))
                }
            }
        }
    }

    /// The keys in the editor: brighter than in the settings' small preview, with lines of the same width at every preview size. The
    /// chosen control is filled cream with dark type and a soft halo, a refused spot red, so it reads at a glance.
    func draw(_ c: TouchLayout.Control, _ g: PadGeo, k: CGFloat, highlight: Highlight = .none, in context: inout GraphicsContext) {
        var style = PadDrawing.Style(fill: .white.opacity(0.17), line: .white.opacity(0.62), text: .white.opacity(0.9), ring: .white.opacity(0.07),
                                     lineWidth: 1.5 / k)
        var halo: Color?
        switch highlight {
        case .none: break
        case .chosen:
            style.fill = ShellPalette.cream.opacity(model.held ? 1 : 0.9); style.line = ShellPalette.cream; style.text = .black.opacity(0.85)
            style.ring = ShellPalette.cream.opacity(0.22); style.lineWidth = 2.5 / k
            halo = ShellPalette.cream.opacity(model.held ? 0.5 : 0.32)
        case .refused:
            style.fill = DeleteStyle.red.opacity(0.9); style.line = DeleteStyle.red; style.text = .white
            style.ring = DeleteStyle.red.opacity(0.25); style.lineWidth = 2.5 / k
            halo = DeleteStyle.red.opacity(0.4)
        }
        for shape in Self.shapes(c, g) {
            if let halo { context.stroke(PadDrawing.outline(shape), with: .color(halo), lineWidth: (model.held ? 12 : 9) / k) }
            PadDrawing.draw(shape, in: &context, style: style)
        }
    }

    /// The drawn shapes of one control, in the gamepad's look.
    static func shapes(_ c: TouchLayout.Control, _ g: PadGeo) -> [TouchPadPreviewGeometry.Shape] {
        switch c {
        case .face: (0..<4).map { .circle(g.faceKey[$0], g.faceR, label: ["A", "B", "X", "Y"][$0]) }
        case .a: [.circle(g.faceKey[0], g.faceR, label: "A")]
        case .b: [.circle(g.faceKey[1], g.faceR, label: "B")]
        case .x: [.circle(g.faceKey[2], g.faceR, label: "X")]
        case .y: [.circle(g.faceKey[3], g.faceR, label: "Y")]
        case .stick: [.ring(g.stick, g.stickR, knob: g.knobR)]
        case .dpad: [.dpad(g.dpad, g.dpadR)]
        case .zl, .l, .zr, .r:
            [.drop(g.drop[PadGeo.dropIndex(c)], g.dropR[PadGeo.dropIndex(c)], tipRight: c == .zr || c == .r, label: c.title)]
        case .l3: [.circle(g.click[0], g.clickR, label: "L3")]
        case .r3: [.circle(g.click[1], g.clickR, label: "R3")]
        case .minus: [.pill(g.pill[0], label: "−")]
        case .plus: [.pill(g.pill[1], label: "+")]
        }
    }
}
