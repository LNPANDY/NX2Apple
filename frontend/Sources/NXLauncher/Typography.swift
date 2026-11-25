import SwiftUI
import CoreText
import NXCore

/// The interface face, Manrope, from the binary (EmbeddedFonts.swift); the system's when it cannot be read.
/// Paths and the build log use the system's monospaced face.
package enum Typography {
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

    /// The same weight as a Core Text weight trait (NSFont.Weight's values), for the faces after Manrope.
    private static func weightTrait(_ weight: Font.Weight) -> CGFloat {
        switch weight {
        case .ultraLight: return -0.8
        case .thin: return -0.6
        case .light: return -0.4
        case .medium: return 0.23
        case .semibold: return 0.3
        case .bold: return 0.4
        case .heavy: return 0.56
        case .black: return 0.62
        default: return 0
        }
    }

    /// The face for the Chinese, Japanese or Korean characters Manrope does not have, by the launcher's language (#1514).
    ///
    /// Without it Core Text falls back character by character by the Mac's languages. On a Mac with Japanese first, a Chinese title
    /// then takes the characters Japanese shares from a Japanese face and the Simplified-only ones from a Chinese face of another
    /// weight, so one title shows two weights. Other languages keep the system's fallback.
    package static func cjkFamily(_ lang: Lang) -> String? {
        switch lang.code {
        case "zh": return "PingFang SC"
        case "ja": return "Hiragino Sans"
        case "ko": return "Apple SD Gothic Neo"
        default: return nil
        }
    }

    /// The installed face of `family` nearest to `weight`, named exactly, so the cascade list does not pick its own weight.
    private static func cascadeFace(_ family: String, weight: Font.Weight) -> CTFontDescriptor? {
        let wanted = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family,
                                                           kCTFontTraitsAttribute: [kCTFontWeightTrait: weightTrait(weight)]] as CFDictionary)
        let mandatory: Set<String> = [kCTFontFamilyNameAttribute as String]
        guard let match = CTFontDescriptorCreateMatchingFontDescriptor(wanted, mandatory as CFSet),
              let name = CTFontDescriptorCopyAttribute(match, kCTFontNameAttribute) as? String else { return nil }
        return CTFontDescriptorCreateWithNameAndSize(name as CFString, 0)
    }

    private static func ctFont(_ face: CTFontDescriptor?, size: CGFloat, weight: Font.Weight, cjk: String?) -> CTFont? {
        LauncherWork.count(.font)   // before the guard, so the count is the same where Manrope cannot be read
        guard let face else { return nil }
        var attributes: [CFString: Any] = [kCTFontVariationAttribute: [0x7767_6874: axis(weight)]]
        if let cjk, let fallback = cascadeFace(cjk, weight: weight) { attributes[kCTFontCascadeListAttribute] = [fallback] }
        let variation = CTFontDescriptorCreateCopyWithAttributes(face, attributes as CFDictionary)
        return CTFontCreateWithFontDescriptor(variation, size, nil)
    }

    /// Manrope as a CTFont, to measure how wide a label is set (nil when the face cannot be read). `lang` is the launcher's language
    /// (`Lang.interface`) unless a test names one.
    package static func manropeFont(size: CGFloat, weight: Font.Weight, lang: Lang? = nil) -> CTFont? {
        manropeFace(size: size, weight: weight, lang: lang).ctFont
    }

    package static func text(_ size: CGFloat, _ weight: Font.Weight) -> Font { manropeFace(size: size, weight: weight, lang: nil).font }

    /// Every label asks for its font each time a page is drawn, and a page has hundreds of labels. Each size and
    /// weight is made once: one CTFont and one Font, so Core Text and SwiftUI see the same font again and reuse
    /// what they measured.
    private struct Face { let ctFont: CTFont?; let font: Font }
    /// The CJK face is part of the key: languages without one share their fonts, and a language change makes the new ones.
    private struct FaceKey: Hashable { let size: CGFloat; let weight: Font.Weight; let cjk: String? }
    private static let facesLock = NSLock()
    private static var faces: [FaceKey: Face] = [:]
    private static func manropeFace(size: CGFloat, weight: Font.Weight, lang: Lang?) -> Face {
        facesLock.lock()
        defer { facesLock.unlock() }
        let cjk = cjkFamily(lang ?? Lang.interface)
        let key = FaceKey(size: size, weight: weight, cjk: cjk)
        if let face = faces[key] { return face }
        let ct = ctFont(manrope, size: size, weight: weight, cjk: cjk)
        let face = Face(ctFont: ct, font: ct.map { Font($0) } ?? .system(size: size, weight: weight))
        faces[key] = face
        return face
    }
}

