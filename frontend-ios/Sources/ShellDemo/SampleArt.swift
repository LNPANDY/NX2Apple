import SwiftUI
import ShellUI

/// Square icons for the fictional sample games, drawn here and rendered to images at launch. The views receive them
/// exactly as they will receive a real game's NACP icon, the fallback when a game has no banner. Each game has its own palette, composition and lettering, so the
/// library reads as a shelf of different games. Nothing here is taken from a real game.
@MainActor enum SampleArt {
    private static var cache: [String: Artwork] = [:]

    /// The square icon, with the game's lettering, as a NACP icon has it.
    static func icon(_ id: String) -> Artwork? { render(id, lettering: true) }

    private static func render(_ id: String, lettering: Bool) -> Artwork? {
        let key = "\(id).\(lettering)"
        if let art = cache[key] { return art }
        _ = ShellFonts.font(12)   // registers Manrope before the first render
        let renderer = ImageRenderer(content: composition(id).environment(\.lettering, lettering).frame(width: 384, height: 384))
        renderer.scale = 2.5
        guard let image = renderer.cgImage else { return nil }
        let art = Artwork(id: "sample.\(key)", image: image)
        cache[key] = art
        return art
    }

    @ViewBuilder static func composition(_ id: String) -> some View {
        switch id {
        case "orbit": OrbitValleyArt()
        case "tide": QuietTideArt()
        case "paper": PaperTrailsArt()
        case "moon": MoonlitExpressArt()
        case "wild": WildGardensArt()
        case "drift": DriftAtlasArt()
        case "amber": AmberHoursArt()
        default: Color.gray
        }
    }
}

/// The game's lettering in the picture. Always on for icons, kept switchable for previews of the bare art.
private struct LetteringKey: EnvironmentKey { static let defaultValue = true }
private extension EnvironmentValues {
    var lettering: Bool {
        get { self[LetteringKey.self] }
        set { self[LetteringKey.self] = newValue }
    }
}

private func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r, green: g, blue: b) }
private func manrope(_ size: CGFloat, _ weight: Font.Weight) -> Font { .custom("Manrope", fixedSize: size).weight(weight) }

/// A repeatable sequence, so the scattered stars and leaves land in the same places on every launch.
private struct Scatter {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat((state >> 33) % 10_000) / 10_000
    }
}

/// A band of land or water: a sine line across, filled down to the bottom edge.
private struct Wave: Shape {
    var baseline: CGFloat
    var amplitude: CGFloat
    var frequency: CGFloat
    var phase: CGFloat
    var filled = true
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let steps = 80
        for step in 0...steps {
            let x = rect.width * CGFloat(step) / CGFloat(steps)
            let y = rect.height * baseline + sin(x / rect.width * .pi * 2 * frequency + phase) * rect.height * amplitude
            if step == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        if filled {
            path.addLine(to: CGPoint(x: rect.width, y: rect.height))
            path.addLine(to: CGPoint(x: 0, y: rect.height))
            path.closeSubpath()
        }
        return path
    }
}

// MARK: Orbit Valley: warm dusk over teal hills, a planet on its rings

