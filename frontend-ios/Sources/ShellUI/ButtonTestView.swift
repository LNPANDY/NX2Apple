import SwiftUI

/// The button test: an Xbox controller drawn whole, each button lighting up while it is held, the sticks moving and the
/// triggers filling as they are pulled. Every button belongs to the test while it is open, so a controller closes it by
/// holding B. Touch closes it with ×, a keyboard with Escape.
struct ButtonTestView: View {
    let snapshot: PadSnapshot?
    let close: () -> Void
    /// How long B is held to close.
    static let holdToClose: Double = 1.5
    @State private var holding = false
    @State private var holdTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ShellStrings.text("Button test")).shellType(ShellType.flowTitle(20)).lineLimit(1)
                        .accessibilityAddTraits(.isHeader).accessibilityIdentifier("buttonTest.title")
                    Text(snapshot.map { $0.name.isEmpty ? ShellStrings.text("Controller") : $0.name } ?? ShellStrings.text("Press any button on a controller"))
                        .shellType(ShellType.note).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .semibold)).frame(width: 44, height: 44)
                        .background(.white.opacity(0.08), in: Circle()).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(ShellStrings.text("Close"))
                .accessibilityIdentifier("buttonTest.close")
                .shellTarget("test.close", radius: 22, action: close)
            }
            .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 8)
            Rectangle().fill(ShellPalette.hairline).frame(height: 1)
            XboxControllerDiagram(snapshot: snapshot ?? PadSnapshot())
                .aspectRatio(XboxControllerDiagram.design.width / XboxControllerDiagram.design.height, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 10)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(ShellStrings.text("Controller"))
                .accessibilityValue(pressedText)
                .accessibilityIdentifier("buttonTest.diagram")
            Text(pressedText).shellText(14.5, .semibold).foregroundStyle(ShellPalette.cream)
                .lineLimit(2).frame(maxWidth: .infinity, minHeight: 40).multilineTextAlignment(.center)
                .padding(.horizontal, 20)
                .accessibilityIdentifier("buttonTest.pressed")
            HStack(spacing: 10) {
                ZStack {
                    Circle().stroke(.white.opacity(0.15), lineWidth: 3)
                    Circle().trim(from: 0, to: holding ? 1 : 0).stroke(ShellPalette.cream, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text(verbatim: "B").font(ShellFonts.fixed(10, weight: .bold))
                }.frame(width: 22, height: 22).accessibilityHidden(true)
                Text(ShellStrings.text("Hold B to close")).shellText(13, .medium, relativeTo: .footnote).foregroundStyle(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity).padding(.bottom, 18).padding(.top, 4)
        }
        .frame(maxWidth: 620)
        .background(Color(red: 0.075, green: 0.075, blue: 0.082), in: RoundedRectangle(cornerRadius: 26))
        .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(.white.opacity(0.10)))
        .shadow(color: .black.opacity(0.5), radius: 40)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("buttonTest")
        .onChange(of: snapshot?.pressed.contains(.b) ?? false) { _, held in held ? startHold() : stopHold() }
        .onDisappear { holdTask?.cancel() }
    }

    private var pressedText: String {
        let pressed = PadElement.allCases.filter { snapshot?.pressed.contains($0) == true }.map(XboxControllerDiagram.name)
        return pressed.isEmpty ? ShellStrings.text("No button held") : pressed.joined(separator: " + ")
    }

    private func startHold() {
        withAnimation(.linear(duration: Self.holdToClose)) { holding = true }
        holdTask?.cancel()
        holdTask = Task {
            try? await Task.sleep(for: .seconds(Self.holdToClose))
            if !Task.isCancelled { close() }
        }
    }
    private func stopHold() {
        holdTask?.cancel()
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { holding = false }
    }
}

/// An Xbox controller in outline, drawn in a 320 × 220 design space and scaled to fit. Held buttons light up: the face
/// buttons in their own colours, everything else in cream.
struct XboxControllerDiagram: View {
    let snapshot: PadSnapshot
    static let design = CGSize(width: 320, height: 220)