extension Font {
    /// Manrope, the interface's face.
    package static func manrope(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { Typography.text(size, weight) }
    /// The system's monospaced face: paths and the build log.
    package static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .monospaced) }
}

/// A thick rounded bar on a dark track, the launcher's build progress. Without a value (a step that reports
/// no percentage) it shows calm diagonal stripes that run steadily to the right: a barber pole, not a bounce.
/// When `segments` has multiple steps, each step occupies a proportional segment of the bar and fills inside its share.
package struct LauncherProgressBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    package var value: Double?
    package var height: CGFloat = 8
    package var tint: Color = LauncherPalette.building
    package var segments: [ProgressSegment] = []

    package init(value: Double?, height: CGFloat = 8, tint: Color = LauncherPalette.building, segments: [ProgressSegment] = []) {
        self.value = value; self.height = height; self.tint = tint; self.segments = segments
    }

    package var body: some View {
        Group {
            if segments.count > 1 {
                segmentedBody
            } else {
                singleBody
            }
        }
        .frame(height: height)
        .clipShape(Capsule())
        .accessibilityElement()
        .accessibilityValue(value.map { "\(Int($0 * 100))%" } ?? "")
    }

    private var singleBody: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(LauncherPalette.ink(0.12))
            if let value {
                GeometryReader { g in
                    Capsule().fill(tint).frame(width: max(height, g.size.width * min(max(value, 0), 1)))
                        .animation(LauncherMotion.animation(.easeOut(duration: 0.3), reduceMotion: reduceMotion), value: value)
                }
            } else {
                indeterminateStripes
            }
        }
    }

    private var segmentedBody: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 2
            let totalSpacing = spacing * CGFloat(max(0, segments.count - 1))
            let usableWidth = max(0, geo.size.width - totalSpacing)
            let totalWeight = max(0.1, segments.reduce(0.0) { $0 + max(0.1, $1.weight) })
            HStack(spacing: spacing) {
                ForEach(segments) { segment in
                    let width = usableWidth * CGFloat(max(0.1, segment.weight) / totalWeight)
                    segmentView(segment, width: width)
                        .frame(width: max(2, width), height: height)
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                }
            }
        }
    }

    @ViewBuilder private func segmentView(_ segment: ProgressSegment, width: CGFloat) -> some View {
        switch segment.state {
        case .done:
            Rectangle().fill(tint)
        case .pending:
            Rectangle().fill(LauncherPalette.ink(0.12))
        case .failed:
            ZStack(alignment: .leading) {
                Rectangle().fill(LauncherPalette.ink(0.12))
                let fillWidth = max(min(width, 2), width * min(max(segment.fraction ?? 1.0, 0), 1))
                Rectangle().fill(DS.Color.statusError).frame(width: fillWidth)
            }
        case .running:
            ZStack(alignment: .leading) {
                if let frac = segment.fraction {
                    Rectangle().fill(LauncherPalette.ink(0.12))
                    let fillWidth = frac > 0 ? max(min(width, 2), width * min(max(frac, 0), 1)) : 0
                    Rectangle().fill(tint).frame(width: fillWidth)
                        .animation(LauncherMotion.animation(.easeOut(duration: 0.3), reduceMotion: reduceMotion), value: frac)
                } else {
                    indeterminateStripes
                }
            }
        }
    }

    private var indeterminateStripes: some View {
        ZStack {
            Rectangle().fill(tint.opacity(0.16))   // a tinted track under soft stripes
            TimelineView(.animation(paused: reduceMotion)) { context in
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
}