private struct OrbitValleyArt: View {
    @Environment(\.lettering) private var lettering
    var body: some View {
        GeometryReader { g in
            let s = g.size.width
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [rgb(0.06, 0.19, 0.24), rgb(0.52, 0.46, 0.40), rgb(0.97, 0.64, 0.44)],
                               startPoint: .top, endPoint: .bottom)
                Circle().fill(rgb(1, 0.87, 0.64)).frame(width: s * 0.36).position(x: s * 0.42, y: s * 0.66)
                ForEach(0..<3, id: \.self) { ring in
                    Ellipse().stroke(rgb(1, 0.95, 0.86).opacity(0.55 - Double(ring) * 0.15), lineWidth: s * 0.006)
                        .frame(width: s * (0.62 + CGFloat(ring) * 0.26), height: s * (0.16 + CGFloat(ring) * 0.07))
                        .rotationEffect(.degrees(-14)).position(x: s * 0.6, y: s * 0.4)
                }
                Circle().fill(rgb(0.98, 0.95, 0.9)).frame(width: s * 0.075).position(x: s * 0.9, y: s * 0.29)
                Circle().fill(rgb(0.98, 0.95, 0.9)).frame(width: s * 0.13).position(x: s * 0.6, y: s * 0.4)
                    .shadow(color: rgb(1, 0.8, 0.6).opacity(0.6), radius: s * 0.03)
                Wave(baseline: 0.70, amplitude: 0.035, frequency: 1.3, phase: 0.6).fill(rgb(0.10, 0.31, 0.31))
                Wave(baseline: 0.78, amplitude: 0.04, frequency: 1.1, phase: 2.4).fill(rgb(0.06, 0.22, 0.23))
                Wave(baseline: 0.88, amplitude: 0.03, frequency: 1.6, phase: 4.0).fill(rgb(0.03, 0.12, 0.13))
                Text("ORBIT\nVALLEY").font(manrope(s * 0.105, .heavy)).tracking(s * 0.012).lineSpacing(-s * 0.03)
                    .foregroundStyle(rgb(1, 0.97, 0.9)).padding(s * 0.075).opacity(lettering ? 1 : 0)
            }
        }
    }
}

// MARK: The Quiet Tide: a navy sea under a pale moon, set in a serif italic

private struct QuietTideArt: View {
    @Environment(\.lettering) private var lettering
    var body: some View {
        GeometryReader { g in
            let s = g.size.width
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: [rgb(0.03, 0.06, 0.13), rgb(0.06, 0.13, 0.23)], startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [rgb(0.9, 0.92, 1).opacity(0.22), .clear], center: UnitPoint(x: 0.68, y: 0.28),
                               startRadius: 0, endRadius: s * 0.45)
                Circle().fill(rgb(0.94, 0.92, 0.85)).frame(width: s * 0.25).position(x: s * 0.68, y: s * 0.28)
                ForEach(0..<7, id: \.self) { index in
                    Capsule().fill(rgb(0.94, 0.92, 0.85).opacity(0.5 - Double(index) * 0.06))
                        .frame(width: s * (0.22 - CGFloat(index) * 0.022), height: s * 0.008)
                        .position(x: s * 0.68, y: s * (0.58 + CGFloat(index) * 0.035))
                }
                ForEach(0..<9, id: \.self) { index in
                    Wave(baseline: 0.56 + CGFloat(index) * 0.045, amplitude: 0.006 + CGFloat(index) * 0.002,
                         frequency: 2.5 + CGFloat(index) * 0.3, phase: CGFloat(index) * 1.7, filled: false)
                        .stroke(rgb(0.55, 0.72, 0.88).opacity(0.18 + Double(index) * 0.04), lineWidth: s * 0.005)
                }
                VStack(alignment: .leading, spacing: s * 0.01) {
                    Text("THE").font(manrope(s * 0.035, .bold)).tracking(s * 0.02)
                    Text("Quiet Tide").font(.system(size: s * 0.11, weight: .regular, design: .serif).italic())
                }.foregroundStyle(rgb(0.95, 0.93, 0.86)).padding(s * 0.08).opacity(lettering ? 1 : 0)
            }
        }
    }
}

// MARK: Paper Trails: a folded map on cream paper, a red dashed route, heavy ink lettering

