import SwiftUI
import CoreText

/// The interface face, Manrope, from the binary (EmbeddedFonts.swift); the system's when it cannot be read.
/// Paths and the build log use the system's monospaced face.
enum Typography {
    private static let manrope = descriptor(EmbeddedFonts.manrope)

    private static func descriptor(_ base64: String) -> CTFontDescriptor? {
        guard let data = Data(base64Encoded: base64) else { return nil }
        return CTFontManagerCreateFontDescriptorFromData(data as CFData)
    }

    /// The variable font's weight axis ('wght') at the weight SwiftUI names.
    private static func axis(_ weight: Font.Weight) -> CGFloat {
        switch weight {
        case .ultraLight: return 200
        case .thin, .light: return 300
        case .medium: return 500
        case .semibold: return 600
        case .bold: return 700
        case .heavy, .black: return 800
        default: return 400
        }
    }

    private static func ctFont(_ face: CTFontDescriptor?, size: CGFloat, weight: Font.Weight) -> CTFont? {
        guard let face else { return nil }
        let variation = CTFontDescriptorCreateCopyWithAttributes(face, [kCTFontVariationAttribute: [0x7767_6874: axis(weight)]] as CFDictionary)
        return CTFontCreateWithFontDescriptor(variation, size, nil)
    }

    static func font(_ face: CTFontDescriptor?, size: CGFloat, weight: Font.Weight, fallback: Font) -> Font {
        ctFont(face, size: size, weight: weight).map { Font($0) } ?? fallback
    }

    /// Manrope as a CTFont, to measure how wide a label is set (nil when the face cannot be read).
    static func manropeFont(size: CGFloat, weight: Font.Weight) -> CTFont? { ctFont(manrope, size: size, weight: weight) }

    static func text(_ size: CGFloat, _ weight: Font.Weight) -> Font {
        font(manrope, size: size, weight: weight, fallback: .system(size: size, weight: weight))
    }
}

extension Font {
    /// Manrope, the interface's face.
    static func manrope(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { Typography.text(size, weight) }
    /// The system's monospaced face: paths and the build log.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .monospaced) }
}

/// A thick rounded bar on a dark track, the launcher's build progress. Without a value (a step that reports
/// no percentage) it shows calm diagonal stripes that run steadily to the right: a barber pole, not a bounce.
struct LauncherProgressBar: View {
    var value: Double?
    var height: CGFloat = 8
    var tint: Color = LauncherPalette.building

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.12))
            if let value {
                GeometryReader { g in
                    Capsule().fill(tint).frame(width: max(height, g.size.width * min(max(value, 0), 1)))
                        .animation(.easeOut(duration: 0.3), value: value)
                }
            } else {
                Capsule().fill(tint.opacity(0.16))   // an amber-tinted track under soft stripes
                TimelineView(.animation) { context in
                    Canvas { canvas, size in
                        // One stripe and one gap per period; the pattern moves one period every 1.2 s, linearly
                        let period = height * 3, stripe = height * 1.5
                        let t = context.date.timeIntervalSinceReferenceDate
                        let phase = CGFloat(t.truncatingRemainder(dividingBy: 1.2) / 1.2) * period
                        var x = -size.height - period + phase
                        while x < size.width {
                            var p = Path()
                            p.move(to: CGPoint(x: x, y: size.height))
                            p.addLine(to: CGPoint(x: x + size.height, y: 0))
                            p.addLine(to: CGPoint(x: x + size.height + stripe, y: 0))
                            p.addLine(to: CGPoint(x: x + stripe, y: size.height))
                            p.closeSubpath()
                            canvas.fill(p, with: .color(tint.opacity(0.45)))
                            x += period
                        }
                    }
                }
            }
        }
        .frame(height: height)
        .clipShape(Capsule())
        .accessibilityElement()
        .accessibilityValue(value.map { "\(Int($0 * 100))%" } ?? "")
    }
}