    static func name(_ element: PadElement) -> String {
        switch element {
        case .a: "A"
        case .b: "B"
        case .x: "X"
        case .y: "Y"
        case .leftBumper: "LB"
        case .rightBumper: "RB"
        case .leftTrigger: "LT"
        case .rightTrigger: "RT"
        case .leftStick: "LS"
        case .rightStick: "RS"
        case .view: "View"
        case .menu: "Menu"
        case .home: "Xbox"
        case .up: ShellStrings.text("D-pad up")
        case .down: ShellStrings.text("D-pad down")
        case .left: ShellStrings.text("D-pad left")
        case .right: ShellStrings.text("D-pad right")
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let s = min(geometry.size.width / Self.design.width, geometry.size.height / Self.design.height)
            ZStack(alignment: .topLeading) {
                trigger(.leftTrigger, value: snapshot.leftTrigger, x: 62, s: s)
                trigger(.rightTrigger, value: snapshot.rightTrigger, x: 216, s: s)
                bumper(.leftBumper, x: 52, s: s)
                bumper(.rightBumper, x: 196, s: s)
                ControllerBody()
                    .fill(Color.white.opacity(0.06))
                    .overlay(ControllerBody().stroke(Color.white.opacity(0.35), lineWidth: max(1, 1.6 * s)))
                    .frame(width: Self.design.width * s, height: Self.design.height * s)
                stick(.leftStick, at: CGPoint(x: 88, y: 92), offset: snapshot.leftStick, s: s)
                stick(.rightStick, at: CGPoint(x: 202, y: 140), offset: snapshot.rightStick, s: s)
                dpad(center: CGPoint(x: 118, y: 140), s: s)
                face(.y, at: CGPoint(x: 240, y: 70), color: Color(red: 0.98, green: 0.80, blue: 0.20), s: s)
                face(.x, at: CGPoint(x: 219, y: 92), color: Color(red: 0.25, green: 0.55, blue: 1.0), s: s)
                face(.b, at: CGPoint(x: 261, y: 92), color: Color(red: 0.95, green: 0.30, blue: 0.28), s: s)
                face(.a, at: CGPoint(x: 240, y: 114), color: Color(red: 0.35, green: 0.80, blue: 0.30), s: s)
                small(.view, symbol: "rectangle.on.rectangle", at: CGPoint(x: 138, y: 92), s: s)
                small(.menu, symbol: "line.3.horizontal", at: CGPoint(x: 182, y: 92), s: s)
                home(at: CGPoint(x: 160, y: 60), s: s)
            }
            .frame(width: Self.design.width * s, height: Self.design.height * s)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func held(_ e: PadElement) -> Bool { snapshot.pressed.contains(e) }

    private func place(_ view: some View, center: CGPoint, size: CGSize, s: CGFloat) -> some View {
        view.frame(width: size.width * s, height: size.height * s)
            .position(x: center.x * s, y: center.y * s)
    }

    private func trigger(_ e: PadElement, value: Double, x: CGFloat, s: CGFloat) -> some View {
        let on = held(e) || value > 0.05
        let shape = UnevenRoundedRectangle(topLeadingRadius: 10 * s, bottomLeadingRadius: 3 * s, bottomTrailingRadius: 3 * s, topTrailingRadius: 10 * s)
        return place(
            ZStack(alignment: .bottom) {
                shape.fill(Color.white.opacity(0.06))
                shape.fill(ShellPalette.cream.opacity(0.9)).scaleEffect(x: 1, y: max(0, min(1, held(e) && value < 0.05 ? 1 : value)), anchor: .bottom)
                shape.stroke(Color.white.opacity(on ? 0.9 : 0.35), lineWidth: max(1, 1.4 * s))
                Text(Self.name(e)).font(ShellFonts.fixed(9 * s, weight: .bold)).foregroundStyle(on ? .black : .white.opacity(0.7))
                    .frame(maxHeight: .infinity)
            },
            center: CGPoint(x: x + 21, y: 13), size: CGSize(width: 42, height: 22), s: s)
    }

    private func bumper(_ e: PadElement, x: CGFloat, s: CGFloat) -> some View {
        let on = held(e)
        return place(
            ZStack {
                Capsule().fill(on ? ShellPalette.cream : Color.white.opacity(0.06))
                Capsule().stroke(Color.white.opacity(on ? 0.9 : 0.35), lineWidth: max(1, 1.4 * s))
                Text(Self.name(e)).font(ShellFonts.fixed(8 * s, weight: .bold)).foregroundStyle(on ? .black : .white.opacity(0.7))
            },
            center: CGPoint(x: x + 36, y: 32), size: CGSize(width: 72, height: 12), s: s)
    }

    private func stick(_ e: PadElement, at c: CGPoint, offset: CGPoint, s: CGFloat) -> some View {
        let on = held(e)
        let moved = hypot(offset.x, offset.y) > 0.15
        return ZStack {
            place(Circle().fill(Color.black.opacity(0.35)).overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: max(1, s))),
                  center: c, size: CGSize(width: 46, height: 46), s: s)
            place(Circle().fill(on ? ShellPalette.cream : Color(white: moved ? 0.42 : 0.26))
                    .overlay(Circle().stroke(Color.white.opacity(on || moved ? 0.9 : 0.4), lineWidth: max(1, 1.4 * s))),
                  center: CGPoint(x: c.x + offset.x * 10, y: c.y - offset.y * 10), size: CGSize(width: 30, height: 30), s: s)
        }
    }