private struct PaperTrailsArt: View {
    @Environment(\.lettering) private var lettering
    var body: some View {
        GeometryReader { g in
            let s = g.size.width
            ZStack(alignment: .topLeading) {
                rgb(0.95, 0.92, 0.85)
                Path { p in
                    p.move(to: CGPoint(x: s * 0.34, y: 0)); p.addLine(to: CGPoint(x: s * 0.66, y: 0))
                    p.addLine(to: CGPoint(x: s * 0.66, y: s)); p.addLine(to: CGPoint(x: s * 0.34, y: s))
                }.fill(.black.opacity(0.045))
                Path { p in
                    p.move(to: CGPoint(x: s * 0.66, y: 0)); p.addLine(to: CGPoint(x: s, y: 0))
                    p.addLine(to: CGPoint(x: s, y: s)); p.addLine(to: CGPoint(x: s * 0.66, y: s))
                }.fill(.black.opacity(0.02))
                Path { p in
                    p.move(to: CGPoint(x: s * 0.08, y: s * 0.9))
                    p.addCurve(to: CGPoint(x: s * 0.5, y: s * 0.62), control1: CGPoint(x: s * 0.35, y: s * 0.95), control2: CGPoint(x: s * 0.2, y: s * 0.6))
                    p.addCurve(to: CGPoint(x: s * 0.82, y: s * 0.36), control1: CGPoint(x: s * 0.8, y: s * 0.64), control2: CGPoint(x: s * 0.62, y: s * 0.38))
                }.stroke(rgb(0.86, 0.27, 0.2), style: StrokeStyle(lineWidth: s * 0.016, lineCap: .round, dash: [s * 0.035, s * 0.03]))
                ForEach([45.0, -45.0], id: \.self) { angle in
                    Capsule().fill(rgb(0.86, 0.27, 0.2)).frame(width: s * 0.09, height: s * 0.022)
                        .rotationEffect(.degrees(angle)).position(x: s * 0.86, y: s * 0.32)
                }
                Path { p in
                    p.move(to: CGPoint(x: s * 0.05, y: s * 0.97)); p.addLine(to: CGPoint(x: s * 0.2, y: s * 0.86))
                    p.addLine(to: CGPoint(x: s * 0.1, y: s * 0.83)); p.closeSubpath()
                }.fill(rgb(0.99, 0.99, 0.97)).shadow(color: .black.opacity(0.15), radius: s * 0.01, y: s * 0.006)
                Text("PAPER\nTRAILS").font(manrope(s * 0.15, .heavy)).tracking(-s * 0.004).lineSpacing(-s * 0.045)
                    .foregroundStyle(rgb(0.14, 0.13, 0.13)).padding(s * 0.075).opacity(lettering ? 1 : 0)
            }
        }
    }
}

// MARK: Moonlit Express: a night train on a viaduct, gold windows, monospaced lettering

private struct MoonlitExpressArt: View {
    @Environment(\.lettering) private var lettering
    var body: some View {
        GeometryReader { g in
            let s = g.size.width
            let gold = rgb(0.96, 0.80, 0.46)
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: [rgb(0.03, 0.06, 0.09), rgb(0.07, 0.15, 0.17)], startPoint: .top, endPoint: .bottom)
                Canvas { context, size in
                    var scatter = Scatter(7)
                    for _ in 0..<46 {
                        let x = scatter.next() * size.width, y = scatter.next() * size.height * 0.55
                        let r = 0.6 + scatter.next() * 1.6
                        context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)), with: .color(.white.opacity(0.3 + scatter.next() * 0.6)))
                    }
                }
                Circle().fill(gold)
                    .overlay(Circle().fill(.black).offset(x: s * 0.055, y: -s * 0.035).blendMode(.destinationOut))
                    .compositingGroup()
                    .frame(width: s * 0.2).position(x: s * 0.76, y: s * 0.22)
                // The viaduct: a deck and its arches, slightly uphill to the right.
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(rgb(0.02, 0.04, 0.05)).frame(width: s * 1.3, height: s * 0.035)
                    HStack(spacing: s * 0.05) {
                        ForEach(0..<8, id: \.self) { _ in
                            Rectangle().fill(rgb(0.02, 0.04, 0.05)).frame(width: s * 0.035, height: s * 0.5)
                        }
                    }.padding(.leading, s * 0.03)
                    HStack(spacing: s * 0.012) {
                        ForEach(0..<4, id: \.self) { car in
                            RoundedRectangle(cornerRadius: s * 0.015).fill(rgb(0.13, 0.16, 0.18))
                                .frame(width: s * 0.2, height: s * 0.065)
                                .overlay {
                                    HStack(spacing: s * 0.018) {
                                        ForEach(0..<4, id: \.self) { _ in
                                            RoundedRectangle(cornerRadius: s * 0.004).fill(gold).frame(width: s * 0.022, height: s * 0.022)
                                        }
                                    }
                                }
                                .shadow(color: gold.opacity(car == 0 ? 0.5 : 0.25), radius: s * 0.02)
                        }
                    }.offset(x: s * 0.2, y: -s * 0.07)
                }
                .rotationEffect(.degrees(-8), anchor: .topLeading)
                .position(x: s * 0.62, y: s * 0.9)
                Text("MOONLIT\nEXPRESS").font(.system(size: s * 0.07, weight: .semibold, design: .monospaced))
                    .tracking(s * 0.018).foregroundStyle(gold).padding(s * 0.075).opacity(lettering ? 1 : 0)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }
}

// MARK: Wild Gardens: dense leaves, pink flowers, a rounded heavy wordmark

private struct WildGardensArt: View {
    @Environment(\.lettering) private var lettering
    var body: some View {
        GeometryReader { g in
            let s = g.size.width
            let greens = [rgb(0.16, 0.45, 0.25), rgb(0.25, 0.58, 0.30), rgb(0.10, 0.33, 0.20), rgb(0.45, 0.68, 0.32)]
            ZStack(alignment: .bottomLeading) {
                rgb(0.05, 0.19, 0.12)
                Canvas { context, size in
                    var scatter = Scatter(31)
                    for index in 0..<34 {
                        let x = scatter.next() * size.width, y = scatter.next() * size.height
                        var leaf = context
                        leaf.translateBy(x: x, y: y)
                        leaf.rotate(by: .radians(Double(scatter.next()) * .pi))
                        let w = size.width * (0.22 + scatter.next() * 0.16)
                        leaf.fill(Path(ellipseIn: CGRect(x: -w / 2, y: -w * 0.18, width: w, height: w * 0.36)), with: .color(greens[index % 4]))
                        leaf.stroke(Path { p in p.move(to: CGPoint(x: -w / 2, y: 0)); p.addLine(to: CGPoint(x: w / 2, y: 0)) },
                                    with: .color(.black.opacity(0.18)), lineWidth: 1.2)
                    }
                    for _ in 0..<6 {
                        let x = scatter.next() * size.width, y = scatter.next() * size.height * 0.7
                        let petal = size.width * 0.045
                        for k in 0..<5 {
                            let a = Double(k) / 5 * 2 * .pi
                            let px = x + CGFloat(cos(a)) * petal, py = y + CGFloat(sin(a)) * petal
                            context.fill(Path(ellipseIn: CGRect(x: px - petal * 0.8, y: py - petal * 0.8, width: petal * 1.6, height: petal * 1.6)),
                                         with: .color(rgb(0.93, 0.36, 0.53)))
                        }
                        context.fill(Path(ellipseIn: CGRect(x: x - petal * 0.6, y: y - petal * 0.6, width: petal * 1.2, height: petal * 1.2)),
                                     with: .color(rgb(0.99, 0.83, 0.32)))
                    }
                }
                LinearGradient(colors: [.clear, rgb(0.03, 0.12, 0.08).opacity(0.92)], startPoint: UnitPoint(x: 0.5, y: 0.5), endPoint: .bottom)
                Text("Wild\nGardens").font(.system(size: s * 0.13, weight: .heavy, design: .rounded)).lineSpacing(-s * 0.04)
                    .foregroundStyle(rgb(1, 0.95, 0.86)).padding(s * 0.075).opacity(lettering ? 1 : 0)
            }
        }
    }
}

// MARK: Drift Atlas: contour lines on sand, a compass, wide-tracked capitals