    private func dpad(center c: CGPoint, s: CGFloat) -> some View {
        let arms: [(PadElement, CGFloat, CGFloat)] = [(.up, 0, -12), (.down, 0, 12), (.left, -12, 0), (.right, 12, 0)]
        return ZStack {
            place(RoundedRectangle(cornerRadius: 3 * s).fill(Color.white.opacity(0.10)), center: c, size: CGSize(width: 12, height: 12), s: s)
            ForEach(arms, id: \.0) { e, dx, dy in
                place(RoundedRectangle(cornerRadius: 3 * s).fill(held(e) ? ShellPalette.cream : Color.white.opacity(0.10))
                        .overlay(RoundedRectangle(cornerRadius: 3 * s).stroke(Color.white.opacity(held(e) ? 0.9 : 0.35), lineWidth: max(1, s))),
                      center: CGPoint(x: c.x + dx, y: c.y + dy), size: CGSize(width: 12, height: 12), s: s)
            }
        }
    }

    private func face(_ e: PadElement, at c: CGPoint, color: Color, s: CGFloat) -> some View {
        let on = held(e)
        return place(
            ZStack {
                Circle().fill(on ? color : Color.black.opacity(0.35))
                Circle().stroke(on ? Color.white : color.opacity(0.8), lineWidth: max(1, 1.5 * s))
                Text(Self.name(e)).font(ShellFonts.fixed(11 * s, weight: .heavy)).foregroundStyle(on ? .black : color)
            }
            .shadow(color: on ? color.opacity(0.8) : .clear, radius: 8 * s),
            center: c, size: CGSize(width: 20, height: 20), s: s)
    }

    private func small(_ e: PadElement, symbol: String, at c: CGPoint, s: CGFloat) -> some View {
        let on = held(e)
        return place(
            ZStack {
                Circle().fill(on ? ShellPalette.cream : Color.black.opacity(0.35))
                Circle().stroke(Color.white.opacity(on ? 0.9 : 0.35), lineWidth: max(1, s))
                Image(systemName: symbol).font(.system(size: 6 * s, weight: .bold)).foregroundStyle(on ? .black : .white.opacity(0.7))
            },
            center: c, size: CGSize(width: 14, height: 14), s: s)
    }

    private func home(at c: CGPoint, s: CGFloat) -> some View {
        let on = held(.home)
        return place(
            ZStack {
                Circle().fill(on ? ShellPalette.cream : Color.black.opacity(0.35))
                Circle().stroke(Color.white.opacity(on ? 0.9 : 0.45), lineWidth: max(1, 1.4 * s))
                Image(systemName: "xmark").font(.system(size: 8 * s, weight: .heavy)).foregroundStyle(on ? .black : .white.opacity(0.75))
            },
            center: c, size: CGSize(width: 22, height: 22), s: s)
    }
}

/// The outline of an Xbox controller: a broad top, the two grips curving down and in, a shallow bottom between them.
private struct ControllerBody: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / XboxControllerDiagram.design.width, sy = rect.height / XboxControllerDiagram.design.height
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