private struct DriftAtlasArt: View {
    @Environment(\.lettering) private var lettering
    var body: some View {
        GeometryReader { g in
            let s = g.size.width
            let ink = rgb(0.42, 0.29, 0.18)
            ZStack(alignment: .topLeading) {
                rgb(0.87, 0.79, 0.63)
                Canvas { context, size in
                    func contours(cx: CGFloat, cy: CGFloat, count: Int, step: CGFloat, seed: Double) {
                        for ring in 0..<count {
                            let base = size.width * (0.05 + CGFloat(ring) * step)
                            var path = Path()
                            for k in 0...96 {
                                let a = Double(k) / 96 * 2 * .pi
                                let r = base * (1 + 0.13 * CGFloat(sin(3 * a + seed + Double(ring) * 0.4)) + 0.05 * CGFloat(sin(5 * a + seed)))
                                let point = CGPoint(x: cx + CGFloat(cos(a)) * r, y: cy + CGFloat(sin(a)) * r * 0.85)
                                if k == 0 { path.move(to: point) } else { path.addLine(to: point) }
                            }
                            path.closeSubpath()
                            context.stroke(path, with: .color(ink.opacity(ring % 3 == 2 ? 0.75 : 0.42)), lineWidth: ring % 3 == 2 ? 1.6 : 1)
                        }
                    }
                    contours(cx: size.width * 0.6, cy: size.height * 0.58, count: 9, step: 0.052, seed: 0.3)
                    contours(cx: size.width * 0.16, cy: size.height * 0.34, count: 3, step: 0.05, seed: 2.1)
                }
                ZStack {
                    Circle().stroke(ink, lineWidth: s * 0.005).frame(width: s * 0.17)
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: -s * 0.07)); p.addLine(to: CGPoint(x: s * 0.018, y: 0)); p.addLine(to: CGPoint(x: -s * 0.018, y: 0))
                    }.fill(rgb(0.76, 0.26, 0.18)).offset(x: s * 0.085, y: s * 0.085)
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: s * 0.07)); p.addLine(to: CGPoint(x: s * 0.018, y: 0)); p.addLine(to: CGPoint(x: -s * 0.018, y: 0))
                    }.fill(ink).offset(x: s * 0.085, y: s * 0.085)
                }.frame(width: s * 0.17, height: s * 0.17).rotationEffect(.degrees(18)).position(x: s * 0.2, y: s * 0.8)
                Text("DRIFT ATLAS").font(manrope(s * 0.068, .bold)).tracking(s * 0.03)
                    .foregroundStyle(rgb(0.25, 0.17, 0.10)).padding(s * 0.075).opacity(lettering ? 1 : 0)
            }
        }
    }
}

// MARK: Amber Hours: a sundial in amber, a light wordmark

private struct AmberHoursArt: View {
    @Environment(\.lettering) private var lettering
    var body: some View {
        GeometryReader { g in
            let s = g.size.width
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [rgb(0.99, 0.68, 0.27), rgb(0.62, 0.21, 0.08)], startPoint: .top, endPoint: .bottom)
                ForEach(0..<7, id: \.self) { ring in
                    Circle().stroke(rgb(1, 0.93, 0.8).opacity(0.16 + Double(ring) * 0.04), lineWidth: s * 0.01)
                        .frame(width: s * (0.4 + CGFloat(ring) * 0.26))
                        .position(x: s * 0.08, y: s * 0.96)
                }
                Circle().fill(rgb(1, 0.93, 0.78)).frame(width: s * 0.2).position(x: s * 0.74, y: s * 0.34)
                    .shadow(color: rgb(1, 0.85, 0.5), radius: s * 0.05)
                Capsule().fill(rgb(0.33, 0.09, 0.04)).frame(width: s * 0.82, height: s * 0.022)
                    .rotationEffect(.degrees(-38), anchor: .leading)
                    .position(x: s * 0.49, y: s * 0.96)
                Circle().fill(rgb(0.33, 0.09, 0.04)).frame(width: s * 0.07).position(x: s * 0.08, y: s * 0.96)
                Text("Amber\nHours").font(manrope(s * 0.15, .light)).tracking(-s * 0.004).lineSpacing(-s * 0.05)
                    .foregroundStyle(rgb(1, 0.97, 0.92)).padding(s * 0.075).opacity(lettering ? 1 : 0)
            }
        }
    }
}
